# Contrato tx03v2 <-> dx03v2 — versão 2 (2026-10-14)

Versão 2: o OpenTelemetry Collector da camada de plataforma do tx03v2 recebe os traces do app. A versão
1 (2026-10-11) não tinha traces.

Interface entre a infraestrutura (`tx03v2`) e a aplicação (este repositório), na parte que o app usa.
A fonte da verdade é o
[`docs/CONTRATO.md` do tx03v2](https://github.com/maringelix/tx03v2/blob/main/docs/CONTRATO.md):
em caso de divergência, vale aquele arquivo. Qualquer mudança exige PRs coordenados nos dois
repositórios e incremento da versão.

## Como o contrato é verificado aqui

| O quê | Onde | Status |
|---|---|---|
| Nomes de Services, portas, probes, Secrets, ConfigMap, Gateway (classe, `NamedAddress`, listener), HTTPRoute (rotas), HealthCheckPolicies, GCPBackendPolicies, ExternalSecrets, HPA, NetworkPolicies (faixas do load balancer, `/32` do Cloud SQL, cache DNS do nó), `TRUST_PROXY_HOPS=2`, labels, só tipos que a Role `dx03v2-deployer` pode escrever | check `contract-app` (`scripts/check-manifests.mjs` sobre os overlays renderizados `gcp` e `gcp-waf`) | `verificado localmente` |
| Endpoint OTLP da versão 2 no ConfigMap da API e NetworkPolicy só até o Collector (namespace `observability`, porta 4318) | check `contract-app` | `verificado localmente` |
| Manifests válidos para Kubernetes 1.36, para a Gateway API v1.5.0 standard (a versão que a GKE serve), para `networking.gke.io/v1` (HealthCheckPolicy, GCPBackendPolicy) e para o CRD `ExternalSecret` (`external-secrets.io/v1`) | checks `crd-schemas` e `kubeconform` (estrito) | `verificado localmente` |
| Formatos dos parâmetros dos overlays (imagens do Artifact Registry com o SHA de 40 caracteres, nome do endereço, política do Cloud Armor ou `none`, exatamente as duas faixas do load balancer, IP RFC 1918 do endpoint do Cloud SQL); valores errados, desconhecidos ou ausentes são recusados | `k8s_validate_params` em `scripts/lib/k8s.sh`, provado por `contract-app` (10 entradas ruins recusadas) | `verificado localmente` |
| O deploy lê exatamente as 15 chaves abaixo do parâmetro `tx03v2-lab-contract`, confere os valores fixos (os mesmos nomes dos manifests), confia só na raiz do Cloud SQL do contrato, aplica `gcp-waf` ou `gcp`, usa o endpoint DNS e chama o `gcloud` só para leitura | check `contract-app` (sobre `scripts/deploy-gcp.sh`) | `verificado localmente` |
| Valores do parâmetro conferidos no cluster de verdade: projeto = `GCP_PROJECT_ID`, repositório `<region>-docker.pkg.dev/<project>/dx03v2`, `db/endpoint-ip` dentro de `nodes-subnet-cidr`, preflight de API groups e RBAC, Gateway programado no endereço `gateway/address` | `scripts/deploy-gcp.sh` falha antes de construir ou aplicar qualquer coisa (exercitado offline com CLIs simulados, `docs/HARNESS.md`) | `não executado em nuvem (v2)` |
| Comportamento real no Google Cloud | `docs/RUNBOOK.md` | `não executado em nuvem (v2)` |

## Identificadores

| Item | Valor |
|---|---|
| Projeto Google Cloud | um projeto dedicado ao lab (variável `GCP_PROJECT_ID` do GitHub neste repositório; nos exemplos `tx03v2-lab-example`, número `000000000000`) |
| Região | variável `region` do tx03v2, padrão `us-central1` (chave `region` abaixo) |
| Projeto / ambiente / prefixo | `tx03v2` / `lab` / `tx03v2-lab` |
| Cluster GKE | `tx03v2-lab`, Autopilot, regional, canal `REGULAR` (Kubernetes 1.36), nós privados, endpoint IP público desligado, endpoint DNS com autorização só pelo IAM, Gateway API (canal standard), Dataplane V2 (aplica NetworkPolicy) |
| Nós | x86-64 (classe general-purpose do Autopilot): as imagens são `linux/amd64` |
| Namespace do app | `dx03v2` — criado pela camada de plataforma do tx03v2 com os labels `pod-security.kubernetes.io/enforce=restricted` e `pod-security.kubernetes.io/enforce-version=latest`. Os overlays `gcp*` não criam o namespace; o overlay `local` cria um equivalente para o kind |
| RBAC Kubernetes do deployer | Role `dx03v2-deployer` + RoleBinding `dx03v2-deployers` no namespace `dx03v2`; sujeitos `kind: User` com o e-mail da conta de serviço `dx03v2-gha-deploy` e os e-mails de `app_deployer_members` do tx03v2 |
| Artifact Registry | repositório `dx03v2` (Docker, região do lab, tags imutáveis); imagens `<region>-docker.pkg.dev/<project_id>/dx03v2/api` e `.../web`, tag = SHA git completo (40 caracteres) do dx03v2. A conta de serviço dos nós lê o repositório |
| Conta de serviço do deploy | `dx03v2-gha-deploy@<project_id>.iam.gserviceaccount.com` (nos exemplos `dx03v2-gha-deploy@tx03v2-lab-example.iam.gserviceaccount.com`) |
| Traces (OpenTelemetry, versão 2) | `http://opentelemetry-collector.observability.svc:4318` (OTLP/HTTP; `OTEL_EXPORTER_OTLP_ENDPOINT` do componente `gcp`). O Collector é instalado pela camada de plataforma do tx03v2 e grava os spans no Cloud Trace do projeto (o ServiceAccount dele é o principal com `roles/cloudtrace.agent`); o app não recebe nenhum papel do IAM para isso |

Regras da Role `dx03v2-deployer` (namespace `dx03v2`), que limitam o que os overlays `gcp*` podem
conter (o check `contract-app` recusa qualquer outro tipo, e o deploy confere cada verbo com
`kubectl auth can-i` antes de construir):

- `apps`: deployments → get, list, watch, create, update, patch, delete; replicasets → get, list, watch
- core: services, configmaps, serviceaccounts → get, list, watch, create, update, patch, delete;
  pods, pods/log, events, endpoints → get, list, watch; secrets → get, list, watch (o ESO escreve
  os segredos; o deployer nunca os escreve)
- `networking.k8s.io`: networkpolicies → CRUD completo
- `gateway.networking.k8s.io`: gateways, httproutes → CRUD completo
- `networking.gke.io`: healthcheckpolicies, gcpbackendpolicies → CRUD completo (as
  GCPBackendPolicies são escritas pelo `gcp-waf` e apagadas pelo `gcp`, então o deploy sempre exige
  os dois)
- `autoscaling`: horizontalpodautoscalers → CRUD completo; `policy`: poddisruptionbudgets → CRUD completo
- `external-secrets.io`: externalsecrets → CRUD completo

GatewayClasses têm escopo de cluster e ficam fora da Role: o deploy confere a classe quando consegue
lê-la; senão, a condição `Programmed` do Gateway é a prova.

Com o perfil `full` do `tx03v2`, o Argo CD é o dono dos manifests do app. O deploy configura o caminho,
as imagens e os valores reais em `spec.source.kustomize` da Application `dx03v2` no namespace `argocd`;
em seguida, publica o commit do app e `params.env` copiado do exemplo na branch `gitops/gcp` e pede
refresh ao Argo CD. O app pai ignora somente `spec.source.path` e `spec.source.kustomize` dessa
Application e usa `RespectIgnoreDifferences=true`. Para um cluster sem Argo CD, selecione `push` e o
script aplica diretamente o overlay. A branch pública não recebe IDs reais da conta ou do projeto.

## Workload Identity Federation do GitHub

Pool `tx03v2-github`, provider `github` (issuer `https://token.actions.githubusercontent.com`,
condição restrita ao dono e aos repositórios `tx03v2` e `dx03v2`). A conta de serviço
`dx03v2-gha-deploy` tem `roles/iam.workloadIdentityUser` só para o sujeito exato
`repo:<owner>@<id do dono>/dx03v2@<id do repositório>:environment:lab` (o `sub` imutável do GitHub; dono e
IDs configuráveis no tx03v2: `github_owner`, `github_owner_id`, `dx03v2_repository_id`, sem padrão; um nome
de conta apagado e registrado de novo tem outros IDs e não herda o lab). O environment `lab` só implanta
a partir de `main`. Por isso o
job do `deploy-gcp.yml` usa `environment: lab` (o check `policy-workflows` exige), e o provider vira a
variável `GCP_WORKLOAD_IDENTITY_PROVIDER`
(`projects/<número>/locations/global/workloadIdentityPools/tx03v2-github/providers/github`).

Papéis de `dx03v2-gha-deploy` (concedidos pelo root do lab do tx03v2):
`roles/artifactregistry.writer` no repositório `dx03v2`; `roles/container.clusterViewer` no projeto
(credenciais do cluster e acesso pelo endpoint DNS); `roles/parametermanager.parameterAccessor` no
projeto (ler o parâmetro do contrato). Nada no Secret Manager. Acesso Kubernetes só pela RoleBinding
acima. Os `app_deployer_members` (deploy a partir de um laptop, `user:<e-mail>` ou
`serviceAccount:<e-mail>`; `group:` é recusado) recebem os mesmos três papéis e entram na RoleBinding.

## Parâmetro de contrato: Parameter Manager `tx03v2-lab-contract`

Parâmetro global com formato `JSON`, lido pelo alias `latest`:
`gcloud parametermanager parameters versions render latest --parameter=tx03v2-lab-contract
--location=global --project=<GCP_PROJECT_ID>`. Nenhum valor é segredo, mas o deploy mascara no
GitHub Actions o projeto e o e-mail da conta de serviço. O JSON tem exatamente estas 15 chaves
(valores string); o deploy recusa uma chave a mais, uma a menos ou um valor vazio:

| Chave | Valor | Uso no dx03v2 |
|---|---|---|
| `project-id` | ID do projeto do lab | conferida: igual a `GCP_PROJECT_ID` |
| `region` | região | conferida (formato); `get-credentials --location`, host do registry, bundle da CA do Cloud SQL |
| `cluster-name` | `tx03v2-lab` | conferida; `gcloud container clusters get-credentials --dns-endpoint` |
| `network-name` | `tx03v2-lab` | conferida (valor fixo) |
| `nodes-subnet-cidr` | CIDR da subnet dos nós | conferida (RFC 1918); `db/endpoint-ip` precisa estar dentro dela |
| `db/endpoint-ip` | IP interno do endpoint Private Service Connect do Cloud SQL | NetworkPolicy `api-egress-to-cloudsql`: `<ip>/32`, porta 5432 (`DB_ENDPOINT_IP`) |
| `lb-source-ranges` | `35.191.0.0/16,130.211.0.0/22` (fixo) | NetworkPolicies `web-ingress-from-lb` e `api-ingress-from-lb`, um `ipBlock` por faixa (`LB_SOURCE_RANGES`) |
| `artifact-registry/repository` | `<region>-docker.pkg.dev/<project_id>/dx03v2` | conferida contra a região e o projeto; imagens `api` e `web` (`API_IMAGE`, `WEB_IMAGE`) |
| `db/secret-name` | `tx03v2-lab-db-app` | conferida contra o ExternalSecret `db-credentials` |
| `app/admin-token-secret-name` | `tx03v2-lab-app-admin-token` | conferida contra o ExternalSecret `app-secrets` |
| `eso/cluster-secret-store` | `gcp-secret-manager` | conferida contra o `secretStoreRef` dos ExternalSecrets |
| `gateway/address-name` | `tx03v2-lab-gateway` | `spec.addresses` do Gateway, `type: NamedAddress` (`GATEWAY_ADDRESS_NAME`) |
| `gateway/address` | o IPv4 desse endereço | conferida (formato); o Gateway programado precisa ter esse endereço; URL do smoke test |
| `waf/security-policy` | `tx03v2-lab-waf`, ou `none` com `enable_waf = false` no tx03v2 | GCPBackendPolicies `api` e `web` (`WAF_SECURITY_POLICY`, overlay `gcp-waf`); com `none`, overlay `gcp` e as políticas antigas são apagadas |
| `deploy/service-account` | e-mail de `dx03v2-gha-deploy` | conferida: `dx03v2-gha-deploy@<GCP_PROJECT_ID>.iam.gserviceaccount.com` |

## Secret Manager (do tx03v2; o deploy não lê)

- `tx03v2-lab-db-app`: JSON com valores string `username`, `password`, `host`, `port`, `dbname`.
  `host` é o nome DNS da instância para Private Service Connect
  (`<uid>.<rótulo do projeto>.<region>.sql.goog`), o nome que o `verify-full` confere.
- `tx03v2-lab-app-admin-token`: string pura, 48 caracteres alfanuméricos aleatórios.
- Só o ServiceAccount `external-secrets/external-secrets` do ESO (principal do Workload Identity
  Federation for GKE) tem `roles/secretmanager.secretAccessor` nesses dois segredos.

## Camada de plataforma (instalada pelo `platform/install.sh` do tx03v2)

- External Secrets Operator 2.12.0 no namespace `external-secrets`; ClusterSecretStore
  `gcp-secret-manager` (provider `gcpsm`, sem bloco `auth`), utilizável só a partir do namespace
  `dx03v2`.
- Namespace `dx03v2`, Role e RoleBinding acima. O controlador de Gateway da GKE é gerenciado pelo
  Google (GatewayClass `gke-l7-global-external-managed`); a GKE serve a Gateway API v1.5.0 (GKE >=
  1.35.2-gke.1842000). O metrics-server da GKE atende o HPA da API.
- O `platform/uninstall.sh` do tx03v2 apaga o namespace `dx03v2` antes do destroy e espera o finalizer
  do Gateway e o sumiço dos NEGs: o load balancer que o Gateway deste repositório cria fica fora do
  state do Terraform.

## Runtime do app (dx03v2)

- Secret `db-credentials`: chaves `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`
  (Google Cloud: ExternalSecret de `tx03v2-lab-db-app`, uma propriedade JSON por chave; kind e
  compose: gerado em tempo de execução com valores aleatórios por `scripts/e2e-kind.sh` e
  `scripts/dev-env.sh`).
- Secret `app-secrets`: chave `ADMIN_TOKEN` (Google Cloud: ExternalSecret de `tx03v2-lab-app-admin-token`).
- TLS do banco no Google Cloud: `DB_SSL_MODE=verify-full`, `DB_SSL_CA_FILE=/etc/cloudsql-ca/ca.pem` a
  partir do ConfigMap `cloudsql-ca`, criado pelo deploy com o bundle público da região
  (`https://storage.googleapis.com/cloudsql-ca-bundles/<region>.pem`). O deploy **recusa** um bundle
  com blocos PEM que não sejam certificados, sem exatamente uma raiz autoassinada com o SHA-256
  abaixo, ou com um certificado que não seja CA emitida por ela (`openssl verify -x509_strict` só
  com a raiz, sem o store do sistema); o ConfigMap recebe os certificados reescritos pelo openssl.
  O arquivo nunca é fixado: as CAs subordinadas da região mudam com a rotação.

  | Raiz | SHA-256 (contrato) | SHA-1 | Validade |
  |---|---|---|---|
  | `CN=Google Cloud SQL Root Server CA 0b29df` (ECDSA P-384) | `C7B0FCD282B346F1FCC45EE8A79ECF6EF6FAEF2D669BEEC664293B93D83E59BE` | `9E0DDEC1969957360315A0B849CD609E6FC0905C` | 2049-06-27 |

  Local: `DB_SSL_MODE=disable`. Com `APP_ENV=lab` a API recusa qualquer modo diferente de `verify-full`.
- `TRUST_PROXY_HOPS=2`: o Application Load Balancer externo global acrescenta
  `<ip do cliente>,<ip do load balancer>` ao `X-Forwarded-For` e a conexão chega de um Google Front
  End (teste de integração `rate-limit`).
- Services: `api` (porta 3000 http, 9464 métricas), `web` (porta 8080).
- Tráfego (só Google Cloud): Gateway `dx03v2` (classe `gke-l7-global-external-managed`,
  `spec.addresses` com `type: NamedAddress` e o valor `gateway/address-name`), listener HTTP na porta
  80 (HTTPS `planejado`); HTTPRoute `dx03v2`: `/api` → `api:3000`, `/` → `web:8080`;
  HealthCheckPolicies `web` (`/healthz`, porta 8080) e `api` (`/readyz`, porta 3000);
  GCPBackendPolicies `api` e `web` com `securityPolicy` = `waf/security-policy` (omitidas com `none`).
- Cloud Armor (do tx03v2): regras pré-configuradas `sqli-v33-stable` e `xss-v33-stable` em
  `deny(403)`, inspeção dos primeiros 64 KB do corpo, sem bloqueio por tamanho — então o corpo de
  70 KB do smoke chega à API, que responde 413 ela mesma. Nenhuma regra pode bloquear o smoke test; um
  limite de taxa, se existir, precisa ser >= 300 requisições por minuto por cliente.
- NetworkPolicies no Google Cloud: entrada em web:8080 e api:3000 só a partir de `lb-source-ranges`;
  saída da api para `db/endpoint-ip`/32:5432; DNS (base) e saída para o cache DNS do nó
  `169.254.20.10/32:53` (NodeLocal DNSCache do Autopilot).
- Cloud SQL for PostgreSQL 17 (edição Enterprise), porta 5432, só por Private Service Connect,
  `ssl_mode = ENCRYPTED_ONLY`, `server_ca_mode = GOOGLE_MANAGED_CAS_CA`.

## Lab local (contrato local do tx03v2, versão 2)

O deploy local (scripts/deploy-local.sh, docs/LAB_LOCAL.md) lê o ConfigMap `lab-system/lab-contract`
da plataforma local do tx03v2, exige a versão `2` e recusa valores diferentes dos fixados no overlay
`local-platform`:
`registry` = `registry.tx03v2.local`, `db.secret-name` = `tx03v2-lab-db-app`,
`app.admin-token-secret-name` = `tx03v2-lab-app-admin-token` (chave `token`; no Secret Manager é uma
string pura), `eso.cluster-secret-store` = `local-secrets`, `gateway.class` = `istio`,
`tls.cluster-issuer` = `lab-ca`, `argocd.project` = `dx03v2`, `monitoring.prometheus-service-account` =
`monitoring/kube-prometheus-stack-prometheus`, `tracing.otlp-endpoint` =
`http://opentelemetry-collector.monitoring.svc:4318` (versão 2: o `OTEL_EXPORTER_OTLP_ENDPOINT` da API
e as NetworkPolicies até o Collector). Do contrato ele lê ainda `registry-push`
(`localhost:5003`), `network-cidr` (`10.252.0.0/24`), `db.endpoint-ip` (`10.252.0.11`),
`db.ca-configmap`, `gitops.push-url`, `gitops.read-url` e `gitops.push-key-secret`. O overlay só usa os
kinds que o AppProject `dx03v2` aceita (check `contract-app`). Diferenças de borda: o Gateway local
mantém um `X-Request-Id` externo (`SMOKE_EDGE=istio`) e tem um único salto de proxy
(`TRUST_PROXY_HOPS=1`, contra 2 atrás do load balancer do Google). A fonte da verdade é o
`docs/CONTRATO.md` do tx03v2.

## Mudando o contrato

1. Abra PRs nos dois repositórios, com links cruzados, e incremente a versão no título dos dois
   arquivos `docs/CONTRATO.md`.
2. Atualize os checks que cobrem o item (tabela "Como o contrato é verificado aqui"):
   `scripts/check-manifests.mjs`, `scripts/deploy-gcp.sh` (`CONTRACT_KEYS` e os valores fixos),
   `scripts/lib/k8s.sh` e `CONTRACT_PARAMETER_KEYS` em `scripts/harness.sh`.
3. Faça o merge do lado que publica (tx03v2) antes do lado que consome (este), salvo remoções
   (ao contrário).
