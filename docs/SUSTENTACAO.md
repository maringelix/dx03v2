# Sustentação do dx03v2

Como manter o repositório saudável sem conta na nuvem: rotinas, calendário de fim de suporte e
procedimentos passo a passo. Datas e versões verificadas em 2026-10-11 e 2026-10-12.

## 1. Objetivo e escopo

Cobre o código do app (API, página, migrações), as dependências npm, as imagens base, os manifests,
os schemas dos CRDs, os scripts e workflows, as ferramentas do harness, a paridade com o `dx01v2` e o
`dx02v2` e as rodadas opcionais em nuvem. A infraestrutura (GKE Autopilot, Cloud SQL, Cloud Armor,
Secret Manager, Parameter Manager, Artifact Registry, Workload Identity Federation, camada de
plataforma) é do `tx03v2`, com a sustentação descrita lá.

## 2. Estado atual

- Estágios `static`, `test`, `build` e `e2e` `verificado no CI` (jobs `static`, `test`, `images` e
  `e2e`) e localmente em containers Linux (`HARNESS_STRICT=1`).
- Deploy no Google Cloud: `não executado em nuvem (v2)`; `scripts/deploy-gcp.sh` foi exercitado só
  com `gcloud`/`kubectl`/`docker` simulados (13 cenários, `docs/HARNESS.md`).
- Contrato com o tx03v2: versão 1 (`docs/CONTRATO.md`), espelho da parte do app do
  `docs/CONTRATO.md` do tx03v2.
- App: o do `dx02v2` (que é o do `dx01v2` no commit `22e69c4`), com as diferenças da seção 5.11.
  O caso do `X-Forwarded-For` do load balancer do Google Cloud (`TRUST_PROXY_HOPS=2`) no teste de
  integração `rate-limit` começou aqui e já está no dx01v2 e no dx02v2.
- Exceções de scanner: nenhuma (`.trivyignore.yaml` vazio).

## 3. Rotinas

| Quando | O quê | Como |
|---|---|---|
| Semanal (automático) | CI agendado (segunda 06:00 UTC) roda todos os jobs, inclusive o trivy das imagens e o `crd-schemas` | Falhou? Seção 6. Causas típicas: CVE novo numa imagem base ou dependência, URL que mudou, rede |
| Mensal | PRs do Dependabot (npm, Docker, actions, pre-commit) | Playbook "Dependency updater" do `AGENTS.md`; um PR por grupo, CI verde antes do merge; o mesmo bump no dx01v2 e no dx02v2 |
| Trimestral | Ferramentas do harness, digests das imagens (PostgreSQL, kind, devcontainer), versões de plataforma (Node.js, nginx, Kubernetes/GKE), versão da Gateway API servida pela GKE, schemas do kubeconform, gcloud e as actions do Google, raiz da CA do Cloud SQL, ignores perto de vencer, **paridade com o dx01v2 e o dx02v2** | Seções 4 e 5; registre no CHANGELOG |
| Por rodada em nuvem: antes | Ler o custo (README e `docs/CUSTOS.md` do tx03v2), CI verde no commit, tx03v2 aplicado e com a plataforma instalada, variáveis do GitHub | `docs/RUNBOOK.md` |
| Por rodada em nuvem: durante | Anotar horários, saída do smoke test e problemas; não deixar a rodada aberta de um dia para o outro | `docs/RUNBOOK.md` |
| Por rodada em nuvem: depois | destroy do tx03v2, checagem de sobras limpa, issue `cloud_run_report`, matriz de status só com evidência | `docs/RUNBOOK.md`, seção 7 |

## 4. Calendário de fim de suporte

| Componente | Versão | Fim do suporte | Fonte | Ação |
|---|---|---|---|---|
| Node.js | 24 (`.nvmrc`; imagens com 24.21.0) | 2028-04-30 | [calendário do Node.js](https://github.com/nodejs/Release#release-schedule) | Migrar para o 26 (seção 5.3) com folga, depois de ele virar LTS, junto com o dx01v2 e o dx02v2 |
| Node.js | 26 | LTS a partir de 2026-10-28; fim em 2029-04-30 | idem | Candidato na primeira revisão trimestral depois de 2026-10-28 |
| TypeScript | 6.0.3 | sem data publicada | [typescript-eslint: versões suportadas](https://typescript-eslint.io/users/dependency-versions) | Manter dentro de `>=4.8.4 <6.1.0` (typescript-eslint 8.71); o `dependabot.yml` ignora minors e majors do `typescript` |
| React / Vite / Vitest | 19.3 / 8.3 / 5.0 | sem calendário publicado | react.dev, vite.dev, vitest.dev | Majors chegam como PRs individuais do Dependabot; ler o guia de migração |
| Express | 5.3 | linha 5.x ativa | [política de suporte do Express](https://expressjs.com/en/support/) | Acompanhar pelo Dependabot |
| PostgreSQL | 17 (`postgres:17-alpine`, imagem com 17.11; Cloud SQL 17 no tx03v2) | 2029-11-08 (comunidade) | [versionamento do PostgreSQL](https://www.postgresql.org/support/versioning/) | A major segue o Cloud SQL do tx03v2 (contrato); trocar compose, CI, kind e harness juntos |
| nginx (web) | 1.30 estável (`nginxinc/nginx-unprivileged:1.30.5-alpine3.24-slim`) | até a próxima estável (1.32, prevista para ~abril de 2027) | [nginx.org](https://nginx.org/en/download.html) | Mudar para a nova linha estável na revisão trimestral seguinte ao lançamento |
| Alpine (build e runtime do web) | 3.24 | ~2028-05 | [releases do Alpine](https://alpinelinux.org/releases/) | Acompanha os digests do node e do nginx-unprivileged |
| Distroless (runtime da API) | `nodejs24-debian13:nonroot` | segue o Debian 13 (segurança até ~2028-08) e o Node.js 24 | [distroless](https://github.com/GoogleContainerTools/distroless) | Não voltar para a variante `debian12` (parou no Node.js 24.14.0) |
| Kubernetes (kind, kubectl, schemas) e GKE | 1.36 (nó `v1.36.4`, kubectl 1.36.5; canal REGULAR da GKE com 1.36.4-gke.1391002, nota de 2026-10-08) | GKE 1.36: fim do suporte padrão por volta de 2027-06-30 (endoflife.date; confirme no cronograma da GKE) | [cronograma de versões da GKE](https://cloud.google.com/kubernetes-engine/docs/release-schedule), [releases do Kubernetes](https://kubernetes.io/releases/) | O canal atualiza o cluster sozinho; a minor dos schemas, do kind e do kubectl muda junto com o tx03v2 (mudança de minor é mudança de contrato), seção 5.5 |
| kind | v0.33.0 (padrão do kind: Kubernetes 1.37.0) | sem política de fim de suporte | [releases do kind](https://github.com/kubernetes-sigs/kind/releases) | Trimestral; a imagem do nó vem das notas da release, por digest |
| Gateway API servida pela GKE | v1.5.0 standard (GKE >= 1.35.2-gke.1842000, ligada por padrão no Autopilot); schemas em `deploy/k8s/schemas` | segue a versão da GKE | documentação "GatewayClass capabilities" da GKE | Quando a GKE passar a servir outra versão, seção 5.7 (junto com o tx03v2) |
| CRDs `networking.gke.io` (HealthCheckPolicy, GCPBackendPolicy) | `v1`, schemas do datreeio/CRDs-catalog `f3e4382` | segue a GKE (o Google não publica os CRDs) | [CRDs-catalog](https://github.com/datreeio/CRDs-catalog) | Trimestral: conferir se o catálogo mudou esses schemas (seção 5.7) |
| Google Cloud CLI (gcloud) | 588.0.0 (2026-10-02), com `gke-gcloud-auth-plugin` | sem política por versão; versões novas toda semana | [release notes](https://cloud.google.com/sdk/docs/release-notes) | Trimestral (seção 5.9), a mesma versão do tx03v2 |
| `google-github-actions/auth` / `setup-gcloud` | v3.0.0 (`7c6bc770dae815cd3e89ee6cdf493a5fab2cc093`) / v3.0.1 (`aa5489c8933f4cc7a4f7d45035b3b1440c9c10db`) | sem data publicada | [auth](https://github.com/google-github-actions/auth/releases), [setup-gcloud](https://github.com/google-github-actions/setup-gcloud/releases) | Dependabot de actions; o `policy-workflows` exige essas tags: um bump muda o harness junto (seção 5.8) |
| Raiz da CA do Cloud SQL (contrato) | `CN=Google Cloud SQL Root Server CA 0b29df` (ECDSA P-384, SHA-256 `C7B0FCD2...3E59BE`) | válida até 2049-06-27 | `https://storage.googleapis.com/cloudsql-ca-bundles/<region>.pem` | Trimestral (seção 5.10); trocar a raiz é mudança de contrato; as subordinadas giram sem aviso e não são fixadas |
| Runners e devcontainer | Ubuntu 24.04 LTS (runners), Debian 13 (`javascript-node:24-trixie`) | Ubuntu 24.04: 2029-04 | ubuntu.com, debian.org | Trocar antes do fim |
| Exceções do trivy | nenhuma | — | `.trivyignore.yaml` | Seção 5.12 quando houver |

## 5. Procedimentos

### 5.1 Ferramenta do harness (trivy, hadolint, actionlint, shellcheck, kubeconform, gitleaks, kind, kubectl)

```bash
scripts/update-tool-checksums.sh kubeconform 0.8.1   # baixa o arquivo de checksums oficial da release
make tools && HARNESS_STRICT=1 make verify build
git diff tools/                                      # versions.env + checksums.txt
```

O script lê o arquivo de checksums publicado na release exata (shellcheck não publica: o script baixa
os três artefatos e calcula o SHA256). Leia as release notes antes; para o trivy, achados novos podem
aparecer só com a ferramenta nova.

### 5.2 Dependências npm

PRs do Dependabot: confira o CI e as release notes. À mão, sempre com versão exata e o lock junto:

```bash
npm install --save-exact --workspace api express@5.3.1   # ou --workspace web, ou sem workspace (raiz)
HARNESS_STRICT=1 make verify build && make e2e
```

Restrições: `typescript` dentro da faixa do `typescript-eslint`; `@types/node` na major do Node.js de
`.nvmrc`; `@vitejs/plugin-react` compatível com a major do Vite. Um PR do Dependabot que quebra uma
dessas restrições falha no `npm ci` (ERESOLVE) e deve ser fechado com um comentário, nunca forçado
com `--legacy-peer-deps`. Faça o mesmo bump no dx01v2 e no dx02v2 (seção 5.11).

### 5.3 Major do Node.js (por exemplo 24 → 26)

1. `.nvmrc` e `engines.node` dos três `package.json` (`>=26 <27`); `@types/node` 26.
2. Imagem de build `node:26-alpine<versão>` nos dois Dockerfiles (mesmo digest) e runtime
   `gcr.io/distroless/nodejs26-debian13:nonroot` na API.
3. Devcontainer `javascript-node:26-*` por digest.
4. `HARNESS_STRICT=1 make verify build && make e2e`; o check `version-consistency` acusa o que faltar.

### 5.4 Digests de imagens

```bash
docker buildx imagetools inspect node:24-alpine3.24              # e nginxinc/nginx-unprivileged:1.30-alpine-slim
docker buildx imagetools inspect gcr.io/distroless/nodejs24-debian13:nonroot
docker buildx imagetools inspect postgres:17-alpine
docker buildx imagetools inspect mcr.microsoft.com/devcontainers/javascript-node:24-trixie
```

Use o digest do índice multiplataforma e atualize o comentário com a tag e a data. O digest do
PostgreSQL aparece em `compose.yaml`, `.github/workflows/ci.yml`,
`deploy/k8s/overlays/local/postgres.yaml` e `scripts/harness.sh` (o `version-consistency` exige o
mesmo nos quatro). Confira a versão real dentro da imagem, porque tags podem parar de ser
reconstruídas. Os digests das imagens do app são os mesmos do dx01v2 e do dx02v2: mude nos três.

### 5.5 Kubernetes, kind e GKE

1. kind: `scripts/update-tool-checksums.sh kind <versão>`; a imagem do nó (`kind/kind-config.yaml`)
   vem das notas da release, sempre com `@sha256`.
2. kubectl na mesma minor do nó: `scripts/update-tool-checksums.sh kubectl <versão>`.
3. `K8S_SCHEMA_KUBERNETES_VERSION` em `scripts/harness.sh` (e um `K8S_SCHEMA_REF` que tenha essa
   versão). O `version-consistency` exige a mesma minor no nó, no kubectl e nos schemas.
4. A minor da GKE vem do canal REGULAR do tx03v2 (contrato): mude os dois repositórios juntos.

### 5.6 Gate do trivy vermelho (imagens)

1. Leia a tabela do check `trivy-image:*` (pacote, versão instalada, versão corrigida).
2. Pacote do sistema (Alpine/Debian): atualize o digest da imagem base (5.4); se a correção ainda não
   chegou à imagem, espere a reconstrução ou troque de tag.
3. Pacote npm: atualize a dependência (5.2); se a vulnerável for transitiva, um `overrides` no
   `package.json` da raiz com versão exata, explicado no PR.
4. Sem correção aplicável e risco aceito: exceção temporária (seção 5.12 e `docs/GUARDRAILS.md`),
   nunca `--severity` mais baixo nem o gate desligado.

### 5.7 Schemas do kubeconform (catálogos, Gateway API e `networking.gke.io`)

- `K8S_SCHEMA_REF` (yannh/kubernetes-json-schema) e `CRD_SCHEMA_REF` (datreeio/CRDs-catalog, usado só
  para o `ExternalSecret`) em `scripts/harness.sh` apontam para commits fixos:
  `gh api 'repos/datreeio/CRDs-catalog/commits?path=external-secrets.io/externalsecret_v1.json&per_page=1'`.
- Gateway API e `networking.gke.io` vêm de `deploy/k8s/schemas` (`source.env`: URL, versão e SHA-256
  de cada entrada). Quando a GKE passar a servir outra versão da Gateway API ou o catálogo mudar os
  schemas da GKE:

  ```bash
  gh api 'repos/datreeio/CRDs-catalog/commits?path=networking.gke.io/gcpbackendpolicy_v1.json&per_page=1'
  scripts/update-crd-schemas.sh v1.5.0 f3e4382095909ac60000da025f323ba44d4c738a   # <gateway-api> <commit>
  HARNESS_STRICT=1 make verify              # crd-schemas, kubeconform e contract-app
  git diff deploy/k8s/schemas               # revise: mudanças de campo podem exigir ajuste nos manifests
  ```

  O script recusa o asset da Gateway API se o SHA-256 diferir do digest que o GitHub registra.
  Atualize a data em `source.env` e as linhas da seção 4. Nunca edite os `.json`.

### 5.8 Actions

Fora do Dependabot: `gh api repos/<o>/<r>/git/ref/tags/<tag>`; se `object.type == "tag"`, siga
`gh api repos/<o>/<r>/git/tags/<sha>`; use o SHA do commit com `# vX.Y.Z` e confirme que ele existe
(`gh api repos/<o>/<r>/commits/<sha>`). `google-github-actions/auth` e `setup-gcloud` têm a tag
conferida pelo `policy-workflows`: um bump delas muda o check no mesmo PR, depois de ler as notas da
release (entradas e comportamento do arquivo de credenciais).

### 5.9 gcloud

1. Versão nova nas [release notes](https://cloud.google.com/sdk/docs/release-notes); use a mesma do
   tx03v2.
2. `version:` do `setup-gcloud` em `.github/workflows/deploy-gcp.yml` (o `policy-workflows` exige uma
   versão `X.Y.Z`, nunca `latest`) e as linhas da seção 4 e do README.
3. Confira nas notas se mudou a saída de `parametermanager parameters versions render`
   (`renderedPayload`), de `artifacts packages list`/`docker tags list` ou de `container clusters
   get-credentials --dns-endpoint`, que o deploy usa.

### 5.10 Raiz da CA do Cloud SQL

```bash
curl -fsSO https://storage.googleapis.com/cloudsql-ca-bundles/us-central1.pem
awk '/BEGIN CERT/{n++} {print > ("c" n ".pem")}' us-central1.pem
for c in c*.pem; do openssl x509 -in "$c" -noout -subject -issuer -enddate -fingerprint -sha256; done
```

Esperado: exatamente uma raiz autoassinada `CN=Google Cloud SQL Root Server CA 0b29df` com o SHA-256
do contrato e subordinadas emitidas por ela. As subordinadas mudarem é normal; uma raiz nova é
mudança de contrato (PRs coordenados com o tx03v2, `CLOUDSQL_ROOT_SHA256` no deploy e no harness).

### 5.11 Paridade com o dx01v2 e o dx02v2 (trimestral e a cada mudança de app)

O app (`api/`, `web/`, `e2e/`), a `base` dos manifests e o overlay `local` têm de continuar iguais aos
do `dx02v2` (a origem direta) e, por ele, aos do `dx01v2`, a menos dos nomes. Compare com a `main`
de cada um:

```bash
ref="$(mktemp -d)"
for repo in dx02v2 dx01v2; do
  git clone --quiet "https://github.com/maringelix/$repo.git" "$ref/$repo"
  for d in api web e2e deploy/k8s/base deploy/k8s/overlays/local; do
    mkdir -p "$ref/norm-$repo/$d" && cp -R "$ref/$repo/$d/." "$ref/norm-$repo/$d/"
  done
  grep -rlIE '[dt]x0[12]v2' "$ref/norm-$repo" | xargs -r sed -i -E 's/([dt])x0[12]v2/\1x03v2/g'
  for d in api web e2e deploy/k8s/base deploy/k8s/overlays/local; do
    diff -ru -x node_modules -x dist -x coverage "$ref/norm-$repo/$d" "$d"
  done
done
rm -rf "$ref"
```

Diferenças esperadas em relação ao dx02v2 (só estas, verificadas em 2026-10-12):

- `e2e/smoke.mjs`: `SMOKE_EDGE` com `nginx` e `gke`, e a checagem do `X-Request-Id` atrás do Gateway
  (só a propriedade de segurança); compose e kind com as mesmas asserções.
- `api/Dockerfile.dockerignore` e `web/Dockerfile.dockerignore`: a exclusão de `**/gha-creds-*.json`
  (arquivo de credenciais do `google-github-actions/auth`).
- Comentários em `deploy/k8s/base/configmap.yaml`, `deploy/k8s/base/kustomization.yaml`,
  `deploy/k8s/base/networkpolicies.yaml` e `deploy/k8s/overlays/local/namespace.yaml`.

Em relação ao dx01v2: as diferenças que o `docs/SUSTENTACAO.md` do dx02v2 lista, mais estas.
Comentários em `api/` e `web/` que descrevem a borda do dx02v2 ficam como lá. Qualquer outra
diferença é deriva: porte a correção para o repositório que ficou para trás (um PR em cada) ou
registre no CHANGELOG por que ela é só do Google Cloud.

### 5.12 Revisão das exceções do trivy

Para cada entrada de `.trivyignore.yaml` perto do `expired_at`: o motivo ainda vale? Se sim, renove
por até ~7 meses com a justificativa atualizada; se não, corrija e remova a entrada.

## 6. Resposta a problemas

| Situação | Primeiros passos |
|---|---|
| CI vermelho | Leia o primeiro `FAIL` (o log do check vem logo abaixo). Corrija no código; nunca enfraqueça o check. Reproduza com `HARNESS_STRICT=1 make verify build` e `make e2e` |
| Vulnerabilidade | Gate do trivy: 5.6. Alerta do Dependabot ou advisory: atualize por PR (nos três repositórios do app). Reporte privado: `SECURITY.md` |
| Credencial exposta | Local: `scripts/dev-env.sh --force` e `docker compose -p dx03v2-dev down -v`. Google Cloud: gire o valor no Secret Manager (tx03v2), espere o ESO sincronizar (até 1 h) e `kubectl -n dx03v2 rollout restart deployment/api`. Identidade do GitHub: remova o vínculo `roles/iam.workloadIdentityUser` da `dx03v2-gha-deploy` (tx03v2). Reescrever histórico é decisão do mantenedor |
| Alerta de custo | Siga o tx03v2 (checagem de sobras, destroy); o app programa o load balancer do Gateway, que cobra enquanto existir |
| Sobras após o destroy | Runbook do tx03v2 (NEGs `k8s1-*`, forwarding rules, backend services do Gateway); registre no `cloud_run_report` |
| Download da raiz do Cloud SQL ou dos schemas recusado | Um SHA-256 diferente nunca é aceito: confira as fontes oficiais; mudar a raiz é mudança de contrato (5.10); schemas na seção 5.7 |

## 7. Registro de execuções em nuvem

Toda rodada gera uma issue com o template `cloud_run_report` (data, região, commits, versão da GKE,
passos, duração, custo observado, saída do smoke test, problemas, sobras). A matriz de status do
README só muda com essa evidência.

## 8. Responsáveis

Mantenedor: @maringelix (decisões, merges, rodadas em nuvem). Agentes de IA seguem o `AGENTS.md`.
