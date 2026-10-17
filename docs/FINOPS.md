# R10 — capacidade, SLO e rightsizing do app

Construção para fork; nenhuma execução GCP (v2).
O workflow completo usa o tx03v2 fixado em deploy/local/tx03v2.ref.
O cenário small permanece num nó/7 GiB; o cenário de capacidade usa LOCAL_TOPOLOGY=ha,
LOCAL_FINOPS=1 e recomenda 12 GiB disponíveis no Docker. Rodadas pesadas ficam no Actions.

## Aula e evidência

O CI e2e-platform executa scripts/capacity-app.sh após as sondas anteriores.
Em Linux/devcontainer com recursos disponíveis:

    LOCAL_TOPOLOGY=ha LOCAL_FINOPS=1 make e2e-platform

O teste aceita somente o kubeconfig kind-tx03v2-local. Mede requisições HTTPS reais
a /api/messages pelo Gateway com CA validada, sem gravar nem expor credenciais.
Cada fase tem concorrência e duração limitadas, deadline do pod e limpeza.

1. Mede baseline com 4 clientes por 30 segundos (sucesso >=99%, p99 <=1,5 s).
2. Injeta StressChaos de CPU, com limites de CPU de 500m no API, junto da carga HTTP.
   Exige HPA chegar a quatro réplicas prontas.
3. Drena somente os pods API de um worker pertencente ao kind. PDB, readiness e
   RollingUpdate continuam ativos; o cliente mantém o mesmo SLO durante o ensaio.
4. Remove o stress, experimenta requests CPU 100m → 50m e exige scale-down para dois.
   Repete a mesma carga/SLO e registra requests agregados antes/depois.
5. Faz um lock de tabela PostgreSQL por 10 s: pelo menos dez conexões API bloqueadas,
   pool saturado e erros visíveis ao cliente. Ao soltar o lock, exige recuperação
   e repete o SLO. Mais pods não consertam um gargalo no banco.
6. Exige recomendação VPA com updateMode Off; uma quota rejeita um pod caro por
   exceder CPU. O JSON de evidência contém contagens/latência, sem corpos/respostas.

O controlador Argo CD é pausado durante o experimento imperativo. O trap restaura
requests, HPA e o número original de réplicas do controlador, inclusive em falhas.
Os manifests GitOps continuam a fonte de configuração permanente. O HPA normal
tem janelas de estabilização; somente o teste usa scale-down curto.

## Showback e interpretação

Todo template de pod da aplicação exige cost.lab/owner e cost.lab/environment;
o check contract-app falha se qualquer label faltar. Ajuste owner no kustomize
para o responsável da aula. OpenCost e Grafana são instalados pelo tx03v2:
consulte a aula de [FinOps da infraestrutura](https://github.com/maringelix/tx03v2/blob/main/docs/FINOPS.md)
para /allocation, idle/shared, fontes/data/moeda/região e serviços fora dos pods.

Reduzir requests não garante economia: o HPA pode pedir mais réplicas. Compare
requests agregados, uso medido, latência, erros e alocação para a mesma carga.
O candidato de 50m é um ensaio, restaurado ao terminar; não muda a configuração
de produção automaticamente. VPA Off não compete com HPA sobre requests.

## GCP e limpeza

Autopilot provisiona capacidade a partir dos requests; a aula Spot do tx03v2 usa
tarefa descartável com deadline/fallback on-demand explícito, preservando o app
crítico. Aumentar réplicas no kind não comprova escala gerenciada ou preço de GCP.
Use o gate de estimativa, budget e expiração do tx03v2 antes de qualquer apply;
não trate OpenCost como fatura nem budget como teto de cobrança.

Em falha, examine capacity-app.json, eventos, HPA/PDB/VPA, metrics-server,
pool/conexões e logs do Gateway. O teardown do e2e sempre destrói os recursos que
esse estado criou e verifica sobras. A limpeza cloud usa o runbook do par e só
deve ocorrer na rodada autorizada.
