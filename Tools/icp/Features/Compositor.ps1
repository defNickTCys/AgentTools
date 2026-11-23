function New-IcpCompositorState {
    # Cria estado mutável do rascunho no compositor interativo.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Cria objeto de estado em memória para o rascunho do compositor.')]
    param()
    return [pscustomobject]@{
        Linhas  = [System.Collections.Generic.List[string]]::new()
        Explain = $false
        Step    = $false
    }
}

function Test-IcpCompositorRascunho {
    # Executa parser AST e Test-IcpPreVoo nas linhas fornecidas, distinguindo erros definitivos de bloco incompleto.
    param([string[]]$Linhas)
    if ($null -eq $Linhas -or $Linhas.Count -eq 0) {
        return [pscustomobject]@{
            PreVoo           = @()
            ErrosSintaxe     = @()
            ErrosDefinitivos = @()
            Incompleto       = $false
        }
    }
    $texto = $Linhas -join "`n"
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($texto, [ref]$tokens, [ref]$parseErrors)
    $preVoo = @(Test-IcpPreVoo -Ast $ast)
    $erros = @($parseErrors | ForEach-Object { $_.Message })
    $definitivos = @($parseErrors | Where-Object { -not $_.IncompleteInput } | ForEach-Object { $_.Message })
    $incompleto = (@($parseErrors | Where-Object { $_.IncompleteInput }).Count -gt 0)
    return [pscustomobject]@{
        PreVoo           = $preVoo
        ErrosSintaxe     = $erros
        ErrosDefinitivos = $definitivos
        Incompleto       = $incompleto
    }
}

function Resolve-IcpCompositorAviso {
    # Avalia linhas candidatas e a linha atual sem alterar o estado; retorna pré-voo deduplicado e erros definitivos.
    param([string[]]$LinhasCandidatas, [string]$Linha, [int]$NumeroLinha = 0)
    $chkLinha = Test-IcpCompositorRascunho -Linhas @($Linha)
    $chkTudo = Test-IcpCompositorRascunho -Linhas $LinhasCandidatas
    $num = if ($NumeroLinha -gt 0) { $NumeroLinha } else { $LinhasCandidatas.Count }
    $vistos = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $avisos = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $chkTudo.PreVoo) {
        if ($vistos.Add($a)) { $avisos.Add($a) }
    }
    foreach ($a in $chkLinha.PreVoo) {
        $aj = if ($num -gt 1 -and $a -match '^Comando 1: ') {
            $a -replace '^Comando 1: ', "Comando ${num}: "
        }
        else { $a }
        if ($vistos.Add($aj)) { $avisos.Add($aj) }
    }
    return [pscustomobject]@{
        Avisos           = @($avisos)
        ErrosDefinitivos = @($chkTudo.ErrosDefinitivos)
        Incompleto       = $chkTudo.Incompleto
    }
}

function Invoke-IcpCompositorComando {
    # Processa uma entrada no compositor interativo; rejeita linhas inválidas/bloqueadas antes de gravar no rascunho.
    param($Estado, [string]$Entrada)
    if ([string]::IsNullOrWhiteSpace($Entrada)) {
        return [pscustomobject]@{ Acao = 'vazio'; Mensagem = ''; Avisos = @(); ErrosSintaxe = @(); Incompleto = $false }
    }
    $trim = $Entrada.Trim()
    if ($trim -match '^(?i):(?:cancel|q|quit)$') {
        return [pscustomobject]@{ Acao = 'cancelar'; Mensagem = 'Execução cancelada.'; Avisos = @(); ErrosSintaxe = @(); Incompleto = $false }
    }
    if ($trim -match '^(?i):clear$') {
        $Estado.Linhas.Clear()
        return [pscustomobject]@{ Acao = 'limpo'; Mensagem = 'Rascunho limpo.'; Avisos = @(); ErrosSintaxe = @(); Incompleto = $false }
    }
    if ($trim -match '^(?i):explain$') {
        $Estado.Explain = -not $Estado.Explain
        $estadoTxt = if ($Estado.Explain) { 'ligado' } else { 'desligado' }
        return [pscustomobject]@{ Acao = 'explain'; Mensagem = "Modo -Explain: $estadoTxt."; Avisos = @(); ErrosSintaxe = @(); Incompleto = $false }
    }
    if ($trim -match '^(?i):step$') {
        $Estado.Step = -not $Estado.Step
        $estadoTxt = if ($Estado.Step) { 'ligado' } else { 'desligado' }
        return [pscustomobject]@{ Acao = 'step'; Mensagem = "Modo -Step (passo a passo): $estadoTxt."; Avisos = @(); ErrosSintaxe = @(); Incompleto = $false }
    }
    if ($trim -match '^(?i):(?:list|ls)$') {
        $chk = Test-IcpCompositorRascunho -Linhas $Estado.Linhas.ToArray()
        return [pscustomobject]@{ Acao = 'lista'; Mensagem = ''; Avisos = @($chk.PreVoo); ErrosSintaxe = @($chk.ErrosSintaxe); Incompleto = $chk.Incompleto }
    }
    if ($trim -match '^(?i):(?:help|\?)$') {
        return [pscustomobject]@{ Acao = 'ajuda'; Mensagem = ''; Avisos = @(); ErrosSintaxe = @(); Incompleto = $false }
    }
    if ($trim -match '^(?i):del(?:\s+(\S+))?$') {
        if ($Estado.Linhas.Count -eq 0) {
            return [pscustomobject]@{ Acao = 'erro'; Mensagem = 'Nenhuma linha para remover.'; Avisos = @(); ErrosSintaxe = @(); Incompleto = $false }
        }
        $idx = $Estado.Linhas.Count
        if ($Matches[1]) {
            $parsed = 0
            if (-not [int]::TryParse($Matches[1], [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt $Estado.Linhas.Count) {
                return [pscustomobject]@{ Acao = 'erro'; Mensagem = "Linha inválida: $($Matches[1]) (disponíveis: 1..$($Estado.Linhas.Count))."; Avisos = @(); ErrosSintaxe = @(); Incompleto = $false }
            }
            $idx = $parsed
        }
        $removida = $Estado.Linhas[$idx - 1]
        $Estado.Linhas.RemoveAt($idx - 1)
        return [pscustomobject]@{ Acao = 'removido'; Mensagem = "Linha $idx removida: $removida"; Avisos = @(); ErrosSintaxe = @(); Incompleto = $false }
    }
    if ($trim -match '^(?i):edit\s+(\S+)\s+(.+)$') {
        $parsed = 0
        if (-not [int]::TryParse($Matches[1], [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt $Estado.Linhas.Count) {
            return [pscustomobject]@{ Acao = 'erro'; Mensagem = "Linha inválida: $($Matches[1]) (disponíveis: 1..$($Estado.Linhas.Count))."; Avisos = @(); ErrosSintaxe = @(); Incompleto = $false }
        }
        $novoTexto = $Matches[2]
        $cand = [string[]]$Estado.Linhas.ToArray()
        $cand[$parsed - 1] = $novoTexto
        $resChk = Resolve-IcpCompositorAviso -LinhasCandidatas $cand -Linha $novoTexto -NumeroLinha $parsed
        if ($resChk.Avisos.Count -gt 0 -or $resChk.ErrosDefinitivos.Count -gt 0) {
            return [pscustomobject]@{
                Acao         = 'rejeitado'
                Mensagem     = "Edição da linha $parsed rejeitada (linha anterior preservada)."
                Avisos       = $resChk.Avisos
                ErrosSintaxe = $resChk.ErrosDefinitivos
                Incompleto   = $false
            }
        }
        $Estado.Linhas[$parsed - 1] = $novoTexto
        $msgEd = if ($resChk.Incompleto) { "Linha $parsed atualizada (bloco aberto: feche ao continuar)." } else { "Linha $parsed atualizada." }
        return [pscustomobject]@{ Acao = 'editado'; Mensagem = $msgEd; Avisos = @(); ErrosSintaxe = @(); Incompleto = $resChk.Incompleto }
    }
    if ($trim -match '^(?i):edit\b') {
        return [pscustomobject]@{ Acao = 'erro'; Mensagem = 'Uso: :edit <N> <novo comando>'; Avisos = @(); ErrosSintaxe = @(); Incompleto = $false }
    }
    if ($trim.StartsWith(':')) {
        return [pscustomobject]@{ Acao = 'erro'; Mensagem = "Comando desconhecido: $trim (use :list, :del, :edit, :clear, :explain, :cancel)."; Avisos = @(); ErrosSintaxe = @(); Incompleto = $false }
    }
    $cand = @($Estado.Linhas.ToArray()) + @($Entrada)
    $resChk = Resolve-IcpCompositorAviso -LinhasCandidatas $cand -Linha $Entrada -NumeroLinha $cand.Count
    if ($resChk.Avisos.Count -gt 0 -or $resChk.ErrosDefinitivos.Count -gt 0) {
        return [pscustomobject]@{
            Acao         = 'rejeitado'
            Mensagem     = 'Linha rejeitada (não adicionada ao rascunho; corrija e digite novamente).'
            Avisos       = $resChk.Avisos
            ErrosSintaxe = $resChk.ErrosDefinitivos
            Incompleto   = $false
        }
    }
    $Estado.Linhas.Add($Entrada)
    $msgInc = if ($resChk.Incompleto) { 'Bloco aberto: continue na próxima linha e feche ao terminar.' } else { '' }
    return [pscustomobject]@{ Acao = 'adicionado'; Mensagem = $msgInc; Avisos = @(); ErrosSintaxe = @(); Incompleto = $resChk.Incompleto }
}

function ConvertTo-IcpCompositorScriptBlock {
    # Valida sintaxe do rascunho e cria o scriptblock para execução.
    param($Estado)
    if ($null -eq $Estado -or $Estado.Linhas.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; ScriptBlock = $null; Erro = 'Nenhum comando no rascunho.' }
    }
    $texto = $Estado.Linhas.ToArray() -join "`n"
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($texto, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        return [pscustomobject]@{ Ok = $false; ScriptBlock = $null; Erro = $parseErrors[0].Message }
    }
    try {
        $sb = [scriptblock]::Create($texto)
        return [pscustomobject]@{ Ok = $true; ScriptBlock = $sb; Erro = '' }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; ScriptBlock = $null; Erro = $_.Exception.Message }
    }
}

function Format-IcpComandoColorido {
    # Realça tokens PowerShell com as cores atuais do PSReadLine; respeita NO_COLOR.
    param([string]$Texto)
    if ([string]::IsNullOrEmpty($Texto) -or -not [string]::IsNullOrEmpty($env:NO_COLOR)) { return $Texto }
    $pal = @{
        CommandColor      = "`e[93m"
        ParameterColor    = "`e[90m"
        StringColor       = "`e[36m"
        VariableColor     = "`e[92m"
        KeywordColor      = "`e[92m"
        OperatorColor     = "`e[90m"
        CommentColor      = "`e[32m"
        NumberColor       = "`e[97m"
        TypeColor         = "`e[37m"
        MemberColor       = "`e[37m"
        DefaultTokenColor = "`e[37m"
    }
    try {
        $opt = Get-PSReadLineOption -ErrorAction Ignore
        if ($null -ne $opt) {
            foreach ($k in @($pal.Keys)) {
                $val = $opt.$k
                if (-not [string]::IsNullOrEmpty($val)) { $pal[$k] = $val }
            }
        }
    }
    catch { $null = $_ }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Texto, [ref]$tokens, [ref]$parseErrors)
    if ($null -eq $tokens -or $tokens.Count -eq 0) { return $Texto }

    $cmdStarts = [System.Collections.Generic.HashSet[int]]::new()
    if ($null -ne $ast) {
        $cmdsAst = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($ca in $cmdsAst) {
            if ($ca.CommandElements.Count -gt 0) {
                [void]$cmdStarts.Add($ca.CommandElements[0].Extent.StartOffset)
            }
        }
    }

    $tf = [System.Management.Automation.Language.TokenFlags]
    $opFlags = $tf::BinaryOperator -bor $tf::UnaryOperator -bor $tf::AssignmentOperator
    $sb = [System.Text.StringBuilder]::new($Texto.Length * 2)
    $pos = 0
    $corAtiva = ''
    foreach ($tok in $tokens) {
        if ($tok.Kind -eq 'EndOfInput') { continue }
        $ini = $tok.Extent.StartOffset
        $fim = $tok.Extent.EndOffset
        if ($ini -lt $pos -or $fim -gt $Texto.Length) { continue }
        if ($ini -gt $pos) {
            [void]$sb.Append($Texto.Substring($pos, $ini - $pos))
        }
        $cor = if ($cmdStarts.Contains($ini)) { $pal.CommandColor }
        elseif ($tok.Kind -eq 'Comment') { $pal.CommentColor }
        elseif ($tok.Kind -eq 'Parameter') { $pal.ParameterColor }
        elseif ($tok.Kind -in 'StringLiteral', 'StringExpandable', 'HereStringLiteral', 'HereStringExpandable') { $pal.StringColor }
        elseif ($tok.Kind -in 'Variable', 'SplattedVariable') { $pal.VariableColor }
        elseif ($tok.Kind -eq 'Number') { $pal.NumberColor }
        elseif (($tok.TokenFlags -band $tf::Keyword) -ne 0) { $pal.KeywordColor }
        elseif (($tok.TokenFlags -band $tf::TypeName) -ne 0) { $pal.TypeColor }
        elseif (($tok.TokenFlags -band $tf::MemberName) -ne 0) { $pal.MemberColor }
        elseif (($tok.TokenFlags -band $opFlags) -ne 0 -or $tok.Kind -in 'Pipe', 'Semi', 'LBracket', 'RBracket', 'LCurly', 'RCurly', 'LParen', 'RParen', 'AtParen', 'AtCurly', 'DollarParen') { $pal.OperatorColor }
        else { $pal.DefaultTokenColor }

        if ($cor -ne $corAtiva) {
            if ([string]::IsNullOrEmpty($cor)) { [void]$sb.Append("`e[0m") }
            else { [void]$sb.Append($cor) }
            $corAtiva = $cor
        }
        [void]$sb.Append($Texto.Substring($ini, $fim - $ini))
        $pos = $fim
    }
    if ($pos -lt $Texto.Length) {
        [void]$sb.Append($Texto.Substring($pos))
    }
    if (-not [string]::IsNullOrEmpty($corAtiva)) {
        [void]$sb.Append("`e[0m")
    }
    return $sb.ToString()
}

function Read-IcpCompositorLinha {
    # Lê uma linha com realce de sintaxe nativo do PSReadLine sem poluir o histórico global; cai para Console.ReadLine se NO_COLOR/indisponível.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Emite prompt e lê linha interativa no console.')]
    param([string]$Prompt)
    [Console]::Write($Prompt)
    $psrl = 'Microsoft.PowerShell.PSConsoleReadLine' -as [type]
    if ([string]::IsNullOrEmpty($env:NO_COLOR) -and $null -ne $psrl) {
        $oldHandler = $null
        $temHandler = $false
        $l = $null
        try {
            $opt = Get-PSReadLineOption -ErrorAction Ignore
            if ($null -ne $opt) {
                $oldHandler = $opt.AddToHistoryHandler
                $temHandler = $true
                Set-PSReadLineOption -AddToHistoryHandler { param($line) $null = $line; return $false } -ErrorAction Ignore
            }
            $l = $psrl::ReadLine($Host.Runspace, $ExecutionContext, $null)
        }
        finally {
            if ($temHandler) {
                Set-PSReadLineOption -AddToHistoryHandler $oldHandler -ErrorAction Ignore
            }
        }
        if ($null -eq $l) { return $null }
        if ($l -eq '') {
            $curLeft = try { [Console]::CursorLeft } catch { 0 }
            if ($curLeft -gt 0) {
                [Console]::WriteLine('')
                return $null
            }
        }
        return $l
    }
    return (try { [Console]::ReadLine() } catch { $null })
}

function Show-IcpInicioCartao {
    # Exibe cartão compacto de abertura do compositor interativo e devolve quantas linhas ocupou.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Exibe o cartão de abertura do compositor interativo no terminal.')]
    param([int]$WindowWidth = 120)
    $ver = if ($script:AgentToolsVersion) { $script:AgentToolsVersion } else { '1.0.0' }
    $dir = (Get-Location).Path
    $git = ''
    if ((Get-Location).Provider.Name -eq 'FileSystem' -and (Get-Command git -CommandType Application -ErrorAction Ignore)) {
        $branch = & git -C $dir rev-parse --abbrev-ref HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $branch) { $git = $branch }
    }
    $logsCount = Get-IcpLogCount
    $w = if ($WindowWidth -lt 40) { 120 } else { $WindowWidth }
    $linhas = @(
        "$(Format-IcpCor '╭─' 'Petroleo') $(Format-IcpCor "AgentTools · icp v$ver" 'Ambar' -Negrito) $(Format-IcpCor '· compositor interativo' 'Neutro')"
        "$(Format-IcpCor '│ ' 'Pedra')$(Format-IcpCor 'pasta:' 'Neutro') $(Format-IcpCor $dir 'Creme')$(if ($git) { "  $(Format-IcpCor "git: $git" 'PetroleoClaro')" })  $(Format-IcpCor "logs: $logsCount" 'Pedra')"
        "$(Format-IcpCor '│ ' 'Pedra')$(Format-IcpCor 'comandos:' 'Neutro') $(Format-IcpCor ':list' 'PetroleoClaro') $(Format-IcpCor '·' 'Pedra') $(Format-IcpCor ':del [N]' 'PetroleoClaro') $(Format-IcpCor '·' 'Pedra') $(Format-IcpCor ':edit N txt' 'PetroleoClaro') $(Format-IcpCor '·' 'Pedra') $(Format-IcpCor ':clear' 'PetroleoClaro') $(Format-IcpCor '·' 'Pedra') $(Format-IcpCor ':explain' 'PetroleoClaro') $(Format-IcpCor '·' 'Pedra') $(Format-IcpCor ':step' 'PetroleoClaro') $(Format-IcpCor '·' 'Pedra') $(Format-IcpCor ':cancel' 'PetroleoClaro')"
        "$(Format-IcpCor '╰─' 'Petroleo') $(Format-IcpCor 'Um comando por linha (rejeita pré-voo/erro na hora). Enter em linha vazia executa.' 'Neutro')"
    )
    $emitidas = 0
    foreach ($l in $linhas) {
        Write-Host $l
        $vis = (Remove-Ansi -Text $l).Length
        $emitidas += [Math]::Max(1, [int][Math]::Ceiling($vis / [double]$w))
    }
    return $emitidas
}

function Invoke-IcpCompositor {
    # Compositor assistido linha a linha quando 'icp' é chamado sem argumentos em terminal interativo.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interface interativa do compositor linha a linha no terminal.')]
    param()
    $w = try { [Console]::WindowWidth } catch { 120 }
    if ($w -lt 40) { $w = 120 }
    $estado = New-IcpCompositorState
    $linhasTela = Show-IcpInicioCartao -WindowWidth $w
    $emit = {
        param([string]$Texto)
        Write-Host $Texto
        $vis = (Remove-Ansi -Text $Texto).Length
        return [Math]::Max(1, [int][Math]::Ceiling([Math]::Max(1, $vis) / [double]$w))
    }
    while ($true) {
        $n = $estado.Linhas.Count + 1
        $tags = @()
        if ($estado.Explain) { $tags += (Format-IcpCor '[-Explain]' 'PetroleoClaro') }
        if ($estado.Step) { $tags += (Format-IcpCor '[-Step]' 'Ambar') }
        $tagExp = if ($tags.Count -gt 0) { ' ' + ($tags -join ' ') } else { '' }
        $prompt = "  $(Format-IcpCor "$n" 'Ambar')$tagExp $(Format-IcpCor '›' 'PetroleoClaro') "
        $promptVis = (Remove-Ansi -Text $prompt).Length
        $entrada = Read-IcpCompositorLinha -Prompt $prompt
        if ($null -eq $entrada) {
            Write-Host ''
            $linhasTela++
            Write-Host (Format-IcpCor 'icp: compositor cancelado.' 'Neutro')
            return [pscustomobject]@{ Executar = $false; ScriptBlock = $null; Explain = $false; Step = $false; LinhasTela = 0 }
        }
        $subs = @($entrada -split '\r?\n')
        for ($si = 0; $si -lt $subs.Count; $si++) {
            $pref = if ($si -eq 0) { $promptVis } else { 3 }
            $linhasTela += [Math]::Max(1, [int][Math]::Ceiling(($pref + $subs[$si].Length) / [double]$w))
        }
        $res = Invoke-IcpCompositorComando -Estado $estado -Entrada $entrada
        switch ($res.Acao) {
            'cancelar' {
                $linhasTela += & $emit (Format-IcpCor 'icp: compositor cancelado (nada foi executado).' 'Neutro')
                return [pscustomobject]@{ Executar = $false; ScriptBlock = $null; Explain = $false; Step = $false; LinhasTela = 0 }
            }
            'rejeitado' {
                foreach ($av in $res.Avisos) {
                    $linhasTela += & $emit (Format-IcpCor "  [PRÉ-VOO] $av" 'Terracota' -Negrito)
                }
                foreach ($es in $res.ErrosSintaxe) {
                    $linhasTela += & $emit (Format-IcpCor "  [SINTAXE] $es" 'Terracota' -Negrito)
                }
                $linhasTela += & $emit (Format-IcpCor "  $($res.Mensagem)" 'Laranja')
            }
            'vazio' {
                if ($estado.Linhas.Count -eq 0) {
                    $pVazio = "  $(Format-IcpCor 'Rascunho vazio:' 'Ambar') $(Format-IcpCor '[A] Continuar digitando · [Enter/C] Cancelar › ' 'Neutro')"
                    $pVazioVis = (Remove-Ansi -Text $pVazio).Length
                    [Console]::Write($pVazio)
                    $resp = try { [Console]::ReadLine() } catch { $null }
                    if ($null -eq $resp) {
                        Write-Host ''
                        return [pscustomobject]@{ Executar = $false; ScriptBlock = $null; Explain = $false; Step = $false; LinhasTela = 0 }
                    }
                    $linhasTela += [Math]::Max(1, [int][Math]::Ceiling(($pVazioVis + $resp.Length) / [double]$w))
                    if ($resp.Trim() -match '^(?i)a$') { continue }
                    $linhasTela += & $emit (Format-IcpCor 'icp: compositor cancelado.' 'Neutro')
                    return [pscustomobject]@{ Executar = $false; ScriptBlock = $null; Explain = $false; Step = $false; LinhasTela = 0 }
                }
                $pConf = "  $(Format-IcpCor '[Enter/S]' 'Oliva') $(Format-IcpCor 'Executar' 'Creme') $(Format-IcpCor '·' 'Pedra') $(Format-IcpCor '[P]' 'Ambar') $(Format-IcpCor 'Passo a passo' 'Neutro') $(Format-IcpCor '·' 'Pedra') $(Format-IcpCor '[A]' 'PetroleoClaro') $(Format-IcpCor 'Continuar' 'Neutro') $(Format-IcpCor '·' 'Pedra') $(Format-IcpCor '[E]' 'Ambar') $(Format-IcpCor '-Explain' 'Neutro') $(Format-IcpCor '·' 'Pedra') $(Format-IcpCor '[C]' 'Terracota') $(Format-IcpCor 'Cancelar › ' 'Neutro')"
                $pConfVis = (Remove-Ansi -Text $pConf).Length
                [Console]::Write($pConf)
                $resp = try { [Console]::ReadLine() } catch { $null }
                if ($null -eq $resp) {
                    Write-Host ''
                    return [pscustomobject]@{ Executar = $false; ScriptBlock = $null; Explain = $false; Step = $false; LinhasTela = 0 }
                }
                $linhasTela += [Math]::Max(1, [int][Math]::Ceiling(($pConfVis + $resp.Length) / [double]$w))
                $op = $resp.Trim()
                if ($op -match '^(?i)(?:c|cancel|n)$') {
                    $linhasTela += & $emit (Format-IcpCor 'icp: compositor cancelado (nada foi executado).' 'Neutro')
                    return [pscustomobject]@{ Executar = $false; ScriptBlock = $null; Explain = $false; Step = $false; LinhasTela = 0 }
                }
                if ($op -match '^(?i)a$') { continue }
                if ($op -eq '' -or $op -match '^(?i)(?:s|sim|y|p|passo|step|e|explain)$') {
                    $usarExplain = $estado.Explain -or ($op -match '^(?i)(?:e|explain)$')
                    $usarStep = $estado.Step -or ($op -match '^(?i)(?:p|passo|step)$')
                    $comp = ConvertTo-IcpCompositorScriptBlock -Estado $estado
                    if (-not $comp.Ok) {
                        $linhasTela += & $emit (Format-IcpCor "  [SINTAXE] $($comp.Erro) — corrija com :edit ou :del." 'Terracota')
                        continue
                    }
                    return [pscustomobject]@{ Executar = $true; ScriptBlock = $comp.ScriptBlock; Explain = $usarExplain; Step = $usarStep; LinhasTela = $linhasTela }
                }
                $linhasTela += & $emit (Format-IcpCor '  Opção não reconhecida; voltando à edição.' 'Ambar')
            }
            'lista' {
                if ($estado.Linhas.Count -eq 0) {
                    $linhasTela += & $emit (Format-IcpCor '  (rascunho vazio)' 'Pedra')
                }
                else {
                    for ($i = 0; $i -lt $estado.Linhas.Count; $i++) {
                        $cmdCol = Format-IcpComandoColorido -Texto $estado.Linhas[$i]
                        $linhasTela += & $emit "  $(Format-IcpCor "$($i + 1)." 'Ambar') $cmdCol"
                    }
                }
                foreach ($av in $res.Avisos) {
                    $linhasTela += & $emit (Format-IcpCor "  [PRÉ-VOO] $av" 'Terracota')
                }
                foreach ($es in $res.ErrosSintaxe) {
                    $linhasTela += & $emit (Format-IcpCor "  [SINTAXE] $es" 'Terracota')
                }
            }
            'ajuda' {
                $linhasTela += & $emit (Format-IcpCor '  :list | :del [N] | :edit N <cmd> | :clear | :explain | :step | :cancel | Enter vazio executa' 'PetroleoClaro')
            }
            'erro' {
                $linhasTela += & $emit (Format-IcpCor "  $($res.Mensagem)" 'Terracota')
            }
            default {
                if ($res.Mensagem) {
                    $corMsg = if ($res.Incompleto) { 'Ambar' } else { 'PetroleoClaro' }
                    $linhasTela += & $emit (Format-IcpCor "  $($res.Mensagem)" $corMsg)
                }
                foreach ($av in $res.Avisos) {
                    $linhasTela += & $emit (Format-IcpCor "  [PRÉ-VOO] $av" 'Laranja')
                }
            }
        }
    }
}

function Read-IcpConfirmacaoPasso {
    # Pausa entre comandos em -Step mostrando o próximo comando colorido e aguardando decisão do operador.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Exibe prompt de confirmação passo a passo no terminal interativo.')]
    param([int]$ProximoN, [int]$Total, [string]$ProximoComando)
    $borda = Format-IcpCor '│ ' 'Pedra'
    Write-Host "$borda$(Format-IcpCor '▸' 'Ambar') $(Format-IcpCor "Próximo [$ProximoN/$Total]:" 'Ambar' -Negrito) $(Format-IcpComandoColorido -Texto $ProximoComando)"
    while ($true) {
        $p = "$(Format-IcpCor '│   ' 'Pedra')$(Format-IcpCor '[Enter/S]' 'Oliva') $(Format-IcpCor 'Executar' 'Creme') $(Format-IcpCor '·' 'Pedra') $(Format-IcpCor '[A]' 'PetroleoClaro') $(Format-IcpCor 'Rodar restantes' 'Neutro') $(Format-IcpCor '·' 'Pedra') $(Format-IcpCor '[C]' 'Terracota') $(Format-IcpCor 'Parar aqui › ' 'Neutro')"
        [Console]::Write($p)
        $resp = try { [Console]::ReadLine() } catch { $null }
        if ($null -eq $resp) {
            Write-Host ''
            return 'parar'
        }
        $op = $resp.Trim()
        if ($op -eq '' -or $op -match '^(?i)(?:s|sim|y|yes|ok)$') { return 'seguir' }
        if ($op -match '^(?i)(?:a|all|t|todos)$') { return 'todos' }
        if ($op -match '^(?i)(?:c|cancel|n|nao|não|q|quit|p|parar)$') { return 'parar' }
        Write-Host "$borda  $(Format-IcpCor 'Opção não reconhecida; use Enter/S, A ou C.' 'Ambar')"
    }
}
