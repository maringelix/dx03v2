# Runbook do dx03v2

Passo a passo para desenvolver e testar o app localmente (npm, compose, kind) e para publicá-lo no
cluster GKE Autopilot do tx03v2. O caminho local é grátis e `verificado localmente`; o deploy no
Google Cloud nunca foi executado (`não executado em nuvem (v2)`): você será a primeira evidência.

## 1. Pré-requisitos locais

- Docker e o devcontainer (`.devcontainer/devcontainer.json`, com Docker-in-Docker), ou Linux/WSL 2
  com Docker, bash >= 4.4, Node.js 24 (`.nvmrc`), curl, unzip, xz, git e make.
- `make tools` instala trivy, hadolint, actionlint, shellcheck, kubeconform, gitleaks, kind e kubectl
  fixados em `.tools/`.
- Portas locais: 8080 (compose, `WEB_PORT`, só 127.0.0.1), 15432 (PostgreSQL de desenvolvimento, só
  127.0.0.1), 5173 (Vite, só 127.0.0.1) e 3000/9464 (API em desenvolvimento, todas as interfaces).

## 2. Desenvolvimento com npm workspaces

Um único `package-lock.json` na raiz; os workspaces são `api` e `web`.

```bash
npm ci
# PostgreSQL 17 descartável em 127.0.0.1:15432, senha e token aleatórios só nesta sessão do shell
export DB_PASSWORD="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
export ADMIN_TOKEN="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
docker run -d --rm --name dx03v2-dev-pg -p 127.0.0.1:15432:5432 \
  -e POSTGRES_DB=dx03v2 -e POSTGRES_USER=dx03v2 -e POSTGRES_PASSWORD="$DB_PASSWORD" \
  postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24
export DB_HOST=127.0.0.1 DB_PORT=15432 DB_NAME=dx03v2 DB_USER=dx03v2
node api/src/migrate.ts            # migrações (o Node.js 24 executa TypeScript direto)
npm run dev --workspace api        # API na porta 3000, métricas na 9464, recarrega ao salvar
npm run dev --workspace web        # outro terminal: Vite em http://127.0.0.1:5173 (/api → :3000)
docker rm -f dx03v2-dev-pg         # ao terminar
```

Comandos úteis: `npm run lint`, `npm run typecheck`, `npm run format`, `npm run build`; testes:
`npm run test:coverage --workspace web` e, para a API, que usa o banco de `DB_*` e **apaga e recria
as tabelas**, um banco cujo nome termina em `_test` (os testes recusam qualquer outro nome):

```bash
docker exec dx03v2-dev-pg createdb -U dx03v2 dx03v2_test
DB_NAME=dx03v2_test npm run test:coverage --workspace api
```

O gate completo é `HARNESS_STRICT=1 make verify`: sem `DB_HOST` ele sobe um PostgreSQL descartável;
com `DB_*` exportadas, usa esse banco e recusa um `DB_NAME` que não termine em `_test` (neste shell:
`env -u DB_HOST HARNESS_STRICT=1 make verify`).

## 3. Stack do compose (projeto `dx03v2-dev`)

```bash
scripts/dev-env.sh                                  # .env com DB_PASSWORD e ADMIN_TOKEN aleatórios (600)
docker compose -p dx03v2-dev up -d --build --wait   # db → migrate → api → web
scripts/compose-smoke.sh                            # e2e/smoke.mjs contra http://127.0.0.1:8080
docker compose -p dx03v2-dev down -v                # remove containers, rede e volume do banco
```

- Só o web é publicado (`127.0.0.1:${WEB_PORT:-8080}`); a API e o banco ficam em redes internas.
- Containers com root filesystem somente leitura, `cap_drop: [ALL]` e `no-new-privileges`.
- O modo admin da página aceita o `ADMIN_TOKEN` do `.env` (fica só na memória da aba).
- Trocar os segredos: `scripts/dev-env.sh --force` e depois `down -v` (o volume guarda a senha antiga).
- Outra porta: `WEB_PORT=18080 scripts/dev-env.sh --force`.

## 4. Ponta a ponta no kind (`make e2e`)

```bash
make tools
make e2e                         # cria dx03v2-e2e, testa e apaga o cluster
KEEP_CLUSTER=1 make e2e          # mantém o cluster para investigar
kind get kubeconfig --name dx03v2-e2e > /tmp/dx03v2-e2e.kubeconfig
KUBECONFIG=/tmp/dx03v2-e2e.kubeconfig kubectl -n dx03v2 get pods,svc,networkpolicy
kind delete cluster --name dx03v2-e2e
```

O script (`scripts/e2e-kind.sh`) constrói as imagens `dx03v2-api:e2e` e `dx03v2-web:e2e`, cria o
cluster a partir de `kind/kind-config.yaml` (nó v1.36.4 por digest), carrega as imagens, cria os
Secrets com valores aleatórios, aplica `deploy/k8s/overlays/local`, espera os rollouts, prova que o
namespace rejeita um pod privilegiado, roda o smoke test por um port-forward para `svc/web` e testa
as NetworkPolicies com pods descartáveis. Em caso de falha, os diagnósticos ficam em
`$TMPDIR/dx03v2-harness/e2e-diagnostics`.

## 5. Google Cloud: pré-requisitos

> **Custo**: o app roda no lab do tx03v2, que custa cerca de US$0,12 por hora em us-central1 com o
> free tier da GKE cobrindo a taxa do cluster e cerca de US$0,22 sem ele; o load balancer que o
> Gateway programa custa cerca de US$0,025 por hora mais os dados, e o Cloud Armor cerca de
> US$0,011 por hora (preços de tabela lidos em 2026-10-11, estimativas não verificadas numa fatura).
> Ver o `docs/CUSTOS.md` do tx03v2. Destrua no mesmo dia.

1. tx03v2: bootstrap, apply e plataforma concluídos (runbook do tx03v2): parâmetro
   `tx03v2-lab-contract`, endereço global `tx03v2-lab-gateway`, repositório `dx03v2` no Artifact
   Registry, External Secrets Operator com o ClusterSecretStore `gcp-secret-manager`, namespace
   `dx03v2` com a Role `dx03v2-deployer` e a RoleBinding `dx03v2-deployers`. Para deploy a partir de
   um laptop, o seu e-mail precisa estar em `app_deployer_members` do tx03v2 (o apply dá os papéis
   IAM da seção 6 e o `platform` de novo dá a RoleBinding).
2. Repositório dx03v2 com `scripts/repo-guardrails.sh` aplicado (environment `lab` com revisor
   obrigatório e só `main`; o sujeito aceito pelo Workload Identity Federation é
   `repo:<owner>/dx03v2:environment:lab`).
3. Variáveis do GitHub (seção 6).
4. Laptop: Google Cloud CLI com o componente `gke-gcloud-auth-plugin`
   (`gcloud components install gke-gcloud-auth-plugin`, ou o pacote do sistema), Docker com buildx,
   `make tools` (kubectl) e `node`, `git`, `curl`, `openssl` (o script confere todos antes de começar).

## 6. Variáveis do GitHub e papéis IAM

Settings > Secrets and variables > Actions > **Variables** (aparecem nos logs: nada privado). O
primeiro passo do workflow (`Check repository variables`) confere as três antes de tudo e aponta para
esta seção quando falta alguma. Os valores vêm do output `github_variables_dx03v2` do tx03v2.

| Variável | Exemplo | Uso |
|---|---|---|
| `GCP_PROJECT_ID` | `tx03v2-lab-example` | projeto do lab; o deploy confere que é o `project-id` do parâmetro de contrato |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/000000000000/locations/global/workloadIdentityPools/tx03v2-github/providers/github` | provider do Workload Identity Federation (`google-github-actions/auth`) |
| `GCP_DEPLOY_SERVICE_ACCOUNT` | `dx03v2-gha-deploy@tx03v2-lab-example.iam.gserviceaccount.com` | conta de serviço que o job personifica; precisa ser a `dx03v2-gha-deploy` do `GCP_PROJECT_ID` |

Papéis IAM de quem faz o deploy (o tx03v2 concede à `dx03v2-gha-deploy` e a cada membro de
`app_deployer_members`): `roles/artifactregistry.writer` no repositório `dx03v2`,
`roles/container.clusterViewer` e `roles/parametermanager.parameterAccessor` no projeto, mais a
RoleBinding `dx03v2-deployers` no namespace (`docs/CONTRATO.md`). Nada no Secret Manager.

## 7. Deploy

Actions > `deploy-gcp` > Run workflow (branch `main`) e aprove o environment `lab`. O job confere
as variáveis, instala o kubectl fixado e o buildx, faz a autenticação por Workload Identity
Federation (`google-github-actions/auth` v3.0.0), instala o gcloud 588.0.0 com o
`gke-gcloud-auth-plugin` (`setup-gcloud` v3.0.1) e roda `scripts/deploy-gcp.sh`, que:

1. confere o working tree limpo, que `GIT_SHA` é o commit do checkout e que o gcloud tem uma
   credencial ativa;
2. renderiza o parâmetro `tx03v2-lab-contract` (`gcloud parametermanager parameters versions render
   latest`), recusa qualquer conjunto de chaves diferente das 15 do contrato e confere os valores
   fixos, os formatos, o projeto, o caminho do repositório e que `db/endpoint-ip` está dentro de
   `nodes-subnet-cidr`, antes de mudar qualquer coisa;
3. gera um kubeconfig temporário pelo endpoint DNS (`gcloud container clusters get-credentials
   --dns-endpoint`), confere que o cluster serve `gateway.networking.k8s.io/v1`,
   `networking.gke.io/v1` e `external-secrets.io/v1`, a GatewayClass `gke-l7-global-external-managed`
   quando consegue lê-la, e que a identidade pode escrever cada tipo do overlay no namespace `dx03v2`
   (`kubectl auth can-i`);
4. autentica o Docker no Artifact Registry (token pelo stdin) e lista as tags: uma tag que já existe é
   reaproveitada, nunca publicada de novo;
5. constrói as imagens `linux/amd64` que faltam e publica `dx03v2/api:<sha>` e `dx03v2/web:<sha>`
   (`docker buildx build --push`);
6. cria o ConfigMap `cloudsql-ca` com o bundle da região, depois de conferir a raiz do contrato
   (SHA-256) e que todo outro certificado é uma CA emitida por ela;
7. renderiza o overlay `gcp-waf` (ou `gcp`, quando `waf/security-policy` é `none`; nesse caso apaga
   as GCPBackendPolicies antigas) com os valores do contrato e aplica com `kubectl apply -k`;
8. espera os ExternalSecrets `db-credentials` e `app-secrets`, os rollouts e o Gateway `Programmed`
   no endereço `gateway/address`, e registra as condições da HTTPRoute e das políticas;
9. roda `e2e/smoke.mjs` pelo load balancer com `SMOKE_EDGE=gke` (até 15 minutos de espera,
   `SMOKE_WAIT_SECONDS`) e escreve o resumo do job.

A partir de um laptop (working tree limpo e no commit que você quer publicar, porque a tag é o SHA):

```bash
make tools                                   # kubectl fixado
gcloud auth login
GCP_PROJECT_ID=tx03v2-lab-example scripts/deploy-gcp.sh   # o ID real do seu projeto
```

Em Apple Silicon o build `linux/amd64` roda emulado (mais lento): os nós do Autopilot são x86-64.

## 8. Conferir

```bash
export KUBECONFIG=/tmp/dx03v2-lab.kubeconfig
gcloud container clusters get-credentials tx03v2-lab --location us-central1 \
  --project "$GCP_PROJECT_ID" --dns-endpoint
kubectl -n dx03v2 get pods,gateway,httproute,externalsecrets,hpa
kubectl -n dx03v2 get healthcheckpolicies.networking.gke.io,gcpbackendpolicies.networking.gke.io
curl -fsS "http://$(kubectl -n dx03v2 get gateway dx03v2 -o jsonpath='{.status.addresses[0].value}')/api/info"
```

Com o WAF, uma requisição com padrão de SQL injection deve receber 403 do Cloud Armor (ver o runbook
do tx03v2).

Traces (contrato v2): depois de algumas requisições, o serviço `dx03v2-api` aparece no Trace Explorer
do projeto. O caminho é API → `opentelemetry-collector.observability` (OTLP/HTTP, porta 4318) → Cloud
Trace; o Collector e a concessão `roles/cloudtrace.agent` são do tx03v2.

## 9. Desligar

O teardown é o destroy do tx03v2 (workflow de destroy + checagem de sobras): o
`platform/uninstall.sh` dele apaga o namespace `dx03v2` primeiro e espera o finalizer do Gateway e o
sumiço dos NEGs, para o load balancer criado pelo Gateway não vazar, e depois o Terraform remove o
cluster, o Cloud SQL, o Artifact Registry e o resto. Para tirar só a entrada do app e manter o
cluster: `kubectl -n dx03v2 delete gateway dx03v2` (o endereço reservado continua do tx03v2 e é
cobrado enquanto não estiver preso a uma forwarding rule).

## 10. Problemas comuns

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| `Repository variable problem: ...` | variável ausente ou com outro formato | seção 6 |
| `the working tree has uncommitted changes` / `GIT_SHA must be the checked-out commit` | build a partir de um estado que não é o commit | faça commit ou `git stash`; rode no commit que quer publicar |
| `gcloud has no active credential` | sem `gcloud auth login` (laptop) ou sem o passo de autenticação | `gcloud auth login`; no workflow, confira as variáveis |
| `cannot render tx03v2-lab-contract` | tx03v2 não aplicado, projeto errado ou sem `roles/parametermanager.parameterAccessor` | aplique o tx03v2 ou corrija `GCP_PROJECT_ID`; papéis da seção 6 |
| `the contract keys differ from docs/CONTRATO.md` / `contract key ... expect ...` | o tx03v2 publica outra versão do contrato | compare os dois `docs/CONTRATO.md`; mudança de contrato exige PRs coordenados |
| `contract key project-id is not GCP_PROJECT_ID` | o parâmetro é de outro projeto | corrija `GCP_PROJECT_ID` |
| `cannot fetch the credentials of tx03v2-lab` | sem `roles/container.clusterViewer` ou cluster ausente | papéis da seção 6; confira o apply do tx03v2 |
| `the cluster does not serve ...` | camada de plataforma do tx03v2 não instalada (ESO) ou Gateway API desligada | rode o workflow `platform` do tx03v2 |
| `this identity cannot deploy to namespace dx03v2 (...)` | sem RoleBinding `dx03v2-deployers` para este e-mail, ou regra faltando na Role | confira a plataforma do tx03v2 e `app_deployer_members`; os plurais da Role são `healthcheckpolicies` e `gcpbackendpolicies` (`docs/CONTRATO.md`) |
| `docker login to ... failed` / push recusado | sem `roles/artifactregistry.writer` no repositório `dx03v2` | papéis da seção 6 |
| `refusing https://storage.googleapis.com/cloudsql-ca-bundles/...` | o bundle tem outra raiz, duas raízes ou um certificado não emitido pela raiz do contrato | pare: confira a documentação de CAs do Cloud SQL; mudar a raiz é mudança de contrato |
| ExternalSecret não fica `Ready` | ClusterSecretStore, identidade do ESO ou segredo ausente | `kubectl -n dx03v2 describe externalsecret db-credentials`; confira a plataforma do tx03v2 |
| initContainer `migrate` falha com erro de TLS | ConfigMap `cloudsql-ca` ausente, ou `host` do segredo não é o nome DNS da instância | o script recria o ConfigMap; confira o `host` em `tx03v2-lab-db-app` e a zona DNS privada do tx03v2 |
| `the Gateway was not programmed in 15 minutes` | GatewayClass, endereço `tx03v2-lab-gateway` ausente ou política do Cloud Armor inexistente | `kubectl -n dx03v2 describe gateway dx03v2` (eventos do controlador) |
| `the programmed Gateway is not on the contract address` | o endereço reservado mudou depois do contrato | reaplique o tx03v2 (o parâmetro acompanha o endereço) |
| Smoke com 502 ou tempo esgotado logo depois do `Programmed` | load balancer ainda propagando, ou health checks falhando | espere; `kubectl -n dx03v2 describe healthcheckpolicies.networking.gke.io`; NetworkPolicies das faixas do load balancer |
| Smoke com 403 em tudo | regra do Cloud Armor | logs do Cloud Armor no tx03v2; nenhuma regra pode bloquear o smoke (contrato) |
| `ImagePullBackOff` | conta de serviço dos nós sem leitura no repositório `dx03v2` | o tx03v2 concede esse papel no apply (contrato); confira o apply |
| Nenhum trace no Cloud Trace | Collector ausente (plataforma antiga do tx03v2, contrato v1) ou sem `roles/cloudtrace.agent` | `kubectl -n observability get pods`; logs do Collector (`kubectl -n observability logs deployment/opentelemetry-collector`); a API nunca falha por isso: os spans só se perdem |

## 11. Registro

Abra uma issue com o template **Cloud run report**: data, região, commits do dx03v2/tx03v2, versão da
GKE, passos, duração, custo observado, saída do smoke test, problemas e a saída (redigida) da
checagem de sobras do tx03v2.
