@{
    Name              = 'icp'
    Version           = '1.0.0'
    Entrypoint        = 'icp.ps1'
    ExportedFunctions = @('icp')
    RequiresCore      = @('Loader', 'Masking', 'Theme', 'Terminal', 'Process')
    Files             = @(
        'Engine\PreFlight.ps1'
        'Features\Report.ps1'
        'Features\Formatters\Xml.ps1'
        'Features\Formatters\Json.ps1'
        'Features\Formatters\Markdown.ps1'
        'Features\StatusBar.ps1'
        'Features\Compositor.ps1'
        'Features\Help.ps1'
        'Engine\Engine.ps1'
    )
    NativeBinaries    = @{}
}
