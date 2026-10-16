# API do dx03v2

Referência da API do mural de mensagens: endpoints, erros, configuração e exemplos com curl. O
comportamento descrito aqui é coberto pelos testes de `api/test` e pelo `e2e/smoke.mjs`. É a mesma
API do `dx01v2` e do `dx02v2` (só os nomes mudam; a rotina de paridade está no
`docs/SUSTENTACAO.md`).

Os exemplos usam a stack do compose (`http://127.0.0.1:8080`, a API atrás do nginx em `/api/`). Para
o `DELETE`, carregue o token do `.env` gerado por `scripts/dev-env.sh` sem imprimi-lo:

```bash
BASE=http://127.0.0.1:8080
ADMIN_TOKEN="$(sed -n 's/^ADMIN_TOKEN=//p' .env)"
```

## Endpoints

| Método e caminho | Descrição | Respostas |
|---|---|---|
| `GET /healthz` | liveness, sem dependências | 200 `{"status":"ok"}` |
| `GET /readyz` | readiness: `SELECT 1` em até 1 s e processo fora do desligamento | 200 `{"status":"ready"}`; 503 `{"status":"db_unavailable"}` ou `{"status":"shutting_down"}` |
| `GET /api/info` | identidade do build e do runtime (nunca segredos nem dados do banco) | 200 `{"name","version","commit","environment","uptimeSeconds"}` |
| `GET /api/messages?limit=N` | mensagens da mais nova para a mais antiga; `limit` inteiro de 1 a 100, padrão 20 | 200 `{"items":[{"id","author","text","createdAt"}]}`; 400 |
| `POST /api/messages` | cria uma mensagem; corpo JSON `{"author","text"}` | 201 com a mensagem e `Location`; 400, 413, 415, 429 |
| `DELETE /api/messages/:id` | apaga uma mensagem; exige `Authorization: Bearer <ADMIN_TOKEN>` | 204; 400, 401, 404; 503 `admin_disabled` sem `ADMIN_TOKEN` configurado |
| `GET /api/stats` | contagem de mensagens | 200 `{"messages":N}` |
| `GET /metrics` (porta `METRICS_PORT`, 9464) | métricas no formato OpenMetrics: padrão do Node.js + `http_request_duration_seconds{method,route,status_code}`, com o `trace_id` da requisição como exemplar quando há tracing | 200; não exposto pelo web nem pelo Gateway |

`/healthz` e `/readyz` não passam pelo nginx (`/healthz` do nginx é do próprio web): o Kubernetes
consulta a API direto no pod e, no Google Cloud, o load balancer do Gateway usa `/readyz` como
health check da API (HealthCheckPolicy `api`, porta 3000).

Regras de entrada do `POST`:

- `author`: texto, 1 a 40 caracteres depois do `trim`; `text`: 1 a 280 caracteres depois do `trim`.
- Caracteres de controle (C0, DEL, C1) são rejeitados; campos extras também (`strictObject`).
- O texto é gravado como recebido (sem escapar HTML); a página o renderiza como texto.
- Limite de escrita por cliente (`req.ip`): `RATE_LIMIT_WRITE_PER_MINUTE` (padrão 10) por minuto,
  contado antes da validação. Acima dele: 429 com `Retry-After` e os cabeçalhos `RateLimit-Policy` e
  `RateLimit` (draft 8 do IETF).

## Erros

Todo erro tem o mesmo formato, sem detalhes internos:

```json
{"error":{"code":"validation_error","message":"author: must have 1 to 40 characters","requestId":"3f1c..."}}
```

| Status | `code` | Quando |
|---|---|---|
| 400 | `validation_error` | corpo, `limit` ou `id` inválidos (resumo das falhas do zod, até 5) |
| 400 | `invalid_json` | JSON malformado |
| 400 | `bad_request` | corpo que não pôde ser lido |
| 401 | `unauthorized` | token de admin ausente ou errado (com `WWW-Authenticate: Bearer`) |
| 404 | `not_found` | rota desconhecida ou mensagem inexistente |
| 413 | `payload_too_large` | corpo acima de 10 kb (o nginx devolve o mesmo JSON acima de 64k) |
| 415 | `unsupported_media_type` | `Content-Type` diferente de `application/json` ou charset não UTF-8 |
| 429 | `rate_limited` | limite de escrita atingido |
| 500 | `internal_error` | falha inesperada (o detalhe vai só para o log) |
| 503 | `db_unavailable` | banco indisponível |
| 503 | `admin_disabled` | `DELETE` sem `ADMIN_TOKEN` configurado |
| 503 | `api_unavailable` | resposta do nginx quando a API não responde (502/503/504 do upstream) |

Cada resposta traz `X-Request-Id`: o valor recebido é reaproveitado só se casar com
`^[A-Za-z0-9-]{1,64}$`; senão a API gera um UUID. O mesmo ID aparece em todas as linhas de log da
requisição e no campo `requestId` dos erros. No Google Cloud, a documentação do Application Load
Balancer externo global não diz se ele repassa, troca ou acrescenta o `X-Request-Id` (verificado em
2026-10-11); o smoke test com `SMOKE_EDGE=gke` confere só a propriedade de segurança: um ID seguro
volta igual ou como UUID, um ID inseguro nunca volta e duas requisições nunca compartilham o ID.

## Cabeçalhos

- API: helmet com CSP `default-src 'none'; frame-ancestors 'none'`, `X-Content-Type-Options: nosniff`,
  `Cache-Control: no-store`, sem `X-Powered-By`, sem HSTS (decidido na borda), sem CORS.
- Web (nginx): CSP `default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'`,
  `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`, `Cross-Origin-Opener-Policy`,
  `Cross-Origin-Embedder-Policy: require-corp` e `Cross-Origin-Resource-Policy: same-origin` em
  toda resposta (inclusive assets e erros); HSTS só quando `X-Forwarded-Proto` é `https`.

## Configuração (variáveis de ambiente)

| Variável | Padrão | Observação |
|---|---|---|
| `APP_ENV` | `local` | `local`, `ci`, `kind` ou `lab` |
| `PORT` / `METRICS_PORT` | `3000` / `9464` | precisam ser diferentes |
| `TRUST_PROXY_HOPS` | `0` | número de proxies na frente da API: 1 no compose e no kind (o nginx), 2 atrás do Application Load Balancer do Google Cloud (Google Front End + load balancer); nunca `true` |
| `LOG_LEVEL` | `info` | `fatal`, `error`, `warn`, `info`, `debug`, `trace`, `silent` |
| `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | — | obrigatórias (Secret `db-credentials`) |
| `DB_PORT` | `5432` | |
| `DB_SSL_MODE` | `disable` | `disable`, `require` ou `verify-full`; com `APP_ENV=lab` só `verify-full` |
| `DB_SSL_CA_FILE` | — | obrigatório com `verify-full` (PEM; no Google Cloud `/etc/cloudsql-ca/ca.pem`) |
| `DB_POOL_MAX` | `10` | 1 a 100 |
| `RATE_LIMIT_WRITE_PER_MINUTE` | `10` | 1 a 10000 |
| `ADMIN_TOKEN` | — | opcional; com valor, no mínimo 32 caracteres (Secret `app-secrets`) |
| `GIT_SHA` | `unknown` | commit exibido em `/api/info` (as imagens recebem pelo build arg) |
| `SHUTDOWN_TIMEOUT_MS` | `10000` | prazo do desligamento gracioso antes da saída forçada |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | — | opcional; URL http(s) de um receptor OTLP/HTTP (o OpenTelemetry Collector da plataforma). Com valor, a API exporta os spans das requisições e das consultas (W3C `traceparent` de entrada continuado) e escreve `trace_id`/`span_id` nos logs; sem valor, nada é exportado |

Qualquer valor inválido encerra o processo na partida com a lista de problemas (sem ecoar valores).

## Exemplos com curl

```bash
curl -fsS "$BASE/api/info"
curl -fsS "$BASE/api/messages?limit=5"
curl -sS -X POST "$BASE/api/messages" -H 'Content-Type: application/json' \
  -d '{"author":"Ana","text":"Olá, <b>mural</b>!"}'                       # 201, texto gravado como enviado
curl -sS -X POST "$BASE/api/messages" -H 'Content-Type: application/json' \
  -d '{"author":"","text":"x"}'                                             # 400 validation_error
curl -sS -X POST "$BASE/api/messages" -H 'Content-Type: application/json' -d '{"author":'  # 400 invalid_json
curl -sS -o /dev/null -w '%{http_code}\n' -X DELETE "$BASE/api/messages/1"  # 401
curl -sS -o /dev/null -w '%{http_code}\n' -X DELETE "$BASE/api/messages/1" \
  -H "Authorization: Bearer $ADMIN_TOKEN"                                   # 204 (ou 404 se não existir)
curl -fsS "$BASE/api/stats"
curl -sSI "$BASE/api/info" -H 'X-Request-Id: meu-teste-123' | grep -i x-request-id
```

Rate limit com `X-Forwarded-For` falso (o limite não muda, porque `req.ip` vem do proxy confiável):

```bash
for i in $(seq 1 12); do
  curl -s -o /dev/null -w '%{http_code} ' -X POST "$BASE/api/messages" \
    -H 'Content-Type: application/json' -H "X-Forwarded-For: 198.51.100.$i" -d '{"author":"","text":""}'
done; echo   # 400 ... 400 429 429
```

Métricas (dentro da rede do compose; a porta não é publicada):

```bash
docker compose -p dx03v2-dev exec web wget -qO- http://api:9464/metrics | head
```
