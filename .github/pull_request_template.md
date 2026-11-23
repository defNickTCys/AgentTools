## Resumo e Escopo

Descreva em poucas linhas o que muda e por quê. Liste o que fica fora do escopo.

## Autoria e Rastreio

| Papel (Operador / Orquestrador / Subagente) | Modelo / Conexão | Escopo da contribuição |
|---|---|---|
| Operador | | |
| Orquestrador | | |
| Subagente | | |

> O `Author` e o `Committer` dos commits são sempre a conta do mantenedor. O rastreio de quem fez o quê fica nos *Git trailers* `Actor`, `Agent-Role`, `Agent-Model` e `Reviewed-By-Model`, e nos *labels* `actor:*`, `review:*` e `area:*` deste PR.

## Verificações Executadas

- [ ] `Test-ModuleManifest .\AgentTools.psd1`
- [ ] `Invoke-Pester -Path .\Tests` (em `pwsh -NoProfile -NoLogo`)
- [ ] `Invoke-ScriptAnalyzer` em todas as regras, sem achados
- [ ] Conferência de BOM e EOL dos arquivos alterados

Cole abaixo as contagens e saídas objetivas. Registre o que não foi executado.

## Riscos, Decisões e Pendências

- Riscos:
- Decisões:
- Pendências:
