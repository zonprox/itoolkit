if (-not (Get-Command -Name Wait-UserAcknowledge -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot ../Private/Wait-UserAcknowledge.ps1
    if (Test-Path $waitScript) {
        . $waitScript
    }
}

function Get-OfficeContextInfoLines {
    $lines = [System.Collections.Generic.List[string]]::new()

    # 1. Office Product
    $officeVer = "Office 16.0 (Standard Desktop / LTSC)"
    try {
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration') {
            $c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
            if ($null -ne $c2r) {
                $verNum = $c2r.VersionToReport
                $arch = $c2r.Platform
                $prod = $c2r.ProductReleaseIds
                $officeVer = "Microsoft Office ClickToRun v$verNum [$arch] ($prod) [READY]"
            }
        }
        elseif (Test-Path 'HKLM:\SOFTWARE\Microsoft\Office\16.0\Common\InstallRoot') {
            $officeVer = "Microsoft Office 16.0 Desktop (MSI / Volume LTSC) [READY]"
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("Office Product : $officeVer")

    # 2. Graphics Acceleration
    $accelStatus = "Enabled [DEFAULT]"
    try {
        $regPath = 'HKCU:\Software\Microsoft\Office\16.0\Common\Graphics'
        if (Test-Path $regPath) {
            $val = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).DisableHardwareAcceleration
            if ($val -eq 1) {
                $accelStatus = "Disabled [SAFE]"
            }
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("Graphics Acceleration : $accelStatus")

    # 3. Excel Process
    $excelStatus = "Stopped [SAFE]"
    try {
        $procs = Get-Process -Name 'EXCEL' -ErrorAction SilentlyContinue
        if ($null -ne $procs) {
            $pCount = $procs.Count
            $pids = ($procs | ForEach-Object { $_.Id }) -join ', '
            $excelStatus = "Running ($pCount instance; PID: $pids) [WARN]"
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("Excel Process  : $excelStatus")

    # 4. Excel UI Cache
    $cacheStatus = "Clean [READY]"
    try {
        if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
            $xlb15 = Join-Path $env:APPDATA 'Microsoft\Excel\Excel15.xlb'
            $xlb16 = Join-Path $env:APPDATA 'Microsoft\Excel\Excel16.xlb'
            if ((Test-Path $xlb15) -or (Test-Path $xlb16)) {
                $cacheStatus = "Cache Present (Excel16.xlb found) [WARN]"
            }
        }
    }
    catch {
        $null = $_
    }
    $lines.Add("Excel UI Cache : $cacheStatus")

    return $lines.ToArray()
}

function Invoke-ToolkitSubmenuOffice {
<#
.SYNOPSIS
    Submenu for Office & Excel Troubleshooting with item-centric UI/UX.
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
        $officeApps = @()
        $appsDef = @(
            @{ Name = 'Microsoft Excel';      Proc = 'EXCEL';    Exe = 'EXCEL.EXE' },
            @{ Name = 'Microsoft Word';       Proc = 'WINWORD';  Exe = 'WINWORD.EXE' },
            @{ Name = 'Microsoft PowerPoint'; Proc = 'POWERPNT'; Exe = 'POWERPNT.EXE' },
            @{ Name = 'Microsoft Outlook';    Proc = 'OUTLOOK';  Exe = 'OUTLOOK.EXE' },
            @{ Name = 'Microsoft OneNote';    Proc = 'ONENOTE';  Exe = 'ONENOTE.EXE' },
            @{ Name = 'Microsoft Access';     Proc = 'MSACCESS'; Exe = 'MSACCESS.EXE' }
        )

        $c2rVer = '16.0'
        $c2rArch = 'x64'
        try {
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration') {
                $c2rProps = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
                if ($null -ne $c2rProps) {
                    if ($c2rProps.VersionToReport) { $c2rVer = [string]$c2rProps.VersionToReport }
                    if ($c2rProps.Platform) { $c2rArch = [string]$c2rProps.Platform }
                }
            }
        }
        catch {
            $null = $_
        }

        foreach ($app in $appsDef) {
            $isInstalled = $false
            $exePath = ''
            try {
                $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$($app.Exe)"
                if (Test-Path $regPath) {
                    $isInstalled = $true
                    $prop = Get-ItemProperty $regPath -ErrorAction SilentlyContinue
                    if ($null -ne $prop -and $prop.'(default)') {
                        $exePath = [string]$prop.'(default)'
                    }
                }
            }
            catch {
                $null = $_
            }

            $isRunning = $false
            try {
                $procs = @(Get-Process -Name $app.Proc -ErrorAction SilentlyContinue)
                if ($procs.Count -gt 0) {
                    $isRunning = $true
                    $isInstalled = $true
                }
            }
            catch {
                $null = $_
            }

            if ($isInstalled) {
                $stat = if ($isRunning) { '[ACTIVE]' } else { '[READY]' }
                $officeApps += [PSCustomObject]@{
                    Name         = $app.Name
                    Status       = $stat
                    Version      = $c2rVer
                    Architecture = $c2rArch
                    ProcessName  = $app.Proc
                    Executable   = $app.Exe
                    Path         = $exePath
                    IsRunning    = $isRunning
                }
            }
        }

        $clear = if ($NonInteractive) { $false } else { $true }
        $officeInfo = Get-OfficeContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > OFFICE & EXCEL TROUBLESHOOTING' -Subtitle 'Graphics Acceleration, Cache Reset, COM Add-ins, GDI Leaks, Click-to-Run Repair' -ClearScreen:$clear -InfoLines $officeInfo

        Show-ToolkitItemTable -Items $officeApps -Columns @('Name', 'Status', 'Version', 'Architecture') -Headers @('NAME', 'STATUS', 'VERSION', 'ARCHITECTURE') -Title 'Installed Office Applications'

        Write-Host ""
        $topLevelActions = @(
            @{ Key = 'K'; Label = 'KMS Probe' },
            @{ Key = 'L'; Label = 'License Diagnostics' },
            @{ Key = 'R'; Label = 'Quick Repair' },
            @{ Key = 'O'; Label = 'Online Repair' },
            @{ Key = 'C'; Label = 'Clear Temp Cache' },
            @{ Key = 'H'; Label = 'Toggle Graphics Acceleration' },
            @{ Key = 'G'; Label = 'Audit GDI Leakers' }
        )
        $navActions = @(
            @{ Key = 'B'; Label = 'Back' },
            @{ Key = 'Q'; Label = 'Quit' }
        )
        Show-ToolkitActionCatalog -Actions $topLevelActions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Office & Excel Troubleshooting & Repair'." -Type 'INFO'
            return
        }

        $validKeys = @('K', 'L', 'R', 'O', 'C', 'H', 'G', 'B', 'Q')
        $promptText = if ($officeApps.Count -gt 0) { "  Select item [1-$($officeApps.Count)] or action" } else { "  Select action [K, L, R, O, C, H, G, B, Q]" }
        $selection = Read-ToolkitItemSelection -MaxIndex $officeApps.Count -ValidHotkeys $validKeys -Prompt $promptText

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
                'K' {
                    Write-ToolkitStatus -Message "Probing KMS host connectivity (TCP 1688)..." -Type 'INFO'
                    try {
                        if (Get-Command -Name 'Test-NetConnection' -ErrorAction SilentlyContinue) {
                            $kmsRes = Test-NetConnection -ComputerName 'kms.local' -Port 1688 -WarningAction SilentlyContinue
                            if ($null -ne $kmsRes -and $kmsRes.TcpTestSucceeded) {
                                Write-ToolkitStatus -Message "KMS Host probe succeeded (port 1688 open)." -Type 'OK'
                            }
                            else {
                                Write-ToolkitStatus -Message "KMS Host unreachable or unconfigured (port 1688)." -Type 'WARN'
                            }
                        }
                        else {
                            Write-ToolkitStatus -Message "KMS probe skipped (Test-NetConnection unavailable)." -Type 'INFO'
                        }
                    }
                    catch {
                        Write-ToolkitStatus -Message "KMS probe error: $($_.Exception.Message)" -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                'L' {
                    Write-ToolkitStatus -Message "Querying Office SoftwareLicensingProduct status..." -Type 'INFO'
                    try {
                        if (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
                            $lic = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "Name like 'Office%'" -ErrorAction SilentlyContinue)
                            if ($lic.Count -gt 0) {
                                $lic | Select-Object Name, LicenseStatus, GracePeriodRemaining | Format-Table -AutoSize
                                Write-ToolkitStatus -Message "Office license check completed." -Type 'OK'
                            }
                            else {
                                Write-ToolkitStatus -Message "No SoftwareLicensingProduct Office records found." -Type 'INFO'
                            }
                        }
                    }
                    catch {
                        Write-ToolkitStatus -Message "License query error: $($_.Exception.Message)" -Type 'WARN'
                    }
                    Wait-UserAcknowledge
                }
                'R' {
                    if (Get-Command -Name 'Start-OfficeClickToRunRepair' -ErrorAction SilentlyContinue) {
                        try {
                            Start-OfficeClickToRunRepair -RepairType 'Quick'
                            Write-ToolkitStatus -Message "Office Quick Repair launched." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Quick Repair failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'O' {
                    if (Get-Command -Name 'Start-OfficeClickToRunRepair' -ErrorAction SilentlyContinue) {
                        try {
                            Start-OfficeClickToRunRepair -RepairType 'Full'
                            Write-ToolkitStatus -Message "Office Online Repair launched." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Online Repair failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'C' {
                    if (Get-Command -Name 'Clear-OfficeTempCache' -ErrorAction SilentlyContinue) {
                        try {
                            Clear-OfficeTempCache
                            Write-ToolkitStatus -Message "Office temporary cache cleared." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to clear temp cache: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'H' {
                    if (Get-Command -Name 'Set-ExcelHardwareAcceleration' -ErrorAction SilentlyContinue) {
                        try {
                            $regPath = 'HKCU:\Software\Microsoft\Office\16.0\Common\Graphics'
                            $isCurrentlyDisabled = $false
                            if (Test-Path $regPath) {
                                $val = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).DisableHardwareAcceleration
                                if ($val -eq 1) {
                                    $isCurrentlyDisabled = $true
                                }
                            }
                            if ($isCurrentlyDisabled) {
                                Set-ExcelHardwareAcceleration -Enable
                                Write-ToolkitStatus -Message "Hardware graphics acceleration enabled." -Type 'OK'
                            }
                            else {
                                Set-ExcelHardwareAcceleration -Disable
                                Write-ToolkitStatus -Message "Hardware graphics acceleration disabled." -Type 'OK'
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to toggle acceleration: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
                'G' {
                    if (Get-Command -Name 'Get-ExcelGdiHandleUsage' -ErrorAction SilentlyContinue) {
                        try {
                            $gdi = Get-ExcelGdiHandleUsage
                            if ($null -ne $gdi) {
                                $gdi | Format-Table -AutoSize
                            }
                            else {
                                Write-ToolkitStatus -Message "No leaking Excel processes detected." -Type 'OK'
                            }
                        }
                        catch {
                            Write-ToolkitStatus -Message "GDI handle audit failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    Wait-UserAcknowledge
                }
            }
        }
        elseif ($selection.Type -eq 'Index') {
            $idx = [int]$selection.Value
            if ($idx -ge 1 -and $idx -le $officeApps.Count) {
                $targetApp = $officeApps[$idx - 1]

                $targetInfo = @(
                    "Application    : $($targetApp.Name)",
                    "Executable     : $($targetApp.Executable)",
                    "Version        : $($targetApp.Version) ($($targetApp.Architecture))",
                    "Process State  : $($targetApp.Status)"
                )
                Show-ToolkitHeader -Title "ITOOLKIT > OFFICE APP: $($targetApp.Name)" -Subtitle "Version: $($targetApp.Version) | State: $($targetApp.Status)" -ClearScreen:$true -InfoLines $targetInfo

                $contextDetails = @(
                    @{ Key = '1'; Action = 'Targeted Repair'; Description = "Execute Click-to-Run repair for '$($targetApp.Name)'."; Prerequisite = 'C2R installation [READY]' },
                    @{ Key = '2'; Action = 'Kill Process'; Description = "Terminate running instances of '$($targetApp.Executable)'."; Prerequisite = 'Process running [READY]' },
                    @{ Key = '3'; Action = 'Clear Cache'; Description = "Reset UI buffers and application temp cache."; Prerequisite = 'Application stopped [READY]' },
                    @{ Key = '4'; Action = 'Manage Add-ins'; Description = "Audit and configure installed COM add-ins."; Prerequisite = 'Registry access [READY]' },
                    @{ Key = '5'; Action = 'Reset Resiliency'; Description = "Clear blocked items list in registry."; Prerequisite = 'Registry access [READY]' }
                )
                $contextNav = @(
                    @{ Key = 'B'; Label = 'Back to Office Apps Table' },
                    @{ Key = 'Q'; Label = 'Exit Console' }
                )
                Show-ToolkitDetailPanel -Details $contextDetails -NavActions $contextNav -Title 'CONTEXTUAL ACTIONS'

                $ctxChoice = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3', '4', '5', 'B', 'Q') -Default 'B'

                if ([string]::IsNullOrWhiteSpace($ctxChoice) -or $ctxChoice.ToUpperInvariant() -eq 'B') {
                    continue
                }
                if ($ctxChoice.ToUpperInvariant() -eq 'Q') {
                    return
                }

                switch ($ctxChoice) {
                    '1' {
                        if (Get-Command -Name 'Start-OfficeClickToRunRepair' -ErrorAction SilentlyContinue) {
                            try {
                                Start-OfficeClickToRunRepair -RepairType 'Quick'
                                Write-ToolkitStatus -Message "Targeted repair initiated for '$($targetApp.Name)'." -Type 'OK'
                            }
                            catch {
                                Write-ToolkitStatus -Message "Repair failed for '$($targetApp.Name)': $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    '2' {
                        try {
                            Stop-Process -Name $targetApp.ProcessName -Force -ErrorAction SilentlyContinue
                            Write-ToolkitStatus -Message "Terminated processes matching '$($targetApp.Executable)'." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to stop '$($targetApp.Executable)': $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    '3' {
                        try {
                            if ($targetApp.ProcessName -eq 'EXCEL' -and (Get-Command -Name 'Reset-ExcelUiCache' -ErrorAction SilentlyContinue)) {
                                Reset-ExcelUiCache
                            }
                            if (Get-Command -Name 'Clear-OfficeTempCache' -ErrorAction SilentlyContinue) {
                                Clear-OfficeTempCache
                            }
                            Write-ToolkitStatus -Message "Application cache cleared for '$($targetApp.Name)'." -Type 'OK'
                        }
                        catch {
                            Write-ToolkitStatus -Message "Failed to clear cache: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    }
                    '4' {
                        if (Get-Command -Name 'Get-ExcelComAddin' -ErrorAction SilentlyContinue) {
                            try {
                                $addins = Get-ExcelComAddin
                                if ($addins) {
                                    $addins | Format-Table -AutoSize
                                }
                                else {
                                    Write-ToolkitStatus -Message "No COM add-ins registered for '$($targetApp.Name)'." -Type 'INFO'
                                }
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to query COM add-ins: $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                    '5' {
                        if (Get-Command -Name 'Reset-ExcelResiliency' -ErrorAction SilentlyContinue) {
                            try {
                                Reset-ExcelResiliency
                                Write-ToolkitStatus -Message "Add-in resiliency list reset for '$($targetApp.Name)'." -Type 'OK'
                            }
                            catch {
                                Write-ToolkitStatus -Message "Failed to reset resiliency: $($_.Exception.Message)" -Type 'FAIL'
                            }
                        }
                    }
                }
                Wait-UserAcknowledge
            }
        }
    }
}

if (Get-Command -Name Get-OfficeContextInfoLines -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path function:global:Get-OfficeContextInfoLines -Value (Get-Command -Name Get-OfficeContextInfoLines).ScriptBlock
}
if (Get-Command -Name Invoke-ToolkitSubmenuOffice -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path function:global:Invoke-ToolkitSubmenuOffice -Value (Get-Command -Name Invoke-ToolkitSubmenuOffice).ScriptBlock
}

