if (-not (Get-Command -Name 'Wait-UserAcknowledge' -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot '../Private/Wait-UserAcknowledge.ps1'
    if (Test-Path $waitScript) {
        . $waitScript
    }
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

function Get-WindowsCleanupContextInfoLines {
    [CmdletBinding()]
    param()

    $lines = [System.Collections.Generic.List[string]]::new()

    # 1. Elevation & Privilege Status
    $adminStr = "Standard User [ELEVATION RECOMMENDED]"
    if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
        try {
            if (Test-IsAdmin) {
                $adminStr = "Administrator [ELEVATED - FULL ACCESS]"
            }
        }
        catch {
            $null = $_
        }
    }
    $lines.Add("Security & Env : $adminStr")

    # 2. System Drive Status
    $sysDriveDisplay = "System Drive   : N/A"
    try {
        $driveLetter = "C"
        if (-not [string]::IsNullOrWhiteSpace($env:SystemDrive)) {
            $driveLetter = $env:SystemDrive.TrimEnd(':')
        }
        $drive = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
        if ($drive -and $drive.Free -and $drive.Used) {
            $freeGB = [math]::Round($drive.Free / 1GB, 1)
            $totalGB = [math]::Round(($drive.Free + $drive.Used) / 1GB, 1)
            $pctFree = [math]::Round(($drive.Free / ($drive.Free + $drive.Used)) * 100, 1)
            $badge = if ($pctFree -lt 15) { "[WARN]" } else { "[READY]" }
            $sysDriveDisplay = "System Drive ($($driveLetter):) : $freeGB GB Free of $totalGB GB ($pctFree% free) $badge"
        }
        elseif ($drive -and $drive.Free) {
            $freeGB = [math]::Round($drive.Free / 1GB, 1)
            $sysDriveDisplay = "System Drive ($($driveLetter):) : $freeGB GB Free [READY]"
        }
    }
    catch {
        $null = $_
    }
    $lines.Add($sysDriveDisplay)

    # 3. Servicing Build
    $buildDisplay = "Windows Servicing : Native DISM Servicing Stack [ONLINE]"
    if (Get-Command -Name 'Get-ToolkitTelemetryData' -ErrorAction SilentlyContinue) {
        try {
            $telem = Get-ToolkitTelemetryData
            if ($telem -and $telem.OSDisplay) {
                $buildDisplay = "OS & Servicing    : $($telem.OSDisplay) | DISM [ONLINE]"
            }
        }
        catch {
            $null = $_
        }
    }
    $lines.Add($buildDisplay)

    # 4. Engine & Invariants
    $lines.Add("Cleanup Engine : Non-Destructive Servicing & Safe Temp Purge [READY]")

    return $lines.ToArray()
}

function Format-ToolkitCleanupSize {
    param([int64]$Bytes)
    if ($Bytes -le 0) { return "0 B" }
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $order = 0
    $len = [double]$Bytes
    while ($len -ge 1024.0 -and $order -lt ($units.Count - 1)) {
        $order++
        $len = $len / 1024.0
    }
    if ($order -eq 0) { return "{0:N0} {1}" -f $len, $units[$order] }
    return "{0:N2} {1}" -f $len, $units[$order]
}

function Invoke-ToolkitSubmenuWindowsCleanup {
<#
.SYNOPSIS
    Submenu for Deep & Safe Windows 10/11 System Disk and Cache Cleanup.
.DESCRIPTION
    Presents enterprise-grade, non-destructive disk and cache cleanup capabilities:
    - Component Store (WinSxS) via DISM StartComponentCleanup (optional /ResetBase)
    - Windows Update Download Cache (SoftwareDistribution\Download) with service lifecycle
    - Delivery Optimization peer-to-peer cache
    - System Logs, WER crash dumps, memory dumps, and CBS logs
    - Safe system and user temporary file caches (skipping active files < 24h and locked files)
    Supports dry-run preview mode (-WhatIf space estimation) and elevation warnings.
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

    $whatIfMode = $true
    $inSubmenu = $true

    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $cleanupInfo = Get-WindowsCleanupContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > WINDOWS DISK & CACHE CLEANUP' -Subtitle 'Safe Enterprise Disk Space Recovery & Servicing Cache Purge' -ClearScreen:$clear -InfoLines $cleanupInfo

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
            Write-ToolkitStatus -Message "ELEVATION WARNING: Administrative privileges recommended for full system cleanup." -Type 'WARN'
        }

        # Item-centric table for the 5 subsystems
        $cleanupItems = @(
            [PSCustomObject]@{ Subsystem = 'Component Store (WinSxS)'; Status = '[READY]'; Scope = 'DISM /StartComponentCleanup'; Safety = '[SAFE]' },
            [PSCustomObject]@{ Subsystem = 'Windows Update Cache'; Status = '[READY]'; Scope = 'SoftwareDistribution\Download'; Safety = '[SAFE]' },
            [PSCustomObject]@{ Subsystem = 'Delivery Optimization'; Status = '[READY]'; Scope = 'Delivery Optimization Cache'; Safety = '[SAFE]' },
            [PSCustomObject]@{ Subsystem = 'System Logs & Dumps'; Status = '[READY]'; Scope = 'WER Dumps, Minidumps, CBS Logs'; Safety = '[SAFE]' },
            [PSCustomObject]@{ Subsystem = 'Temporary Files'; Status = '[READY]'; Scope = 'System & User Temp (Age > 24h)'; Safety = '[SAFE]' }
        )
        Show-ToolkitItemTable -Items $cleanupItems -Columns @('Subsystem', 'Status', 'Scope', 'Safety') -Headers @('SUBSYSTEM', 'STATUS', 'SCOPE / METHOD', 'SAFETY LEVEL') -Title 'Windows Cleanup & Maintenance Subsystems'

        Write-Host ""
        $modeLabel = if ($whatIfMode) { 'Toggle WhatIf [WHATIF: ON]' } else { 'Toggle WhatIf [LIVE: ACTIVE]' }
        $cleanupActions = @(
            @{ Key = 'W'; Label = $modeLabel },
            @{ Key = 'A'; Label = 'Quick Clean All' },
            @{ Key = 'R'; Label = 'ResetBase Component Store' },
            @{ Key = 'D'; Label = 'Refresh Space Estimates' }
        )
        $navActions = @(
            @{ Key = 'B'; Label = 'Back to Main Menu' },
            @{ Key = 'Q'; Label = 'Quit' }
        )
        Show-ToolkitActionCatalog -Actions $cleanupActions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Windows Disk & Cache Cleanup'." -Type 'INFO'
            return
        }

        $validKeys = @('W', 'A', 'R', 'D', 'B', 'Q')
        $promptText = "  Select subsystem [1-$($cleanupItems.Count)] or action [W, A, R, D, B, Q]"
        $selection = Read-ToolkitItemSelection -MaxIndex $cleanupItems.Count -ValidHotkeys $validKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit') {
            return
        }

        $actionKey = ''
        $selectedSubsystemIndex = 0

        if ($selection.Type -eq 'Hotkey') {
            $actionKey = $selection.Value.ToString().ToUpperInvariant()
        }
        elseif ($selection.Type -eq 'Index') {
            $selectedSubsystemIndex = [int]$selection.Value
        }

        # Handle top-level actions
        if (-not [string]::IsNullOrWhiteSpace($actionKey)) {
            switch ($actionKey) {
                'B' {
                    return
                }
                'Q' {
                    return
                }
                'W' {
                    $whatIfMode = -not $whatIfMode
                    if ($whatIfMode) {
                        Write-ToolkitStatus -Message "WhatIf / Dry-Run mode enabled: Operations will estimate space without deleting files." -Type 'INFO'
                    }
                    else {
                        Write-ToolkitStatus -Message "LIVE EXECUTION MODE ENABLED: Cleanup actions will delete files." -Type 'WARN'
                    }
                    Start-Sleep -Milliseconds 800
                    continue
                }
                'A' {
                    # Quick Clean All
                    Write-Host ""
                    if ($whatIfMode) {
                        Write-ToolkitStatus -Message "Running Quick Clean All in WhatIf / Dry-Run mode..." -Type 'INFO'
                    }
                    else {
                        Write-ToolkitStatus -Message "Executing Quick Clean All (Live Execution)..." -Type 'INFO'
                    }

                    if (Get-Command -Name 'Invoke-WindowsCleanup' -ErrorAction SilentlyContinue) {
                        try {
                            $res = if ($whatIfMode) {
                                Invoke-WindowsCleanup -All -WhatIf
                            }
                            else {
                                Invoke-WindowsCleanup -All
                            }
                            if ($res) {
                                $reclaimedStr = Format-ToolkitCleanupSize -Bytes $res.ReclaimedBytes
                                $msgType = if ($res.Success) { 'OK' } else { 'WARN' }
                                Write-ToolkitStatus -Message "Quick Clean All completed ($($res.Status)). Space: $reclaimedStr, Items: $($res.ItemCount), Skipped: $($res.SkippedCount)." -Type $msgType
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "Quick Clean All encountered an error: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    else {
                        Write-ToolkitStatus -Message "Invoke-WindowsCleanup cmdlet not available." -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                    continue
                }
                'R' {
                    # ResetBase Component Store with safety warning
                    Write-Host ""
                    Write-ToolkitMenuDivider
                    Write-Host "  ==================== CRITICAL SAFETY WARNING ====================" -ForegroundColor Red
                    Write-Host "  Executing Component Store Cleanup with /ResetBase removes all" -ForegroundColor Yellow
                    Write-Host "  superseded component versions. Once completed, all currently" -ForegroundColor Yellow
                    Write-Host "  installed Windows updates become baseline and CANNOT be uninstalled!" -ForegroundColor Yellow
                    Write-Host "  ==================================================================" -ForegroundColor Red
                    Write-Host ""

                    $confirmed = $false
                    if ($whatIfMode) {
                        $confirmed = $true
                        Write-ToolkitStatus -Message "Dry-Run mode active: simulating ResetBase without permanent changes." -Type 'INFO'
                    }
                    else {
                        Write-Host "  Type 'YES' to confirm irreversible /ResetBase cleanup: " -NoNewline -ForegroundColor Yellow
                        try {
                            $userInput = Read-Host
                            if ($userInput -eq 'YES') {
                                $confirmed = $true
                            }
                        }
                        catch {
                            $confirmed = $false
                        }
                    }

                    if ($confirmed) {
                        if (Get-Command -Name 'Invoke-WindowsComponentCleanup' -ErrorAction SilentlyContinue) {
                            try {
                                Write-ToolkitStatus -Message "Executing DISM /StartComponentCleanup /ResetBase..." -Type 'INFO'
                                $res = if ($whatIfMode) {
                                    Invoke-WindowsComponentCleanup -ResetBase -WhatIf
                                }
                                else {
                                    Invoke-WindowsComponentCleanup -ResetBase
                                }
                                if ($res) {
                                    $msgType = if ($res.Success) { 'OK' } else { 'WARN' }
                                    Write-ToolkitStatus -Message "Component Store ResetBase completed ($($res.Status))." -Type $msgType
                                }
                            }
                            catch {
                                Write-ToolkitStatus -Message "ResetBase encountered an error: $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                        else {
                            Write-ToolkitStatus -Message "Invoke-WindowsComponentCleanup cmdlet not available." -Type 'WARN'
                        }
                    }
                    else {
                        Write-ToolkitStatus -Message "ResetBase operation cancelled by user." -Type 'INFO'
                    }
                    Wait-UserAcknowledge
                    continue
                }
                'D' {
                    # Refresh Space Estimates
                    Write-Host ""
                    Write-ToolkitStatus -Message "Refreshing space reclamation estimates across all subsystems (WhatIf)..." -Type 'INFO'
                    if (Get-Command -Name 'Invoke-WindowsCleanup' -ErrorAction SilentlyContinue) {
                        try {
                            $est = Invoke-WindowsCleanup -All -WhatIf
                            if ($est) {
                                $reclaimedStr = Format-ToolkitCleanupSize -Bytes $est.ReclaimedBytes
                                Write-ToolkitStatus -Message "Space Estimates: $reclaimedStr potentially reclaimable across $($est.ItemCount) items ($($est.SkippedCount) preserved)." -Type 'OK'
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "Space estimation failed: $($_.Exception.Message)" -Type 'WARN'
                        }
                    }
                    else {
                        Write-ToolkitStatus -Message "Invoke-WindowsCleanup cmdlet not available." -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                    continue
                }
            }
        }

        # Handle contextual item selection (indices 1..5)
        if ($selectedSubsystemIndex -gt 0) {
            Write-Host ""
            switch ($selectedSubsystemIndex) {
                1 {
                    # 1. Component Store (WinSxS)
                    Write-ToolkitStatus -Message "Processing Component Store (WinSxS) cleanup..." -Type 'INFO'
                    if (Get-Command -Name 'Invoke-WindowsComponentCleanup' -ErrorAction SilentlyContinue) {
                        try {
                            $res = if ($whatIfMode) {
                                Invoke-WindowsComponentCleanup -WhatIf
                            }
                            else {
                                Invoke-WindowsComponentCleanup
                            }
                            if ($res) {
                                $msgType = if ($res.Success) { 'OK' } else { 'WARN' }
                                Write-ToolkitStatus -Message "Component Store cleanup completed ($($res.Status))." -Type $msgType
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "Component Store cleanup failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    else {
                        Write-ToolkitStatus -Message "Invoke-WindowsComponentCleanup cmdlet not available." -Type 'WARN'
                    }
                }
                2 {
                    # 2. Windows Update Cache
                    Write-ToolkitStatus -Message "Processing Windows Update Cache purge..." -Type 'INFO'
                    if (Get-Command -Name 'Clear-WindowsUpdateCache' -ErrorAction SilentlyContinue) {
                        try {
                            $res = if ($whatIfMode) {
                                Clear-WindowsUpdateCache -WhatIf
                            }
                            else {
                                Clear-WindowsUpdateCache
                            }
                            if ($res) {
                                $spaceStr = Format-ToolkitCleanupSize -Bytes $res.ReclaimedBytes
                                $msgType = if ($res.Success) { 'OK' } else { 'WARN' }
                                Write-ToolkitStatus -Message "Windows Update Cache purge completed ($($res.Status)). Space: $spaceStr, Items: $($res.ItemCount)." -Type $msgType
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "Windows Update Cache purge failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    else {
                        Write-ToolkitStatus -Message "Clear-WindowsUpdateCache cmdlet not available." -Type 'WARN'
                    }
                }
                3 {
                    # 3. Delivery Optimization
                    Write-ToolkitStatus -Message "Processing Delivery Optimization Cache purge..." -Type 'INFO'
                    if (Get-Command -Name 'Clear-WindowsDeliveryOptimizationCache' -ErrorAction SilentlyContinue) {
                        try {
                            $res = if ($whatIfMode) {
                                Clear-WindowsDeliveryOptimizationCache -WhatIf
                            }
                            else {
                                Clear-WindowsDeliveryOptimizationCache
                            }
                            if ($res) {
                                $spaceStr = Format-ToolkitCleanupSize -Bytes $res.ReclaimedBytes
                                $msgType = if ($res.Success) { 'OK' } else { 'WARN' }
                                Write-ToolkitStatus -Message "Delivery Optimization Cache purge completed ($($res.Status)). Space: $spaceStr, Items: $($res.ItemCount)." -Type $msgType
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "Delivery Optimization Cache purge failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    else {
                        Write-ToolkitStatus -Message "Clear-WindowsDeliveryOptimizationCache cmdlet not available." -Type 'WARN'
                    }
                }
                4 {
                    # 4. System Logs & Dumps
                    Write-ToolkitStatus -Message "Processing System Logs & Crash Dumps purge..." -Type 'INFO'
                    if (Get-Command -Name 'Clear-WindowsSystemLogs' -ErrorAction SilentlyContinue) {
                        try {
                            $res = if ($whatIfMode) {
                                Clear-WindowsSystemLogs -WhatIf
                            }
                            else {
                                Clear-WindowsSystemLogs
                            }
                            if ($res) {
                                $spaceStr = Format-ToolkitCleanupSize -Bytes $res.ReclaimedBytes
                                $msgType = if ($res.Success) { 'OK' } else { 'WARN' }
                                Write-ToolkitStatus -Message "System Logs & Crash Dumps purge completed ($($res.Status)). Space: $spaceStr, Items: $($res.ItemCount)." -Type $msgType
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "System Logs & Crash Dumps purge failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    else {
                        Write-ToolkitStatus -Message "Clear-WindowsSystemLogs cmdlet not available." -Type 'WARN'
                    }
                }
                5 {
                    # 5. Temporary Files
                    Write-ToolkitStatus -Message "Processing Temporary Files & User Caches purge..." -Type 'INFO'
                    if (Get-Command -Name 'Clear-WindowsTempCache' -ErrorAction SilentlyContinue) {
                        try {
                            $res = if ($whatIfMode) {
                                Clear-WindowsTempCache -WhatIf
                            }
                            else {
                                Clear-WindowsTempCache
                            }
                            if ($res) {
                                $spaceStr = Format-ToolkitCleanupSize -Bytes $res.ReclaimedBytes
                                $msgType = if ($res.Success) { 'OK' } else { 'WARN' }
                                Write-ToolkitStatus -Message "Temporary Files purge completed ($($res.Status)). Space: $spaceStr, Items: $($res.ItemCount), Skipped: $($res.SkippedCount)." -Type $msgType
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "Temporary Files purge failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    else {
                        Write-ToolkitStatus -Message "Clear-WindowsTempCache cmdlet not available." -Type 'WARN'
                    }
                }
            }
            Wait-UserAcknowledge
        }
    }
}

if (Get-Command -Name 'Get-WindowsCleanupContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-WindowsCleanupContextInfoLines' -Value (Get-Command -Name 'Get-WindowsCleanupContextInfoLines').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuWindowsCleanup' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuWindowsCleanup' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuWindowsCleanup').ScriptBlock
}
