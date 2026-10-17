# Guardrails do dx03v2

Um guardrail é uma regra mais o mecanismo que a faz valer — automático sempre que possível. Este
documento lista as regras do repositório, onde cada uma é aplicada e o que elas não garantem.
Tipos: `bloqueante` (falha o harness/CI), `alerta` (notifica), `processo` (disciplina humana/agente).

## Regras

| ID | Regra | Por quê | Onde é aplicada | Tipo |
|---|---|---|---|---|
| SEC-01 | Nenhum segredo no repositório | repositório público; histórico é para sempre | `gitleaks` (harness, pre-commit) | bloqueante |
| SEC-02 | Sem identificadores reais: projeto só `tx03v2-lab-example` (caminhos `projects/...`, imagens do Artifact Registry, e-mails de contas de serviço, pools `*.svc.id.goog`), números de 12 dígitos só `000000000000`, e-mails `example.com`/`example.org`/`example.net` ou contas de serviço do projeto placeholder, GUIDs só `00000000-0000-0000-0000-000000000000` (mais o vetor de teste da API), IPs só privados (RFC 1918), de documentação (RFC 5737), `35.191.0.0/16`, `130.211.0.0/22` (faixas do load balancer do contrato) `169.254.20.10` (cache DNS do nó) e `169.254.7.127` (origem das sondas do kubelet no Istio ambient, lab local) | evita expor projetos, contas, pessoas e endereços | check `policy-identifiers` | bloqueante |
| SEC-03 | Credenciais locais geradas em tempo de execução com valores aleatórios (`scripts/dev-env.sh`, `scripts/e2e-kind.sh`); `.env` ignorado pelo git; `.env.example` só com placeholders; nenhum `Secret` nos manifests | nada de senha padrão copiada para todo lado | `.gitignore`, `gitleaks`, `contract-app` | bloqueante |
| SEC-04 | Google Cloud só por Workload Identity Federation (`google-github-actions/auth`, environment `lab` e sujeito imutável com os IDs do dono e do repositório); `id-token: write` só no job `deploy` do `deploy-gcp.yml` (WIF) e no job `publish` do `publish-images.yml` (attestations Sigstore), nunca no CI; nada de chave de conta (`credentials_json`, `GOOGLE_APPLICATION_CREDENTIALS`) nem inputs interpolados | sem credenciais de longa duração; publicar imagens não concede acesso cloud; um nome de conta apagado e registrado de novo não herda o lab | `policy-workflows`; `scripts/repo-guardrails.sh` confere o `sub` do environment | bloqueante |
| SEC-05 | Token de admin com 32+ caracteres, comparado em tempo constante; sem token configurado a rota responde 503 `admin_disabled` | nada de token curto nem comparação que vaza tempo | `api/src/config.ts`, testes `admin-auth`, `config`, `messages` | bloqueante |
| SEC-06 | Logs redigem `Authorization`, `Cookie` e campos `password`/`token`; o deploy mascara no GitHub Actions o projeto, a conta ativa e o e-mail da conta de serviço do contrato (o token de smoke não é lido, SEC-10); os tokens GHCR e Artifact Registry vão por stdin a um `DOCKER_CONFIG` temporário (SEC-11) | segredos e IDs não vão parar em logs públicos | `api/src/logger.ts` + teste `logger`; `contract-app` (máscaras e `crane auth login --password-stdin` no `scripts/deploy-gcp.sh`) | bloqueante / processo |
| SEC-07 | O TLS do banco no Google Cloud só confia na raiz do Cloud SQL do contrato (SHA-256) e nas CAs emitidas por ela; o bundle da região nunca é fixado; `verify-full` obrigatório com `APP_ENV=lab` | um download adulterado não vira raiz de confiança | `scripts/deploy-gcp.sh`; `contract-app` (um único SHA-256 fixado, URL do bundle); teste `config` | bloqueante |
| SEC-08 | O arquivo de credenciais do `google-github-actions/auth` (`gha-creds-*.json`) fica fora do git e de todo contexto de build das imagens, inclusive nos diretórios liberados pelos `Dockerfile.dockerignore` | a credencial do job não vai parar numa imagem nem num commit | `policy-images` (`git check-ignore`, `scripts/check-build-context.mjs`) | bloqueante |
| SEC-09 | Testes e scripts só agem no que é do lab: os testes de integração, que apagam e recriam tabelas, só aceitam um banco cujo nome termina em `_test`; o `scripts/deploy-local.sh` só faz deploy no contexto `kind-tx03v2-local` | quem faz fork roda o harness na própria máquina, onde `DB_*` e o contexto atual do kubectl podem apontar para outro trabalho | `requireTestDatabase` (`api/test/integration/helpers.ts`) + teste `test-database`; check `test:api`; `require_lab_context` (`scripts/deploy-local.sh`) | bloqueante |
| SEC-10 | O smoke test nunca manda o token de admin por HTTP puro para outra máquina: com HTTPS ou em `127.0.0.1` ele manda; senão pula só a chamada que precisa do token (o `deploy-gcp.sh` nem lê o token, porque o Gateway do lab só fala HTTP) | o load balancer do lab sem certificado é a internet | `e2e/smoke.mjs`, `scripts/deploy-gcp.sh`; `contract-app` exige `ADMIN_TOKEN=""` no deploy | bloqueante |
| SEC-11 | Os logins GHCR e Artifact Registry ficam em `DOCKER_CONFIG` temporário (`private_registry_config`); `~/.docker/config.json` não muda; `rm -rf` em `scripts/lib/k8s.sh` só com variável não vazia (`${dest:?}`, `${tmp:?}`) | os tokens dos registries são removidos ao sair e um destino vazio não apaga o que o caminho passa a ser | `policy-app` | bloqueante |
| SUP-01 | Ferramentas do harness com versão e SHA256 fixados; divergência é erro fatal | cadeia de suprimentos | `scripts/install-tools.sh`, `tools/checksums.txt` | bloqueante |
| SUP-02 | Toda action fixada por SHA de 40 caracteres com comentário `# vX.Y.Z`; `auth` v3.0.0 e `setup-gcloud` v3.0.1 exigidos no deploy; o gcloud fixado por versão (nunca `latest`) | tags podem ser movidas | `policy-workflows` | bloqueante |
| SUP-03 | Toda imagem por digest (Dockerfiles, compose, manifests, CI, kind, devcontainer e features); nada de `:latest` | erro do v1: imagens `:latest` e bases flutuantes | `policy-images` | bloqueante |
| SUP-04 | npm com versões exatas em todos os `package.json` e `package-lock.json` em sincronia | erro do v1: `npm ci` com `ERESOLVE` | `version-consistency`, `npm-ci` (`npm ci` sempre no modo estrito) | bloqueante |
| SUP-05 | trivy só via `scripts/install-tools.sh` (nunca `trivy-action`/`setup-trivy`, GHSA-69fq-xp46-6x23) | incidente de cadeia de suprimentos de março de 2026 | `policy-workflows` | bloqueante |
| SUP-06 | Imagens sem vulnerabilidades HIGH/CRITICAL com correção disponível | o que é publicado não carrega CVE conhecido e corrigível | `trivy-image:api`, `trivy-image:web` | bloqueante |
| SUP-07 | Versões coerentes entre arquivos: Node.js (`.nvmrc`, `engines`, imagem de build), digest do PostgreSQL (compose, CI, kind, harness), minor do Kubernetes (kind, kubectl, schemas) | uma atualização pela metade não passa | `version-consistency` | bloqueante |
| SUP-08 | Dependabot mensal (npm, docker, actions, pre-commit), minor+patch agrupados, majors separados | nada apodrece em silêncio | `.github/dependabot.yml` | alerta |
| SUP-09 | Schemas dos CRDs gerados de entradas fixadas por SHA-256 (asset oficial da Gateway API na versão que a GKE serve; HealthCheckPolicy e GCPBackendPolicy de um commit fixado do catálogo), nunca editados à mão | o kubeconform valida contra o que o cluster serve | `crd-schemas` (`scripts/update-crd-schemas.sh --check`) | bloqueante |
| K8S-01 | Manifests renderizados válidos com kubeconform estrito e schemas fixados (Kubernetes 1.36, Gateway API v1.5.0 standard, `networking.gke.io/v1`, `ExternalSecret`) | manifest inválido não chega ao cluster | `kubeconform` | bloqueante |
| K8S-02 | Pods conforme Pod Security `restricted`: `runAsNonRoot`, uid numérico, seccomp `RuntimeDefault`, sem escalada de privilégio, `drop: [ALL]`, `readOnlyRootFilesystem`, sem token de service account, sem `hostPath`/host namespaces, requests e limite de memória | menor privilégio; o namespace da GKE impõe `restricted` | `contract-app`; no kind, o e2e prova que um pod privilegiado é rejeitado | bloqueante |
| K8S-03 | NetworkPolicies: nega tudo (entrada e saída) e libera só DNS, web → api:3000, api → PostgreSQL:5432 (local) ou o `/32` do endpoint do Cloud SQL (Google Cloud), as duas faixas do load balancer → web:8080 e api:3000 (um `ipBlock` por faixa, sem `except`), o cache DNS do nó `169.254.20.10/32:53` e métricas só do namespace `monitoring` | um pod comprometido não alcança o banco nem o resto da VPC; erro do v1: regra sem `from` e saída para qualquer IP | `contract-app`; sondas do e2e no kind | bloqueante |
| K8S-04 | Overlays `gcp*` só com os tipos que a Role `dx03v2-deployer` pode escrever e o label `app.kubernetes.io/part-of: dx03v2` em tudo; namespace e RBAC são do tx03v2 | o deploy roda com privilégio mínimo | `contract-app`; preflight `kubectl auth can-i` do deploy | bloqueante |
| K8S-05 | `trivy config` sem achados HIGH/CRITICAL nos manifests renderizados e nos Dockerfiles | segurança da configuração | `trivy-config` | bloqueante |
| K8S-06 | Tráfego no Google Cloud só pelo Gateway `dx03v2` (classe `gke-l7-global-external-managed`, endereço do contrato, HTTP 80, uma HTTPRoute: `/api` → api:3000, `/` → web:8080) com HealthCheckPolicies `/healthz` e `/readyz` e, com o WAF, as GCPBackendPolicies do Cloud Armor nos dois Services | nada fica exposto fora do contrato; um único IP público (erro do v1: três forwarding rules) | `contract-app` | bloqueante |
| APP-01 | `trust proxy` é uma contagem de saltos (`TRUST_PROXY_HOPS`: 1 local, 2 no Google Cloud), nunca `true`; o rate limit usa `req.ip` | `X-Forwarded-For` falso não fura o limite | `policy-app`; teste `rate-limit` (inclui o formato do load balancer do Google Cloud); `contract-app` (`TRUST_PROXY_HOPS=2`); smoke (429 com XFF falso diferente a cada requisição) | bloqueante |
| APP-02 | Sem middleware de CORS (mesma origem) e sem escapar HTML antes de gravar; a UI renderiza texto como texto | CORS fixo é erro comum dos v1 | `policy-app`; testes de integração e smoke (texto com `<b>` volta igual) | bloqueante |
| APP-03 | UI sem estilos nem scripts inline (CSP `script-src 'self'; style-src 'self'`) e sem sourcemaps publicados | erros dos v1: `unsafe-inline` e sourcemap público | `policy-app`; smoke; `image-policy:web` | bloqueante |
| APP-04 | Cabeçalhos de segurança em toda resposta do nginx, inclusive assets e erros; HSTS só para requisições HTTPS; `server_tokens off` | erro dos v1: HSTS com preload em HTTP | `policy-app`; smoke | bloqueante |
| APP-05 | Erros sempre em JSON `{"error":{"code","message","requestId"}}`, sem detalhes internos: 400, 413, 404, 415, 429, 500, 503 | erro dos v1: tudo virava 500 | testes de integração; smoke | bloqueante |
| APP-06 | A API loga só pelo pino (JSON, com request ID em cada linha) | logs estruturados e redigidos | `policy-app` (nada de `console.*`); eslint `no-console` | bloqueante |
| APP-07 | O token de admin fica só em memória no navegador | nada de credencial em `localStorage`/cookie | `policy-app` | bloqueante |
| APP-08 | Imagem da API distroless, sem shell nem npm/npx/corepack; as duas imagens com uid:gid numérico não root e labels OCI `source`/`revision` | menor superfície de ataque | `policy-images`, `image-policy:api`, `image-policy:web`, `hadolint` | bloqueante |
| APP-09 | Cobertura mínima: API linhas >= 80 % e branches >= 70 %; web linhas >= 70 %; os testes exercitam o código real | erro dos v1: `expect(true).toBe(true)` | limites do vitest (`test:api`, `test:web`) | bloqueante |
| APP-10 | Migrações aplicadas nunca são editadas (checksum em `schema_migrations`); uma por transação, sob advisory lock | réplicas e initContainers concorrentes não corrompem o schema | `api/src/migrate.ts`; teste `migrations` | bloqueante |
| APP-11 | Contrato com o tx03v2 versionado; mudanças em PRs coordenados nos dois repositórios | os dois lados evoluem juntos | `docs/CONTRATO.md`, `contract-app` | processo |
| APP-12 | O app é o mesmo do dx01v2 e do dx02v2: mudanças em `api/`, `web/` e `e2e/` vão para os três repositórios | a comparação entre nuvens continua justa | template de PR; rotina de paridade (`docs/SUSTENTACAO.md`) | processo |
| APP-13 | Nada dos caminhos das outras nuvens volta (arquivos, manifests, workflows, scripts, docs); só README, ARQUITETURA e CHANGELOG comparam a família | o repositório descreve só o que faz | `policy-cloud`; `contract-app` (manifests renderizados) | bloqueante |
| CUSTO-01 | Deploy só por `workflow_dispatch`, sem inputs, e environment `lab` (revisor obrigatório); o workflow usa GitOps e `contents: write` fica só no job de deploy | intenção explícita e push limitado ao job de deploy | `policy-workflows`, `scripts/publish-gitops.sh` | bloqueante |
| CUSTO-02 | Rodada em nuvem termina no mesmo dia com o destroy do tx03v2 + checagem de sobras e um relatório `cloud_run_report` | o cluster, o Cloud SQL e o load balancer com o Cloud Armor cobram por hora | `docs/RUNBOOK.md` | processo |
| CUSTO-03 | O deploy promove o digest assinado sem rebuild, reutiliza a tag SHA só quando o conteúdo coincide e recusa substituição; falha no preflight se contrato, plataforma ou RBAC não estiverem prontos | nenhuma imagem trocada nem build pago à toa | `scripts/deploy-gcp.sh`; `contract-app` (somente `crane copy`, sem `docker build`/`docker push`, sem `:latest`) | bloqueante (no deploy) |
| CI-01 | O CI é o harness: as checagens vivem em `scripts/harness.sh` e os jobs só chamam `make <alvo>`; o deploy roda o mesmo `scripts/deploy-gcp.sh` de um laptop | o que passa local passa no CI | revisão de PR; `ci.yml`; `policy-workflows` | processo |
| CI-02 | Sem `continue-on-error: true`, `\|\| true`, `\|\| echo` em workflows | gates honestos | `policy-workflows` | bloqueante |
| CI-03 | `permissions: contents: read` no topo; só deploy pode elevar para `contents: write`; `id-token: write` só no deploy e na publicação de imagens para WIF/attestations; `timeout-minutes`, `concurrency`, `ubuntu-24.04`, `persist-credentials: false` | menor privilégio e previsibilidade | `policy-workflows` | bloqueante |
| CI-04 | `HARNESS_STRICT=1` no CI: todo SKIP vira FAIL e as versões das ferramentas precisam bater; o CI não usa segredos | nada é pulado em silêncio | `ci.yml`, `scripts/harness.sh` | bloqueante |
| CI-05 | O job `e2e` testa exatamente as imagens que o job `images` construiu e escaneou (artefato) | o que vai para o cluster é o que passou no trivy | `ci.yml` | processo |
| CI-06 | CI semanal agendado (segunda 06:00 UTC) | detecta CVEs novos, ignores vencidos e URLs quebradas | `ci.yml` | alerta |
| MUD-01 | `main` protegido por ruleset: PR obrigatório, checks `static`, `test`, `images` e `e2e` estritos, sem force-push | toda mudança passa pelo harness | `.github/rulesets/main.json` + `scripts/repo-guardrails.sh` | bloqueante (depois de publicado) |
| MUD-02 | Ignore de scanner só com `statement` e `expired_at` em até ~7 meses | exceções revisadas | `trivyignore-policy` | bloqueante |
| MUD-03 | Conventional Commits; um assunto por PR; CHANGELOG `[Unreleased]` atualizado | histórico legível | template de PR | processo |
| DOC-01 | README e docs só afirmam o que é verificado, com os rótulos exatos; sem auto-elogios; texto UTF-8 com LF | erro do v1: status escrito antes da evidência | `repo-structure` (rótulos, auto-elogios, tamanho do README, LF, UTF-8 sem BOM); revisão | bloqueante |
| DOC-02 | Docs atualizadas na mesma mudança do código | docs não envelhecem | template de PR | processo |
| AGT-01 | Agentes de IA nunca executam ações que alteram a nuvem sem pedido humano explícito na tarefa | dinheiro e segurança | `AGENTS.md` | processo |
| AGT-02 | Agentes não enfraquecem gates, não baixam cobertura e não adicionam ignores sem justificativa e validade | o harness só vale se for respeitado | `AGENTS.md`; checks acima | processo |
| AGT-03 | Agentes param e perguntam nos casos listados em `AGENTS.md` | decisões caras são humanas | `AGENTS.md` | processo |
| LOC-01 | No lab local o app entra só pelo GitOps (Argo CD, AppProject `dx03v2`); o deploy não aplica manifests do app direto no cluster | um único dono do namespace (v1 tinha dois) | `scripts/deploy-local.sh`; sonda `gitops` | bloqueante (job `e2e-platform`) |
| LOC-02 | No lab local: mTLS `STRICT`, `AuthorizationPolicy` por identidade e NetworkPolicies com HBONE e as sondas do kubelet do ambient | zero trust com identidade, não só por IP | `contract-app` (`local-platform`); sonda `mesh` | bloqueante |
| LOC-03 | Toda regra de alerta usa uma série que o app ou o kube-state-metrics exporta e tem teste no promtool | v1 pagava Prometheus e Alertmanager sem alerta provado | `promtool-rules`; sonda `observability` | bloqueante |

## Exceções

Uma exceção é um ignore de scanner. Para adicionar uma:

1. Confirme que o achado é uma escolha deliberada do lab ou que não há como corrigi-lo agora (não um
   defeito a corrigir).
2. Adicione a entrada em `.trivyignore.yaml` com `id`, `paths` ou `purls` (o mais restrito possível),
   `statement` (por que é aceitável e o que compensa o risco) e `expired_at` em até ~7 meses.
3. Explique a exceção no PR. O check `trivyignore-policy` rejeita entradas sem justificativa, sem
   validade, vencidas ou longas demais; o trivy deixa de aplicar uma entrada vencida.

As outras exclusões são fixas e explicadas no próprio check: o `policy-identifiers` não examina
`package-lock.json`, `tools/checksums.txt` e `deploy/k8s/schemas` (hashes e exemplos dos CRDs
oficiais, garantidos pelo `crd-schemas`) e aceita um UUID de teste da API; o `policy-cloud` deixa
README, ARQUITETURA e CHANGELOG nomearem as outras nuvens, porque comparam a família, e não procura
os termos da nuvem do dx02v2 em `api/` e `web/`, que seguem aquele repositório (alguns comentários
descrevem a borda dele).

Exceções atuais do trivy (verificado em 2026-10-12): nenhuma. O gate das imagens usa
`--ignore-unfixed`: vulnerabilidades sem correção publicada e as de severidade LOW/MEDIUM não falham o
build; o harness imprime a contagem completa no resumo de `trivy-image:*` para acompanhamento.

## Limites (o que NÃO é garantido)

- Nada do v2 rodou no Google Cloud: o deploy, os ExternalSecrets com o Secret Manager, o Gateway e o
  load balancer, o Cloud Armor, o TLS com o Cloud SQL (`verify-full`) e o preflight de RBAC foram
  renderizados, validados e exercitados com `gcloud`/`kubectl`/`docker` simulados, não contra a nuvem.
- O e2e prova o enforcement de NetworkPolicy com o kindnet do kind (kube-network-policies), não com o
  Dataplane V2 da GKE; as regras por endereço (faixas do load balancer, endpoint do Cloud SQL, cache
  DNS do nó) só existem nos overlays `gcp*`.
- As faixas `35.191.0.0/16` e `130.211.0.0/22` são de todos os Google Front Ends, não só do load
  balancer deste lab: a NetworkPolicy limita a origem ao Google, não ao Gateway.
- O rate limit de escrita fica em memória por réplica da API: com N réplicas o limite efetivo chega a
  N vezes o configurado.
- O token de admin é um segredo único e compartilhado (sem usuários, sem rotação automática); trocar o
  valor no Secret Manager exige reiniciar os pods da API depois da sincronização do ESO.
- O smoke test pelo load balancer lê o token de admin do Secret `app-secrets` (o deployer pode ler
  Secrets) e o mascara nos logs do GitHub Actions; quem pode disparar o deploy pode ver o token.
- Os plurais RBAC `healthcheckpolicies` e `gcpbackendpolicies` e a semântica do status das políticas
  da GKE não foram vistos num cluster; o preflight do deploy acusaria a divergência.
- `trivy --ignore-unfixed` não bloqueia CVEs sem correção; o agendamento semanal os reavalia.
- No Google Cloud só o perfil full serve HTTPS (certificado gerenciado do Certificate Map do tx03v2, HTTP
  responde 301); o perfil core continua só em HTTP e, sem execução na nuvem, a emissão do certificado não
  foi exercitada. Localmente o TLS vem do lab do tx03v2 (cert-manager e CA do lab).
- Antes do primeiro commit, o `gitleaks` examina só os arquivos visíveis ao git (versionados e não
  ignorados); depois, todo o histórico.
- O bit executável dos scripts só é checado para arquivos já no índice do git.

## Como verificar

```bash
make tools                  # ferramentas fixadas em .tools/
HARNESS_STRICT=1 make verify
HARNESS_STRICT=1 make build
make e2e
scripts/harness.sh list     # todos os checks e estágios
```
