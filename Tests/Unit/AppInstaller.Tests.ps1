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
    if (-not (Get-Command 'Add-AppxPackage' -ErrorAction SilentlyContinue)) {
        function global:Add-AppxPackage { param($Path, $DependencyPath, $Register, [switch]$DisableDevelopmentMode) }
    }
    if (-not (Get-Command 'Get-AppxPackage' -ErrorAction SilentlyContinue)) {
        function global:Get-AppxPackage { param($Name) }
    }
}

Describe 'Unit: AppInstaller Module' {

    Context 'Get-ToolkitInstalledApplication' {
        It 'Returns all 8 catalog applications when AppName is All or omitted' -Skip:(-not $isAppInstallerAvailable) {
            $apps = Get-ToolkitInstalledApplication
            $apps | Should -Not -BeNullOrEmpty
            $apps.Count | Should -Be 8
            $appNames = $apps | ForEach-Object { $_.AppName }
            $appNames | Should -Contain 'UniKey'
            $appNames | Should -Contain 'UltraVNC'
            $appNames | Should -Contain 'KLiteCodec'
            $appNames | Should -Contain 'Chrome'
            $appNames | Should -Contain 'VCRedistAIO'
            $appNames | Should -Contain 'FoxitReader'
            $appNames | Should -Contain 'Zalo'
            $appNames | Should -Contain 'WinRAR'
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

        It 'Filters specifically by AppName for WinRAR' -Skip:(-not $isAppInstallerAvailable) {
            $winrar = Get-ToolkitInstalledApplication -AppName 'WinRAR'
            $winrar | Should -Not -BeNullOrEmpty
            $winrar.AppName | Should -Be 'WinRAR'
            $winrar.DisplayName | Should -Be 'WinRAR'
        }

        It 'Detects WinRAR installed status and version when candidate path exists' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $LiteralPath -like '*WinRAR.exe' }
            Mock Get-Item {
                return [PSCustomObject]@{
                    VersionInfo = [PSCustomObject]@{ ProductVersion = '7.01.0' }
                }
            } -ParameterFilter { $LiteralPath -like '*WinRAR.exe' }

            $res = Get-ToolkitInstalledApplication -AppName 'WinRAR'
            $res.Installed | Should -BeTrue
            $res.ExecutablePath | Should -Match 'WinRAR\.exe$'
            $res.Version | Should -Be '7.01.0'
        }

        It 'Detects WinRAR installed status and version from uninstall registry' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $false }
            Mock Get-ItemProperty {
                return [PSCustomObject]@{
                    DisplayName     = 'WinRAR 7.01 (64-bit)'
                    DisplayVersion  = '7.01.0'
                    InstallLocation = 'C:\Program Files\WinRAR'
                    PSChildName     = 'WinRAR archiver'
                }
            } -ParameterFilter { $Path -like 'HKLM:\*' }

            $res = Get-ToolkitInstalledApplication -AppName 'WinRAR'
            $res.Installed | Should -BeTrue
            $res.Version | Should -Be '7.01.0'
            $res.ExecutablePath | Should -Be 'C:\Program Files\WinRAR'
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

        It 'Detects Zalo version authoritatively from user uninstall registry DisplayVersion' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $LiteralPath -like '*Zalo.exe' }
            Mock Get-Item {
                return [PSCustomObject]@{
                    VersionInfo = [PSCustomObject]@{ ProductVersion = '1.0.0' }
                }
            } -ParameterFilter { $LiteralPath -like '*Zalo.exe' }
            Mock Get-ItemProperty {
                return [PSCustomObject]@{
                    DisplayName    = 'Zalo'
                    DisplayVersion = '26.10.10'
                    PSChildName    = 'Zalo'
                }
            } -ParameterFilter { $Path -like 'HKCU:\*' }

            $res = Get-ToolkitInstalledApplication -AppName 'Zalo'
            $res.Installed | Should -BeTrue
            $res.Version | Should -Be '26.10.10'
        }

        It 'Detects Zalo version from FileVersion metadata when ProductVersion is empty' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $LiteralPath -like '*Zalo.exe' }
            Mock Get-Item {
                return [PSCustomObject]@{
                    VersionInfo = [PSCustomObject]@{
                        ProductVersion = $null
                        FileVersion    = '24.10.1.0'
                    }
                }
            } -ParameterFilter { $LiteralPath -like '*Zalo.exe' }

            $res = Get-ToolkitInstalledApplication -AppName 'Zalo'
            $res.Installed | Should -BeTrue
            $res.Version | Should -Be '24.10.1.0'
        }

        It 'Detects Zalo version from active version-specific subdirectory when executable has no version' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $LiteralPath -like '*Zalo.exe' -or $LiteralPath -like '*Programs*Zalo*' }
            Mock Get-Item {
                return [PSCustomObject]@{
                    VersionInfo = [PSCustomObject]@{ ProductVersion = $null; FileVersion = $null }
                }
            }
            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{
                        Name          = 'Zalo-24.10.1'
                        FullName      = 'C:\Users\User\AppData\Local\Programs\Zalo\Zalo-24.10.1'
                        LastWriteTime = [DateTime]::UtcNow
                    }
                )
            }

            $res = Get-ToolkitInstalledApplication -AppName 'Zalo'
            $res.Installed | Should -BeTrue
            $res.Version | Should -Be '24.10.1'
        }

        It 'Detects Zalo from machine uninstall registry when executable is not present on disk' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $false }
            Mock Get-ItemProperty {
                return [PSCustomObject]@{
                    DisplayName     = 'Zalo PC'
                    DisplayVersion  = '24.10.1'
                    InstallLocation = 'C:\Program Files\Zalo'
                    PSChildName     = 'Zalo'
                }
            } -ParameterFilter { $Path -like 'HKLM:\*' }

            $res = Get-ToolkitInstalledApplication -AppName 'Zalo'
            $res.Installed | Should -BeTrue
            $res.Version | Should -Be '24.10.1'
            $res.ExecutablePath | Should -Be 'C:\Program Files\Zalo'
        }

        It 'Picks Zalo version from active version-specific subdirectory over launcher stub version' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $LiteralPath -like '*Zalo*' }
            Mock Get-Item {
                if ($LiteralPath -like '*Zalo-24.10.1*') {
                    return [PSCustomObject]@{ VersionInfo = [PSCustomObject]@{ ProductVersion = '24.10.1' } }
                }
                return [PSCustomObject]@{ VersionInfo = [PSCustomObject]@{ ProductVersion = '1.0.0' } }
            }
            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{
                        Name          = 'Zalo-24.10.1'
                        FullName      = 'C:\Users\User\AppData\Local\Programs\Zalo\Zalo-24.10.1'
                        LastWriteTime = [DateTime]::UtcNow
                    }
                )
            }
            Mock Get-ItemProperty { return $null }

            $res = Get-ToolkitInstalledApplication -AppName 'Zalo'
            $res.Version | Should -Be '24.10.1'
        }

        It 'Selects highest semantic version directory when multiple Zalo version folders exist regardless of timestamp' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $LiteralPath -like '*Zalo*' }
            Mock Get-Item {
                if ($LiteralPath -like '*Zalo-24.10.1*') {
                    return [PSCustomObject]@{ VersionInfo = [PSCustomObject]@{ ProductVersion = '24.10.1' } }
                }
                if ($LiteralPath -like '*Zalo-24.9.2*') {
                    return [PSCustomObject]@{ VersionInfo = [PSCustomObject]@{ ProductVersion = '24.9.2' } }
                }
                return [PSCustomObject]@{ VersionInfo = [PSCustomObject]@{ ProductVersion = $null } }
            }
            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{
                        Name          = 'Zalo-24.9.2'
                        FullName      = 'C:\Users\User\AppData\Local\Programs\Zalo\Zalo-24.9.2'
                        LastWriteTime = (Get-Date).AddDays(1)
                    },
                    [PSCustomObject]@{
                        Name          = 'Zalo-24.10.1'
                        FullName      = 'C:\Users\User\AppData\Local\Programs\Zalo\Zalo-24.10.1'
                        LastWriteTime = (Get-Date).AddDays(-5)
                    }
                )
            }
            Mock Get-ItemProperty { return $null }

            $res = Get-ToolkitInstalledApplication -AppName 'Zalo'
            $res.Version | Should -Be '24.10.1'
        }

        It 'Checks machine uninstall registry when user uninstall key has empty DisplayVersion' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $false }
            Mock Get-ItemProperty {
                if ($Path -like 'HKCU:\*') {
                    return [PSCustomObject]@{
                        DisplayName    = 'Zalo'
                        DisplayVersion = $null
                        PSChildName    = 'Zalo'
                    }
                }
                if ($Path -like 'HKLM:\*') {
                    return [PSCustomObject]@{
                        DisplayName     = 'Zalo'
                        DisplayVersion  = '24.10.1'
                        InstallLocation = 'C:\Program Files\Zalo'
                        PSChildName     = 'Zalo'
                    }
                }
                return $null
            }

            $res = Get-ToolkitInstalledApplication -AppName 'Zalo'
            $res.Version | Should -Be '24.10.1'
        }

        It 'Extracts version from directory name when executable metadata is 0.0.0.0' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $LiteralPath -like '*Zalo*' }
            Mock Get-Item {
                return [PSCustomObject]@{
                    VersionInfo = [PSCustomObject]@{ ProductVersion = '0.0.0.0'; FileVersion = '0.0.0.0' }
                }
            }
            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{
                        Name          = 'Zalo-24.10.1'
                        FullName      = 'C:\Users\User\AppData\Local\Programs\Zalo\Zalo-24.10.1'
                        LastWriteTime = [DateTime]::UtcNow
                    }
                )
            }
            Mock Get-ItemProperty { return $null }

            $res = Get-ToolkitInstalledApplication -AppName 'Zalo'
            $res.Version | Should -Be '24.10.1'
        }

        It 'Does not report Zalo as installed if orphaned registry key has no version, location, or disk files' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $false }
            Mock Get-ItemProperty {
                return [PSCustomObject]@{
                    DisplayName     = 'Zalo'
                    DisplayVersion  = $null
                    InstallLocation = $null
                    DisplayIcon     = $null
                    PSChildName     = 'Zalo'
                }
            }

            $res = Get-ToolkitInstalledApplication -AppName 'Zalo'
            $res.Installed | Should -BeFalse
        }

        It 'Does not downgrade active subdirectory version with outdated registry version' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $LiteralPath -like '*Zalo*' }
            Mock Get-Item {
                if ($LiteralPath -like '*Zalo-24.10.1*') {
                    return [PSCustomObject]@{ VersionInfo = [PSCustomObject]@{ ProductVersion = '24.10.1' } }
                }
                return [PSCustomObject]@{ VersionInfo = [PSCustomObject]@{ ProductVersion = '1.0.0' } }
            }
            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{
                        Name          = 'Zalo-24.10.1'
                        FullName      = 'C:\Users\User\AppData\Local\Programs\Zalo\Zalo-24.10.1'
                        LastWriteTime = [DateTime]::UtcNow
                    }
                )
            }
            Mock Get-ItemProperty {
                return [PSCustomObject]@{
                    DisplayName    = 'Zalo'
                    DisplayVersion = '24.5.1'
                    PSChildName    = 'Zalo'
                }
            }

            $res = Get-ToolkitInstalledApplication -AppName 'Zalo'
            $res.Version | Should -Be '24.10.1'
        }

        It 'Picks higher version across hives when HKCU is older than HKLM' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $false }
            Mock Get-ItemProperty {
                if ($Path -like 'HKCU:\*') {
                    return [PSCustomObject]@{
                        DisplayName    = 'Zalo'
                        DisplayVersion = '24.5.1'
                        PSChildName    = 'Zalo'
                    }
                }
                if ($Path -like 'HKLM:\*') {
                    return [PSCustomObject]@{
                        DisplayName     = 'Zalo'
                        DisplayVersion  = '24.10.1'
                        InstallLocation = 'C:\Program Files\Zalo'
                        PSChildName     = 'Zalo'
                    }
                }
                return $null
            }

            $res = Get-ToolkitInstalledApplication -AppName 'Zalo'
            $res.Version | Should -Be '24.10.1'
        }

        It 'Prefers primary Zalo key and higher version when multiple registry keys exist in same hive' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $false }
            Mock Get-ItemProperty {
                return @(
                    [PSCustomObject]@{
                        DisplayName    = 'Zalo Crash Reporter'
                        DisplayVersion = '1.0.0'
                        PSChildName    = 'ZaloCrash'
                    },
                    [PSCustomObject]@{
                        DisplayName     = 'Zalo'
                        DisplayVersion  = '24.10.1'
                        InstallLocation = 'C:\Program Files\Zalo'
                        PSChildName     = 'Zalo'
                    }
                )
            } -ParameterFilter { $Path -like 'HKCU:\*' }

            $res = Get-ToolkitInstalledApplication -AppName 'Zalo'
            $res.Version | Should -Be '24.10.1'
            $res.DisplayName | Should -Be 'Zalo'
        }

        It 'Extracts FileVersion when ProductVersion is 0.0.0.0 on candidate executable' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $LiteralPath -like '*Zalo*' }
            Mock Get-Item {
                return [PSCustomObject]@{
                    VersionInfo = [PSCustomObject]@{ ProductVersion = '0.0.0.0'; FileVersion = '24.10.1' }
                }
            } -ParameterFilter { $LiteralPath -like '*Zalo*' }
            Mock Get-ChildItem { return @() }
            Mock Get-ItemProperty { return $null }

            $res = Get-ToolkitInstalledApplication -AppName 'Zalo'
            $res.Version | Should -Be '24.10.1'
        }

        It 'Picks primary application entry over helper or crash reporter when neither has DisplayVersion' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $false }
            Mock Get-ItemProperty {
                return @(
                    [PSCustomObject]@{
                        DisplayName    = 'Zalo Crash Reporter'
                        DisplayVersion = $null
                        PSChildName    = 'ZaloCrash'
                    },
                    [PSCustomObject]@{
                        DisplayName     = 'Zalo'
                        DisplayVersion  = $null
                        InstallLocation = 'C:\Program Files\Zalo'
                        PSChildName     = 'Zalo'
                    }
                )
            }

            $res = Get-ToolkitInstalledApplication -AppName 'Zalo'
            $res.ExecutablePath | Should -Be 'C:\Program Files\Zalo'
            $res.Installed | Should -BeTrue
        }

        It 'Resolves executable when InstallLocation in registry has surrounding quotes' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $LiteralPath -like '*Zalo.exe' }
            Mock Get-ItemProperty {
                return [PSCustomObject]@{
                    DisplayName     = 'Zalo'
                    DisplayVersion  = '24.10.1'
                    InstallLocation = '"C:\Program Files\Zalo"'
                    PSChildName     = 'Zalo'
                }
            }

            $res = Get-ToolkitInstalledApplication -AppName 'Zalo'
            ($res.ExecutablePath -replace '[\\/]', '\') | Should -Be 'C:\Program Files\Zalo\Zalo.exe'
        }

        It 'Compares version with 64-bit timestamp build number without integer overflow' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $false }
            Mock Get-ItemProperty {
                if ($Path -like 'HKCU:\*') {
                    return [PSCustomObject]@{
                        DisplayName    = 'Zalo'
                        DisplayVersion = '24.10.202610091230'
                        PSChildName    = 'Zalo'
                    }
                }
                if ($Path -like 'HKLM:\*') {
                    return [PSCustomObject]@{
                        DisplayName    = 'Zalo'
                        DisplayVersion = '24.10.202610091234'
                        PSChildName    = 'Zalo'
                    }
                }
                return $null
            }

            $res = Get-ToolkitInstalledApplication -AppName 'Zalo'
            $res.Version | Should -Be '24.10.202610091234'
        }

        It 'Extracts clean semantic version from active directory with trailing non-numeric suffix' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $true } -ParameterFilter { $LiteralPath -like '*Zalo*' }
            Mock Get-Item {
                return [PSCustomObject]@{
                    VersionInfo = [PSCustomObject]@{ ProductVersion = '0.0.0.0'; FileVersion = '0.0.0.0' }
                }
            }
            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{
                        Name          = 'Zalo-24.10.1-x64'
                        FullName      = 'C:\Users\User\AppData\Local\Programs\Zalo\Zalo-24.10.1-x64'
                        LastWriteTime = [DateTime]::UtcNow
                    }
                )
            }
            Mock Get-ItemProperty { return $null }

            $res = Get-ToolkitInstalledApplication -AppName 'Zalo'
            $res.Version | Should -Be '24.10.1'
        }

        It 'Queries multiple applications when AppName array is provided' -Skip:(-not $isAppInstallerAvailable) {
            $res = Get-ToolkitInstalledApplication -AppName 'Chrome', 'Zalo'
            $res.Count | Should -Be 2
            $names = $res | ForEach-Object { $_.AppName }
            $names | Should -Contain 'Chrome'
            $names | Should -Contain 'Zalo'
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

        It 'Creates desktop shortcut for WinRAR' -Skip:(-not $isAppInstallerAvailable) {
            $mockWinRAR = Join-Path $script:tempDesktop 'WinRAR.exe'
            Set-Content -Path $mockWinRAR -Value 'MOCK_BIN' -Encoding UTF8

            $res = New-ToolkitDesktopShortcut -TargetExecutable $mockWinRAR -ShortcutName 'WinRAR.lnk' -DesktopDirectory $script:tempDesktop
            $res | Should -Not -BeNullOrEmpty
            $res.Created | Should -BeTrue
            Test-Path (Join-Path $script:tempDesktop 'WinRAR.lnk') | Should -BeTrue
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

        It 'Gracefully falls back to HKCU when HKLM write encounters permission denial' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Path { return $true }
            Mock Get-ItemProperty { return $null }
            Mock Set-ItemProperty {
                param($Path, $Name, $Value)
                if ($Path -like 'HKLM:*') {
                    throw "Access to registry key HKLM is denied."
                }
                return $null
            }

            $res = Set-ToolkitChromeExtensionPolicy
            $res.Configured | Should -BeTrue
            $res.RegistryPaths | Should -Contain 'HKCU:\Software\Policies\Google\Chrome\ExtensionInstallForcelist'
            $res.RegistryPaths | Should -Not -Contain 'HKLM:\Software\Policies\Google\Chrome\ExtensionInstallForcelist'
        }
    }

    Context 'Install-ToolkitApplication' {
        BeforeEach {
            Mock Repair-ToolkitWinget {
                return [PSCustomObject]@{
                    Success      = $true
                    Healthy      = $true
                    ActionsTaken = @('Diagnose and repair package manager')
                    ErrorMessage = $null
                }
            }
        }

        It 'Fails fast if internet connectivity pre-flight check fails' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $false }

            { Install-ToolkitApplication -AppName 'Chrome' } | Should -Throw '*Internet connectivity is required*'
        }

        It 'Fails fast and rejects installation on 32-bit operating systems' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-Is64BitOperatingSystem { return $false }

            { Install-ToolkitApplication -AppName 'WinRAR' } | Should -Throw '*Only 64-bit Windows operating systems are supported*'
        }

        It 'Transparently invokes Repair-ToolkitWinget when package manager is unhealthy during installation' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Get-ToolkitWingetStatus {
                return [PSCustomObject]@{ Available = $true; Healthy = $false; SourcesHealthy = $false }
            }
            $script:repairInvoked = $false
            Mock Repair-ToolkitWinget {
                $script:repairInvoked = $true
                return [PSCustomObject]@{ Success = $true; Healthy = $true; ActionsTaken = @('Diagnose and repair') }
            }
            Mock Get-Command {
                param($Name)
                if ($Name -in @('winget', 'Get-ToolkitWingetStatus', 'Repair-ToolkitWinget')) {
                    return [PSCustomObject]@{ Name = $Name }
                }
                return $null
            }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            $script:tCheckCount = 0
            Mock Get-ToolkitInstalledApplication {
                $script:tCheckCount++
                if ($script:tCheckCount -eq 1) {
                    return [PSCustomObject]@{ AppName = 'WinRAR'; DisplayName = 'WinRAR'; Installed = $false; ExecutablePath = $null; Version = $null }
                }
                return [PSCustomObject]@{ AppName = 'WinRAR'; DisplayName = 'WinRAR'; Installed = $true; ExecutablePath = 'C:\Program Files\WinRAR\WinRAR.exe'; Version = '7.01.0' }
            }
            Mock New-ToolkitDesktopShortcut { return [PSCustomObject]@{ Created = $true } }

            $res = Install-ToolkitApplication -AppName 'WinRAR'
            $script:repairInvoked | Should -BeTrue
            $res.Installed | Should -BeTrue
        }

        It 'Installs WinRAR silently with desktop shortcut and returns structured result' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Get-Command {
                param($Name)
                if ($Name -eq 'winget') { return [PSCustomObject]@{ Name = 'winget' } }
                return $null
            }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            $script:winrarCheckCount = 0
            Mock Get-ToolkitInstalledApplication {
                $script:winrarCheckCount++
                if ($script:winrarCheckCount -eq 1) {
                    return [PSCustomObject]@{ AppName = 'WinRAR'; DisplayName = 'WinRAR'; Installed = $false; ExecutablePath = $null; Version = $null }
                }
                return [PSCustomObject]@{ AppName = 'WinRAR'; DisplayName = 'WinRAR'; Installed = $true; ExecutablePath = 'C:\Program Files\WinRAR\WinRAR.exe'; Version = '7.01.0' }
            }
            Mock New-ToolkitDesktopShortcut {
                return [PSCustomObject]@{ Created = $true; ShortcutPath = 'C:\Users\User\Desktop\WinRAR.lnk' }
            }

            $res = Install-ToolkitApplication -AppName 'WinRAR' -CreateShortcut
            $res | Should -Not -BeNullOrEmpty
            $res.AppName | Should -Be 'WinRAR'
            $res.DisplayName | Should -Be 'WinRAR'
            $res.Installed | Should -BeTrue
            $res.ShortcutCreated | Should -BeTrue
            $res.Status | Should -Be 'OK'
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

        It 'Ensures desktop shortcut is created for already-installed application when -CreateShortcut is specified without -Force' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $true }
            $script:startProcessInvoked = $false
            Mock Start-Process {
                $script:startProcessInvoked = $true
                return [PSCustomObject]@{ ExitCode = 0 }
            }
            Mock Get-ToolkitInstalledApplication {
                return [PSCustomObject]@{
                    AppName        = 'UniKey'
                    DisplayName    = 'UniKey Vietnamese Input Method'
                    Installed      = $true
                    ExecutablePath = 'C:\Program Files\UniKey\UniKeyNT.exe'
                    Version        = '4.6'
                }
            }
            $script:shortcutCreatedWithTarget = $null
            Mock New-ToolkitDesktopShortcut {
                param($TargetExecutable, $ShortcutName, $Force)
                $script:shortcutCreatedWithTarget = $TargetExecutable
                return [PSCustomObject]@{ Created = $true; ShortcutPath = 'C:\Users\User\Desktop\UniKey.lnk' }
            }

            $res = Install-ToolkitApplication -AppName 'UniKey' -CreateShortcut
            $res | Should -Not -BeNullOrEmpty
            $res.AppName | Should -Be 'UniKey'
            $res.Installed | Should -BeTrue
            $res.ShortcutCreated | Should -BeTrue
            $res.Status | Should -Be 'OK'
            $script:startProcessInvoked | Should -BeFalse
            $script:shortcutCreatedWithTarget | Should -Be 'C:\Program Files\UniKey\UniKeyNT.exe'
        }

        It 'Deploys Chrome extensions when Chrome is already installed' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Get-ToolkitInstalledApplication {
                return [PSCustomObject]@{
                    AppName        = 'Chrome'
                    DisplayName    = 'Google Chrome'
                    Installed      = $true
                    ExecutablePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
                    Version        = '120.0.0.0'
                }
            }
            Mock New-ToolkitDesktopShortcut { return [PSCustomObject]@{ Created = $true } }
            Mock Set-ToolkitDefaultApplication { return @([PSCustomObject]@{ DefaultSet = $true }) }
            $script:installedChromePolicyCalled = $false
            Mock Set-ToolkitChromeExtensionPolicy {
                $script:installedChromePolicyCalled = $true
                return [PSCustomObject]@{ Configured = $true }
            }

            $res = Install-ToolkitApplication -AppName 'Chrome'
            $res.Installed | Should -BeTrue
            $script:installedChromePolicyCalled | Should -BeTrue
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
            Mock Get-Command {
                param($Name)
                if ($Name -eq 'winget') { return [PSCustomObject]@{ Name = 'winget' } }
                return $null
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

        It 'Sequences VCRedistAIO first when installing custom array of applications' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            $script:customOrder = [System.Collections.Generic.List[string]]::new()
            Mock Get-ToolkitInstalledApplication {
                param($AppName)
                $script:customOrder.Add($AppName)
                return [PSCustomObject]@{
                    AppName        = $AppName
                    DisplayName    = $AppName
                    Installed      = $true
                    ExecutablePath = "C:\Tools\$AppName\$AppName.exe"
                    Version        = '1.0'
                }
            }

            $res = Install-ToolkitApplication -AppName 'Chrome', 'VCRedistAIO'
            $res.Count | Should -Be 2
            $script:customOrder[0] | Should -Be 'VCRedistAIO'
            $script:customOrder[1] | Should -Be 'Chrome'
        }

        It 'Falls back to alternate Winget ID when primary ID returns non-zero exit code' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Get-Command {
                param($Name)
                if ($Name -eq 'winget') { return [PSCustomObject]@{ Name = 'winget' } }
                return $null
            }
            $script:attemptedWingetArgs = [System.Collections.Generic.List[string]]::new()
            Mock Start-Process {
                param($FilePath, $ArgumentList)
                if ($FilePath -eq 'winget') {
                    $script:attemptedWingetArgs.Add($ArgumentList)
                    if ($ArgumentList -like '*--id VNG.Zalo*') {
                        return [PSCustomObject]@{ ExitCode = 1 } # Primary ID fails
                    }
                    if ($ArgumentList -like '*--id VNGCorp.Zalo*') {
                        return [PSCustomObject]@{ ExitCode = 0 } # Alternate ID succeeds
                    }
                }
                return [PSCustomObject]@{ ExitCode = 0 }
            }
            $script:zaloCheck = 0
            Mock Get-ToolkitInstalledApplication {
                param($AppName)
                $script:zaloCheck++
                if ($script:zaloCheck -eq 1) {
                    return [PSCustomObject]@{ AppName = 'Zalo'; DisplayName = 'Zalo'; Installed = $false; ExecutablePath = $null }
                }
                return [PSCustomObject]@{ AppName = 'Zalo'; DisplayName = 'Zalo'; Installed = $true; ExecutablePath = 'C:\Zalo\Zalo.exe' }
            }

            $res = Install-ToolkitApplication -AppName 'Zalo' -Force
            $res.Installed | Should -BeTrue
            $script:attemptedWingetArgs.Count | Should -BeGreaterThan 1
            ($script:attemptedWingetArgs | Where-Object { $_ -like '*VNG.Zalo*' }) | Should -Not -BeNullOrEmpty
            ($script:attemptedWingetArgs | Where-Object { $_ -like '*VNGCorp.Zalo*' }) | Should -Not -BeNullOrEmpty
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
                    Version        = '4.6.0.0'
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

        It 'Suppresses DEBUG log messages from console output while recording to daily log file' -Skip:(-not $isAppInstallerAvailable) {
            $testLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ("IToolkit_LogTest_" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $testLogDir -Force | Out-Null
            try {
                Mock Write-Host {}
                Write-AppInstallerLog -Message "Diagnostic trace details" -Level 'DEBUG' -Component 'AppInstaller' -LogDirectory $testLogDir
                Assert-MockCalled Write-Host -Times 0 -Scope It
                $logFiles = Get-ChildItem -Path $testLogDir -Filter "*.log"
                $logFiles.Count | Should -BeGreaterThan 0
                $content = Get-Content -LiteralPath $logFiles[0].FullName -Raw
                $content | Should -Match '\[DEBUG\] \[AppInstaller\] Diagnostic trace details'
            } finally {
                Remove-Item -LiteralPath $testLogDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Batch installs All 8 applications' -Skip:(-not $isAppInstallerAvailable) {
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
            $res.Count | Should -Be 8
            $appNames = $res | ForEach-Object { $_.AppName }
            $appNames | Should -Contain 'UniKey'
            $appNames | Should -Contain 'UltraVNC'
            $appNames | Should -Contain 'KLiteCodec'
            $appNames | Should -Contain 'Chrome'
            $appNames | Should -Contain 'VCRedistAIO'
            $appNames | Should -Contain 'FoxitReader'
            $appNames | Should -Contain 'Zalo'
            $appNames | Should -Contain 'WinRAR'
        }

        It 'Falls back to official zip archive download and extraction for UniKey when winget fails' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Get-Command -ParameterFilter { $Name -eq 'winget' } { return [PSCustomObject]@{ Name = 'winget' } }
            Mock Resolve-ToolkitApplicationDownloadUrl {
                return [PSCustomObject]@{
                    AppName              = 'UniKey'
                    PrimaryUrl           = 'https://www.unikey.org/assets/release/unikey46RC2-230919-win64.zip'
                    FallbackUrls         = @()
                    ResolvedDynamically  = $false
                    DetectedArchitecture = 'win64'
                }
            }
            # Winget fails
            Mock Start-Process {
                param($FilePath)
                if ($FilePath -eq 'winget') { return [PSCustomObject]@{ ExitCode = 1 } }
                return [PSCustomObject]@{ ExitCode = 0 }
            }
            # Web request writes a valid temporary test zip containing UniKeyNT.exe
            Mock Invoke-WebRequest {
                param($Uri, $OutFile)
                $tempScratch = Join-Path ([System.IO.Path]::GetTempPath()) ("IToolkit_UniKeyTest_" + [System.Guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $tempScratch -Force | Out-Null
                $mockExe = Join-Path $tempScratch 'UniKeyNT.exe'
                Set-Content -LiteralPath $mockExe -Value 'MOCK_UNIKEY_BINARY' -Encoding UTF8
                Compress-Archive -Path $mockExe -DestinationPath $OutFile -Force
                Remove-Item -LiteralPath $tempScratch -Recurse -Force -ErrorAction SilentlyContinue
            }
            $script:installedCounter = 0
            Mock Get-ToolkitInstalledApplication {
                param($AppName)
                $script:installedCounter++
                if ($script:installedCounter -eq 1) {
                    return [PSCustomObject]@{ AppName = $AppName; DisplayName = 'UniKey Vietnamese Input Method'; Installed = $false; ExecutablePath = $null }
                }
                return [PSCustomObject]@{
                    AppName        = $AppName
                    DisplayName    = 'UniKey Vietnamese Input Method'
                    Installed      = $true
                    ExecutablePath = 'C:\Program Files\UniKey\UniKeyNT.exe'
                    Version        = '4.6.0.0'
                }
            }
            Mock New-ToolkitDesktopShortcut {
                param($TargetExecutable, $ShortcutName)
                return [PSCustomObject]@{ Created = $true; ShortcutPath = "C:\Users\User\Desktop\$ShortcutName" }
            }

            $res = Install-ToolkitApplication -AppName 'UniKey' -CreateShortcut -Force
            $res | Should -Not -BeNullOrEmpty
            $res.AppName | Should -Be 'UniKey'
            $res.Installed | Should -BeTrue
            $res.ShortcutCreated | Should -BeTrue
            $res.DefaultConfigured | Should -BeFalse
            $res.Status | Should -Be 'OK'
        }

        It 'Never configures default applications or Chrome policies when installing UniKey' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Get-Command -ParameterFilter { $Name -eq 'winget' } { return [PSCustomObject]@{ Name = 'winget' } }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            Mock Get-ToolkitInstalledApplication {
                return [PSCustomObject]@{
                    AppName        = 'UniKey'
                    DisplayName    = 'UniKey Vietnamese Input Method'
                    Installed      = $true
                    ExecutablePath = 'C:\Program Files\UniKey\UniKeyNT.exe'
                    Version        = '4.6.0.0'
                }
            }
            Mock New-ToolkitDesktopShortcut {
                param($TargetExecutable, $ShortcutName)
                return [PSCustomObject]@{ Created = $true; ShortcutPath = "C:\Users\User\Desktop\$ShortcutName" }
            }
            Mock Set-ToolkitDefaultApplication { }
            Mock Set-ToolkitChromeExtensionPolicy { }

            $res = Install-ToolkitApplication -AppName 'UniKey' -Force

            $res | Should -Not -BeNullOrEmpty
            $res.AppName | Should -Be 'UniKey'
            $res.Installed | Should -BeTrue
            $res.DefaultConfigured | Should -BeFalse
            Assert-MockCalled -CommandName 'Set-ToolkitDefaultApplication' -Times 0
            Assert-MockCalled -CommandName 'Set-ToolkitChromeExtensionPolicy' -Times 0
        }

        It 'Resolve-ToolkitApplicationDownloadUrl resolves UniKey with architecture matching and fallback' -Skip:(-not $isAppInstallerAvailable) {
            $x64Res = Resolve-ToolkitApplicationDownloadUrl -AppName 'UniKey' -Architecture 'win64'
            $x64Res | Should -Not -BeNullOrEmpty
            $x64Res.AppName | Should -Be 'UniKey'
            $x64Res.PrimaryUrl | Should -Match 'unikey.*-win64\.zip$'
            $x64Res.DetectedArchitecture | Should -Be 'win64'

            $armRes = Resolve-ToolkitApplicationDownloadUrl -AppName 'UniKey' -Architecture 'arm64'
            $armRes.PrimaryUrl | Should -Match 'unikey.*-arm64\.zip$'
            $armRes.DetectedArchitecture | Should -Be 'arm64'
        }

        It 'Resolve-ToolkitApplicationDownloadUrl provides resilient fallback endpoints for Zalo' -Skip:(-not $isAppInstallerAvailable) {
            $zaloUrls = Resolve-ToolkitApplicationDownloadUrl -AppName 'Zalo'
            $zaloUrls | Should -Not -BeNullOrEmpty
            $zaloUrls.AppName | Should -Be 'Zalo'
            $zaloUrls.PrimaryUrl | Should -Match 'ZaloSetup.*\.exe$'
            $zaloUrls.FallbackUrls | Should -Contain 'https://res-zaloapp-aka-jpt.zdn.vn/win/ZaloSetup-26.10.10.exe'
        }

        It 'Resolve-ToolkitApplicationDownloadUrl resolves valid non-null URLs for UltraVNC and KLiteCodec' -Skip:(-not $isAppInstallerAvailable) {
            $uvnc = Resolve-ToolkitApplicationDownloadUrl -AppName 'UltraVNC'
            $uvnc | Should -Not -BeNullOrEmpty
            $uvnc.PrimaryUrl | Should -Not -BeNullOrEmpty
            $uvnc.PrimaryUrl | Should -Match '\.exe$'
            $uvnc.ResolvedDynamically | Should -BeTrue
            $uvnc.FallbackUrls.Count | Should -BeGreaterThan 0

            $klite = 'KLiteCodec' | Resolve-ToolkitApplicationDownloadUrl
            $klite | Should -Not -BeNullOrEmpty
            $klite.PrimaryUrl | Should -Not -BeNullOrEmpty
            $klite.PrimaryUrl | Should -Match '\.exe$'
            $klite.ResolvedDynamically | Should -BeTrue
            $klite.FallbackUrls.Count | Should -BeGreaterThan 0
        }

        It 'Resolve-ToolkitApplicationDownloadUrl resolves UltraVNC targeting x64 installer' -Skip:(-not $isAppInstallerAvailable) {
            $vnc64 = Resolve-ToolkitApplicationDownloadUrl -AppName 'UltraVNC' -Architecture 'x64'
            $vnc64.PrimaryUrl | Should -Match 'X64_Setup\.exe$'
            $vnc64.FallbackUrls | Should -Contain 'https://github.com/ultravnc/UltraVNC/releases/download/1.5.0.0/UltraVNC_1_5_0_0_X64_Setup.exe'

            $vncWin64 = Resolve-ToolkitApplicationDownloadUrl -AppName 'UltraVNC' -Architecture 'win64'
            $vncWin64.PrimaryUrl | Should -Match 'X64_Setup\.exe$'

            $vncDefault = Resolve-ToolkitApplicationDownloadUrl -AppName 'UltraVNC'
            $vncDefault.PrimaryUrl | Should -Match 'X64_Setup\.exe$'
        }

        It 'Resolve-ToolkitApplicationDownloadUrl resolves WinRAR x64 download URL' -Skip:(-not $isAppInstallerAvailable) {
            $winrar = Resolve-ToolkitApplicationDownloadUrl -AppName 'WinRAR'
            $winrar | Should -Not -BeNullOrEmpty
            $winrar.AppName | Should -Be 'WinRAR'
            $winrar.PrimaryUrl | Should -Match 'winrar-x64-.*\.exe$'
            $winrar.ResolvedDynamically | Should -BeTrue
            $winrar.FallbackUrls.Count | Should -BeGreaterThan 0
        }

        It 'Verifies all 8 catalog applications resolve valid installer or archive URLs ending in exe, zip, or msi' -Skip:(-not $isAppInstallerAvailable) {
            $allApps = @('UniKey', 'Zalo', 'Chrome', 'FoxitReader', 'VCRedistAIO', 'UltraVNC', 'KLiteCodec', 'WinRAR')
            foreach ($app in $allApps) {
                $resolved = Resolve-ToolkitApplicationDownloadUrl -AppName $app
                $resolved | Should -Not -BeNullOrEmpty
                $resolved.PrimaryUrl | Should -Not -BeNullOrEmpty
                $resolved.PrimaryUrl | Should -Match '\.(exe|zip|msi)(\?.*)?$'
            }
        }

        It 'Falls back to direct URL download installer for UltraVNC when winget is unavailable' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Get-Command {
                param($Name)
                if ($Name -eq 'winget') { return $null }
                return $null
            }
            $script:webRequestUri = $null
            Mock Invoke-WebRequest {
                param($Uri, $OutFile)
                $script:webRequestUri = $Uri
                Set-Content -LiteralPath $OutFile -Value 'MOCK_EXE'
            }
            Mock Start-Process {
                param($FilePath, $ArgumentList)
                return [PSCustomObject]@{ ExitCode = 0 }
            }
            $script:checkNum = 0
            Mock Get-ToolkitInstalledApplication {
                param($AppName)
                $script:checkNum++
                if ($script:checkNum -eq 1) {
                    return [PSCustomObject]@{ AppName = $AppName; DisplayName = $AppName; Installed = $false; ExecutablePath = $null }
                }
                return [PSCustomObject]@{ AppName = $AppName; DisplayName = $AppName; Installed = $true; ExecutablePath = 'C:\Tools\UltraVNC\winvnc.exe' }
            }

            $res = Install-ToolkitApplication -AppName 'UltraVNC' -Force
            $res.Installed | Should -BeTrue
            $res.Status | Should -Be 'OK'
            $script:webRequestUri | Should -Match 'UltraVNC.*\.exe$'
        }

        It 'Install-ToolkitApplication handles direct download failure gracefully when winget is unavailable' -Skip:(-not $isAppInstallerAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Get-Command {
                param($Name)
                if ($Name -eq 'winget') { return $null }
                return $null
            }
            Mock Invoke-WebRequest {
                throw "Network connection timed out"
            }
            Mock Get-ToolkitInstalledApplication {
                param($AppName)
                return [PSCustomObject]@{
                    AppName        = $AppName
                    DisplayName    = 'UltraVNC Remote Support'
                    Installed      = $false
                    ExecutablePath = $null
                }
            }
            $res = Install-ToolkitApplication -AppName 'UltraVNC' -Force
            $res | Should -Not -BeNullOrEmpty
            $res.AppName | Should -Be 'UltraVNC'
            $res.Installed | Should -BeFalse
            $res.Status | Should -Be 'WARN'
        }
    }

    Context 'Get-ToolkitWingetStatus' {
        It 'Returns structured status object when winget is unavailable' -Skip:(-not $isAppInstallerAvailable) {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'winget' }
            Mock Test-Path { return $false }

            $status = Get-ToolkitWingetStatus
            $status | Should -Not -BeNullOrEmpty
            $status.Available | Should -BeFalse
            $status.Healthy | Should -BeFalse
            $status.SourcesHealthy | Should -BeFalse
            $status.Version | Should -BeNullOrEmpty
            $status.ErrorMessage | Should -Match 'not found'
        }

        It 'Detects available winget via App Execution Alias path' -Skip:(-not $isAppInstallerAvailable) {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'winget' }
            Mock Test-Path { return $true } -ParameterFilter { $LiteralPath -like '*winget.exe' }
            Mock Get-Command { return [PSCustomObject]@{ Name = 'winget' } } -ParameterFilter { $Name -eq 'winget' }

            function script:winget {
                param([Parameter(ValueFromRemainingArguments = $true)]$args)
                if ($args -contains '--version') { return 'v1.9.25200' }
                if ($args -contains 'source') { return 'Name   Argument' }
                return ''
            }

            $status = Get-ToolkitWingetStatus
            $status.Available | Should -BeTrue
            $status.Healthy | Should -BeTrue
            $status.SourcesHealthy | Should -BeTrue
            $status.Version | Should -Match '1\.9\.25200'
        }

        It 'Detects unhealthy sources when winget source list fails' -Skip:(-not $isAppInstallerAvailable) {
            Mock Get-Command { return [PSCustomObject]@{ Name = 'winget' } } -ParameterFilter { $Name -eq 'winget' }

            function script:winget {
                param([Parameter(ValueFromRemainingArguments = $true)]$args)
                if ($args -contains '--version') { return 'v1.9.25200' }
                if ($args -contains 'source') { throw "Sources corrupted" }
                return ''
            }

            $status = Get-ToolkitWingetStatus
            $status.Available | Should -BeTrue
            $status.Healthy | Should -BeFalse
            $status.SourcesHealthy | Should -BeFalse
            $status.ErrorMessage | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Install-ToolkitWingetLatest' {
        It 'Bypasses installation and returns WhatIf status when -WhatIf is passed' -Skip:(-not $isAppInstallerAvailable) {
            $res = Install-ToolkitWingetLatest -WhatIf
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'WhatIf'
        }

        It 'Returns current version without reinstalling when winget is healthy and -Force omitted' -Skip:(-not $isAppInstallerAvailable) {
            Mock Get-ToolkitWingetStatus {
                return [PSCustomObject]@{ Available = $true; Healthy = $true; Version = 'v1.9.25200' }
            }
            $res = Install-ToolkitWingetLatest
            $res.Success | Should -BeTrue
            $res.Version | Should -Be 'v1.9.25200'
            $res.DependenciesInstalled.Count | Should -Be 0
        }

        It 'Downloads dependencies and invokes Add-AppxPackage when bootstrapping' -Skip:(-not $isAppInstallerAvailable) {
            Mock Get-ToolkitWingetStatus {
                return [PSCustomObject]@{ Available = $false; Healthy = $false; Version = $null }
            }
            $script:downloadedUrls = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-WebRequest {
                param($Uri, $OutFile)
                $script:downloadedUrls.Add($Uri)
                Set-Content -LiteralPath $OutFile -Value "MOCK_PKG" -Force
            }
            $script:appxInvoked = $false
            $script:depPathsPassed = $null
            Mock Add-AppxPackage {
                param($Path, $DependencyPath)
                $script:appxInvoked = $true
                $script:depPathsPassed = $DependencyPath
            }

            $res = Install-ToolkitWingetLatest -Force
            $res.Success | Should -BeTrue
            $script:downloadedUrls.Count | Should -BeGreaterThan 0
            $script:appxInvoked | Should -BeTrue
            $res.DependenciesInstalled.Count | Should -BeGreaterThan 0
        }

        It 'Handles bundle download failure gracefully' -Skip:(-not $isAppInstallerAvailable) {
            Mock Get-ToolkitWingetStatus {
                return [PSCustomObject]@{ Available = $false; Healthy = $false; Version = $null }
            }
            Mock Invoke-WebRequest {
                throw "Network download failed"
            }
            $res = Install-ToolkitWingetLatest -Force
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'Failed'
        }
    }

    Context 'Repair-ToolkitWinget' {
        It 'Respects -WhatIf switch and returns WhatIf notice' -Skip:(-not $isAppInstallerAvailable) {
            $res = Repair-ToolkitWinget -WhatIf
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'WhatIf'
        }

        It 'Resets sources via winget source reset --force and repairs alias' -Skip:(-not $isAppInstallerAvailable) {
            $script:statusCall = 0
            Mock Get-ToolkitWingetStatus {
                $script:statusCall++
                if ($script:statusCall -le 2) {
                    return [PSCustomObject]@{ Available = $true; Healthy = $false; SourcesHealthy = $false; Version = 'v1.9' }
                }
                return [PSCustomObject]@{ Available = $true; Healthy = $true; SourcesHealthy = $true; Version = 'v1.9' }
            }
            $script:resetCalled = $false
            Mock Start-Process {
                param($FilePath, $ArgumentList)
                if ($FilePath -eq 'winget' -and $ArgumentList -like '*source reset --force*') {
                    $script:resetCalled = $true
                    return [PSCustomObject]@{ ExitCode = 0 }
                }
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $res = Repair-ToolkitWinget
            $res.Success | Should -BeTrue
            $res.Healthy | Should -BeTrue
            $script:resetCalled | Should -BeTrue
            ($res.ActionsTaken | Where-Object { $_ -like '*source cache*' }) | Should -Not -BeNullOrEmpty
        }

        It 'Re-registers AppX package and reinstalls dependencies when broken' -Skip:(-not $isAppInstallerAvailable) {
            $script:rStatusCall = 0
            Mock Get-ToolkitWingetStatus {
                $script:rStatusCall++
                if ($script:rStatusCall -le 3) {
                    return [PSCustomObject]@{ Available = $false; Healthy = $false; SourcesHealthy = $false; Version = $null }
                }
                return [PSCustomObject]@{ Available = $true; Healthy = $true; SourcesHealthy = $true; Version = 'v1.9.25200' }
            }
            Mock Install-ToolkitWingetLatest {
                return [PSCustomObject]@{ Success = $true; Version = 'v1.9.25200'; DependenciesInstalled = @('VCLibs') }
            }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }

            $res = Repair-ToolkitWinget -Force
            $res.Success | Should -BeTrue
            $res.ActionsTaken.Count | Should -BeGreaterThan 0
        }
    }

    Context 'Install-WingetPackage' {
        It 'Respects -WhatIf switch and returns WhatIf status' -Skip:(-not $isAppInstallerAvailable) {
            $res = Install-WingetPackage -PackageId 'Google.Chrome' -WhatIf
            $res.Installed | Should -BeFalse
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'WhatIf'
        }

        It 'Executes silent winget install with exact flags on exit code 0' -Skip:(-not $isAppInstallerAvailable) {
            $script:passedWingetArgs = $null
            Mock Start-Process {
                param($FilePath, $ArgumentList)
                if ($FilePath -eq 'winget') {
                    $script:passedWingetArgs = $ArgumentList
                    return [PSCustomObject]@{ ExitCode = 0 }
                }
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $res = Install-WingetPackage -PackageId 'Google.Chrome'
            $res.PackageId | Should -Be 'Google.Chrome'
            $res.Installed | Should -BeTrue
            $res.Success | Should -BeTrue
            $script:passedWingetArgs | Should -Match 'install --id Google\.Chrome'
            $script:passedWingetArgs | Should -Match '--exact'
            $script:passedWingetArgs | Should -Match '--silent'
            $script:passedWingetArgs | Should -Match '--accept-package-agreements'
            $script:passedWingetArgs | Should -Match '--accept-source-agreements'
        }

        It 'Returns uninstalled and error message on non-zero exit code' -Skip:(-not $isAppInstallerAvailable) {
            Mock Start-Process {
                param($FilePath, $ArgumentList)
                return [PSCustomObject]@{ ExitCode = 1603 }
            }

            $res = Install-WingetPackage -PackageId 'PhamKimLong.UniKey'
            $res.PackageId | Should -Be 'PhamKimLong.UniKey'
            $res.Installed | Should -BeFalse
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match '1603'
        }
    }

    Context 'Update-WingetPackage' {
        It 'Respects -WhatIf switch and returns WhatIf status' -Skip:(-not $isAppInstallerAvailable) {
            $res = Update-WingetPackage -All -WhatIf
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'WhatIf'
        }

        It 'Executes winget upgrade --all when -All is specified' -Skip:(-not $isAppInstallerAvailable) {
            $script:upgradeArgs = $null
            Mock Start-Process {
                param($FilePath, $ArgumentList)
                if ($FilePath -eq 'winget') {
                    $script:upgradeArgs = $ArgumentList
                    return [PSCustomObject]@{ ExitCode = 0 }
                }
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $res = Update-WingetPackage -All
            $res.Success | Should -BeTrue
            $res.TotalUpgraded | Should -BeGreaterThan 0
            $script:upgradeArgs | Should -Match 'upgrade --all'
            $script:upgradeArgs | Should -Match '--silent'
            $script:upgradeArgs | Should -Match '--accept-package-agreements'
        }

        It 'Executes winget upgrade for individual package when -PackageId is passed' -Skip:(-not $isAppInstallerAvailable) {
            $script:singleUpgradeArgs = $null
            Mock Start-Process {
                param($FilePath, $ArgumentList)
                if ($FilePath -eq 'winget') {
                    $script:singleUpgradeArgs = $ArgumentList
                    return [PSCustomObject]@{ ExitCode = 0 }
                }
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $res = Update-WingetPackage -PackageId 'Google.Chrome'
            $res.Success | Should -BeTrue
            $res.UpgradedPackages | Should -Contain 'Google.Chrome'
            $script:singleUpgradeArgs | Should -Match 'upgrade --id Google\.Chrome'
        }

        It 'Returns non-zero exit code error message gracefully' -Skip:(-not $isAppInstallerAvailable) {
            Mock Start-Process {
                return [PSCustomObject]@{ ExitCode = 2 }
            }

            $res = Update-WingetPackage -All
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'exit code: 2'
        }
    }

    Context 'TUI Submenu AppInstaller Integration' {
        It 'Get-AppInstallerContextInfoLines displays winget health badge when active' -Skip:(-not $isAppInstallerAvailable) {
            Mock Get-ToolkitWingetStatus {
                return [PSCustomObject]@{ Available = $true; Healthy = $true; Version = 'v1.9.25200' }
            }
            $lines = Get-AppInstallerContextInfoLines
            $engineLine = $lines | Where-Object { $_ -like '*Deploy Engine*' }
            $engineLine | Should -Match 'winget \[ACTIVE - v1\.9\.25200\]'
        }

        It 'Get-AppInstallerContextInfoLines displays standalone direct download when winget unavailable' -Skip:(-not $isAppInstallerAvailable) {
            Mock Get-ToolkitWingetStatus {
                return [PSCustomObject]@{ Available = $false; Healthy = $false; Version = $null }
            }
            $lines = Get-AppInstallerContextInfoLines
            $engineLine = $lines | Where-Object { $_ -like '*Deploy Engine*' }
            $engineLine | Should -Match '\[STANDALONE DIRECT DOWNLOAD\]'
        }

        It 'Invoke-ToolkitSubmenuAppInstaller exposes 8, U and removes manual W, B from action catalog' -Skip:(-not $isAppInstallerAvailable) {
            $script:capturedActions = $null
            Mock Show-ToolkitActionCatalog {
                param($Actions, $NavActions, $Title)
                $script:capturedActions = $Actions
            }
            Invoke-ToolkitSubmenuAppInstaller -NonInteractive
            $script:capturedActions | Should -Not -BeNullOrEmpty
            $keys = $script:capturedActions | ForEach-Object { $_.Key }
            $keys | Should -Contain '8'
            $keys | Should -Contain 'U'
            $keys | Should -Not -Contain 'W'
            $keys | Should -Not -Contain 'B'
        }

        It 'Invoke-ToolkitSubmenuAppInstaller dispatches Update-WingetPackage -All on hotkey U' -Skip:(-not $isAppInstallerAvailable) {
            $script:upgradeAllCalled = $false
            Mock Update-WingetPackage {
                param([switch]$All)
                $script:upgradeAllCalled = [bool]$All
                return [PSCustomObject]@{ Success = $true; TotalUpgraded = 3 }
            }
            Mock Wait-UserAcknowledge { }
            $script:uCount = 0
            Mock Read-ToolkitMenuChoice {
                $script:uCount++
                if ($script:uCount -eq 1) { return 'U' }
                return 'Q'
            }

            Invoke-ToolkitSubmenuAppInstaller
            $script:upgradeAllCalled | Should -BeTrue
        }

        It 'Invoke-ToolkitSubmenuAppInstaller dispatches WinRAR installation on hotkey 8' -Skip:(-not $isAppInstallerAvailable) {
            $script:winrarInstalled = $false
            $script:winrarShortcut = $false
            Mock Install-ToolkitApplication {
                param($AppName, $CreateShortcut)
                if ($AppName -eq 'WinRAR') {
                    $script:winrarInstalled = $true
                    $script:winrarShortcut = [bool]$CreateShortcut
                }
                return [PSCustomObject]@{ AppName = $AppName; Installed = $true }
            }
            Mock Wait-UserAcknowledge { }
            $script:keyCount = 0
            Mock Read-ToolkitMenuChoice {
                $script:keyCount++
                if ($script:keyCount -eq 1) { return '8' }
                return 'Q'
            }

            Invoke-ToolkitSubmenuAppInstaller
            $script:winrarInstalled | Should -BeTrue
            $script:winrarShortcut | Should -BeTrue
        }

        It 'Invoke-ToolkitSubmenuAppInstaller rejects manual W hotkey from valid keys and includes standard navigation' -Skip:(-not $isAppInstallerAvailable) {
            $script:capturedValidKeys = $null
            Mock Read-ToolkitMenuChoice {
                param($Prompt, $ValidKeys)
                $script:capturedValidKeys = $ValidKeys
                return 'Q'
            }

            Invoke-ToolkitSubmenuAppInstaller
            $script:capturedValidKeys | Should -Not -Contain 'W'
            $script:capturedValidKeys | Should -Contain 'B'
            $script:capturedValidKeys | Should -Contain '8'
        }
    }
}


