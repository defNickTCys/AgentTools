function ConvertTo-IcpCorAnsi {
    # Converte cor (#RRGGBB ou nome ANSI) para escape SGR; devolve $null se inválida.
    param([string]$Valor)
    if ([string]::IsNullOrWhiteSpace($Valor)) { return $null }
    $v = $Valor.Trim()
    if ($v -match '^#([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})$') {
        $r = [Convert]::ToInt32($Matches[1], 16)
        $g = [Convert]::ToInt32($Matches[2], 16)
        $b = [Convert]::ToInt32($Matches[3], 16)
        return "`e[38;2;$r;$g;${b}m"
    }
    $mapa = @{
        black         = '30'; red           = '31'; green         = '32'; yellow        = '33'
        blue          = '34'; magenta       = '35'; cyan          = '36'; white         = '37'
        gray          = '90'; grey          = '90'; brightblack   = '90'
        brightred     = '91'; brightgreen   = '92'; brightyellow  = '93'
        brightblue    = '94'; brightmagenta = '95'; brightcyan    = '96'; brightwhite   = '97'
    }
    $k = $v.ToLowerInvariant()
    if ($k -eq 'default') { return '' }
    if ($mapa.ContainsKey($k)) { return "`e[$($mapa[$k])m" }
    return $null
}

function Get-IcpTema {
    # Retorna paleta ativa (gruvbox com OK/Falha herdados do terminal, terminal ANSI, ou gruvbox-puro) + overrides; respeita NO_COLOR.
    if (-not [string]::IsNullOrEmpty($env:NO_COLOR)) {
        return @{
            Petroleo = ''; PetroleoClaro = ''; Pedra = ''; Neutro = ''
            Creme = ''; Ambar = ''; Oliva = ''; Laranja = ''; Terracota = ''
            Negrito = ''; Reset = ''
        }
    }
    $nome = if ($env:AGENTTOOLS_ICP_THEME) { $env:AGENTTOOLS_ICP_THEME.Trim().ToLowerInvariant() } else { 'gruvbox' }
    $tema = switch ($nome) {
        { $_ -in 'terminal', 'ansi', 'inherit', 'herdar' } {
            @{
                Petroleo      = "`e[36m"
                PetroleoClaro = "`e[96m"
                Pedra         = "`e[90m"
                Neutro        = "`e[37m"
                Creme         = ''
                Ambar         = "`e[93m"
                Oliva         = "`e[92m"
                Laranja       = "`e[33m"
                Terracota     = "`e[91m"
                Negrito       = "`e[1m"
                Reset         = "`e[0m"
            }
        }
        { $_ -in 'gruvbox-puro', 'gruvbox-classic', 'gruvbox-dark' } {
            @{
                Petroleo      = "`e[38;2;69;133;136m"
                PetroleoClaro = "`e[38;2;131;165;152m"
                Pedra         = "`e[38;2;102;92;84m"
                Neutro        = "`e[38;2;168;153;132m"
                Creme         = "`e[38;2;251;241;199m"
                Ambar         = "`e[38;2;250;189;47m"
                Oliva         = "`e[38;2;184;187;38m"
                Laranja       = "`e[38;2;254;128;25m"
                Terracota     = "`e[38;2;251;73;52m"
                Negrito       = "`e[1m"
                Reset         = "`e[0m"
            }
        }
        default {
            @{
                Petroleo      = "`e[38;2;69;133;136m"
                PetroleoClaro = "`e[38;2;131;165;152m"
                Pedra         = "`e[38;2;102;92;84m"
                Neutro        = "`e[38;2;168;153;132m"
                Creme         = "`e[38;2;251;241;199m"
                Ambar         = "`e[38;2;250;189;47m"
                Oliva         = "`e[92m"
                Laranja       = "`e[38;2;254;128;25m"
                Terracota     = "`e[91m"
                Negrito       = "`e[1m"
                Reset         = "`e[0m"
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENTTOOLS_ICP_COLORS)) {
        $aliases = @{
            borda = 'Petroleo'; petroleo = 'Petroleo'
            destaque = 'PetroleoClaro'; petroleoclaro = 'PetroleoClaro'
            sutil = 'Pedra'; pedra = 'Pedra'
            neutro = 'Neutro'
            texto = 'Creme'; creme = 'Creme'
            titulo = 'Ambar'; ambar = 'Ambar'
            ok = 'Oliva'; verde = 'Oliva'; oliva = 'Oliva'
            alerta = 'Laranja'; laranja = 'Laranja'
            erro = 'Terracota'; falha = 'Terracota'; vermelho = 'Terracota'; terracota = 'Terracota'
        }
        foreach ($par in ($env:AGENTTOOLS_ICP_COLORS -split '[;,]')) {
            if ($par -notmatch '^\s*([^=]+?)\s*=\s*(.+?)\s*$') { continue }
            $chave = $aliases[$Matches[1].Trim().ToLowerInvariant()]
            if (-not $chave) { continue }
            $ansi = ConvertTo-IcpCorAnsi -Valor $Matches[2]
            if ($null -ne $ansi) { $tema[$chave] = $ansi }
        }
    }
    return $tema
}

function Get-IcpStatusBarPalette {
    # Extrai as 7 cores ordenadas para AgentTools.IcpStatusBar a partir do tema ativo.
    $t = Get-IcpTema
    return [string[]]@($t.Petroleo, $t.PetroleoClaro, $t.Pedra, $t.Creme, $t.Ambar, $t.Laranja, $t.Terracota)
}

function Format-IcpCor {
    # Aplica cor Gruvbox Dark ao texto; devolve texto puro quando NO_COLOR está ativo.
    param([string]$Texto, [string]$Cor = 'Creme', [switch]$Negrito)
    if ([string]::IsNullOrEmpty($Texto)) { return '' }
    $t = Get-IcpTema
    $c = $t[$Cor]
    if ([string]::IsNullOrEmpty($c)) {
        if ($Negrito -and $t.Negrito) { return "$($t.Negrito)$Texto$($t.Reset)" }
        return $Texto
    }
    if ($Negrito) { return "$($t.Negrito)$c$Texto$($t.Reset)" }
    return "$c$Texto$($t.Reset)"
}
