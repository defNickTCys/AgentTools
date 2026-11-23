# AgentTools 1.0.0

AgentTools é um módulo para PowerShell no Windows. Seu comando público, `icp`, executa cada comando de um bloco uma vez, em sequência, e para na primeira falha por padrão. Ele mostra o andamento no terminal e gera um relatório estruturado para compartilhar ou analisar em scripts.

## Requisitos

- Windows 11.
- PowerShell 7.2 ou superior (`pwsh`).
- Git para clonar o repositório e Pester 5 ou superior para rodar os testes.

## Instalação rápida

Clone o repositório em uma pasta chamada `AgentTools` dentro de um diretório listado em `$env:PSModulePath`. Para listar esses diretórios, rode `$env:PSModulePath -split [IO.Path]::PathSeparator`. O exemplo abaixo usa o diretório de módulos do usuário, dentro de `Documents\PowerShell\Modules`.

```powershell
$modulos = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'
New-Item -ItemType Directory -Path $modulos -Force | Out-Null
$destino = Join-Path $modulos 'AgentTools'
git clone https://github.com/defNickTCys/AgentTools.git $destino
Import-Module AgentTools
icp -Help
```

Se você já mantém uma cópia do repositório em outro local, abra o PowerShell na raiz dessa cópia e crie uma *junction* NTFS, um vínculo de diretório que faz a cópia aparecer no caminho de módulos. O destino `Documents\PowerShell\Modules\AgentTools` precisa estar livre.

```powershell
$origem = (Get-Location).Path
$modulos = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'
New-Item -ItemType Directory -Path $modulos -Force | Out-Null
$destino = Join-Path $modulos 'AgentTools'
New-Item -ItemType Junction -Path $destino -Target $origem | Out-Null
Import-Module AgentTools
```

## Uso

```powershell
icp { Get-Location; Get-ChildItem -Name }
icp -Format json -OutFile .\relatorio.json { Get-Location }
icp -Help -Full
```

Em um terminal interativo, `icp` sem argumentos abre o compositor para editar o bloco linha a linha. Antes de executar, o pré-voo inspeciona a estrutura dos comandos e bloqueia construções incompatíveis. Os comandos de um bloco compartilham um escopo isolado do motor de execução.

## Arquitetura

- `AgentTools.psd1` declara os metadados do módulo e exporta `icp`. `AgentTools.psm1` carrega o núcleo e o ponto de entrada da ferramenta.
- `Core/` reúne carregamento, ocultação de segredos, temas, controle do terminal e inspeção de processos.
- `Tools/<nome>/` contém as ferramentas isoladas. O motor de `icp` é carregado na primeira chamada que precisa dele. [Guia da ferramenta](Tools/icp/README.md)

## Parâmetros do `icp`

| Parâmetro | Padrão | Comportamento |
|---|---|---|
| `-ScriptBlock` | Obrigatório para execução | Bloco `{ ... }` na posição 0. Em terminal interativo, `icp` sem argumentos abre o compositor. |
| `-Format` | `xml` | Seleciona `xml`, `json` ou `markdown`. |
| `-Explain` | Desligado | Inclui legenda, aviso e ambiente detalhados. |
| `-Step` | Desligado | Em terminal interativo, pede confirmação antes de passar ao próximo comando. |
| `-ContinueOnError` | Desligado | Executa os comandos seguintes após uma falha. |
| `-AllowedExitCodes` | `@()` | Aceita os códigos de saída nativos informados e registra `exit` e `exit_permitido`. |
| `-Raw` | Desligado | Desativa deduplicação e cortes de linhas e largura no relatório. |
| `-MaxLinesPerCommand` | `150` (mínimo `10`) | Limita as linhas de saída de cada comando no relatório. |
| `-MaxLineLength` | `1500` (mínimo `80`) | Limita o comprimento de cada linha do relatório. |
| `-MaxClipboardChars` | `20000` (mínimo `1`) | Acima do limite, grava o relatório em `icp-logs` e copia um resumo com o caminho. A retenção dos arquivos é de sete dias. |
| `-RedirectTailLines` | `5` (`0` desliga) | Inclui as linhas finais dos arquivos de saída redirecionada. |
| `-OutFile` | Vazio | Grava o relatório completo em UTF-8 sem BOM e dispensa a área de transferência. |
| `-NoClipboard` | Desligado | Dispensa a cópia para a área de transferência. |
| `-NoMask` | Desligado | Desativa a ocultação automática de segredos no relatório. |
| `-AllowTrailingBackslash` | Desligado | Permite uma barra invertida isolada no fim do comando. |
| `-CommandTimeoutSeconds` | `0` (desligado) | Ao atingir o limite, encerra processos filhos iniciados pelo comando e registra falha. |
| `-KeepBlock` | Desligado | Mantém o bloco digitado visível no terminal. |
| `-NoStatus` | Desligado | Desativa a barra de status e o recolhimento do bloco. |
| `-Help` | Desligado | Exibe a ajuda visual. Aceita a abreviação `-h`. |
| `-Full` | Desligado | Amplia a referência exibida por `-Help`. |
| `-Demo` | Desligado | Exibe uma demonstração animada da barra com `-Help`. |

## Contrato do relatório

O contrato `versao="2"` registra o resultado do bloco, o estado de cada comando, a duração total e os diagnósticos, como erros silenciosos, processos filhos ativos e códigos de saída permitidos. A versão do módulo que gerou o relatório aparece em `versao_icp`.

- **XML** é o padrão e oferece saída compacta para compartilhar.
- **JSON** fornece dados estruturados para leitura em scripts.
- **Markdown** organiza o resultado para leitura direta e usa cercas de código ajustadas ao conteúdo.

O conteúdo capturado na saída dos comandos é dado bruto. Consulte os campos de cada formato e as regras de resumo e truncamento no [contrato do relatório](Tools/icp/Contracts/REPORT_CONTRACT.md).

## Verificação

Na raiz do repositório, em um processo limpo iniciado com `pwsh -NoProfile -NoLogo`, execute:

```powershell
Test-ModuleManifest .\AgentTools.psd1
Import-Module Pester -MinimumVersion 5.0
Invoke-Pester -Path .\Tests
```

## Contribuição e autoria

Abra uma branch de tarefa e use o [template de pull request](.github/pull_request_template.md) para registrar escopo e verificações. Escreva mensagens de commit em português no formato `TASK-NNN Un: descrição`.

`Author` e `Committer` identificam a conta do mantenedor, `defNickTCys`, com o e-mail `noreply` do GitHub. Registre a participação de pessoas e agentes nos *Git trailers*, campos no rodapé da mensagem de commit, com `Actor`, `Agent-Role`, `Agent-Model` e `Reviewed-By-Model`. Use os rótulos `actor:*`, `review:*` e `area:*` no PR. [Guia de contribuição](AGENTS.md)

## Licença

O AgentTools é distribuído sob a [licença MIT](LICENSE).
