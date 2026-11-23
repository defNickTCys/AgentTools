function Test-IcpNativo {
    # True se o statement chama diretamente algum programa externo (.exe etc.).
    param($Ast)
    $cmds = $Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $cmds) {
        $nome = $c.GetCommandName()
        if (-not $nome) { continue }
        $info = Get-Command $nome -ErrorAction Ignore | Select-Object -First 1
        if ($info -and $info.CommandType -eq 'Application') { return $true }
    }
    return $false
}

function Test-IcpPodeForcarCorNativa {
    # True apenas para comando nativo isolado seguro para colorir na tela (respeita AGENTTOOLS_ICP_NOFORCECOLOR e exceções).
    param($Ast, [bool]$EhNativo)
    if (-not [string]::IsNullOrEmpty($env:AGENTTOOLS_ICP_NOFORCECOLOR)) { return $false }
    if (-not $EhNativo -or $null -eq $Ast) { return $false }
    if ($Ast -is [System.Management.Automation.Language.AssignmentStatementAst]) { return $false }
    if ($Ast -isnot [System.Management.Automation.Language.PipelineAst]) { return $false }
    if ($Ast.PipelineElements.Count -ne 1) { return $false }
    $redirs = $Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.RedirectionAst] }, $true)
    if ($redirs.Count -gt 0) { return $false }

    $cmdAst = $Ast.PipelineElements[0]
    if ($cmdAst -is [System.Management.Automation.Language.CommandAst] -and $cmdAst.CommandElements.Count -gt 0) {
        $elementos = @($cmdAst.CommandElements)
        $tokensArg = [System.Collections.Generic.List[string]]::new()
        for ($idx = 1; $idx -lt $elementos.Count; $idx++) {
            $el = $elementos[$idx]
            if ($el -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $txt = [string]$el.Value
            }
            elseif ($el -is [System.Management.Automation.Language.ConstantExpressionAst]) {
                $txt = [string]$el.Value
            }
            elseif ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
                $txt = $el.Extent.Text
                if ($null -ne $el.Argument -and
                    $el.Argument -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $el.Argument -isnot [System.Management.Automation.Language.ConstantExpressionAst]) {
                    return $false
                }
            }
            else {
                return $false
            }
            $tokensArg.Add($txt)
            if ($txt -cmatch '^(?i)--output(?:=|$)' -or $txt -cmatch '^(?i)--(?:no-color|color=never)$') {
                return $false
            }
        }
        $cmdNome = $cmdAst.GetCommandName()
        if ($cmdNome) {
            $baseNome = [System.IO.Path]::GetFileNameWithoutExtension($cmdNome)
            if ($baseNome -ieq 'git') {
                $flagsComValor = @('-C', '-c', '--git-dir', '--work-tree', '--namespace', '--config-env')
                $sub = $null
                $pularProx = $false
                foreach ($arg in $tokensArg) {
                    if ($pularProx) { $pularProx = $false; continue }
                    if ($arg -eq '--') { break }
                    if ($arg -in $flagsComValor) { $pularProx = $true; continue }
                    if ($arg.StartsWith('-')) { continue }
                    $sub = $arg
                    break
                }
                if ($sub -and ($sub.ToLowerInvariant() -in @('commit', 'am', 'rebase', 'format-patch', 'apply', 'merge', 'cherry-pick'))) {
                    return $false
                }
            }
        }
    }
    return $true
}

function Test-IcpPreVoo {
    # Validação pré-voo na AST antes de executar o 1º comando.
    # Devolve lista de diagnósticos (vazia se tudo OK).
    param($Ast, [switch]$AllowTrailingBackslash)
    $problemas = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Ast) { return $problemas }
    if ($null -ne $Ast.BeginBlock -or $null -ne $Ast.ProcessBlock) {
        $problemas.Add("Bloco contém 'begin' ou 'process', que o icp não executa; coloque todos os comandos diretamente no bloco principal.")
    }
    $temClean = ($null -ne $Ast.PSObject.Properties['CleanBlock']) -and ($null -ne $Ast.CleanBlock)
    if ($temClean -or $null -ne $Ast.DynamicParamBlock) {
        $problemas.Add("Bloco contém 'clean' ou 'dynamicparam', que o icp não executa; coloque todos os comandos diretamente no bloco principal.")
    }
    if ($null -ne $Ast.EndBlock) {
        $stmts = @($Ast.EndBlock.Statements)
        for ($i = 0; $i -lt $stmts.Count; $i++) {
            $st = $stmts[$i]
            $cmds = @($st.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true))

            if (-not $AllowTrailingBackslash) {
                foreach ($cmd in $cmds) {
                    if ($cmd.CommandElements.Count -eq 0) { continue }
                    $last = $cmd.CommandElements[-1]
                    if ($last -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                        $last.StringConstantType -eq 'BareWord' -and
                        $last.Value -eq '\') {
                        $noFimCmd = $last.Extent.EndOffset -eq $cmd.Extent.EndOffset
                        $pai = $cmd.Parent
                        $noFimPai = ($null -eq $pai) -or
                            ($last.Extent.EndOffset -eq $pai.Extent.EndOffset) -or
                            ($last.Extent.EndLineNumber -lt $pai.Extent.EndLineNumber)
                        if ($noFimCmd -and $noFimPai) {
                            $problemas.Add("Comando $($i + 1): barra invertida isolada '\' no fim da linha (em PowerShell '\' é argumento literal, não continuação de linha; use linha única ou backtick '``').")
                            break
                        }
                    }
                }
            }

            $soltoBreak = $false
            $soltoContinue = $false
            $saltos = @($st.FindAll({
                param($a)
                $a -is [System.Management.Automation.Language.BreakStatementAst] -or
                $a -is [System.Management.Automation.Language.ContinueStatementAst]
            }, $false))
            foreach ($salto in $saltos) {
                $dentroDeLaco = $false
                $cur = $salto.Parent
                while ($null -ne $cur -and $cur -ne $st.Parent) {
                    if ($cur -is [System.Management.Automation.Language.LoopStatementAst] -or
                        $cur -is [System.Management.Automation.Language.SwitchStatementAst]) {
                        $dentroDeLaco = $true
                        break
                    }
                    $cur = $cur.Parent
                }
                if (-not $dentroDeLaco) {
                    if ($salto -is [System.Management.Automation.Language.BreakStatementAst]) {
                        if (-not $soltoBreak) {
                            $soltoBreak = $true
                            $problemas.Add("Comando $($i + 1): 'break' fora de laço ou switch (interrompe o laço interno do icp e corrompe o relatório).")
                        }
                    }
                    elseif (-not $soltoContinue) {
                        $soltoContinue = $true
                        $problemas.Add("Comando $($i + 1): 'continue' fora de laço ou switch (interrompe o laço interno do icp e corrompe o relatório).")
                    }
                }
            }

            foreach ($cmd in $cmds) {
                if ($cmd.CommandElements.Count -eq 0) { continue }
                $first = $cmd.CommandElements[0]
                if ($first -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $first.StringConstantType -eq 'BareWord' -and
                    $first.Value -cmatch '^[A-Za-z_][A-Za-z0-9_]*=') {
                    $problemas.Add("Comando $($i + 1): sintaxe POSIX '$($first.Value)' como comando (no PowerShell defina variáveis de ambiente com `$env:NOME = 'valor' antes do comando).")
                    break
                }
            }
        }
    }
    return $problemas
}

function Get-IcpOrigemComando {
    # Identifica origem para a linha de status (script .ps1, sub-bloco, interno, nativo).
    param($Ast)
    if ($null -eq $Ast) { return '' }
    $cmds = $Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $cmds) {
        if ($c.InvocationOperator -in 'Dot', 'Ampersand' -and $c.CommandElements.Count -gt 0 -and
            $c.CommandElements[0] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
            return 'sub-bloco'
        }
        $nome = $c.GetCommandName()
        if (-not $nome) { continue }
        if ($nome -match '\.ps1$') { return "script: $([System.IO.Path]::GetFileName($nome))" }
        if ($nome -in 'Invoke-Command', 'Start-Job', 'Start-ThreadJob', 'Start-Process') { return "interno: $nome" }
        $info = Get-Command $nome -ErrorAction Ignore | Select-Object -First 1
        if ($info) {
            if ($info.CommandType -eq 'ExternalScript') { return "script: $($info.Name)" }
            if ($info.CommandType -eq 'Application') { return "nativo: $($info.Name)" }
        }
    }
    return ''
}
