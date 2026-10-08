# ==============================================================================
# AppInstaller.Tests.ps1
# Unit test suite for Modules/AppInstaller
# Covers: Get-ToolkitInstalledApplication, New-ToolkitDesktopShortcut,
#         Set-ToolkitDefaultApplication, Set-ToolkitChromeExtensionPolicy,
#         Install-ToolkitApplication.
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
        It 'Returns all 7 catalog applications when AppName is All or omitted' -Skip:(-not $isAppInstallerAvailable) {
            $apps = Get-ToolkitInstalledApplication
            $apps | Should -Not -BeNullOrEmpty
            $apps.Count | Should -Be 7
            $appNames = $apps | ForEach-Object { $_.AppName }
            $appNames | Should -Contain 'UniKey'
            $appNames | Should -Contain 'UltraVNC'
            $appNames | Should -Contain 'KLiteCodec'
            $appNames | Should -Contain 'Chrome'
            $appNames | Should -Contain 'VCRedistAIO'
            $appNames | Should -Contain 'FoxitReader'
            $appNames | Should -Contain 'Zalo'
        }

        It 'Filters specifically by AppName for Chrome' -Skip:(-not $isAppInstallerAvailable) {
            $chrome = Get-ToolkitInstalledApplication -AppName 'Chrome'
            $chrome | Should -Not -BeNullOrEmpty
            $chrome.AppName | Should -Be 'Chrome'
            $chrome.DisplayName | Should -Be 'Google Chrome Browser'
        }

        It 'Filters specifically by AppName for Zalo' -Skip:(-not $isAppInstallerAvailable) {
            $zalo = Get-ToolkitInstalledApplication -AppName 'Zalo'
            $zalo | Should -Not -BeNullOrEmpty
            $zalo.AppName | Should -Be 'Zalo'
            $zalo.DisplayName | Should -Be 'Zalo'
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

        It 'Detects Zalo installed status when candidate path exists' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $LiteralPath -like '*Zalo.exe' }
            Mock Get-Item {
                return [PSCustomObject]@{
                    VersionInfo = [PSCustomObject]@{ ProductVersion = '24.10.1' }
                }
            } -ParameterFilter { $LiteralPath -like '*Zalo.exe' }

            $res = Get-ToolkitInstalledApplication -AppName 'Zalo'
            $res.Installed | Should -BeTrue
            $res.ExecutablePath | Should -Match 'Zalo\.exe$'
            $res.Version | Should -Be '24.10.1'
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

        It 'Creates desktop shortcut for Zalo' -Skip:(-not $isAppInstallerAvailable) {
            $mockZalo = Join-Path $script:tempDesktop 'Zalo.exe'
            Set-Content -Path $mockZalo -Value 'MOCK_BIN' -Encoding UTF8

            $res = New-ToolkitDesktopShortcut -TargetExecutable $mockZalo -ShortcutName 'Zalo.lnk' -DesktopDirectory $script:tempDesktop
            $res | Should -Not -BeNullOrEmpty
            $res.Created | Should -BeTrue
            Test-Path (Join-Path $script:tempDesktop 'Zalo.lnk') | Should -BeTrue
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

    Context 'Set-ToolkitChromeExtensionPolicy' {
        It 'Configures ExtensionInstallForcelist with uBlock Origin Lite ID and update URL' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $true }
            Mock New-Item { return $null }
            Mock Get-ItemProperty { return $null }
            $script:recordedPolicies = [System.Collections.Generic.List[PSCustomObject]]::new()
            Mock Set-ItemProperty {
                param($Path, $Name, $Value)
                $script:recordedPolicies.Add([PSCustomObject]@{ Path = $Path; Name = $Name; Value = $Value })
            }

            $res = Set-ToolkitChromeExtensionPolicy
            $res | Should -Not -BeNullOrEmpty
            $res.Configured | Should -BeTrue
            $res.ExtensionId | Should -Be 'ddkjiahejlhfcafbddmgiahcphecmpfh'
            $res.PolicyEntry | Should -Be 'ddkjiahejlhfcafbddmgiahcphecmpfh;https://clients2.google.com/service/update2/crx'
            $script:recordedPolicies.Count | Should -BeGreaterThan 0
            ($script:recordedPolicies | Where-Object { $_.Value -like 'ddkjiahejlhfcafbddmgiahcphecmpfh*' }) | Should -Not -BeNullOrEmpty
        }

        It 'Supports -WhatIf mode for Chrome extension policy' -Skip:(-not $isAppInstallerAvailable) {
            $res = Set-ToolkitChromeExtensionPolicy -WhatIf
            $res.Configured | Should -BeFalse
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
                if ($Name -eq 'Set-ToolkitChromeExtensionPolicy') { return [PSCustomObject]@{ Name = 'Set-ToolkitChromeExtensionPolicy' } }
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
            Mock Set-ToolkitChromeExtensionPolicy {
                return [PSCustomObject]@{ ExtensionId = 'ddkjiahejlhfcafbddmgiahcphecmpfh'; Configured = $true }
            }

            $res = Install-ToolkitApplication -AppName 'Chrome' -CreateShortcut -SetDefault -Force
            $res | Should -Not -BeNullOrEmpty
            $res.AppName | Should -Be 'Chrome'
            $res.Installed | Should -BeTrue
            $res.ShortcutCreated | Should -BeTrue
            $res.DefaultConfigured | Should -BeTrue
            $res.Status | Should -Be 'OK'
        }

        It 'Installs Zalo PC with desktop shortcut and returns structured result' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Get-Command {
                param($Name)
                if ($Name -eq 'winget') { return [PSCustomObject]@{ Name = 'winget' } }
                return $null
            }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            $script:zaloCheckCount = 0
            Mock Get-ToolkitInstalledApplication {
                $script:zaloCheckCount++
                if ($script:zaloCheckCount -eq 1) {
                    return [PSCustomObject]@{ AppName = 'Zalo'; DisplayName = 'Zalo'; Installed = $false; ExecutablePath = $null; Version = $null }
                }
                return [PSCustomObject]@{ AppName = 'Zalo'; DisplayName = 'Zalo'; Installed = $true; ExecutablePath = 'C:\Users\User\AppData\Local\Programs\Zalo\Zalo.exe'; Version = '24.10.1' }
            }
            Mock New-ToolkitDesktopShortcut {
                return [PSCustomObject]@{ Created = $true; ShortcutPath = 'C:\Users\User\Desktop\Zalo.lnk' }
            }

            $res = Install-ToolkitApplication -AppName 'Zalo' -CreateShortcut
            $res | Should -Not -BeNullOrEmpty
            $res.AppName | Should -Be 'Zalo'
            $res.DisplayName | Should -Be 'Zalo'
            $res.Installed | Should -BeTrue
            $res.ShortcutCreated | Should -BeTrue
            $res.Status | Should -Be 'OK'
        }

        It 'Skips already-installed application when -Force is omitted without running installer or re-downloading' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $true }
            $script:startProcessInvoked = $false
            Mock Start-Process {
                $script:startProcessInvoked = $true
                return [PSCustomObject]@{ ExitCode = 0 }
            }
            Mock Get-ToolkitInstalledApplication {
                return [PSCustomObject]@{
                    AppName        = 'Chrome'
                    DisplayName    = 'Google Chrome'
                    Installed      = $true
                    ExecutablePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
                    Version        = '130.0.0.0'
                }
            }

            $res = Install-ToolkitApplication -AppName 'Chrome'
            $res | Should -Not -BeNullOrEmpty
            $res.AppName | Should -Be 'Chrome'
            $res.Installed | Should -BeTrue
            $res.Status | Should -Be 'OK'
            $script:startProcessInvoked | Should -BeFalse
        }

        It 'Re-executes installation when -Force is explicitly passed for an already-installed application' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $true }
            $script:startProcessInvoked = $false
            Mock Start-Process {
                $script:startProcessInvoked = $true
                return [PSCustomObject]@{ ExitCode = 0 }
            }
            Mock Get-Command {
                param($Name)
                if ($Name -eq 'winget') { return [PSCustomObject]@{ Name = 'winget' } }
                return $null
            }
            Mock Get-ToolkitInstalledApplication {
                return [PSCustomObject]@{
                    AppName        = 'Chrome'
                    DisplayName    = 'Google Chrome'
                    Installed      = $true
                    ExecutablePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
                    Version        = '130.0.0.0'
                }
            }
            Mock New-ToolkitDesktopShortcut { return [PSCustomObject]@{ Created = $true } }
            Mock Set-ToolkitDefaultApplication { return [PSCustomObject]@{ DefaultSet = $true } }

            $res = Install-ToolkitApplication -AppName 'Chrome' -Force
            $res.Installed | Should -BeTrue
            $script:startProcessInvoked | Should -BeTrue
        }

        It 'Detects and terminates active conflicting processes before installation' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $true }
            $script:killedProcessName = $null
            Mock Get-Process {
                param($Name)
                if ($Name -eq 'Zalo') {
                    return [PSCustomObject]@{ ProcessName = 'Zalo'; Id = 4321 }
                }
                return $null
            }
            Mock Stop-Process {
                param($Name)
                $script:killedProcessName = $Name
            }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            Mock Get-ToolkitInstalledApplication {
                return [PSCustomObject]@{
                    AppName        = 'Zalo'
                    DisplayName    = 'Zalo'
                    Installed      = $true
                    ExecutablePath = 'C:\Zalo\Zalo.exe'
                    Version        = '24.10.1'
                }
            }

            $res = Install-ToolkitApplication -AppName 'Zalo' -Force
            $script:killedProcessName | Should -Be 'Zalo'
        }

        It 'Sequences VCRedistAIO runtime dependency first when installing All applications' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            $script:evaluationOrder = [System.Collections.Generic.List[string]]::new()
            Mock Get-ToolkitInstalledApplication {
                param($AppName)
                if ($AppName -ne 'All') {
                    $script:evaluationOrder.Add($AppName)
                }
                return [PSCustomObject]@{
                    AppName        = $AppName
                    DisplayName    = $AppName
                    Installed      = $true
                    ExecutablePath = "C:\Tools\$AppName\$AppName.exe"
                    Version        = '1.0'
                }
            }

            $res = Install-ToolkitApplication -AppName 'All'
            $script:evaluationOrder.Count | Should -BeGreaterThan 1
            $script:evaluationOrder[0] | Should -Be 'VCRedistAIO'
        }

        It 'Falls back to direct URL download installer when winget returns non-zero exit code' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Get-Command {
                param($Name)
                if ($Name -eq 'winget') { return [PSCustomObject]@{ Name = 'winget' } }
                return $null
            }
            $script:webRequestUri = $null
            Mock Start-Process {
                param($FilePath, $ArgumentList)
                if ($FilePath -eq 'winget') {
                    return [PSCustomObject]@{ ExitCode = 1 } # Winget fails
                }
                return [PSCustomObject]@{ ExitCode = 0 } # Direct installer succeeds
            }
            Mock Invoke-WebRequest {
                param($Uri, $OutFile)
                $script:webRequestUri = $Uri
                Set-Content -LiteralPath $OutFile -Value 'MOCK_EXE'
            }
            $script:checkNum = 0
            Mock Get-ToolkitInstalledApplication {
                param($AppName)
                $script:checkNum++
                if ($script:checkNum -eq 1) {
                    return [PSCustomObject]@{ AppName = $AppName; DisplayName = $AppName; Installed = $false; ExecutablePath = $null }
                }
                return [PSCustomObject]@{ AppName = $AppName; DisplayName = $AppName; Installed = $true; ExecutablePath = 'C:\Tools\Chrome.exe' }
            }

            $res = Install-ToolkitApplication -AppName 'Chrome' -Force
            $res.Installed | Should -BeTrue
            $script:webRequestUri | Should -Match 'chrome_installer\.exe$'
        }

        It 'Installs UniKey strictly without triggering Chrome deployment, default browser association, or Chrome logs' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Get-Command {
                param($Name)
                if ($Name -eq 'winget') { return [PSCustomObject]@{ Name = 'winget' } }
                return $null
            }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            Mock Get-ToolkitInstalledApplication {
                param($AppName)
                return [PSCustomObject]@{
                    AppName        = $AppName
                    DisplayName    = 'UniKey Vietnamese Input Method'
                    Installed      = $true
                    ExecutablePath = 'C:\Program Files\UniKey\UniKeyNT.exe'
                    Version        = '4.3'
                }
            }
            Mock New-ToolkitDesktopShortcut {
                return [PSCustomObject]@{ Created = $true; ShortcutPath = 'C:\Users\User\Desktop\UniKey.lnk' }
            }
            $script:chromeRoutinesCalled = $false
            Mock Set-ToolkitDefaultApplication {
                param($Application)
                if ($Application -eq 'Chrome' -or $Application -eq 'All') {
                    $script:chromeRoutinesCalled = $true
                }
                return @([PSCustomObject]@{ Application = $Application; DefaultSet = $true })
            }
            Mock Set-ToolkitChromeExtensionPolicy {
                $script:chromeRoutinesCalled = $true
                return [PSCustomObject]@{ Configured = $true }
            }

            $res = Install-ToolkitApplication -AppName 'UniKey' -CreateShortcut -Force
            $res | Should -Not -BeNullOrEmpty
            $res.AppName | Should -Be 'UniKey'
            $res.Installed | Should -BeTrue
            $res.DefaultConfigured | Should -BeFalse
            $script:chromeRoutinesCalled | Should -BeFalse
        }

        It 'Emits structured log messages into daily log file in logs directory' -Skip:(-not $isAppInstallerAvailable) {
            $testLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ("IToolkit_LogTest_" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $testLogDir -Force | Out-Null
            try {
                Write-AppInstallerLog -Message "Verifying persistent diagnostic logging capability." -Level 'INFO' -Component 'AppInstaller' -LogDirectory $testLogDir
                $logFiles = Get-ChildItem -Path $testLogDir -Filter "*.log"
                $logFiles.Count | Should -BeGreaterThan 0
                $content = Get-Content -LiteralPath $logFiles[0].FullName -Raw
                $content | Should -Match '\[INFO\] \[AppInstaller\] Verifying persistent diagnostic logging capability'
            } finally {
                Remove-Item -LiteralPath $testLogDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Batch installs All 7 applications' -Skip:(-not $isAppInstallerAvailable) {
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
            $res.Count | Should -Be 7
            $appNames = $res | ForEach-Object { $_.AppName }
            $appNames | Should -Contain 'UniKey'
            $appNames | Should -Contain 'UltraVNC'
            $appNames | Should -Contain 'KLiteCodec'
            $appNames | Should -Contain 'Chrome'
            $appNames | Should -Contain 'VCRedistAIO'
            $appNames | Should -Contain 'FoxitReader'
            $appNames | Should -Contain 'Zalo'
        }
    }
}
