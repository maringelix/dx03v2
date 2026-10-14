# Publicação do dx03v2

Checklist para tornar o repositório público com as proteções do padrão v2. Siga na ordem; cada item
tem o comando ou o lugar onde é verificado. O repositório nasce privado; rodar o
`scripts/repo-guardrails.sh` e torná-lo público só com o OK explícito do mantenedor. O tx03v2 é
publicado junto.

## Antes de publicar

- [ ] `HARNESS_STRICT=1 make verify build` e `make e2e` verdes no devcontainer ou em Linux.
- [ ] Bit executável nos scripts de entrada antes do primeiro commit (o Windows não o grava):
      `git add --chmod=+x scripts/compose-smoke.sh scripts/deploy-gcp.sh scripts/dev-env.sh scripts/e2e-kind.sh scripts/harness.sh scripts/install-tools.sh scripts/render-k8s.sh scripts/repo-guardrails.sh scripts/update-crd-schemas.sh scripts/update-tool-checksums.sh`
      (o check `repo-structure` confere o índice do git).
- [ ] Primeiro commit feito e enviado para `main` (privado) e CI verde (`static`, `test`, `images`, `e2e`).
- [ ] `gitleaks git` limpo no histórico completo (o check `gitleaks` faz isso quando há commits).
- [ ] Nenhum identificador real: `policy-identifiers` verde (projetos, números, e-mails, GUIDs, IPs) e
      uma leitura humana de `docs/`.
- [ ] Matriz de status do README conferida: `verificado localmente` só vira `verificado no CI` depois
      do primeiro CI verde, num PR (a linha do compose continua local); o deploy no Google Cloud
      continua `não executado em nuvem (v2)` até um `cloud_run_report`.
- [ ] Descrição e tópicos do repositório (`gh repo edit maringelix/dx03v2 --description ... --add-topic kubernetes`).

## Publicar

- [ ] `gh repo edit maringelix/dx03v2 --visibility public --accept-visibility-change-consequences`
- [ ] `scripts/repo-guardrails.sh maringelix/dx03v2`: alertas de vulnerabilidade, security updates do
      Dependabot, squash-only, `delete_branch_on_merge`, issues, `GITHUB_TOKEN` só leitura por padrão
      (sem aprovar PRs), ruleset `main`, secret scanning + push protection, private vulnerability
      reporting, aprovação obrigatória para workflows de PRs de forks de colaboradores externos e
      environment `lab` (revisor: quem roda o script; só `main`). Ele também falha enquanto o Actions
      estiver desligado e aponta o que um fork ainda precisa trocar (`FORK.md`). O script imprime o
      que foi aplicado, pulado, as notas e o que falhou.
- [ ] Tabelas da família nos outros cinco repositórios v2 (os da tabela do README): trocar o nome do
      dx03v2 por um link, um PR em cada.

## Ruleset `main` (`.github/rulesets/main.json`)

- Bloqueia deleção e force-push; exige PR (0 aprovações para mantenedor solo,
  `dismiss_stale_reviews_on_push`, `required_review_thread_resolution`), merge só squash.
- Checks obrigatórios (modo estrito, app GitHub Actions): `static`, `test`, `images`, `e2e` e
  `e2e-platform` (o app na plataforma local).
- Bypass: papel de admin do repositório, modo `pull_request` — **só para emergência** (por exemplo,
  um check quebrado por fator externo bloqueando uma correção de segurança). Registre o motivo no PR.

## Ids de jobs estáveis

Mudar um id quebra a proteção. Ids atuais:

| Workflow | Job | Exigido pelo ruleset |
|---|---|---|
| `ci.yml` | `static` | sim |
| `ci.yml` | `test` | sim |
| `ci.yml` | `images` | sim |
| `ci.yml` | `e2e` | sim |
| `deploy-gcp.yml` | `deploy` | não (só `workflow_dispatch`, environment `lab`; o check `policy-workflows` exige o id) |

## Depois de publicar

- [ ] CI verde em `main` público e badge funcionando; atualize a matriz (`verificado no CI`).
- [ ] Variáveis do GitHub (`GCP_PROJECT_ID`, `GCP_WORKLOAD_IDENTITY_PROVIDER`,
      `GCP_DEPLOY_SERVICE_ACCOUNT`) só depois do bootstrap e do apply do tx03v2 (`docs/RUNBOOK.md`,
      seção 6).
- [ ] Primeira rodada em nuvem registrada com `cloud_run_report`.
