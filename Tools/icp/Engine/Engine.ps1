function Get-IcpItemSizeEstimate {
    # Estima o custo textual aproximado de um item antes de retê-lo no buffer de captura em memória.
    param($Item, [int]$MaxCheck = 4096)
    if ($null -eq $Item) { return 2 }
    if ($Item -is [string]) { return $Item.Length + 2 }
    if ($Item -is [System.Management.Automation.ErrorRecord]) {
        $msg = if ($null -ne $Item.Exception -and $Item.Exception.Message) { $Item.Exception.Message } else { $Item.ToString() }
        return ([string]$msg).Length + 16
    }
    if ($Item -is [ValueType]) { return ([string]$Item).Length + 2 }
    if ($Item -is [System.Collections.IDictionary]) {
        $tot = 16
        foreach ($k in $Item.Keys) {
            $tot += ([string]$k).Length + 4
            $v = $Item[$k]
            $tot += if ($null -eq $v) { 4 } elseif ($v -is [string]) { $v.Length } else { ([string]$v).Length }
            if ($tot -gt $MaxCheck) { return $tot }
        }
        return $tot
    }
    if ($Item -is [System.Collections.IEnumerable]) {
        $tot = 16
        foreach ($el in $Item) {
            $tot += if ($null -eq $el) { 4 } elseif ($el -is [string]) { $el.Length + 2 } else { ([string]$el).Length + 2 }
            if ($tot -gt $MaxCheck) { return $tot }
        }
        return $tot
    }
    $tot = 32
    try {
        foreach ($prop in $Item.PSObject.Properties) {
            $tot += $prop.Name.Length + 4
            $pv = $prop.Value
            $tot += if ($null -eq $pv) { 4 } elseif ($pv -is [string]) { $pv.Length } else { ([string]$pv).Length }
            if ($tot -gt $MaxCheck) { return $tot }
        }
    }
    catch {
        return 128
    }
    return $tot
}

function ConvertTo-IcpCommandOutput {
    # Converte itens capturados, redirecionamentos, marcador opcional e mascaramento nas linhas finais de saída.
    param(
        $EngineState,
        $StmtAst,
        [object[]]$Itens,
        $Antigos,
        [bool]$NativoFalhou,
        [bool]$CaptureTruncated,
        [int]$DroppedItems,
        [int]$CapturedChars,
        [string]$ExtraLine = '',
        [string]$MarkerLine = '',
        [ref]$TiposOut
    )
    $tipos = @(foreach ($it in $Itens) { Get-IcpTipo -Item $it -ErrosAntigos $Antigos })
    if ($null -ne $TiposOut) { $TiposOut.Value = $tipos }
    $linhas = @(ConvertTo-IcpLinha -Itens $Itens -Tipos $tipos -Largura 4096 -NativoFalhou $NativoFalhou)
    if ($ExtraLine) { $linhas += $ExtraLine }
    if ($CaptureTruncated) {
        $linhas += "[icp: captura limitada em $($EngineState.MaxCaptureChars) chars; $DroppedItems item(ns) excedente(s) descartado(s)]"
    }
    if ($EngineState.TailRedir -gt 0 -and $null -ne $StmtAst) {
        $saldoRedir = [Math]::Max(256, [Math]::Min(65536, $EngineState.MaxCaptureChars - $CapturedChars))
        $linhas += @(Get-IcpRedirecionamento -Ast $StmtAst -Tail $EngineState.TailRedir -MaxChars $saldoRedir)
    }
    if ($MarkerLine) { $linhas += $MarkerLine }
    if ($EngineState.Mascarar -and $linhas.Count -gt 0) {
        $ocultosOut = 0
        $linhas = @((Hide-IcpSegredo -Text ($linhas -join "`n") -Contagem ([ref]$ocultosOut)) -split "`n")
        $EngineState.Ocultos += $ocultosOut
    }
    return [string[]]@($linhas)
}

function Complete-IcpReportDelivery {
    # Consolida o modelo v2, entrega em -OutFile/icp-logs/clipboard e exibe o rodapé final.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Emite rodapé e avisos de entrega para o operador na tela.')]
    param(
        [Parameter(Mandatory)]$Eng,
        [int]$MsTotal,
        $AmbienteInfo,
        [switch]$InterrompidoCtrlC
    )
    if ($null -eq $AmbienteInfo) { $AmbienteInfo = Get-IcpAmbienteInfo }

    $emitLine = {
        param([string]$Txt, [ConsoleColor]$Color = [ConsoleColor]::Gray, [switch]$NoColorArg)
        if ($InterrompidoCtrlC) {
            try { [Console]::WriteLine($Txt) } catch { $null = $_ }
        }
        elseif ($NoColorArg) {
            Write-Host $Txt
        }
        else {
            Write-Host $Txt -ForegroundColor $Color
        }
    }

    $falhas = @($Eng.Res | Where-Object Status -eq 'FALHOU' | ForEach-Object N)
    $naoExec = @($Eng.Res | Where-Object Status -eq 'NAO_EXECUTADO')
    $executadosCount = @($Eng.Res | Where-Object Status -ne 'NAO_EXECUTADO').Count
    $resultado = if ($Eng.Bloqueado) { "BLOQUEADO no pré-voo (0 de $($Eng.Total) executados)" }
    elseif ($InterrompidoCtrlC -or ($falhas.Count -eq 0 -and $Eng.ParadoOperador)) { "INTERROMPIDO pelo operador ($executadosCount de $($Eng.Total) executados)" }
    elseif ($falhas.Count -eq 0) { 'OK' }
    elseif ($naoExec.Count -gt 0 -or -not $Eng.Continuar) { "FALHOU no comando $($falhas[0]) de $($Eng.Total)" }
    else { "COM FALHAS nos comandos $($falhas -join ', ') de $($Eng.Total)" }

    $algumInterativo = $Eng.ModoInterativo -or (@($Eng.Res | Where-Object { $_.Interativo }).Count -gt 0)
    $flags = Get-IcpFlagList -Explain:$Eng.Explicar -Raw:$Eng.Raw -ContinueOnError:$Eng.Continuar `
        -Step:$Eng.PassoAPassoInicial -NoMask:(-not $Eng.Mascarar) -AllowTrailingBackslash:$Eng.PermitirBarra `
        -AllowedExitCodes $Eng.AllowedExitCodes -CommandTimeoutSeconds $Eng.TimeoutSeg `
        -Interactive:$algumInterativo

    $model = New-IcpReportModel -VersaoIcp $script:AgentToolsVersion -Formato $Eng.Formato -Explain:$Eng.Explicar `
        -Resultado $resultado -MsTotal $MsTotal -Flags $flags -Bloqueios $Eng.Bloqueios `
        -AmbienteInfo $AmbienteInfo -Mascarar $Eng.Mascarar -Ocultos $Eng.Ocultos -Registros $Eng.Res.ToArray()

    $maxFileChars = Get-IcpMaxFileChar
    $serFull = Format-IcpReportText -Model $model -Format $Eng.Formato -MaxFileChars $(if ($Eng.ModoOut) { $maxFileChars } else { 0 })
    $texto = $serFull.Text

    $arquivo = $null
    $clip = $texto
    $outCaminho = $Eng.OutCaminho
    if ($Eng.ModoOut) {
        if ($Eng.OutVazio) {
            & $emitLine 'icp: -OutFile vazio; o relatório não foi gravado nem copiado.' ([ConsoleColor]::Yellow)
        }
        elseif ($Eng.OutErro) {
            & $emitLine "icp: não consegui gravar o relatório em '$($Eng.OutArq)' ($($Eng.OutErro)); nada foi copiado." ([ConsoleColor]::Yellow)
        }
        else {
            try { [System.IO.File]::WriteAllText($outCaminho, $texto, [System.Text.UTF8Encoding]::new($false)) }
            catch {
                & $emitLine "icp: não consegui gravar o relatório em '$($Eng.OutArq)' ($($_.Exception.Message)); nada foi copiado." ([ConsoleColor]::Yellow)
                $outCaminho = $null
            }
        }
    }
    elseif ($texto.Length -gt $Eng.MaxClip) {
        try {
            $dir = Get-IcpLogDirectory
            $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop
            Clear-IcpOldLog -Directory $dir -Days 7

            $serArq = Format-IcpReportText -Model $model -Format $Eng.Formato -MaxFileChars $maxFileChars
            $arquivo = Write-IcpLogFileExclusive -Directory $dir -Content $serArq.Text -Format $Eng.Formato
            $texto = $serArq.Text

            $model.arquivo = [pscustomobject]@{
                caminho       = $arquivo
                formato       = $Eng.Formato
                chars         = $serArq.CharCount
                bytes         = $serArq.ByteCount
                truncado_teto = $serArq.Truncated
            }
            $serSum = Format-IcpReportText -Model $model -Format $Eng.Formato -Summary
            $clip = $serSum.Text
            if ($Eng.Formato -eq 'xml' -and $Eng.MaxClip -ge 1000) {
                $clip = Format-IcpBudgetSummaryXml -Model $model -MaxChars $Eng.MaxClip
            }
        }
        catch {
            if ($Eng.SemClip) { & $emitLine "icp: não consegui gravar o arquivo ($_); o relatório não foi gravado nem copiado (-NoClipboard)." ([ConsoleColor]::Yellow) }
            else { & $emitLine "icp: não consegui gravar o arquivo ($_); copiando o relatório inteiro." ([ConsoleColor]::Yellow) }
            $arquivo = $null
        }
    }

    $copiou = $false
    if (-not $Eng.ModoOut -and -not $Eng.SemClip) {
        try { Set-Clipboard -Value $clip -ErrorAction Stop; $copiou = $true }
        catch { & $emitLine "icp: não consegui copiar para a área de transferência: $_" ([ConsoleColor]::Yellow) }
    }

    $modoRel = if ($Eng.Explicar) { 'completo/-Explain' } else { 'compacto' }
    if ($Eng.Formato -ne 'xml') { $modoRel += " · $($Eng.Formato)" }
    $durTotal = Format-IcpDuracao -Ms $MsTotal
    if ($Eng.Interativo) {
        $corResT = if ($resultado -eq 'OK') { 'Oliva' } elseif (($InterrompidoCtrlC -or $Eng.ParadoOperador) -and $falhas.Count -eq 0) { 'Ambar' } else { 'Terracota' }
        $icRes = if ($resultado -eq 'OK') { '✓' } elseif (($InterrompidoCtrlC -or $Eng.ParadoOperador) -and $falhas.Count -eq 0) { '■' } else { '✗' }
        & $emitLine "$(Format-IcpCor '╰─' 'Petroleo') $(Format-IcpCor "$icRes Resultado: $resultado" $corResT -Negrito) $(Format-IcpCor "($durTotal · $modoRel)" 'Neutro')" -NoColorArg
        if ($Eng.ModoOut) {
            if ($outCaminho) { & $emitLine (Format-IcpCor "--- Relatório ($($texto.Length) caracteres) gravado em: $outCaminho" 'Ambar') -NoColorArg }
        }
        elseif ($arquivo) {
            & $emitLine (Format-IcpCor "--- Relatório ($($texto.Length) caracteres) gravado em: $arquivo" 'Ambar') -NoColorArg
            if ($Eng.SemClip) { & $emitLine (Format-IcpCor '--- Área de transferência: não usada (-NoClipboard).' 'Neutro') -NoColorArg }
            else { & $emitLine (Format-IcpCor "--- Área de transferência: resumo de $($clip.Length) caracteres com o caminho. Anexe o arquivo." 'Ambar') -NoColorArg }
        }
        elseif ($Eng.SemClip) { & $emitLine (Format-IcpCor '--- Área de transferência: não usada (-NoClipboard).' 'Neutro') -NoColorArg }
        elseif ($copiou) { & $emitLine (Format-IcpCor "--- Relatório copiado para a área de transferência ($($clip.Length) caracteres)." 'Oliva') -NoColorArg }
        if ($naoExec.Count -gt 0) {
            & $emitLine (Format-IcpCor "--- Comandos não executados: $($naoExec.Count)" 'Neutro') -NoColorArg
        }
        if ($Eng.Ocultos -gt 0) {
            & $emitLine (Format-IcpCor "--- Segredos ocultados no relatório: $($Eng.Ocultos) (a tela mostra o original)" 'Ambar') -NoColorArg
        }
    }
    else {
        $corRes = if ($resultado -eq 'OK') { 'Green' } elseif (($InterrompidoCtrlC -or $Eng.ParadoOperador) -and $falhas.Count -eq 0) { 'Yellow' } else { 'Red' }
        $sep = ('─' * [Math]::Min(60, $Eng.LarguraTela))
        if ($InterrompidoCtrlC) {
            try {
                [Console]::WriteLine($sep)
                [Console]::WriteLine("--- Resultado: $resultado ($durTotal · $modoRel)")
            }
            catch { $null = $_ }
        }
        else {
            Write-Host $sep -ForegroundColor DarkGray
            Write-Host "--- Resultado: $resultado" -ForegroundColor $corRes -NoNewline
            Write-Host " ($durTotal · $modoRel)" -ForegroundColor DarkGray
        }
        if ($Eng.ModoOut) {
            if ($outCaminho) { & $emitLine "--- Relatório ($($texto.Length) caracteres) gravado em: $outCaminho" ([ConsoleColor]::Yellow) }
        }
        elseif ($arquivo) {
            & $emitLine "--- Relatório ($($texto.Length) caracteres) gravado em: $arquivo" ([ConsoleColor]::Yellow)
            if ($Eng.SemClip) { & $emitLine '--- Área de transferência: não usada (-NoClipboard).' ([ConsoleColor]::Yellow) }
            else { & $emitLine "--- Área de transferência: resumo de $($clip.Length) caracteres com o caminho. Anexe o arquivo." ([ConsoleColor]::Yellow) }
        }
        elseif ($Eng.SemClip) { & $emitLine '--- Área de transferência: não usada (-NoClipboard).' -NoColorArg }
        elseif ($copiou) { & $emitLine "--- Relatório copiado para a área de transferência ($($clip.Length) caracteres)." ([ConsoleColor]::Green) }
        & $emitLine "--- Comandos não executados: $($naoExec.Count)" -NoColorArg
        if ($Eng.Ocultos -gt 0) { & $emitLine "--- Segredos ocultados no relatório: $($Eng.Ocultos) (a tela mostra o original)" ([ConsoleColor]::Yellow) }
    }
}

function Invoke-IcpEngineDispatch {
    # Máquina de estados privada no escopo do módulo AgentTools gerenciada pelo motor icp.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Emite progresso e cabeçalhos visuais na tela do operador.')]
    param(
        [Parameter(Mandatory)][string]$Action,
        $Payload = $null
    )
    if ($null -eq $script:IcpEngineStack -or $script:IcpEngineStack.Count -eq 0) {
        throw 'Estado interno do motor icp indisponível.'
    }
    $e = $script:IcpEngineStack.Peek()

    switch ($Action) {
        'begin' {
            if ($e.Index -ge $e.Total) { return 'stop' }
            $e.CurStmt = $e.Stmts[$e.Index]
            $e.CurCmdText = $e.CurStmt.Extent.Text
            $meta = if ($null -ne $e.Metas -and $e.Index -lt $e.Metas.Count) { $e.Metas[$e.Index] } else { $null }
            $rotuloRaw = if ($null -ne $meta) { $meta.Rotulo } else { $null }
            $rotuloMasc = $rotuloRaw
            if ($e.Mascarar -and -not [string]::IsNullOrWhiteSpace($rotuloRaw)) {
                $ocultosRot = 0
                $rotuloMasc = Hide-IcpSegredo -Text $rotuloRaw -Contagem ([ref]$ocultosRot)
                $e.Ocultos += $ocultosRot
            }
            $e.CurRotulo = $rotuloRaw
            $e.CurRotuloTela = if (-not [string]::IsNullOrWhiteSpace($rotuloRaw)) {
                $rt = ($rotuloRaw -replace '\s+', ' ').Trim()
                if ($rt.Length -gt 70) { $rt.Substring(0, 69) + '…' } else { $rt }
            }
            else { $null }

            $e.CurReg = [pscustomobject]@{
                N             = $e.Index + 1
                Comando       = $e.CurCmdText
                Rotulo        = $rotuloMasc
                KeepOutput    = [bool]($null -ne $meta -and $meta.KeepOutput)
                Interativo    = $false
                Status        = 'NAO_EXECUTADO'
                Exit          = $null
                ExitPermitido = $false
                Ms            = 0
                Linhas        = @()
                Atribuicao    = $null
                Silenciosos   = 0
                SegundoPlano  = @()
                Filho         = @()
                SemSaidaS     = $null
            }
            if ($e.Mascarar) {
                $ocultosCmd = 0
                $cmdAstMasc = Hide-IcpAtribuicaoSensivel -Ast $e.CurStmt -Text $e.CurCmdText -Contagem ([ref]$ocultosCmd)
                $cmdSegMasc = Hide-IcpSegredo -Text $cmdAstMasc -Contagem ([ref]$ocultosCmd)
                $e.Ocultos += $ocultosCmd
                $e.CurReg.Comando = $cmdSegMasc
            }
            $resumo = ($e.CurCmdText -replace '\s+', ' ').Trim()
            if ($resumo.Length -gt 70) { $resumo = $resumo.Substring(0, 69) + '…' }
            $e.CurResumo = $resumo
            $labelExib = if ($e.CurRotuloTela) { $e.CurRotuloTela } else { $resumo }

            if ($e.Parar) {
                if ($e.Interativo) {
                    $labelFmt = if ($e.CurRotuloTela) { Format-IcpCor $e.CurRotuloTela 'Creme' } else { Format-IcpComandoColorido -Texto $resumo }
                    Write-Host "$(Format-IcpCor '│ ' 'Pedra')$(Format-IcpCor "[$($e.CurReg.N)/$($e.Total)] " 'Neutro')$(Format-IcpCor 'NAO_EXECUTADO' 'Pedra') $labelFmt"
                }
                else {
                    Write-Host "[$($e.CurReg.N)/$($e.Total)] " -NoNewline
                    Write-Host 'NAO_EXECUTADO' -ForegroundColor $e.Cores.NAO_EXECUTADO -NoNewline
                    Write-Host " $labelExib"
                }
                $e.Res.Add($e.CurReg)
                $e.CurReg = $null
                $e.Index++
                $e.CurSkipped = $true
                return 'skip'
            }

            $e.CurNativo = Test-IcpNativo -Ast $e.CurStmt
            $e.CurAntigos = [System.Collections.Generic.HashSet[object]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
            foreach ($errItem in $global:Error) { [void]$e.CurAntigos.Add($errItem) }
            $e.CurEmitSet = [System.Collections.Generic.HashSet[object]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
            $e.CurEmitSetMax = [Math]::Max(512, $global:Error.Count + 64)
            $e.CurItens = [System.Collections.Generic.List[object]]::new()
            $e.CurExc = $null
            $e.CurCapturedChars = 0
            $e.CurDroppedItems = 0
            $e.CurCaptureTruncated = $false
            $e.CurExtraErrors = 0
            $e.CurHasNewError = $false
            $e.CurSemSaidaS = $null
            $e.CurMortos.Clear()
            $e.CurFilhosAtivos.Clear()
            $global:LASTEXITCODE = 0

            $querInterativo = $e.ModoInterativo -or ([bool]($null -ne $meta -and $meta.Interativo))
            if ($querInterativo -and -not $e.TemEntradaInterativa) {
                if (-not $e.ModoInterativo) {
                    Write-Host 'icp: #* interactive ignorado em modo não interativo (executando em modo capturado).' -ForegroundColor Yellow
                }
                $querInterativo = $false
            }

            if ($querInterativo) {
                $e.CurInterativoCmd = $true
                $e.CurReg.Interativo = $true
                $e.CurDiretoInterativo = Test-IcpInterativoDireto -Ast $e.CurStmt -EhNativo $e.CurNativo
                $e.CurForcarCor = $false
                $e.CurEnvAntes = $null
                $e.CurBaseFilhos = if ($e.TemProcessTree) { Get-AgentToolsProcessBaseline -RootPid $PID } else { $null }
                $borda = Format-IcpCor '│ ' 'Pedra'
                $cabInt = "$borda$(Format-IcpCor "[$($e.CurReg.N)/$($e.Total)]" 'Neutro') $(Format-IcpCor '▸ INTERATIVO' 'Ambar' -Negrito) "
                $cabInt += if ($e.CurRotuloTela) { Format-IcpCor $e.CurRotuloTela 'Creme' -Negrito } else { Format-IcpComandoColorido -Texto $resumo }
                Write-Host $cabInt
                if ($e.TimeoutSeg -gt 0) {
                    Write-Host "$borda  $(Format-IcpCor '[INTERATIVO] timeout suspenso durante interação do operador' 'Neutro')"
                }
                $e.CurLastOutputSw = [System.Diagnostics.Stopwatch]::StartNew()
                $e.CurSw = [System.Diagnostics.Stopwatch]::StartNew()
                $e.CurConcluiu = $false
                $e.CurSkipped = $false
                return 'run-interactive'
            }

            $e.CurInterativoCmd = $false
            $e.CurDiretoInterativo = $false
            $e.CurOrigem = if ($e.UsarStatus) { Get-IcpOrigemComando -Ast $e.CurStmt } else { '' }
            $e.CurBaseFilhos = $null
            $e.CurForcarCor = $e.PreservarCorTela -and (Test-IcpPodeForcarCorNativa -Ast $e.CurStmt -EhNativo $e.CurNativo)
            $e.CurEnvAntes = @{}
            if ($e.CurForcarCor) {
                foreach ($ek in 'CLICOLOR_FORCE', 'FORCE_COLOR', 'GIT_CONFIG_COUNT') {
                    $e.CurEnvAntes[$ek] = [Environment]::GetEnvironmentVariable($ek, 'Process')
                }
                if ([string]::IsNullOrEmpty($env:CLICOLOR_FORCE) -and [string]::IsNullOrEmpty($env:CLICOLOR)) {
                    [Environment]::SetEnvironmentVariable('CLICOLOR_FORCE', '1', 'Process')
                }
                if ([string]::IsNullOrEmpty($env:FORCE_COLOR)) {
                    [Environment]::SetEnvironmentVariable('FORCE_COLOR', '1', 'Process')
                }
                $gitIdx = 0
                [void][int]::TryParse($env:GIT_CONFIG_COUNT, [ref]$gitIdx)
                $gitCountKey = "GIT_CONFIG_KEY_$gitIdx"
                $gitValKey = "GIT_CONFIG_VALUE_$gitIdx"
                $e.CurEnvAntes[$gitCountKey] = [Environment]::GetEnvironmentVariable($gitCountKey, 'Process')
                $e.CurEnvAntes[$gitValKey] = [Environment]::GetEnvironmentVariable($gitValKey, 'Process')
                [Environment]::SetEnvironmentVariable($gitCountKey, 'color.ui', 'Process')
                [Environment]::SetEnvironmentVariable($gitValKey, 'always', 'Process')
                [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', [string]($gitIdx + 1), 'Process')
            }

            if ($null -ne $e.Status) {
                $e.Status.BeginCommand($e.CurReg.N, $e.Total, $e.CurOrigem, $labelExib, $e.TimeoutSeg)
            }
            elseif ($e.TemProcessTree) {
                $e.CurBaseFilhos = Get-AgentToolsProcessBaseline -RootPid $PID
            }
            $e.CurLastOutputSw = [System.Diagnostics.Stopwatch]::StartNew()
            $e.CurSw = [System.Diagnostics.Stopwatch]::StartNew()
            $e.CurConcluiu = $false
            $e.CurSkipped = $false
            return 'run'
        }
        'cmd' {
            return $e.CurCmdText
        }
        'sink' {
            if ($e.CurSkipped) { return }
            if ($null -ne $e.CurLastOutputSw) { $e.CurLastOutputSw.Restart() }
            $isErr = $Payload -is [System.Management.Automation.ErrorRecord]
            $isNativeErr = $isErr -and ($Payload.FullyQualifiedErrorId -like 'NativeCommandError*')
            $isNewPsErr = $isErr -and (-not $isNativeErr) -and (-not $e.CurAntigos.Contains($Payload))
            if ($isNewPsErr) { $e.CurHasNewError = $true }

            $restante = [Math]::Max(0, $e.MaxCaptureChars - $e.CurCapturedChars)
            $itemLen = Get-IcpItemSizeEstimate -Item $Payload -MaxCheck ($restante + 1)
            if ($itemLen -le $restante) {
                $e.CurCapturedChars += $itemLen
                $e.CurItens.Add($Payload)
            }
            else {
                $e.CurCaptureTruncated = $true
                if ($isErr -and $e.CurExtraErrors -lt 50) {
                    $e.CurExtraErrors++
                    $errTxt = [string]$Payload.ToString()
                    if ($errTxt.Length -gt 1024) { $errTxt = $errTxt.Substring(0, 1023) + '…' }
                    $prefixoErr = if ($isNativeErr) { '' } else { '[ERRO] ' }
                    $e.CurItens.Add("$prefixoErr$errTxt")
                }
                else {
                    $e.CurDroppedItems++
                }
            }
            if ($isErr -and $e.CurEmitSet.Count -lt $e.CurEmitSetMax) {
                [void]$e.CurEmitSet.Add($Payload)
            }
            if ($null -ne $e.Status -and -not $e.CurInterativoCmd) {
                if ($isErr) {
                    if ($isNativeErr) { $e.Status.NoteStderr() }
                    elseif (-not $e.CurAntigos.Contains($Payload)) { $e.Status.NoteError() }
                    else { $e.Status.NoteOutput() }
                }
                else {
                    $e.Status.NoteOutput()
                }
                $silLive = Get-IcpErroSilenciosoCount -ErrosAntigos $e.CurAntigos -Emitidos $e.CurEmitSet
                if ($silLive -gt 0) { $e.Status.NoteSilentError($silLive) }
            }
        }
        'done' {
            if ($null -ne $e.CurSw) { $e.CurSw.Stop() }
            if ($null -ne $e.CurLastOutputSw) { $e.CurLastOutputSw.Stop() }
            $e.CurConcluiu = $true
        }
        'catch' {
            $e.CurExc = $Payload
            if ($null -ne $e.CurSw) { $e.CurSw.Stop() }
            if ($null -ne $e.CurLastOutputSw) { $e.CurLastOutputSw.Stop() }
            $e.CurConcluiu = $true
        }
        'end' {
            if ($null -ne $e.Status -and -not $e.CurInterativoCmd) { $e.Status.EndCommand() }
            if ($e.CurForcarCor -and $null -ne $e.CurEnvAntes) {
                foreach ($ek in $e.CurEnvAntes.Keys) {
                    [Environment]::SetEnvironmentVariable($ek, $e.CurEnvAntes[$ek], 'Process')
                }
            }
            if (-not $e.CurConcluiu) {
                if ($null -ne $e.CurSw) { $e.CurSw.Stop() }
                if ($null -ne $e.CurLastOutputSw) { $e.CurLastOutputSw.Stop() }
                $idleS = if ($null -ne $e.Status -and -not $e.CurInterativoCmd) {
                    [int][Math]::Floor($e.Status.LastIdleSeconds)
                }
                elseif ($null -ne $e.CurLastOutputSw) {
                    [int][Math]::Floor($e.CurLastOutputSw.Elapsed.TotalSeconds)
                }
                else { 0 }
                $e.CurSemSaidaS = $idleS

                if ($null -ne $e.Status -and -not $e.CurInterativoCmd) {
                    foreach ($obs in @($e.Status.LastActiveChildren)) {
                        if (-not [string]::IsNullOrWhiteSpace($obs) -and -not $e.CurFilhosAtivos.Contains($obs)) {
                            $e.CurFilhosAtivos.Add($obs)
                        }
                    }
                    foreach ($rem in @($e.Status.RemainingChildren)) {
                        if (-not [string]::IsNullOrWhiteSpace($rem) -and -not $e.CurFilhosAtivos.Contains($rem)) {
                            $e.CurFilhosAtivos.Add($rem)
                        }
                    }
                }
                elseif ($e.TemProcessTree -and $null -ne $e.CurBaseFilhos) {
                    foreach ($rem in @(Get-AgentToolsNewChild -RootPid $PID -Baseline $e.CurBaseFilhos)) {
                        if (-not [string]::IsNullOrWhiteSpace($rem) -and -not $e.CurFilhosAtivos.Contains($rem)) {
                            $e.CurFilhosAtivos.Add($rem)
                        }
                    }
                }

                $mortosCmd = @()
                if ($null -ne $e.Status -and -not $e.CurInterativoCmd) {
                    $mortosCmd = @($e.Status.KillActiveChildren())
                }
                elseif ($e.TemProcessTree -and $null -ne $e.CurBaseFilhos) {
                    $mortosCmd = @(Stop-AgentToolsNewChild -RootPid $PID -Baseline $e.CurBaseFilhos)
                }
                foreach ($m in $mortosCmd) {
                    if ([string]::IsNullOrWhiteSpace($m)) { continue }
                    if (-not $e.CurMortos.Contains($m)) { $e.CurMortos.Add($m) }
                    if ($e.MortosVistos.Add($m)) { $e.MortosCtrlC.Add($m) }
                }
            }
        }
        'after' {
            if ($e.Parar -and $e.CurReg.Status -eq 'NAO_EXECUTADO') {
                return
            }
            if ($e.CurInterativoCmd) {
                $novosErr = [System.Collections.Generic.List[object]]::new()
                foreach ($errObj in $global:Error) {
                    if ($e.CurAntigos.Contains($errObj)) { break }
                    if ($null -ne $e.CurExc -and ([object]::ReferenceEquals($errObj, $e.CurExc) -or [object]::ReferenceEquals($errObj, $e.CurExc.ErrorRecord))) { continue }
                    $novosErr.Add($errObj)
                }
                for ($ei = $novosErr.Count - 1; $ei -ge 0; $ei--) {
                    $errItem = $novosErr[$ei]
                    $isNat = ($errItem -is [System.Management.Automation.ErrorRecord]) -and ($errItem.FullyQualifiedErrorId -like 'NativeCommandError*')
                    if (-not $isNat) { $e.CurHasNewError = $true }
                    $e.CurItens.Add($errItem)
                    if ($e.CurEmitSet.Count -lt $e.CurEmitSetMax) { [void]$e.CurEmitSet.Add($errItem) }
                }
            }

            $exit = $global:LASTEXITCODE -as [int]
            if ($null -eq $exit) { $exit = 0 }
            $tiposPreview = @(foreach ($it in $e.CurItens) { Get-IcpTipo -Item $it -ErrosAntigos $e.CurAntigos })
            $exitFalhou = -not $e.ExitsPermitidos.Contains($exit)
            $falhou = ($null -ne $e.CurExc) -or $e.CurHasNewError -or ($tiposPreview -contains 'erro') -or $exitFalhou
            $msgTimeout = $null
            if ($null -ne $e.Status -and -not $e.CurInterativoCmd -and $e.Status.TimedOut) {
                $falhou = $true
                $msgTimeout = if ($e.Status.KilledSummary) {
                    "[ERRO] [icp] Timeout após $($e.TimeoutSeg)s: processo(s) filho(s) encerrado(s): $($e.Status.KilledSummary)"
                }
                else {
                    "[ERRO] [icp] Timeout após $($e.TimeoutSeg)s (sem processo filho encerrável)."
                }
            }
            if ($null -ne $e.CurExc) {
                if ($e.CurEmitSet.Count -lt $e.CurEmitSetMax) { [void]$e.CurEmitSet.Add($e.CurExc) }
                $e.CurItens.Add($e.CurExc)
            }
            $tipos = @()
            $marcInterativo = if ($e.CurInterativoCmd) { '[icp: comando executado em modo interativo (saída exibida diretamente no console)]' } else { '' }
            $linhas = ConvertTo-IcpCommandOutput -EngineState $e -StmtAst $e.CurStmt -Itens $e.CurItens.ToArray() `
                -Antigos $e.CurAntigos -NativoFalhou $exitFalhou -CaptureTruncated $e.CurCaptureTruncated `
                -DroppedItems $e.CurDroppedItems -CapturedChars $e.CurCapturedChars `
                -ExtraLine $msgTimeout -MarkerLine $marcInterativo -TiposOut ([ref]$tipos)

            $errosSilenciosos = Get-IcpErroSilenciosoCount -ErrosAntigos $e.CurAntigos -Emitidos $e.CurEmitSet
            $e.CurReg.Silenciosos = $errosSilenciosos
            $spBruto = if ($null -ne $e.Status -and -not $e.CurInterativoCmd) {
                @($e.Status.RemainingChildren)
            }
            elseif ($e.TemProcessTree -and $null -ne $e.CurBaseFilhos) {
                @(Get-AgentToolsNewChild -RootPid $PID -Baseline $e.CurBaseFilhos)
            }
            else { @() }
            $e.CurReg.SegundoPlano = @($spBruto | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            $e.CurReg.Status = if ($falhou) { 'FALHOU' } else { 'OK' }
            $e.CurReg.Ms = [int]$e.CurSw.ElapsedMilliseconds
            if ($e.CurNativo -or $exit -ne 0) {
                $e.CurReg.Exit = $exit
                if (-not $falhou -and $exit -ne 0) {
                    $e.CurReg.ExitPermitido = $true
                }
            }
            if (-not $e.CurInterativoCmd -and
                $e.CurStmt -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                -not $falhou -and $linhas.Count -eq 0) {
                $e.CurReg.Atribuicao = "[Variável atribuída: $($e.CurStmt.Left.Extent.Text)]"
            }
            elseif ($e.Raw) {
                $e.CurReg.Linhas = [string[]]@($linhas)
            }
            else {
                $e.CurReg.Linhas = [string[]]@(Limit-IcpSaida -Linhas $linhas -MaxLinhas $e.MaxLinhas -MaxLargura $e.MaxLargura)
            }
            if ($falhou -and -not $e.Continuar) { $e.Parar = $true }

            $icone = if ($e.CurReg.Status -eq 'OK') { '✓' } else { '✗' }
            $exitTela = if ($null -ne $e.CurReg.Exit -and $e.CurReg.Exit -ne 0) { " exit=$($e.CurReg.Exit)" } else { '' }
            $tela = if ($e.CurInterativoCmd) {
                @(ConvertTo-IcpLinha -Itens $e.CurItens -Tipos $tipos -Largura ([Math]::Max(40, $e.LarguraTela - 4)) -NativoFalhou $exitFalhou -PreservarAnsi:$e.PreservarCorTela | Where-Object { $_.StartsWith('[ERRO] ') })
            }
            elseif ($e.CurReg.Atribuicao) { @($e.CurReg.Atribuicao) }
            else {
                @(ConvertTo-IcpLinha -Itens $e.CurItens -Tipos $tipos -Largura ([Math]::Max(40, $e.LarguraTela - 4)) -NativoFalhou $exitFalhou -PreservarAnsi:$e.PreservarCorTela)
            }
            if ($e.CompactLive -and $e.CurReg.Status -eq 'OK' -and $errosSilenciosos -eq 0 -and $e.CurReg.SegundoPlano.Count -eq 0 -and -not $e.CurInterativoCmd -and -not @($tipos | Where-Object { $_ -match 'Warning|Aviso' }).Count) { $tela = @() }
            if ($msgTimeout) { $tela += $msgTimeout }
            $durTela = Format-IcpDuracao -Ms $e.CurReg.Ms
            $durSuf = if ($e.CurInterativoCmd) { "($durTela · interativo)" } else { "($durTela)" }
            $labelTela = if ($e.CurRotuloTela) { $e.CurRotuloTela } else { $e.CurResumo }

            if ($e.Interativo) {
                $borda = Format-IcpCor '│ ' 'Pedra'
                $corSt = if ($e.CurReg.Status -eq 'OK') { 'Oliva' } else { 'Terracota' }
                $cabCmd = "$borda$(Format-IcpCor "[$($e.CurReg.N)/$($e.Total)]" 'Neutro') $(Format-IcpCor "$icone $($e.CurReg.Status)" $corSt -Negrito)"
                if ($exitTela) {
                    $corExit = if ($e.CurReg.Status -eq 'OK') { 'Pedra' } else { 'Terracota' }
                    $cabCmd += Format-IcpCor $exitTela $corExit
                }
                $cmdSeg = if ($e.CurRotuloTela) { Format-IcpCor $e.CurRotuloTela 'Creme' } else { Format-IcpComandoColorido -Texto $e.CurResumo }
                $cabCmd += " $cmdSeg $(Format-IcpCor $durSuf 'Pedra')"
                Write-Host $cabCmd
                foreach ($l in ($tela | Select-Object -First 40)) {
                    if ($l.StartsWith('[ERRO] ')) {
                        if ($l.Contains([char]27)) { Write-Host "$borda  $(Format-IcpCor '[ERRO] ' 'Terracota')$($l.Substring(7))" }
                        else { Write-Host "$borda  $(Format-IcpCor $l 'Terracota')" }
                    }
                    else { Write-Host "$borda  $l" }
                }
                if ($tela.Count -gt 40) {
                    Write-Host "$borda  $(Format-IcpCor "(+$($tela.Count - 40) linhas; completo no relatório)" 'Neutro')"
                }
                if ($errosSilenciosos -gt 0) {
                    Write-Host "$borda  $(Format-IcpCor "[SILENCIOSO] +$errosSilenciosos erro(s) silencioso(s) registrado(s) em `$global:Error" 'Laranja')"
                }
                if ($e.CurReg.SegundoPlano.Count -gt 0) {
                    Write-Host "$borda  $(Format-IcpCor "[SEGUNDO PLANO] Processo(s) iniciado(s) ainda ativo(s): $($e.CurReg.SegundoPlano -join ', ')" 'Laranja')"
                }
            }
            else {
                Write-Host "[$($e.CurReg.N)/$($e.Total)] " -NoNewline -ForegroundColor DarkGray
                Write-Host "$icone $($e.CurReg.Status)" -ForegroundColor $e.Cores[$e.CurReg.Status] -NoNewline
                if ($exitTela) {
                    $corExitNaoInt = if ($e.CurReg.Status -eq 'OK') { 'DarkGray' } else { 'Red' }
                    Write-Host $exitTela -ForegroundColor $corExitNaoInt -NoNewline
                }
                Write-Host " $labelTela " -NoNewline
                Write-Host $durSuf -ForegroundColor DarkGray
                foreach ($l in ($tela | Select-Object -First 40)) {
                    if ($l.StartsWith('[ERRO] ')) { Write-Host $l -ForegroundColor Red } else { Write-Host $l }
                }
                if ($tela.Count -gt 40) { Write-Host "(+$($tela.Count - 40) linhas; completo no relatório)" -ForegroundColor DarkGray }
                if ($errosSilenciosos -gt 0) {
                    Write-Host "[SILENCIOSO] +$errosSilenciosos erro(s) silencioso(s) registrado(s) em `$global:Error" -ForegroundColor DarkYellow
                }
                if ($e.CurReg.SegundoPlano.Count -gt 0) {
                    Write-Host "[SEGUNDO PLANO] Processo(s) iniciado(s) ainda ativo(s): $($e.CurReg.SegundoPlano -join ', ')" -ForegroundColor Yellow
                }
            }

            $e.Res.Add($e.CurReg)
            $e.CurReg = $null
            $e.Index++

            if ((-not $e.Parar) -and $e.PassoAPasso -and ($e.Index -lt $e.Total)) {
                $proxResumo = ($e.Stmts[$e.Index].Extent.Text -replace '\s+', ' ').Trim()
                if ($proxResumo.Length -gt 70) { $proxResumo = $proxResumo.Substring(0, 69) + '…' }
                $proxMeta = if ($null -ne $e.Metas -and $e.Index -lt $e.Metas.Count) { $e.Metas[$e.Index] } else { $null }
                $proxRot = if ($null -ne $proxMeta -and -not [string]::IsNullOrWhiteSpace($proxMeta.Rotulo)) {
                    $pr = ($proxMeta.Rotulo -replace '\s+', ' ').Trim()
                    if ($pr.Length -gt 70) { $pr.Substring(0, 69) + '…' } else { $pr }
                }
                else { '' }
                $decPasso = Read-IcpConfirmacaoPasso -ProximoN ($e.Index + 1) -Total $e.Total -ProximoComando $proxResumo -ProximoRotulo $proxRot
                if ($decPasso -eq 'todos') { $e.PassoAPasso = $false }
                elseif ($decPasso -eq 'parar') { $e.Parar = $true; $e.ParadoOperador = $true }
            }
        }
    }
}

function Invoke-IcpEngine {
    # Motor de execução isolado do icp: compositor, pré-voo, barra de status, execução, relatório v2 e limpeza de bordas.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'A tela é para o operador; o relatório vai para a área de transferência ou arquivo.')]
    param(
        [scriptblock]$ScriptBlock,
        [ValidateSet('xml', 'json', 'markdown', 'yaml', 'toml')][string]$Format = 'xml',
        [bool]$FormatExplicit = $false,
        [int]$MaxLinesPerCommand = 150,
        [int]$MaxLineLength = 1500,
        [switch]$Raw,
        [switch]$ContinueOnError,
        [int[]]$AllowedExitCodes = @(),
        [int]$MaxClipboardChars = 20000,
        [switch]$NoMask,
        [int]$RedirectTailLines = 5,
        [string]$OutFile = '',
        [switch]$NoClipboard,
        [switch]$AllowTrailingBackslash,
        [switch]$Explain,
        [switch]$Step,
        [switch]$Interactive,
        [switch]$CompactLive,
        [switch]$NoStatus,
        [int]$CommandTimeoutSeconds = 0,
        [switch]$KeepBlock,
        [switch]$Help,
        [switch]$Full,
        [switch]$Demo,
        [bool]$ModoOutFile = $false,
        $CallerInvocation = $null,
        [string]$ParameterSetName = 'Exec'
    )
    if ($ParameterSetName -eq 'Help' -or $Help) {
        $__encAntesH = try { [Console]::OutputEncoding } catch { $null }
        try {
            try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { $null = $_ }
            if ($Demo) { Show-IcpDemo; return }
            Show-IcpAjuda -Full:$Full
            return
        }
        finally {
            Restore-AgentToolsConsoleState -OutputEncoding $__encAntesH
        }
    }

    $__paramSet = $ParameterSetName
    $__formatosValidos = @('xml', 'json', 'markdown', 'yaml', 'toml')
    if ($FormatExplicit) {
        $__formato = $Format.ToLowerInvariant()
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:AGENTTOOLS_ICP_FORMAT) -and
        ($env:AGENTTOOLS_ICP_FORMAT.Trim().ToLowerInvariant() -in $__formatosValidos)) {
        $__formato = $env:AGENTTOOLS_ICP_FORMAT.Trim().ToLowerInvariant()
    }
    else {
        $__formato = $Format.ToLowerInvariant()
    }
    $__explicar = [bool]$Explain
    $__passoAPasso = [bool]$Step
    $__modoInterativo = [bool]$Interactive
    $__jaRecolheu = $false
    $__raw = [bool]$Raw
    $__continuar = [bool]$ContinueOnError
    $__exitsPermitidos = [System.Collections.Generic.HashSet[int]]::new([int[]]@(0))
    foreach ($__ec in @($AllowedExitCodes)) { [void]$__exitsPermitidos.Add([int]$__ec) }
    $__maxLinhas = $MaxLinesPerCommand
    $__maxLargura = $MaxLineLength
    $__maxClip = $MaxClipboardChars
    $__mascarar = -not $NoMask
    $__tailRedir = $RedirectTailLines
    $__outArq = $OutFile
    $__modoOut = [bool]$ModoOutFile
    $__outVazio = $__modoOut -and [string]::IsNullOrWhiteSpace($__outArq)
    $__outCaminho = $null
    $__outErro = $null
    if ($__modoOut -and -not $__outVazio) {
        try { $__outCaminho = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($__outArq) }
        catch { $__outErro = $_.Exception.Message; $__outCaminho = $null }
    }
    $__semClip = [bool]$NoClipboard
    $__permitirBarra = [bool]$AllowTrailingBackslash
    $__semStatus = [bool]$NoStatus
    $__timeoutSeg = $CommandTimeoutSeconds
    $__manterBloco = [bool]$KeepBlock
    $__invChamador = $CallerInvocation

    $__encAntes = try { [Console]::OutputEncoding } catch { $null }
    $__encInAntes = try { [Console]::InputEncoding } catch { $null }
    $script:IcpProfundidade++
    try {
        if ($__paramSet -eq 'Inicio') {
            if (-not (Test-IcpInterativo -RequireInput)) {
                Write-Host 'Uso: icp { <comandos> } | icp -Help'
                return
            }
            try {
                try {
                    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
                    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
                }
                catch { $null = $_ }
                $__comp = Invoke-IcpCompositor
                if (-not $__comp -or -not $__comp.Executar) { return }
                Clear-IcpLinhasTela -Linhas $__comp.LinhasTela
                $ScriptBlock = $__comp.ScriptBlock
                $__explicar = [bool]$__comp.Explain
                $__passoAPasso = [bool]$__comp.Step
                $__modoInterativo = [bool]$__comp.Interactive
                $__jaRecolheu = $true
            }
            finally {
                Restore-AgentToolsConsoleState -OutputEncoding $__encAntes -InputEncoding $__encInAntes
            }
        }

        $__interativo = Test-IcpInterativo
        $__temEntradaInterativa = Test-IcpInterativo -RequireInput
        $__cursorAntes = if ($__interativo) { try { [Console]::CursorVisible } catch { $null } } else { $null }
        $__usarStatus = (-not $__semStatus) -and $__interativo
        $__preservarCorTela = $__interativo -and [string]::IsNullOrEmpty($env:NO_COLOR)
        if ($__passoAPasso -and -not $__temEntradaInterativa) {
            Write-Host 'icp: -Step ignorado em modo não interativo (executando sem pausas).' -ForegroundColor Yellow
            $__passoAPasso = $false
        }
        if ($__modoInterativo -and -not $__temEntradaInterativa) {
            Write-Host 'icp: -Interactive ignorado em modo não interativo (executando em modo capturado).' -ForegroundColor Yellow
            $__modoInterativo = $false
        }

        $__stmts = if ($null -ne $ScriptBlock.Ast.EndBlock) { @($ScriptBlock.Ast.EndBlock.Statements) } else { @() }
        $__comLabelsEnv = $env:AGENTTOOLS_ICP_COMMENT_LABELS
        $__usarComPlain = (-not [string]::IsNullOrWhiteSpace($__comLabelsEnv)) -and ($__comLabelsEnv.Trim() -notmatch '^(?i)(?:0|false)$')
        $__metas = @(Get-IcpStatementMeta -Ast $ScriptBlock.Ast -AllowPlainComments:$__usarComPlain)

        $__larguraTela = try { $Host.UI.RawUI.WindowSize.Width - 1 } catch { 0 }
        if ($__larguraTela -lt 40) { $__larguraTela = 120 }

        if ($__usarStatus -and (-not $__manterBloco) -and (-not $__jaRecolheu) -and ($null -ne $__invChamador)) {
            if ([string]::IsNullOrEmpty($__invChamador.ScriptName) -and
                $__invChamador.CommandOrigin -eq 'Runspace' -and
                $__invChamador.OffsetInLine -le 1) {
                $__winW = try { [Console]::WindowWidth } catch { 120 }
                $__winH = try { [Console]::WindowHeight } catch { 30 }
                $__medBloco = Measure-IcpLinhasBloco -InvocationLine $__invChamador.Line `
                    -ScriptBlockText $ScriptBlock.Ast.Extent.Text `
                    -WindowWidth $__winW -WindowHeight $__winH
                if ($__medBloco.Cabe) {
                    Clear-IcpLinhasTela -Linhas $__medBloco.Recolher
                }
            }
        }

        $__swTotal = [System.Diagnostics.Stopwatch]::StartNew()
        $__temaInt = if ($__interativo) { Get-IcpTema } else { $null }
        $__prefInt = if ($__interativo -and $null -ne $__temaInt) { "$($__temaInt.Pedra)│ $($__temaInt.Reset)  $($__temaInt.Laranja)" } else { '' }
        $__sufInt = if ($__interativo -and $null -ne $__temaInt) { $__temaInt.Reset } else { '' }

        $__eng = @{
            Stmts                = $__stmts
            Metas                = $__metas
            Total                = $__stmts.Count
            Index                = 0
            Res                  = [System.Collections.Generic.List[object]]::new()
            Parar                = $false
            ParadoOperador       = $false
            InterrompidoCtrlC    = $false
            Bloqueado            = $false
            Bloqueios            = @()
            Ocultos              = 0
            Formato              = $__formato
            Explicar             = $__explicar
            Raw                  = $__raw
            Continuar            = $__continuar
            AllowedExitCodes     = $AllowedExitCodes
            ExitsPermitidos      = $__exitsPermitidos
            MaxLinhas            = $__maxLinhas
            MaxLargura           = $__maxLargura
            MaxClip              = $__maxClip
            Mascarar             = $__mascarar
            TailRedir            = $__tailRedir
            PermitirBarra        = $__permitirBarra
            PassoAPasso          = $__passoAPasso
            PassoAPassoInicial   = $__passoAPasso
            ModoInterativo       = $__modoInterativo
            TemEntradaInterativa = $__temEntradaInterativa
            TimeoutSeg           = $__timeoutSeg
            ModoOut              = $__modoOut
            OutVazio             = $__outVazio
            OutErro              = $__outErro
            OutCaminho           = $__outCaminho
            OutArq               = $__outArq
            SemClip              = $__semClip
            CompactLive          = [bool]$CompactLive
            Interativo           = $__interativo
            UsarStatus           = $__usarStatus
            PreservarCorTela     = $__preservarCorTela
            LarguraTela          = $__larguraTela
            Cores                = @{ OK = 'Green'; FALHOU = 'Red'; NAO_EXECUTADO = 'DarkGray' }
            TemStatusBar         = $false
            TemProcessTree       = $false
            BaseFilhosLote       = $null
            Status               = $null
            MortosCtrlC          = [System.Collections.Generic.List[string]]::new()
            MortosVistos         = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            ConcluiuLaco         = $false
            MaxCaptureChars      = Get-IcpMaxCaptureChar
            CurStmt              = $null
            CurCmdText           = ''
            CurResumo            = ''
            CurRotulo            = $null
            CurRotuloTela        = $null
            CurInterativoCmd     = $false
            CurDiretoInterativo  = $false
            CurReg               = $null
            CurNativo            = $false
            CurAntigos           = $null
            CurEmitSet           = $null
            CurEmitSetMax        = 512
            CurItens             = $null
            CurExc               = $null
            CurSw                = $null
            CurLastOutputSw      = $null
            CurSemSaidaS         = $null
            CurMortos            = [System.Collections.Generic.List[string]]::new()
            CurFilhosAtivos      = [System.Collections.Generic.List[string]]::new()
            CurConcluiu          = $false
            CurSkipped           = $false
            CurOrigem            = ''
            CurBaseFilhos        = $null
            CurForcarCor         = $false
            CurEnvAntes          = $null
            CurCapturedChars     = 0
            CurDroppedItems      = 0
            CurCaptureTruncated  = $false
            CurExtraErrors       = 0
            CurHasNewError       = $false
        }

        if ($null -eq $script:IcpEngineStack) {
            $script:IcpEngineStack = [System.Collections.Generic.Stack[hashtable]]::new()
        }
        $script:IcpEngineStack.Push($__eng)
        $__ambInfo = $null
        $__relatorioEmitido = $false
        try {
            try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { $null = $_ }
            $__ambInfo = Get-IcpAmbienteInfo
            $__eng.Bloqueios = @(Test-IcpPreVoo -Ast $ScriptBlock.Ast -AllowTrailingBackslash:$__permitirBarra)
            $__eng.Bloqueado = $__eng.Bloqueios.Count -gt 0
            $__eng.Parar = $__eng.Bloqueado

            if ($__interativo) {
                $__modoCab = if ($__explicar) { 'completo/-Explain' } else { 'compacto' }
                if ($__continuar) { $__modoCab += ' · -ContinueOnError' }
                if ($__passoAPasso) { $__modoCab += ' · -Step' }
                if ($__modoInterativo) { $__modoCab += ' · -Interactive' }
                if ($__formato -ne 'xml') { $__modoCab += " · $__formato" }
                if ($__eng.Bloqueado) { $__modoCab += ' · pré-voo' }
                Write-Host "$(Format-IcpCor '╭─' 'Petroleo') $(Format-IcpCor 'icp' 'Ambar' -Negrito) $(Format-IcpCor "· $($__eng.Total) comando(s) · $__modoCab" 'Neutro')"
            }

            if ($__eng.Bloqueado) {
                foreach ($__b in $__eng.Bloqueios) {
                    if ($__interativo) {
                        Write-Host "$(Format-IcpCor '│ ' 'Pedra')$(Format-IcpCor "[PRE-VOO] BLOQUEADO: $__b" 'Terracota' -Negrito)"
                    }
                    else {
                        Write-Host "[PRE-VOO] BLOQUEADO: $__b" -ForegroundColor Red
                    }
                }
                while ((Invoke-IcpEngineDispatch -Action 'begin') -ne 'stop') { }
            }
            elseif ($__eng.Total -gt 0) {
                $__eng.TemStatusBar = Initialize-IcpStatusBar
                $__eng.TemProcessTree = if ($__eng.TemStatusBar) { $true } else { Initialize-AgentToolsProcessTree }
                if ($__eng.TemProcessTree) {
                    $__eng.BaseFilhosLote = Get-AgentToolsProcessBaseline -RootPid $PID
                }
                if ($__eng.TemStatusBar -and ($__usarStatus -or $__timeoutSeg -gt 0)) {
                    $__barType = Get-IcpStatusBarType
                    $__eng.Status = $__barType::new($__usarStatus, $__interativo, (Get-IcpStatusBarPalette))
                }

                # Executa os comandos do usuário em módulo anônimo isolado sem expor o despachante do motor.
                $__userMod = [psmoduleinfo]::new($true)
                $__execInUserMod = {
                    param([psmoduleinfo]$__m, [scriptblock]$__sb)
                    . $__m $__sb
                }
                while (($__step = Invoke-IcpEngineDispatch -Action 'begin') -ne 'stop') {
                    if ($__step -eq 'skip') { continue }
                    try {
                        $__userSb = [scriptblock]::Create((Invoke-IcpEngineDispatch -Action 'cmd'))
                        if ($__step -eq 'run-interactive') {
                            if ($__eng.CurDiretoInterativo) {
                                & $__execInUserMod $__userMod $__userSb
                            }
                            else {
                                & $__execInUserMod $__userMod $__userSb | Out-Host
                            }
                        }
                        else {
                            & $__execInUserMod $__userMod $__userSb *>&1 | ForEach-Object {
                                Invoke-IcpEngineDispatch -Action 'sink' -Payload $_
                            }
                        }
                        Invoke-IcpEngineDispatch -Action 'done'
                    }
                    catch {
                        Invoke-IcpEngineDispatch -Action 'catch' -Payload $_
                    }
                    finally {
                        Invoke-IcpEngineDispatch -Action 'end'
                    }
                    Invoke-IcpEngineDispatch -Action 'after'
                }
            }
            $__eng.ConcluiuLaco = $true
        }
        catch {
            Write-Host "icp: erro interno: $_" -ForegroundColor Red
        }
        finally {
            if ($null -ne $__eng.Status) {
                try { $__eng.Status.Dispose() } catch { $null = $_ }
            }
            if (-not $__eng.ConcluiuLaco) {
                if ($null -ne $__eng.CurSw) { try { $__eng.CurSw.Stop() } catch { $null = $_ } }
                if ($null -ne $__eng.CurLastOutputSw) { try { $__eng.CurLastOutputSw.Stop() } catch { $null = $_ } }
                if ($__eng.TemProcessTree -and $null -ne $__eng.BaseFilhosLote) {
                    try {
                        foreach ($__m in @(Stop-AgentToolsNewChild -RootPid $PID -Baseline $__eng.BaseFilhosLote)) {
                            if ([string]::IsNullOrWhiteSpace($__m)) { continue }
                            if (-not $__eng.CurMortos.Contains($__m)) { $__eng.CurMortos.Add($__m) }
                            if ($__eng.MortosVistos.Add($__m)) { $__eng.MortosCtrlC.Add($__m) }
                        }
                    }
                    catch { $null = $_ }
                }

                if ($null -ne $__eng.CurReg -and ($__eng.CurReg.N -eq ($__eng.Index + 1)) -and ($__eng.Res.Count -eq $__eng.Index) -and (-not $__eng.CurSkipped)) {
                    $__filhosRel = [System.Collections.Generic.List[string]]::new()
                    $__vistosRel = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    $__fonteFilhos = if ($__eng.CurMortos.Count -gt 0) { $__eng.CurMortos } else { $__eng.CurFilhosAtivos }
                    foreach ($__fn in $__fonteFilhos) {
                        if (-not [string]::IsNullOrWhiteSpace($__fn) -and $__vistosRel.Add($__fn)) {
                            $__filhosRel.Add($__fn)
                        }
                    }
                    $__marcInt = if ($__filhosRel.Count -gt 0) {
                        "[icp: comando interrompido pelo operador (Ctrl+C); processo(s): $($__filhosRel -join ', ')]"
                    }
                    else {
                        '[icp: comando interrompido pelo operador (Ctrl+C)]'
                    }
                    $__linhasInt = ConvertTo-IcpCommandOutput -EngineState $__eng -StmtAst $__eng.CurStmt `
                        -Itens $__eng.CurItens.ToArray() -Antigos $__eng.CurAntigos -NativoFalhou $true `
                        -CaptureTruncated $__eng.CurCaptureTruncated -DroppedItems $__eng.CurDroppedItems `
                        -CapturedChars $__eng.CurCapturedChars -MarkerLine $__marcInt
                    if (-not $__eng.Raw) {
                        $__linhasInt = [string[]]@(Limit-IcpSaida -Linhas $__linhasInt -MaxLinhas $__eng.MaxLinhas -MaxLargura $__eng.MaxLargura)
                    }
                    $__semSaidaFinal = if ($null -ne $__eng.CurSemSaidaS) {
                        [int]$__eng.CurSemSaidaS
                    }
                    elseif ($null -ne $__eng.CurLastOutputSw) {
                        [int][Math]::Floor($__eng.CurLastOutputSw.Elapsed.TotalSeconds)
                    }
                    else { 0 }
                    $__spInt = if ($__eng.TemProcessTree -and $null -ne $__eng.CurBaseFilhos) {
                        @(Get-AgentToolsNewChild -RootPid $PID -Baseline $__eng.CurBaseFilhos | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                    }
                    else { @() }

                    $__eng.CurReg.Status = 'INTERROMPIDO'
                    $__eng.CurReg.Ms = if ($null -ne $__eng.CurSw) { [int]$__eng.CurSw.ElapsedMilliseconds } else { 0 }
                    $__eng.CurReg.Linhas = $__linhasInt
                    $__eng.CurReg.Filho = [string[]]$__filhosRel.ToArray()
                    $__eng.CurReg.SemSaidaS = $__semSaidaFinal
                    $__eng.CurReg.Silenciosos = Get-IcpErroSilenciosoCount -ErrosAntigos $__eng.CurAntigos -Emitidos $__eng.CurEmitSet
                    $__eng.CurReg.SegundoPlano = $__spInt
                    $__eng.Res.Add($__eng.CurReg)
                    $__eng.CurReg = $null
                    $__eng.Index++
                }

                while ($__eng.Index -lt $__eng.Total) {
                    $__remStmt = $__eng.Stmts[$__eng.Index]
                    $__remCmd = $__remStmt.Extent.Text
                    $__remMeta = if ($null -ne $__eng.Metas -and $__eng.Index -lt $__eng.Metas.Count) { $__eng.Metas[$__eng.Index] } else { $null }
                    $__remRot = if ($null -ne $__remMeta) { $__remMeta.Rotulo } else { $null }
                    if ($__eng.Mascarar) {
                        $__ocRem = 0
                        $__remAstMasc = Hide-IcpAtribuicaoSensivel -Ast $__remStmt -Text $__remCmd -Contagem ([ref]$__ocRem)
                        $__remCmd = Hide-IcpSegredo -Text $__remAstMasc -Contagem ([ref]$__ocRem)
                        if (-not [string]::IsNullOrWhiteSpace($__remRot)) {
                            $__remRot = Hide-IcpSegredo -Text $__remRot -Contagem ([ref]$__ocRem)
                        }
                        $__eng.Ocultos += $__ocRem
                    }
                    $__eng.Res.Add([pscustomobject]@{
                        N             = $__eng.Index + 1
                        Comando       = $__remCmd
                        Rotulo        = $__remRot
                        Interativo    = $false
                        Status        = 'NAO_EXECUTADO'
                        Exit          = $null
                        ExitPermitido = $false
                        Ms            = 0
                        Linhas        = @()
                        Atribuicao    = $null
                        Silenciosos   = 0
                        SegundoPlano  = @()
                        Filho         = @()
                        SemSaidaS     = $null
                    })
                    $__eng.Index++
                }

                $__eng.InterrompidoCtrlC = $true
                $__eng.ParadoOperador = $true

                $__mortosLimpos = @($__eng.MortosCtrlC | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $__ativosLimpos = @($__eng.CurFilhosAtivos | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($__mortosLimpos.Count -gt 0) {
                    $__msgInt = "[INTERROMPIDO] Processo(s) filho(s) encerrado(s): $($__mortosLimpos -join ', ')"
                }
                elseif ($__ativosLimpos.Count -gt 0) {
                    $__msgInt = "[INTERROMPIDO] Execução interrompida pelo operador (processo(s) filho(s): $($__ativosLimpos -join ', '))"
                }
                else {
                    $__msgInt = '[INTERROMPIDO] Execução interrompida pelo operador.'
                }
                try { [Console]::WriteLine("$__prefInt$__msgInt$__sufInt") } catch { $null = $_ }

                $__swTotal.Stop()
                try {
                    Complete-IcpReportDelivery -Eng $__eng -MsTotal ([int]$__swTotal.ElapsedMilliseconds) -AmbienteInfo $__ambInfo -InterrompidoCtrlC
                    $__relatorioEmitido = $true
                }
                catch { $null = $_ }
            }
            Restore-AgentToolsConsoleState -OutputEncoding $__encAntes -InputEncoding $__encInAntes -RestoreCursor:$($__interativo -and -not $__eng.ConcluiuLaco) -CursorVisibleBefore $__cursorAntes
            if ($script:IcpEngineStack.Count -gt 0) {
                $null = $script:IcpEngineStack.Pop()
            }
        }
        $__swTotal.Stop()
        if (-not $__relatorioEmitido) {
            Complete-IcpReportDelivery -Eng $__eng -MsTotal ([int]$__swTotal.ElapsedMilliseconds) -AmbienteInfo $__ambInfo
        }
    }
    finally {
        $script:IcpProfundidade = [Math]::Max(0, $script:IcpProfundidade - 1)
    }
}
