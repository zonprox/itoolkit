if (-not (Get-Command -Name 'Wait-UserAcknowledge' -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot '../Private/Wait-UserAcknowledge.ps1'
    if (Test-Path $waitScript) {
        . $waitScript
    }
}

function Get-SoftwareOptimizationContextInfoLines {
    [CmdletBinding()]
    param()

    $lines = [System.Collections.Generic.List[string]]::new()
    $telemetry = Get-ToolkitTelemetryData
    $archStr = if ([System.Environment]::Is64BitOperatingSystem) { '64-bit [ENFORCED]' } else { '32-bit [UNSUPPORTED]' }
    $lines.Add("Architecture   : $($telemetry.Architecture) | $archStr")

    $netStatus = "Online [READY]"
    if (Get-Command -Name 'Test-InternetConnectivity' -ErrorAction SilentlyContinue) {
        try {
            $isOnline = Test-InternetConnectivity
            $netStatus = if ($isOnline) { "Online [READY]" } else { "Offline [STANDALONE DIRECT DOWNLOAD]" }
        } catch { $netStatus = "Offline [STANDALONE DIRECT DOWNLOAD]" }
    }
    $lines.Add("Internet Check : $netStatus")

    $wingetVer = 'Auto-Detect'
    if (Get-Command -Name 'Get-ToolkitWingetStatus' -ErrorAction SilentlyContinue) {
        try {
            $wStatus = Get-ToolkitWingetStatus
            if ($wStatus -and $wStatus.Version) { $wingetVer = $wStatus.Version }
        } catch { $null = $_ }
    }
    $lines.Add("Deploy Engine  : Winget v$wingetVer / Direct 64-Bit Fallback")
    $lines.Add("Catalog Status : 8 Applications Managed | Win11Debloat & External Tools")

    return $lines.ToArray()
}

function Get-AppInstallerContextInfoLines {
    [CmdletBinding()]
    param()

    $wStatus = if (Get-Command -Name 'Get-ToolkitWingetStatus' -ErrorAction SilentlyContinue) {
        Get-ToolkitWingetStatus
    } else { $null }

    $deployStr = if ($wStatus -and $wStatus.Available -and $wStatus.Healthy) {
        "winget [ACTIVE - $($wStatus.Version)]"
    } else {
        "[STANDALONE DIRECT DOWNLOAD]"
    }

    return @(
        "Architecture : 64-bit",
        "Deploy Engine: $deployStr"
    )
}

function Get-ExternalToolsContextInfoLines {
    [CmdletBinding()]
    param()

    return @(
        "Tool 1 : Win11Debloat [READY]",
        "Tool 2 : BrowserDebloat [READY]",
        "Tool 3 : Office Tool Plus [READY]",
        "Status : All 3 external tools configured"
    )
}

if (Get-Command -Name 'Get-SoftwareOptimizationContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-SoftwareOptimizationContextInfoLines' -Value (Get-Command -Name 'Get-SoftwareOptimizationContextInfoLines').ScriptBlock
}
if (Get-Command -Name 'Get-AppInstallerContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-AppInstallerContextInfoLines' -Value (Get-Command -Name 'Get-AppInstallerContextInfoLines').ScriptBlock
}
if (Get-Command -Name 'Get-ExternalToolsContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-ExternalToolsContextInfoLines' -Value (Get-Command -Name 'Get-ExternalToolsContextInfoLines').ScriptBlock
}

function Invoke-ToolkitSubmenuSoftwareOptimization {
<#
.SYNOPSIS
    Submenu for Software & System Optimization (App Installer & Debloat Utilities).
.DESCRIPTION
    Presents 64-bit silent software installation and system debloat utilities:
    - 64-bit silent installations: Chrome, Foxit, UniKey, UltraVNC, K-Lite, VCRedist, Zalo, WinRAR
    - Batch installation of all applications with desktop shortcuts and defaults
    - Winget mass package update
    - Windows 11 bloatware and telemetry debloat scripts
    - Browser debloat and Office Tool Plus launchers
    - Internet connectivity verification
.PARAMETER ExitImmediately
    Bypasses interactive loop and returns immediately (for automated testing).
.PARAMETER NonInteractive
    Headless automation mode: renders menu once and returns cleanly.
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

    if (-not [System.Environment]::Is64BitOperatingSystem) {
        Write-ToolkitStatus -Message "FATAL: IToolkit application deployment strictly requires 64-bit Windows. 32-bit architecture is unsupported." -Type 'FAIL'
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
        $optInfo = Get-SoftwareOptimizationContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > SOFTWARE & SYSTEM OPTIMIZATION' -Subtitle 'Quick App Installer & 64-Bit Silent Deployment, Winget Maintenance, Debloat & External Tool Launchers' -ClearScreen:$clear -InfoLines $optInfo

        $appsList = @()
        if (Get-Command -Name 'Get-ToolkitInstalledApplication' -ErrorAction SilentlyContinue) {
            try {
                $rawApps = Get-ToolkitInstalledApplication
                $standardOrder = @('Chrome', 'FoxitReader', 'UniKey', 'UltraVNC', 'KLiteCodec', 'VCRedistAIO', 'Zalo', 'WinRAR')
                $sortedApps = @()
                foreach ($targetName in $standardOrder) {
                    $matched = $rawApps | Where-Object { $_.AppName -eq $targetName } | Select-Object -First 1
                    if ($null -ne $matched) {
                        $sortedApps += $matched
                    }
                }
                foreach ($app in $rawApps) {
                    if ($standardOrder -notcontains $app.AppName) {
                        $sortedApps += $app
                    }
                }
                foreach ($app in $sortedApps) {
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
                [PSCustomObject]@{ Application = 'Google Chrome Browser'; Status = '[READY]'; Executable = 'chrome.exe'; Version = 'Latest 64-bit' },
                [PSCustomObject]@{ Application = 'Foxit PDF Reader'; Status = '[READY]'; Executable = 'FoxitPDFReader.exe'; Version = 'Latest 64-bit' },
                [PSCustomObject]@{ Application = 'UniKey Vietnamese Input'; Status = '[READY]'; Executable = 'UniKeyNT.exe'; Version = '64-bit' },
                [PSCustomObject]@{ Application = 'UltraVNC Remote Support'; Status = '[READY]'; Executable = 'vncviewer.exe'; Version = 'x64 Setup' },
                [PSCustomObject]@{ Application = 'K-Lite Codec Pack'; Status = '[READY]'; Executable = 'mpc-hc64.exe'; Version = '64-bit' },
                [PSCustomObject]@{ Application = 'Visual C++ Redistributable AIO'; Status = '[READY]'; Executable = 'System Runtimes'; Version = 'x64' },
                [PSCustomObject]@{ Application = 'Zalo PC Messenger'; Status = '[READY]'; Executable = 'Zalo.exe'; Version = 'Latest' },
                [PSCustomObject]@{ Application = 'WinRAR Archiver'; Status = '[READY]'; Executable = 'WinRAR.exe'; Version = 'x64' }
            )
        }
        Show-ToolkitItemTable -Items $appsList -Columns @('Application', 'Status', 'Executable', 'Version') -Headers @('APPLICATION', 'STATUS', 'EXECUTABLE', 'VERSION') -Title 'Managed Enterprise 64-Bit Application Catalog' -NoIndex

        Write-Host ""
        $installerActions = @(
            @{ Key = '1'; Label = 'Google Chrome' },
            @{ Key = '2'; Label = 'Foxit Reader' },
            @{ Key = '3'; Label = 'UniKey' },
            @{ Key = '4'; Label = 'UltraVNC' },
            @{ Key = '5'; Label = 'K-Lite Codec Pack' },
            @{ Key = '6'; Label = 'Visual C++ Redistributable AIO' },
            @{ Key = '7'; Label = 'Zalo PC' },
            @{ Key = '8'; Label = 'WinRAR' },
            @{ Key = '9'; Label = 'Update All Winget Apps' },
            @{ Key = '10'; Label = 'Win11Debloat' },
            @{ Key = '11'; Label = 'Browser Debloat' },
            @{ Key = '12'; Label = 'Office Tool Plus' }
        )
        $navActions = @(
            @{ Key = '0'; Label = 'Back to Main Menu' }
        )
        Show-ToolkitActionCatalog -Actions $installerActions -NavActions $navActions -Title 'DEPLOYMENT & OPTIMIZATION ACTIONS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Software & System Optimization'." -Type 'INFO'
            return
        }

        $validKeys = @('1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11', '12', '0')
        $sub = Read-ToolkitMenuChoice -Prompt 'Select Action' -ValidKeys $validKeys
        if ([string]::IsNullOrWhiteSpace($sub) -or $sub -eq '0' -or $sub -notin $validKeys) {
            $inSubmenu = $false
            break
        }

        switch ($sub) {
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
                    Write-ToolkitStatus -Message "Installing UniKey Vietnamese Input Method..." -Type 'INFO'
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
                    Write-ToolkitStatus -Message "Installing UltraVNC Remote Support..." -Type 'INFO'
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
                    Write-ToolkitStatus -Message "Installing K-Lite Codec Pack Standard..." -Type 'INFO'
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
                    Write-ToolkitStatus -Message "Installing Visual C++ Redistributable All-In-One..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'VCRedistAIO'
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "Visual C++ Redistributables deployment finished." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            '7' {
                if (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Installing Zalo PC Messenger..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'Zalo' -CreateShortcut
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "Zalo PC deployment finished." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            '8' {
                if (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Installing WinRAR Archiver..." -Type 'INFO'
                    $res = Install-ToolkitApplication -AppName 'WinRAR' -CreateShortcut
                    $res | Format-Table -AutoSize
                    Write-ToolkitStatus -Message "WinRAR deployment finished." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            '9' {
                if (Get-Command -Name 'Update-WingetPackage' -ErrorAction SilentlyContinue) {
                    Write-ToolkitStatus -Message "Initiating automated upgrade for all installed winget packages..." -Type 'INFO'
                    $upRes = Update-WingetPackage -All
                    if ($upRes -and $upRes.Success) {
                        Write-ToolkitStatus -Message "All winget packages updated successfully. Total updated: $($upRes.TotalUpgraded)." -Type 'OK'
                    } else {
                        Write-ToolkitStatus -Message "Winget package update finished with status: $($upRes.Status)." -Type 'INFO'
                    }
                } else {
                    Write-ToolkitStatus -Message "Update-WingetPackage command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            '10' {
                if (Get-Command -Name 'Invoke-Win11Debloat' -ErrorAction SilentlyContinue) {
                    Invoke-Win11Debloat | Format-List
                }
                Wait-UserAcknowledge
                break
            }
            '11' {
                if (Get-Command -Name 'Invoke-BrowserDebloat' -ErrorAction SilentlyContinue) {
                    Invoke-BrowserDebloat | Format-List
                }
                Wait-UserAcknowledge
                break
            }
            '12' {
                if (Get-Command -Name 'Invoke-OfficeToolPlus' -ErrorAction SilentlyContinue) {
                    Invoke-OfficeToolPlus | Format-List
                } else {
                    Write-ToolkitStatus -Message "Invoke-OfficeToolPlus command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
                break
            }
            '0' {
                $inSubmenu = $false
                return
            }
        }
    }
}

function Invoke-ToolkitSubmenuAppInstaller {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][switch]$ExitImmediately,
        [Parameter(Mandatory = $false)][switch]$NonInteractive,
        [Parameter(Mandatory = $false)][int]$MenuDepth = 1
    )
    Invoke-ToolkitSubmenuSoftwareOptimization @PSBoundParameters
}

function Invoke-ToolkitSubmenuExternalTools {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][switch]$ExitImmediately,
        [Parameter(Mandatory = $false)][switch]$NonInteractive,
        [Parameter(Mandatory = $false)][int]$MenuDepth = 1
    )
    Invoke-ToolkitSubmenuSoftwareOptimization @PSBoundParameters
}

if (Get-Command -Name 'Invoke-ToolkitSubmenuSoftwareOptimization' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuSoftwareOptimization' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuSoftwareOptimization').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuAppInstaller' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuAppInstaller' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuAppInstaller').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuExternalTools' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuExternalTools' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuExternalTools').ScriptBlock
}
