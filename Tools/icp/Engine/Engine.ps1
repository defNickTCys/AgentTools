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
            $e.CurReg = [pscustomobject]@{
                N             = $e.Index + 1
                Comando       = $e.CurCmdText
                Status        = 'NAO_EXECUTADO'
                Exit          = $null
                ExitPermitido = $false
                Ms            = 0
                Linhas        = @()
                Atribuicao    = $null
                Silenciosos   = 0
                SegundoPlano  = @()
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

            if ($e.Parar) {
                if ($e.Interativo) {
                    Write-Host "$(Format-IcpCor '│ ' 'Pedra')$(Format-IcpCor "[$($e.CurReg.N)/$($e.Total)] " 'Neutro')$(Format-IcpCor 'NAO_EXECUTADO' 'Pedra') $(Format-IcpComandoColorido -Texto $resumo)"
                }
                else {
                    Write-Host "[$($e.CurReg.N)/$($e.Total)] " -NoNewline
                    Write-Host 'NAO_EXECUTADO' -ForegroundColor $e.Cores.NAO_EXECUTADO -NoNewline
                    Write-Host " $resumo"
                }
                $e.Res.Add($e.CurReg)
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
            $global:LASTEXITCODE = 0

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
                $e.Status.BeginCommand($e.CurReg.N, $e.Total, $e.CurOrigem, $resumo, $e.TimeoutSeg)
            }
            elseif ($e.TemProcessTree) {
                $e.CurBaseFilhos = Get-AgentToolsProcessBaseline -RootPid $PID
            }
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
            if ($null -ne $e.Status) {
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
            $e.CurConcluiu = $true
        }
        'catch' {
            $e.CurExc = $Payload
            if ($null -ne $e.CurSw) { $e.CurSw.Stop() }
            $e.CurConcluiu = $true
        }
        'end' {
            if ($null -ne $e.Status) { $e.Status.EndCommand() }
            if ($e.CurForcarCor -and $null -ne $e.CurEnvAntes) {
                foreach ($ek in $e.CurEnvAntes.Keys) {
                    [Environment]::SetEnvironmentVariable($ek, $e.CurEnvAntes[$ek], 'Process')
                }
            }
            if (-not $e.CurConcluiu) {
                $mortosCmd = @()
                if ($null -ne $e.Status) {
                    $mortosCmd = @($e.Status.KillActiveChildren())
                }
                elseif ($e.TemProcessTree -and $null -ne $e.CurBaseFilhos) {
                    $mortosCmd = @(Stop-AgentToolsNewChild -RootPid $PID -Baseline $e.CurBaseFilhos)
                }
                foreach ($m in $mortosCmd) {
                    if ($e.MortosVistos.Add($m)) { $e.MortosCtrlC.Add($m) }
                }
            }
        }
        'after' {
            if ($e.Parar -and $e.CurReg.Status -eq 'NAO_EXECUTADO') {
                return
            }
            $exit = $global:LASTEXITCODE -as [int]
            if ($null -eq $exit) { $exit = 0 }
            $tipos = @(foreach ($it in $e.CurItens) { Get-IcpTipo -Item $it -ErrosAntigos $e.CurAntigos })
            $exitFalhou = -not $e.ExitsPermitidos.Contains($exit)
            $falhou = ($null -ne $e.CurExc) -or $e.CurHasNewError -or ($tipos -contains 'erro') -or $exitFalhou
            $msgTimeout = $null
            if ($null -ne $e.Status -and $e.Status.TimedOut) {
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
                $tipos += 'erro'
            }
            $linhas = @(ConvertTo-IcpLinha -Itens $e.CurItens -Tipos $tipos -Largura 4096 -NativoFalhou $exitFalhou)
            if ($msgTimeout) { $linhas += $msgTimeout }
            if ($e.CurCaptureTruncated) {
                $linhas += "[icp: captura limitada em $($e.MaxCaptureChars) chars; $($e.CurDroppedItems) item(ns) excedente(s) descartado(s)]"
            }
            if ($e.TailRedir -gt 0) {
                $saldoRedir = [Math]::Max(256, [Math]::Min(65536, $e.MaxCaptureChars - $e.CurCapturedChars))
                $linhas += @(Get-IcpRedirecionamento -Ast $e.CurStmt -Tail $e.TailRedir -MaxChars $saldoRedir)
            }
            if ($e.Mascarar -and $linhas.Count -gt 0) {
                $ocultosOut = 0
                $linhas = @((Hide-IcpSegredo -Text ($linhas -join "`n") -Contagem ([ref]$ocultosOut)) -split "`n")
                $e.Ocultos += $ocultosOut
            }

            $errosSilenciosos = Get-IcpErroSilenciosoCount -ErrosAntigos $e.CurAntigos -Emitidos $e.CurEmitSet
            $e.CurReg.Silenciosos = $errosSilenciosos
            $e.CurReg.SegundoPlano = if ($null -ne $e.Status) {
                @($e.Status.RemainingChildren)
            }
            elseif ($e.TemProcessTree -and $null -ne $e.CurBaseFilhos) {
                @(Get-AgentToolsNewChild -RootPid $PID -Baseline $e.CurBaseFilhos)
            }
            else { @() }

            $e.CurReg.Status = if ($falhou) { 'FALHOU' } else { 'OK' }
            $e.CurReg.Ms = [int]$e.CurSw.ElapsedMilliseconds
            if ($e.CurNativo -or $exit -ne 0) {
                $e.CurReg.Exit = $exit
                if (-not $falhou -and $exit -ne 0) {
                    $e.CurReg.ExitPermitido = $true
                }
            }
            if ($e.CurStmt -is [System.Management.Automation.Language.AssignmentStatementAst] -and
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
            $tela = if ($e.CurReg.Atribuicao) { @($e.CurReg.Atribuicao) } else {
                @(ConvertTo-IcpLinha -Itens $e.CurItens -Tipos $tipos -Largura ([Math]::Max(40, $e.LarguraTela - 4)) -NativoFalhou $exitFalhou -PreservarAnsi:$e.PreservarCorTela)
            }
            if ($msgTimeout) { $tela += $msgTimeout }
            if ($e.Interativo) {
                $borda = Format-IcpCor '│ ' 'Pedra'
                $corSt = if ($e.CurReg.Status -eq 'OK') { 'Oliva' } else { 'Terracota' }
                $cabCmd = "$borda$(Format-IcpCor "[$($e.CurReg.N)/$($e.Total)]" 'Neutro') $(Format-IcpCor "$icone $($e.CurReg.Status)" $corSt -Negrito)"
                if ($exitTela) {
                    $corExit = if ($e.CurReg.Status -eq 'OK') { 'Pedra' } else { 'Terracota' }
                    $cabCmd += Format-IcpCor $exitTela $corExit
                }
                $cabCmd += " $(Format-IcpComandoColorido -Texto $e.CurResumo) $(Format-IcpCor "($(Format-IcpDuracao -Ms $e.CurReg.Ms))" 'Pedra')"
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
                Write-Host " $($e.CurResumo) " -NoNewline
                Write-Host "($(Format-IcpDuracao -Ms $e.CurReg.Ms))" -ForegroundColor DarkGray
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

            if ((-not $e.Parar) -and $e.PassoAPasso -and ($e.Index + 1 -lt $e.Total)) {
                $proxResumo = ($e.Stmts[$e.Index + 1].Extent.Text -replace '\s+', ' ').Trim()
                if ($proxResumo.Length -gt 70) { $proxResumo = $proxResumo.Substring(0, 69) + '…' }
                $decPasso = Read-IcpConfirmacaoPasso -ProximoN ($e.Index + 2) -Total $e.Total -ProximoComando $proxResumo
                if ($decPasso -eq 'todos') { $e.PassoAPasso = $false }
                elseif ($decPasso -eq 'parar') { $e.Parar = $true; $e.ParadoOperador = $true }
            }

            $e.Res.Add($e.CurReg)
            $e.Index++
        }
    }
}

function Invoke-IcpEngine {
    # Motor de execução isolado do icp: compositor, pré-voo, barra de status, execução, relatório v2 e limpeza de bordas.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'A tela é para o operador; o relatório vai para a área de transferência ou arquivo.')]
    param(
        [scriptblock]$ScriptBlock,
        [ValidateSet('xml', 'json', 'markdown')][string]$Format = 'xml',
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
    $__formato = $Format.ToLowerInvariant()
    $__explicar = [bool]$Explain
    $__passoAPasso = [bool]$Step
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
                $__jaRecolheu = $true
            }
            finally {
                Restore-AgentToolsConsoleState -OutputEncoding $__encAntes -InputEncoding $__encInAntes
            }
        }

        $__interativo = Test-IcpInterativo
        $__cursorAntes = if ($__interativo) { try { [Console]::CursorVisible } catch { $null } } else { $null }
        $__usarStatus = (-not $__semStatus) -and $__interativo
        $__preservarCorTela = $__interativo -and [string]::IsNullOrEmpty($env:NO_COLOR)
        if ($__passoAPasso -and -not (Test-IcpInterativo -RequireInput)) {
            Write-Host 'icp: -Step ignorado em modo não interativo (executando sem pausas).' -ForegroundColor Yellow
            $__passoAPasso = $false
        }

        $__stmts = if ($null -ne $ScriptBlock.Ast.EndBlock) { @($ScriptBlock.Ast.EndBlock.Statements) } else { @() }
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
            Stmts               = $__stmts
            Total               = $__stmts.Count
            Index               = 0
            Res                 = [System.Collections.Generic.List[object]]::new()
            Parar               = $false
            ParadoOperador      = $false
            Bloqueado           = $false
            Bloqueios           = @()
            Ocultos             = 0
            Raw                 = $__raw
            Continuar           = $__continuar
            ExitsPermitidos     = $__exitsPermitidos
            MaxLinhas           = $__maxLinhas
            MaxLargura          = $__maxLargura
            Mascarar            = $__mascarar
            TailRedir           = $__tailRedir
            PassoAPasso         = $__passoAPasso
            TimeoutSeg          = $__timeoutSeg
            Interativo          = $__interativo
            UsarStatus          = $__usarStatus
            PreservarCorTela    = $__preservarCorTela
            LarguraTela         = $__larguraTela
            Cores               = @{ OK = 'Green'; FALHOU = 'Red'; NAO_EXECUTADO = 'DarkGray' }
            TemStatusBar        = $false
            TemProcessTree      = $false
            BaseFilhosLote      = $null
            Status              = $null
            MortosCtrlC         = [System.Collections.Generic.List[string]]::new()
            MortosVistos        = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            ConcluiuLaco        = $false
            MaxCaptureChars     = Get-IcpMaxCaptureChar
            CurStmt             = $null
            CurCmdText          = ''
            CurResumo           = ''
            CurReg              = $null
            CurNativo           = $false
            CurAntigos          = $null
            CurEmitSet          = $null
            CurEmitSetMax       = 512
            CurItens            = $null
            CurExc              = $null
            CurSw               = $null
            CurConcluiu         = $false
            CurSkipped          = $false
            CurOrigem           = ''
            CurBaseFilhos       = $null
            CurForcarCor        = $false
            CurEnvAntes         = $null
            CurCapturedChars    = 0
            CurDroppedItems     = 0
            CurCaptureTruncated = $false
            CurExtraErrors      = 0
            CurHasNewError      = $false
        }

        if ($null -eq $script:IcpEngineStack) {
            $script:IcpEngineStack = [System.Collections.Generic.Stack[hashtable]]::new()
        }
        $script:IcpEngineStack.Push($__eng)
        $__ambInfo = $null
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
                        & $__execInUserMod $__userMod $__userSb *>&1 | ForEach-Object {
                            Invoke-IcpEngineDispatch -Action 'sink' -Payload $_
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
                if ($__eng.TemProcessTree -and $null -ne $__eng.BaseFilhosLote) {
                    try {
                        foreach ($__m in @(Stop-AgentToolsNewChild -RootPid $PID -Baseline $__eng.BaseFilhosLote)) {
                            if ($__eng.MortosVistos.Add($__m)) { $__eng.MortosCtrlC.Add($__m) }
                        }
                    }
                    catch { $null = $_ }
                }
                if ($__eng.MortosCtrlC.Count -gt 0) {
                    $__msgInt = "[INTERROMPIDO] Processo(s) filho(s) encerrado(s): $($__eng.MortosCtrlC -join ', ')"
                    try { [Console]::WriteLine("$__prefInt$__msgInt$__sufInt") } catch { $null = $_ }
                }
            }
            Restore-AgentToolsConsoleState -OutputEncoding $__encAntes -InputEncoding $__encInAntes -RestoreCursor:$($__interativo -and -not $__eng.ConcluiuLaco) -CursorVisibleBefore $__cursorAntes
            if ($script:IcpEngineStack.Count -gt 0) {
                $null = $script:IcpEngineStack.Pop()
            }
        }
        $__swTotal.Stop()
        $__msTotal = [int]$__swTotal.ElapsedMilliseconds
        if ($null -eq $__ambInfo) { $__ambInfo = Get-IcpAmbienteInfo }

        $__falhas = @($__eng.Res | Where-Object Status -eq 'FALHOU' | ForEach-Object N)
        $__naoExec = @($__eng.Res | Where-Object Status -eq 'NAO_EXECUTADO')
        $__resultado = if ($__eng.Bloqueado) { "BLOQUEADO no pré-voo (0 de $($__eng.Total) executados)" }
        elseif ($__falhas.Count -eq 0 -and $__eng.ParadoOperador) { "INTERROMPIDO pelo operador ($(@($__eng.Res | Where-Object Status -ne 'NAO_EXECUTADO').Count) de $($__eng.Total) executados)" }
        elseif ($__falhas.Count -eq 0) { 'OK' }
        elseif ($__naoExec.Count -gt 0 -or -not $__continuar) { "FALHOU no comando $($__falhas[0]) de $($__eng.Total)" }
        else { "COM FALHAS nos comandos $($__falhas -join ', ') de $($__eng.Total)" }

        $__flags = Get-IcpFlagList -Explain:$__explicar -Raw:$__raw -ContinueOnError:$__continuar `
            -Step:$__eng.PassoAPasso -NoMask:$NoMask -AllowTrailingBackslash:$__permitirBarra `
            -AllowedExitCodes $AllowedExitCodes -CommandTimeoutSeconds $__timeoutSeg

        $__model = New-IcpReportModel -VersaoIcp $script:AgentToolsVersion -Formato $__formato -Explain:$__explicar `
            -Resultado $__resultado -MsTotal $__msTotal -Flags $__flags -Bloqueios $__eng.Bloqueios `
            -AmbienteInfo $__ambInfo -Mascarar $__mascarar -Ocultos $__eng.Ocultos -Registros $__eng.Res.ToArray()

        $__maxFileChars = Get-IcpMaxFileChar
        $__serFull = Format-IcpReportText -Model $__model -Format $__formato -MaxFileChars $(if ($__modoOut) { $__maxFileChars } else { 0 })
        $__texto = $__serFull.Text

        $__arquivo = $null
        $__clip = $__texto
        if ($__modoOut) {
            if ($__outVazio) {
                Write-Host 'icp: -OutFile vazio; o relatório não foi gravado nem copiado.' -ForegroundColor Yellow
            }
            elseif ($__outErro) {
                Write-Host "icp: não consegui gravar o relatório em '$__outArq' ($__outErro); nada foi copiado." -ForegroundColor Yellow
            }
            else {
                try { [System.IO.File]::WriteAllText($__outCaminho, $__texto, [System.Text.UTF8Encoding]::new($false)) }
                catch {
                    Write-Host "icp: não consegui gravar o relatório em '$__outArq' ($($_.Exception.Message)); nada foi copiado." -ForegroundColor Yellow
                    $__outCaminho = $null
                }
            }
        }
        elseif ($__texto.Length -gt $__maxClip) {
            try {
                $__dir = Get-IcpLogDirectory
                $null = New-Item -ItemType Directory -Path $__dir -Force -ErrorAction Stop
                Clear-IcpOldLog -Directory $__dir -Days 7

                $__serArq = Format-IcpReportText -Model $__model -Format $__formato -MaxFileChars $__maxFileChars
                $__arquivo = Write-IcpLogFileExclusive -Directory $__dir -Content $__serArq.Text -Format $__formato
                $__texto = $__serArq.Text

                $__model.arquivo = [pscustomobject]@{
                    caminho       = $__arquivo
                    formato       = $__formato
                    chars         = $__serArq.CharCount
                    bytes         = $__serArq.ByteCount
                    truncado_teto = $__serArq.Truncated
                }
                $__serSum = Format-IcpReportText -Model $__model -Format $__formato -Summary
                $__clip = $__serSum.Text
            }
            catch {
                if ($__semClip) { Write-Host "icp: não consegui gravar o arquivo ($_); o relatório não foi gravado nem copiado (-NoClipboard)." -ForegroundColor Yellow }
                else { Write-Host "icp: não consegui gravar o arquivo ($_); copiando o relatório inteiro." -ForegroundColor Yellow }
                $__arquivo = $null
            }
        }

        $__copiou = $false
        if (-not $__modoOut -and -not $__semClip) {
            try { Set-Clipboard -Value $__clip -ErrorAction Stop; $__copiou = $true }
            catch { Write-Host "icp: não consegui copiar para a área de transferência: $_" -ForegroundColor Yellow }
        }

        $__modoRel = if ($__explicar) { 'completo/-Explain' } else { 'compacto' }
        if ($__formato -ne 'xml') { $__modoRel += " · $__formato" }
        $__durTotal = Format-IcpDuracao -Ms $__msTotal
        if ($__interativo) {
            $__corResT = if ($__resultado -eq 'OK') { 'Oliva' } elseif ($__eng.ParadoOperador -and $__falhas.Count -eq 0) { 'Ambar' } else { 'Terracota' }
            $__icRes = if ($__resultado -eq 'OK') { '✓' } elseif ($__eng.ParadoOperador -and $__falhas.Count -eq 0) { '■' } else { '✗' }
            Write-Host "$(Format-IcpCor '╰─' 'Petroleo') $(Format-IcpCor "$__icRes Resultado: $__resultado" $__corResT -Negrito) $(Format-IcpCor "($__durTotal · $__modoRel)" 'Neutro')"
            if ($__modoOut) {
                if ($__outCaminho) { Write-Host (Format-IcpCor "--- Relatório ($($__texto.Length) caracteres) gravado em: $__outCaminho" 'Ambar') }
            }
            elseif ($__arquivo) {
                Write-Host (Format-IcpCor "--- Relatório ($($__texto.Length) caracteres) gravado em: $__arquivo" 'Ambar')
                if ($__semClip) { Write-Host (Format-IcpCor '--- Área de transferência: não usada (-NoClipboard).' 'Neutro') }
                else { Write-Host (Format-IcpCor "--- Área de transferência: resumo de $($__clip.Length) caracteres com o caminho. Anexe o arquivo." 'Ambar') }
            }
            elseif ($__semClip) { Write-Host (Format-IcpCor '--- Área de transferência: não usada (-NoClipboard).' 'Neutro') }
            elseif ($__copiou) { Write-Host (Format-IcpCor "--- Relatório copiado para a área de transferência ($($__clip.Length) caracteres)." 'Oliva') }
            if ($__naoExec.Count -gt 0) {
                Write-Host (Format-IcpCor "--- Comandos não executados: $($__naoExec.Count)" 'Neutro')
            }
            if ($__eng.Ocultos -gt 0) {
                Write-Host (Format-IcpCor "--- Segredos ocultados no relatório: $($__eng.Ocultos) (a tela mostra o original)" 'Ambar')
            }
        }
        else {
            $__corRes = if ($__resultado -eq 'OK') { 'Green' } elseif ($__eng.ParadoOperador -and $__falhas.Count -eq 0) { 'Yellow' } else { 'Red' }
            Write-Host ('─' * [Math]::Min(60, $__larguraTela)) -ForegroundColor DarkGray
            Write-Host "--- Resultado: $__resultado" -ForegroundColor $__corRes -NoNewline
            Write-Host " ($__durTotal · $__modoRel)" -ForegroundColor DarkGray
            if ($__modoOut) {
                if ($__outCaminho) { Write-Host "--- Relatório ($($__texto.Length) caracteres) gravado em: $__outCaminho" -ForegroundColor Yellow }
            }
            elseif ($__arquivo) {
                Write-Host "--- Relatório ($($__texto.Length) caracteres) gravado em: $__arquivo" -ForegroundColor Yellow
                if ($__semClip) { Write-Host '--- Área de transferência: não usada (-NoClipboard).' -ForegroundColor Yellow }
                else { Write-Host "--- Área de transferência: resumo de $($__clip.Length) caracteres com o caminho. Anexe o arquivo." -ForegroundColor Yellow }
            }
            elseif ($__semClip) { Write-Host '--- Área de transferência: não usada (-NoClipboard).' }
            elseif ($__copiou) { Write-Host "--- Relatório copiado para a área de transferência ($($__clip.Length) caracteres)." -ForegroundColor Green }
            Write-Host "--- Comandos não executados: $($__naoExec.Count)"
            if ($__eng.Ocultos -gt 0) { Write-Host "--- Segredos ocultados no relatório: $($__eng.Ocultos) (a tela mostra o original)" -ForegroundColor Yellow }
        }
    }
    finally {
        $script:IcpProfundidade = [Math]::Max(0, $script:IcpProfundidade - 1)
    }
}
