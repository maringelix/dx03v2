# Arquitetura do dx03v2

Como o app é montado em cada ambiente (compose, kind, GKE Autopilot), as decisões de design, o que
difere dos pares da AWS (`dx01v2`) e da Azure (`dx02v2`) e o que mudou em relação ao v1 do Google
Cloud (`dx03`). O contrato com a infraestrutura está em `docs/CONTRATO.md`; os endpoints em
`docs/API.md`.

## O app é o do dx01v2

Por decisão de projeto (2026-10-11), cada par de nuvem tem o seu repositório de aplicação, mas os
três rodam o **mesmo** app, para a comparação entre nuvens ser justa. O `dx02v2` começou como cópia
de todos os arquivos versionados do `dx01v2` no commit `22e69c4` (maringelix/dx01v2), e este
repositório começou como cópia de todos os arquivos versionados do `dx02v2`, com os nomes trocados
(`dx02v2` → `dx03v2`, `tx02v2` → `tx03v2`). Só o destino do deploy mudou: o GKE Autopilot do
`tx03v2` no lugar do AKS do `tx02v2`. A API, a página, as migrações, os testes, o smoke test, a
`base` dos manifests e o overlay `local` (kind) têm o mesmo comportamento; as diferenças estão na
tabela "dx01v2 ↔ dx02v2 ↔ dx03v2" abaixo, e a rotina trimestral que as mantém assim está em
`docs/SUSTENTACAO.md` (comparar `api/`, `web/` e `e2e/` com os outros dois e portar correções).

## Componentes

| Componente | O quê | Imagem (por digest) |
|---|---|---|
| `api` | Express 5 + TypeScript estrito (ESM) no Node.js 24: mural de mensagens, probes, métricas em porta separada | build `node:24-alpine3.24`; runtime `gcr.io/distroless/nodejs24-debian13:nonroot` (uid 65532, sem shell, sem npm) |
| `migrate` | `dist/migrate.js` na mesma imagem da API: aplica `api/migrations/*.sql` sob advisory lock | a da API |
| `web` | página React 19 (Vite 8) servida pelo nginx, que também faz proxy de `/api/` para a API | build `node:24-alpine3.24`; runtime `nginxinc/nginx-unprivileged:1.30-alpine-slim` (uid 101, porta 8080; sem os módulos image-filter/xslt/geoip/njs) |
| banco | PostgreSQL 17 | local/kind: `postgres:17-alpine`; Google Cloud: Cloud SQL for PostgreSQL 17 do tx03v2 (só Private Service Connect) |

## Local (compose, projeto `dx03v2-dev`)

```mermaid
flowchart LR
  user((Navegador)) -->|"127.0.0.1:8080"| web
  subgraph compose["projeto dx03v2-dev"]
    subgraph frontend["rede frontend"]
      web["web (nginx-unprivileged)"]
    end
    api["api (TRUST_PROXY_HOPS=1)"]
    subgraph backend["rede backend"]
      db[("db: postgres:17-alpine<br/>volume db-data")]
      migrate["migrate (dist/migrate.js)"]
    end
    web -->|"/api/ → api:3000"| api
    api --> db
    migrate --> db
  end
```

`db` (healthcheck) → `migrate` (termina com sucesso) → `api` (healthy em `/readyz`) → `web`. Só o web
é publicado, em 127.0.0.1. Todos com root filesystem somente leitura, `cap_drop: [ALL]` e
`no-new-privileges`; segredos do `.env` gerado por `scripts/dev-env.sh`.

## kind (`make e2e`)

```mermaid
flowchart LR
  smoke["e2e/smoke.mjs"] -->|"kubectl port-forward svc/web"| web
  subgraph ns["namespace dx03v2: Pod Security restricted, default deny"]
    web["Deployment web ×2"] -->|"web → api:3000"| api["Deployment api ×2<br/>initContainer migrate"]
    api -->|"api → postgres:5432"| pg[("StatefulSet postgres<br/>emptyDir, uid 70")]
    probe["pods de sonda"] -.->|"bloqueado"| api
    probe -.->|"bloqueado"| pg
  end
```

Um nó Kubernetes 1.36 (`kind/kind-config.yaml`); imagens carregadas com `kind load` e
`imagePullPolicy: Never`; Secrets aleatórios criados pelo script. O kindnet, CNI padrão do kind,
aplica NetworkPolicy desde o kind v0.24.0 (kube-network-policies), e o e2e prova isso com sondas
permitidas e bloqueadas.

## Google Cloud (GKE Autopilot do tx03v2, `não executado em nuvem (v2)`)

```mermaid
flowchart LR
  internet((Internet)) --> lb["Application Load Balancer externo global<br/>endereço tx03v2-lab-gateway + Cloud Armor (tx03v2)"]
  subgraph gke["GKE Autopilot tx03v2-lab (Dataplane V2), namespace dx03v2"]
    gw["Gateway dx03v2 + HTTPRoute<br/>(controlador de Gateway da GKE)"]
    lb -->|"/api → api:3000, NEG zonal direto no pod"| api["api ×2–4 (HPA, CPU 70 %)"]
    lb -->|"/ → web:8080"| web["web ×2"]
    web --> api
    eso["ExternalSecrets"] -->|"db-credentials, app-secrets"| api
  end
  gw -.->|"programa"| lb
  api -->|"TLS verify-full (ConfigMap cloudsql-ca)<br/>endpoint PSC /32"| sql[("Cloud SQL PostgreSQL 17")]
  sm["Secret Manager"] --> eso
  gha["deploy-gcp (Workload Identity Federation, workflow_dispatch)"] -->|"Parameter Manager, Artifact Registry + atestação de promoção, GitOps ou apply direto"| gke
```

O namespace, a RBAC do deployer, o ClusterSecretStore, o External Secrets Operator, o endereço
global reservado, a política do Cloud Armor, o Secret Manager, o Artifact Registry e o Cloud SQL
(com o endpoint PSC e a zona DNS privada) são do tx03v2; o controlador de Gateway é gerenciado pelo
Google. O app traz Gateway, HTTPRoute, HealthCheckPolicies, as GCPBackendPolicies (opcionais),
ExternalSecrets, HPA e NetworkPolicies; os valores do parâmetro de contrato (imagens, nome do
endereço, política do Cloud Armor, faixas do load balancer, IP do endpoint do Cloud SQL) entram por
um `params.env` e `replacements` do kustomize. O load balancer chega aos pods direto por NEGs zonais
(IP e porta do pod), a partir das faixas `35.191.0.0/16` e `130.211.0.0/22` dos Google Front Ends e
dos health checks — por isso as NetworkPolicies liberam essas duas faixas, e não o nó.

O perfil `full` acrescenta HTTPS no hostname do contrato (certificado gerenciado pelo Certificate Map do
tx03v2, redirect HTTP 301) e o exercício de malha nos sidecars do Cloud Service Mesh gerenciado: um
`VirtualService` divide `/variant` em 80/20 entre `mesh-stable` e `mesh-canary`, limita retries em `/fail` e
um `DestinationRule` ejeta o canário depois de três 5xx; uma `AuthorizationPolicy` aceita só a identidade
`mesh-probe` e o `mesh-intruder` recebe 403. Como o Autopilot não roda o Istio ambient, o lab local prova o
mesmo exercício na malha ambient (`components/mesh-full`, com waypoint) e a nuvem o roda em sidecars
(`components/mesh-csm`); os dois compartilham os backends (`components/mesh-demo`).

## Decisões

1. **Um processo por container.** API e web em imagens e Deployments separados; nada de nginx e Node
   no mesmo container com um trap de shell.
2. **Runtime distroless da API.** `nodejs24-debian13:nonroot`, sem shell nem npm (a variante
   `debian12` parou no Node.js 24.14.0). O healthcheck do compose é uma linha de Node
   (`/nodejs/bin/node -e fetch(...)`).
3. **nginx próprio no web.** `default.conf` com `server_tokens off`, IPv4 + IPv6, `/healthz` local,
   `/api/` com os cabeçalhos de encaminhamento padrão, fallback de SPA e cache longo para os assets
   com hash. Os cabeçalhos de segurança ficam em um snippet incluído em **cada** `location`. HSTS só
   quando `X-Forwarded-Proto` é `https`; o load balancer preenche esse cabeçalho com o protocolo que
   recebeu; no perfil core o listener do Gateway é só HTTP, então não há HSTS ali, e no perfil full a página sai por HTTPS e o `X-Forwarded-Proto` é `https`.
4. **`trust proxy` como contagem de saltos.** `TRUST_PROXY_HOPS=1` em compose e kind (o nginx) e `2`
   no Google Cloud. A documentação "External Application Load Balancer overview" (verificada em
   2026-10-11) diz que o proxy acrescenta `<ip do cliente>,<ip do load balancer>` ao que o cliente
   mandou em `X-Forwarded-For`, e a conexão chega de um Google Front End: com dois saltos
   confiáveis, `req.ip` é o cliente e entradas falsas à esquerda são ignoradas. O teste de integração
   `rate-limit` cobre esse formato (o mesmo caso está no dx01v2 e no dx02v2) e o smoke prova o 429
   com `X-Forwarded-For` falso diferente a cada requisição.
5. **Rate limit de escrita em memória.** `express-rate-limit` por `req.ip`, 10 por minuto por padrão,
   contado antes da validação. Com N réplicas o limite efetivo chega a N vezes; um store
   compartilhado (Redis) ficou de fora por custo e complexidade.
6. **Erros JSON e limites.** Todo erro sai como `{"error":{"code","message","requestId"}}`; corpo até
   10 kb na API (413), 64k no nginx; 415 para corpo que não é JSON; 503 `db_unavailable` quando o
   banco cai, sem detalhes internos.
7. **Configuração validada na partida.** Um schema zod sobre o ambiente; com `APP_ENV=lab`, só
   `DB_SSL_MODE=verify-full` com `DB_SSL_CA_FILE` é aceito. O rótulo do ambiente é `APP_ENV`, nunca
   o `NODE_ENV` (erro do v1).
8. **Banco que se recupera.** Pool `pg` preguiçoso (conexão em 3 s, `statement_timeout` 5 s);
   `/readyz` faz `SELECT 1` com limite de 1 s e volta a 200 quando o banco volta.
9. **Migrações explícitas.** Arquivos SQL numerados, uma transação por arquivo, `pg_advisory_lock` e
   checksum em `schema_migrations`. Rodam no initContainer `migrate` e no serviço `migrate` (compose).
10. **Desligamento gracioso.** SIGTERM → `/readyz` 503 → `server.close()` → `pool.end()` → flush dos
    spans pendentes (no máximo 5 s; um Collector fora do ar não transforma o desligamento em falha);
    saída forçada após `SHUTDOWN_TIMEOUT_MS` (10 s); `preStop` com a ação `sleep` de 5 s.
11. **Métricas separadas.** `/metrics` na porta 9464, no formato OpenMetrics (o exemplar leva o
    `trace_id` da requisição); nem o web nem o Gateway expõem essa porta; a NetworkPolicy só aceita o
    namespace `monitoring` (não há Prometheus neste lab).
12. **Gateway API no controlador de Gateway da GKE.** O controlador é gerenciado pelo Google (nada a
    instalar, nenhuma versão para manter) e a GKE serve a Gateway API v1.5.0 (GKE >=
    1.35.2-gke.1842000, ligada por padrão no Autopilot). A classe `gke-l7-global-external-managed`
    cria um Application Load Balancer externo global; `spec.addresses` com `type: NamedAddress`
    aponta para o endereço que o tx03v2 reserva, então o IP não muda entre deploys e o load balancer
    não vira um segundo IP público (erro do v1). A HTTPRoute manda `/api` direto para a API (o caminho
    mais longo vence na Gateway API) e `/` para o web; uma HealthCheckPolicy por Service define os
    health checks (`/healthz` na 8080, `/readyz` na 3000), que saem das mesmas faixas do tráfego.
13. **WAF como componente opcional.** `components/gcp-waf` (uma GCPBackendPolicy por Service com a
    `securityPolicy` do Cloud Armor) só entra nos overlays `gcp-waf` e `gcp-waf-full`, escolhidos pelo deploy
    quando `waf/security-policy` não é `none`; com `none`, `gcp`/`gcp-full` e o deploy apaga as políticas
    antigas, que apontariam para uma política do Cloud Armor apagada.
14. **Kustomize com componentes.** `base` neutra; `overlays/local` (kind), `gcp` e `gcp-waf` (perfil core),
    `gcp-full` e `gcp-waf-full` (core mais `gcp-https` e `mesh-csm`) e `local-platform` (malha ambient no kind do
    tx03v2). No Google Cloud o HPA controla as réplicas da API (`spec.replicas` removido). O CI renderiza
    e valida todos os overlays com `params.example.env`.
15. **Schemas dos CRDs gerados e fixados.** O kubeconform valida Gateway e HTTPRoute contra schemas
    convertidos por `scripts/update-crd-schemas.sh` do asset oficial `standard-install.yaml` da
    Gateway API v1.5.0 (SHA-256 igual ao digest que o GitHub registra), a versão que a GKE serve. A
    GKE instala os CRDs `networking.gke.io` sozinha e o Google não publica o arquivo deles, então os
    schemas de HealthCheckPolicy e GCPBackendPolicy são cópias de um commit fixado do
    datreeio/CRDs-catalog (`f3e4382`, SHA-256 conferido). O ExternalSecret continua validado pelo
    catálogo fixado no harness.
16. **Segurança de pods.** Pod Security `restricted` em todo pod, sem token de service account,
    NetworkPolicies que negam tudo e liberam só o necessário. O Autopilot sobe requests abaixo do
    mínimo dele (50m de CPU e 52 MiB por pod na classe general-purpose, documentação "Resource
    requests in Autopilot", verificada em 2026-10-12): o web pede 64Mi de memória no overlay `gcp`,
    para o que roda ser o que o manifest diz.
17. **Tags de imagem que não mudam.** No Artifact Registry, tag = SHA completo do commit, num
    repositório com tags imutáveis. O deploy lista as tags antes e reaproveita uma imagem que já
    existe, sem tentar publicá-la de novo. Localmente a tag é `e2e` (kind) ou `local` (compose).
    Promoção atestada, sem rebuild: o workflow `deploy-gcp` verifica o release e a imagem do GHCR, promove
    a mesma imagem para o Artifact Registry e assina uma atestação que liga os digests de origem e
    destino; no perfil full o Kyverno exige essa assinatura antes de admitir o pod. `platform_profile`
    seleciona `core|full`; `deploy_mode` seleciona `auto|gitops|push`.
18. **Uma credencial só: o gcloud.** No GitHub Actions o `google-github-actions/auth` grava um arquivo
    de credenciais do Workload Identity Federation (`gha-creds-*.json`, fora do git e de todo
    contexto de build, conferido pelo `policy-images`) que o gcloud renova durante o job; o kubectl
    pega tokens do gcloud pelo `gke-gcloud-auth-plugin` e o Docker recebe um token de acesso pelo
    stdin. Mesmo assim o deploy lê o contrato, gera o kubeconfig e faz o preflight de RBAC e o login
    no registry **antes** de construir as imagens, para falhar cedo, sem gastar o build, se a
    plataforma não estiver pronta.
19. **Endpoint DNS do control plane.** O cluster não tem endpoint IP público; o deploy usa
    `get-credentials --dns-endpoint` (`*.gke.goog`), em que cada requisição é autenticada e
    autorizada pelo IAM (`roles/container.clusterViewer` do contrato). Os runners não precisam de
    lista de IPs.
20. **Raiz do TLS do banco conferida.** O deploy baixa o bundle público da região, exige exatamente
    uma raiz autoassinada com o SHA-256 do contrato e só CAs emitidas por ela (`openssl verify
    -x509_strict` sem o store do sistema) e cria o ConfigMap `cloudsql-ca` com os certificados
    reescritos; o arquivo não é fixado, porque as subordinadas giram. O `verify-full` confere a cadeia
    e o nome DNS da instância (o `host` do segredo).
21. **NetworkPolicies por endereço.** Entrada só das duas faixas do load balancer (valor fixo do
    contrato, um `ipBlock` por faixa, sem `except`); saída da API só para o `/32` do endpoint PSC do
    Cloud SQL na 5432, que o deploy confere estar dentro da subnet dos nós; DNS pelo cache do nó
    `169.254.20.10`. A documentação "Setting up NodeLocal DNSCache" diz que essa regra é dispensável
    com Cloud DNS ou Dataplane V2 (os dois sempre ligados no Autopilot); ela fica explícita em vez de
    depender disso e abre só a porta 53 desse endereço.
22. **Um smoke test para todos os ambientes.** `e2e/smoke.mjs` (Node.js puro) roda contra o compose,
    o kind e o load balancer, com asserções exatas por borda: `SMOKE_EDGE=nginx` (padrão) espera a CSP
    do web em `/api` e o `X-Request-Id` ecoado; `SMOKE_EDGE=gke` espera a CSP da própria API em
    `/api` e só a propriedade de segurança do `X-Request-Id` (a documentação do load balancer não diz
    se ele repassa, troca ou acrescenta esse cabeçalho). O corpo de 70 KB recebe 413 nos dois: do
    nginx (64k) ou, atrás do Gateway, da própria API (o Cloud Armor inspeciona os primeiros 64 KB e não
    bloqueia por tamanho).
23. **Traces com OpenTelemetry, sem loader.** A API cria os próprios spans (SERVER por requisição,
    CLIENT por consulta dentro dela) com a API e o SDK oficiais do OpenTelemetry, em vez da
    auto-instrumentação, que no ESM exige um hook de carregamento de módulos. Spans em OTLP/HTTP para o
    Collector da plataforma do tx03v2 (`OTEL_EXPORTER_OTLP_ENDPOINT`; desligado sem ele), que os grava no
    Cloud Trace; W3C trace context, e o trace id nos logs (`trace_id`, `span_id`) e nos exemplars. As
    sondas `/healthz` e `/readyz` não geram span. O mesmo código do dx01v2 e do dx02v2.

### Riscos conhecidos do caminho Google Cloud

- **Keep-alive.** O servidor da API fecha conexões ociosas após 65 s (`keepAliveTimeout`, escolhido
  para o nginx, 60 s; o comentário de `api/src/server.ts` remete a esta seção, que no dx02v2 trata dos
  timeouts do Application Gateway for Containers). A documentação "Request distribution for external
  Application Load Balancers" (consultada em 2026-10-12) diz que o timeout de keep-alive do load
  balancer com os backends é fixo em 600 s; um backend que fecha antes pode causar 502 esporádicos
  (`backend_connection_closed_before_data_sent_to_client`). Verificar na primeira rodada; a correção
  (subir o `keepAliveTimeout` acima de 600 s) muda o app e precisa ir para os três repositórios.
- **Regras pré-configuradas do Cloud Armor.** O smoke grava um texto com `<b>`; o `xss-v33-stable` com
  sensibilidade 1 não deveria tratá-lo como XSS, mas só uma rodada real prova (a regra está em
  `deny(403)`).
- **Status das políticas e propagação.** O deploy espera `Programmed` no Gateway e o endereço do
  contrato, e registra as condições da HTTPRoute e das políticas sem exigir um tipo de condição
  (a semântica do status das políticas `networking.gke.io` não está documentada). O load balancer pode
  levar minutos para responder depois do `Programmed`: o smoke espera até 15 minutos.
- **RBAC dos CRDs da GKE.** Os plurais `healthcheckpolicies` e `gcpbackendpolicies` da Role foram
  assumidos a partir dos CRDs do catálogo; o preflight `kubectl auth can-i` do deploy acusaria uma
  divergência antes de qualquer escrita.

## dx01v2 ↔ dx02v2 ↔ dx03v2

| Aspecto | dx01v2 (AWS) | dx02v2 (Azure) | dx03v2 (Google Cloud) |
|---|---|---|---|
| App (`api/`, `web/`, migrações) | commit `22e69c4` + traces com OpenTelemetry (2026-10-14) | o mesmo; só nomes e comentários | o mesmo; só nomes e comentários (o serviço dos spans é `dx03v2-api`) |
| Traces | Collector do tx01v2 → AWS X-Ray | Collector do tx02v2 → Application Insights | Collector do tx03v2 → Cloud Trace (o ServiceAccount do Collector é o principal do IAM) |
| Testes | suíte do commit `22e69c4` + os casos de integração do `X-Forwarded-For` do AGC (sem espaço) e do load balancer do Google (`<cliente>,<load balancer>`, `TRUST_PROXY_HOPS=2`) | a mesma suíte | a mesma suíte (os dois casos começaram no dx02v2 e aqui e foram portados para os três) |
| Smoke test | `SMOKE_BEHIND_WAF=1`: 403 do WAF acima de 8 KB | `SMOKE_EDGE=agc`: CSP da API, `X-Request-Id` do AGC, 413 da API | `SMOKE_EDGE=gke`: CSP da API, propriedade de segurança do `X-Request-Id`, 413 da API |
| Cluster | EKS 1.36 (tx01v2), access entries | AKS 1.36 (tx02v2), Entra ID; `kubelogin` | GKE Autopilot 1.36 (tx03v2, canal REGULAR); endpoint DNS e `gke-gcloud-auth-plugin` |
| Entrada | Ingress da AWS Load Balancer Controller (ALB) + WAFv2 | Gateway API no Application Gateway for Containers + WebApplicationFirewallPolicy | Gateway API no controlador da GKE (Application Load Balancer externo global) + GCPBackendPolicies com Cloud Armor |
| Saltos confiáveis (`TRUST_PROXY_HOPS`) | 1 | 1 | 2 |
| Health checks | anotações nos Services | HealthCheckPolicy por Service | HealthCheckPolicy por Service (`networking.gke.io`) |
| Segredos | Secrets Manager → ESO | Key Vault → ESO | Secret Manager → ESO (`gcp-secret-manager`) |
| Parâmetros do contrato | SSM `/tx01v2/lab/*` (10) | App Configuration `tx02v2/lab/*` (15) | Parameter Manager `tx03v2-lab-contract`, um JSON com 18 chaves |
| Registry | ECR, tags IMMUTABLE | ACR Basic, o deploy recusa sobrescrever tags | Artifact Registry, tags imutáveis; tag existente reaproveitada |
| TLS do banco | bundle `rds-ca` da região | três raízes com thumbprint SHA-1 conferido | bundle da região com a raiz do contrato (SHA-256) e só CAs emitidas por ela |
| NetworkPolicies de borda | CIDR da VPC (ALB e RDS) | subnet do AGC (/24) e subnet delegada do PostgreSQL | faixas do load balancer, `/32` do endpoint PSC e cache DNS do nó |
| Enforcement de NetworkPolicy | VPC CNI | Cilium (Azure CNI Overlay) | Dataplane V2 |
| HTTPS | overlay `aws-https` (certificado ACM) | AGC com certificado ACME no perfil full | Gateway com certificado gerenciado do Certificate Map no perfil full (`gcp-https`) |
| Identidade do GitHub | papel IAM com OIDC | managed identity com credencial federada | conta de serviço `dx03v2-gha-deploy` com Workload Identity Federation |
| Ferramentas do harness | 8 | as mesmas + `kubelogin` | as mesmas 8 (o gcloud vem do `setup-gcloud` no workflow) |
| Schemas do kubeconform | catálogo datreeio (ESO) | + gerados dos CRDs do ALB Controller | + Gateway API do asset oficial e `networking.gke.io` de um commit fixado do catálogo |

## v1 → v2

Problemas do v1 do Google Cloud (`dx03`, resumidos no `docs/LICOES_APRENDIDAS.md` do tx03v2, lições
18 e 30 a 37) que o v2 não pode repetir. As lições gerais do v1 (CORS fixo, erros sempre 500, probes
erradas, `expect(true).toBe(true)`, HSTS em HTTP, UTF-16) estão nas tabelas do dx01v2 e do dx02v2 e
continuam cobertas aqui pelos mesmos checks.

| Problema no v1 | Como o v2 resolve | Onde é verificado |
|---|---|---|
| `npm ci` do client falhando com `ERESOLVE` (eslint 8 com um plugin que exige eslint 9), depois de `EUSAGE` sem lockfile e de um `.gitignore` que escondia o `package.json` | um `package-lock.json` na raiz para os workspaces, versões exatas, `npm ci` sempre no modo estrito; os Dockerfiles também usam `npm ci` | `npm-ci`, `version-consistency`, `image:*` |
| `NODE_ENV: "dev"` no ConfigMap derrubando o backend (`Invalid NODE_ENV`) só para trocar um rótulo da UI | rótulo de ambiente em `APP_ENV` (`lab` no overlay `gcp`), validado pelo zod na partida com mensagem legível | teste `config`; `contract-app` |
| Readiness com `Authorization: Bearer METRICS_TOKEN_PLACEHOLDER`, que só funcionava depois de um `sed` no deploy | `/healthz` e `/readyz` sem segredo; HealthCheckPolicies e probes conferidos pelo contrato; o token de admin só vem do ExternalSecret `app-secrets` | testes `readiness`; `contract-app` |
| UI lendo campos que a API tirou de `/health` (`TypeError` em produção) | API e página mudam juntas, com testes da página, testes de integração e o mesmo smoke em compose, kind e no load balancer (este `não executado em nuvem (v2)`) | `test:web`, `test:api`, smoke |
| Imagens mutáveis (`:latest` e bases flutuantes) | tag = SHA de 40 caracteres num repositório de tags imutáveis; bases por digest; nada de `:latest` | `policy-images`; `contract-app` (deploy sem `:latest` e sem `docker push`) |
| Senha e host do banco como secrets do GitHub e `kubectl create secret` no workflow | o pipeline não manipula segredos: ExternalSecrets do Secret Manager; a conta de deploy não tem nada no Secret Manager e nunca escreve Secrets | `contract-app` (só tipos da Role, nenhum `Secret`); `policy-workflows` |
| ArgoCD sincronizando um caminho que nunca existiu, com o workflow do app como segundo dono do namespace | o workflow configura a Application para o overlay e a branch GitOps, publica a revisão e espera o Argo CD sincronizar; o app pai ignora apenas os campos dinâmicos da Application | `contract-app` valida os patches; o sync em nuvem segue `não executado em nuvem (v2)` |
| Workload Identity Federation criado à mão, aberto ao dono inteiro, e um vínculo extra feito à mão para o dx03 depois de falhar | pool e provider no Terraform do tx03v2, condição restrita aos dois repositórios e um sujeito exato (`environment:lab`) por conta de serviço; o harness recusa chaves de conta de serviço e o arquivo de credenciais fica fora do git e das imagens | `policy-workflows`, `policy-images` |
| URL da API resolvida no build e comentário com o IP público | mesma origem (`/api` e `/` na mesma HTTPRoute); só placeholders e as faixas documentadas | `policy-identifiers`; `contract-app` |
| Status escrito antes da evidência ("PRODUCTION READY", "100% HEALTHY") | matriz de status com rótulos e evidência; nada do Google Cloud afirmado sem `cloud_run_report` | `repo-structure`; revisão |
