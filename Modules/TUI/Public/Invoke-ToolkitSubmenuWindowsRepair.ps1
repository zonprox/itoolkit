if (-not (Get-Command -Name Wait-UserAcknowledge -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot ../Private/Wait-UserAcknowledge.ps1
    if (Test-Path $waitScript) {
        . $waitScript
    }
}

function Get-WindowsRepairContextInfoLines {
    [CmdletBinding()]
    param()

    $lines = [System.Collections.Generic.List[string]]::new()

    # 1. OS & Architecture
    $telemetry = Get-ToolkitTelemetryData
    $lines.Add("OS & Build     : $($telemetry.OSDisplay) | $($telemetry.Architecture)")

    # 2. Elevation Status
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

    # 3. Component Store & System Root
    $sysDir = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
    $lines.Add("System Root    : $sysDir | Component Store [ONLINE]")

    # 4. Repair Subsystems
    $lines.Add("Repair Tools   : SFC, DISM, Windows Update, Network Stack, WMI [READY]")

    return $lines.ToArray()
}

if (Get-Command -Name 'Get-WindowsRepairContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-WindowsRepairContextInfoLines' -Value (Get-Command -Name 'Get-WindowsRepairContextInfoLines').ScriptBlock
}

function Invoke-ToolkitSubmenuWindowsRepair {
<#
.SYNOPSIS
    Submenu for Windows System Repair & Maintenance with Tri-Panel / Action Catalog UI/UX.
.DESCRIPTION
    Presents diagnostic repair capabilities for System File Checker (sfc /scannow),
    DISM Component Store (/RestoreHealth), Windows Update components reset,
    network stack (Winsock/TCP-IP/DNS) reset, and WMI repository salvage.
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
        if (Test-Path $catScript) {
            . $catScript
        }
    }
    if (-not (Get-Command -Name 'Show-ToolkitItemTable' -ErrorAction SilentlyContinue)) {
        $tableScript = Join-Path $PSScriptRoot 'Show-ToolkitItemTable.ps1'
        if (Test-Path $tableScript) {
            . $tableScript
        }
    }
    if (-not (Get-Command -Name 'Read-ToolkitItemSelection' -ErrorAction SilentlyContinue)) {
        $selectScript = Join-Path $PSScriptRoot 'Read-ToolkitItemSelection.ps1'
        if (Test-Path $selectScript) {
            . $selectScript
        }
    }

    $inSubmenu = $true
    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $repairInfo = Get-WindowsRepairContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > WINDOWS SYSTEM REPAIR & MAINTENANCE' -Subtitle 'SFC Integrity, DISM Component Store, Windows Update & Network Stack' -ClearScreen:$clear -InfoLines $repairInfo

        # Elevation warning banner if Test-IsAdmin returns false
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

        # Item-centric summary of repair subsystems
        $repairItems = @(
            [PSCustomObject]@{ Component = 'System File Checker (SFC)'; Status = '[READY]'; Action = 'sfc /scannow'; Details = 'Integrity scan & repair of protected system files' },
            [PSCustomObject]@{ Component = 'DISM Component Store'; Status = '[READY]'; Action = 'DISM /RestoreHealth'; Details = 'Windows component store repair via online/cleanup' },
            [PSCustomObject]@{ Component = 'Windows Update Services'; Status = '[READY]'; Action = 'Reset-WindowsUpdate'; Details = 'Reset update services & clear SoftwareDistribution' },
            [PSCustomObject]@{ Component = 'Network & Winsock Stack'; Status = '[READY]'; Action = 'Reset-NetworkStack'; Details = 'Reset Winsock, TCP/IP stack, and flush DNS cache' },
            [PSCustomObject]@{ Component = 'WMI Repository'; Status = '[READY]'; Action = 'Repair-WmiRepository'; Details = 'Verify and salvage corrupted WMI repository' }
        )
        Show-ToolkitItemTable -Items $repairItems -Columns @('Component', 'Status', 'Action', 'Details') -Headers @('COMPONENT', 'STATUS', 'ACTION', 'DETAILS') -Title 'Windows Repair Subsystems'

        Write-Host ""
        $repairActions = @(
            @{ Key = 'S'; Label = 'SFC Scan' },
            @{ Key = 'D'; Label = 'DISM RestoreHealth' },
            @{ Key = 'W'; Label = 'Reset Windows Update' },
            @{ Key = 'N'; Label = 'Reset Network Stack' },
            @{ Key = 'R'; Label = 'Repair WMI Repository' }
        )
        $navActions = @(
            @{ Key = 'B'; Label = 'Back to Main Menu' },
            @{ Key = 'Q'; Label = 'Quit' }
        )
        Show-ToolkitActionCatalog -Actions $repairActions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Windows System Repair & Maintenance'." -Type 'INFO'
            return
        }

        $validKeys = @('S', 'D', 'W', 'N', 'R', 'B', 'Q')
        $promptText = "  Select item [1-$($repairItems.Count)] or action [S, D, W, N, R, B, Q]"
        $selection = Read-ToolkitItemSelection -MaxIndex $repairItems.Count -ValidHotkeys $validKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit') {
            return
        }

        $actionKey = ''
        if ($selection.Type -eq 'Hotkey') {
            $actionKey = $selection.Value.ToString().ToUpperInvariant()
        }
        elseif ($selection.Type -eq 'Index') {
            switch ($selection.Value) {
                1 { $actionKey = 'S' }
                2 { $actionKey = 'D' }
                3 { $actionKey = 'W' }
                4 { $actionKey = 'N' }
                5 { $actionKey = 'R' }
            }
        }

        switch ($actionKey) {
            'B' {
                return
            }
            'Q' {
                return
            }
            'S' {
                if (Get-Command -Name 'Invoke-WindowsSfcScan' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Executing System File Checker scan (sfc /scannow)..." -Type 'INFO'
                        $sfcResult = Invoke-WindowsSfcScan
                        if ($sfcResult -and $sfcResult.Success) {
                            Write-ToolkitStatus -Message "SFC scan completed successfully: $($sfcResult.Status)." -Type 'OK'
                        }
                        else {
                            $statMsg = if ($sfcResult) { $sfcResult.Status } else { 'Scan completed' }
                            Write-ToolkitStatus -Message "SFC scan finished with notice: $statMsg." -Type 'WARN'
                        }
                    }
                    catch {
                        Write-ToolkitStatus -Message "SFC scan error: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                else {
                    Write-ToolkitStatus -Message "Invoke-WindowsSfcScan command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            'D' {
                if (Get-Command -Name 'Invoke-WindowsDismRepair' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Executing DISM RestoreHealth repair..." -Type 'INFO'
                        $dismResult = Invoke-WindowsDismRepair -Mode 'RestoreHealth'
                        if ($dismResult -and $dismResult.Success) {
                            Write-ToolkitStatus -Message "DISM RestoreHealth completed successfully: $($dismResult.Status)." -Type 'OK'
                        }
                        else {
                            $dismMsg = if ($dismResult) { $dismResult.Status } else { 'Repair completed' }
                            Write-ToolkitStatus -Message "DISM repair finished with notice: $dismMsg." -Type 'WARN'
                        }
                    }
                    catch {
                        Write-ToolkitStatus -Message "DISM repair error: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                else {
                    Write-ToolkitStatus -Message "Invoke-WindowsDismRepair command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            'W' {
                if (Get-Command -Name 'Reset-WindowsUpdateComponents' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Resetting Windows Update components and cache..." -Type 'INFO'
                        $wuResult = Reset-WindowsUpdateComponents
                        if ($wuResult -and $wuResult.Success) {
                            Write-ToolkitStatus -Message "Windows Update components reset successfully." -Type 'OK'
                        }
                        else {
                            Write-ToolkitStatus -Message "Windows Update reset finished with warnings." -Type 'WARN'
                        }
                    }
                    catch {
                        Write-ToolkitStatus -Message "Windows Update reset error: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                else {
                    Write-ToolkitStatus -Message "Reset-WindowsUpdateComponents command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            'N' {
                if (Get-Command -Name 'Reset-NetworkStack' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Resetting network sockets, IP stack, and DNS cache..." -Type 'INFO'
                        $netResult = Reset-NetworkStack
                        if ($netResult -and $netResult.Success) {
                            Write-ToolkitStatus -Message "Network stack reset successfully." -Type 'OK'
                        }
                        else {
                            Write-ToolkitStatus -Message "Network stack reset finished with warnings." -Type 'WARN'
                        }
                    }
                    catch {
                        Write-ToolkitStatus -Message "Network stack reset error: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                else {
                    Write-ToolkitStatus -Message "Reset-NetworkStack command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            'R' {
                if (Get-Command -Name 'Repair-WmiRepository' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Salvaging and repairing WMI repository..." -Type 'INFO'
                        $wmiResult = Repair-WmiRepository -Action 'Salvage'
                        if ($wmiResult -and $wmiResult.Success) {
                            Write-ToolkitStatus -Message "WMI repository salvage completed successfully: $($wmiResult.Status)." -Type 'OK'
                        }
                        else {
                            $wmiMsg = if ($wmiResult) { $wmiResult.Status } else { 'Salvage notice' }
                            Write-ToolkitStatus -Message "WMI repository salvage finished with notice: $wmiMsg." -Type 'WARN'
                        }
                    }
                    catch {
                        Write-ToolkitStatus -Message "WMI repair error: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                else {
                    Write-ToolkitStatus -Message "Repair-WmiRepository command not available." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
        }
    }
}

if (Get-Command -Name Get-WindowsRepairContextInfoLines -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path function:global:Get-WindowsRepairContextInfoLines -Value (Get-Command -Name Get-WindowsRepairContextInfoLines).ScriptBlock
}
if (Get-Command -Name Invoke-ToolkitSubmenuWindowsRepair -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path function:global:Invoke-ToolkitSubmenuWindowsRepair -Value (Get-Command -Name Invoke-ToolkitSubmenuWindowsRepair).ScriptBlock
}

