# ==============================================================================
# AppInstaller.Tests.ps1
# Unit test suite for Modules/AppInstaller
# Covers: Get-ToolkitInstalledApplication, New-ToolkitDesktopShortcut,
#         Set-ToolkitDefaultApplication, Install-ToolkitApplication.
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:AppInstallerManifest = Join-Path $ProjectRoot 'Modules/AppInstaller/AppInstaller.psd1'
$isAppInstallerAvailable = Test-Path $script:AppInstallerManifest

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
    if (-not (Get-PSDrive -Name 'C' -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name 'C' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -ErrorAction SilentlyContinue -WhatIf:$false | Out-Null
    }
}

Describe 'Unit: AppInstaller Module' {

    Context 'Get-ToolkitInstalledApplication' {
        It 'Returns all 6 catalog applications when AppName is All or omitted' -Skip:(-not $isAppInstallerAvailable) {
            $apps = Get-ToolkitInstalledApplication
            $apps | Should -Not -BeNullOrEmpty
            $apps.Count | Should -Be 6
            $appNames = $apps | ForEach-Object { $_.AppName }
            $appNames | Should -Contain 'UniKey'
            $appNames | Should -Contain 'UltraVNC'
            $appNames | Should -Contain 'KLiteCodec'
            $appNames | Should -Contain 'Chrome'
            $appNames | Should -Contain 'VCRedistAIO'
            $appNames | Should -Contain 'FoxitReader'
        }

        It 'Filters specifically by AppName' -Skip:(-not $isAppInstallerAvailable) {
            $chrome = Get-ToolkitInstalledApplication -AppName 'Chrome'
            $chrome | Should -Not -BeNullOrEmpty
            $chrome.AppName | Should -Be 'Chrome'
            $chrome.DisplayName | Should -Be 'Google Chrome Browser'
        }

        It 'Detects installed status when candidate path exists' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $LiteralPath -like '*chrome.exe' }
            Mock Get-Item {
                return [PSCustomObject]@{
                    VersionInfo = [PSCustomObject]@{ ProductVersion = '130.0.6723.70' }
                }
            } -ParameterFilter { $LiteralPath -like '*chrome.exe' }

            $res = Get-ToolkitInstalledApplication -AppName 'Chrome'
            $res.Installed | Should -BeTrue
            $res.ExecutablePath | Should -Match 'chrome\.exe$'
            $res.Version | Should -Be '130.0.6723.70'
        }
    }

    Context 'New-ToolkitDesktopShortcut' {
        BeforeAll {
            $script:tempDesktop = Join-Path ([System.IO.Path]::GetTempPath()) ("IToolkit_DesktopTest_" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:tempDesktop -Force | Out-Null
        }

        AfterAll {
            if ($script:tempDesktop -and (Test-Path $script:tempDesktop)) {
                Remove-Item -LiteralPath $script:tempDesktop -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Creates shortcut on target desktop directory' -Skip:(-not $isAppInstallerAvailable) {
            $mockExe = Join-Path $script:tempDesktop 'testapp.exe'
            Set-Content -Path $mockExe -Value 'MOCK_BIN' -Encoding UTF8

            $res = New-ToolkitDesktopShortcut -TargetExecutable $mockExe -ShortcutName 'Test App.lnk' -DesktopDirectory $script:tempDesktop
            $res | Should -Not -BeNullOrEmpty
            $res.Created | Should -BeTrue
            Test-Path (Join-Path $script:tempDesktop 'Test App.lnk') | Should -BeTrue
        }

        It 'Respects Force flag when shortcut already exists' -Skip:(-not $isAppInstallerAvailable) {
            $mockExe = Join-Path $script:tempDesktop 'testapp2.exe'
            Set-Content -Path $mockExe -Value 'MOCK_BIN' -Encoding UTF8

            # First create
            New-ToolkitDesktopShortcut -TargetExecutable $mockExe -ShortcutName 'Test App 2.lnk' -DesktopDirectory $script:tempDesktop | Out-Null
            
            # Second create without force should report AlreadyExists
            $resNoForce = New-ToolkitDesktopShortcut -TargetExecutable $mockExe -ShortcutName 'Test App 2.lnk' -DesktopDirectory $script:tempDesktop
            $resNoForce.Created | Should -BeFalse
            $resNoForce.AlreadyExists | Should -BeTrue

            # Third create with force should recreate
            $resForce = New-ToolkitDesktopShortcut -TargetExecutable $mockExe -ShortcutName 'Test App 2.lnk' -DesktopDirectory $script:tempDesktop -Force
            $resForce.Created | Should -BeTrue
        }

        It 'Supports -WhatIf without creating shortcut file' -Skip:(-not $isAppInstallerAvailable) {
            $mockExe = Join-Path $script:tempDesktop 'whatifapp.exe'
            $whatIfLnk = Join-Path $script:tempDesktop 'WhatIf.lnk'

            $res = New-ToolkitDesktopShortcut -TargetExecutable $mockExe -ShortcutName 'WhatIf.lnk' -DesktopDirectory $script:tempDesktop -WhatIf
            $res.Created | Should -BeFalse
            Test-Path $whatIfLnk | Should -BeFalse
        }
    }

    Context 'Set-ToolkitDefaultApplication' {
        It 'Configures Chrome as default web browser and associates protocols' -Skip:(-not $isAppInstallerAvailable) {
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            Mock Test-Path { return $true }
            Mock New-Item { return $null }
            Mock Set-ItemProperty { return $null }

            $res = Set-ToolkitDefaultApplication -Application 'Chrome' -ExecutablePath 'C:\Program Files\Google\Chrome\Application\chrome.exe'
            $res | Should -Not -BeNullOrEmpty
            $res.Application | Should -Be 'Chrome'
            $res.Handlers | Should -Contain 'http'
            $res.Handlers | Should -Contain 'https'
            $res.Handlers | Should -Contain '.html'
            $res.Handlers | Should -Contain '.htm'
        }

        It 'Configures Foxit Reader as default PDF viewer and associates .pdf' -Skip:(-not $isAppInstallerAvailable) {
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            Mock Test-Path { return $true }
            Mock New-Item { return $null }
            Mock Set-ItemProperty { return $null }

            $res = Set-ToolkitDefaultApplication -Application 'FoxitReader' -ExecutablePath 'C:\Program Files\Foxit Software\Foxit PDF Reader\FoxitPDFReader.exe'
            $res | Should -Not -BeNullOrEmpty
            $res.Application | Should -Be 'FoxitReader'
            $res.Handlers | Should -Contain '.pdf'
        }

        It 'Configures both Chrome and Foxit when Application is All' -Skip:(-not $isAppInstallerAvailable) {
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            Mock Test-Path { return $true }
            Mock New-Item { return $null }
            Mock Set-ItemProperty { return $null }

            $res = Set-ToolkitDefaultApplication -Application 'All'
            $res.Count | Should -Be 2
            ($res | Where-Object { $_.Application -eq 'Chrome' }) | Should -Not -BeNullOrEmpty
            ($res | Where-Object { $_.Application -eq 'FoxitReader' }) | Should -Not -BeNullOrEmpty
        }

        It 'Supports -WhatIf mode without applying changes' -Skip:(-not $isAppInstallerAvailable) {
            $res = Set-ToolkitDefaultApplication -Application 'Chrome' -WhatIf
            $res.DefaultSet | Should -BeFalse
            $res.Details | Should -Match 'WhatIf'
        }
    }

    Context 'Install-ToolkitApplication' {
        It 'Fails fast if internet connectivity pre-flight check fails' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $false }

            { Install-ToolkitApplication -AppName 'Chrome' } | Should -Throw '*Internet connectivity is required*'
        }

        It 'Supports -WhatIf mode returning WhatIf status' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $true }

            $res = Install-ToolkitApplication -AppName 'Chrome' -WhatIf
            $res | Should -Not -BeNullOrEmpty
            $res.AppName | Should -Be 'Chrome'
            $res.Status | Should -Be 'WhatIf'
        }

        It 'Installs application and triggers shortcut and default associations' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Get-Command {
                param($Name)
                if ($Name -eq 'winget') { return [PSCustomObject]@{ Name = 'winget' } }
                return $null
            }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            Mock Get-ToolkitInstalledApplication {
                return [PSCustomObject]@{
                    AppName        = 'Chrome'
                    DisplayName    = 'Google Chrome'
                    Installed      = $true
                    ExecutablePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
                    Version        = '130.0.0.0'
                }
            }
            Mock New-ToolkitDesktopShortcut {
                return [PSCustomObject]@{ Created = $true; ShortcutPath = 'C:\Users\User\Desktop\Google Chrome.lnk' }
            }
            Mock Set-ToolkitDefaultApplication {
                return [PSCustomObject]@{ Application = 'Chrome'; DefaultSet = $true }
            }

            $res = Install-ToolkitApplication -AppName 'Chrome' -CreateShortcut -SetDefault
            $res | Should -Not -BeNullOrEmpty
            $res.AppName | Should -Be 'Chrome'
            $res.Installed | Should -BeTrue
            $res.ShortcutCreated | Should -BeTrue
            $res.DefaultConfigured | Should -BeTrue
            $res.Status | Should -Be 'OK'
        }

        It 'Batch installs All 6 applications' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Get-Command { return $null }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            Mock Get-ToolkitInstalledApplication {
                param($AppName)
                return [PSCustomObject]@{
                    AppName        = $AppName
                    DisplayName    = $AppName
                    Installed      = $true
                    ExecutablePath = "C:\Tools\$AppName\$AppName.exe"
                    Version        = '1.0'
                }
            }
            Mock New-ToolkitDesktopShortcut {
                return [PSCustomObject]@{ Created = $true }
            }
            Mock Set-ToolkitDefaultApplication {
                return [PSCustomObject]@{ DefaultSet = $true }
            }

            $res = Install-ToolkitApplication -AppName 'All'
            $res.Count | Should -Be 6
            $appNames = $res | ForEach-Object { $_.AppName }
            $appNames | Should -Contain 'UniKey'
            $appNames | Should -Contain 'UltraVNC'
            $appNames | Should -Contain 'KLiteCodec'
            $appNames | Should -Contain 'Chrome'
            $appNames | Should -Contain 'VCRedistAIO'
            $appNames | Should -Contain 'FoxitReader'
        }
    }
}
