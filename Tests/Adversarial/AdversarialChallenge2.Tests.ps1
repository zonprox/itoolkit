# ==============================================================================
# AdversarialChallenge2.Tests.ps1
# Empirical Adversarial Challenge 2:
# 1. Start-IToolkitMenu option dispatch
# 2. Headless execution of submenus (zero hangs, clean exit code 0)
# 3. Winget fallback to direct download installer
# 4. Winget repair under simulated corruption scenarios
# ==============================================================================

$script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:StartScript = Join-Path $script:ProjectRoot 'Start-IToolkit.ps1'
$script:TuiManifest = Join-Path $script:ProjectRoot 'Modules/TUI/TUI.psd1'
$script:AppInstallerManifest = Join-Path $script:ProjectRoot 'Modules/AppInstaller/AppInstaller.psd1'

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:ProjectRoot = $root
    $script:StartScript = Join-Path $root 'Start-IToolkit.ps1'
    $script:TuiManifest = Join-Path $root 'Modules/TUI/TUI.psd1'
    $script:AppInstallerManifest = Join-Path $root 'Modules/AppInstaller/AppInstaller.psd1'

    # Ensure C: drive alias exists in Linux test environments
    if (-not (Get-PSDrive -Name 'C' -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name 'C' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -ErrorAction SilentlyContinue | Out-Null
    }

    # Import all modules so all toolkit functions (including ExternalTools) are available
    $manifests = Get-ChildItem -Path (Join-Path $root "Modules") -Filter "*.psd1" -Recurse -ErrorAction SilentlyContinue
    if ($manifests) {
        foreach ($m in $manifests) {
            try {
                Import-Module $m.FullName -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Warning "Failed to load module $($m.Name): $_"
            }
        }
    }
    if (-not (Get-Command 'Add-AppxPackage' -ErrorAction SilentlyContinue)) {
        function global:Add-AppxPackage { param($Path, $DependencyPath, $Register, [switch]$DisableDevelopmentMode) }
    }
    if (-not (Get-Command 'Get-AppxPackage' -ErrorAction SilentlyContinue)) {
        function global:Get-AppxPackage { param($Name) }
    }
}

# ------------------------------------------------------------------------------
# 1. Start-IToolkitMenu Option Dispatch
# ------------------------------------------------------------------------------
Describe 'Adversarial 1: Start-IToolkitMenu Option Dispatch' {

    Context 'Direct MenuOption Dispatch' {
        It 'Dispatches Printers submenu on -MenuOption "3"' {
            $script:printersCalled = $false
            Mock Invoke-ToolkitSubmenuPrinters {
                $script:printersCalled = $true
            }
            Mock Invoke-ToolkitSubmenuNetwork { }
            Mock Invoke-ToolkitSubmenuAppInstaller { }

            Start-IToolkitMenu -MenuOption '3' -NonInteractive

            $script:printersCalled | Should -BeTrue
        }

        It 'Dispatches Network submenu on -MenuOption "N"' {
            $script:networkCalled = $false
            Mock Invoke-ToolkitSubmenuNetwork {
                $script:networkCalled = $true
            }
            Mock Invoke-ToolkitSubmenuPrinters { }
            Mock Invoke-ToolkitSubmenuAppInstaller { }

            Start-IToolkitMenu -MenuOption 'N' -NonInteractive

            $script:networkCalled | Should -BeTrue
        }

        It 'Dispatches Network submenu on lowercase -MenuOption "n"' {
            $script:networkLowerCalled = $false
            Mock Invoke-ToolkitSubmenuNetwork {
                $script:networkLowerCalled = $true
            }

            Start-IToolkitMenu -MenuOption 'n' -NonInteractive

            $script:networkLowerCalled | Should -BeTrue
        }

        It 'Dispatches Network submenu on alias -MenuOption "NETWORK"' {
            $script:networkAliasCalled = $false
            Mock Invoke-ToolkitSubmenuNetwork {
                $script:networkAliasCalled = $true
            }

            Start-IToolkitMenu -MenuOption 'NETWORK' -NonInteractive

            $script:networkAliasCalled | Should -BeTrue
        }

        It 'Dispatches AppInstaller submenu on -MenuOption "8"' {
            $script:appInstallerCalled = $false
            Mock Invoke-ToolkitSubmenuAppInstaller {
                $script:appInstallerCalled = $true
            }

            Start-IToolkitMenu -MenuOption '8' -NonInteractive

            $script:appInstallerCalled | Should -BeTrue
        }

        It 'Rejects invalid numeric option "99" and warns without throwing or hanging' {
            $script:warnMessage = $null
            Mock Write-ToolkitStatus {
                param($Message, $Type)
                if ($Type -eq 'WARN') {
                    $script:warnMessage = $Message
                }
            }

            { Start-IToolkitMenu -MenuOption '99' -NonInteractive } | Should -Not -Throw
            $script:warnMessage | Should -Match "Unrecognized menu option '99'"
        }

        It 'Rejects invalid string option "INVALID_OPTION" and warns without throwing or hanging' {
            $script:warnMessage = $null
            Mock Write-ToolkitStatus {
                param($Message, $Type)
                if ($Type -eq 'WARN') {
                    $script:warnMessage = $Message
                }
            }

            { Start-IToolkitMenu -MenuOption 'INVALID_OPTION' -NonInteractive } | Should -Not -Throw
            $script:warnMessage | Should -Match "Unrecognized menu option 'INVALID_OPTION'"
        }

        It 'Rejects negative option "-1" cleanly' {
            $script:warnMessage = $null
            Mock Write-ToolkitStatus {
                param($Message, $Type)
                if ($Type -eq 'WARN') {
                    $script:warnMessage = $Message
                }
            }

            { Start-IToolkitMenu -MenuOption '-1' -NonInteractive } | Should -Not -Throw
            $script:warnMessage | Should -Match "Unrecognized menu option '-1'"
        }
    }
}

# ------------------------------------------------------------------------------
# 2. Headless Execution (Zero Hangs, Clean Exit Code 0)
# ------------------------------------------------------------------------------
Describe 'Adversarial 2: Headless Submenu Execution & Closed Stdin' {

    Context 'In-Process NonInteractive Invocation' {
        It 'Invoke-ToolkitSubmenuPrinters -NonInteractive returns cleanly without hanging' {
            { Invoke-ToolkitSubmenuPrinters -NonInteractive } | Should -Not -Throw
        }

        It 'Invoke-ToolkitSubmenuNetwork -NonInteractive returns cleanly without hanging' {
            { Invoke-ToolkitSubmenuNetwork -NonInteractive } | Should -Not -Throw
        }

        It 'Invoke-ToolkitSubmenuAppInstaller -NonInteractive returns cleanly without hanging' {
            { Invoke-ToolkitSubmenuAppInstaller -NonInteractive } | Should -Not -Throw
        }
    }

    Context 'Out-of-Process Headless CLI Execution with Closed Stdin' {
        It 'Executes Printers submenu headless via Start-IToolkit.ps1 -MenuOption 3 with exit code 0' {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'
            $psi.Arguments = "-NoProfile -File `"$($script:StartScript)`" -SkipElevation -NonInteractive -MenuOption 3"
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false

            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.StandardInput.Close()
            $stdout = $proc.StandardOutput.ReadToEnd()
            $completed = $proc.WaitForExit(10000)
            if (-not $completed) { try { $proc.Kill() } catch { $null = $_ } }

            $completed | Should -BeTrue
            $proc.ExitCode | Should -Be 0
            $stdout | Should -Match '(?i)Printers & Spooler'
        }

        It 'Executes Network submenu headless via Start-IToolkit.ps1 -MenuOption N with exit code 0' {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'
            $psi.Arguments = "-NoProfile -File `"$($script:StartScript)`" -SkipElevation -NonInteractive -MenuOption N"
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false

            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.StandardInput.Close()
            $stdout = $proc.StandardOutput.ReadToEnd()
            $completed = $proc.WaitForExit(10000)
            if (-not $completed) { try { $proc.Kill() } catch { $null = $_ } }

            $completed | Should -BeTrue
            $proc.ExitCode | Should -Be 0
            $stdout | Should -Match '(?i)Network Diagnostics & Repair'
        }

        It 'Executes AppInstaller submenu headless via Start-IToolkit.ps1 -MenuOption 8 with exit code 0' {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'
            $psi.Arguments = "-NoProfile -File `"$($script:StartScript)`" -SkipElevation -NonInteractive -MenuOption 8"
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false

            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.StandardInput.Close()
            $stdout = $proc.StandardOutput.ReadToEnd()
            $completed = $proc.WaitForExit(10000)
            if (-not $completed) { try { $proc.Kill() } catch { $null = $_ } }

            $completed | Should -BeTrue
            $proc.ExitCode | Should -Be 0
            $stdout | Should -Match '(?i)Quick App Installer'
        }
    }
}

# ------------------------------------------------------------------------------
# 3. Winget Fallback to Direct Download Installer
# ------------------------------------------------------------------------------
Describe 'Adversarial 3: Winget Fallback to Direct Download Installer' {

    Context 'Winget Absent / Unavailable' {
        It 'Falls back to direct download for UniKey when winget is unavailable' {
            Mock Test-InternetConnectivity { return $true }
            Mock Get-ToolkitWingetStatus {
                return [PSCustomObject]@{ Available = $false; Healthy = $false }
            }
            Mock Get-Command -ParameterFilter { $Name -eq 'winget' } { return $null }

            # Mock download of zip archive containing UniKeyNT.exe
            Mock Invoke-WebRequest {
                param($Uri, $OutFile)
                $tempScratch = Join-Path ([System.IO.Path]::GetTempPath()) ("IToolkit_AdvTest_" + [System.Guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $tempScratch -Force | Out-Null
                $mockExe = Join-Path $tempScratch 'UniKeyNT.exe'
                Set-Content -LiteralPath $mockExe -Value 'MOCK_UNIKEY_BINARY' -Encoding UTF8
                Compress-Archive -Path $mockExe -DestinationPath $OutFile -Force
                Remove-Item -LiteralPath $tempScratch -Recurse -Force -ErrorAction SilentlyContinue
            }

            $script:installedState = 0
            Mock Get-ToolkitInstalledApplication {
                param($AppName)
                $script:installedState++
                if ($script:installedState -eq 1) {
                    return [PSCustomObject]@{ AppName = $AppName; DisplayName = 'UniKey'; Installed = $false; ExecutablePath = $null }
                }
                return [PSCustomObject]@{
                    AppName        = $AppName
                    DisplayName    = 'UniKey'
                    Installed      = $true
                    ExecutablePath = 'C:\Program Files\UniKey\UniKeyNT.exe'
                    Version        = '4.6.0.0'
                }
            }
            Mock New-ToolkitDesktopShortcut {
                param($TargetExecutable, $ShortcutName)
                return [PSCustomObject]@{ Created = $true; ShortcutPath = "C:\Users\User\Desktop\$ShortcutName" }
            }

            $res = Install-ToolkitApplication -AppName 'UniKey' -Force
            $res | Should -Not -BeNullOrEmpty
            $res.AppName | Should -Be 'UniKey'
            $res.Installed | Should -BeTrue
            $res.Status | Should -Be 'OK'
        }
    }

    Context 'Winget Execution Failure' {
        It 'Falls back to direct download installer for Chrome when winget fails with exit code 1' {
            Mock Test-InternetConnectivity { return $true }
            Mock Get-ToolkitWingetStatus {
                return [PSCustomObject]@{ Available = $true; Healthy = $true }
            }
            Mock Get-Command -ParameterFilter { $Name -eq 'winget' } { return [PSCustomObject]@{ Name = 'winget' } }

            # Winget fails
            $script:directInstallerRan = $false
            Mock Start-Process {
                param($FilePath, $ArgumentList)
                if ($FilePath -eq 'winget') {
                    return [PSCustomObject]@{ ExitCode = 1 }
                }
                # Direct installer execution
                $script:directInstallerRan = $true
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            # Download mock installer
            Mock Invoke-WebRequest {
                param($Uri, $OutFile)
                Set-Content -LiteralPath $OutFile -Value 'MOCK_CHROME_INSTALLER' -Encoding UTF8
            }

            $script:chromeInstalledState = 0
            Mock Get-ToolkitInstalledApplication {
                param($AppName)
                $script:chromeInstalledState++
                if ($script:chromeInstalledState -eq 1) {
                    return [PSCustomObject]@{ AppName = $AppName; DisplayName = 'Google Chrome'; Installed = $false; ExecutablePath = $null }
                }
                return [PSCustomObject]@{
                    AppName        = $AppName
                    DisplayName    = 'Google Chrome'
                    Installed      = $true
                    ExecutablePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
                    Version        = '130.0'
                }
            }
            Mock New-ToolkitDesktopShortcut {
                return [PSCustomObject]@{ Created = $true }
            }
            Mock Set-ToolkitDefaultApplication {
                return [PSCustomObject]@{ DefaultSet = $true }
            }
            Mock Set-ToolkitChromeExtensionPolicy { }

            $res = Install-ToolkitApplication -AppName 'Chrome' -Force
            $res | Should -Not -BeNullOrEmpty
            $res.AppName | Should -Be 'Chrome'
            $res.Installed | Should -BeTrue
            $res.Status | Should -Be 'OK'
            $script:directInstallerRan | Should -BeTrue
        }

        It 'Gracefully handles failure when both winget and direct download fail' {
            Mock Test-InternetConnectivity { return $true }
            Mock Get-ToolkitWingetStatus {
                return [PSCustomObject]@{ Available = $true; Healthy = $true }
            }
            Mock Get-Command -ParameterFilter { $Name -eq 'winget' } { return [PSCustomObject]@{ Name = 'winget' } }

            # Winget fails
            Mock Start-Process {
                param($FilePath)
                if ($FilePath -eq 'winget') { return [PSCustomObject]@{ ExitCode = 1 } }
                return [PSCustomObject]@{ ExitCode = 1 }
            }

            # Download also fails
            Mock Invoke-WebRequest {
                throw "HTTP 500 Internal Server Error"
            }

            Mock Get-ToolkitInstalledApplication {
                param($AppName)
                return [PSCustomObject]@{ AppName = $AppName; DisplayName = 'Google Chrome'; Installed = $false; ExecutablePath = $null }
            }

            $res = Install-ToolkitApplication -AppName 'Chrome' -Force
            $res | Should -Not -BeNullOrEmpty
            $res.Installed | Should -BeFalse
            $res.Status | Should -Be 'WARN'
        }

        It 'Falls back to direct download for UltraVNC when winget fails' {
            Mock Test-InternetConnectivity { return $true }
            Mock Get-ToolkitWingetStatus {
                return [PSCustomObject]@{ Available = $true; Healthy = $true }
            }
            Mock Get-Command -ParameterFilter { $Name -eq 'winget' } { return [PSCustomObject]@{ Name = 'winget' } }

            # Winget fails
            $script:uvncInstallerRan = $false
            Mock Start-Process {
                param($FilePath, $ArgumentList)
                if ($FilePath -eq 'winget') { return [PSCustomObject]@{ ExitCode = 1 } }
                $script:uvncInstallerRan = $true
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            Mock Invoke-WebRequest {
                param($Uri, $OutFile)
                Set-Content -LiteralPath $OutFile -Value 'MOCK_UVNC_INSTALLER' -Encoding UTF8
            }

            $script:uvncState = 0
            Mock Get-ToolkitInstalledApplication {
                param($AppName)
                $script:uvncState++
                if ($script:uvncState -eq 1) {
                    return [PSCustomObject]@{ AppName = $AppName; DisplayName = 'UltraVNC Remote Support'; Installed = $false; ExecutablePath = $null }
                }
                return [PSCustomObject]@{
                    AppName        = $AppName
                    DisplayName    = 'UltraVNC Remote Support'
                    Installed      = $true
                    ExecutablePath = 'C:\Program Files\uvnc bvba\UltraVNC\vncviewer.exe'
                    Version        = '1.5.0.0'
                }
            }
            Mock New-ToolkitDesktopShortcut { return [PSCustomObject]@{ Created = $true } }

            $res = Install-ToolkitApplication -AppName 'UltraVNC' -Force
            $res | Should -Not -BeNullOrEmpty
            $res.AppName | Should -Be 'UltraVNC'
            $res.Installed | Should -BeTrue
            $res.Status | Should -Be 'OK'
            $script:uvncInstallerRan | Should -BeTrue
        }
    }
}

# ------------------------------------------------------------------------------
# 4. Winget Repair Under Simulated Corruption Scenarios
# ------------------------------------------------------------------------------
Describe 'Adversarial 4: Winget Repair Under Simulated Corruption Scenarios' {

    Context 'Source Repository Corruption' {
        It 'Resets package source cache with --force when sources are unhealthy' {
            $script:repairStatusCall = 0
            Mock Get-ToolkitWingetStatus {
                $script:repairStatusCall++
                if ($script:repairStatusCall -le 2) {
                    return [PSCustomObject]@{ Available = $true; Healthy = $false; SourcesHealthy = $false; Version = 'v1.9.0' }
                }
                return [PSCustomObject]@{ Available = $true; Healthy = $true; SourcesHealthy = $true; Version = 'v1.9.0' }
            }

            $script:sourceResetCalled = $false
            Mock Start-Process {
                param($FilePath, $ArgumentList)
                if ($FilePath -eq 'winget' -and $ArgumentList -like '*source reset --force*') {
                    $script:sourceResetCalled = $true
                    return [PSCustomObject]@{ ExitCode = 0 }
                }
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $res = Repair-ToolkitWinget
            $res | Should -Not -BeNullOrEmpty
            $res.Success | Should -BeTrue
            $res.Healthy | Should -BeTrue
            $script:sourceResetCalled | Should -BeTrue
            ($res.ActionsTaken | Where-Object { $_ -like '*Reset winget package source cache*' }) | Should -Not -BeNullOrEmpty
        }
    }

    Context 'App Execution Alias & PATH Corruption' {
        It 'Repairs App Execution Alias and PATH configuration when alias missing or not in PATH' {
            $script:aliasStatusCall = 0
            Mock Get-ToolkitWingetStatus {
                $script:aliasStatusCall++
                return [PSCustomObject]@{ Available = $false; Healthy = $false; SourcesHealthy = $true; Version = $null }
            }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            Mock Install-ToolkitWingetLatest {
                return [PSCustomObject]@{ Success = $true; Version = 'v1.9.0'; DependenciesInstalled = @() }
            }

            $res = Repair-ToolkitWinget -Force
            $res | Should -Not -BeNullOrEmpty
            ($res.ActionsTaken | Where-Object { $_ -like '*Repaired App Execution Alias*' }) | Should -Not -BeNullOrEmpty
        }
    }

    Context 'AppX Registration Corruption' {
        It 'Re-registers DesktopAppInstaller package when winget is unavailable or version is missing' {
            $script:appxStatusCall = 0
            Mock Get-ToolkitWingetStatus {
                $script:appxStatusCall++
                if ($script:appxStatusCall -le 3) {
                    return [PSCustomObject]@{ Available = $false; Healthy = $false; SourcesHealthy = $false; Version = $null }
                }
                return [PSCustomObject]@{ Available = $true; Healthy = $true; SourcesHealthy = $true; Version = 'v1.9.25200' }
            }
            $script:latestInstallerCalled = $false
            Mock Install-ToolkitWingetLatest {
                $script:latestInstallerCalled = $true
                return [PSCustomObject]@{ Success = $true; Version = 'v1.9.25200'; DependenciesInstalled = @('VCLibs') }
            }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }

            $res = Repair-ToolkitWinget -Force
            $res | Should -Not -BeNullOrEmpty
            $res.Success | Should -BeTrue
            $script:latestInstallerCalled | Should -BeTrue
            ($res.ActionsTaken | Where-Object { $_ -like '*Re-registered Microsoft.DesktopAppInstaller*' }) | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Runtime Dependencies Corruption & -WhatIf Safety' {
        It 'Re-installs missing runtime dependencies (VCLibs / UI.Xaml) when unhealthy' {
            Mock Get-ToolkitWingetStatus {
                return [PSCustomObject]@{ Available = $true; Healthy = $false; SourcesHealthy = $true; Version = 'v1.9.0' }
            }
            $script:depReinstallCalled = $false
            Mock Install-ToolkitWingetLatest {
                $script:depReinstallCalled = $true
                return [PSCustomObject]@{ Success = $true; DependenciesInstalled = @('Microsoft.VCLibs.140.00.UWPDesktop') }
            }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }

            $res = Repair-ToolkitWinget -Force
            $res | Should -Not -BeNullOrEmpty
            $script:depReinstallCalled | Should -BeTrue
            ($res.ActionsTaken | Where-Object { $_ -like '*runtime dependencies*' }) | Should -Not -BeNullOrEmpty
        }

        It 'Respects -WhatIf parameter and aborts modification safely' {
            $res = Repair-ToolkitWinget -WhatIf
            $res | Should -Not -BeNullOrEmpty
            $res.Success | Should -BeFalse
            $res.ActionsTaken.Count | Should -Be 0
            $res.ErrorMessage | Should -Match 'WhatIf'
        }
    }
}
