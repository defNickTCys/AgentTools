function Remove-Ansi {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Só transforma texto; não altera estado do sistema.')]
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return ($Text -replace '\x1b\[[0-9;?]*[a-zA-Z]', '' -replace '\x1b\][^\x07\x1b]*(\x07|\x1b\\)', '')
}

function Format-IcpLinhaLimpa {
    # Remove ANSI (ou preserva apenas SGR com -PreservarAnsi) e resolve '\r' isolado mantendo o último quadro visível.
    param([string]$Text, [switch]$PreservarAnsi)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $usarAnsi = [bool]$PreservarAnsi -and [string]::IsNullOrEmpty($env:NO_COLOR)
    if (-not $usarAnsi) {
        $limpo = Remove-Ansi -Text $Text
        if ($limpo.Contains("`r")) {
            $partes = @($limpo -split "`r" | Where-Object { $_.TrimEnd() -ne '' })
            $limpo = if ($partes.Count -gt 0) { $partes[-1] } else { '' }
        }
        return $limpo.TrimEnd()
    }
    $limpo = $Text -creplace '\x1b\][^\x07\x1b]*(\x07|\x1b\\)', '' -creplace '\x1b\[[0-9;?]*[\x40-\x6c\x6e-\x7e]', '' -creplace '\x1b\[[0-9;?]*\?[0-9;]*m', ''
    if ($limpo.Contains("`r")) {
        $partes = @($limpo -split "`r" | Where-Object { (Remove-Ansi -Text $_).TrimEnd() -ne '' })
        $limpo = if ($partes.Count -gt 0) { $partes[-1] } else { '' }
    }
    $limpo = $limpo.TrimEnd()
    if ($limpo.Contains([char]27) -and -not $limpo.EndsWith("`e[0m")) {
        $limpo += "`e[0m"
    }
    return $limpo
}

function Format-IcpDuracao {
    # Formata duração em ms para exibição humana na tela (ex.: 42 ms, 2.3s, 1m05s).
    param([int]$Ms)
    if ($Ms -lt 1000) { return "$Ms ms" }
    $seg = $Ms / 1000.0
    if ($seg -lt 60.0) {
        return $seg.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture) + 's'
    }
    $mins = [int][Math]::Floor($seg / 60.0)
    $rem = [int][Math]::Floor($seg % 60.0)
    return "${mins}m$($rem.ToString('00'))s"
}

function Test-IcpInterativo {
    # True somente em ConsoleHost interativo sem redirecionamento ou -NonInteractive.
    param([switch]$RequireInput)
    if ($env:AGENTTOOLS_ICP_NOSTATUS) { return $false }
    if ($Host.Name -ne 'ConsoleHost') { return $false }
    try {
        foreach ($a in [Environment]::GetCommandLineArgs()) {
            if ($a -match '^(?i)-noni(nteractive)?$') { return $false }
        }
    }
    catch { $null = $_ }
    try {
        if ([Console]::IsOutputRedirected) { return $false }
        if ($RequireInput -and [Console]::IsInputRedirected) { return $false }
        return $true
    }
    catch { return $false }
}

function Clear-IcpLinhasTela {
    # Sobe o cursor e limpa linhas já impressas de forma sincronizada (DEC 2026).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Limpa apenas linhas visuais no console antes de redesenhar a saída.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Emite sequências DEC 2026 diretamente no console para recolher linhas.')]
    param([int]$Linhas)
    if ($Linhas -le 0) { return }
    $n = $Linhas
    try {
        $top = [Console]::CursorTop
        if ($top -ge 0 -and $n -gt $top) { $n = $top }
    }
    catch { $null = $_ }
    if ($n -le 0) { return }
    try {
        [Console]::Write("`e[?2026h`e[${n}A`r`e[J`e[?2026l")
    }
    catch { $null = $_ }
}

function Restore-AgentToolsConsoleState {
    # Restaura cursor e encodings de saída/entrada de forma independente sem propagar exceções no cleanup.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Restaura estado anterior de cursor e codificação do console em blocos finally.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Restaura visibilidade do cursor no console após interrupção.')]
    param(
        [System.Text.Encoding]$OutputEncoding = $null,
        [System.Text.Encoding]$InputEncoding = $null,
        [switch]$RestoreCursor,
        [Nullable[bool]]$CursorVisibleBefore = $null
    )
    if ($RestoreCursor -and ($null -eq $CursorVisibleBefore -or $CursorVisibleBefore -eq $true)) {
        try { [Console]::Write("`e[?25h") } catch { $null = $_ }
    }
    if ($null -ne $OutputEncoding) {
        try { [Console]::OutputEncoding = $OutputEncoding } catch { $null = $_ }
    }
    if ($null -ne $InputEncoding) {
        try { [Console]::InputEncoding = $InputEncoding } catch { $null = $_ }
    }
}
