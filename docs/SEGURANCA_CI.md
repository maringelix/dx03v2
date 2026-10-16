# Segurança e qualidade no CI

Este fluxo executa os scanners em pull requests e em forks sem depender de SonarCloud, assinatura
comercial, secrets de produção ou credenciais de nuvem. Os serviços são descartáveis e os checks
falham fechados: serviço indisponível, relatório ausente ou gate reprovado impede o check obrigatório.

## Análise estática e qualidade

- **CodeQL** roda as queries `security-extended` para JavaScript/TypeScript no job `test`. O SARIF
  fica como artefato do job por sete dias; o workflow não publica findings no GitHub Code Scanning e
  não precisa de `security-events: write`. O harness bloqueia findings de segurança com severidade
  `>= 7.0` e findings de segurança sem severidade numérica. Outros findings continuam visíveis no
  relatório para revisão.
- **SonarQube Community Build** sobe em container com PostgreSQL descartável e versão fixada. O
  SonarScanner também fica fixado por versão e SHA256 antes de executar. O job importa
  LCOV da API e da web, roda o Quality Gate `Sonar way` e falha se o scanner não conseguir publicar
  ou consultar o resultado.
- A edição Community analisa uma branch principal por projeto e não oferece decoração de PR. Cada
  execução usa um servidor novo; o snapshot do pull request é analisado como `main` nesse servidor,
  e o status do Quality Gate volta pelo próprio scanner. Isso não representa análise multibranch nem
  um comentário do Sonar na página do PR.
- O bootstrap troca a senha inicial `admin/admin`, cria apenas projetos descartáveis e emite tokens
  de análise limitados a cada projeto. Não há GitHub Secret configurado: os valores são gerados no
  runner, usados pelo scanner e encerram junto com o serviço descartável ao fim do job.
- Uma fixture fictícia, fora das fontes da aplicação, tem mais de 20 linhas sem cobertura e um LCOV
  explícito com zero linhas cobertas. O CI envia essa fixture a um segundo projeto, associa a ele um
  gate descartável que inclui `coverage < 80%` e confirma, pelo ID daquela análise, que o gate falhou
  nessa condição. Se a fixture passar ou o scanner falhar antes do upload, o check falha.

## Dependências, configuração e aplicação em execução

- `make static` usa Trivy para configuração Kubernetes/Docker e para CVEs corrigíveis HIGH/CRITICAL
  nos manifestos de dependências. Gitleaks examina arquivos visíveis ao Git e o histórico completo;
  o check de histórico falha se a ferramenta informar zero commits lidos, e `gitleaks-negative-gate`
  verifica que um token aleatório de teste é identificado e redigido no relatório.
- `make build` continua bloqueando CVEs corrigíveis HIGH/CRITICAL nas duas imagens finais.
- `make dast` usa as imagens já construídas (`make build` localmente; o artefato da etapa `images` no CI),
  sobe o app e o PostgreSQL num projeto Compose descartável e executa o OWASP ZAP Baseline
  com Ajax Spider em `127.0.0.1` e remove containers, rede e volume ao terminar. O processo ZAP roda
  sem capabilities adicionais, sem token administrativo e sem acesso a uma nuvem. A política
  `security/dast-baseline.conf` promove ausência de cabeçalhos e proteções selecionados a `FAIL`;
  `-I` evita reprovar por avisos de baseline fora dessa política, que continuam visíveis nos relatórios.
  COEP e CORP também são enviados pela aplicação e verificados no smoke test. HTML e JSON ficam fora
  do repositório; no CI os relatórios são artefatos por sete dias. Depois o mesmo check roda ZAP contra uma fixture local sem CSP, marca
  a regra 10038 como `FAIL` e exige que o scanner retorne falha com esse finding no JSON.
- O Baseline faz spider e análise passiva; não é um pentest nem uma prova de ausência de falhas. Ele
  não envia credenciais e não substitui revisão dos findings ou os testes de API e de segurança do
  harness.

## Executar e investigar

```bash
make tools
HARNESS_STRICT=1 make verify build
make dast
```

`make dast` precisa de Docker com rede e usa a porta `18080` por padrão. Se ela estiver ocupada,
defina `ZAP_TARGET_PORT`. Para guardar o relatório noutro local, defina `ZAP_REPORT_DIR`. Em máquina
com recursos limitados, rode esse check no GitHub Actions; ele não é incluído em `make all`.

Em `make test` local, sem `CODEQL_SARIF_PATH`, o harness executa o autoteste do parser SARIF. No job
`test` do GitHub Actions, o SARIF produzido pelo CodeQL é obrigatório e avaliado antes dos testes de
API e web. O SonarQube real também roda no Actions; a indisponibilidade do serviço não vira `SKIP`.

## Artefato, SBOM e proveniencia

O job `images` constrói as imagens uma vez, testa as imagens carregadas pelo build e guarda por 14 dias
o tar com os IDs das imagens e seu SHA256. O workflow publish-images roda manualmente a partir de main
para um SHA cujo ci.yml push passou pelos checks static, test, images, e2e e e2e-platform. Ele confere
o tar e os image IDs, publica as mesmas imagens no GHCR sem rebuild e cria SBOMs SPDX com hashes
registrados no bundle de release.

Trivy escaneia os digests no registry. actions/attest cria attestations de proveniencia SLSA e SBOM com
certificado Sigstore efemero. O gate verifica o digest da imagem, repositorio, workflow de publicacao,
emissor https://token.actions.githubusercontent.com, ref main, SHA do source e recusa runner self-hosted.
O job prova que um artefato sem attestation, um workflow diferente, um emissor diferente e um SHA de
source diferente falham. O manifesto e os arquivos SPDX ficam no Actions por 90 dias.

O workflow deploy-gcp recebe o ID da publicacao e, antes de solicitar aprovacao do environment lab,
confere de novo o publisher, a execucao CI, seus cinco checks, os hashes dos SBOMs e as attestations.
Depois da aprovacao copia os digests verificados do GHCR para o Artifact Registry sem rebuild, valida o digest e
o image ID e publica os manifests por digest no Argo CD. A verificacao do bundle nao configura nem
altera contas cloud.

A cópia exige `roles/artifactregistry.writer` na identidade de deploy, limitada ao repositório `dx03v2`.
O tx03v2 já concede esse papel no contrato de deploy (`docs/CONTRATO.md`); a identidade não recebe
permissão de escrita no projeto inteiro.


## Aula: provar que o gate bloqueia

1. Remova cobertura de um bloco novo com mais de 20 linhas no app. O limite local de cobertura e o
   Quality Gate do Sonar devem reprovar; não reduza thresholds nem adicione ignore.
2. Para observar o bloqueio SAST sem inserir código vulnerável no app, use a fixture SARIF dos
   testes de `scripts/check-codeql-sarif.mjs --self-test`: severity `6.9` passa, `7.0` falha e
   finding de segurança sem severidade também falha.
3. Execute `HARNESS_ONLY='^gitleaks-negative-gate$' scripts/harness.sh static` para criar, detectar
   e apagar um segredo fictício em diretório temporário. Nenhum token estático é salvo no repositório.
4. Execute `make dast`, abra `zap.html` e `zap.json` em `ZAP_REPORT_DIR` e siga a evidência do alerta
   até o cabeçalho, resposta ou rota que o gerou. Corrija a causa e rode novamente; `zap-fixture.json`
   demonstra que o CI falha diante da CSP ausente.
5. Em pull request de fork, confira que o job usa somente `contents: read`, credenciais geradas para
   o Sonar local e nenhum GitHub Secret ou identificador de nuvem.

## Exceções

Não há ignore de CodeQL, Sonar, ZAP, Gitleaks ou Trivy nesta rodada. Uma exceção futura precisa
registrar finding, evidência, motivo, responsável, mitigação e data de expiração; precisa passar pelos
guardrails já existentes para ignores e nunca pode baixar os limites globais do harness.
