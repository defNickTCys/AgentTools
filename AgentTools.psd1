@{
    RootModule        = 'AgentTools.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '49e84889-31ea-486e-97f0-dc8e60a551ee'
    Author            = 'defNickTCys'
    Description       = 'Utilitários de terminal do operador: icp executa cada comando uma vez, para na primeira falha e gera relatório estruturado (XML, JSON ou Markdown) para IA ou leitura.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @('icp')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData = @{
        PSData = @{
            Tags         = @('PowerShell', 'Windows', 'Terminal', 'CLI', 'AI', 'Agents', 'icp')
            LicenseUri   = 'https://github.com/defNickTCys/AgentTools/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/defNickTCys/AgentTools'
            ReleaseNotes = 'https://github.com/defNickTCys/AgentTools/blob/main/CHANGELOG.md'
        }
    }
}
