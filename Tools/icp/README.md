# Ferramenta `icp` (`AgentTools 0.9.5`)

O `icp` executa cada comando de um bloco `{ ... }` **uma única vez** em sequência, dentro de um escopo isolado do motor, para na primeira falha (salvo `-ContinueOnError`), mantém saída colorida na tela para o operador e gera relatório estruturado **`versao="2"`** em **XML compacto** (padrão), **JSON estrito** ou **Markdown** (área de transferência ou arquivo).

## Estrutura interna (`Tools/icp/`)

- [tool.psd1](tool.psd1): manifesto local da ferramenta (ordem explícita de carga, dependências `RequiresCore` e `Entrypoint`).
- [icp.ps1](icp.ps1): *entrypoint* fino carregado no import do módulo `AgentTools`; dispara `Import-AgentToolsTool -Name 'icp'` sob demanda na primeira execução.
- `Engine/`:
  - [PreFlight.ps1](Engine/PreFlight.ps1): análise AST pré-voo (`\` Bash, `begin`/`process`/`clean`/`dynamicparam`, `break`/`continue` soltos, `VAR=valor` POSIX) e guarda de cor nativa (`AGENTTOOLS_ICP_NOFORCECOLOR`, `--output`, `git commit`/`am`/`rebase`).
  - [Engine.ps1](Engine/Engine.ps1): motor isolado em `[psmoduleinfo]::new($true)`, captura com teto de memória, controle `Ctrl+C`, limpeza de console e entrega.
- `Features/`:
  - [Report.ps1](Features/Report.ps1): modelo intermediário `versao="2"`, teto de disco, criação exclusiva (`icp-*.txt|json|md`) e retenção de 7 dias.
  - `Formatters/`: [Xml.ps1](Features/Formatters/Xml.ps1), [Json.ps1](Features/Formatters/Json.ps1) e [Markdown.ps1](Features/Formatters/Markdown.ps1).
  - [StatusBar.ps1](Features/StatusBar.ps1): barra C# versionada (`DEC Mode 2026`), ligada via delegates ao `Core/Process.ps1`.
  - [Compositor.ps1](Features/Compositor.ps1): compositor interativo linha a linha com `PSReadLine`.
  - [Help.ps1](Features/Help.ps1): painel visual `icp -Help` / `-Full`.
- [Contracts/REPORT_CONTRACT.md](Contracts/REPORT_CONTRACT.md): contrato formal `versao="2"`.

## Exemplos rápidos

```powershell
icp                                                            # cartão + compositor interativo
icp { git status --short; git --no-pager log --oneline -3 }    # relatório v2 XML compacto (padrão)
icp -Format json -OutFile .\relatorio.json { dotnet test }     # JSON estrito em arquivo
icp -Format markdown { git diff --stat }                       # Markdown com cercas dinâmicas
icp -Step { git diff --stat; git commit -m "msg" }             # confirmação passo a passo
icp -AllowedExitCodes 1 { findstr /n "x" a.txt }               # exit=1 como OK (registra exit_permitido)
icp -Help -Full                                                # ajuda completa na TUI
```
