# Testes do núcleo compartilhado Core/ do AgentTools. Rode em processo filho limpo:
#   pwsh -NoProfile -NoLogo -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester .\Tests\Core.Tests.ps1"

BeforeAll {
    $__mod = if ($env:AGENTTOOLS_TEST_MODULE) { $env:AGENTTOOLS_TEST_MODULE } else { Join-Path $PSScriptRoot '..\AgentTools.psd1' }
    Import-Module $__mod -Force
}

Describe 'AgentTools Core' {
    Context '1. Core/Loader (manifestos, dependências, colisão e Resolve-AgentToolsNativeBin)' {
        BeforeAll {
            $script:TmpTools = Join-Path $env:TEMP ("at-loader-tests-" + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $script:TmpTools -Force
        }
        AfterAll {
            if ($script:TmpTools -and (Test-Path -LiteralPath $script:TmpTools)) {
                Remove-Item -LiteralPath $script:TmpTools -Recurse -Force -ErrorAction Ignore
            }
        }

        It 'carrega Core/ no import sem carregar Tools/icp até a 1ª execução' {
            InModuleScope AgentTools {
                $script:AgentToolsCoreModules.Contains('Loader') | Should -BeTrue
                $script:AgentToolsCoreModules.Contains('Masking') | Should -BeTrue
                $script:AgentToolsCoreModules.Contains('Theme') | Should -BeTrue
                $script:AgentToolsCoreModules.Contains('Terminal') | Should -BeTrue
                $script:AgentToolsCoreModules.Contains('Process') | Should -BeTrue
                $script:AgentToolsFunctionOwners['icp'] | Should -Be 'Tool:icp:Entry'
            }
        }

        It 'Import-AgentToolsTool respeita ordem explícita, isola escopo do módulo e é idempotente' {
            $tDir = Join-Path $script:TmpTools 'demo'
            $null = New-Item -ItemType Directory -Path $tDir -Force
            Set-Content -LiteralPath (Join-Path $tDir 'first.ps1') -Value 'function Get-DemoOrder { return "first" }'
            Set-Content -LiteralPath (Join-Path $tDir 'second.ps1') -Value 'function Invoke-DemoTool { return "$(Get-DemoOrder)-second" }'
            @'
@{
    Name = 'demo'
    Version = '0.1.0'
    Entrypoint = 'entry.ps1'
    ExportedFunctions = @()
    RequiresCore = @('Loader', 'Masking')
    Files = @('first.ps1', 'second.ps1')
    NativeBinaries = @{}
}
'@ | Set-Content -LiteralPath (Join-Path $tDir 'tool.psd1')
            Set-Content -LiteralPath (Join-Path $tDir 'entry.ps1') -Value ''

            $env:AGENTTOOLS_TEST_TOOLSROOT = $script:TmpTools
            try {
                InModuleScope AgentTools {
                    $root = $env:AGENTTOOLS_TEST_TOOLSROOT
                    Test-AgentToolsToolLoaded -Name 'demo' -ToolsRoot $root | Should -BeFalse
                    Import-AgentToolsTool -Name 'demo' -ToolsRoot $root
                    Test-AgentToolsToolLoaded -Name 'demo' -ToolsRoot $root | Should -BeTrue
                    Invoke-DemoTool | Should -BeExactly 'first-second'
                    # Idempotente na segunda chamada:
                    { Import-AgentToolsTool -Name 'demo' -ToolsRoot $root } | Should -Not -Throw
                }
                # Não vazou para o escopo global:
                Get-Command Invoke-DemoTool -ErrorAction Ignore | Should -BeNullOrEmpty
            }
            finally {
                Remove-Item Env:AGENTTOOLS_TEST_TOOLSROOT -ErrorAction Ignore
            }
        }

        It 'Import-AgentToolsTool falha alto quando RequiresCore está ausente' {
            $tDir = Join-Path $script:TmpTools 'missingcore'
            $null = New-Item -ItemType Directory -Path $tDir -Force
            Set-Content -LiteralPath (Join-Path $tDir 'a.ps1') -Value 'function Get-MissingCoreFn { 1 }'
            @'
@{
    Name = 'missingcore'
    Version = '0.1.0'
    Entrypoint = 'a.ps1'
    RequiresCore = @('CoreInexistente')
    Files = @('a.ps1')
}
'@ | Set-Content -LiteralPath (Join-Path $tDir 'tool.psd1')

            $env:AGENTTOOLS_TEST_TOOLSROOT = $script:TmpTools
            try {
                InModuleScope AgentTools {
                    { Import-AgentToolsTool -Name 'missingcore' -ToolsRoot $env:AGENTTOOLS_TEST_TOOLSROOT } | Should -Throw '*CoreInexistente*'
                    Test-AgentToolsToolLoaded -Name 'missingcore' -ToolsRoot $env:AGENTTOOLS_TEST_TOOLSROOT | Should -BeFalse
                }
            }
            finally { Remove-Item Env:AGENTTOOLS_TEST_TOOLSROOT -ErrorAction Ignore }
        }

        It 'Import-AgentToolsTool falha alto em colisão de nome sem executar arquivos nem promover funções parciais' {
            $tDir = Join-Path $script:TmpTools 'collide'
            $null = New-Item -ItemType Directory -Path $tDir -Force
            Set-Content -LiteralPath (Join-Path $tDir 'good.ps1') -Value "`$script:AgentToolsCollideProbe = 'EXECUTOU'`r`nfunction Invoke-CollideSafeTemp { 1 }"
            Set-Content -LiteralPath (Join-Path $tDir 'bad.ps1') -Value 'function Hide-IcpSegredo { "sequestrado" }'
            @'
@{
    Name = 'collide'
    Version = '0.1.0'
    Entrypoint = 'good.ps1'
    RequiresCore = @('Masking')
    Files = @('good.ps1', 'bad.ps1')
}
'@ | Set-Content -LiteralPath (Join-Path $tDir 'tool.psd1')

            $env:AGENTTOOLS_TEST_TOOLSROOT = $script:TmpTools
            try {
                InModuleScope AgentTools {
                    $script:AgentToolsCollideProbe = $null
                    { Import-AgentToolsTool -Name 'collide' -ToolsRoot $env:AGENTTOOLS_TEST_TOOLSROOT } | Should -Throw '*Colisão de função*'
                    $script:AgentToolsCollideProbe | Should -BeNullOrEmpty
                    Test-AgentToolsToolLoaded -Name 'collide' -ToolsRoot $env:AGENTTOOLS_TEST_TOOLSROOT | Should -BeFalse
                    # Rollback atômico: good.ps1 não foi promovida e Hide-IcpSegredo original permanece intacta.
                    Get-Command Invoke-CollideSafeTemp -ErrorAction Ignore | Should -BeNullOrEmpty
                    $c = 0
                    (Hide-IcpSegredo -Text ('gh' + 'p_' + ('A' * 24)) -Contagem ([ref]$c)) | Should -Match '\[segredo ocultado: github\]'
                }
            }
            finally { Remove-Item Env:AGENTTOOLS_TEST_TOOLSROOT -ErrorAction Ignore }
        }

        It 'Test-AgentToolsRelativeChildPath bloqueia junção/reparse point em Import-AgentToolsTool e Resolve-AgentToolsNativeBin' {
            $extDir = Join-Path $script:TmpTools 'outside-target'
            $null = New-Item -ItemType Directory -Path $extDir -Force
            Set-Content -LiteralPath (Join-Path $extDir 'ext.ps1') -Value 'function Get-OutsideJunctionFn { 1 }'
            $extBin = Join-Path $extDir 'ext.exe'
            [System.IO.File]::WriteAllBytes($extBin, [byte[]](9, 8, 7, 6))
            $extHash = (Get-FileHash -LiteralPath $extBin -Algorithm SHA256).Hash.ToLowerInvariant()

            $tDir = Join-Path $script:TmpTools 'junctool'
            $null = New-Item -ItemType Directory -Path $tDir -Force
            Set-Content -LiteralPath (Join-Path $tDir 'entry.ps1') -Value ''
            $juncPath = Join-Path $tDir 'link'
            $null = New-Item -ItemType Junction -Path $juncPath -Target $extDir
            @"
@{
    Name = 'junctool'
    Version = '0.1.0'
    Entrypoint = 'entry.ps1'
    Files = @('link\ext.ps1')
    NativeBinaries = @{
        ExtBin = @{ RelativePath = 'link\ext.exe'; Sha256 = '$extHash' }
    }
}
"@ | Set-Content -LiteralPath (Join-Path $tDir 'tool.psd1')

            $env:AGENTTOOLS_TEST_TOOLSROOT = $script:TmpTools
            try {
                InModuleScope AgentTools {
                    $r = $env:AGENTTOOLS_TEST_TOOLSROOT
                    { Import-AgentToolsTool -Name 'junctool' -ToolsRoot $r } | Should -Throw '*inválido ou ausente*'
                    $resBin = Resolve-AgentToolsNativeBin -ToolName 'junctool' -BinaryName 'ExtBin' -ToolsRoot $r
                    $resBin.Available | Should -BeFalse
                    $resBin.Reason | Should -BeExactly 'invalid-path'
                }
            }
            finally { Remove-Item Env:AGENTTOOLS_TEST_TOOLSROOT -ErrorAction Ignore }
        }

        It 'Import-AgentToolsTool bloqueia path traversal fora da pasta da ferramenta' {
            $tDir = Join-Path $script:TmpTools 'trav'
            $null = New-Item -ItemType Directory -Path $tDir -Force
            @'
@{
    Name = 'trav'
    Version = '0.1.0'
    Entrypoint = '..\demo\entry.ps1'
    RequiresCore = @('Loader')
    Files = @('..\demo\first.ps1')
}
'@ | Set-Content -LiteralPath (Join-Path $tDir 'tool.psd1')

            $env:AGENTTOOLS_TEST_TOOLSROOT = $script:TmpTools
            try {
                InModuleScope AgentTools {
                    { Import-AgentToolsTool -Name 'trav' -ToolsRoot $env:AGENTTOOLS_TEST_TOOLSROOT } | Should -Throw '*inválido ou ausente*'
                }
            }
            finally { Remove-Item Env:AGENTTOOLS_TEST_TOOLSROOT -ErrorAction Ignore }
        }

        It 'Resolve-AgentToolsNativeBin valida SHA-256 e sinaliza fallback em ausência, hash errado ou caminho inválido' {
            $tDir = Join-Path $script:TmpTools 'nativetest'
            $binDir = Join-Path $tDir 'bin\win-x64'
            $null = New-Item -ItemType Directory -Path $binDir -Force
            $binPath = Join-Path $binDir 'fake-tool.exe'
            [System.IO.File]::WriteAllBytes($binPath, [byte[]](1, 2, 3, 4, 5, 6, 7, 8))
            $realHash = (Get-FileHash -LiteralPath $binPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $wrongHash = ('0' * 64)

            @"
@{
    Name = 'nativetest'
    Version = '0.1.0'
    Entrypoint = 'entry.ps1'
    NativeBinaries = @{
        GoodBin   = @{ RelativePath = 'bin\win-x64\fake-tool.exe'; Sha256 = '$realHash' }
        BadHash   = @{ RelativePath = 'bin\win-x64\fake-tool.exe'; Sha256 = '$wrongHash' }
        NoHash    = @{ RelativePath = 'bin\win-x64\fake-tool.exe'; Sha256 = '' }
        Missing   = @{ RelativePath = 'bin\win-x64\nao-existe.exe'; Sha256 = '$realHash' }
        Traversal = @{ RelativePath = '..\..\evil.exe'; Sha256 = '$realHash' }
    }
}
"@ | Set-Content -LiteralPath (Join-Path $tDir 'tool.psd1')
            Set-Content -LiteralPath (Join-Path $tDir 'entry.ps1') -Value ''

            $env:AGENTTOOLS_TEST_TOOLSROOT = $script:TmpTools
            try {
                InModuleScope AgentTools {
                    $r = $env:AGENTTOOLS_TEST_TOOLSROOT
                    $ok = Resolve-AgentToolsNativeBin -ToolName 'nativetest' -BinaryName 'GoodBin' -ToolsRoot $r
                    $ok.Available | Should -BeTrue
                    $ok.Fallback | Should -BeFalse
                    $ok.Reason | Should -BeExactly 'ok'
                    Test-Path -LiteralPath $ok.Path | Should -BeTrue

                    $bad = Resolve-AgentToolsNativeBin -ToolName 'nativetest' -BinaryName 'BadHash' -ToolsRoot $r
                    $bad.Available | Should -BeFalse
                    $bad.Fallback | Should -BeTrue
                    $bad.Reason | Should -BeExactly 'sha256-mismatch'
                    $bad.Path | Should -BeNullOrEmpty

                    $noH = Resolve-AgentToolsNativeBin -ToolName 'nativetest' -BinaryName 'NoHash' -ToolsRoot $r
                    $noH.Available | Should -BeFalse
                    $noH.Fallback | Should -BeTrue
                    $noH.Reason | Should -BeExactly 'missing-sha256'

                    $miss = Resolve-AgentToolsNativeBin -ToolName 'nativetest' -BinaryName 'Missing' -ToolsRoot $r
                    $miss.Available | Should -BeFalse
                    $miss.Fallback | Should -BeTrue
                    $miss.Reason | Should -BeExactly 'file-not-found'

                    $trav = Resolve-AgentToolsNativeBin -ToolName 'nativetest' -BinaryName 'Traversal' -ToolsRoot $r
                    $trav.Available | Should -BeFalse
                    $trav.Fallback | Should -BeTrue
                    $trav.Reason | Should -BeExactly 'invalid-path'

                    $none = Resolve-AgentToolsNativeBin -ToolName 'nativetest' -BinaryName 'NaoDeclarado' -ToolsRoot $r
                    $none.Available | Should -BeFalse
                    $none.Fallback | Should -BeTrue
                    $none.Reason | Should -BeExactly 'not-declared'
                }
            }
            finally { Remove-Item Env:AGENTTOOLS_TEST_TOOLSROOT -ErrorAction Ignore }
        }
    }

    Context '2. Core/Masking (Basic auth, colchetes, JSON escapado, timeout e AST)' {
        It 'oculta Authorization Basic curto, valor com [segredo] parcial, colchetes e JSON escapado com idempotência' {
            InModuleScope AgentTools {
                $c = 0
                $b1 = Hide-IcpSegredo -Text ('Authorization: Basic ' + ('dXNlcjpzZWNyZXQ=')) -Contagem ([ref]$c)
                $b1 | Should -BeExactly 'Authorization: Basic [segredo ocultado: basic-auth]'
                $c | Should -Be 1

                $c = 0
                $bShort = Hide-IcpSegredo -Text 'Authorization: Basic YTpi' -Contagem ([ref]$c)
                $bShort | Should -BeExactly 'Authorization: Basic [segredo ocultado: basic-auth]'
                $c | Should -Be 1

                $c = 0
                $b2 = Hide-IcpSegredo -Text ('"Proxy-Authorization": "Basic YWJjZGVmZ2g="') -Contagem ([ref]$c)
                $b2 | Should -Match '\[segredo ocultado: basic-auth\]'

                $c = 0
                $comum = Hide-IcpSegredo -Text 'Basic configuration step completed' -Contagem ([ref]$c)
                $comum | Should -BeExactly 'Basic configuration step completed'
                $c | Should -Be 0

                $c = 0
                $falsoMarc = Hide-IcpSegredo -Text 'password=[segredo]valor-ficticio' -Contagem ([ref]$c)
                $falsoMarc | Should -BeExactly 'password=[segredo ocultado: atribuicao]'
                $c | Should -Be 1

                $c = 0
                $idemp = Hide-IcpSegredo -Text $falsoMarc -Contagem ([ref]$c)
                $idemp | Should -BeExactly 'password=[segredo ocultado: atribuicao]'
                $c | Should -Be 0

                $c = 0
                $col = Hide-IcpSegredo -Text 'password=[Sec123] api_key=[abc]999 token=[]' -Contagem ([ref]$c)
                $col | Should -BeExactly 'password=[segredo ocultado: atribuicao] api_key=[segredo ocultado: atribuicao] token=[]'
                $c | Should -Be 2

                $c = 0
                $jEsc = Hide-IcpSegredo -Text '{\"password\":\"seg\\\"ret123\",\"user\":\"joao\",\"empty\":\"\"}' -Contagem ([ref]$c)
                $jEsc | Should -BeExactly '{\"password\":[segredo ocultado: atribuicao],\"user\":\"joao\",\"empty\":\"\"}'
                $c | Should -Be 1
            }
        }

        It 'Hide-IcpAtribuicaoSensivel oculta literal em AssignmentStatementAst sensível sem tocar booleanos/nulos/contadores' {
            InModuleScope AgentTools {
                $t = $null; $e = $null
                $ast1 = [System.Management.Automation.Language.Parser]::ParseInput('$api_key = "segredo-123"; $token_count = 10; $secret = $null', [ref]$t, [ref]$e)
                $st1 = $ast1.EndBlock.Statements[0]
                $st2 = $ast1.EndBlock.Statements[1]
                $st3 = $ast1.EndBlock.Statements[2]

                $c = 0
                (Hide-IcpAtribuicaoSensivel -Ast $st1 -Text $st1.Extent.Text -Contagem ([ref]$c)) | Should -BeExactly '$api_key = [segredo ocultado: atribuicao]'
                $c | Should -Be 1

                $c = 0
                (Hide-IcpAtribuicaoSensivel -Ast $st2 -Text $st2.Extent.Text -Contagem ([ref]$c)) | Should -BeExactly '$token_count = 10'
                $c | Should -Be 0

                $c = 0
                (Hide-IcpAtribuicaoSensivel -Ast $st3 -Text $st3.Extent.Text -Contagem ([ref]$c)) | Should -BeExactly '$secret = $null'
                $c | Should -Be 0
            }
        }

        It 'Hide-IcpSegredo falha fechado em timeout regex sem vazar trecho original' {
            InModuleScope AgentTools {
                $c = 0
                $tinyTimeout = [TimeSpan]::FromTicks(1)
                $res = Hide-IcpSegredo -Text (('x' * 5000) + ' password=' + ('v' * 2000)) -Contagem ([ref]$c) -Timeout $tinyTimeout
                $res | Should -BeExactly '[segredo ocultado: timeout-mascara]'
                $res | Should -Not -Match 'vvvv'
                $c | Should -BeGreaterThan 0
            }
        }
    }

    Context '3. Core/Process e Core/Terminal (namespace versionado, GetProcessTimes e cleanup)' {
        It 'compila ProcessTree no namespace versionado, valida TryKillVerified e preserva processo preexistente em KillNewChildren' {
            InModuleScope AgentTools {
                Initialize-AgentToolsProcessTree | Should -BeTrue
                $pt = Get-AgentToolsProcessTreeType
                $pt | Should -Not -BeNullOrEmpty
                $pt.Namespace | Should -BeExactly $script:AgentToolsTypeNamespace
                $pt.Namespace | Should -Match '^AgentTools\.V1_0_0$'

                $myCt = $pt::GetProcessCreationTime($PID)
                $myCt | Should -BeGreaterThan 0

                $proc1 = Start-Process pwsh -ArgumentList @('-NoProfile', '-NoLogo', '-Command', 'Start-Sleep 30') -WindowStyle Hidden -PassThru
                $proc2 = $null
                try {
                    Start-Sleep -Milliseconds 300
                    $ctProc1 = $pt::GetProcessCreationTime($proc1.Id)
                    $ctProc1 | Should -BeGreaterThan 0

                    # TryKillVerified recusa horário 0, horário divergente e PID ausente:
                    $pt::TryKillVerified($proc1.Id, 0) | Should -BeFalse
                    $pt::TryKillVerified($proc1.Id, $ctProc1 - 10000) | Should -BeFalse
                    $pt::TryKillVerified(99999999, $ctProc1) | Should -BeFalse
                    $proc1.HasExited | Should -BeFalse

                    # Mesmo PID + mesmo CreationTime -> não é tratado como novo filho:
                    $baseReal = $pt::CaptureBaseline($PID)
                    $baseReal.ContainsKey($proc1.Id) | Should -BeTrue
                    @($pt::GetNewChildren($PID, $baseReal)) | Should -Not -Contain "pwsh.exe#$($proc1.Id)"

                    # Mesmo PID + CreationTime divergente (simula reúso de PID) -> detectado como novo filho:
                    $baseReuso = [System.Collections.Generic.Dictionary[int, long]]::new()
                    $baseReuso[$proc1.Id] = $ctProc1 - 10000
                    (@($pt::GetNewChildren($PID, $baseReuso)) -join ',') | Should -Match "#$($proc1.Id)\b"

                    # Segundo filho iniciado após baseline é morto, preservando $proc1 preexistente:
                    $proc2 = Start-Process pwsh -ArgumentList @('-NoProfile', '-NoLogo', '-Command', 'Start-Sleep 30') -WindowStyle Hidden -PassThru
                    Start-Sleep -Milliseconds 300
                    $killed = @($pt::KillNewChildren($PID, $baseReal))
                    ($killed -join ',') | Should -Match "#$($proc2.Id)\b"
                    ($killed -join ',') | Should -Not -Match "#$($proc1.Id)\b"
                    $proc2.WaitForExit(3000) | Should -BeTrue
                    $proc1.HasExited | Should -BeFalse
                }
                finally {
                    foreach ($pr in @($proc1, $proc2)) {
                        if ($pr -and -not $pr.HasExited) {
                            Stop-Process -Id $pr.Id -Force -ErrorAction Ignore
                        }
                    }
                }
            }
        }

        It 'Restore-AgentToolsConsoleState restaura encodings sem lançar exceção mesmo se um passo falhar' {
            InModuleScope AgentTools {
                $encOut = [Console]::OutputEncoding
                $encIn = [Console]::InputEncoding
                { Restore-AgentToolsConsoleState -OutputEncoding $encOut -InputEncoding $encIn } | Should -Not -Throw
            }
        }
    }
}
