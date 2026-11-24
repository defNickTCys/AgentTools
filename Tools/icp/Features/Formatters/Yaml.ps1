function Format-IcpYamlScalar {
    # Formata escalar YAML 1.2 seguro (null, booleanos, números e strings com escapes explícitos).
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } return 'false' }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or
        $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64] -or
        $Value -is [decimal] -or $Value -is [double] -or $Value -is [single]) {
        return [Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    $s = [string]$Value
    $sb = [System.Text.StringBuilder]::new($s.Length + 8)
    [void]$sb.Append('"')
    for ($i = 0; $i -lt $s.Length; $i++) {
        $ch = $s[$i]
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
                if ($code -lt 0x20 -or $code -eq 0x7F -or ($code -ge 0x80 -and $code -le 0x9F)) {
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

function Add-IcpYamlBlock {
    # Emite block scalar '|2-' para preservar espaços iniciais ou faz fallback para string citada em caracteres de controle.
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Indent,
        [string]$Key,
        [string[]]$Lines
    )
    $arr = if ($null -eq $Lines -or $Lines.Count -eq 0) { @('') } else { @($Lines) }
    $usarScalar = ($arr[-1] -eq '')
    if (-not $usarScalar) {
        foreach ($ln in $arr) {
            if ($null -eq $ln) { $usarScalar = $true; break }
            if ($ln -cmatch '[\x00-\x08\x0B-\x1F\x7F\x80-\x9F]') {
                $usarScalar = $true
                break
            }
        }
    }
    if ($usarScalar) {
        $List.Add("${Indent}${Key}: $(Format-IcpYamlScalar -Value ($arr -join "`n"))")
        return
    }
    $List.Add("${Indent}${Key}: |2-")
    $bodyIndent = "$Indent  "
    foreach ($ln in $arr) {
        if ($ln.Length -eq 0) {
            $List.Add('')
        }
        else {
            $List.Add("$bodyIndent$ln")
        }
    }
}

function Format-IcpReportYaml {
    # Serializa o modelo v2 em YAML 1.2 válido e compacto com block scalars '|2-'.
    param($Model, [switch]$Summary)

    $linhas = [System.Collections.Generic.List[string]]::new()
    $linhas.Add("versao: $($Model.versao)")
    $linhas.Add("versao_icp: $(Format-IcpYamlScalar -Value $Model.versao_icp)")
    $linhas.Add('formato: "yaml"')
    $linhas.Add("modo: $(Format-IcpYamlScalar -Value $Model.modo)")
    $linhas.Add("resultado: $(Format-IcpYamlScalar -Value $Model.resultado)")
    $linhas.Add("ms_total: $($Model.ms_total)")

    $flagsAtivos = @($Model.flags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($flagsAtivos.Count -eq 0) {
        $linhas.Add('flags: []')
    }
    else {
        $linhas.Add('flags:')
        foreach ($fl in $flagsAtivos) {
            $linhas.Add("  - $(Format-IcpYamlScalar -Value $fl)")
        }
    }
    if ($Summary) {
        $linhas.Add('completo: "arquivo"')
    }

    $avisoTxt = if ($Summary -and $Model.arquivo) { Get-IcpSummaryAvisoText -Model $Model } else { $Model.aviso }
    $linhas.Add("aviso: $(Format-IcpYamlScalar -Value $avisoTxt)")
    if ($Model.aviso_pre_voo) {
        $linhas.Add("aviso_pre_voo: $(Format-IcpYamlScalar -Value $Model.aviso_pre_voo)")
    }
    if ($Model.legenda) {
        $linhas.Add("legenda: $(Format-IcpYamlScalar -Value $Model.legenda)")
    }

    $linhas.Add('ambiente:')
    $linhas.Add("  diretorio: $(Format-IcpYamlScalar -Value $Model.ambiente.info.Diretorio)")
    $gitVal = if ($Model.ambiente.info.GitBranch) { $Model.ambiente.info.GitBranch } else { $null }
    $linhas.Add("  git_branch: $(Format-IcpYamlScalar -Value $gitVal)")
    $linhas.Add("  data: $(Format-IcpYamlScalar -Value $Model.ambiente.info.Data)")
    $linhas.Add("  fuso: $(Format-IcpYamlScalar -Value $Model.ambiente.info.Fuso)")
    $linhas.Add("  pwd_env_definido: $(Format-IcpYamlScalar -Value ([bool]$Model.ambiente.info.PwdEnvDefinido))")
    $linhas.Add('  mascara:')
    $linhas.Add("    ligada: $(Format-IcpYamlScalar -Value ([bool]$Model.ambiente.mascara))")
    $linhas.Add("    trechos_ocultados: $([int]$Model.ambiente.ocultos)")
    if ($Model.explain) {
        $linhas.Add("  powershell: $(Format-IcpYamlScalar -Value $Model.ambiente.info.PowerShell)")
        $linhas.Add("  windows: $(Format-IcpYamlScalar -Value $Model.ambiente.info.Windows)")
        $linhas.Add("  cultura: $(Format-IcpYamlScalar -Value $Model.ambiente.info.Cultura)")
        $linhas.Add("  admin: $(Format-IcpYamlScalar -Value ([bool]$Model.ambiente.info.Admin))")
    }

    $linhas.Add('resumo:')
    $linhas.Add("  total: $($Model.resumo.total)")
    $linhas.Add("  executados: $($Model.resumo.executados)")
    $linhas.Add("  ok: $($Model.resumo.ok)")
    $linhas.Add("  falharam: $($Model.resumo.falharam)")
    $linhas.Add("  nao_executados: $($Model.resumo.nao_executados)")
    if ($Model.resumo.Contains('interrompidos') -and $Model.resumo.interrompidos -gt 0) {
        $linhas.Add("  interrompidos: $($Model.resumo.interrompidos)")
    }

    if ($Model.PSObject.Properties['truncado_teto'] -and $Model.truncado_teto) {
        $linhas.Add('truncado_teto: true')
    }
    if ($Model.PSObject.Properties['comandos_omitidos'] -and $Model.comandos_omitidos -gt 0) {
        $linhas.Add("comandos_omitidos: $([int]$Model.comandos_omitidos)")
    }

    $cmds = @($Model.comandos)
    if ($cmds.Count -eq 0) {
        $linhas.Add('comandos: []')
    }
    else {
        $linhas.Add('comandos:')
        foreach ($c in $cmds) {
            $linhas.Add("  - n: $($c.n)")
            $linhas.Add("    status: $(Format-IcpYamlScalar -Value $c.status)")
            if (-not [string]::IsNullOrWhiteSpace($c.rotulo)) {
                $linhas.Add("    rotulo: $(Format-IcpYamlScalar -Value $c.rotulo)")
            }
            if ($c.status -eq 'NAO_EXECUTADO') {
                $entTxt = if ($Summary) { [string]$c.entrada_resumo } else { [string]$c.entrada }
                $entLines = @($entTxt -split '\r?\n')
                if ($entLines.Count -gt 1) {
                    Add-IcpYamlBlock -List $linhas -Indent '    ' -Key 'entrada' -Lines $entLines
                }
                else {
                    $linhas.Add("    entrada: $(Format-IcpYamlScalar -Value $entTxt)")
                }
                continue
            }

            if ($c.interativo) { $linhas.Add('    interativo: true') }
            $linhas.Add("    ms: $($c.ms)")
            if ($null -ne $c.exit) { $linhas.Add("    exit: $($c.exit)") }
            if ($c.exit_permitido) { $linhas.Add('    exit_permitido: true') }
            if ($c.silenciosos -gt 0) { $linhas.Add("    silenciosos: $($c.silenciosos)") }
            $spItens = @($c.segundo_plano | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($spItens.Count -gt 0) {
                $linhas.Add('    segundo_plano:')
                foreach ($sp in $spItens) { $linhas.Add("      - $(Format-IcpYamlScalar -Value $sp)") }
            }
            $filhoItens = @($c.filho | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($filhoItens.Count -gt 0) {
                $linhas.Add('    filho:')
                foreach ($fh in $filhoItens) { $linhas.Add("      - $(Format-IcpYamlScalar -Value $fh)") }
            }
            if ($null -ne $c.sem_saida_s) {
                $linhas.Add("    sem_saida_s: $([int]$c.sem_saida_s)")
            }

            if ($Summary) {
                $linhas.Add("    linhas: $($c.linhas)")
                $linhas.Add("    chars: $($c.chars)")
                $linhas.Add("    entrada: $(Format-IcpYamlScalar -Value $c.entrada_resumo)")
                if ($c.status -in 'FALHOU', 'INTERROMPIDO' -and $c.erro_resumo.Count -gt 0) {
                    $linhas.Add('    erro:')
                    foreach ($er in @($c.erro_resumo)) { $linhas.Add("      - $(Format-IcpYamlScalar -Value $er)") }
                }
                elseif ($c.status -eq 'OK' -and -not [string]::IsNullOrEmpty($c.previa)) {
                    $linhas.Add("    previa: $(Format-IcpYamlScalar -Value $c.previa)")
                }
            }
            else {
                $entTxt = [string]$c.entrada
                $entLines = @($entTxt -split '\r?\n')
                if ($entLines.Count -gt 1) {
                    Add-IcpYamlBlock -List $linhas -Indent '    ' -Key 'entrada' -Lines $entLines
                }
                else {
                    $linhas.Add("    entrada: $(Format-IcpYamlScalar -Value $entTxt)")
                }
                if ($c.atribuicao) {
                    $linhas.Add("    atribuicao: $(Format-IcpYamlScalar -Value $c.atribuicao)")
                }
                $saidaCorpo = if ($c.saida.Count -eq 0) { @('[Sem saída]') } else { @($c.saida) }
                Add-IcpYamlBlock -List $linhas -Indent '    ' -Key 'saida' -Lines $saidaCorpo
            }
        }
    }

    if ($Summary -and $Model.arquivo) {
        $linhas.Add('arquivo:')
        $linhas.Add("  caminho: $(Format-IcpYamlScalar -Value $Model.arquivo.caminho)")
        $linhas.Add("  formato: $(Format-IcpYamlScalar -Value $Model.arquivo.formato)")
        $linhas.Add("  chars: $($Model.arquivo.chars)")
        $linhas.Add("  bytes: $($Model.arquivo.bytes)")
        $linhas.Add("  truncado_teto: $(Format-IcpYamlScalar -Value ([bool]$Model.arquivo.truncado_teto))")
    }

    return ($linhas -join "`r`n")
}
