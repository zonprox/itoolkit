<#
.SYNOPSIS
    Dedicated interactive and automated administration menu for Microsoft PowerPoint repairs.
.DESCRIPTION
    Provides targeted fixes for PowerPoint 2016-2024:
    [1] Toggle Hardware Acceleration (presentation rendering & slide show GPU acceleration)
    [2] Reset Font & Slide Cache (clears corrupted slide layout preview and font caches)
    [3] Reset Add-in Resiliency & Disabled Items (clears blacklisted/crashed add-in entries)
    [4] Terminate PowerPoint Processes (graceful + forced termination of POWERPNT.EXE)
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


function Get-OfficePowerPointContextInfoLines {
    <#
    .SYNOPSIS
        Gathers live environment context for Microsoft PowerPoint repairs.
    #>
    [CmdletBinding()]
    param()

    $lines = [System.Collections.Generic.List[string]]::new()

    # Process status
    $pptProcs = @(Get-Process -Name 'POWERPNT' -ErrorAction SilentlyContinue)
    $procStatus = if ($pptProcs.Count -gt 0) { "Running ($($pptProcs.Count) instance(s)) [ACTIVE]" } else { "Stopped [READY]" }
    $lines.Add("PowerPoint Procs: $procStatus")

    # Hardware acceleration state
    $accelDisabled = $false
    try {
        $optPath = 'HKCU:\Software\Microsoft\Office\16.0\PowerPoint\Options'
        if (Test-Path -LiteralPath $optPath) {
            $val = Get-ItemPropertyValue -Path $optPath -Name 'DisableHardwareAcceleration' -ErrorAction SilentlyContinue
            if ($val -eq 1) { $accelDisabled = $true }
        }
    } catch { $null = $_ }
    $accelDisplay = if ($accelDisabled) { "Disabled (Software Fallback) [ACTIVE]" } else { "Enabled (GPU Accelerated) [DEFAULT]" }
    $lines.Add("Graphics Accel : $accelDisplay")

    # Font and slide cache status
    $localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'AppData\Local' } else { [System.IO.Path]::GetTempPath() }
    $cacheDir = Join-Path (Join-Path (Join-Path $localAppData 'Microsoft') 'Office\16.0\PowerPoint') 'Cache'
    $cacheCount = 0
    if (Test-Path -LiteralPath $cacheDir) {
        $cacheCount = @(Get-ChildItem -LiteralPath $cacheDir -File -Recurse -ErrorAction SilentlyContinue).Count
    }
    $lines.Add("Slide/Font Cache: $cacheCount cached file(s) in %LOCALAPPDATA%\Microsoft\Office\16.0\PowerPoint\Cache")

    # Resiliency disabled items count
    $disabledCount = 0
    try {
        $resPath = 'HKCU:\Software\Microsoft\Office\16.0\PowerPoint\Resiliency\DisabledItems'
        if (Test-Path -LiteralPath $resPath) {
            $item = Get-Item -LiteralPath $resPath -ErrorAction SilentlyContinue
            if ($null -ne $item) { $disabledCount = @($item.Property).Count }
        }
    } catch { $null = $_ }
    $lines.Add("Resiliency Hive : $disabledCount disabled item(s) in PowerPoint\Resiliency\DisabledItems")

    return $lines.ToArray()
}

function Invoke-ToolkitSubmenuOfficePowerPoint {
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
                Write-ToolkitLog -Message "PowerPoint Repairs submenu launched with -ExitImmediately flag. Returning." -Level INFO -Component 'TUI' -NoConsole
            }
            return
        }

    $inSubmenu = $true
    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $pptInfo = Get-OfficePowerPointContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > OFFICE > MICROSOFT POWERPOINT REPAIRS' `
            -Subtitle 'Targeted Diagnostics, Acceleration, Font/Slide Cache & Resiliency' `
            -ClearScreen:$clear `
            -InfoLines $pptInfo

        $pptItems = @(
            [PSCustomObject]@{ Component = 'Hardware Acceleration'; Status = '[READY]'; Subsystem = 'PowerPoint\Options'; Details = 'Presentation rendering & slide show GPU acceleration' },
            [PSCustomObject]@{ Component = 'Font & Slide Cache'; Status = '[READY]'; Subsystem = 'PowerPoint\Cache'; Details = 'Cached font render artifacts & slide preview bitmaps' },
            [PSCustomObject]@{ Component = 'Resiliency & Add-ins'; Status = '[READY]'; Subsystem = 'Resiliency\DisabledItems'; Details = 'Blacklisted & crashed COM add-ins list' },
            [PSCustomObject]@{ Component = 'Process Controller'; Status = '[READY]'; Subsystem = 'POWERPNT.EXE'; Details = 'Active background & hung PowerPoint instances' }
        )
        Show-ToolkitItemTable -Items $pptItems -Columns @('Component', 'Status', 'Subsystem', 'Details') -Headers @('SUBSYSTEM', 'STATUS', 'TARGET', 'PURPOSE') -Title 'Microsoft PowerPoint Architectural Subsystems' -NoIndex

        Write-Host ""
        $actions = @(
            @{ Key = '1'; Label = 'Toggle Hardware Acceleration' },
            @{ Key = '2'; Label = 'Reset Font & Slide Cache' },
            @{ Key = '3'; Label = 'Reset Add-in Resiliency & Disabled Items' },
            @{ Key = '4'; Label = 'Terminate PowerPoint Processes' }
        )
        $navActions = @(
            @{ Key = '0'; Label = 'Back to Office Hub' }
        )
        Show-ToolkitActionCatalog -Actions $actions -NavActions $navActions -Title 'POWERPOINT REPAIR ACTIONS'

        if ($NonInteractive) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Non-interactive category listing complete for 'Microsoft PowerPoint Repairs'." -Level INFO -Component 'TUI' -NoConsole
            }
            Write-Host "Non-interactive category listing complete for 'Microsoft PowerPoint Repairs'." -ForegroundColor Cyan
            return
        }

        $validKeys = @('1', '2', '3', '4', '0')
        $promptText = "  Select PowerPoint repair action [1-4, 0]"
        $selection = Read-ToolkitItemSelection -MaxIndex 0 -ValidHotkeys $validKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit' -or $selection.Value -eq '0') {
            return
        }

        $actionKey = "$($selection.Value)"

        switch ($actionKey) {
            '1' {
                try {
                    Write-ToolkitStatus -Message "Checking PowerPoint hardware acceleration status..." -Type 'INFO'
                    if (Get-Command -Name 'Set-PowerPointHardwareAcceleration' -ErrorAction SilentlyContinue) {
                        $curDisabled = $false
                        try {
                            $val = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Office\16.0\PowerPoint\Options' -Name 'DisableHardwareAcceleration' -ErrorAction SilentlyContinue
                            if ($val -eq 1) { $curDisabled = $true }
                        } catch { $null = $_ }

                        $targetDisable = -not $curDisabled
                        $res = Set-PowerPointHardwareAcceleration -Disable $targetDisable
                        if ($res -and $res.Status -eq 'Success') {
                            $stateDesc = if ($res.Disabled) { "DISABLED (Software Rendering)" } else { "ENABLED (Hardware Rendering)" }
                            Write-ToolkitStatus -Message "PowerPoint hardware graphics acceleration set to: $stateDesc." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "Hardware acceleration update processed." -Type 'INFO'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Set-PowerPointHardwareAcceleration command unavailable." -Type 'WARN'
                    }
                } catch {
                    Write-ToolkitStatus -Message "Hardware acceleration toggle failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '2' {
                try {
                    Write-ToolkitStatus -Message "Purging PowerPoint font and slide layout preview cache..." -Type 'INFO'
                    if (Get-Command -Name 'Reset-PowerPointCache' -ErrorAction SilentlyContinue) {
                        $res = Reset-PowerPointCache -Force
                        if ($res -and $res.Status -eq 'Success') {
                            Write-ToolkitStatus -Message "Purged $($res.CleanedFilesCount) cached file(s) ($([math]::Round($res.BytesFreed / 1KB, 1)) KB freed)." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "PowerPoint cache is already clean." -Type 'INFO'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Reset-PowerPointCache command unavailable." -Type 'WARN'
                    }
                } catch {
                    Write-ToolkitStatus -Message "Cache purge failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '3' {
                try {
                    Write-ToolkitStatus -Message "Resetting PowerPoint add-in resiliency disabled items list..." -Type 'INFO'
                    if (Get-Command -Name 'Reset-PowerPointResiliency' -ErrorAction SilentlyContinue) {
                        $res = Reset-PowerPointResiliency
                        if ($res -and $res.Status -eq 'Success') {
                            Write-ToolkitStatus -Message "PowerPoint Resiliency reset: $($res.ClearedItems) blacklisted item(s) unblocked." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "No disabled items found in PowerPoint Resiliency list." -Type 'INFO'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Reset-PowerPointResiliency command unavailable." -Type 'WARN'
                    }
                } catch {
                    Write-ToolkitStatus -Message "Resiliency reset failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '4' {
                try {
                    Write-ToolkitStatus -Message "Terminating active PowerPoint (POWERPNT) processes..." -Type 'INFO'
                    if (Get-Command -Name 'Stop-OfficeProcess' -ErrorAction SilentlyContinue) {
                        $res = Stop-OfficeProcess -ProcessNames @('POWERPNT') -Force
                        if ($res -and $res.Status -eq 'Success') {
                            $termCount = @($res.Terminated).Count
                            Write-ToolkitStatus -Message "Terminated $termCount PowerPoint process instance(s)." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "No active PowerPoint processes found." -Type 'INFO'
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


if (Get-Command -Name 'Get-OfficePowerPointContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-OfficePowerPointContextInfoLines' -Value (Get-Command -Name 'Get-OfficePowerPointContextInfoLines').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficePowerPoint' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuOfficePowerPoint' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuOfficePowerPoint').ScriptBlock
}
