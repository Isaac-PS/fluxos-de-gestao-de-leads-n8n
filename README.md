
# Pipeline de Leads & Agente Admin

Este pacote contém **os exports dos dois fluxos no N8N** e um guia para que outro usuário importe e execute sem dor de cabeça. Também inclui o SQL de criação da tabela `lead_v` no Supabase (com índices e RPCs), um `.env.example` e uma coleção Postman.

> **Fluxos (já no pacote):**
> - `Fluxo A) Pipeline de Leads.json` — ingestão, normalização/validação, dedupe, roteamento/override de owner, enriquecimento leve, persistência em Supabase e Bubble, notificação e embeddings de notas.
> - `Fluxo B) Agente Admin.json` — agente de IA com buscas, contagens, consulta semântica (RAG) e gestão de coorte no Redis, incluindo confirmação antes de atualizar owner em lote.

---

## 0) Pré‑requisitos

- n8n ≥ 1.50 rodando localmente ou em um servidor (Railway, Render ou Docker).
- Conta **Supabase** (Postgres + pgvector).
- App **Bubble** com **Data API** habilitada.
- **Redis** acessível (local ou serviço gerenciado).
- **Slack** (Incoming Webhook ou App com chat:write).
- Chaves externas: **Abstract API** (email), **Voyage AI** (embeddings), **OpenRouter** (LLM do agente).

---

## 1) Variáveis de ambiente (modelo)

Copie o arquivo `.env.example` para `.env` (ou cadastre como **Variables** no n8n) e preencha:

```
# Supabase (Copie do seu projeto do Supabase a URL, A KEY e a SERVICE_ROLE)
SUPABASE_URL=
SUPABASE_KEY=
SUPABASE_SERVICE_ROLE=

# Bubble (Copie do seu projeto do Bubble a URL base ex: https://seu-app.bubbleapps.io/version-test/, e a API token)
BUBBLE_API_URL=
BUBBLE_API_TOKEN=

# Slack (Copie do seu projeto do Slack a URL do webhook o 'Bot User OAuth Token' e o 'Signing Secret')
SLACK_WEBHOOK_URL=
SLACK_TOKEN=
SIGNING_SECRET=

# Enrichment (Copie do seu projeto do ABSTRACT a API KEY acesse e crei seu projeto em https://app.abstractapi.com/)
ABSTRACT_API_KEY=

# Embeddings (RAG) (Copie do seu projeto da VOYAGE a API KEY acesse e crei seu projeto em https://www.voyageai.com/)
VOYAGE_API_KEY=

# LLM do Agente (OpenRouter) (Copie a sua API KEY do Openrouter ou de outro chat model caso queira trocar acesse em https://openrouter.ai/)
OPENROUTER_API_KEY=

# Redis (Insira as variáveis do REDIS, caso ainda não tenham sido preenchidas)
QUEUE_BULL_REDIS_HOST=127.0.0.1
QUEUE_BULL_REDIS_PORT=6379
QUEUE_BULL_REDIS_PASSWORD=

# Override protegido de owner (Fluxo A) (Crie a variável de OWNER_OVERRIDE_KEY que será inserida no header da requisição para autorizar a atualização de um owner fugindo à regra comum)
OWNER_OVERRIDE_KEY=troque-esta-chave

# Segurança do webhook de ingestão (Crie as variáveis de autorização a serem inseridas nos webhooks dos fluxos)
N8N_INGEST_HEADER_NAME=x-api-key
N8N_INGEST_HEADER_VALUE=troque-este-token

# Conveniência para testes na variável do postman
N8N_BASE=http://localhost:5678 ou pode ser como exemplo:N8N_BASE=https://seu-n8n/webhook-test (caso esteja em teste) ou https://seu-n8n/webhook (caso esteja em produção)
```

> Os fluxos já referenciam essas variáveis pelos nós HTTP/Credentials. Se preferir nomes diferentes, ajuste as credenciais no n8n após importar.

---

## 2) Supabase — criar tabela, índices e RPCs

1. No Supabase **SQL Editor**, rode o arquivo `supabase_schema.sql` deste pacote. Ele cria:
   - Extensões `pg_trgm`, `unaccent` e `vector`.
   - Tabela `public.lead_v` com colunas condizentes com o fluxo e os **campos de enrichment**;
   - Índices para fuzzy search e vetor (cosine);
   - Trigger `updated_at`;
   - **RPCs usados pelos fluxos**:
     - `rpc_search_leads_by_name` — usado no Admin para busca por nome (fuzzy);
     - `search_lead_by_email` — busca por e‑mail (fuzzy);
     - `count_leads_by_country`, `count_leads_by_source`, `contar_por_periodo` — agregações;
     - `search_notes_semantic_voy` — RAG (pgvector) sobre `notes`.
2. (Opcional p/ o teste) Desative RLS da tabela `lead_v` para simplificar, ou crie políticas permissivas. Em produção, mantenha RLS e use `SUPABASE_SERVICE_ROLE` apenas nos RPCs/ações sensíveis.

### Campos previstos (Supabase)

Core: `lead_id`, `email`, `full_name`, `country_iso2`, `source`, `utm_campaign`, `owner`, `notes`, `created_at`, `updated_at`  
AI/enrichment: `embedding_voy`, `notes_hash`, `enriched`, `enriched_at`, `enrichment (jsonb)`, `email_status`, `company_domain`, `company_name`, `linkedin_url`, `phone_e164`, `city`

> **Importante:** `linkedin_url` e parte dos demais (ex.: `company_domain`/`company_name`) **só serão preenchidos se o enrichment retornar**. No fluxo atual, enriquecimento é **leve** (e-mail reputation + sugestão de domínio) — portanto é esperado que `linkedin_url` permaneça **nulo** até você plugar um provider que traga isso.

---

## 3) Bubble — Data Type `lead_v` (espelho simplificado)

Crie no Bubble um **Data Type** `lead_v` com os campos (tipos indicados):

- `lead_id` (text) — chave de negócio;
- `full_name` (text), `email` (text), `country_iso2` (text), `source` (text), `utm_campaign` (text);
- `owner` (text), `notes` (text);
- `phone_e164` (text);
- `created_at` (date), `enriched` (yes/no), `enriched_at` (date);
- `company_domain` (text), `company_name` (text), `email_status` (text);
- (opcional) `city` (text).

> Diferenças **Supabase × Bubble**: Bubble **não** armazena os campos de IA (`embedding_voy`, `notes_hash`, `enrichment jsonb`, `linkedin_url`). Isso é esperado e está documentado no desafio — a persistência dupla guarda apenas o essencial no Bubble.

Habilite **Data API** no app, gere um **API Token** e guarde a **base URL** (ex.: `https://<app>.bubbleapps.io/version-test`).

---

## 4) Importar os fluxos no n8n

1. Abra **n8n → Workflows → Import from file** e selecione(importe em workflows diferentes):
   - `Fluxo A) Pipeline de Leads.json`
   - `Fluxo B) Agente Admin.json`
2. Em **Credentials**, verifique/atualize:
   - **Supabase**(insira em qualquer nó oficial do Supabase que aparecer)
	1.Crie a credencial
	2.Em Host insira: {{$env.SUPABASE_URL}}
	3.Em Service Role Secret insira: {{$env.SUPABASE_SERVICE_ROLE}}
	4.Salve a credencial
   - **Bubble** (insira em qualquer nó oficial do Bubble que aparecer, presente apenas no Fluxo de Agente Admin);
	1.Crie a credencial
	2.Em API Token insira: {{$env.BUBBLE_API_TOKEN}}
	3.Em App Name insira o nome do seu app Bubble presente na URL
   - **Redis**(insira em qualquer nó oficial do Redis que aparecer, presente apenas no Fluxo de Agente Admin);;
	1.Crie a credencial
	2.Em Password insira: {{$env.QUEUE_BULL_REDIS_PASSWORD}}
	3.Em Host insira: {{$env.QUEUE_BULL_REDIS_HOST}}
	4.Em Port insira: {{$env.QUEUE_BULL_REDIS_PORT}}
   - **Slack** (Insira no nó 'Send a message' presente no segundo fluxo);
	1.Crie a credencial
	2.Selecione em Connect using: Access Token
	3.Em Access Token insira: {{$env.SLACK_TOKEN}}
	4.Em Signature Secret insira: {{$env.SIGNING_SECRET}}
   - **Abstract API** e **Voyage AI** não têm nós oficiais, apenas HTTP requests, portanto as variáveis já vêm no fluxo;
   - **Header Auth** para os Webhooks dos fluxos(faça o mesmo processo em ambos os fluxos):
	1.clique no nó do Webhook
	2.Crie a credencial em Credential for Header Auth
	2.Em Name insira: {{$env.N8N_INGEST_HEADER_NAME}}
	4.Em Value insira: {{$env.N8N_INGEST_HEADER_VALUE}}
   - **OpenRouter**(no nó de chat model OpenRouter Chat Model)
	1.Crie a credencial
	2.Em API Key insira: {{$env.OPENROUTER_API_KEY}}
> **Endereços dos webhooks**: após ativar os workflows, o n8n mostra a URL pública.  
> - Fluxo B (Admin): o caminho do webhook é **`/admin-agent`**  
> - Fluxo A (Pipeline): o caminho depende do seu nó Webhook; verifique no editor e use essa URL nos testes.

---

## 5) Testes com a coleção Postman

> - 5.1 Importar e preparar o ambiente do Postman

> - Importe o arquivo postman_collection.json. no Postman

> - Em Variables altere:

	> - N8N_BASE → ex.: http://localhost:5678

	> - LEADS_WEBHOOK → URL exata do webhook do Fluxo A (copie do n8n após ativar o workflow).

	> - N8N_INGEST_HEADER_NAME → x-api-key (ou como tiver salvo no n8n)

	> - N8N_INGEST_HEADER_VALUE → o mesmo valor que você colocou no .env do n8n

> - Selecione o Environment no canto superior direito do Postman.

	Dica: se mudar a URL do n8n ou o webhook, só ajuste as variáveis do Environment — a coleção continua igual.

> - 5.2 Requests incluídos (ordem sugerida)

Na coleção importada você verá estes itens:

# Leads — Ingest
> - Envia um lead para o webhook do Pipeline (Fluxo A).

Esperado: 200 com mensagem de sucesso; upsert em Supabase; atualização correspondente no Bubble; notificação no Slack.

Variações:

> - Envie o mesmo lead_id duas vezes para testar dedupe (esperar “duplicado” sem criar novo).

> - Remova um campo essencial (ex.: email) para ver o erro de validação (esperar 4xx).

> - Adicione o header x-owner-override-key: {{OWNER_OVERRIDE_KEY}} (valor real do .env) e um owner no body para testar o override protegido, confira um item com owner no seed.

# Admin — Buscar por nome
POST {{N8N_BASE}}/webhook/admin-agent com {"mensagem":"buscar pessoa maria limit 5"}.

Esperado: lista de leads compatível + coorte salva no Redis (TTL 1800s).

# Admin — Contar por país
{"mensagem":"contar por país"}.

Esperado: agregação por country_iso2 (não grava coorte).

# Admin — Consulta semântica
{"mensagem":"notas sobre <termo>"} (ex.: “cobrança” ou “proposta”).

Esperado: top-matches por similaridade (não grava coorte).

# Admin — Preparar atualização de owner
{"mensagem":"trocar o dono para owner_us@company.com"}.

Esperado: resposta de resumo/pending com quantidade afetada (o conjunto vem da última coorte ativa, criada por Buscar por nome).

# Admin — Confirmar
{"mensagem":"confirmar"}.

Esperado: atualização em Supabase e Bubble com totais de sucesso/falha; pending limpo.

Para cancelar ao invés de confirmar: {"mensagem":"cancelar"} (deve limpar o pending e responder “cancelado”).

# Apêndice A — Bateria de testes (checklist do avaliador)

Use os requests acima. Siga a ordem e marque cada item.

A.1 Pipeline (Fluxo A)

 Lead válido: enviar um lead novo → 200, persistência dupla (Supabase+Bubble), Slack notificado.

 Dedupe: reenviar mesmo lead_id → não cria duplicata; resposta deixa claro que é duplicado (o teu fluxo faz upsert; o avaliador pode verificar que não houve nova linha).

 Validação: enviar sem email ou full_name → 4xx com mensagem clara.

 Override protegido: com header x-owner-override-key correto + owner no body → owner final deve refletir o override; sem header ou com chave incorreta → prevalece regra por país.

 Enrichment leve: enviar lead com email realista → campos como email_status, company_domain/company_name podem preencher; linkedin_url pode ficar nulo (documentado).

 Embeddings de notas: enviar/atualizar notes → embedding_voy gravado; ao atualizar com notes diferentes → notes_hash muda e recalcula.

 Segurança: enviar sem {{N8N_INGEST_HEADER_NAME}} ou com valor errado → 401/403.

A.2 Agente Admin (Fluxo B)

 Busca por nome: “buscar pessoa <nome> limit 5” → resultados (fuzzy) + coorte salva (ver próximos passos A.3).

 Busca por e-mail: “buscar e-mail <endereço>” → resultados (fuzzy) + coorte salva.

 Contagens: “contar por período 01-01-2024..03-01-2024”, “contar por país”, “contar por origem” → respostas formatadas sem mexer em coorte.

 RAG em notas: “notas sobre <tema>” → top matches por similaridade.

 Atualização com confirmação:

faça uma busca por nome para criar a coorte;

“trocar o dono para owner_us@company.com
” → mostra resumo/pending;

“confirmar” → atualiza em Supabase e Bubble;

faça uma leitura direta no Supabase/Bubble para ver os owners trocados.

 Cancelar: crie um pending e mande “cancelar” → pending limpo, nenhum update aplicado.

 Coorte: use os comandos do teu fluxo para visualizar/limpar a coorte; conferir TTL ~1800s.

A.3 Conferências pontuais

 Supabase: tabela lead_v com embedding_voy vector(1024); índices criados; RPCs acessíveis.

 Bubble: Data Type lead_v com os campos listados (sem os de IA).

 Redis: chaves cohort:default:admin (TTL 1800s) e pending:default:admin (TTL 600s) durante os testes.

 Slack: mensagens chegando no canal configurado.

Observações rápidas (troubleshooting)

Se mudar o modelo de embedding, ajuste a dimensão do vector(...) e das funções RPC (vector(1024) no caso).

Erros no Slack de escopo/permissão: confirme se está usando Incoming Webhook (fluxo do pipeline) ou OAuth com chat:write (fluxo admin) conforme o seu README — e preencha as credenciais certas no nó correspondente.


---

## 6) Como cada fluxo funciona

### Fluxo A — Pipeline de Leads
- **Webhook** recebe o payload.
- **Normalize + Validate**: padroniza e valida campos essenciais; normaliza `email`, `country_iso2` e **telefone** (`phone_e164`).
- **Dedup**: consulta Supabase e Bubble; marca duplicado; faz **upsert** (evita duplicatas).
- **Routing de owner** por país, com **override protegido** via header `x-owner-override-key` = `OWNER_OVERRIDE_KEY` (se ausente, ignora override do payload).
- **Enrichment leve**: reputação de e‑mail (Abstract) e sugestão de domínio/empresa; não bloqueia o fluxo se falhar, escolha enriquecer ou não o fluxo manualmente em Config (inline): do_enrich.
- **Persistência dupla**: Supabase (REST) e Bubble (Data API).  
- **Embeddings de notas**: se `notes` não vazio, calcula `embedding_voy` (Voyage) e grava; usa `notes_hash` para evitar recálculo desnecessário.
- **Notificação** em Slack com resumo do lead.

### Fluxo B — Agente Admin
- **Entrada**: `POST /admin-agent` com body `{"mensagem":"..."}`.
- **AI Agent (OpenRouter)**: traduz linguagem natural para *intent + params* (JSON estrito).
- **Buscas**:
  - Por **nome** → `rpc_search_leads_by_name` (fuzzy, tolerante a acento/caixa);
  - Por **e‑mail** → `search_lead_by_email` (fuzzy).
- **Coorte (Redis)**: salva o conjunto encontrado em `cohort:default:admin` com **TTL 1800s**; comandos de **ver** e **limpar** também existem.
- **Contagens**: `contar_por_periodo`, `count_leads_by_country`, `count_leads_by_source` — com respostas já formatadas(essas contagens não salvam leads no Redis!).
- **RAG em notas**: gera embedding da consulta (Voyage), chama `search_notes_semantic_voy`, formata o resultado.(o resultado do RAG também não salva leads no Redis!)
- **Ações com confirmação**:
  - `preparar_atualizacao_owner` cria um **pending** em `pending:default:admin` (TTL 600s) com preview da quantidade;
  - `confirmar_atualizacao_owner` aplica **update em lote** (Supabase + Bubble) e responde com totais;
  - `cancelar_update` limpa o pending e responde claramente.
- **Mensagens de erro** amigáveis para casos sem resultado, pending vazio, etc.

---

## 7) Observações de conformidade solicitadas no desafio

- **Coorte com TTL**: `cohort:default:admin` (1800s), `pending:default:admin` (600s).
- **Busca semântica & difusa**: via `search_notes_semantic_voy` (pgvector) e RPCs fuzzy de nome/e‑mail.
- **Persistência dupla** e **notificação** estão implementadas.
- **Campos de enrichment** (ex.: `linkedin_url`) podem ficar nulos até que um provider os preencha — comportamento esperado e documentado aqui.
- **Sem SQL livre**: consultas via RPCs; parâmetros são validados/normalizados nos nós “Prep/Validate”.

---

## 8) Próximos passos sugeridos (não necessários para validar a entrega)

- Adicionar paginação/cursor real nos RPCs do Admin.
- Expandir enrichment para preencher `linkedin_url` (ex.: Clearbit Enrichment).
- RLS endurecida no Supabase para produção e separação mais rígida do uso de `SERVICE_ROLE`.
