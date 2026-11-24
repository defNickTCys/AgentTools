function Format-IcpReportXml {
    # Serializa o modelo v2 no estilo XML compacto para LLMs (escapa apenas tags do contrato).
    param($Model, [switch]$Summary)

    $flagsAtivos = @($Model.flags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $flagsAttr = if ($flagsAtivos.Count -gt 0) { " flags=""$(Protect-IcpAtributo ($flagsAtivos -join ','))""" } else { '' }
    $compAttr = if ($Summary) { ' completo="arquivo"' } else { '' }
    $raiz = "<icp_relatorio versao=""$($Model.versao)"" versao_icp=""$(Protect-IcpAtributo $Model.versao_icp)"" resultado=""$(Protect-IcpAtributo $Model.resultado)"" ms_total=""$($Model.ms_total)""$flagsAttr$compAttr>"

    $linhas = [System.Collections.Generic.List[string]]::new()
    $linhas.Add($raiz)
    $avisoTxt = if ($Summary -and $Model.arquivo) { Get-IcpSummaryAvisoText -Model $Model } else { $Model.aviso }
    $linhas.Add("<aviso>$(Protect-IcpTexto $avisoTxt)</aviso>")
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
