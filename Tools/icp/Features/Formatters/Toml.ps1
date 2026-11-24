function Format-IcpTomlString {
    # Formata string básica TOML 1.0 de uma linha com escapes completos.
    param([string]$Value)
    if ($null -eq $Value) { $Value = '' }
    $sb = [System.Text.StringBuilder]::new($Value.Length + 8)
    [void]$sb.Append('"')
    for ($i = 0; $i -lt $Value.Length; $i++) {
        $ch = $Value[$i]
        $code = [int][char]$ch
        switch ($code) {
            0x22 { [void]$sb.Append('\"') }
            0x5C { [void]$sb.Append('\\') }
            0x08 { [void]$sb.Append('\b') }
            0x09 { [void]$sb.Append('\t') }
            0x0A { [void]$sb.Append('\n') }
            0x0C { [void]$sb.Append('\f') }
            0x0D { [void]$sb.Append('\r') }
            default {
                if ($code -lt 0x20 -or $code -eq 0x7F) {
                    [void]$sb.Append('\u').Append($code.ToString('x4', [System.Globalization.CultureInfo]::InvariantCulture))
                }
                else {
                    [void]$sb.Append($ch)
                }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Format-IcpTomlMultilineString {
    # Formata string básica multilinhas TOML 1.0 ("""...""") escapando sequências de 3+ aspas, aspa final e barras.
    param([string[]]$Lines)
    $arr = if ($null -eq $Lines -or $Lines.Count -eq 0) { @('') } else { @($Lines) }
    $joined = ($arr -join "`n") -replace '\r\n', "`n"
    $sb = [System.Text.StringBuilder]::new($joined.Length + 16)
    [void]$sb.Append('"""').Append("`r`n")
    $quoteRun = 0
    $n = $joined.Length
    for ($i = 0; $i -lt $n; $i++) {
        $ch = $joined[$i]
        $code = [int][char]$ch
        if ($code -eq 0x22) {
            if ($quoteRun -ge 2 -or $i -eq ($n - 1)) {
                [void]$sb.Append('\"')
                $quoteRun = 0
            }
            else {
                [void]$sb.Append('"')
                $quoteRun++
            }
            continue
        }
        $quoteRun = 0
        switch ($code) {
            0x5C { [void]$sb.Append('\\') }
            0x08 { [void]$sb.Append('\b') }
            0x09 { [void]$sb.Append("`t") }
            0x0A { [void]$sb.Append("`r`n") }
            0x0C { [void]$sb.Append('\f') }
            0x0D { [void]$sb.Append('\r') }
            default {
                if ($code -lt 0x20 -or $code -eq 0x7F) {
                    [void]$sb.Append('\u').Append($code.ToString('x4', [System.Globalization.CultureInfo]::InvariantCulture))
                }
                else {
                    [void]$sb.Append($ch)
                }
            }
        }
    }
    [void]$sb.Append('"""')
    return $sb.ToString()
}

function Format-IcpReportToml {
    # Serializa o modelo v2 em TOML 1.0 estrito (chaves raiz antes de tabelas; campos nulos omitidos).
    param($Model, [switch]$Summary)

    $linhas = [System.Collections.Generic.List[string]]::new()
    $linhas.Add("versao = $($Model.versao)")
    $linhas.Add("versao_icp = $(Format-IcpTomlString -Value $Model.versao_icp)")
    $linhas.Add('formato = "toml"')
    $linhas.Add("modo = $(Format-IcpTomlString -Value $Model.modo)")
    $linhas.Add("resultado = $(Format-IcpTomlString -Value $Model.resultado)")
    $linhas.Add("ms_total = $($Model.ms_total)")

    $flagsAtivos = @($Model.flags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Format-IcpTomlString -Value $_ })
    $linhas.Add("flags = [$($flagsAtivos -join ', ')]")

    if ($Summary) {
        $linhas.Add('completo = "arquivo"')
    }

    $avisoTxt = if ($Summary -and $Model.arquivo) { Get-IcpSummaryAvisoText -Model $Model } else { $Model.aviso }
    $linhas.Add("aviso = $(Format-IcpTomlString -Value $avisoTxt)")
    if ($Model.aviso_pre_voo) {
        $linhas.Add("aviso_pre_voo = $(Format-IcpTomlString -Value $Model.aviso_pre_voo)")
    }
    if ($Model.legenda) {
        $linhas.Add("legenda = $(Format-IcpTomlString -Value $Model.legenda)")
    }
    if ($Model.PSObject.Properties['truncado_teto'] -and $Model.truncado_teto) {
        $linhas.Add('truncado_teto = true')
    }
    if ($Model.PSObject.Properties['comandos_omitidos'] -and $Model.comandos_omitidos -gt 0) {
        $linhas.Add("comandos_omitidos = $([int]$Model.comandos_omitidos)")
    }

    $cmds = @($Model.comandos)
    if ($cmds.Count -eq 0) {
        $linhas.Add('comandos = []')
    }

    $linhas.Add('')
    $linhas.Add('[ambiente]')
    $linhas.Add("diretorio = $(Format-IcpTomlString -Value $Model.ambiente.info.Diretorio)")
    if (-not [string]::IsNullOrEmpty($Model.ambiente.info.GitBranch)) {
        $linhas.Add("git_branch = $(Format-IcpTomlString -Value $Model.ambiente.info.GitBranch)")
    }
    $linhas.Add("data = $(Format-IcpTomlString -Value $Model.ambiente.info.Data)")
    $linhas.Add("fuso = $(Format-IcpTomlString -Value $Model.ambiente.info.Fuso)")
    $linhas.Add("pwd_env_definido = $(if ($Model.ambiente.info.PwdEnvDefinido) { 'true' } else { 'false' })")
    if ($Model.explain) {
        $linhas.Add("powershell = $(Format-IcpTomlString -Value $Model.ambiente.info.PowerShell)")
        $linhas.Add("windows = $(Format-IcpTomlString -Value $Model.ambiente.info.Windows)")
        $linhas.Add("cultura = $(Format-IcpTomlString -Value $Model.ambiente.info.Cultura)")
        $linhas.Add("admin = $(if ($Model.ambiente.info.Admin) { 'true' } else { 'false' })")
    }

    $linhas.Add('')
    $linhas.Add('[ambiente.mascara]')
    $linhas.Add("ligada = $(if ($Model.ambiente.mascara) { 'true' } else { 'false' })")
    $linhas.Add("trechos_ocultados = $([int]$Model.ambiente.ocultos)")

    $linhas.Add('')
    $linhas.Add('[resumo]')
    $linhas.Add("total = $($Model.resumo.total)")
    $linhas.Add("executados = $($Model.resumo.executados)")
    $linhas.Add("ok = $($Model.resumo.ok)")
    $linhas.Add("falharam = $($Model.resumo.falharam)")
    $linhas.Add("nao_executados = $($Model.resumo.nao_executados)")
    if ($Model.resumo.Contains('interrompidos') -and $Model.resumo.interrompidos -gt 0) {
        $linhas.Add("interrompidos = $($Model.resumo.interrompidos)")
    }

    if ($Summary -and $Model.arquivo) {
        $linhas.Add('')
        $linhas.Add('[arquivo]')
        $linhas.Add("caminho = $(Format-IcpTomlString -Value $Model.arquivo.caminho)")
        $linhas.Add("formato = $(Format-IcpTomlString -Value $Model.arquivo.formato)")
        $linhas.Add("chars = $($Model.arquivo.chars)")
        $linhas.Add("bytes = $($Model.arquivo.bytes)")
        $linhas.Add("truncado_teto = $(if ($Model.arquivo.truncado_teto) { 'true' } else { 'false' })")
    }

    foreach ($c in $cmds) {
        $linhas.Add('')
        $linhas.Add('[[comandos]]')
        $linhas.Add("n = $($c.n)")
        $linhas.Add("status = $(Format-IcpTomlString -Value $c.status)")
        if (-not [string]::IsNullOrWhiteSpace($c.rotulo)) {
            $linhas.Add("rotulo = $(Format-IcpTomlString -Value $c.rotulo)")
        }
        if ($c.status -eq 'NAO_EXECUTADO') {
            $entTxt = if ($Summary) { [string]$c.entrada_resumo } else { [string]$c.entrada }
            $entLines = @($entTxt -split '\r?\n')
            if ($entLines.Count -gt 1) {
                $linhas.Add("entrada = $(Format-IcpTomlMultilineString -Lines $entLines)")
            }
            else {
                $linhas.Add("entrada = $(Format-IcpTomlString -Value $entTxt)")
            }
            continue
        }

        if ($c.interativo) { $linhas.Add('interativo = true') }
        $linhas.Add("ms = $($c.ms)")
        if ($null -ne $c.exit) { $linhas.Add("exit = $($c.exit)") }
        if ($c.exit_permitido) { $linhas.Add('exit_permitido = true') }
        if ($c.silenciosos -gt 0) { $linhas.Add("silenciosos = $($c.silenciosos)") }
        $spItens = @($c.segundo_plano | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Format-IcpTomlString -Value $_ })
        if ($spItens.Count -gt 0) { $linhas.Add("segundo_plano = [$($spItens -join ', ')]") }
        $filhoItens = @($c.filho | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Format-IcpTomlString -Value $_ })
        if ($filhoItens.Count -gt 0) { $linhas.Add("filho = [$($filhoItens -join ', ')]") }
        if ($null -ne $c.sem_saida_s) { $linhas.Add("sem_saida_s = $([int]$c.sem_saida_s)") }

        if ($Summary) {
            $linhas.Add("linhas = $($c.linhas)")
            $linhas.Add("chars = $($c.chars)")
            $linhas.Add("entrada = $(Format-IcpTomlString -Value $c.entrada_resumo)")
            if ($c.status -in 'FALHOU', 'INTERROMPIDO' -and $c.erro_resumo.Count -gt 0) {
                $erFmt = @($c.erro_resumo | ForEach-Object { Format-IcpTomlString -Value $_ })
                $linhas.Add("erro = [$($erFmt -join ', ')]")
            }
            elseif ($c.status -eq 'OK' -and -not [string]::IsNullOrEmpty($c.previa)) {
                $linhas.Add("previa = $(Format-IcpTomlString -Value $c.previa)")
            }
        }
        else {
            $entTxt = [string]$c.entrada
            $entLines = @($entTxt -split '\r?\n')
            if ($entLines.Count -gt 1) {
                $linhas.Add("entrada = $(Format-IcpTomlMultilineString -Lines $entLines)")
            }
            else {
                $linhas.Add("entrada = $(Format-IcpTomlString -Value $entTxt)")
            }
            if ($c.atribuicao) {
                $linhas.Add("atribuicao = $(Format-IcpTomlString -Value $c.atribuicao)")
            }
            $saidaCorpo = if ($c.saida.Count -eq 0) { @('[Sem saída]') } else { @($c.saida) }
            $linhas.Add("saida = $(Format-IcpTomlMultilineString -Lines $saidaCorpo)")
        }
    }

    return ($linhas -join "`r`n")
}
