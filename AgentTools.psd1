@{
    RootModule        = 'AgentTools.psm1'
    ModuleVersion     = '0.9.5'
    GUID              = '49e84889-31ea-486e-97f0-dc8e60a551ee'
    Author            = 'operador'
    Description       = 'Utilitários de terminal do operador: icp executa cada comando uma vez, para na primeira falha e gera relatório estruturado (XML, JSON ou Markdown) para IA ou leitura.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @('icp')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
