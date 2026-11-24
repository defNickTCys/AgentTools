function Format-IcpReportJson {
    # Serializa o modelo v2 como JSON estrito (-Depth 10) para parsing automatizado.
    param($Model, [switch]$Summary, [switch]$Compress)

    $ambObj = [ordered]@{
        diretorio = $Model.ambiente.info.Diretorio
        git_branch = if ($Model.ambiente.info.GitBranch) { $Model.ambiente.info.GitBranch } else { $null }
        data = $Model.ambiente.info.Data
        fuso = $Model.ambiente.info.Fuso
        pwd_env_definido = $Model.ambiente.info.PwdEnvDefinido
        mascara = [ordered]@{
            ligada = $Model.ambiente.mascara
            trechos_ocultados = $Model.ambiente.ocultos
        }
    }
    if ($Model.explain) {
        $ambObj['powershell'] = $Model.ambiente.info.PowerShell
        $ambObj['windows'] = $Model.ambiente.info.Windows
        $ambObj['cultura'] = $Model.ambiente.info.Cultura
        $ambObj['admin'] = $Model.ambiente.info.Admin
    }

    $cmdsOut = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $Model.comandos) {
        $item = [ordered]@{
            n      = $c.n
            status = $c.status
        }
        if (-not [string]::IsNullOrWhiteSpace($c.rotulo)) { $item['rotulo'] = $c.rotulo }
        if ($c.status -eq 'NAO_EXECUTADO') {
            $item['entrada'] = if ($Summary) { $c.entrada_resumo } else { $c.entrada }
            $cmdsOut.Add($item)
            continue
        }
        if ($c.interativo) { $item['interativo'] = $true }
        $item['ms'] = $c.ms
        if ($null -ne $c.exit) { $item['exit'] = $c.exit }
        if ($c.exit_permitido) { $item['exit_permitido'] = $true }
        if ($c.silenciosos -gt 0) { $item['silenciosos'] = $c.silenciosos }
        if ($c.segundo_plano.Count -gt 0) { $item['segundo_plano'] = [string[]]@($c.segundo_plano) }
        if ($null -ne $c.filho -and $c.filho.Count -gt 0) { $item['filho'] = [string[]]@($c.filho) }
        if ($null -ne $c.sem_saida_s) { $item['sem_saida_s'] = [int]$c.sem_saida_s }

        if ($Summary) {
            $item['linhas'] = $c.linhas
            $item['chars'] = $c.chars
            $item['entrada'] = $c.entrada_resumo
            if ($c.status -in 'FALHOU', 'INTERROMPIDO' -and $c.erro_resumo.Count -gt 0) {
                $erroList = [System.Collections.Generic.List[string]]::new()
                foreach ($er in @($c.erro_resumo)) { $erroList.Add([string]$er) }
                $item['erro'] = $erroList.ToArray()
            }
            elseif ($c.status -eq 'OK' -and -not [string]::IsNullOrEmpty($c.previa)) {
                $item['previa'] = $c.previa
            }
        }
        else {
            $item['entrada'] = $c.entrada
            if ($c.atribuicao) { $item['atribuicao'] = $c.atribuicao }
            $saidaList = [System.Collections.Generic.List[string]]::new()
            if ($c.saida.Count -eq 0) {
                $saidaList.Add('[Sem saída]')
            }
            else {
                foreach ($sl in @($c.saida)) { $saidaList.Add([string]$sl) }
            }
            $item['saida'] = $saidaList.ToArray()
        }
        $cmdsOut.Add($item)
    }

    $avisoTxt = if ($Summary -and $Model.arquivo) { Get-IcpSummaryAvisoText -Model $Model } else { $Model.aviso }
    $flagsList = [System.Collections.Generic.List[string]]::new()
    foreach ($fl in @($Model.flags)) { $flagsList.Add([string]$fl) }
    $doc = [ordered]@{
        versao     = $Model.versao
        versao_icp = $Model.versao_icp
        formato    = 'json'
        modo       = $Model.modo
        resultado  = $Model.resultado
        ms_total   = $Model.ms_total
        flags      = $flagsList.ToArray()
    }
    if ($Summary) { $doc['completo'] = 'arquivo' }
    $doc['aviso'] = $avisoTxt
    if ($Model.aviso_pre_voo) { $doc['aviso_pre_voo'] = $Model.aviso_pre_voo }
    if ($Model.legenda) { $doc['legenda'] = $Model.legenda }
    $doc['ambiente'] = $ambObj
    $doc['resumo'] = $Model.resumo
    if ($Model.PSObject.Properties['truncado_teto'] -and $Model.truncado_teto) {
        $doc['truncado_teto'] = $true
    }
    if ($Model.PSObject.Properties['comandos_omitidos'] -and $Model.comandos_omitidos -gt 0) {
        $doc['comandos_omitidos'] = [int]$Model.comandos_omitidos
    }
    $doc['comandos'] = $cmdsOut.ToArray()
    if ($Summary -and $Model.arquivo) {
        $doc['arquivo'] = [ordered]@{
            caminho       = $Model.arquivo.caminho
            formato       = $Model.arquivo.formato
            chars         = $Model.arquivo.chars
            bytes         = $Model.arquivo.bytes
            truncado_teto = [bool]$Model.arquivo.truncado_teto
        }
    }

    $json = ConvertTo-Json -InputObject $doc -Depth 10 -Compress:$Compress
    return (($json -replace '\r?\n', "`r`n"))
}
