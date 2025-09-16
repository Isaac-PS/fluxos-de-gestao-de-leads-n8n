-- =========================
-- EXTENSIONS
-- =========================
create extension if not exists pg_trgm;
create extension if not exists unaccent;
create extension if not exists vector;

-- (opcional) para alternativas case-insensitive
-- create extension if not exists citext;

-- =========================
-- FUNÇÃO IMUTÁVEL p/ UNACCENT (para usar em índices/expressões)
-- =========================
create or replace function public.unaccent_immutable(txt text)
returns text
language sql
immutable
parallel safe
as $$
  select public.unaccent('public.unaccent'::regdictionary, txt);
$$;

-- =========================
-- TABELA PRINCIPAL
-- =========================
create table if not exists public.lead_v (
  id              bigserial primary key,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  -- core
  full_name       text,
  lead_id         text not null,
  email           text,
  country_iso2    text,
  source          text,
  utm_campaign    text,
  owner           text,
  notes           text,

  -- enrichment / IA
  enriched        boolean default false,
  enriched_at     timestamptz,
  enrichment      jsonb,
  email_status    text,
  company_domain  text,
  company_name    text,
  linkedin_url    text,
  phone_e164      text,
  city            text,

  -- RAG (pgvector 1024)
  embedding_voy   vector(1024),
  notes_hash      text
);

-- unicidade por lead_id
create unique index if not exists uq_lead_v_lead_id on public.lead_v (lead_id);

-- =========================
-- COLUNA GERADA PARA EMAIL NORMALIZADO (NULL p/ vazios)
-- - evita conflito de UNIQUE com e-mails nulos/vazios
-- =========================

-- remove restos de migrações antigas
drop index  if exists public.uq_lead_v_email_lower_idx;
drop index  if exists public.uq_lead_v_email_lower;
alter table public.lead_v drop constraint if exists uq_lead_v_email_lower;

do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'lead_v' and column_name = 'email_lower'
  ) then
    -- recria para garantir a expressão correta
    alter table public.lead_v drop column email_lower;
  end if;

  alter table public.lead_v
    add column email_lower text
    generated always as (
      nullif(lower(trim(coalesce(email, ''))), '')
    ) stored;
end$$;

-- Índice ÚNICO PARCIAL: aplica unicidade só quando email_lower não é NULL
create unique index if not exists uq_lead_v_email_lower_unique
  on public.lead_v (email_lower)
  where email_lower is not null;

-- =========================
-- ÍNDICES GERAIS
-- =========================
create index if not exists idx_lead_v_created_at on public.lead_v (created_at);
create index if not exists idx_lead_v_owner      on public.lead_v (owner);
create index if not exists idx_lead_v_source     on public.lead_v (source);

-- fuzzy (trgm)
create index if not exists idx_lead_v_email_trgm on public.lead_v using gin (email gin_trgm_ops);
create index if not exists idx_lead_v_fullname_trgm
  on public.lead_v using gin ((public.unaccent_immutable(full_name)) gin_trgm_ops);
create index if not exists idx_lead_v_notes_trgm on public.lead_v using gin (notes gin_trgm_ops);

-- vetor (cosine) — 1024 dims
drop index if exists lead_v_embedding_voy_idx;
create index lead_v_embedding_voy_idx
  on public.lead_v using ivfflat (embedding_voy vector_cosine_ops)
  with (lists = 100);

-- =========================
-- TRIGGER updated_at
-- =========================
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end
$$;

drop trigger if exists trg_set_updated_at on public.lead_v;
create trigger trg_set_updated_at
before update on public.lead_v
for each row execute function public.set_updated_at();

-- =========================
-- RPCs (Agente Admin)
-- =========================

-- 1) Buscar por NOME (fuzzy, acento/caixa)
create or replace function public.rpc_search_leads_by_name(
  name text,
  limit_count int default 25,
  offset_count int default 0
)
returns setof public.lead_v
language sql
stable
as $$
  select *
  from public.lead_v
  where public.unaccent_immutable(full_name) ilike '%' || public.unaccent_immutable(name) || '%'
  order by similarity(public.unaccent_immutable(full_name), public.unaccent_immutable(name)) desc,
           created_at desc
  limit least(limit_count, 100)
  offset greatest(offset_count, 0);
$$;

-- 2) Buscar por E-MAIL (exato + fuzzy controlado)
create or replace function public.search_lead_by_email(
  p_email text,
  p_limit int default 25
)
returns setof public.lead_v
language sql
stable
as $$
  with q as (
    select lower(trim(p_email)) as e
  )
  -- match exato (normalizado)
  select l.*
  from public.lead_v l, q
  where q.e is not null and length(q.e) >= 3 and l.email_lower = q.e
  union all
  -- fuzzy leve (ignora o exato)
  select l.*
  from public.lead_v l, q
  where q.e is not null and length(q.e) >= 3
    and l.email_lower is not null
    and l.email_lower <> q.e
    and similarity(l.email_lower, q.e) >= 0.45
  order by 1 desc
  limit least(coalesce(p_limit,25), 100);
$$;

-- 3) Contagem por PAÍS
create or replace function public.count_leads_by_country(
  p_owner  text default null,
  p_source text default null,
  p_start  date default null,
  p_end    date default null
)
returns table(country_iso2 text, lead_count bigint)
language sql
stable
as $$
  with base as (
    select
      case when l.country_iso2 ~ '^[A-Za-z]{2}$' then upper(l.country_iso2) else 'UNK' end as c
    from public.lead_v l
    where (p_owner  is null or l.owner  = p_owner)
      and (p_source is null or l.source = p_source)
      and (p_start  is null or l.created_at >= (p_start)::timestamptz)
      and (p_end    is null or l.created_at <  ((p_end + 1)::timestamptz))
  )
  select c as country_iso2, count(*)::bigint as lead_count
  from base
  group by c;
$$;

-- 4) Contagem por ORIGEM
create or replace function public.count_leads_by_source(
  p_owner        text default null,
  p_country_iso2 text default null,
  p_start        date default null,
  p_end          date default null
)
returns table(source text, lead_count bigint)
language sql
stable
as $$
  with base as (
    select coalesce(l.source, 'unknown') as s
    from public.lead_v l
    where (p_owner        is null or l.owner        = p_owner)
      and (p_country_iso2 is null or upper(coalesce(l.country_iso2,'UNK')) = upper(p_country_iso2))
      and (p_start        is null or l.created_at >= (p_start)::timestamptz)
      and (p_end          is null or l.created_at <  ((p_end + 1)::timestamptz))
  )
  select s as source, count(*)::bigint as lead_count
  from base
  group by s;
$$;

-- 5) Contar por PERÍODO
create or replace function public.contar_por_periodo(
  p_start date,
  p_end   date,
  p_granularity text default 'day'
)
returns table(bucket date, lead_count bigint)
language sql
stable
as $$
  with params as (
    select case
      when lower(coalesce(p_granularity,'day')) in ('day','d') then interval '1 day'
      when lower(p_granularity) in ('week','w')                then interval '1 week'
      else                                                          interval '1 month' end as step
  ),
  series as (
    select generate_series(p_start, p_end, (select step from params))::date as bucket
  )
  select s.bucket,
         count(l.id)::bigint as lead_count
  from series s
  left join public.lead_v l
    on l.created_at >= (s.bucket)::timestamptz
   and l.created_at <  ((s.bucket)::timestamptz + (select step from params))
  group by s.bucket
  order by s.bucket;
$$;

-- 6) RAG (pgvector 1024)
create or replace function public.search_notes_semantic_voy(
  query_embedding vector(1024),
  match_count int default 10
)
returns table(
  id bigint,
  lead_id text,
  full_name text,
  email text,
  notes text,
  similarity double precision
)
language sql
stable
as $$
  select id, lead_id, full_name, email, notes,
         1 - (embedding_voy <=> query_embedding) as similarity
  from public.lead_v
  where embedding_voy is not null
  order by embedding_voy <=> query_embedding
  limit least(match_count, 100);
$$;

-- (para desenvolvimento; em produção, ajuste RLS conforme necessário)
-- alter table public.lead_v disable row level security;
