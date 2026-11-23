# AgentTools (`0.9.5`)

Módulo utilitário modular para PowerShell 7.2+ no Windows 11. Exporta atualmente a função `icp`, com núcleo compartilhado em `Core/` e ferramentas isoladas em `Tools/<nome>/` carregadas sob demanda.

## Arquitetura (`Core/` + `Tools/<nome>/`)

- [AgentTools.psd1](AgentTools.psd1) e [AgentTools.psm1](AgentTools.psm1): carregam apenas `Core/` e os *entrypoints* finos de cada ferramenta no import do módulo; o motor de cada ferramenta carrega sob demanda na primeira chamada.
- **`Core/` (núcleo compartilhado):**
  - [Loader.ps1](Core/Loader.ps1): `Import-AgentToolsCoreModule`, `Import-AgentToolsToolEntrypoint`, `Import-AgentToolsTool` (lendo `tool.psd1` com validação de `RequiresCore` e falha alta em colisão de funções) e `Resolve-AgentToolsNativeBin` (verificação `SHA256` com sinalização de *fallback* PS puro).
  - [Masking.ps1](Core/Masking.ps1): ocultação de segredos com timeout de regex (`500 ms`), `Authorization: Basic`, valores `[...]`, JSON escapado e AST (`Hide-IcpAtribuicaoSensivel`).
  - [Theme.ps1](Core/Theme.ps1): temas Gruvbox / Terminal ANSI / Gruvbox-puro, `AGENTTOOLS_ICP_COLORS` e `NO_COLOR`.
  - [Terminal.ps1](Core/Terminal.ps1): limpeza ANSI/`\r`, detecção interativa, limpeza DEC 2026 e `Restore-AgentToolsConsoleState`.
  - [Process.ps1](Core/Process.ps1): snapshot Win32 da árvore de processos em namespace C# versionado, com validação de tempo de criação via `GetProcessTimes`.
- **`Tools/icp/` (ferramenta isolada):** documentada em [Tools/icp/README.md](Tools/icp/README.md) e especificada no contrato `versao="2"` em [Tools/icp/Contracts/REPORT_CONTRACT.md](Tools/icp/Contracts/REPORT_CONTRACT.md).

## Parâmetros principais do `icp`

| Parâmetro | Padrão | O que faz |
|---|---|---|
| `-ScriptBlock` (pos. 0) | obrigatório em `-Exec` | Bloco com os comandos. Sem args em terminal interativo abre o compositor. |
| `-Format` | `'xml'` | Formato do relatório `versao="2"`: `xml` (compacto LLM), `json` (estrito) ou `markdown` (cercas dinâmicas). |
| `-Explain` | desligado | Inclui `<legenda>`, `<aviso>` e `<ambiente>` completos (ideal no 1º envio a uma IA nova). |
| `-Step` | desligado | Pausa após cada comando exibido em modo interativo (`[Enter/S]`, `[A]`, `[C]`). |
| `-ContinueOnError` | desligado | Executa todos os comandos mesmo com falha. |
| `-AllowedExitCodes` | `@()` | Códigos não-zero aceitos como `OK` em nativos (registra `exit` e `exit_permitido`). |
| `-Raw` | desligado | Desliga deduplicação e limites de linhas/largura (mantém máscara e envio para arquivo). |
| `-MaxLinesPerCommand` | `150` (mín. `10`) | Mantém 2/3 iniciais e 1/5 final quando excede. |
| `-MaxLineLength` | `1500` (mín. `80`) | Corta linhas maiores no relatório. |
| `-MaxClipboardChars` | `20000` | Acima disso grava arquivo exclusivo em `icp-logs` (`.txt`/`.json`/`.md`, retenção 7 dias) e copia resumo. |
| `-RedirectTailLines` | `5` (`0` desliga) | Inclui linhas finais de arquivos redirecionados (`>`, `>>`, `2>`, `*>`). |
| `-OutFile` | vazio | Grava relatório completo em arquivo (UTF-8 sem BOM), sem clipboard e sem `icp-logs`. |
| `-NoClipboard` | desligado | Não altera a área de transferência. |
| `-NoMask` | desligado | Desliga ocultação de segredos (não recomendado ao compartilhar logs). |
| `-AllowTrailingBackslash` | desligado | Libera `\` isolado no fim de linha mantendo os demais bloqueios do pré-voo. |
| `-CommandTimeoutSeconds` | `0` (desligado) | Encerra filhos iniciados após N segundos e marca `FALHOU`. |
| `-KeepBlock` / `-NoStatus` | desligados | Mantém bloco digitado / desliga linha de status DEC 2026 (`AGENTTOOLS_ICP_NOFORCECOLOR` desliga cor forçada em nativos). |
| `-Help` / `-Full` / `-Demo` | desligados | Guia visual TUI, referência completa na TUI ou simulação animada da barra. |

## Testes e validação

```powershell
Test-ModuleManifest .\Modules\AgentTools\AgentTools.psd1
Import-Module Pester -MinimumVersion 5.0
Invoke-Pester -Path .\Modules\AgentTools\Tests -Output None -PassThru
```

A suíte está dividida em [Tests/Core.Tests.ps1](Tests/Core.Tests.ps1) (núcleo `Core/`) e [Tests/icp.Tests.ps1](Tests/icp.Tests.ps1) (ferramenta `icp` e contrato `versao="2"`).
