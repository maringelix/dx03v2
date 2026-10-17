# O app na plataforma local

O tx03v2 monta, no Docker, a plataforma completa que o lab v1 só tinha na nuvem (Istio, cert-manager,
External Secrets, Prometheus/Alertmanager/Grafana, Loki/Alloy, Tempo e o OpenTelemetry Collector, Argo
CD, Gatekeeper, Trivy Operator, Velero, Chaos Mesh) em cima de um kind com Artifact Registry, Cloud SQL,
Cloud Storage (por um emulador da API do S3), load balancer e servidor git emulados
(`docs/LAB_LOCAL.md` do tx03v2). Este repositório faz o deploy do app nela do jeito GitOps e prova o
comportamento com sondas. Nada aqui fala com o Google Cloud.

Status: o job `e2e-platform` executa 19 sondas no tamanho padrão; este PR acrescenta o exercício de
rollback R7.2 à suíte de 18 sondas já verificada. O job `e2e-platform-small` executa as mesmas 19
sondas no tamanho `small` com o Docker limitado a 7 GB. CI deste PR confirma os dois tamanhos. A prova
`verificado localmente` foi feita em
2026-10-13 (as 13 sondas de então, rodada do zero na plataforma local do tx03v2, lab destruído sem
sobras). As cinco sondas de 2026-10-14 (traces, rollout e chaos do banco) só rodaram no CI: a
plataforma `full` com o app passa dos 7,65 GiB de memória do Docker Desktop usado aqui no tamanho
padrão; no tamanho `small`, cabe em 7 GB (abaixo).

## Como rodar

```bash
make build                          # imagens dx03v2-api:e2e e dx03v2-web:e2e (ou deixe o e2e construir)
make e2e-platform                   # sobe o lab do tx03v2, faz o deploy, roda as sondas e destrói tudo
LOCAL_SIZE=small make e2e-platform  # o mesmo, com a plataforma no tamanho small (Docker com 7 GB)
```

O script clona o tx03v2 no commit de `deploy/local/tx03v2.ref`; com `TX03V2_DIR=<checkout>` ele usa
um checkout seu, e `TX03V2_REPO=<URL https>` clona outro repositório (o seu fork; no CI, a variável de
repositório `TX03V2_REPO`, `FORK.md`). `KEEP_LAB=1` mantém o lab no fim (`bash <tx03v2>/scripts/local-lab.sh down` depois).
Dentro de um contêiner que usa o Docker do host, exporte `LOCAL_KIND_INTERNAL=1`. Precisa de Docker com
8 GB de memória, ou 7 GB com `LOCAL_SIZE=small`.

Com o lab do tx03v2 já de pé (`make local-up` lá), o deploy sozinho:

```bash
export KUBECONFIG="$(bash ../tx03v2/scripts/local-lab.sh kubeconfig)"
GIT_SHA=$(git rev-parse HEAD) scripts/deploy-local.sh
```

O `scripts/deploy-local.sh` recusa qualquer contexto do kubectl que não seja `kind-tx03v2-local`: um
cluster seu que esteja no contexto atual nunca recebe o deploy.

## Tamanho `small` e a prova dos 7 GB

`LOCAL_SIZE=small` chega ao `platform/local/install.sh` do tx03v2: os mesmos componentes, com limites
de memória menores, retenção curta no Prometheus e no Tempo, menos séries e menos workers
(`docs/LAB_LOCAL.md` do tx03v2 diz o que muda em cada chart). O app não muda. Um valor diferente de
`default` ou `small` falha antes de qualquer build.

`make e2e-platform-small` (job `e2e-platform-small` do CI, `scripts/e2e-platform-small.sh`) roda o
`e2e-platform` com `LOCAL_SIZE=small` dentro de um Docker-in-Docker (`docker:29.9.0-dind`, por digest)
limitado a 7 GB, sem swap: é o Docker de um notebook com 7 GB para ele. O resultado do job é o do
e2e, e o resumo do job traz o pico de memória do daemon inteiro, o pico de memória anônima (o cache de
páginas enche qualquer limite; sem swap, a memória anônima é a que não pode ser devolvida), os maiores
contêineres e os processos que o kernel matou por falta de memória. Não é check exigido: quem barra o
merge é o `e2e-platform` no tamanho padrão.

| Plataforma `full` + app | Docker | Resultado |
|---|---|---|
| tamanho padrão | runner do CI, 16 GB | passa (job `e2e-platform`) |
| tamanho `small` | 7 GB, sem swap (CI, 2026-10-15) | passa: as 18 sondas anteriores ao drill de rollback em cerca de 13 minutos, memória anônima de 4,40 GiB. Em uma das duas rodadas desta prova, o kernel matou duas vezes a cópia do plugin do Velero na instalação (init container BestEffort, que o kubelet roda de novo); CI deste PR repete o ensaio com 19 sondas |

O par 01 mediu também o tamanho padrão em 7 GB (falha por thrashing) e o `small` em 6 GB (a sonda de
rollout perde requisições) e em 8 GB (passa): `docs/LAB_LOCAL.md` do dx01v2. A meta da R1.8 era 6 GB;
o tamanho `small` ficou em 7 GB por decisão do Bruno em 2026-10-15, abaixo dos 7,65 GiB do Docker
Desktop de desenvolvimento. Os maiores consumidores (pico do working set no job, 2026-10-15):
apiserver do Kubernetes 1279 MiB, Grafana 309 MiB, controller do Argo CD 284 MiB,
Prometheus 250 MiB, Trivy Operator 190 MiB, etcd 160 MiB e os dois pods do Gatekeeper, 264 MiB; a
API do app usa 62 MiB por pod.

O `e2e-platform-small` é pesado: além dos 7 GB, o daemon interno baixa de novo todas as imagens do
lab. Ele foi feito para o runner do CI; num notebook de 16 GB com editor e navegador abertos, rode
`LOCAL_SIZE=small make e2e-platform` com o Docker configurado em 7 GB.

## Como o deploy funciona (`scripts/deploy-local.sh`)

1. Lê o contrato local `lab-system/lab-contract` (versão 2) e recusa valores diferentes dos fixados no
   overlay (registry, segredos, ClusterSecretStore, GatewayClass, issuer, AppProject, endpoint OTLP).
2. Envia as imagens para o registry do lab (o gêmeo local do Artifact Registry) com a tag do commit
   (`localhost:5003/dx03v2/*:<sha>`; no cluster elas se chamam `registry.tx03v2.local/dx03v2/*`).
3. Copia a CA do lab para o ConfigMap `lab-ca` do namespace (a API usa `DB_SSL_MODE=verify-full`).
4. Renderiza `deploy/k8s/overlays/local-platform` com os valores do contrato e faz commit no repositório
   GitOps do servidor git do lab (push com a chave de `lab-secrets/gitops-push-key`).
5. Cria a Application `dx03v2` (AppProject `dx03v2`, prune e self-heal) e espera Synced/Healthy no
   commit que acabou de enviar (num redeploy a Application ainda está Synced no commit anterior), os
   rollouts e o Gateway `Programmed`.

O overlay `local-platform` acrescenta à `base`: Gateway `dx03v2` (classe `istio`, HTTPS com o
certificado do `lab-ca`, HTTP → 301) e HTTPRoutes (`/api` → api:3000, `/` → web:8080, as mesmas regras
do Gateway da GKE); ExternalSecrets de `local-secrets` (o gêmeo local do Secret Manager); HPA 2-4;
`PeerAuthentication` `STRICT` e `AuthorizationPolicy` por identidade (Gateway e web para a API, Gateway
para o web, Prometheus para a porta de métricas); NetworkPolicies com HBONE (15008) e as sondas do
kubelet do ambient (`169.254.7.127/32`); saída da API só para o banco (`10.252.0.11/32`) e para o
OpenTelemetry Collector (OTLP/HTTP, `OTEL_EXPORTER_OTLP_ENDPOINT`), saída do Gateway para o Collector
(os spans dele, OTLP/gRPC), as duas pelo mesh (HBONE); ServiceMonitor, cinco regras de alerta e um
dashboard do Grafana. Só usa os kinds que o AppProject `dx03v2` do tx03v2 aceita (o `contract-app`
confere).

O componente `mesh-full` (R8.2) acrescenta o exercício de malha com um waypoint próprio (Gateway
`dx03v2-waypoint`, classe `istio-waypoint`) ligado só aos três Services `mesh-*`: dois backends da imagem da API
(`mesh-stable` e `mesh-canary`, `api/src/mesh-demo.ts`), um HTTPRoute com 80/20 em `/variant` e no máximo dois
retries em `/fail` (canal experimental da Gateway API no lab do tx03v2), um DestinationRule que ejeta o canário
após três 5xx e uma AuthorizationPolicy no waypoint que só aceita a identidade `mesh-probe`. As NetworkPolicies do
waypoint e dos backends são explícitas (HBONE na 15008, istiod na 15012, kubelet). O restante do app não passa
pelo waypoint. A nuvem roda o mesmo exercício nos sidecars do Cloud Service Mesh gerenciado (`mesh-csm`).

## Traces, logs e métricas ligados

A API cria um span SERVER por requisição (com o nome da rota, nunca o caminho cru) e um span CLIENT por
consulta ao PostgreSQL feita dentro dela (só o SQL parametrizado: os valores não vão para o span), e
continua o `traceparent` W3C que o Gateway do Istio manda. Os spans saem em OTLP/HTTP para o Collector do
tx03v2, que os grava no Tempo. Cada linha de log escrita dentro da requisição leva `trace_id` e
`span_id`, e o histograma de latência guarda o `trace_id` como exemplar (o `/metrics` fala
OpenMetrics). No Grafana: do gráfico de latência para o trace (exemplar), do trace para os logs, e da
linha de log para o trace. Sem `OTEL_EXPORTER_OTLP_ENDPOINT` (compose, kind, testes) nada é exportado.

## O que as sondas provam (`scripts/e2e-platform.sh`)

| Sonda | O que prova |
|---|---|
| gitops | as imagens estão no registry do lab, o Argo CD sincronizou o commit (Synced, Healthy) e recria um objeto apagado |
| backup | `pg_dump` do banco do lab, mensagem apagada pela API, restore traz de volta |
| smoke | o smoke test inteiro (`e2e/smoke.mjs`, `SMOKE_EDGE=istio`) por HTTPS em `dx03v2.tx03v2.local`, de fora do mesh: load balancer emulado → Gateway do Istio → app, certificado conferido contra a CA do lab |
| mesh | um cliente em texto puro fora do mesh não chega na API nem no serviço do exercício; o Job com a identidade `mesh-probe` mede o 80/20 do canário (400 requisições), a requisição de falha tem o original mais dois retries no canário (contados nos logs do backend) e, depois da ejeção, a seguinte não chega mais nele; o Job com a identidade `mesh-intruder` recebe 403 |
| observability | Prometheus coleta a API pelo mesh, as cinco regras estão carregadas, há métricas do tráfego do smoke, o Grafana carregou o dashboard, os logs da API estão no Loki |
| tracing | uma leitura com `traceparent` vira um trace no Tempo da borda ao banco (span do Gateway, `GET /api/messages`, `SELECT dx03v2`); as linhas de log dela no Loki têm o `trace_id`; o histograma da API no Prometheus tem um exemplar com ele |
| trivy | o Trivy Operator gerou relatórios de vulnerabilidade das imagens do app |
| hpa | o HPA está `ScalingActive` (metrics-server) |
| rollout | hipótese: uma versão nova entregue pelo GitOps (tags novas, rolling update com `maxUnavailable: 0`, readiness, `preStop` e desligamento gracioso) não perde nenhuma requisição de um leitor que alterna API e web pelo Gateway (zero downtime) |
| chaos | hipóteses: com 2 réplicas, matar um pod da API não interrompe as leituras (pelo menos 38 de 40); com 200 ms entre a API e o PostgreSQL (`NetworkChaos`), todas as leituras passam e o trace mostra o atraso no span da consulta |

`SMOKE_EDGE=istio`: como no Gateway da GKE, `/api` vai direto para a API (as respostas de `/api` têm a
CSP da própria API; um único salto de proxy: `TRUST_PROXY_HOPS=1`, contra 2 atrás do load balancer do
Google); como no nginx, um `X-Request-Id` externo seguro volta intacto (o `EnvoyFilter`
`gateway-preserve-request-id` do tx03v2; a documentação do load balancer do Google não diz o que ele
faz com esse cabeçalho, então `SMOKE_EDGE=gke` só confere que ele é seguro). As regras de alerta também
são testadas sem cluster pelo `promtool` (check `promtool-rules`,
`deploy/k8s/components/local-platform/alerts-test.yaml`).

## Limites

- Tudo roda num nó kind; nada disso prova o comportamento na GKE Autopilot (o deploy no Google Cloud
  continua `não executado em nuvem (v2)`): nem o Gateway da GKE com o Cloud Armor, nem o Secret
  Manager, nem a Workload Identity Federation for GKE, nem o Cloud SQL pelo Private Service Connect.
  O Autopilot recusaria parte da plataforma local (Istio ambient e Chaos Mesh precisam de privilégios).
- As regras do Autopilot para requests (mínimos e proporção CPU:memória) continuam conferidas pelo
  `contract-app` só nos overlays `gcp`; no kind ninguém as aplica.
- A API vê o endereço do load balancer emulado como cliente (o Envoy dele é TCP): o rate limit vale para
  todos os clientes juntos no lab local.
- O ConfigMap `lab-ca` é criado pelo deploy, fora do GitOps (como o `cloudsql-ca` no Google Cloud).
- O rollout da sonda troca só a tag das imagens (o conteúdo é o mesmo): prova o caminho do deploy e a
  troca dos pods, não uma migração de banco incompatível.
