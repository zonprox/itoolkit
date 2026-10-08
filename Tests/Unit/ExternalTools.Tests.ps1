# ==============================================================================
# ExternalTools.Tests.ps1
# Unit test suite for Modules/ExternalTools (Features 49, 50, 51)
# Covers: Test-InternetConnectivity, Invoke-BrowserDebloat, Invoke-Win11Debloat.
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:ExtToolsManifest = Join-Path $ProjectRoot 'Modules/ExternalTools/ExternalTools.psd1'
$isExtToolsAvailable = Test-Path $script:ExtToolsManifest

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    $manifests = Get-ChildItem -Path (Join-Path $root "Modules") -Filter "*.psd1" -Recurse -ErrorAction SilentlyContinue
    if ($manifests) {
        foreach ($m in $manifests) {
            try {
                Import-Module $m.FullName -Force -ErrorAction Stop
            } catch {
                Write-Warning "Failed to load module $($m.Name): $_"
            }
        }
    }
}
Describe 'Unit: External Tools & Quick Launchers Module' {

    Context 'Pre-Flight Internet Connectivity Check' {
        It 'Test-InternetConnectivity returns true when endpoints respond' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-Connection { return $true }
            Mock Invoke-WebRequest { return [PSCustomObject]@{ StatusCode = 200 } }

            $online = Test-InternetConnectivity -TargetHosts @('1.1.1.1', 'github.com')
            $online | Should -BeTrue
        }

        It 'Test-InternetConnectivity returns false when offline' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-Connection { return $false }
            Mock Invoke-WebRequest { throw "Connection refused" }

            $online = Test-InternetConnectivity
            $online | Should -BeFalse
        }
    }

    Context 'Win11Debloat Launcher' {
        It 'Invoke-Win11Debloat aborts if internet connectivity check fails' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-InternetConnectivity { return $false }
            Mock Start-Process { throw "Should never launch when offline" }

            { Invoke-Win11Debloat } | Should -Throw
        }

        It 'Invoke-Win11Debloat prompts for user confirmation before launching' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Show-ToolkitConfirmation { return $false } # User cancelled
            Mock Start-Process { throw "Should not launch if user cancelled" }

            $res = Invoke-Win11Debloat
            $res.Launched | Should -BeFalse
        }

        It 'Invoke-Win11Debloat supports WhatIf without launching' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-InternetConnectivity { return $true }
            $res = Invoke-Win11Debloat -WhatIf
            $res | Should -Not -BeNullOrEmpty
            $res.Launched | Should -BeFalse
        }

        It 'Invoke-Win11Debloat launches script when confirmed' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Show-ToolkitConfirmation { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }

            $res = Invoke-Win11Debloat
            $res.ToolName | Should -Be 'Win11Debloat'
            $res.ScriptUrl | Should -Be 'https://debloat.raphi.re/'
            $res.Launched | Should -BeTrue
        }
    }

    Context 'Browser Debloat Launcher' {
        It 'Invoke-BrowserDebloat checks internet and prompts confirmation before launch' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Show-ToolkitConfirmation { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }

            $res = Invoke-BrowserDebloat
            $res.ToolName | Should -Be 'BrowserDebloat'
            $res.ScriptUrl | Should -Be 'https://debloat.yashg.dev/install.ps1'
            $res.Launched | Should -BeTrue
        }

        It 'Invoke-BrowserDebloat supports WhatIf' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-InternetConnectivity { return $true }
            $res = Invoke-BrowserDebloat -WhatIf
            $res.Launched | Should -BeFalse
        }
    }
}
