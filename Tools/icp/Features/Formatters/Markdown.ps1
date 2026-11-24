function Get-IcpMarkdownFence {
    # Retorna uma cerca de crases maior que qualquer sequência contígua de crases presente nas linhas.
    param([string[]]$Lines)
    $maxRun = 2
    foreach ($l in @($Lines)) {
        if ([string]::IsNullOrEmpty($l)) { continue }
        foreach ($m in [regex]::Matches($l, '`+')) {
            if ($m.Length -gt $maxRun) { $maxRun = $m.Length }
        }
    }
    return ('`' * ($maxRun + 1))
}

function Format-IcpMarkdownInlineCode {
    # Envolve trecho inline em crases seguras, ajustando a contagem quando houver crases internas.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '""' }
    $maxRun = 0
    foreach ($m in [regex]::Matches($Text, '`+')) {
        if ($m.Length -gt $maxRun) { $maxRun = $m.Length }
    }
    $fence = [string]::new([char]96, $maxRun + 1)
    if ($maxRun -gt 0 -or $Text.StartsWith(' ') -or $Text.EndsWith(' ')) {
        return "$fence $Text $fence"
    }
    return "$fence$Text$fence"
}

function Format-IcpReportMarkdown {
    # Serializa o modelo v2 em Markdown legível para humanos com cercas dinâmicas seguras.
    param($Model, [switch]$Summary)

    $linhas = [System.Collections.Generic.List[string]]::new()
    $flagsAtivos = @($Model.flags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $flagsTxt = if ($flagsAtivos.Count -gt 0) { $flagsAtivos -join ', ' } else { 'nenhuma' }
    $linhas.Add("# Relatório icp v$($Model.versao_icp) (versao $($Model.versao))")
    $linhas.Add('')
    $linhas.Add("- **Resultado:** $(Format-IcpMarkdownInlineCode -Text $Model.resultado)")
    $linhas.Add("- **Duração total:** ``$($Model.ms_total) ms`` | **Modo:** ``$($Model.modo)`` | **Flags:** $(Format-IcpMarkdownInlineCode -Text $flagsTxt)")
    $linhas.Add("- **Resumo:** $($Model.resumo.total) comando(s) · $($Model.resumo.executados) executado(s) · $($Model.resumo.ok) OK · $($Model.resumo.falharam) falharam · $($Model.resumo.nao_executados) não executado(s)")
    if ($Summary -and $Model.arquivo) {
        $linhas.Add("- **Entrega:** ``completo=arquivo``")
    }
    $linhas.Add('')
    $avisoTxt = if ($Summary -and $Model.arquivo) { Get-IcpSummaryAvisoText -Model $Model } else { $Model.aviso }
    $linhas.Add("> **Aviso:** $avisoTxt")
    if ($Model.aviso_pre_voo) {
        $linhas.Add("> **Pré-voo:** $($Model.aviso_pre_voo)")
    }
    if ($Model.legenda) {
        $linhas.Add("> **Legenda:** $($Model.legenda)")
    }
    $linhas.Add('')
    $linhas.Add('## Ambiente')
    $linhas.Add('')
    if ($Model.explain) {
        foreach ($la in $Model.ambiente.full_lines) { $linhas.Add("- $(Format-IcpMarkdownInlineCode -Text $la)") }
    }
    else {
        $linhas.Add("- $(Format-IcpMarkdownInlineCode -Text $Model.ambiente.compact_text)")
    }
    $linhas.Add('')
    $linhas.Add('## Comandos')

    foreach ($c in $Model.comandos) {
        $linhas.Add('')
        $rotSufixo = if (-not [string]::IsNullOrWhiteSpace($c.rotulo)) { " — $($c.rotulo)" } else { '' }
        if ($c.status -eq 'NAO_EXECUTADO') {
            $linhas.Add("### [$($c.n)/$($Model.resumo.total)] NAO_EXECUTADO$rotSufixo")
            $linhas.Add('')
            $ent = if ($Summary) { @($c.entrada_resumo) } else { @($c.entrada -split '\r?\n') }
            $fEnt = Get-IcpMarkdownFence -Lines $ent
            $linhas.Add("${fEnt}powershell")
            foreach ($el in $ent) { $linhas.Add($el) }
            $linhas.Add($fEnt)
            continue
        }

        $meta = [System.Collections.Generic.List[string]]::new()
        $meta.Add("$($c.ms) ms")
        if ($c.interativo) { $meta.Add('interativo=true') }
        if ($null -ne $c.exit) { $meta.Add("exit=$($c.exit)") }
        if ($c.exit_permitido) { $meta.Add('exit_permitido=true') }
        if ($c.silenciosos -gt 0) { $meta.Add("silenciosos=$($c.silenciosos)") }
        $spItens = @($c.segundo_plano | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($spItens.Count -gt 0) { $meta.Add("segundo_plano=$($spItens -join ', ')") }
        $filhoItens = @($c.filho | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($filhoItens.Count -gt 0) { $meta.Add("filho=$($filhoItens -join ', ')") }
        if ($null -ne $c.sem_saida_s) { $meta.Add("sem_saida_s=$($c.sem_saida_s)s") }
        if ($Summary) { $meta.Add("linhas=$($c.linhas), chars=$($c.chars)") }

        $linhas.Add("### [$($c.n)/$($Model.resumo.total)] $($c.status)$rotSufixo ($($meta -join ' · '))")
        $linhas.Add('')
        $ent = if ($Summary) { @($c.entrada_resumo) } else { @($c.entrada -split '\r?\n') }
        $fEnt = Get-IcpMarkdownFence -Lines $ent
        $linhas.Add('**Entrada:**')
        $linhas.Add('')
        $linhas.Add("${fEnt}powershell")
        foreach ($el in $ent) { $linhas.Add($el) }
        $linhas.Add($fEnt)

        if ($Summary) {
            if ($c.status -in 'FALHOU', 'INTERROMPIDO' -and $c.erro_resumo.Count -gt 0) {
                $fErr = Get-IcpMarkdownFence -Lines $c.erro_resumo
                $linhas.Add('')
                $linhas.Add('**Erro (resumo):**')
                $linhas.Add('')
                $linhas.Add("${fErr}text")
                foreach ($er in $c.erro_resumo) { $linhas.Add($er) }
                $linhas.Add($fErr)
            }
            elseif ($c.status -eq 'OK' -and -not [string]::IsNullOrEmpty($c.previa)) {
                $fPrev = Get-IcpMarkdownFence -Lines @($c.previa)
                $linhas.Add('')
                $linhas.Add('**Prévia:**')
                $linhas.Add('')
                $linhas.Add("${fPrev}text")
                $linhas.Add($c.previa)
                $linhas.Add($fPrev)
            }
            continue
        }

        $saidaCorpo = if ($c.saida.Count -eq 0) { @('[Sem saída]') } else { @($c.saida) }
        $fSai = Get-IcpMarkdownFence -Lines $saidaCorpo
        $linhas.Add('')
        $linhas.Add('**Saída:**')
        $linhas.Add('')
        $linhas.Add("${fSai}text")
        foreach ($sl in $saidaCorpo) { $linhas.Add($sl) }
        $linhas.Add($fSai)
    }

    if ($Summary -and $Model.arquivo) {
        $linhas.Add('')
        $linhas.Add('## Arquivo completo')
        $linhas.Add('')
        $linhas.Add("- **Caminho:** $(Format-IcpMarkdownInlineCode -Text $Model.arquivo.caminho)")
        $linhas.Add("- **Formato:** $(Format-IcpMarkdownInlineCode -Text $Model.arquivo.formato) | **Tamanho:** $($Model.arquivo.chars) chars ($($Model.arquivo.bytes) bytes)")
    }

    return ($linhas -join "`r`n")
}
