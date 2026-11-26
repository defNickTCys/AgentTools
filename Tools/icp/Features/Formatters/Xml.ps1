function Format-IcpReportXml {
    # Serializa o modelo v2 no estilo XML compacto para LLMs (escapa apenas tags do contrato).
    param($Model, [switch]$Summary, [switch]$Budget)

    $flagsAtivos = @($Model.flags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $flagsAttr = if ($flagsAtivos.Count -gt 0) { " flags=""$(Protect-IcpAtributo ($flagsAtivos -join ','))""" } else { '' }
    $budgetAttr = if ($Budget) { ' resumido="true"' } else { '' }
    $compAttr = if ($Summary) { ' completo="arquivo"' } else { '' }
    $raiz = "<icp_relatorio versao=""$($Model.versao)"" versao_icp=""$(Protect-IcpAtributo $Model.versao_icp)"" resultado=""$(Protect-IcpAtributo $Model.resultado)"" ms_total=""$($Model.ms_total)""$flagsAttr$compAttr$budgetAttr>"

    $linhas = [System.Collections.Generic.List[string]]::new()
    $linhas.Add($raiz)
    $avisoTxt = if ($Summary -and $Model.arquivo) { Get-IcpSummaryAvisoText -Model $Model } else { $Model.aviso }
    $linhas.Add("<aviso>$(Protect-IcpTexto $avisoTxt)</aviso>")
    if ($Budget -and $Model.comandos_omitidos -gt 0) { $linhas.Add("<aviso>Comandos omitidos do resumo: $($Model.comandos_omitidos).</aviso>") }
    if ($Model.aviso_pre_voo) {
        $linhas.Add("<aviso>$(Protect-IcpTexto $Model.aviso_pre_voo)</aviso>")
    }
    if ($Model.legenda) {
        $linhas.Add("<legenda>$(Protect-IcpTexto $Model.legenda)</legenda>")
    }
    if ($Model.explain) {
        $linhas.Add('<ambiente>')
        foreach ($la in $Model.ambiente.full_lines) { $linhas.Add((Protect-IcpTexto $la)) }
        $linhas.Add('</ambiente>')
    }
    else {
        $linhas.Add("<ambiente>$(Protect-IcpTexto $Model.ambiente.compact_text)</ambiente>")
    }

    $linhas.Add("<comandos total=""$($Model.resumo.total)"" executados=""$($Model.resumo.executados)"">")
    foreach ($c in $Model.comandos) {
        if ($c.status -eq 'NAO_EXECUTADO') {
            $ent = if ($Summary) { $c.entrada_resumo } else { $c.entrada }
            $rotAttr = if (-not [string]::IsNullOrWhiteSpace($c.rotulo)) { " rotulo=""$(Protect-IcpAtributo $c.rotulo)""" } else { '' }
            $linhas.Add("<comando n=""$($c.n)"" status=""NAO_EXECUTADO""$rotAttr><entrada>$(Protect-IcpTexto $ent)</entrada></comando>")
            continue
        }
        $attr = Get-IcpAtributosComando -Registro ([pscustomobject]@{
            Exit          = $c.exit
            ExitPermitido = $c.exit_permitido
            Ms            = $c.ms
            Silenciosos   = $c.silenciosos
            SegundoPlano  = $c.segundo_plano
            Rotulo        = $c.rotulo
            Interativo    = $c.interativo
            Filho         = $c.filho
            SemSaidaS     = $c.sem_saida_s
        })
        if ($Summary) {
            $extra = ''
            if ($c.status -in 'FALHOU', 'INTERROMPIDO' -and $c.erro_resumo.Count -gt 0) {
                $errL = @($c.erro_resumo | ForEach-Object { Protect-IcpTexto $_ })
                $extra = "<erro>$($errL -join "`r`n")</erro>"
            }
            elseif ($c.status -eq 'OK' -and -not [string]::IsNullOrEmpty($c.previa)) {
                $extra = "<previa>$(Protect-IcpTexto $c.previa)</previa>"
            }
            if ($Budget -and $c.budget_saida) { $extra += "<saida>$(Protect-IcpTexto $c.budget_saida)</saida>" }
            $linhas.Add("<comando n=""$($c.n)"" status=""$($c.status)""$attr linhas=""$($c.linhas)"" chars=""$($c.chars)""><entrada>$(Protect-IcpTexto $c.entrada_resumo)</entrada>$extra</comando>")
            continue
        }

        $linhas.Add("<comando n=""$($c.n)"" status=""$($c.status)""$attr>")
        $linhas.Add("<entrada>$(Protect-IcpTexto $c.entrada)</entrada>")
        $linhas.Add('<saida>')
        if ($c.saida.Count -eq 0) {
            $linhas.Add('[Sem saída]')
        }
        else {
            foreach ($sl in $c.saida) { $linhas.Add((Protect-IcpTexto $sl)) }
        }
        $linhas.Add('</saida>')
        $linhas.Add('</comando>')
    }
    $linhas.Add('</comandos>')
    if ($Summary -and $Model.arquivo) {
        $linhas.Add("<arquivo>$(Protect-IcpTexto $Model.arquivo.caminho)</arquivo>")
    }
    $linhas.Add('</icp_relatorio>')
    return ($linhas -join "`r`n")
}

function Format-IcpBudgetSummaryXml {
    # O orçamento é calculado após a serialização pelo formatador de resumo existente.
    param($Model, [int]$MaxChars)
    $clones = @($Model.comandos | ForEach-Object {
        $c = $_.PSObject.Copy()
        $c | Add-Member -NotePropertyName budget_saida -NotePropertyValue ''
        $c
    })
    $reduzido = Copy-IcpReportModelClone -Model $Model -Comandos $clones
    $serializar = { Format-IcpReportXml -Model $reduzido -Summary -Budget }
    while ((& $serializar).Length -gt $MaxChars) {
        $removivel = @($reduzido.comandos | Where-Object { $_.status -notin 'FALHOU', 'INTERROMPIDO' } | Sort-Object @{ Expression = {
            if (@($_.saida | Where-Object { $_ -match '^\[AVISO\]' }).Count) { 1 }
            elseif ($_.keep_output) { 2 }
            else { 3 }
        }; Descending = $true }, @{ Expression = { $_.n }; Descending = $true } | Select-Object -First 1)
        if ($removivel.Count -eq 0) { break }
        $n = $removivel[0].n
        $reduzido.comandos = @($reduzido.comandos | Where-Object { $_.n -ne $n })
        $reduzido.comandos_omitidos++
    }
    $ordenados = @($reduzido.comandos | Sort-Object @{ Expression = {
        if ($_.status -in 'FALHOU', 'INTERROMPIDO') { 0 }
        elseif (@($_.saida | Where-Object { $_ -match '^\[AVISO\]' }).Count) { 1 }
        elseif ($_.keep_output) { 2 }
        else { 3 }
    } }, n)
    foreach ($c in $ordenados) {
        $falha = $c.status -in 'FALHOU', 'INTERROMPIDO'
        $avisos = @($c.saida | Where-Object { $_ -match '^\[AVISO\]' })
        if (-not $falha -and -not $c.keep_output -and $avisos.Count -eq 0) { continue }
        $fonte = [string]($c.saida -join "`r`n")
        if (-not $fonte) { continue }
        $c.budget_saida = $fonte
        if ((& $serializar).Length -le $MaxChars) { continue }
        $baixo = 0; $alto = $fonte.Length
        while ($baixo -lt $alto) {
            $meio = [int][Math]::Ceiling(($baixo + $alto) / 2.0)
            $parte = if ($falha) { $fonte.Substring($fonte.Length - $meio) } else { $fonte.Substring(0, $meio) }
            if ($parte.Length -gt 0 -and [char]::IsLowSurrogate($parte[0])) { $parte = $parte.Substring(1) }
            if ($parte.Length -gt 0 -and [char]::IsHighSurrogate($parte[$parte.Length - 1])) { $parte = $parte.Substring(0, $parte.Length - 1) }
            $c.budget_saida = if ($falha) { '[truncado]' + $parte } else { $parte + '[truncado]' }
            if ((& $serializar).Length -le $MaxChars) { $baixo = $meio } else { $alto = $meio - 1 }
        }
        $parte = if ($falha) { $fonte.Substring($fonte.Length - $baixo) } else { $fonte.Substring(0, $baixo) }
        if ($parte.Length -gt 0 -and [char]::IsLowSurrogate($parte[0])) { $parte = $parte.Substring(1) }
        if ($parte.Length -gt 0 -and [char]::IsHighSurrogate($parte[$parte.Length - 1])) { $parte = $parte.Substring(0, $parte.Length - 1) }
        $c.budget_saida = if ($falha) { '[truncado]' + $parte } else { $parte + '[truncado]' }
        if ((& $serializar).Length -gt $MaxChars) { $c.budget_saida = '' }
    }
    return (& $serializar)
}
