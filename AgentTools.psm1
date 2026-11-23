# AgentTools - utilitários do operador. Não dependem do perfil.
# Carregado automaticamente pelo PowerShell na primeira vez que 'icp' é usado.

$script:AgentToolsRoot = $PSScriptRoot
$__psdPath = Join-Path $PSScriptRoot 'AgentTools.psd1'
$script:AgentToolsVersion = try {
    [string](Import-PowerShellDataFile -LiteralPath $__psdPath).ModuleVersion
}
catch {
    '0.9.5'
}
if ([string]::IsNullOrWhiteSpace($script:AgentToolsVersion)) { $script:AgentToolsVersion = '0.9.5' }
Remove-Variable -Name '__psdPath' -ErrorAction Ignore
$script:AgentToolsTypeNamespace = 'AgentTools.V' + ($script:AgentToolsVersion -replace '[^0-9A-Za-z]', '_')
$script:IcpProfundidade = 0

. (Join-Path $PSScriptRoot 'Core\Loader.ps1')
Initialize-AgentToolsLoader

foreach ($__coreName in 'Masking', 'Theme', 'Terminal', 'Process') {
    Import-AgentToolsCoreModule -Name $__coreName
}
Remove-Variable -Name '__coreName' -ErrorAction Ignore

Import-AgentToolsToolEntrypoint -Name 'icp'

Export-ModuleMember -Function icp
