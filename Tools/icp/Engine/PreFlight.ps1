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

function Test-IcpInterativoDireto {
    # True se o statement pode invocar executável nativo ou script externo diretamente no console (sem pipe Out-Host).
    param($Ast, [bool]$EhNativo)
    if ($EhNativo) { return $true }
    if ($null -eq $Ast) { return $false }
    $cmds = $Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $cmds) {
        if ($c.InvocationOperator -in 'Dot', 'Ampersand' -and $c.CommandElements.Count -gt 0 -and
            $c.CommandElements[0] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
            return $true
        }
        $nome = $c.GetCommandName()
        if (-not $nome) { continue }
        if ($nome -match '\.ps1$' -or $nome -eq 'Start-Process') { return $true }
        $info = Get-Command $nome -ErrorAction Ignore | Select-Object -First 1
        if ($info -and $info.CommandType -eq 'ExternalScript') { return $true }
    }
    return $false
}

function Get-IcpStatementMeta {
    # Extrai metadados de comentários imediatamente anteriores (#* rótulo e #* interactive) alinhados a cada statement.
    param(
        [System.Management.Automation.Language.ScriptBlockAst]$Ast,
        [switch]$AllowPlainComments
    )
    if ($null -eq $Ast -or $null -eq $Ast.EndBlock) { return @() }
    $stmts = @($Ast.EndBlock.Statements)
    if ($stmts.Count -eq 0) { return @() }

    $astText = $Ast.Extent.Text
    $baseLine = $Ast.Extent.StartLineNumber
    $baseOffset = $Ast.Extent.StartOffset
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($astText, [ref]$tokens, [ref]$parseErrors)

    $commentsByLine = @{}
    foreach ($tok in @($tokens)) {
        if ($tok.Kind -ne 'Comment') { continue }
        if ($tok.Extent.StartLineNumber -ne $tok.Extent.EndLineNumber) { continue }
        if (-not $tok.Text.StartsWith('#')) { continue }
        $ln = $tok.Extent.StartLineNumber
        if (-not $commentsByLine.ContainsKey($ln)) {
            $commentsByLine[$ln] = [System.Collections.Generic.List[object]]::new()
        }
        $commentsByLine[$ln].Add($tok)
    }

    $metas = [System.Collections.Generic.List[object]]::new($stmts.Count)
    for ($i = 0; $i -lt $stmts.Count; $i++) {
        $st = $stmts[$i]
        $relStart = $st.Extent.StartOffset - $baseOffset
        $relLine = $st.Extent.StartLineNumber - $baseLine + 1
        $prevEnd = if ($i -gt 0) { $stmts[$i - 1].Extent.EndOffset - $baseOffset } else { -1 }
        $prevEndLine = if ($i -gt 0) { $stmts[$i - 1].Extent.EndLineNumber - $baseLine + 1 } else { 0 }

        $linhasCom = [System.Collections.Generic.List[string]]::new()
        $targetLine = $relLine - 1
        while ($targetLine -gt $prevEndLine) {
            if (-not $commentsByLine.ContainsKey($targetLine)) { break }
            $candidato = $null
            foreach ($ct in $commentsByLine[$targetLine]) {
                if ($ct.Extent.StartOffset -gt $prevEnd -and $ct.Extent.EndOffset -le $relStart) {
                    $candidato = $ct.Text
                }
            }
            if ($null -eq $candidato) { break }
            $linhasCom.Add($candidato)
            $targetLine--
        }

        $starRotulo = $null
        $plainRotulo = $null
        $interativo = $false
        for ($k = $linhasCom.Count - 1; $k -ge 0; $k--) {
            $txt = $linhasCom[$k]
            if ($txt -match '^#\*\s*interactive\s*$') {
                $interativo = $true
            }
            elseif ($txt -match '^#\*\s*interactive\s*[:\-]\s*(.+?)\s*$') {
                $interativo = $true
                $starRotulo = $Matches[1].Trim()
            }
            elseif ($txt -match '^#\*\s*\[interactive\]\s*(.*?)\s*$') {
                $interativo = $true
                if (-not [string]::IsNullOrWhiteSpace($Matches[1])) {
                    $starRotulo = $Matches[1].Trim()
                }
            }
            elseif ($txt -match '^#\*\s*(.+?)\s*$') {
                $starRotulo = $Matches[1].Trim()
            }
            elseif ($AllowPlainComments -and $txt -match '^#(?!\*)\s*(.+?)\s*$') {
                $plainRotulo = $Matches[1].Trim()
            }
        }

        $rotuloFinal = if (-not [string]::IsNullOrWhiteSpace($starRotulo)) {
            $starRotulo
        }
        elseif ($AllowPlainComments -and -not [string]::IsNullOrWhiteSpace($plainRotulo)) {
            $plainRotulo
        }
        else {
            $null
        }

        $metas.Add([pscustomobject]@{
            Rotulo     = $rotuloFinal
            Interativo = [bool]$interativo
        })
    }
    return $metas.ToArray()
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
