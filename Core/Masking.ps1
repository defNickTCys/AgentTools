# Timeout padrão para regex de mascaramento (evita ReDoS/travamento em entradas atípicas).
$script:IcpRegexTimeout = [TimeSpan]::FromMilliseconds(500)

# Segredos ocultados no relatório: regex, substituição. A ordem importa: os
# formatos específicos vêm antes dos genéricos, e os genéricos pulam valor que já
# é marcador completo ([segredo ocultado: <tipo>]). Espaços com [ \t] para não atravessar linhas.
$script:IcpSegredos = @(
    ,@('-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----', '[segredo ocultado: chave-privada]')
    ,@('(?m)(?:^[A-Za-z0-9+/=]+[ \t]*\r?\n)*-----END [A-Z0-9 ]*PRIVATE KEY-----', '[segredo ocultado: chave-privada]')
    ,@('-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----(?![\s\S]*-----END [A-Z0-9 ]*PRIVATE KEY-----)[\s\S]*', '[segredo ocultado: chave-privada]')
    ,@('\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})', '[segredo ocultado: github]')
    ,@('\bsk-[A-Za-z0-9_-]{20,}', '[segredo ocultado: chave-sk]')
    ,@('\bnvapi-[A-Za-z0-9_-]{20,}', '[segredo ocultado: nvidia]')
    ,@('\bAKIA[0-9A-Z]{16}\b', '[segredo ocultado: aws]')
    ,@('\bxox[baprs]-[A-Za-z0-9-]{10,}', '[segredo ocultado: slack]')
    ,@('\bAIza[0-9A-Za-z_-]{35}', '[segredo ocultado: google]')
    ,@('\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}', '[segredo ocultado: jwt]')
    ,@('(?i)\b(Bearer[ \t]+)(?!\[segredo ocultado: [a-z-]+\](?:[\s,;"''\}\]\)]|$))[A-Za-z0-9._~+/-]{8,}=*', '$1[segredo ocultado: bearer]')
    ,@('(?i)\b((?:Proxy-)?Authorization(?:\\?["''])?[ \t]*:[ \t]*(?:\\?["''])?Basic[ \t]+)(?!\[segredo ocultado: [a-z-]+\](?:\\?["''])?(?:[\s,;\}\]\)]|$))[A-Za-z0-9+/=_-]{2,}', '$1[segredo ocultado: basic-auth]')
    ,@('(://[^\s:/@]+:)(?!\[segredo ocultado: [a-z-]+\](?:@|$))[^\s@/]+(?=@)', '$1[segredo ocultado: senha-url]')
    ,@('(?im)^((?:\[ERRO\] )?[A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD)[A-Z0-9_]*[ \t]{2,})(?!\[segredo ocultado: [a-z-]+\][ \t]*$)\S.*$', '$1[segredo ocultado: ambiente]')
    ,@('(?i)\b(?!(?:[\w.-]*(?:tokens(?:[_-](?:in|out|input|output|read|write|cached?|used|total|count|limit|max|min|per[_-]\w+|rate|cost|budget))?|token[_-](?:count|limit|max|min|total|used|usage|budget|rate|cost|ttl|expir\w*|len|length|size|window|price))|(?:has|is|use|enable|require|allow|with)[_-](?:password|passwd|secret|token|api[_-]?key|access[_-]?key))(?:\\?["''])?[ \t]*[:=])([\w.-]*(?:password|passwd|secret|token|api[_-]?key|access[_-]?key)[\w.-]*(?:\\?["''])?[ \t]*[:=][ \t]*)(?!\\?["'']?\[segredo ocultado: [a-z-]+\](?:\\?["''])?(?:[\s,;\}\]\)]|$))(?!\[\s*\])(?![$({\}\]])(?!(?:true|false|null|none|nil)(?:[\s,;"''\}\]\)]|$))(?!\\?["'']\\?["''](?:[\s,;\}\]\)]|$))(\\"(?:[^"\\\r\n]|\\\\\\"|\\\\\\\\|\\[^"\\\r\n])+\\"|"(?:[^"\\\r\n]|\\[^\r\n])+"|''[^''\r\n]+''|(?!\\?["''])(?:\[[^\]\r\n]*\][^\s,;"''\}\]\)]*|[^\s,;"''\}\]\)]+))', '$1[segredo ocultado: atribuicao]')
)

function Hide-IcpAtribuicaoSensivel {
    # Oculta o lado direito de AssignmentStatementAst com alvo sensível antes de entrar em <entrada>.
    param(
        $Ast,
        [string]$Text,
        [ref]$Contagem
    )
    if ($null -eq $Ast -or [string]::IsNullOrEmpty($Text)) { return $Text }
    $baseOff = $Ast.Extent.StartOffset
    $assigns = @($Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))
    if ($assigns.Count -eq 0) { return $Text }

    $sensivelRx = '(?i)(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|auth[_-]?key|client[_-]?secret|bearer|senha)'
    $excluirRx = '(?i)(?:tokens(?:[_-]|$)|token[_-]?(?:count|limit|max|min|total|used|usage|budget|rate|cost|ttl|expir|len|length|size|window|price)|^(?:\$?(?:has|is|use|enable|require|allow|with)[_-]))'
    $valorSeguroRx = '^(?:\$null|\$true|\$false|""|''''|@\{\s*\}|@\(\s*\)|\[segredo ocultado: [a-z-]+\])$'

    $spans = [System.Collections.Generic.List[object]]::new()
    foreach ($as in $assigns) {
        $esq = $as.Left.Extent.Text
        if ($esq -notmatch $sensivelRx) { continue }
        if ($esq -match $excluirRx) { continue }
        $dirText = $as.Right.Extent.Text
        if ([string]::IsNullOrWhiteSpace($dirText) -or $dirText.Trim() -match $valorSeguroRx) { continue }
        $relStart = $as.Right.Extent.StartOffset - $baseOff
        $relEnd = $as.Right.Extent.EndOffset - $baseOff
        if ($relStart -lt 0 -or $relEnd -gt $Text.Length -or $relStart -ge $relEnd) { continue }
        $spans.Add([pscustomobject]@{ Start = $relStart; End = $relEnd })
    }
    if ($spans.Count -eq 0) { return $Text }

    # Mantém apenas os spans mais externos caso haja atribuição sensível aninhada.
    $filtrados = [System.Collections.Generic.List[object]]::new()
    foreach ($sp in ($spans | Sort-Object Start, @{ Expression = 'End'; Descending = $true })) {
        $coberto = $false
        foreach ($ex in $filtrados) {
            if ($sp.Start -ge $ex.Start -and $sp.End -le $ex.End) {
                $coberto = $true
                break
            }
        }
        if (-not $coberto) { $filtrados.Add($sp) }
    }

    $res = $Text
    foreach ($sp in ($filtrados | Sort-Object Start -Descending)) {
        $res = $res.Substring(0, $sp.Start) + '[segredo ocultado: atribuicao]' + $res.Substring($sp.End)
        if ($null -ne $Contagem) { $Contagem.Value++ }
    }
    return $res
}

function Invoke-IcpRegexMaskPass {
    # Aplica uma regra de regex com MatchEvaluator e timeout, devolvendo contagem exata em uma única passagem.
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Replacement,
        [TimeSpan]$Timeout,
        [ref]$Contagem
    )
    $rx = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::None, $Timeout)
    $script:IcpMaskLocalHits = 0
    $script:IcpMaskReplacement = $Replacement
    $eval = [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $script:IcpMaskLocalHits++
        return $m.Result($script:IcpMaskReplacement)
    }
    $out = $rx.Replace($Text, $eval)
    $hits = $script:IcpMaskLocalHits
    if ($hits -gt 0 -and $null -ne $Contagem) { $Contagem.Value += $hits }
    return $out
}

function Hide-IcpSegredo {
    # Troca segredos conhecidos por marcador com timeout de regex (fail-closed); soma em $Contagem quantos trocou.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Só transforma texto; não altera estado do sistema.')]
    param(
        [string]$Text,
        [ref]$Contagem,
        [TimeSpan]$Timeout = $script:IcpRegexTimeout
    )
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    foreach ($p in $script:IcpSegredos) {
        try {
            $Text = Invoke-IcpRegexMaskPass -Text $Text -Pattern $p[0] -Replacement $p[1] -Timeout $Timeout -Contagem $Contagem
        }
        catch {
            $isTimeout = ($_.Exception -is [System.Text.RegularExpressions.RegexMatchTimeoutException]) -or
                ($null -ne $_.Exception.InnerException -and $_.Exception.InnerException -is [System.Text.RegularExpressions.RegexMatchTimeoutException])
            if (-not $isTimeout) { throw }

            $linhas = @([regex]::Split($Text, '(?<=\n)') | Where-Object { $_ -ne '' })
            if ($linhas.Count -le 1) {
                $eol = ''
                if ($Text.EndsWith("`r`n")) { $eol = "`r`n" }
                elseif ($Text.EndsWith("`n")) { $eol = "`n" }
                $Text = "[segredo ocultado: timeout-mascara]$eol"
                if ($null -ne $Contagem) { $Contagem.Value++ }
            }
            else {
                $sb = [System.Text.StringBuilder]::new($Text.Length)
                foreach ($ln in $linhas) {
                    try {
                        $lnMask = Invoke-IcpRegexMaskPass -Text $ln -Pattern $p[0] -Replacement $p[1] -Timeout $Timeout -Contagem $Contagem
                        [void]$sb.Append($lnMask)
                    }
                    catch {
                        $isLnTimeout = ($_.Exception -is [System.Text.RegularExpressions.RegexMatchTimeoutException]) -or
                            ($null -ne $_.Exception.InnerException -and $_.Exception.InnerException -is [System.Text.RegularExpressions.RegexMatchTimeoutException])
                        if (-not $isLnTimeout) { throw }
                        $eol = ''
                        if ($ln.EndsWith("`r`n")) { $eol = "`r`n" }
                        elseif ($ln.EndsWith("`n")) { $eol = "`n" }
                        [void]$sb.Append('[segredo ocultado: timeout-mascara]').Append($eol)
                        if ($null -ne $Contagem) { $Contagem.Value++ }
                    }
                }
                $Text = $sb.ToString()
            }
        }
    }
    return $Text
}
