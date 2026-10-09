if (-not (Get-Command -Name Wait-UserAcknowledge -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot ../Private/Wait-UserAcknowledge.ps1
    if (Test-Path $waitScript) {
        . $waitScript
    }
}

function Get-AppInstallerContextInfoLines {
    [CmdletBinding()]
    param()

    $lines = [System.Collections.Generic.List[string]]::new()

    # 1. Desktop Location & Current User
    $currentUser = if ($env:USERNAME) { $env:USERNAME } else { [Environment]::UserName }
    $desktopPath = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktopPath)) { $desktopPath = "$env:USERPROFILE\Desktop" }
    $lines.Add("Current User   : $currentUser | Desktop: $desktopPath")

    # 2. Package Manager & Installation Engine
    $hasWinget = [bool](Get-Command -Name 'winget' -ErrorAction SilentlyContinue)
    $pmStr = if ($hasWinget) { "winget [READY]" } else { "Direct HTTPS Installer [READY]" }
    $lines.Add("Deploy Engine  : $pmStr")

    # 3. Installed Apps Overview
    $chromeStat = "[MISSING]"
    $foxitStat = "[MISSING]"
    $unikeyStat = "[MISSING]"
    $zaloStat = "[MISSING]"
    if (Get-Command -Name 'Get-ToolkitInstalledApplication' -ErrorAction SilentlyContinue) {
        try {
            $apps = Get-ToolkitInstalledApplication
            $chrome = $apps | Where-Object { $_.AppName -eq 'Chrome' }
            if ($chrome -and $chrome.Installed) { $chromeStat = "[INSTALLED]" }
            $foxit = $apps | Where-Object { $_.AppName -eq 'FoxitReader' }
            if ($foxit -and $foxit.Installed) { $foxitStat = "[INSTALLED]" }
            $unikey = $apps | Where-Object { $_.AppName -eq 'UniKey' }
            if ($unikey -and $unikey.Installed) { $unikeyStat = "[INSTALLED]" }
            $zalo = $apps | Where-Object { $_.AppName -eq 'Zalo' }
            if ($zalo -and $zalo.Installed) { $zaloStat = "[INSTALLED]" }
        } catch {
            $null = $_
        }
    }
    $lines.Add("App Status     : Chrome $chromeStat | Foxit $foxitStat | UniKey $unikeyStat | Zalo $zaloStat")
    $lines.Add("Catalog Targets: UniKey, UltraVNC, K-Lite, Chrome, VCRedist, Foxit, Zalo [READY]")

    return $lines.ToArray()
}

if (Get-Command -Name 'Get-AppInstallerContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-AppInstallerContextInfoLines' -Value (Get-Command -Name 'Get-AppInstallerContextInfoLines').ScriptBlock
}

function Invoke-ToolkitSubmenuAppInstaller {
<#
.SYNOPSIS
    Submenu for Quick Application Installation, Desktop Shortcuts & Default Application Configuration.
.DESCRIPTION
    Presents automated silent installation capabilities for:
    - UniKey (Vietnamese Input Method)
    - UltraVNC (Remote Administration & Screen Sharing)
    - K-Lite Codec Pack (Audio/Video Codecs & Media Player Classic)
    - Google Chrome (Web Browser)
    - Visual C++ Redistributables All-In-One (vcredist AIO)
    - Foxit PDF Reader (PDF Viewer & Editor)
    Generates desktop shortcuts for the current user account and sets Chrome and Foxit as system defaults.
.PARAMETER ExitImmediately
    Switch to bypass interactive loop and return immediately (used for automated testing).
.PARAMETER NonInteractive
    Switch to run in headless automation mode: renders menu once and returns cleanly.
.PARAMETER MenuDepth
    Optional menu recursion depth.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$ExitImmediately,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [int]$MenuDepth = 1
    )

    if ($ExitImmediately) {
        Write-ToolkitStatus -Message "Submenu launched with -ExitImmediately flag. Returning." -Type 'INFO'
        return
    }

    if (-not (Get-Command -Name 'Show-ToolkitActionCatalog' -ErrorAction SilentlyContinue)) {
        $catScript = Join-Path $PSScriptRoot 'Show-ToolkitActionCatalog.ps1'
        if (Test-Path $catScript) { . $catScript }
    }
    if (-not (Get-Command -Name 'Show-ToolkitItemTable' -ErrorAction SilentlyContinue)) {
        $tableScript = Join-Path $PSScriptRoot 'Show-ToolkitItemTable.ps1'
        if (Test-Path $tableScript) { . $tableScript }
    }

    $inSubmenu = $true
    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $installerInfo = Get-AppInstallerContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > QUICK APP INSTALLER & DEPLOYMENT' -Subtitle 'Silent Installation, Desktop Shortcuts & Default App Configuration' -ClearScreen:$clear -InfoLines $installerInfo

        # Query installed apps
        $appsList = @()
        if (Get-Command -Name 'Get-ToolkitInstalledApplication' -ErrorAction SilentlyContinue) {
            try {
                $rawApps = Get-ToolkitInstalledApplication
                foreach ($app in $rawApps) {
                    $statusBadge = if ($app.Installed) { '[INSTALLED]' } else { '[MISSING]' }
                    $exeDisplay = if ($app.ExecutablePath) { Split-Path -Leaf $app.ExecutablePath } else { 'Not Installed' }
                    $appsList += [PSCustomObject]@{
                        Application = $app.DisplayName
                        Status      = $statusBadge
                        Executable  = $exeDisplay
                        Version     = if ($app.Version) { $app.Version } else { 'N/A' }
                    }
                }
            } catch {
                $null = $_
            }
        }

        if ($appsList.Count -eq 0) {
            $appsList = @(
                [PSCustomObject]@{ Application = 'Google Chrome Browser'; Status = '[READY]'; Executable = 'chrome.exe'; Version = 'Latest (Auto-detected)' },
                [PSCustomObject]@{ Application = 'Foxit PDF Reader'; Status = '[READY]'; Executable = 'FoxitPDFReader.exe'; Version = 'Latest (Auto-detected)' },
                [PSCustomObject]@{ Application = 'UniKey Vietnamese Input'; Status = '[READY]'; Executable = 'UniKeyNT.exe'; Version = '4.6 RC2' },
                [PSCustomObject]@{ Application = 'UltraVNC Remote Support'; Status = '[READY]'; Executable = 'vncviewer.exe'; Version = 'Latest (Auto-detected)' },
                [PSCustomObject]@{ Application = 'K-Lite Codec Pack'; Status = '[READY]'; Executable = 'mpc-hc64.exe'; Version = 'Standard' },
                [PSCustomObject]@{ Application = 'Visual C++ Redistributable AIO'; Status = '[READY]'; Executable = 'System Runtimes'; Version = 'v0.105.0+' },
                [PSCustomObject]@{ Application = 'Zalo PC Messenger'; Status = '[READY]'; Executable = 'Zalo.exe'; Version = 'Latest (Auto-detected)' }
            )
        }

        Show-ToolkitItemTable -Items $appsList -Columns @('Application', 'Status', 'Executable', 'Version') -Headers @('APPLICATION', 'STATUS', 'EXECUTABLE', 'VERSION') -Title 'Managed Enterprise Application Catalog'

        Write-Host ""
        $installerActions = @(
            @{ Key = 'A'; Label = 'Install All Apps (Full Setup)' },
            @{ Key = '1'; Label = 'Install Chrome (Set Default)' },
            @{ Key = '2'; Label = 'Install Foxit Reader (Set Default)' },
            @{ Key = '3'; Label = 'Install UniKey (Desktop Shortcut)' },
            @{ Key = '4'; Label = 'Install UltraVNC (Desktop Shortcut)' },
            @{ Key = '5'; Label = 'Install K-Lite Codec Pack' },
            @{ Key = '6'; Label = 'Install VC++ Redist AIO' },
            @{ Key = '7'; Label = 'Install Zalo PC (Desktop Shortcut)' },
            @{ Key = 'E'; Label = 'Deploy Chrome Extensions (uBlock Lite)' },
            @{ Key = 'S'; Label = 'Create Desktop Shortcuts' },
            @{ Key = 'D'; Label = 'Set Default Applications' }
        )
        $navActions = @(
            @{ Key = 'B'; Label = 'Back to Main Menu' },
            @{ Key = 'Q'; Label = 'Quit' }
        )
        Show-ToolkitActionCatalog -Actions $installerActions -NavActions $navActions -Title 'DEPLOYMENT ACTIONS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Quick App Installer'." -Type 'INFO'
            return
        }

        $validKeys = @('A', '1', '2', '3', '4', '5', '6', '7', 'E', 'S', 'D', 'B', 'Q')
        $sub = Read-ToolkitMenuChoice -Prompt 'Select Action' -ValidKeys $validKeys
        if ([string]::IsNullOrWhiteSpace($sub) -or $sub.ToUpperInvariant() -eq 'B') {
            $inSubmenu = $false
            break
        }
        if ($sub.ToUpperInvariant() -eq 'Q') {
            $inSubmenu = $false
            return
        }

        switch ($sub.ToUpperInvariant()) {
            'A' {
                if (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Initiating automated installation of all standard applications..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'All' -CreateShortcut -SetDefault
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "All application deployments completed." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            '1' {
                if (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Installing Google Chrome and setting as default browser..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'Chrome' -CreateShortcut -SetDefault
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "Google Chrome deployment finished." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            '2' {
                if (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Installing Foxit PDF Reader and setting as default PDF viewer..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'FoxitReader' -CreateShortcut -SetDefault
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "Foxit PDF Reader deployment finished." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            '3' {
                if (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Installing UniKey and creating desktop shortcut..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'UniKey' -CreateShortcut
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "UniKey deployment finished." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            '4' {
                if (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Installing UltraVNC and creating desktop shortcut..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'UltraVNC' -CreateShortcut
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "UltraVNC deployment finished." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            '5' {
                if (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Installing K-Lite Codec Pack..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'KLiteCodec' -CreateShortcut
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "K-Lite Codec Pack deployment finished." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            '6' {
                if (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Installing Microsoft Visual C++ Redistributable AIO..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'VCRedistAIO'
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "Visual C++ Redistributable AIO deployment finished." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            '7' {
                if (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Installing Zalo PC and creating desktop shortcut..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'Zalo' -CreateShortcut
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "Zalo PC deployment finished." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            'E' {
                if (Get-Command -Name 'Set-ToolkitChromeExtensionPolicy' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Deploying uBlock Origin Lite extension policy for Chrome..." -Type 'INFO'
                    $extRes = Set-ToolkitChromeExtensionPolicy
                    if ($extRes.Configured) {
                        Write-ToolkitStatus -Message "uBlock Origin Lite enterprise policy applied successfully." -Type 'OK'
                    } else {
                        Write-ToolkitStatus -Message "Chrome extension policy could not be verified." -Type 'WARN'
                    }
                } elseif (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Configuring Chrome extension policy via AppInstaller..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'Chrome' -ConfigureChromeExtensions
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "Chrome extension configuration finished." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Chrome extension deployment cmdlet not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            'S' {
                if ((Get-Command -Name 'Get-ToolkitInstalledApplication' -ErrorAction SilentlyContinue) -and
                    (Get-Command -Name 'New-ToolkitDesktopShortcut' -ErrorAction SilentlyContinue)) {
                    Write-ToolkitStatus -Message "Creating desktop shortcuts for current user..." -Type 'INFO'
                    $installedApps = Get-ToolkitInstalledApplication
                    $shortcutMap = @{
                        'UniKey'      = 'UniKey.lnk'
                        'UltraVNC'    = 'UltraVNC Viewer.lnk'
                        'KLiteCodec'  = 'Media Player Classic.lnk'
                        'Chrome'      = 'Google Chrome.lnk'
                        'FoxitReader' = 'Foxit PDF Reader.lnk'
                        'Zalo'        = 'Zalo.lnk'
                    }
                    foreach ($app in $installedApps) {
                        if ($app.Installed -and $app.ExecutablePath -and $shortcutMap.ContainsKey($app.AppName)) {
                            New-ToolkitDesktopShortcut -TargetExecutable $app.ExecutablePath -ShortcutName $shortcutMap[$app.AppName] -Force | Out-Null
                        }
                    }
                    Write-ToolkitStatus -Message "Desktop shortcut creation completed." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Shortcut creation cmdlets not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            'D' {
                if (Get-Command -Name 'Set-ToolkitDefaultApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Setting default applications (Chrome for Browser, Foxit for PDF)..." -Type 'INFO'
                    $res = Set-ToolkitDefaultApplication -Application 'All'
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "Default application configuration completed." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Set-ToolkitDefaultApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
        }
    }
}

if (Get-Command -Name Get-AppInstallerContextInfoLines -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path function:global:Get-AppInstallerContextInfoLines -Value (Get-Command -Name Get-AppInstallerContextInfoLines).ScriptBlock
}
if (Get-Command -Name Invoke-ToolkitSubmenuAppInstaller -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path function:global:Invoke-ToolkitSubmenuAppInstaller -Value (Get-Command -Name Invoke-ToolkitSubmenuAppInstaller).ScriptBlock
}

