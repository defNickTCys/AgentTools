function Initialize-AgentToolsLoader {
    # Inicializa os registros internos do loader do AgentTools no escopo do módulo.
    if ($null -eq $script:AgentToolsCoreModules) {
        $script:AgentToolsCoreModules = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
    if ($null -eq $script:AgentToolsLoadedTools) {
        $script:AgentToolsLoadedTools = @{}
    }
    if ($null -eq $script:AgentToolsFunctionOwners) {
        $script:AgentToolsFunctionOwners = @{}
    }
    [void]$script:AgentToolsCoreModules.Add('Loader')
    foreach ($fnName in @(
            'Initialize-AgentToolsLoader',
            'Test-AgentToolsRelativeChildPath',
            'Test-AgentToolsScriptDefinition',
            'Import-AgentToolsCoreModule',
            'Get-AgentToolsToolManifest',
            'Test-AgentToolsToolLoaded',
            'Import-AgentToolsToolEntrypoint',
            'Import-AgentToolsTool',
            'Resolve-AgentToolsNativeBin'
        )) {
        if (-not $script:AgentToolsFunctionOwners.ContainsKey($fnName)) {
            $script:AgentToolsFunctionOwners[$fnName] = 'Core:Loader'
        }
    }
}

function Test-AgentToolsRelativeChildPath {
    # Valida que RelativePath é relativo e permanece estritamente dentro de BaseDir (bloqueando traversal e reparse points).
    param(
        [Parameter(Mandatory)][string]$BaseDir,
        [Parameter(Mandatory)][string]$RelativePath
    )
    if ([string]::IsNullOrWhiteSpace($BaseDir) -or [string]::IsNullOrWhiteSpace($RelativePath)) { return $null }
    if ([System.IO.Path]::IsPathRooted($RelativePath)) { return $null }
    $segNorm = $RelativePath -replace '/', '\'
    foreach ($seg in ($segNorm -split '\\')) {
        if ($seg -eq '..') { return $null }
    }
    try {
        $baseFull = [System.IO.Path]::GetFullPath($BaseDir)
        $basePrefix = $baseFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        $targetFull = [System.IO.Path]::GetFullPath((Join-Path $baseFull $segNorm))
        if (-not $targetFull.StartsWith($basePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        $cur = $baseFull
        foreach ($seg in ($segNorm -split '\\')) {
            if ([string]::IsNullOrEmpty($seg) -or $seg -eq '.') { continue }
            $cur = Join-Path $cur $seg
            if ([System.IO.File]::Exists($cur) -or [System.IO.Directory]::Exists($cur)) {
                $attr = [System.IO.File]::GetAttributes($cur)
                if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    return $null
                }
            }
        }
        return $targetFull
    }
    catch {
        return $null
    }
}

function Test-AgentToolsScriptDefinition {
    # Valida sintaxe AST e detecta colisões de funções de nível raiz antes de executar scripts por dot-source.
    param(
        [Parameter(Mandatory)][string[]]$FilePaths,
        [Parameter(Mandatory)][string]$Owner
    )
    $declared = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($fp in $FilePaths) {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($fp, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            throw "Erro de sintaxe em '$fp': $($errors[0].Message)"
        }
        $fnAsts = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        foreach ($fnAst in $fnAsts) {
            $aninhada = $false
            $cur = $fnAst.Parent
            while ($null -ne $cur) {
                if ($cur -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    $aninhada = $true
                    break
                }
                $cur = $cur.Parent
            }
            if ($aninhada) { continue }

            $rawName = [string]$fnAst.Name
            if ($rawName -match '^(?i)global:') {
                throw "Função '$rawName' em '$fp' não pode usar escopo global:."
            }
            $cleanName = $rawName -replace '^(?i)(?:script|local|private):', ''
            if (-not $declared.Add($cleanName)) {
                throw "Colisão intra-lote para '$Owner': função '$cleanName' definida novamente em '$fp'."
            }
            if ($script:AgentToolsFunctionOwners.ContainsKey($cleanName) -and $script:AgentToolsFunctionOwners[$cleanName] -ne $Owner) {
                throw "Colisão de função ao validar '$Owner': '$cleanName' já pertence a '$($script:AgentToolsFunctionOwners[$cleanName])'."
            }
        }
    }
}

function Import-AgentToolsCoreModule {
    # Carrega um arquivo de Core/ no escopo do módulo AgentTools, validando colisões de funções antes e depois da carga.
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$CoreRoot = ''
    )
    if ($null -eq $script:AgentToolsCoreModules) { Initialize-AgentToolsLoader }
    if ($Name -notmatch '^[A-Za-z0-9_-]+$') {
        throw "Nome inválido de módulo Core: '$Name'."
    }
    $usarPadrao = [string]::IsNullOrWhiteSpace($CoreRoot)
    if ($usarPadrao -and $script:AgentToolsCoreModules.Contains($Name)) { return }

    $dirCore = if ($usarPadrao) { Join-Path $script:AgentToolsRoot 'Core' } else { $CoreRoot }
    $filePath = Test-AgentToolsRelativeChildPath -BaseDir $dirCore -RelativePath "$Name.ps1"
    if (-not $filePath -or -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        throw "Módulo Core '$Name' não encontrado em '$dirCore'."
    }

    $owner = "Core:$Name"
    Test-AgentToolsScriptDefinition -FilePaths @($filePath) -Owner $owner

    $before = @{}
    foreach ($fn in Get-ChildItem Function:\) {
        $before[$fn.Name] = $fn.ScriptBlock
    }

    . $filePath

    $staged = @{}
    foreach ($fn in Get-ChildItem Function:\) {
        if (-not $before.ContainsKey($fn.Name) -or -not [object]::ReferenceEquals($before[$fn.Name], $fn.ScriptBlock)) {
            if ($script:AgentToolsFunctionOwners.ContainsKey($fn.Name) -and $script:AgentToolsFunctionOwners[$fn.Name] -ne $owner) {
                throw "Colisão de função ao carregar '$owner': '$($fn.Name)' já pertence a '$($script:AgentToolsFunctionOwners[$fn.Name])'."
            }
            $staged[$fn.Name] = $fn.ScriptBlock
        }
    }

    foreach ($fnName in $staged.Keys) {
        Set-Item -Path "Function:\script:$fnName" -Value $staged[$fnName]
        $script:AgentToolsFunctionOwners[$fnName] = $owner
    }
    if ($usarPadrao) {
        [void]$script:AgentToolsCoreModules.Add($Name)
    }
}

function Get-AgentToolsToolManifest {
    # Lê e valida o manifesto tool.psd1 de uma ferramenta em Tools/<nome>/.
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$ToolsRoot = ''
    )
    if ($Name -notmatch '^[A-Za-z0-9_-]+$') {
        throw "Nome inválido de ferramenta: '$Name'."
    }
    $baseTools = if ([string]::IsNullOrWhiteSpace($ToolsRoot)) { Join-Path $script:AgentToolsRoot 'Tools' } else { $ToolsRoot }
    $toolDir = Test-AgentToolsRelativeChildPath -BaseDir $baseTools -RelativePath $Name
    if (-not $toolDir) {
        throw "Caminho inválido para ferramenta '$Name'."
    }
    $manifestPath = Test-AgentToolsRelativeChildPath -BaseDir $toolDir -RelativePath 'tool.psd1'
    if (-not $manifestPath -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Manifesto tool.psd1 não encontrado para a ferramenta '$Name' em '$toolDir'."
    }
    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    if ($manifest.Name -ne $Name) {
        throw "Manifesto '$manifestPath' declara Name='$($manifest.Name)', esperado '$Name'."
    }
    return [pscustomobject]@{
        Name         = $Name
        ToolDir      = $toolDir
        ManifestPath = [System.IO.Path]::GetFullPath($manifestPath)
        Manifest     = $manifest
    }
}

function Test-AgentToolsToolLoaded {
    # Retorna True se a ferramenta (pelo manifesto atual) já teve suas partes internas carregadas.
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$ToolsRoot = ''
    )
    if ($null -eq $script:AgentToolsLoadedTools) { return $false }
    try {
        $info = Get-AgentToolsToolManifest -Name $Name -ToolsRoot $ToolsRoot
        return $script:AgentToolsLoadedTools.ContainsKey($info.ManifestPath.ToLowerInvariant())
    }
    catch {
        return $false
    }
}

function Import-AgentToolsToolEntrypoint {
    # Carrega apenas o arquivo Entrypoint de Tools/<nome>/tool.psd1 no import do módulo.
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$ToolsRoot = ''
    )
    if ($null -eq $script:AgentToolsCoreModules) { Initialize-AgentToolsLoader }
    $info = Get-AgentToolsToolManifest -Name $Name -ToolsRoot $ToolsRoot
    $entryRel = [string]$info.Manifest.Entrypoint
    $entryPath = Test-AgentToolsRelativeChildPath -BaseDir $info.ToolDir -RelativePath $entryRel
    if (-not $entryPath -or -not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
        throw "Entrypoint '$entryRel' inválido ou ausente em '$($info.ToolDir)'."
    }

    $owner = "Tool:${Name}:Entry"
    Test-AgentToolsScriptDefinition -FilePaths @($entryPath) -Owner $owner

    $before = @{}
    foreach ($fn in Get-ChildItem Function:\) {
        $before[$fn.Name] = $fn.ScriptBlock
    }

    . $entryPath

    $staged = @{}
    foreach ($fn in Get-ChildItem Function:\) {
        if (-not $before.ContainsKey($fn.Name) -or -not [object]::ReferenceEquals($before[$fn.Name], $fn.ScriptBlock)) {
            if ($script:AgentToolsFunctionOwners.ContainsKey($fn.Name) -and $script:AgentToolsFunctionOwners[$fn.Name] -ne $owner) {
                throw "Colisão de função no entrypoint de '$Name': '$($fn.Name)' já pertence a '$($script:AgentToolsFunctionOwners[$fn.Name])'."
            }
            $staged[$fn.Name] = $fn.ScriptBlock
        }
    }

    foreach ($fnName in $staged.Keys) {
        Set-Item -Path "Function:\script:$fnName" -Value $staged[$fnName]
        $script:AgentToolsFunctionOwners[$fnName] = $owner
    }
}

function Import-AgentToolsTool {
    # Carrega sob demanda os arquivos de Tools/<nome>/ declarados em tool.psd1, validando AST e colisões antes de executar.
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$ToolsRoot = ''
    )
    if ($null -eq $script:AgentToolsCoreModules) { Initialize-AgentToolsLoader }
    $info = Get-AgentToolsToolManifest -Name $Name -ToolsRoot $ToolsRoot
    $key = $info.ManifestPath.ToLowerInvariant()
    if ($script:AgentToolsLoadedTools.ContainsKey($key)) { return }

    foreach ($req in @($info.Manifest.RequiresCore)) {
        $reqStr = [string]$req
        if ([string]::IsNullOrWhiteSpace($reqStr)) { continue }
        if (-not $script:AgentToolsCoreModules.Contains($reqStr)) {
            throw "Ferramenta '$Name' requer módulo Core '$reqStr', que não foi carregado."
        }
    }

    $files = @($info.Manifest.Files)
    if ($files.Count -eq 0) {
        throw "Ferramenta '$Name' não declara arquivos em Files no manifesto '$($info.ManifestPath)'."
    }

    $resolvedFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($rel in $files) {
        $relStr = [string]$rel
        $full = Test-AgentToolsRelativeChildPath -BaseDir $info.ToolDir -RelativePath $relStr
        if (-not $full -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "Arquivo declarado em '$($info.ManifestPath)' é inválido ou ausente: '$relStr'."
        }
        $resolvedFiles.Add($full)
    }

    $owner = "Tool:$Name"
    Test-AgentToolsScriptDefinition -FilePaths $resolvedFiles.ToArray() -Owner $owner

    $staged = @{}
    foreach ($filePath in $resolvedFiles) {
        $beforeFile = @{}
        foreach ($fn in Get-ChildItem Function:\) {
            $beforeFile[$fn.Name] = $fn.ScriptBlock
        }

        . $filePath

        foreach ($fn in Get-ChildItem Function:\) {
            if (-not $beforeFile.ContainsKey($fn.Name) -or -not [object]::ReferenceEquals($beforeFile[$fn.Name], $fn.ScriptBlock)) {
                if ($staged.ContainsKey($fn.Name)) {
                    throw "Colisão intra-ferramenta em '$Name': função '$($fn.Name)' definida novamente em '$filePath'."
                }
                if ($script:AgentToolsFunctionOwners.ContainsKey($fn.Name) -and $script:AgentToolsFunctionOwners[$fn.Name] -ne $owner) {
                    throw "Colisão de função ao carregar ferramenta '$Name': '$($fn.Name)' já pertence a '$($script:AgentToolsFunctionOwners[$fn.Name])'."
                }
                $staged[$fn.Name] = $fn.ScriptBlock
            }
        }
    }

    foreach ($fnName in $staged.Keys) {
        Set-Item -Path "Function:\script:$fnName" -Value $staged[$fnName]
        $script:AgentToolsFunctionOwners[$fnName] = $owner
    }
    $script:AgentToolsLoadedTools[$key] = [pscustomobject]@{
        Name       = $Name
        ToolDir    = $info.ToolDir
        LoadedAt   = [DateTimeOffset]::UtcNow
        FileCount  = $resolvedFiles.Count
    }
}

function Resolve-AgentToolsNativeBin {
    # Resolve binário nativo declarado em tool.psd1 validando caminho relativo, reparse points e SHA-256 (assume pasta do módulo protegida contra escrita).
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [Parameter(Mandatory)][string]$BinaryName,
        [string]$ToolsRoot = ''
    )
    $makeResult = {
        param([bool]$Avail, [string]$PathVal, [string]$ReasonVal, [string]$Exp, [string]$Act)
        return [pscustomobject]@{
            Available      = $Avail
            Path           = $PathVal
            Fallback       = (-not $Avail)
            Reason         = $ReasonVal
            ExpectedSha256 = $Exp
            ActualSha256   = $Act
        }
    }

    try {
        $info = Get-AgentToolsToolManifest -Name $ToolName -ToolsRoot $ToolsRoot
    }
    catch {
        return (& $makeResult $false $null 'manifest-error' $null $null)
    }

    $bins = $info.Manifest.NativeBinaries
    if ($null -eq $bins -or -not ($bins -is [hashtable]) -or -not $bins.ContainsKey($BinaryName)) {
        return (& $makeResult $false $null 'not-declared' $null $null)
    }
    $entry = $bins[$BinaryName]
    if ($null -eq $entry -or -not ($entry -is [hashtable])) {
        return (& $makeResult $false $null 'invalid-declaration' $null $null)
    }

    $relPath = [string]$entry.RelativePath
    $expected = ([string]$entry.Sha256).Trim().ToLowerInvariant()
    $fullPath = Test-AgentToolsRelativeChildPath -BaseDir $info.ToolDir -RelativePath $relPath
    if (-not $fullPath) {
        return (& $makeResult $false $null 'invalid-path' $expected $null)
    }
    if ($expected -notmatch '^[0-9a-f]{64}$') {
        return (& $makeResult $false $null 'missing-sha256' $null $null)
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        return (& $makeResult $false $null 'file-not-found' $expected $null)
    }

    try {
        $fs = [System.IO.File]::Open($fullPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $hashBytes = $sha.ComputeHash($fs)
                $actual = ([BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
            }
            finally { $sha.Dispose() }
        }
        finally { $fs.Dispose() }

        if ($actual -cne $expected) {
            return (& $makeResult $false $null 'sha256-mismatch' $expected $actual)
        }
        return (& $makeResult $true $fullPath 'ok' $expected $actual)
    }
    catch {
        return (& $makeResult $false $null 'io-error' $expected $null)
    }
}
