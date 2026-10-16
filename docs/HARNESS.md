# Harness do dx03v2

O harness é o conjunto de checks que prova o que este repositório afirma, sem conta na nuvem.
Ele vive em `scripts/harness.sh`; o `Makefile` e o CI só o chamam. O que passa localmente com
`HARNESS_STRICT=1` passa no CI (jobs `static`, `test`, `images` e `e2e`: `verificado no CI`) e
localmente em containers Linux.

## Camadas

| Camada | Comando | O que prova | O que NÃO prova | Onde roda |
|---|---|---|---|---|
| Ferramentas | `make tools` | binários nas versões de `tools/versions.env` (trivy, hadolint, actionlint, shellcheck, kubeconform, gitleaks, kind, kubectl, promtool), SHA256 conferido | — | local, CI |
| Versões | `tool-versions`, `version-consistency` | PATH com as versões fixadas (estrito); Node.js, PostgreSQL e Kubernetes coerentes entre arquivos; versões npm exatas | — | local, CI |
| Estrutura e honestidade | `repo-structure` | arquivos obrigatórios, rótulos de status, LF, UTF-8 sem BOM (nada de UTF-16), README <= 250 linhas, bit executável dos scripts no índice do git | que a documentação está certa | local, CI |
| Políticas | `policy-identifiers`, `policy-workflows`, `policy-images`, `policy-app`, `policy-cloud`, `trivyignore-policy` | só identificadores placeholder (`tx03v2-lab-example`, `000000000000`, e-mails de exemplo, GUID zerado) e só endereços privados, de documentação, as duas faixas do load balancer e o cache DNS do nó; actions e imagens fixadas; workflow de deploy só manual, Workload Identity Federation sem chaves, `auth` e `setup-gcloud` fixados, gcloud com versão, `gke-gcloud-auth-plugin`, kubectl do `install-tools.sh`; `gha-creds-*.json` fora do git e de todo contexto de build; regressões do v1 (trust proxy, CORS, estilos inline, HSTS, `console.*`); nada dos caminhos das outras nuvens; ignores com validade | intenção de quem escreveu | local, CI |
| Dependências | `npm-ci` | `package-lock.json` em sincronia com os três `package.json` (no modo estrito sempre roda `npm ci`) | que as dependências são seguras (ver trivy) | local, CI |
| Lint, formato e tipos | `eslint`, `prettier`, `typecheck:api`, `typecheck:web` | regras type-aware do typescript-eslint, React hooks, formatação, TypeScript estrito | comportamento | local, CI |
| Dockerfiles, workflows e scripts | `hadolint`, `actionlint` (com shellcheck), `shellcheck` | boas práticas de Dockerfile, YAML e bash corretos (nível style) | comportamento contra a nuvem | local, CI |
| Schemas dos CRDs | `crd-schemas` | `deploy/k8s/schemas` é exatamente o que `scripts/update-crd-schemas.sh` gera das entradas de `source.env` (asset `standard-install.yaml` da Gateway API v1.5.0 e os dois schemas `networking.gke.io` do catálogo no commit `f3e4382`, SHA-256 conferido em cada download) | que a GKE serve a mesma versão no cluster do tx03v2 | local, CI (rede) |
| Manifests | `kubeconform`, `contract-app`, `promtool-rules`, `trivy-config` | overlays `local`, `gcp`, `gcp-waf` e `local-platform` renderizados e válidos (estrito, Kubernetes 1.36, Gateway API v1.5.0 standard, `networking.gke.io/v1`, `ExternalSecret`); asserções do contrato e de hardening (`scripts/check-manifests.mjs`); 10 parâmetros ruins recusados por `k8s_validate_params`; no `scripts/deploy-gcp.sh`: as 15 chaves, o nome do parâmetro, os valores fixos (iguais aos de `externalsecrets.yaml` e `params.example.env`), um único SHA-256 fixado (a raiz do Cloud SQL), a URL do bundle, os dois overlays e a limpeza das GCPBackendPolicies, `--dns-endpoint`, token pelo stdin, máscaras, `gcloud` só nas chamadas de leitura permitidas, nada de `docker push`/`--password`/`:latest`; sem HIGH/CRITICAL de configuração | admission e comportamento no cluster (ver e2e), o controlador de Gateway de verdade | local, CI (rede) |
| Segredos | `gitleaks` | nenhum segredo conhecido (histórico completo quando há commits) | segredos fora dos padrões do gitleaks | local, CI |
| Testes da API | `test:api` | unitários e de integração com supertest contra o app real e um PostgreSQL 17 real: migrações idempotentes, fluxos de criar/listar/apagar, 400/401/404/413/415/429/503, XFF falso não fura o limite (formatos do nginx, sem espaço e `<cliente>,<load balancer>` com dois saltos), readyz 200/503, recuperação do banco, desligamento gracioso; cobertura >= 80 % linhas e >= 70 % branches | TLS com o Cloud SQL, várias réplicas | local, CI (Docker ou `DB_*`) |
| Testes da página | `test:web` | lista, envio com sucesso e erro, validação, modo admin (fetch simulado), cobertura >= 70 % linhas | navegador real, CSP aplicada pelo navegador | local, CI |
| Build | `npm-build`, `image:*`, `image-policy:*` | `tsc` e `vite build`; as duas imagens; usuário numérico não root, labels OCI, sem npm/npx/corepack nem shell no runtime da API, nenhum sourcemap no web | comportamento em runtime (ver e2e) | local, CI (Docker) |
| Vulnerabilidades das imagens | `trivy-image:*` | nenhuma HIGH/CRITICAL com correção disponível | CVEs sem correção, zero-days | local, CI (Docker, rede) |
| Ponta a ponta | `kind-e2e` (`scripts/e2e-kind.sh`) | cluster kind 1.36: rollouts com initContainer de migração, Pod Security `restricted` imposto, smoke test pelo nginx (cabeçalhos, API, 201/400/401/204/404/413/429, XFF falso, request ID) e sondas de NetworkPolicy (permitido/bloqueado) | GKE Autopilot, Gateway e load balancer, Cloud Armor, ESO, Secret Manager, Cloud SQL, Dataplane V2 | local, CI (Docker) |
| Nuvem | workflow deploy-gcp e `contract-app` | render dos overlays e dos patches da Application validados localmente; sync real continua sem execução | GKE e smoke na nuvem | `não executado em nuvem (v2)` |

O smoke do compose (`scripts/compose-smoke.sh`) usa o mesmo `e2e/smoke.mjs`, mas roda à mão (fora
do CI): ver `docs/RUNBOOK.md`.

## Teste offline do deploy (procedimento local, não é um check)

Antes do primeiro push, o `scripts/deploy-gcp.sh` foi exercitado de ponta a ponta sem nuvem, num
container Linux: uma cópia temporária do repositório com um commit descartável, `gcloud`, `kubectl`
(o `kubectl kustomize` é o binário real), `docker` e o `node` da chamada do smoke substituídos por
stubs no PATH que registram cada chamada, e `curl`/`openssl` reais (download real do bundle
`us-central1.pem`: raiz + 3 subordinadas conferidas). 13 cenários, todos com o resultado esperado:

- passam (saída 0): `gcp-waf` com a política do Cloud Armor (27 objetos renderizados) e `none`
  (overlay `gcp`, 25 objetos, e o `delete` das GCPBackendPolicies);
- recusados antes de qualquer escrita: chave a mais, chave faltando, projeto diferente, faixas do
  load balancer alargadas, `db/endpoint-ip` fora da subnet dos nós, Gateway programado noutro
  endereço, RBAC negada, bundle com duas raízes, raiz errada, subordinada estranha e working tree
  sujo (este sem nenhuma chamada externa).

O smoke em si não rodou (o stub do `node` só registra a chamada com `SMOKE_EDGE=gke`). Para repetir:
copie o repositório para um diretório temporário, faça um commit descartável, ponha stubs que
devolvam um parâmetro de contrato de exemplo (os valores de `params.example.env`) e respostas `yes`
do `kubectl auth can-i`, e confira a ordem das chamadas e as recusas. Nada disso vale como rodada em
nuvem.

## Jobs do CI

| Job (`ci.yml`) | Alvo | Estágio do harness |
|---|---|---|
| `static` | `make tools && make static` | `static` |
| `test` | `make test` (service `postgres:17-alpine` por digest, `DB_*` no ambiente) | `test` |
| `images` | build com buildx + cache do GitHub Actions, depois `make tools && make build` com `IMAGES_PREBUILT=1`; as duas imagens viram um artefato | `build` |
| `e2e` | carrega o artefato, `bash scripts/install-tools.sh kind kubectl`, `make e2e` com `E2E_SKIP_BUILD=1`; diagnósticos como artefato em caso de falha | `e2e` |
| `e2e-platform` | carrega o artefato, `make e2e-platform` com `E2E_SKIP_BUILD=1`: clona o tx03v2 no commit de `deploy/local/tx03v2.ref`, sobe o lab local completo, faz o deploy GitOps e roda as sondas (`docs/LAB_LOCAL.md`); log completo e diagnósticos como artefato em caso de falha | `platform` |
| `e2e-platform-small` | carrega o artefato, `make e2e-platform-small` com `E2E_SKIP_BUILD=1`: o mesmo e2e com `LOCAL_SIZE=small` dentro de um Docker-in-Docker limitado a 7 GB, sem swap; picos de memória e OOM kills no resumo do job; diagnósticos como artefato. Não é check exigido | `platform-small` |

Os ids `static`, `test`, `images`, `e2e` e `e2e-platform` são estáveis: são os checks exigidos pelo
ruleset (`.github/rulesets/main.json`; o `e2e-platform` entrou em 2026-10-13); o check `policy-workflows`
impede que mudem sem querer. Checks novos: `promtool-rules` (estático: `promtool check rules` e `promtool test rules`
das regras de alerta do overlay `local-platform`), `platform-e2e` (estágio `platform`) e
`platform-small-e2e` (estágio `platform-small`, que nunca entra no `all`: é pesado e foi feito para o
runner do CI).

## Modo estrito

`HARNESS_STRICT=1` (definido no CI e no devcontainer) transforma todo `SKIP` em `FAIL`, exige que as
versões no PATH sejam as de `tools/versions.env` e sempre roda `npm ci`. Sem ele, um check só pode
dar `SKIP` quando falta um pré-requisito local (ferramenta não instalada, Docker parado) e sempre
imprime o motivo.

Outras variáveis:

| Variável | Efeito |
|---|---|
| `HARNESS_VERBOSE=1` | mostra a saída dos checks que passam |
| `HARNESS_ONLY=<regex>` | roda só os checks cujo nome casa (depuração local; o CI nunca usa), por exemplo `HARNESS_ONLY='^eslint$' scripts/harness.sh static` |
| `HARNESS_WORK_DIR` | logs, manifests renderizados e caches (padrão `$TMPDIR/dx03v2-harness`) |
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | banco dos testes de integração; sem `DB_HOST`, o harness sobe um `postgres:17-alpine` descartável (porta aleatória em 127.0.0.1) e o remove no fim; com `DB_HOST`, o `DB_NAME` tem de terminar em `_test` (os testes apagam e recriam as tabelas) |
| `IMAGE_TAG` | tag das imagens construídas e escaneadas (padrão `e2e`, a que o overlay `local` usa) |
| `IMAGES_PREBUILT=1` | o estágio `build` confere imagens construídas por fora (CI) em vez de construí-las |
| `E2E_SKIP_BUILD=1`, `KEEP_CLUSTER=1`, `E2E_DIAGNOSTICS_DIR`, `E2E_KIND_INTERNAL=1` | ver o cabeçalho de `scripts/e2e-kind.sh` |

## Como adicionar um check

1. Escreva uma função `check_<nome>` em `scripts/harness.sh` que retorna 0 (PASS) ou não-zero (FAIL);
   use `need <ferramenta>`, `need_docker` ou `skip "<motivo>"` só para pré-requisitos ausentes;
   `summary "<texto>"` imprime uma linha de resultado mesmo quando o check passa.
2. Registre-a em `register_checks` no estágio certo (`static`, `test`, `build` ou `e2e`).
3. Rode `scripts/harness.sh list` e `HARNESS_STRICT=1 make verify` (e o estágio do check).
4. Atualize esta tabela, `docs/GUARDRAILS.md` (se for um guardrail) e o CHANGELOG.

Ferramenta nova: adicione-a a `scripts/lib/tools.sh` (URLs oficiais), a `tools/versions.env` e rode
`scripts/update-tool-checksums.sh <ferramenta> <versão>`.

## Windows e macOS

- Windows: use o devcontainer (`.devcontainer/devcontainer.json`: Node.js 24 + Docker-in-Docker,
  imagem e feature fixadas por digest) ou WSL 2 com Ubuntu. Git Bash não é suportado (as ferramentas
  são binários Linux/macOS).
- macOS (Apple Silicon): `brew install bash` (o bash 3.2 do sistema não serve; o harness exige
  bash >= 4.4) ou o devcontainer. Plataformas suportadas pelo `install-tools.sh`: linux_amd64,
  linux_arm64, darwin_arm64.
- Container avulso com o Docker do host (como a verificação local deste repositório): a imagem do
  devcontainer (`mcr.microsoft.com/devcontainers/javascript-node:24-trixie`, por digest) com o cliente
  Docker e os plugins buildx e compose copiados da imagem oficial `docker:29-cli`, o repositório em
  `/work`, o socket do Docker e volumes nomeados para `node_modules`, `.tools` e `dist` (fora de
  pastas sincronizadas como OneDrive; a cobertura já vai para `HARNESS_WORK_DIR`):
  ```bash
  docker run --rm -e HARNESS_STRICT=1 -v "$PWD:/work" -w /work \
    -v dx03v2-nm-root:/work/node_modules -v dx03v2-nm-api:/work/api/node_modules \
    -v dx03v2-nm-web:/work/web/node_modules -v dx03v2-tools:/work/.tools \
    -v dx03v2-out-api-dist:/work/api/dist -v dx03v2-out-web-dist:/work/web/dist \
    -v dx03v2-npm-cache:/root/.npm -v /var/run/docker.sock:/var/run/docker.sock \
    --network <rede com o PostgreSQL> -e DB_HOST=<container do PostgreSQL> -e DB_NAME=dx03v2_test \
    -e DB_USER=... -e DB_PASSWORD <imagem acima> bash -c "make tools && make verify build"
  ```
  Dentro de um container, o PostgreSQL descartável do harness e o `127.0.0.1` publicado pelo kind
  pertencem ao host: passe `DB_*` apontando para um PostgreSQL na mesma rede Docker e, no e2e, use
  `E2E_KIND_INTERNAL=1` (o script entra na rede `kind` e usa o endereço interno do API server).
  Adicione `-e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=*` se o
  dono dos arquivos for outro usuário. Num bind mount do Windows todo arquivo aparece como 0777: antes
  do primeiro commit, use `git -c core.fileMode=false add -A` e `git add --chmod=+x scripts/*.sh`
  (só os scripts de entrada ficam executáveis no índice; o `repo-structure` confere).

## Dados fora do repositório

O harness grava logs, relatórios de cobertura (`coverage-api`, `coverage-web`), manifests
renderizados, a árvore copiada para o gitleaks, as entradas baixadas dos schemas e os caches do trivy
e do kubeconform em `HARNESS_WORK_DIR` (padrão `$TMPDIR/dx03v2-harness`) ou em diretórios
temporários. No repositório ficam só `.tools/`, `node_modules/` e `*/dist/` (ignorados pelo git;
`*/coverage/` só aparece com `npm run test:coverage` à mão). `make clean` remove tudo isso.

## Problemas comuns

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| `SKIP tool-versions - missing tools` | `make tools` não rodou | `make tools` |
| `FAIL npm-ci` | `package-lock.json` fora de sincronia com algum `package.json` | `npm install` (gera o lock) e commit dos dois; nunca edite o lock à mão |
| `FAIL test:api` com `integration tests need DB_HOST...` | sem Docker e sem `DB_*` | inicie o Docker ou exporte `DB_*` para um PostgreSQL 17 |
| `FAIL test:api` com `DB_NAME '...' does not end in _test` | `DB_*` exportadas para outro banco (o de desenvolvimento, por exemplo) | `env -u DB_HOST make test` (o harness sobe um banco descartável) ou aponte `DB_NAME` para um banco `*_test` |
| `FAIL test:api` com `ERROR: Coverage for lines (...) does not meet` | código novo sem teste | escreva o teste; nunca baixe o limite |
| `FAIL trivy-image:*` | CVE HIGH/CRITICAL com correção nova | `docs/SUSTENTACAO.md`, seção 5.6 |
| `FAIL trivyignore-policy ... expired` | ignore venceu | revise a exceção: corrija ou renove com nova justificativa |
| `FAIL crd-schemas` | arquivo de `deploy/k8s/schemas` editado à mão, ou o gerador mudou | `scripts/update-crd-schemas.sh <versão da Gateway API> <commit do catálogo>` (os de `source.env`) e commit do resultado |
| `FAIL crd-schemas ... download failed` / SHA-256 diferente | sem rede, ou o GitHub devolveu outro conteúdo | confira a rede; um SHA-256 diferente nunca é aceito (pare e investigue) |
| `FAIL kubeconform ... could not find schema` | sem rede, ou schema do catálogo que o kubeconform não compila | confira a rede; os commits dos catálogos estão fixados em `scripts/harness.sh` |
| `FAIL contract-app` | manifest, parâmetro ou `scripts/deploy-gcp.sh` divergente do contrato v2 ou do hardening | corrija; mudança de contrato exige PR coordenado com o tx03v2 |
| `FAIL policy-workflows` | `deploy-gcp.yml` sem o passo `Check repository variables`, com outra versão do `auth`/`setup-gcloud`, sem `version:` do gcloud, ou com chave de conta de serviço | siga a mensagem; o deploy é só Workload Identity Federation |
| `FAIL policy-images ... gha-creds` | um `.dockerignore`/`Dockerfile.dockerignore` deixou o arquivo de credenciais entrar no contexto | acrescente `**/gha-creds-*.json` ao arquivo |
| `FAIL policy-cloud` | algo do caminho de outra nuvem (nome de arquivo, serviço, região) fora de README, ARQUITETURA e CHANGELOG | remova ou descreva em termos do Google Cloud |
| `FAIL kind-e2e` | rollout, smoke ou sonda falhou | leia o resumo e os diagnósticos (`E2E_DIAGNOSTICS_DIR`, artefato `e2e-diagnostics` no CI); `KEEP_CLUSTER=1 make e2e` para investigar |
| `FAIL gitleaks` | segredo ou falso positivo | remova o segredo e gire a credencial; placeholders devem ter cara de placeholder (por exemplo SHA ou GUID só com zeros). Antes do primeiro commit o check examina os arquivos visíveis ao git |
| `FAIL policy-identifiers` | projeto, número, e-mail, GUID ou IP real | use `tx03v2-lab-example`, `000000000000`, `you@example.com`, `203.0.113.10` |
