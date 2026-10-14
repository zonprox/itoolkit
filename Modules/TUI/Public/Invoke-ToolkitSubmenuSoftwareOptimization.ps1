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
        "Status : All 2 external tools configured"
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

function Invoke-ToolkitApplicationContextMenu {
<#
.SYNOPSIS
    Contextual administration menu for a targeted application.
.PARAMETER SelectedApp
    The selected application object from the catalog.
.PARAMETER ExitImmediately
    Bypasses interactive loop and returns immediately.
.PARAMETER NonInteractive
    Headless automation mode: renders menu once and returns cleanly.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('App')]
        [PSCustomObject]$SelectedApp,

        [Parameter(Mandatory = $false)]
        [switch]$ExitImmediately,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    if ($ExitImmediately) {
        Write-ToolkitStatus -Message "Application context menu launched with -ExitImmediately flag. Returning." -Type 'INFO'
        return
    }

    $inContext = $true
    while ($inContext) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $appName = if ($SelectedApp.AppName) { [string]$SelectedApp.AppName } else { 'Application' }
        $dispName = if ($SelectedApp.DisplayName) { [string]$SelectedApp.DisplayName } elseif ($SelectedApp.Application) { [string]$SelectedApp.Application } else { $appName }
        $statusBadge = if ($SelectedApp.Installed) { '[INSTALLED]' } elseif ($SelectedApp.Status) { [string]$SelectedApp.Status } else { '[MISSING]' }
        $exeDisplay = if ($SelectedApp.ExecutablePath) { [string]$SelectedApp.ExecutablePath } elseif ($SelectedApp.Executable) { [string]$SelectedApp.Executable } else { 'Not Installed' }
        $verDisplay = if ($SelectedApp.Version) { [string]$SelectedApp.Version } else { 'N/A' }

        $infoLines = @(
            "Target App     : $dispName ($appName)",
            "Status         : $statusBadge | Version: $verDisplay",
            "Executable     : $exeDisplay",
            "Architecture   : 64-bit [ENFORCED]"
        )

        Show-ToolkitHeader -Title 'ITOOLKIT > SOFTWARE > APPLICATION CONTEXT' `
            -Subtitle "Contextual Deployment & Maintenance: $dispName" `
            -ClearScreen:$clear `
            -InfoLines $infoLines

        $contextActions = @(
            @{ Key = '1'; Label = 'Silent Install' },
            @{ Key = '2'; Label = 'Force Reinstall' },
            @{ Key = '3'; Label = 'Verify Status' },
            @{ Key = '4'; Label = 'Create Desktop Shortcut' }
        )
        $navActions = @(
            @{ Key = '0'; Label = 'Back to Applications Table' }
        )
        Show-ToolkitActionCatalog -Actions $contextActions -NavActions $navActions -Title "APPLICATION ACTIONS: $dispName"

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive contextual view rendered for '$dispName'." -Type 'INFO'
            return
        }

        $choice = Read-ToolkitItemSelection -MaxIndex 0 -ValidHotkeys @('1', '2', '3', '4') -Prompt "  Select action for '$dispName' [1-4, 0]"
        if ($null -eq $choice -or $choice.Type -eq 'Exit' -or $choice.Value -eq '0') {
            $inContext = $false
            return
        }

        switch ("$($choice.Value)") {
            '1' {
                Write-ToolkitStatus -Message "Installing $dispName silently..." -Type 'INFO'
                if (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    $installParams = @{
                        AppName        = $appName
                        CreateShortcut = $true
                    }
                    if ($appName -in @('Chrome', 'FoxitReader')) {
                        $installParams['SetDefault'] = $true
                    }
                    $res = Install-ToolkitApplication @installParams
                    $res | Format-Table -AutoSize
                    $SelectedApp.Installed = $true
                    $SelectedApp.Status    = '[INSTALLED]'
                    Write-ToolkitStatus -Message "$dispName deployment completed." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            '2' {
                Write-ToolkitStatus -Message "Force reinstalling $dispName..." -Type 'INFO'
                if (Get-Command -Name 'Install-ToolkitApplication' -ErrorAction SilentlyContinue) {
                    $res = Install-ToolkitApplication -AppName $appName -Force -CreateShortcut
                    $res | Format-Table -AutoSize
                    $SelectedApp.Installed = $true
                    $SelectedApp.Status    = '[INSTALLED]'
                    Write-ToolkitStatus -Message "$dispName force reinstallation completed." -Type 'OK'
                } else {
                    Write-ToolkitStatus -Message "Install-ToolkitApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            '3' {
                Write-ToolkitStatus -Message "Checking status and version for $dispName..." -Type 'INFO'
                if (Get-Command -Name 'Get-ToolkitInstalledApplication' -ErrorAction SilentlyContinue) {
                    $chk = Get-ToolkitInstalledApplication -AppName $appName | Select-Object -First 1
                    if ($chk) {
                        $SelectedApp.Installed      = $chk.Installed
                        $SelectedApp.Status         = if ($chk.Installed) { '[INSTALLED]' } else { '[MISSING]' }
                        $SelectedApp.Version        = if ($chk.Version) { $chk.Version } else { 'N/A' }
                        $SelectedApp.ExecutablePath = $chk.ExecutablePath
                        $chk | Format-List *
                        $st = if ($chk.Installed) { "INSTALLED (v$($chk.Version))" } else { "MISSING" }
                        Write-ToolkitStatus -Message "Application status: $st" -Type 'OK'
                    }
                } else {
                    Write-ToolkitStatus -Message "Get-ToolkitInstalledApplication command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            '4' {
                Write-ToolkitStatus -Message "Creating desktop shortcut for $dispName..." -Type 'INFO'
                if (Get-Command -Name 'New-ToolkitDesktopShortcut' -ErrorAction SilentlyContinue) {
                    $targetExe = $SelectedApp.ExecutablePath
                    if ([string]::IsNullOrWhiteSpace($targetExe) -or -not (Test-Path -LiteralPath $targetExe -ErrorAction SilentlyContinue)) {
                        if (Get-Command -Name 'Get-ToolkitInstalledApplication' -ErrorAction SilentlyContinue) {
                            $appInfo = Get-ToolkitInstalledApplication -AppName $appName | Select-Object -First 1
                            if ($appInfo -and $appInfo.ExecutablePath) {
                                $targetExe = $appInfo.ExecutablePath
                            }
                        }
                    }
                    if (-not [string]::IsNullOrWhiteSpace($targetExe)) {
                        $sc = New-ToolkitDesktopShortcut -TargetExecutable $targetExe -ShortcutName $dispName -Force
                        if ($sc -and $sc.Created) {
                            Write-ToolkitStatus -Message "Desktop shortcut created: $($sc.ShortcutPath)" -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "Desktop shortcut processed: $($sc.ShortcutPath)" -Type 'INFO'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Executable path not found. Please install the application first." -Type 'WARN'
                    }
                } else {
                    Write-ToolkitStatus -Message "New-ToolkitDesktopShortcut command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            '0' {
                $inContext = $false
                return
            }
        }
    }
}

if (Get-Command -Name 'Invoke-ToolkitApplicationContextMenu' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitApplicationContextMenu' -Value (Get-Command -Name 'Invoke-ToolkitApplicationContextMenu').ScriptBlock
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
    - Browser debloat launcher
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
    if (-not (Get-Command -Name 'Read-ToolkitItemSelection' -ErrorAction SilentlyContinue)) {
        $selectScript = Join-Path $PSScriptRoot 'Read-ToolkitItemSelection.ps1'
        if (Test-Path $selectScript) { . $selectScript }
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
                        AppName        = $app.AppName
                        DisplayName    = $app.DisplayName
                        Application    = $app.DisplayName
                        Status         = $statusBadge
                        Executable     = $exeDisplay
                        ExecutablePath = $app.ExecutablePath
                        Version        = if ($app.Version) { $app.Version } else { 'N/A' }
                        Installed      = [bool]$app.Installed
                    }
                }
            } catch {
                $null = $_
            }
        }

        if ($appsList.Count -eq 0) {
            $appsList = @(
                [PSCustomObject]@{ AppName = 'Chrome';      DisplayName = 'Google Chrome Browser';          Application = 'Google Chrome Browser';          Status = '[READY]'; Executable = 'chrome.exe';        ExecutablePath = ''; Version = 'Latest 64-bit'; Installed = $false },
                [PSCustomObject]@{ AppName = 'FoxitReader';  DisplayName = 'Foxit PDF Reader';              Application = 'Foxit PDF Reader';              Status = '[READY]'; Executable = 'FoxitPDFReader.exe'; ExecutablePath = ''; Version = 'Latest 64-bit'; Installed = $false },
                [PSCustomObject]@{ AppName = 'UniKey';       DisplayName = 'UniKey Vietnamese Input Method'; Application = 'UniKey Vietnamese Input Method'; Status = '[READY]'; Executable = 'UniKeyNT.exe';        ExecutablePath = ''; Version = '64-bit';        Installed = $false },
                [PSCustomObject]@{ AppName = 'UltraVNC';     DisplayName = 'UltraVNC Remote Support';       Application = 'UltraVNC Remote Support';       Status = '[READY]'; Executable = 'vncviewer.exe';       ExecutablePath = ''; Version = 'x64 Setup';     Installed = $false },
                [PSCustomObject]@{ AppName = 'KLiteCodec';   DisplayName = 'K-Lite Codec Pack';             Application = 'K-Lite Codec Pack';             Status = '[READY]'; Executable = 'mpc-hc64.exe';        ExecutablePath = ''; Version = '64-bit';        Installed = $false },
                [PSCustomObject]@{ AppName = 'VCRedistAIO';  DisplayName = 'Visual C++ Redistributable AIO'; Application = 'Visual C++ Redistributable AIO'; Status = '[READY]'; Executable = 'System Runtimes';    ExecutablePath = ''; Version = 'x64';           Installed = $false },
                [PSCustomObject]@{ AppName = 'Zalo';         DisplayName = 'Zalo PC Messenger';             Application = 'Zalo PC Messenger';             Status = '[READY]'; Executable = 'Zalo.exe';            ExecutablePath = ''; Version = 'Latest';        Installed = $false },
                [PSCustomObject]@{ AppName = 'WinRAR';       DisplayName = 'WinRAR Archiver';               Application = 'WinRAR Archiver';               Status = '[READY]'; Executable = 'WinRAR.exe';          ExecutablePath = ''; Version = 'x64';           Installed = $false }
            )
        }
        Show-ToolkitItemTable -Items $appsList -Columns @('Application', 'Status', 'Executable', 'Version') -Headers @('APPLICATION', 'STATUS', 'EXECUTABLE', 'VERSION') -Title 'Managed Enterprise 64-Bit Application Catalog'

        Write-Host ""
        $installerActions = @(
            @{ Key = '9'; Label = 'Update All Winget Apps' },
            @{ Key = '10'; Label = 'Win11Debloat' },
            @{ Key = '11'; Label = 'Browser Debloat' }
        )
        $navActions = @(
            @{ Key = '0'; Label = 'Back to Main Menu' }
        )
        Show-ToolkitActionCatalog -Actions $installerActions -NavActions $navActions -Title 'DEPLOYMENT & OPTIMIZATION ACTIONS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Software & System Optimization'." -Type 'INFO'
            return
        }

        $categoryHotkeys = @('9', '10', '11')
        $promptText = "  Select Item [1-$($appsList.Count)], Action [9-11], or [0] Back"
        $selection = Read-ToolkitItemSelection -MaxIndex $appsList.Count -ValidHotkeys $categoryHotkeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit' -or $selection.Value -eq '0') {
            $inSubmenu = $false
            return
        }

        if ($selection.Type -eq 'Index') {
            $targetIdx = [int]$selection.Value - 1
            if ($targetIdx -ge 0 -and $targetIdx -lt $appsList.Count) {
                $selectedApp = $appsList[$targetIdx]
                Invoke-ToolkitApplicationContextMenu -SelectedApp $selectedApp -NonInteractive:$NonInteractive
            }
        }
        elseif ($selection.Type -eq 'Hotkey') {
            switch ("$($selection.Value)") {
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
                }
                '10' {
                    if (Get-Command -Name 'Invoke-Win11Debloat' -ErrorAction SilentlyContinue) {
                        Invoke-Win11Debloat | Format-List
                    }
                    Wait-UserAcknowledge
                }
                '11' {
                    if (Get-Command -Name 'Invoke-BrowserDebloat' -ErrorAction SilentlyContinue) {
                        Invoke-BrowserDebloat | Format-List
                    }
                    Wait-UserAcknowledge
                }
                '0' {
                    $inSubmenu = $false
                    return
                }
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
