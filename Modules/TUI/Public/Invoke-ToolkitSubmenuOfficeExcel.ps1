<#
.SYNOPSIS
    Dedicated interactive and automated administration menu for Microsoft Excel repairs.
.DESCRIPTION
    Provides targeted fixes for Excel 2016-2024:
    [1] Toggle Hardware Acceleration (resolves black screens, white canvases, rendering crashes)
    [2] Clear XLSTART Startup Add-ins (isolates rogue add-ins while preserving Personal.xlsb)
    [3] Reset UI / Ribbon / QAT Cache (backs up Excel16.xlb, clears ribbon customizations & WebServiceCache)
    [4] Reset DDE & Formula Freeze Settings (clears IgnoreRemoteRequests and restores Automatic calculation)
    [5] Audit GDI Leakers (audits active Excel processes for GDI handle consumption > 5000/8000)
    [6] Terminate Excel Processes (graceful + forced termination of EXCEL.EXE)
    [0] Back to Office Hub
.PARAMETER ExitImmediately
    Bypasses interactive loop and returns immediately (for automated testing).
.PARAMETER NonInteractive
    Headless automation mode: renders menu once and returns cleanly.
.PARAMETER MenuDepth
    Menu recursion depth. Default is 2.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$ExitImmediately,

    [Parameter(Mandatory = $false)]
    [switch]$NonInteractive,

    [Parameter(Mandatory = $false)]
    [int]$MenuDepth = 2
)

if (-not (Get-Command -Name 'Wait-UserAcknowledge' -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot '../Private/Wait-UserAcknowledge.ps1'
    if (Test-Path $waitScript) { . $waitScript }
}
if (-not (Get-Command -Name 'Show-ToolkitHeader' -ErrorAction SilentlyContinue)) {
    $headerScript = Join-Path $PSScriptRoot 'Show-ToolkitHeader.ps1'
    if (Test-Path $headerScript) { . $headerScript }
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
if (-not (Get-Command -Name 'Write-ToolkitStatus' -ErrorAction SilentlyContinue)) {
    $statusScript = Join-Path $PSScriptRoot 'Write-ToolkitStatus.ps1'
    if (Test-Path $statusScript) { . $statusScript }
}

if (-not (Get-Command -Name 'Enter-ToolkitTuiMode' -ErrorAction SilentlyContinue)) {
    $coreTui = Join-Path $PSScriptRoot '../../Core/Public/Enter-ToolkitTuiMode.ps1'
    if (Test-Path -LiteralPath $coreTui) { . $coreTui }
}

if (-not (Get-Command -Name 'Exit-ToolkitTuiMode' -ErrorAction SilentlyContinue)) {
    $coreExit = Join-Path $PSScriptRoot '../../Core/Public/Exit-ToolkitTuiMode.ps1'
    if (Test-Path -LiteralPath $coreExit) { . $coreExit }
}


function Get-OfficeExcelContextInfoLines {
    <#
    .SYNOPSIS
        Gathers live environment context for Microsoft Excel repairs.
    #>
    [CmdletBinding()]
    param()

    $lines = [System.Collections.Generic.List[string]]::new()

    # Process status
    $excelProcs = @(Get-Process -Name 'EXCEL' -ErrorAction SilentlyContinue)
    $procStatus = if ($excelProcs.Count -gt 0) { "Running ($($excelProcs.Count) instance(s)) [ACTIVE]" } else { "Stopped [READY]" }
    $lines.Add("Excel Process  : $procStatus")

    # Hardware acceleration state
    $accelDisabled = $false
    try {
        $gfxVal = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Office\16.0\Common\Graphics' -Name 'DisableHardwareAcceleration' -ErrorAction SilentlyContinue
        if ($gfxVal -eq 1) { $accelDisabled = $true }
    } catch { $null = $_ }
    $accelDisplay = if ($accelDisabled) { "Disabled (Software Fallback) [ACTIVE]" } else { "Enabled (GPU Accelerated) [DEFAULT]" }
    $lines.Add("Graphics Accel : $accelDisplay")

    # XLSTART add-ins count
    $appData = if ($env:APPDATA) { $env:APPDATA } elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'AppData\Roaming' } else { [System.IO.Path]::GetTempPath() }
    $xlStartDir = Join-Path (Join-Path (Join-Path $appData 'Microsoft') 'Excel') 'XLSTART'
    $xlStartCount = 0
    if (Test-Path -LiteralPath $xlStartDir) {
        $xlStartCount = @(Get-ChildItem -LiteralPath $xlStartDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\.disabled$' }).Count
    }
    $lines.Add("XLSTART Folder : $xlStartCount active file(s) in %APPDATA%\Microsoft\Excel\XLSTART")

    # DDE and calculation mode
    $ddeStatus = "Normal (0) [READY]"
    $calcMode = "Automatic (1) [READY]"
    try {
        $optPath = 'HKCU:\Software\Microsoft\Office\16.0\Excel\Options'
        if (Test-Path -LiteralPath $optPath) {
            $ddeVal = Get-ItemPropertyValue -Path $optPath -Name 'IgnoreRemoteRequests' -ErrorAction SilentlyContinue
            if ($ddeVal -eq 1) { $ddeStatus = "Ignoring Remote DDE (1) [WARN: FREEZE RISK]" }
            $calcVal = Get-ItemPropertyValue -Path $optPath -Name 'Calculation' -ErrorAction SilentlyContinue
            if ($calcVal -eq 2) { $calcMode = "Semi-Automatic (2)" }
            elseif ($calcVal -eq 3) { $calcMode = "Manual (3) [WARN: FORMULAS FROZEN]" }
        }
    } catch { $null = $_ }
    $lines.Add("DDE & Engine   : DDE: $ddeStatus | Calculation: $calcMode")

    return $lines.ToArray()
}

function Invoke-ToolkitSubmenuOfficeExcel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$ExitImmediately,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [int]$MenuDepth = 2
    )

    if (Get-Command -Name 'Enter-ToolkitTuiMode' -ErrorAction SilentlyContinue) {
        Enter-ToolkitTuiMode
    }
    try {
        if ($ExitImmediately) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Excel Repairs submenu launched with -ExitImmediately flag. Returning." -Level INFO -Component 'TUI' -NoConsole
            }
            return
        }

    $inSubmenu = $true
    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $excelInfo = Get-OfficeExcelContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > OFFICE > MICROSOFT EXCEL REPAIRS' `
            -Subtitle 'Targeted Diagnostics, Acceleration, Add-in Isolation & Memory Audits' `
            -ClearScreen:$clear `
            -InfoLines $excelInfo

        $excelItems = @(
            [PSCustomObject]@{ Component = 'Hardware Acceleration'; Status = '[READY]'; Subsystem = 'Common\Graphics'; Details = 'Hardware GPU acceleration & display driver stability' },
            [PSCustomObject]@{ Component = 'XLSTART Folder'; Status = '[READY]'; Subsystem = 'Excel\XLSTART'; Details = 'Auto-load workbooks, rogue add-ins & Personal.xlsb' },
            [PSCustomObject]@{ Component = 'UI & Toolbar Cache'; Status = '[READY]'; Subsystem = 'Excel16.xlb, QAT'; Details = 'Workspace toolbar layout & ribbon customizations' },
            [PSCustomObject]@{ Component = 'DDE & Calculations'; Status = '[READY]'; Subsystem = 'IgnoreRemoteRequests'; Details = 'DDE message routing & formula calculation mode' },
            [PSCustomObject]@{ Component = 'GDI Handle Monitor'; Status = '[READY]'; Subsystem = 'GetGuiResources'; Details = 'Desktop heap exhaustion & GDI object leakage audit' },
            [PSCustomObject]@{ Component = 'Process Controller'; Status = '[READY]'; Subsystem = 'EXCEL.EXE'; Details = 'Active background & hung Excel instances' }
        )
        Show-ToolkitItemTable -Items $excelItems -Columns @('Component', 'Status', 'Subsystem', 'Details') -Headers @('SUBSYSTEM', 'STATUS', 'TARGET', 'PURPOSE') -Title 'Microsoft Excel Architectural Subsystems' -NoIndex

        Write-Host ""
        $actions = @(
            @{ Key = '1'; Label = 'Toggle Hardware Acceleration' },
            @{ Key = '2'; Label = 'Clear XLSTART Startup Add-ins' },
            @{ Key = '3'; Label = 'Reset UI / Ribbon / QAT Cache' },
            @{ Key = '4'; Label = 'Reset DDE & Formula Freeze Settings' },
            @{ Key = '5'; Label = 'Audit GDI Leakers' },
            @{ Key = '6'; Label = 'Terminate Excel Processes' }
        )
        $navActions = @(
            @{ Key = '0'; Label = 'Back to Office Hub' }
        )
        Show-ToolkitActionCatalog -Actions $actions -NavActions $navActions -Title 'EXCEL REPAIR ACTIONS'

        if ($NonInteractive) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Non-interactive category listing complete for 'Microsoft Excel Repairs'." -Level INFO -Component 'TUI' -NoConsole
            }
            Write-Host "Non-interactive category listing complete for 'Microsoft Excel Repairs'." -ForegroundColor Cyan
            return
        }

        $validKeys = @('1', '2', '3', '4', '5', '6', '0')
        $promptText = "  Select Excel repair action [1-6, 0]"
        $selection = Read-ToolkitItemSelection -MaxIndex 0 -ValidHotkeys $validKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit' -or $selection.Value -eq '0') {
            return
        }

        $actionKey = "$($selection.Value)"

        switch ($actionKey) {
            '1' {
                try {
                    Write-ToolkitStatus -Message "Checking hardware acceleration status..." -Type 'INFO'
                    if (Get-Command -Name 'Set-ExcelHardwareAcceleration' -ErrorAction SilentlyContinue) {
                        $curDisabled = $false
                        try {
                            $val = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Office\16.0\Common\Graphics' -Name 'DisableHardwareAcceleration' -ErrorAction SilentlyContinue
                            if ($val -eq 1) { $curDisabled = $true }
                        } catch { $null = $_ }

                        $targetDisable = -not $curDisabled
                        $res = Set-ExcelHardwareAcceleration -Disable $targetDisable
                        if ($res -and $res.Status -eq 'Success') {
                            $stateDesc = if ($res.Disabled) { "DISABLED (Software Rendering)" } else { "ENABLED (Hardware Rendering)" }
                            Write-ToolkitStatus -Message "Excel hardware graphics acceleration set to: $stateDesc." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "Hardware acceleration update processed." -Type 'INFO'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Set-ExcelHardwareAcceleration command unavailable." -Type 'WARN'
                    }
                } catch {
                    Write-ToolkitStatus -Message "Hardware acceleration toggle failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '2' {
                try {
                    Write-ToolkitStatus -Message "Scanning and isolating rogue XLSTART files..." -Type 'INFO'
                    if (Get-Command -Name 'Clear-ExcelStartupFolder' -ErrorAction SilentlyContinue) {
                        $res = Clear-ExcelStartupFolder -Force
                        if ($res -and $res.Status -eq 'Success') {
                            $rmCount = @($res.RemovedFiles).Count
                            $bkMsg = if ($res.PersonalBackupPath) { " (Personal.xlsb backed up to '$($res.PersonalBackupPath)')" } else { "" }
                            Write-ToolkitStatus -Message "XLSTART folder cleaned: $rmCount rogue file(s) isolated$bkMsg." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "XLSTART folder is already clean." -Type 'INFO'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Clear-ExcelStartupFolder command unavailable." -Type 'WARN'
                    }
                } catch {
                    Write-ToolkitStatus -Message "XLSTART cleanup failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '3' {
                try {
                    Write-ToolkitStatus -Message "Resetting Excel UI workspace, ribbon, and QAT cache..." -Type 'INFO'
                    if (Get-Command -Name 'Reset-ExcelUiCache' -ErrorAction SilentlyContinue) {
                        $res = Reset-ExcelUiCache
                        if ($res -and $res.Status -eq 'Success') {
                            $qCount = @($res.QuarantinedFiles).Count
                            Write-ToolkitStatus -Message "Excel UI cache reset: $qCount file(s) quarantined, WebServiceCache purged ($($res.WebServiceCachePurged))." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "Excel UI cache reset completed." -Type 'INFO'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Reset-ExcelUiCache command unavailable." -Type 'WARN'
                    }
                } catch {
                    Write-ToolkitStatus -Message "UI cache reset failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '4' {
                try {
                    Write-ToolkitStatus -Message "Resetting Excel DDE and calculation mode settings..." -Type 'INFO'
                    if (Get-Command -Name 'Reset-ExcelDdeSettings' -ErrorAction SilentlyContinue) {
                        $res = Reset-ExcelDdeSettings
                        if ($res -and $res.Status -eq 'Success') {
                            Write-ToolkitStatus -Message "DDE remote requests enabled (0), calculation mode restored to Automatic (1)." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "DDE settings processed." -Type 'INFO'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Reset-ExcelDdeSettings command unavailable." -Type 'WARN'
                    }
                } catch {
                    Write-ToolkitStatus -Message "DDE settings reset failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '5' {
                try {
                    Write-ToolkitStatus -Message "Auditing active Excel processes for GDI handle consumption..." -Type 'INFO'
                    $gdiCmd = if (Get-Command -Name 'Get-ProcessGdiHandleCount' -ErrorAction SilentlyContinue) {
                        'Get-ProcessGdiHandleCount'
                    } elseif (Get-Command -Name 'Get-ExcelGdiHandleUsage' -ErrorAction SilentlyContinue) {
                        'Get-ExcelGdiHandleUsage'
                    } else {
                        $null
                    }

                    if ($null -ne $gdiCmd) {
                        $usage = @(& $gdiCmd -WarningThreshold 5000)
                        if ($usage.Count -gt 0) {
                            Show-ToolkitItemTable -Items $usage -Columns @('PID', 'ProcessName', 'GdiHandles', 'UserHandles', 'MemoryMB', 'IsLeaking') -Headers @('PID', 'PROCESS', 'GDI HANDLES', 'USER HANDLES', 'RAM (MB)', 'LEAK FLAG') -Title 'EXCEL GDI & USER OBJECT TELEMETRY' -NoIndex
                            $leaking = @($usage | Where-Object { $_.IsLeaking -eq $true })
                            if ($leaking.Count -gt 0) {
                                Write-ToolkitStatus -Message "WARNING: $($leaking.Count) Excel process instance(s) exceed safe GDI threshold (>5000)." -Type 'WARN'
                                if (Get-Command -Name 'Stop-ExcelGdiLeakers' -ErrorAction SilentlyContinue) {
                                    $confirmed = if ($NonInteractive) { $true } else { (Read-Host "  Terminate leaking Excel process instance(s) now? [y/N]") -match '^(?i)y(es)?$' }
                                    if ($confirmed) {
                                        $termRes = Stop-ExcelGdiLeakers -Threshold 5000 -Force
                                        Write-ToolkitStatus -Message "Terminated $($termRes.Count) leaking Excel process(es)." -Type 'OK'
                                    }
                                }
                            } else {
                                Write-ToolkitStatus -Message "GDI audit complete. All active Excel processes are within safe handle limits." -Type 'OK'
                            }
                        } else {
                            Write-ToolkitStatus -Message "No active Excel processes detected to audit." -Type 'INFO'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Get-ExcelGdiHandleUsage / Get-ProcessGdiHandleCount command unavailable." -Type 'WARN'
                    }
                } catch {
                    Write-ToolkitStatus -Message "GDI handle audit failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '6' {
                try {
                    Write-ToolkitStatus -Message "Terminating active Excel (EXCEL) processes..." -Type 'INFO'
                    if (Get-Command -Name 'Stop-OfficeProcess' -ErrorAction SilentlyContinue) {
                        $res = Stop-OfficeProcess -ProcessNames @('EXCEL') -Force
                        if ($res -and $res.Status -eq 'Success') {
                            $termCount = @($res.Terminated).Count
                            Write-ToolkitStatus -Message "Terminated $termCount Excel process instance(s)." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "No active Excel processes found." -Type 'INFO'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Stop-OfficeProcess command unavailable." -Type 'WARN'
                    }
                } catch {
                    Write-ToolkitStatus -Message "Process termination failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '0' {
                return
            }
        }
    }
}
finally {
    if (Get-Command -Name 'Exit-ToolkitTuiMode' -ErrorAction SilentlyContinue) {
        Exit-ToolkitTuiMode
    }
}
}


if (Get-Command -Name 'Get-OfficeExcelContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-OfficeExcelContextInfoLines' -Value (Get-Command -Name 'Get-OfficeExcelContextInfoLines').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeExcel' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuOfficeExcel' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeExcel').ScriptBlock
}
