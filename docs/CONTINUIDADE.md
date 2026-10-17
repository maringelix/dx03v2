# R9 — dados, perda regional e volta à origem

Status: implementação em revisão; o job `continuity` publica as medições de cada commit.
Nada de v2 foi executado no GCP. Um resultado Docker não certifica SLA, latência,
replicação gerenciada nem promoção do Cloud SQL.

## Experimento reproduzível sem conta cloud

O `make continuity` exige as duas imagens já construídas pelo CI. É um ensaio pesado,
destinado ao Actions. Não compila uma imagem diferente daquela aprovada pelos scanners.

1. Cria A e B com redes de backend/frontend e discos independentes; nenhum banco
   expõe porta no host. Só a aplicação publica HTTP em loopback com porta aleatória.
2. Recupera um pacote de configuração e segredos efêmeros por checksum. Os IDs de
   imagem são conferidos; o pacote e as chaves privadas nunca entram em artifacts.
3. Usa PostgreSQL com TLS `verify-full`, CA efêmera e SAN `db`. A API monta apenas
   a CA pública. O banco e o frontend não compartilham rede diretamente.
4. Grava um marcador pela API através do nginx, para o banco e comprova falha
   de leitura. Reinicia o banco e exige recuperação pela mesma API, sem reiniciá-la.
5. Faz `pg_dump -Fc`, confere o catálogo e SHA256, grava uma transação posterior
   e exige que a tentativa de promoção com o primário vivo seja recusada.
6. Corrompe uma cópia do backup e exige rejeição antes de qualquer restore.
7. Interrompe todos os escritores de A, verifica o fencing e destrói seu disco.
   Restaura B a partir do backup íntegro e inicia a mesma versão da aplicação.
8. Exige o marcador anterior e a ausência da transação posterior ao backup. Mede
   RPO como o intervalo entre o início do backup consistente e a falha; RTO vai da
   falha até a aplicação B servir e confirmar os dados. Limites locais: 120 s/180 s.
9. Grava em B, produz novo backup, bloqueia B e reconstrói A num disco novo.
   A volta precisa preservar tanto os dados originais quanto os gravados em B,
   em até 180 s. B deve permanecer sem capacidade de escrita.

O relatório `continuity/continuity.json` contém checksums, IDs de imagem, RPO,
RTO, tempo de failback e a perda intencional de uma transação. Erros falham o job.
O cleanup verifica o rótulo exclusivo de execução antes de remover cada recurso.
Não usa volume, rede, contexto Kubernetes ou projeto Compose de outro trabalho.

## O que cada camada recupera

| Camada | Mecanismo | Evidência |
|---|---|---|
| Reconexão da API | pool descarta conexão quebrada e abre outra | interrupção do DB, mesmo container da API |
| Backup lógico da aplicação | `pg_dump`, catálogo e SHA256 | marcador preservado e corrupção recusada |
| Arquivo físico/WAL e PITR | exercício do `tx03v2` | base backup verificado, restore point, transação removida recuperada |
| PVC Kubernetes | Velero no `tx03v2` | em construção no PR coordenado, requer checksum após remover o PVC original |
| Perda de ambiente e failback | redes/discos A/B independentes | job `continuity`, fencing e dados novos preservados |
| Imagens e supply chain | artifact do próprio job `images`, release assinada no deploy | mesmos IDs em A e B, gates R7 |
| Banco e runtime gerenciados | perfil `dr` e runbook do `tx03v2` | Terraform mock/validação; não executado na cloud |

Em cloud, confirme o plano e a região do contrato antes de qualquer alteração.
Bloqueie GitOps/deploys e escritores antigos antes de promover a réplica; uma troca
de DNS sozinha não impede split brain. Execute o runbook do par, acompanhe o lag,
guarde evidência de RPO/RTO e só faça failback após reseed consistente da origem.
Se a origem não puder ser isolada, pare a promoção e escale ao operador.

Não copie o arquivo `.env` local para cloud. Segredos regionais ficam no Secret
Manager e workload identities da região. A promoção publica os digests já
assinados no registry da região recuperada; não deve reconstruir o código.

## Deploy da recuperação gerenciada

Com o perfil `dr` do TX aplicado e o banco promovido **depois do fencing**, instale
a plataforma do secundário com `LAB_TARGET=secondary`. No workflow `deploy-gcp`,
selecione `target=secondary`, a mesma release assinada e o perfil de plataforma
instalado. O script lê `tx03v2-lab-dr-contract`, obtém o kubeconfig do cluster
`tx03v2-lab-dr`, promove os digests no registry da região e publica `gitops/gcp-dr`.
Uma referência arbitrária de cluster/contrato é recusada pelo teste `region-target`.

Verifique inicialmente o endereço reservado do secundário usando resolução local
do hostname TLS. Só após consultas, escrita de prova e aceite de dados, altere
`LAB_ACTIVE_REGION=secondary` no TX e revise/aplique o plano de DNS. Esse input
exige o perfil `dr`; ele não faz fencing nem promoção por conta própria. Registre
a hora da última escrita aceita no primário, lag da réplica e primeira escrita
aceita no secundário para medir RPO/RTO da cloud.

O CI de publicação/deploy também exige sucesso de `continuity` na origem da release.
Para failback, reconstrua a origem a partir do banco promovido, sincronize, congele
escritas, faça fencing do secundário e só então retorne o DNS e a branch de deploy
do primário. Não reaplique uma réplica Terraform já promovida sem reconciliar seu
estado e revisar o plano; isso pode causar substituição ou perda de dados.
