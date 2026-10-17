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

O deploy só aceita uma release que veio do CI de `main`; o workflow não reconstrói as imagens.

1. No Actions, rode `publish-images` a partir de `main` e informe em `ci_run_id` o ID de uma execução
   de CI bem-sucedida para o commit atual de `main`. O workflow verifica os cinco checks exigidos,
   os image IDs, os SBOMs e as attestations antes de publicar os mesmos digests no GHCR.
2. Rode `deploy-gcp` a partir de `main` e informe em `release_run_id` o ID dessa execução de
   `publish-images`. Escolha também `platform_profile` (`core` ou `full`, igual ao perfil que o tx03v2
   instalou) e `deploy_mode` (`auto`, `gitops` ou `push`): `auto` usa GitOps quando encontra a Application
   `dx03v2` e aplica o overlay direto quando ela não existe; falha de permissão ou de conexão com o Argo CD
   não é tratada como ausência e interrompe o deploy. O job `verify-release` confere novamente a execução
   de origem, os cinco checks, os hashes dos SBOMs e as attestations antes do environment `lab`.
3. Depois da aprovação de `lab`, o job valida as variáveis, baixa e verifica novamente o bundle,
   autentica com Workload Identity Federation e instala `kubectl`, `crane` e gcloud.
4. O job promove os digests verificados do GHCR para o Artifact Registry (`scripts/deploy-gcp.sh
   --promote-only`, com `crane`, sem rebuild), assina com `actions/attest` uma atestação de promoção para
   cada digest do Artifact Registry (predicado `https://github.com/maringelix/tx00v2/attestations/promoted-image/v1`)
   e confere a assinatura com `gh attestation verify` (workflow `deploy-gcp.yml`, emissor do GitHub, ref
   `main`, commit do job).
5. `scripts/deploy-gcp.sh` roda de novo: lê as 18 chaves do parâmetro de contrato, confere os digests e
   image IDs, grava os digests na revisão GitOps (ou aplica o overlay) e espera Argo CD, ExternalSecrets,
   rollouts, Gateway e smoke test. Com `full`, o overlay é `gcp-full` ou `gcp-waf-full`, o smoke test usa
   HTTPS no hostname do contrato e confere o redirect 301 do HTTP; depois do rollout o script confere que
   cada pod de `api` e `web` tem o sidecar `istio-proxy` do Cloud Service Mesh gerenciado.

O perfil `full` exige a plataforma full do tx03v2 (Cloud Service Mesh gerenciado, Kyverno com a política de
assinatura, domínio e certificado do tx03v2) e roda a partir de `main`. A verificação da release não cria
nem altera recursos cloud; apenas o job protegido `deploy` faz isso. A execução cloud da v2 continua
marcada como `não executado em nuvem`.

O script também roda de um laptop com `DEPLOY_MODE=push` para aplicar os manifests sem Argo CD. Esse
caminho ainda exige uma release verificada (`RELEASE_DIR`, `RELEASE_RUN_ID`, `GH_TOKEN`,
`GITHUB_REPOSITORY` e `GITHUB_ACTOR`) e credenciais cloud próprias; a execução é manual e faturável. No
perfil `full` use apenas digests que já tenham a atestação de promoção assinada pelo workflow em `main`
(a execução manual não cria essa assinatura). Para o fluxo normal, use os dois workflows acima.

### Exercício de malha (perfil full)

Depois do deploy, o exercício roda com dois pods avulsos no namespace `dx03v2`, com as contas de serviço
`mesh-probe` (permitida) e `mesh-intruder` (negada), a imagem da API (`kubectl -n dx03v2 get deployment
mesh-stable -o jsonpath='{.spec.template.spec.containers[0].image}'`), os rótulos
`app.kubernetes.io/name=mesh-probe` ou `mesh-intruder` e os argumentos `dist/mesh-probe.js` com
`MESH_PROBE_MODE=allowed` ou `intruder` (`MESH_PROBE_TARGET` padrão `http://mesh-demo:3000`). Com sidecar o
pod não termina sozinho: leia a saída com `kubectl logs` (`MESH_PROBE_RESULT ...` ou
`MESH_PROBE_DENIED status=403`) e apague o pod. O mesmo exercício roda no lab local (ambient) em
`make e2e-platform`, sonda `mesh`, e é o que o CI prova; na nuvem ele não foi executado.

Se os pods ficarem sem prontidão logo após o primeiro deploy do perfil `full`, olhe primeiro o
`istio-proxy`: a NetworkPolicy `mesh-sidecar-egress` libera só a 443 para endereços públicos e o
servidor de metadados, e os endereços exatos do control plane gerenciado e da Mesh CA só se conhecem
numa primeira execução (`kubectl -n dx03v2 logs <pod> -c istio-proxy`). Depois de descobrir, estreite a
regra; é a única regra do namespace que abre a 443 para fora.

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
| `crane auth login` falhou / promoção recusada | sem `roles/artifactregistry.writer` no repositório `dx03v2`, token GHCR sem `packages: read` ou release inválida | papéis da seção 6 e verificação do bundle |
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
