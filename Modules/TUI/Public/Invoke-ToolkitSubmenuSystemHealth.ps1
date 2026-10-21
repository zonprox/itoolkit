if (-not (Get-Command -Name 'Wait-UserAcknowledge' -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot '../Private/Wait-UserAcknowledge.ps1'
    if (Test-Path $waitScript) {
        . $waitScript
    }
}
if (-not (Get-Command -Name 'Confirm-ToolkitAction' -ErrorAction SilentlyContinue)) {
    $confirmScript = Join-Path $PSScriptRoot '../Private/Confirm-ToolkitAction.ps1'
    if (Test-Path $confirmScript) {
        . $confirmScript
    }
}

if (-not (Get-Command -Name 'Enter-ToolkitTuiMode' -ErrorAction SilentlyContinue)) {
    $coreTui = Join-Path $PSScriptRoot '../../Core/Public/Enter-ToolkitTuiMode.ps1'
    if (Test-Path -LiteralPath $coreTui) { . $coreTui }
}

if (-not (Get-Command -Name 'Exit-ToolkitTuiMode' -ErrorAction SilentlyContinue)) {
    $coreExit = Join-Path $PSScriptRoot '../../Core/Public/Exit-ToolkitTuiMode.ps1'
    if (Test-Path -LiteralPath $coreExit) { . $coreExit }
}


function Get-SystemHealthContextInfoLines {
    [CmdletBinding()]
    param()

    $lines = [System.Collections.Generic.List[string]]::new()
    $telemetry = Get-ToolkitTelemetryData
    $lines.Add("OS & Build     : $($telemetry.OSDisplay) | $($telemetry.Architecture)")

    $adminStr = "Standard User [WARN: Non-Elevated]"
    if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
        try {
            if (Test-IsAdmin) {
                $adminStr = "Administrator [ELEVATED - Full Access]"
            }
        }
        catch { $null = $_ }
    }
    $lines.Add("Elevation State: $adminStr")

    $sysDir = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
    $lines.Add("System Root    : $sysDir | Component Store [ONLINE]")
    $lines.Add("Storage Space  : $($telemetry.StorageDisplay)")
    $lines.Add("Health Engines : SFC, DISM, Windows Update, WMI, WinSxS, Disk Cleanup [READY]")

    return $lines.ToArray()
}

function Get-WindowsRepairContextInfoLines {
    [CmdletBinding()]
    param()
    return Get-SystemHealthContextInfoLines
}

function Get-WindowsCleanupContextInfoLines {
    [CmdletBinding()]
    param()
    return Get-SystemHealthContextInfoLines
}

if (Get-Command -Name 'Get-SystemHealthContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-SystemHealthContextInfoLines' -Value (Get-Command -Name 'Get-SystemHealthContextInfoLines').ScriptBlock
}
if (Get-Command -Name 'Get-WindowsRepairContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-WindowsRepairContextInfoLines' -Value (Get-Command -Name 'Get-WindowsRepairContextInfoLines').ScriptBlock
}
if (Get-Command -Name 'Get-WindowsCleanupContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-WindowsCleanupContextInfoLines' -Value (Get-Command -Name 'Get-WindowsCleanupContextInfoLines').ScriptBlock
}

function Invoke-ToolkitSubmenuSystemHealth {
<#
.SYNOPSIS
    Submenu for System Health & Maintenance (Windows Repair & Disk Cleanup).
.DESCRIPTION
    Combines diagnostic repair capabilities and non-destructive disk and cache cleanup:
    - System File Checker (sfc /scannow)
    - DISM Component Store (/RestoreHealth)
    - Windows Update services reset
    - WMI repository salvage
    - Component Store (WinSxS) cleanup
    - Safe system temp & logs cleanup
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

    if (Get-Command -Name 'Enter-ToolkitTuiMode' -ErrorAction SilentlyContinue) {
        Enter-ToolkitTuiMode
    }
    try {
        if ($ExitImmediately) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Submenu launched with -ExitImmediately flag. Returning." -Level INFO -Component 'TUI' -NoConsole
            }
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
        $healthInfo = Get-SystemHealthContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > SYSTEM HEALTH & MAINTENANCE' -Subtitle 'Unified Windows Repair, Integrity Scans, Servicing & Storage Cleanup' -ClearScreen:$clear -InfoLines $healthInfo

        $isAdmin = $true
        if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
            try {
                $isAdmin = Test-IsAdmin
            }
            catch {
                $isAdmin = $false
            }
        }
        if (-not $isAdmin) {
            Write-ToolkitStatus -Message "ELEVATION WARNING: Administrative privileges required. Run as Administrator for system repairs." -Type 'WARN'
        }

        $healthActions = @(
            @{ Key = '1'; Label = 'Automated DISM + SFC Repair'; Description = 'Sequential component store recovery and protected system file verification' },
            @{ Key = '2'; Label = 'SFC Integrity Scan'; Description = 'Verify protected Windows system files using sfc /scannow' },
            @{ Key = '3'; Label = 'DISM RestoreHealth'; Description = 'Repair component store corruption via DISM online image servicing' },
            @{ Key = '4'; Label = 'Reset Windows Update'; Description = 'Reset update components, stop services, and purge download cache' },
            @{ Key = '5'; Label = 'Repair WMI Repository'; Description = 'Verify consistency and salvage corrupted WMI repository' },
            @{ Key = '6'; Label = 'Unified Storage Cleanup'; Description = 'Purge temporary caches, memory dumps, and superseded WinSxS packages' }
        )
        $navActions = @(
            @{ Key = '0'; Label = 'Back to Main Menu'; Description = 'Return to the primary IToolkit console' }
        )
        Show-ToolkitActionCatalog -Actions $healthActions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Non-interactive category listing complete for 'System Health & Maintenance'." -Level INFO -Component 'TUI' -NoConsole
            }
            Write-Host "Non-interactive category listing complete for 'System Health & Maintenance'." -ForegroundColor Cyan
            return
        }

        $validKeys = @('1', '2', '3', '4', '5', '6', '0')
        $promptText = "  Select action [1-6, 0]"
        $selection = Read-ToolkitItemSelection -MaxIndex 0 -ValidHotkeys $validKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit' -or $selection.Value -eq '0') {
            return
        }

        $actionKey = "$($selection.Value)"

        switch ($actionKey) {
            '1' {
                try {
                    Write-ToolkitStatus -Message "Initiating automated comprehensive system repair (DISM + SFC)..." -Type 'INFO'
                    if (Get-Command -Name 'Invoke-WindowsDismRepair' -ErrorAction SilentlyContinue) {
                        Write-ToolkitStatus -Message "Phase 1/2: Repairing component store via DISM /RestoreHealth..." -Type 'INFO'
                        $dismRes = Invoke-WindowsDismRepair
                        if ($dismRes -and $dismRes.Success) {
                            Write-ToolkitStatus -Message "DISM repair completed successfully: $($dismRes.Status)." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "DISM repair notice: $($dismRes.ErrorMessage)." -Type 'WARN'
                        }
                    }
                    if (Get-Command -Name 'Invoke-WindowsSfcScan' -ErrorAction SilentlyContinue) {
                        Write-ToolkitStatus -Message "Phase 2/2: Verifying protected system files via SFC /scannow..." -Type 'INFO'
                        $sfcRes = Invoke-WindowsSfcScan
                        if ($sfcRes -and $sfcRes.Success) {
                            Write-ToolkitStatus -Message "SFC scan completed successfully: $($sfcRes.Status)." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "SFC scan notice: $($sfcRes.ErrorMessage)." -Type 'WARN'
                        }
                    }
                    Write-ToolkitStatus -Message "Comprehensive system repair complete." -Type 'OK'
                }
                catch {
                    Write-ToolkitStatus -Message "System repair failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '2' {
                try {
                    Write-ToolkitStatus -Message "Starting SFC integrity scan..." -Type 'INFO'
                    if (Get-Command -Name 'Invoke-WindowsSfcScan' -ErrorAction SilentlyContinue) {
                        $sfcRes = Invoke-WindowsSfcScan
                        if ($sfcRes -and $sfcRes.Success) {
                            Write-ToolkitStatus -Message "SFC scan completed: $($sfcRes.Status)." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "SFC scan notice: $($sfcRes.ErrorMessage)." -Type 'WARN'
                        }
                    }
                }
                catch {
                    Write-ToolkitStatus -Message "SFC scan failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '3' {
                try {
                    Write-ToolkitStatus -Message "Starting DISM RestoreHealth operation..." -Type 'INFO'
                    if (Get-Command -Name 'Invoke-WindowsDismRepair' -ErrorAction SilentlyContinue) {
                        $dismRes = Invoke-WindowsDismRepair -Mode 'RestoreHealth'
                        if ($dismRes -and $dismRes.Success) {
                            Write-ToolkitStatus -Message "DISM repair completed: $($dismRes.Status)." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "DISM repair notice: $($dismRes.ErrorMessage)." -Type 'WARN'
                        }
                    }
                }
                catch {
                    Write-ToolkitStatus -Message "DISM repair failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '4' {
                try {
                    Write-ToolkitStatus -Message "Resetting Windows Update components..." -Type 'INFO'
                    if (Get-Command -Name 'Reset-WindowsUpdateComponents' -ErrorAction SilentlyContinue) {
                        $wuRes = Reset-WindowsUpdateComponents
                        if ($wuRes -and $wuRes.Success) {
                            Write-ToolkitStatus -Message "Windows Update reset completed." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "Windows Update reset returned warnings." -Type 'WARN'
                        }
                    }
                }
                catch {
                    Write-ToolkitStatus -Message "Windows Update reset failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '5' {
                try {
                    Write-ToolkitStatus -Message "Repairing WMI repository..." -Type 'INFO'
                    if (Get-Command -Name 'Repair-WmiRepository' -ErrorAction SilentlyContinue) {
                        $wmiRes = Repair-WmiRepository -Action 'Salvage'
                        if ($wmiRes -and $wmiRes.Success) {
                            Write-ToolkitStatus -Message "WMI repository salvage completed: $($wmiRes.Status)." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "WMI repository salvage notice: $($wmiRes.ErrorMessage)." -Type 'WARN'
                        }
                    }
                }
                catch {
                    Write-ToolkitStatus -Message "WMI repository repair failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '6' {
                try {
                    Write-ToolkitStatus -Message "Executing unified storage cleanup..." -Type 'INFO'
                    if (Get-Command -Name 'Invoke-WindowsCleanup' -ErrorAction SilentlyContinue) {
                        $cleanRes = Invoke-WindowsCleanup -Category @('All') -All
                        if ($cleanRes -and $cleanRes.Success) {
                            Write-ToolkitStatus -Message "Unified storage cleanup completed. Reclaimed: $($cleanRes.ReclaimedBytes) bytes." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "Unified storage cleanup completed with warnings." -Type 'WARN'
                        }
                    }
                }
                catch {
                    Write-ToolkitStatus -Message "Unified storage cleanup failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '7' {
                # Legacy alias: Clean Component Store -> Invoke-WindowsCleanup
                try {
                    Write-ToolkitStatus -Message "Executing storage cleanup for Component Store..." -Type 'INFO'
                    if (Get-Command -Name 'Invoke-WindowsCleanup' -ErrorAction SilentlyContinue) {
                        $cleanRes = Invoke-WindowsCleanup -Category @('All') -All
                        if ($cleanRes -and $cleanRes.Success) {
                            Write-ToolkitStatus -Message "Storage cleanup completed. Reclaimed: $($cleanRes.ReclaimedBytes) bytes." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "Storage cleanup completed with warnings." -Type 'WARN'
                        }
                    }
                }
                catch {
                    Write-ToolkitStatus -Message "Storage cleanup failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '8' {
                # Legacy alias: Quick Disk Cleanup -> Invoke-WindowsCleanup
                try {
                    Write-ToolkitStatus -Message "Executing master system disk cleanup..." -Type 'INFO'
                    if (Get-Command -Name 'Invoke-WindowsCleanup' -ErrorAction SilentlyContinue) {
                        $cleanRes = Invoke-WindowsCleanup -Category @('All') -All
                        if ($cleanRes -and $cleanRes.Success) {
                            Write-ToolkitStatus -Message "System disk cleanup completed. Reclaimed: $($cleanRes.ReclaimedBytes) bytes." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "System disk cleanup completed with warnings." -Type 'WARN'
                        }
                    }
                }
                catch {
                    Write-ToolkitStatus -Message "System disk cleanup failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '9' {
                # Legacy alias: Clear Temp & System Logs -> Invoke-WindowsCleanup
                try {
                    Write-ToolkitStatus -Message "Executing master system disk cleanup..." -Type 'INFO'
                    if (Get-Command -Name 'Invoke-WindowsCleanup' -ErrorAction SilentlyContinue) {
                        $cleanRes = Invoke-WindowsCleanup -Category @('All') -All
                        if ($cleanRes -and $cleanRes.Success) {
                            Write-ToolkitStatus -Message "System disk cleanup completed. Reclaimed: $($cleanRes.ReclaimedBytes) bytes." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "System disk cleanup completed with warnings." -Type 'WARN'
                        }
                    }
                    if (Get-Command -Name 'Clear-WindowsTempCache' -ErrorAction SilentlyContinue) {
                        Clear-WindowsTempCache
                    }
                    if (Get-Command -Name 'Clear-WindowsSystemLogs' -ErrorAction SilentlyContinue) {
                        Clear-WindowsSystemLogs
                    }
                }
                catch {
                    Write-ToolkitStatus -Message "Clear temp & logs failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '0' { return }
        }
    }
}
finally {
    if (Get-Command -Name 'Exit-ToolkitTuiMode' -ErrorAction SilentlyContinue) {
        Exit-ToolkitTuiMode
    }
}
}


function Invoke-ToolkitSubmenuWindowsRepair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][switch]$ExitImmediately,
        [Parameter(Mandatory = $false)][switch]$NonInteractive,
        [Parameter(Mandatory = $false)][int]$MenuDepth = 1
    )
    Invoke-ToolkitSubmenuSystemHealth @PSBoundParameters
}

function Invoke-ToolkitSubmenuWindowsCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][switch]$ExitImmediately,
        [Parameter(Mandatory = $false)][switch]$NonInteractive,
        [Parameter(Mandatory = $false)][int]$MenuDepth = 1
    )
    Invoke-ToolkitSubmenuSystemHealth @PSBoundParameters
}

if (Get-Command -Name 'Invoke-ToolkitSubmenuSystemHealth' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuSystemHealth' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuSystemHealth').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuWindowsRepair' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuWindowsRepair' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuWindowsRepair').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuWindowsCleanup' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuWindowsCleanup' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuWindowsCleanup').ScriptBlock
}
