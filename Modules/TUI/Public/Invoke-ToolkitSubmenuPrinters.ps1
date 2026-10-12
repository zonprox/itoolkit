if (-not (Get-Command -Name Wait-UserAcknowledge -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot ../Private/Wait-UserAcknowledge.ps1
    if (Test-Path $waitScript) {
        . $waitScript
    }
}

function Get-PrintersContextInfoLines {
    $lines = [System.Collections.Generic.List[string]]::new()

    # 1. Spooler Service Status
    $spoolerStatus = "Spooler Service: Unknown [WARN]"
    try {
        $svc = Get-Service -Name 'Spooler' -ErrorAction SilentlyContinue
        if ($null -ne $svc) {
            $badge = if ($svc.Status -eq 'Running') { '[READY]' } else { '[FAIL]' }
            $spoolerStatus = "Spooler Service: $($svc.Status) (Startup: $($svc.StartType)) $badge"
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("Spooler Status : $spoolerStatus")

    # 2. Print Queue Jobs
    $queueInfo = "0 Pending Jobs in Spool Folder [CLEAN]"
    try {
        $spoolDir = "$env:SystemRoot\System32\spool\PRINTERS"
        if (Test-Path $spoolDir) {
            $shdFiles = Get-ChildItem -Path $spoolDir -Filter '*.SHD' -ErrorAction SilentlyContinue
            if ($null -ne $shdFiles -and $shdFiles.Count -gt 0) {
                $queueInfo = "$($shdFiles.Count) Stuck Job(s) Queued in Spool Directory [WARN]"
            }
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("Print Queue    : $queueInfo")

    # 3. Point & Print Policy
    $rpcPolicy = "Default / Unrestricted [WARN]"
    try {
        $regP = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint'
        if (Test-Path $regP) {
            $val = (Get-ItemProperty $regP -ErrorAction SilentlyContinue).RestrictDriverInstallationToAdministrators
            if ($val -eq 1) {
                $rpcPolicy = "StrictAdminOnly [SAFE]"
            }
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("RPC Policy     : $rpcPolicy")

    return $lines.ToArray()
}

function Invoke-ToolkitSubmenuPrinters {
<#
.SYNOPSIS
    Submenu for Network & Print Spooler with item-centric UI/UX.
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
        $rawPrinters = @()
        try {
            if (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
                $rawPrinters = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue)
            }
        }
        catch {
            Write-ToolkitStatus -Message "Failed to enumerate printers: $($_.Exception.Message)" -Type 'WARN'
        }

        $printers = @()
        foreach ($p in $rawPrinters) {
            if ($null -ne $p -and $p.PSObject.Properties['Name']) {
                $isOffline = [bool]$p.WorkOffline
                $statusBadge = '[READY]'
                if ($isOffline) {
                    $statusBadge = '[OFFLINE]'
                }
                elseif ($p.PrinterState -and $p.PrinterState -ne 0) {
                    $statusBadge = '[ERROR]'
                }
                elseif ($p.Status -and $p.Status -ne 'OK') {
                    $statusBadge = '[ERROR]'
                }

                $printers += [PSCustomObject]@{
                    Name   = [string]$p.Name
                    Status = $statusBadge
                    Driver = [string]$p.DriverName
                    Port   = [string]$p.PortName
                }
            }
        }

        $clear = if ($NonInteractive) { $false } else { $true }
        $printersInfo = Get-PrintersContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > PRINTERS & SPOOLER' -Subtitle 'Spooler Diagnostics, Queue Purge, Error Code Catalog, Point & Print' -ClearScreen:$clear -InfoLines $printersInfo

        Show-ToolkitItemTable -Items $printers -Columns @('Name', 'Status', 'Driver', 'Port') -Headers @('NAME', 'STATUS', 'DRIVER', 'PORT') -Title 'Installed Printers'

        Write-Host ""
        $topLevelActions = @(
            @{ Key = 'A'; Label = 'Apply All Server' },
            @{ Key = 'L'; Label = 'Apply All Client' },
            @{ Key = 'X'; Label = 'Apply All Both' },
            @{ Key = 'F'; Label = 'Fixes Catalog' },
            @{ Key = 'U'; Label = 'Rollback' },
            @{ Key = 'S'; Label = 'Spooler Restart & Purge' },
            @{ Key = 'R'; Label = 'Register DLLs' },
            @{ Key = 'P'; Label = 'Point & Print Remediation' },
            @{ Key = 'N'; Label = 'Reset Ne Ports' },
            @{ Key = 'C'; Label = 'Refresh Connections' }
        )
        $navActions = @(
            @{ Key = 'B'; Label = 'Back' },
            @{ Key = 'Q'; Label = 'Quit' }
        )
        Show-ToolkitActionCatalog -Actions $topLevelActions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Printers & Spooler Troubleshooting'." -Type 'INFO'
            return
        }

        $validKeys = @('A', 'L', 'X', 'F', 'U', 'S', 'R', 'P', 'N', 'C', 'B', 'Q')
        $promptText = if ($printers.Count -gt 0) { "  Select item [1-$($printers.Count)] or action" } else { "  Select action [A, L, X, F, U, S, R, P, N, C, B, Q]" }
        $selection = Read-ToolkitItemSelection -MaxIndex $printers.Count -ValidHotkeys $validKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit') {
            return
        }

        if ($selection.Type -eq 'Hotkey') {
            $hk = $selection.Value.ToString().ToUpperInvariant()
            switch ($hk) {
                'B' {
                    return
                }
                'Q' {
                    return
                }
                'A' {
                    if (Get-Command -Name 'Set-PrinterServerRemediation' -ErrorAction SilentlyContinue) {
                        try {
                            $res = Set-PrinterServerRemediation -All
                            if ($res -and $res.Success) {
                                Write-ToolkitStatus -Message "All server printer remediations applied successfully. Fixes: $($res.FixesApplied -join ', ')." -Type 'OK'
                            }
                            else {
                                Write-ToolkitStatus -Message "Server remediation completed with warnings." -Type 'WARN'
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to apply server remediations: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    else {
                        Write-ToolkitStatus -Message "Set-PrinterServerRemediation command not available." -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                'L' {
                    if (Get-Command -Name 'Set-PrinterClientRemediation' -ErrorAction SilentlyContinue) {
                        try {
                            $res = Set-PrinterClientRemediation -All
                            if ($res -and $res.Success) {
                                Write-ToolkitStatus -Message "All client printer remediations applied successfully. Fixes: $($res.FixesApplied -join ', ')." -Type 'OK'
                            }
                            else {
                                Write-ToolkitStatus -Message "Client remediation completed with warnings." -Type 'WARN'
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to apply client remediations: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    else {
                        Write-ToolkitStatus -Message "Set-PrinterClientRemediation command not available." -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                'X' {
                    if (Get-Command -Name 'Set-PrinterRemediation' -ErrorAction SilentlyContinue) {
                        try {
                            $res = Set-PrinterRemediation -Role Both -All
                            if ($res -and $res.Success) {
                                Write-ToolkitStatus -Message "All printer remediations (Both Roles) applied successfully. Fixes: $($res.FixesApplied -join ', ')." -Type 'OK'
                            }
                            else {
                                Write-ToolkitStatus -Message "Printer remediation completed with warnings." -Type 'WARN'
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to apply printer remediations: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    else {
                        Write-ToolkitStatus -Message "Set-PrinterRemediation command not available." -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                'F' {
                    Write-Host ""
                    Write-Host "  ========================================================================================" -ForegroundColor Cyan
                    Write-Host "  ITOOLKIT > PRINTERS > ERROR CODE REMEDIATION CATALOG" -ForegroundColor Cyan
                    Write-Host "  Select an error code to apply targeted fix:" -ForegroundColor Yellow
                    Write-Host "  ----------------------------------------------------------------------------------------" -ForegroundColor DarkGray
                    Write-Host "  [1]  0x0000011b : RPC Authn Level Privacy & Remote Endpoints (Server / PrintNightmare)"
                    Write-Host "  [2]  0x00000709 : RPC Named Pipe Protocol & Default Printer Key Reset (Client)"
                    Write-Host "  [3]  0x0000007c : CopyFiles Policy for Point & Print Driver Downloads (Client)"
                    Write-Host "  [4]  0x0000007e : Spooler DLL Re-registration & Driver Path Restoration (Client/Server)"
                    Write-Host "  [5]  0x00000bcb : Point & Print Driver Installation & Elevation Bypass (Client)"
                    Write-Host "  [6]  0x00000002 : Missing Driver File / INF & Driver Store Repair (Client/Server)"
                    Write-Host "  [7]  0x00000006 : Invalid Spooler Handle & Port Lock Cleanup (Client/Server)"
                    Write-Host "  [8]  0x00000057 : Parameter Incorrect & Driver Configuration Reset (Client)"
                    Write-Host "  [9]  0x000003e3 : Aborted I/O Queue Flush & Stalled Job Purge (Client/Server)"
                    Write-Host "  [10] SpoolerCrash: Spooler Crash Recovery (Full Purge & Permissions) (Client/Server)"
                    Write-Host "  [11] NePortConflict: Purge Corrupted Virtual Ne00:-Ne99: Port Bindings (Client)"
                    Write-Host "  [12] RefreshConnections: Rebind & Validate User Network Printer Mappings (Client)"
                    Write-Host "  [B]  Back"
                    Write-Host "  ========================================================================================" -ForegroundColor Cyan
                    $fChoice = Read-ToolkitMenuChoice -Prompt 'Select Fix' -ValidKeys @('1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11', '12', 'B') -Default 'B'
                    if (-not [string]::IsNullOrWhiteSpace($fChoice) -and $fChoice.ToUpperInvariant() -ne 'B') {
                        try {
                            switch ($fChoice) {
                                '1' {
                                    if (Get-Command -Name 'Set-PrinterServerRemediation' -ErrorAction SilentlyContinue) {
                                        $res = Set-PrinterServerRemediation -Fix 'RpcAuthnLevel'
                                    } else {
                                        $res = Set-PrinterRemediation -Fix '0x0000011b'
                                    }
                                    Write-ToolkitStatus -Message "Applied fix for 0x0000011b (RpcAuthnLevel)." -Type 'OK'
                                }
                                '2' {
                                    $res = Set-PrinterRemediation -Fix '0x00000709'
                                    Write-ToolkitStatus -Message "Applied fix for 0x00000709 (RpcNamedPipe & DefaultPrinterKey)." -Type 'OK'
                                }
                                '3' {
                                    $res = Set-PrinterRemediation -Fix '0x0000007c'
                                    Write-ToolkitStatus -Message "Applied fix for 0x0000007c (CopyFilesPolicy)." -Type 'OK'
                                }
                                '4' {
                                    $res = Set-PrinterRemediation -Fix '0x0000007e'
                                    Write-ToolkitStatus -Message "Applied fix for 0x0000007e (SpoolerDLLs & Driver Restoration)." -Type 'OK'
                                }
                                '5' {
                                    $res = Set-PrinterRemediation -Fix '0x00000bcb'
                                    Write-ToolkitStatus -Message "Applied fix for 0x00000bcb (PointAndPrintAdmin & Prompts)." -Type 'OK'
                                }
                                '6' {
                                    $res = Set-PrinterRemediation -Fix '0x00000002'
                                    Write-ToolkitStatus -Message "Applied fix for 0x00000002 (DriverStoreRepair)." -Type 'OK'
                                }
                                '7' {
                                    $res = Set-PrinterRemediation -Fix '0x00000006'
                                    Write-ToolkitStatus -Message "Applied fix for 0x00000006 (SpoolerHandles)." -Type 'OK'
                                }
                                '8' {
                                    $res = Set-PrinterRemediation -Fix '0x00000057'
                                    Write-ToolkitStatus -Message "Applied fix for 0x00000057 (DriverConfig & Connections)." -Type 'OK'
                                }
                                '9' {
                                    $res = Set-PrinterRemediation -Fix '0x000003e3'
                                    Write-ToolkitStatus -Message "Applied fix for 0x000003e3 (ClearStalledJobs)." -Type 'OK'
                                }
                                '10' {
                                    $res = Set-PrinterRemediation -Fix 'SpoolerCrash'
                                    Write-ToolkitStatus -Message "Applied fix for Spooler Crash Recovery (Full Purge & Permissions)." -Type 'OK'
                                }
                                '11' {
                                    $res = Set-PrinterRemediation -Fix 'NePortConflict'
                                    Write-ToolkitStatus -Message "Applied fix for NePortConflict (Virtual Ne Ports Purged)." -Type 'OK'
                                }
                                '12' {
                                    $res = Set-PrinterRemediation -Fix 'RefreshConnections'
                                    Write-ToolkitStatus -Message "Applied fix for RefreshConnections (Rebound Mappings)." -Type 'OK'
                                }
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to apply fix: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'U' {
                    $regFile = Read-Host "  Enter registry backup .reg file path (or press Enter to search default backup folder)"
                    if ([string]::IsNullOrWhiteSpace($regFile)) {
                        $searchDirs = @('C:\Backups\Registry', "$env:TEMP\IToolkit_RegistryBackups", "$env:TEMP")
                        $foundFiles = @()
                        foreach ($sDir in $searchDirs) {
                            if (Test-Path -LiteralPath $sDir) {
                                $foundFiles += @(Get-ChildItem -LiteralPath $sDir -Filter '*.reg' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
                            }
                        }
                        if ($foundFiles.Count -gt 0) {
                            $latest = $foundFiles[0].FullName
                            Write-Host "  Found recent backup: $latest" -ForegroundColor Cyan
                            $confirm = Read-Host "  Restore this backup? [Y/N] (Default: Y)"
                            if ([string]::IsNullOrWhiteSpace($confirm) -or $confirm.ToUpperInvariant() -eq 'Y') {
                                $regFile = $latest
                            }
                        }
                    }
                    if (-not [string]::IsNullOrWhiteSpace($regFile)) {
                        if (Get-Command -Name 'Restore-RegistryKeyBackup' -ErrorAction SilentlyContinue) {
                            try {
                                $success = Restore-RegistryKeyBackup -BackupFilePath $regFile
                                if ($success) {
                                    Write-ToolkitStatus -Message "Registry restored successfully from '$regFile'." -Type 'OK'
                                }
                                else {
                                    Write-ToolkitStatus -Message "Registry restore failed for '$regFile'." -Type 'FAIL'
                                }
                            }
                            catch {
                                Write-ToolkitStatus -Message "Rollback error: $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                        else {
                            Write-ToolkitStatus -Message "Restore-RegistryKeyBackup command not available." -Type 'WARN'
                        }
                    }
                    else {
                        Write-ToolkitStatus -Message "No registry backup file selected. Rollback cancelled." -Type 'INFO'
                    }
                    Wait-UserAcknowledge
                }
                'S' {
                    if (Get-Command -Name 'Reset-PrintSpoolerQueue' -ErrorAction SilentlyContinue) {
                        try {
                            Reset-PrintSpoolerQueue -Force
                            Write-ToolkitStatus -Message "Print spooler service restarted and queue purged." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to reset print spooler queue: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'R' {
                    if (Get-Command -Name 'Register-PrintSpoolerComponents' -ErrorAction SilentlyContinue) {
                        try {
                            Register-PrintSpoolerComponents
                            Write-ToolkitStatus -Message "Print spooler components and DLLs registered." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to register spooler components: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'P' {
                    if (Get-Command -Name 'Set-PointAndPrintRemediation' -ErrorAction SilentlyContinue) {
                        try {
                            Set-PointAndPrintRemediation -Preset 'StrictAdminOnly'
                            Write-ToolkitStatus -Message "Point & Print remediation applied (StrictAdminOnly)." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to apply Point & Print remediation: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'N' {
                    if (Get-Command -Name 'Reset-PrinterNePortBindings' -ErrorAction SilentlyContinue) {
                        try {
                            Reset-PrinterNePortBindings
                            Write-ToolkitStatus -Message "Printer Ne port registry bindings reset." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to reset Ne port bindings: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'C' {
                    if (Get-Command -Name 'Reset-PrinterConnections' -ErrorAction SilentlyContinue) {
                        try {
                            Reset-PrinterConnections
                            Write-ToolkitStatus -Message "User network printer connections refreshed." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to refresh printer connections: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
            }
        }
        elseif ($selection.Type -eq 'Index') {
            $idx = [int]$selection.Value
            if ($idx -ge 1 -and $idx -le $printers.Count) {
                $targetPrinter = $printers[$idx - 1]

                $targetInfo = @(
                    "Printer Name   : $($targetPrinter.Name)",
                    "Driver Model   : $($targetPrinter.Driver)",
                    "Port Name      : $($targetPrinter.Port)",
                    "Current Status : $($targetPrinter.Status)"
                )
                Show-ToolkitHeader -Title "ITOOLKIT > PRINTER: $($targetPrinter.Name)" -Subtitle "Port: $($targetPrinter.Port) | Driver: $($targetPrinter.Driver)" -ClearScreen:$true -InfoLines $targetInfo

                $contextDetails = @(
                    @{ Key = '1'; Action = 'Print Test Page'; Description = "Send diagnostic test page to '$($targetPrinter.Name)'."; Prerequisite = 'Printer online [READY]' },
                    @{ Key = '2'; Action = 'Purge Queue'; Description = "Purge print queue jobs for '$($targetPrinter.Name)'."; Prerequisite = 'Spooler service [READY]' },
                    @{ Key = '3'; Action = 'Port Diagnostics'; Description = "Probe network port connectivity for '$($targetPrinter.Port)'."; Prerequisite = 'Network online [READY]' }
                )
                $contextNav = @(
                    @{ Key = 'B'; Label = 'Back to Printers Table' },
                    @{ Key = 'Q'; Label = 'Exit Console' }
                )
                Show-ToolkitDetailPanel -Details $contextDetails -NavActions $contextNav -Title 'CONTEXTUAL ACTIONS'

                $ctxChoice = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3', 'B', 'Q') -Default 'B'

                if ([string]::IsNullOrWhiteSpace($ctxChoice) -or $ctxChoice.ToUpperInvariant() -eq 'B') {
                    continue
                }
                if ($ctxChoice.ToUpperInvariant() -eq 'Q') {
                    return
                }

                switch ($ctxChoice) {
                    '1' {
                        try {
                            $escapedName = $targetPrinter.Name.Replace("'", "''")
                            $cimP = Get-CimInstance -ClassName Win32_Printer -Filter "Name = '$escapedName'" -ErrorAction SilentlyContinue
                            if ($null -ne $cimP) {
                                $null = Invoke-CimMethod -InputObject $cimP -MethodName PrintTestPage -ErrorAction SilentlyContinue
                            }
                            Write-ToolkitStatus -Message "Test page print command submitted for '$($targetPrinter.Name)'." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to print test page for '$($targetPrinter.Name)': $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    '2' {
                        if (Get-Command -Name 'Reset-PrintSpoolerQueue' -ErrorAction SilentlyContinue) {
                            try {
                                Reset-PrintSpoolerQueue -Force
                                Write-ToolkitStatus -Message "Print spooler queue purged for '$($targetPrinter.Name)'." -Type 'OK'
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to purge queue for '$($targetPrinter.Name)': $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    '3' {
                        $targetHost = $targetPrinter.Port
                        if ($targetHost -match '^IP_(.+)$') {
                            $targetHost = $Matches[1]
                        }
                        elseif ($targetHost -match '^\\\\([^\\]+)') {
                            $targetHost = $Matches[1]
                        }
                        if ([string]::IsNullOrWhiteSpace($targetHost) -or $targetHost -match '^(LPT|COM|USB|FILE|PORTPROMPT|WSD)') {
                            $targetHost = '127.0.0.1'
                        }
                        if (Get-Command -Name 'Test-NetworkPrinterConnectivity' -ErrorAction SilentlyContinue) {
                            try {
                                Test-NetworkPrinterConnectivity -ComputerName $targetHost | Format-List
                                Write-ToolkitStatus -Message "Port diagnostics completed for '$targetHost'." -Type 'OK'
                            }
                            catch {
                                Write-ToolkitStatus -Message "Port diagnostics failed for '$targetHost': $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                }
                Wait-UserAcknowledge
            }
        }
    }
}

if (Get-Command -Name Get-PrintersContextInfoLines -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path function:global:Get-PrintersContextInfoLines -Value (Get-Command -Name Get-PrintersContextInfoLines).ScriptBlock
}
if (Get-Command -Name Invoke-ToolkitSubmenuPrinters -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path function:global:Invoke-ToolkitSubmenuPrinters -Value (Get-Command -Name Invoke-ToolkitSubmenuPrinters).ScriptBlock
}

