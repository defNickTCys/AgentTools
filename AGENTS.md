# AGENTS.md: guia de contribuição e de agentes do AgentTools

`AgentTools` é um módulo PowerShell 7.2+ que exporta a função `icp`. Este guia vale para pessoas e para agentes de IA que contribuem com o repositório. Responda e documente em português do Brasil com acentos.

## Comandos

Rode sempre em um processo limpo (`pwsh -NoProfile -NoLogo`), na raiz do repositório.

| Intenção | Comando |
|---|---|
| Validar o manifesto | `Test-ModuleManifest .\AgentTools.psd1` |
| Testes unitários | `Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path .\Tests -Output None -PassThru` |
| Análise estática | `Invoke-ScriptAnalyzer -ScriptDefinition <código>` (rode regra por regra) |

Use `-Path` no Pester para não executar cópias dos testes fora de `Tests/`. Imprima apenas `Result`, as contagens e os testes que falharam.

## Convenções

### Arquitetura

- `Core/`: núcleo compartilhado (`Loader`, `Masking`, `Theme`, `Terminal`, `Process`).
- `Tools/<nome>/`: ferramentas isoladas, carregadas sob demanda (hoje, `icp`).
- `Tests/`: testes Pester.
- `AgentTools.psd1` é o manifesto e `AgentTools.psm1` é o módulo raiz.

### Arquivos, codificação e quebras de linha

| Arquivos | Codificação | Quebra de linha |
|---|---|---|
| `.ps1`, `.psm1`, `.psd1` | UTF-8 com BOM | CRLF |
| `.md` (exceto `AGENTS.md`) | UTF-8 sem BOM | CRLF |
| `AGENTS.md`, `LICENSE`, `.gitattributes`, `.gitignore`, `*.yml` | UTF-8 sem BOM | LF |

Confira BOM e quebras de linha antes e depois de editar.

### Testes

- Rode os testes sempre em `pwsh -NoProfile -NoLogo`, nunca na sessão interativa.
- Use mock de `Set-Clipboard`; nunca sobrescreva a área de transferência real.
- Grave arquivos temporários apenas em `$env:TEMP`.
- Com Pester 5 ou superior, use `Should -Invoke` e mocks sem filtro.

### API pública

Preserve as assinaturas públicas da `icp`: `icp { ... }` continua válido, com `$ScriptBlock` na posição 0. Parâmetros novos devem ser opcionais, nomeados e com valor padrão, e a ajuda `.PARAMETER` precisa ser atualizada.

### Autoria e rastreio

- `Author` e `Committer` são sempre a conta do mantenedor (`defNickTCys`, com o e-mail `noreply` do GitHub).
- O rastreio de quem contribuiu fica nos *Git trailers* `Actor`, `Agent-Role`, `Agent-Model` e `Reviewed-By-Model`, no template de PR (`.github/pull_request_template.md`) e nos *labels* `actor:*`, `review:*` e `area:*`.
- Mensagens de commit em português, no formato `TASK-NNN Un: descrição`.

## Segurança

- Não grave chaves, senhas, e-mails pessoais nem caminhos de usuário local em arquivos do repositório.
- Não use `git reset --hard`, `git clean` ou `--force` sem autorização.
- Não faça push direto na `main`; use branch e PR com CI verde.
