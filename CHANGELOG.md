# Changelog

## 1.1.0

### Adicionado
- Rótulos descritivos por comando via comentários `#* <descrição>` antes da instrução (e suporte opcional a comentários `#` simples com `AGENTTOOLS_ICP_COMMENT_LABELS=1`), exibidos na barra de status, no prompt `-Step` e no atributo/campo `rotulo` de todos os formatos de relatório.
- Novos formatadores de saída `-Format yaml` (`YAML 1.2` com blocos escalares `|2-`) e `-Format toml` (`TOML 1.0`), além de retenção `.yaml`/`.toml` em `icp-logs`.
- Suporte à variável de ambiente `AGENTTOOLS_ICP_FORMAT` para definir o formato padrão com precedência `-Format` > `AGENTTOOLS_ICP_FORMAT` > `xml`.
- Modo interativo direto por parâmetro `-Interactive`, comentário `#* interactive` ou token `:interactive` no compositor, executando comandos sem captura de *pipe* para preservar TTY (`IsInputRedirected=False`, `IsOutputRedirected=False`), com captura de erros não terminativos e aviso em sessões não interativas.

### Corrigido
- Entrega garantida de relatório parcial em interrupção por `Ctrl+C` (`status="INTERROMPIDO"`), com encerramento correto dos processos filhos reportados em `filho` (sem sufixo vazio), medição de `sem_saida_s`, registro de comandos restantes como `NAO_EXECUTADO` e preservação de `flags="step"` ao escolher `[A]`.
- Redução de falsos positivos no mascaramento de atribuições via `Test-IcpAtribuicaoValorSegredo`, preservando valores não secretos (contagens, booleanos, códigos HTTP, rótulos descritivos) enquanto continua mascarando senhas, chaves e tokens reais.
- Detecção antecipada de processos filhos ativos na barra de status (`_lastChildCheckMs = -650`).

### Documentação
- Atualizados `README.md`, `Tools/icp/README.md`, `Tools/icp/Contracts/REPORT_CONTRACT.md`, ajuda integrada (`Get-Help icp` / `-?`) e `skills/icp/SKILL.md`.

## 1.0.0

- Publica o AgentTools como módulo independente, com instalação documentada, metadados do projeto e licença MIT.
- Alinha as descrições de diagnóstico e as notas de exemplos em `icp -Help`, com cobertura de regressão.
- Atualiza a documentação e os exemplos do contrato de relatório v2.

## 0.9.5

- Separa o núcleo em `Core/` e a ferramenta em `Tools/icp/`, com carregamento sob demanda e motor isolado.
- Adota em definitivo o contrato de relatório v2, com XML compacto, JSON estrito e Markdown.
- Reforça o tratamento de aninhamento e interrupção. Registra códigos de saída aceitos e permite gravar relatórios diretamente em arquivo.

## 0.9.0

- Adiciona execução passo a passo com `-Step`, preserva cores nativas na tela e detalha a referência com `icp -Help -Full`.

## 0.8.0

- Introduz o compositor interativo, os temas de terminal e a barra de status com atualização sincronizada.
- Adiciona `-KeepBlock` e a demonstração visual com `icp -Help -Demo`.

## 0.1.0 a 0.7.x

- A primeira versão do `icp` executava blocos PowerShell em sequência e reunia a saída em um relatório.
- As versões seguintes acrescentaram ocultação de segredos, relatórios em arquivo para saídas grandes e leitura do fim de arquivos redirecionados.
- A série 0.7 refinou o pré-voo, os resumos de erro e os diagnósticos de erros silenciosos e processos filhos ativos.
