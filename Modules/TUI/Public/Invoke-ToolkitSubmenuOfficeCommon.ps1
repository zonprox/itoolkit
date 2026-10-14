<#
.SYNOPSIS
    Interactive submenu for Common Microsoft Office Suite Operations and Repairs.
.DESCRIPTION
    Provides centralized administrative operations applicable across the entire Microsoft Office suite:
    - [1] Repair Click-to-Run Service & Streaming Cache (Repair-OfficeClickToRunService)
    - [2] Reset Office Identity & WAM Modern Auth Tokens (Reset-OfficeIdentityCache)
    - [3] Terminate All Office Processes (Stop-OfficeProcess)
    - [4] Native Office Clean Uninstaller & Scrubber (Uninstall-OfficeSuiteCleanly)
    - [0] Back to Main Office Hub
    Strictly enforces 1-handed numeric keypad navigation ('0'..'4') with zero letter aliases.
    Fully compatible with headless automation via -NonInteractive and -ExitImmediately.
.PARAMETER ExitImmediately
    Bypasses interactive loop and returns immediately (for automated testing).
.PARAMETER NonInteractive
    Headless automation mode: renders menu catalog once and returns cleanly without prompting.
.PARAMETER MenuDepth
    Optional menu recursion depth tracking.
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

if (-not (Get-Command -Name 'Wait-UserAcknowledge' -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot '../Private/Wait-UserAcknowledge.ps1'
    if (Test-Path -LiteralPath $waitScript) {
        . $waitScript
    }
}
if (-not (Get-Command -Name 'Show-ToolkitHeader' -ErrorAction SilentlyContinue)) {
    $headerScript = Join-Path $PSScriptRoot 'Show-ToolkitHeader.ps1'
    if (Test-Path -LiteralPath $headerScript) { . $headerScript }
}
if (-not (Get-Command -Name 'Show-ToolkitActionCatalog' -ErrorAction SilentlyContinue)) {
    $catScript = Join-Path $PSScriptRoot 'Show-ToolkitActionCatalog.ps1'
    if (Test-Path -LiteralPath $catScript) { . $catScript }
}
if (-not (Get-Command -Name 'Read-ToolkitItemSelection' -ErrorAction SilentlyContinue)) {
    $selScript = Join-Path $PSScriptRoot 'Read-ToolkitItemSelection.ps1'
    if (Test-Path -LiteralPath $selScript) { . $selScript }
}
if (-not (Get-Command -Name 'Write-ToolkitStatus' -ErrorAction SilentlyContinue)) {
    $statusScript = Join-Path $PSScriptRoot 'Write-ToolkitStatus.ps1'
    if (Test-Path -LiteralPath $statusScript) { . $statusScript }
}

function Get-OfficeCommonContextInfoLines {
    [CmdletBinding()]
    param()

    if (Get-Command -Name 'Get-OfficeSuiteContextInfoLines' -ErrorAction SilentlyContinue) {
        return (Get-OfficeSuiteContextInfoLines)
    }

    $lines = [System.Collections.Generic.List[string]]::new()
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
    } catch { $null = $_ }

    $lines.Add("Office Build   : Microsoft Office $c2rVer | $c2rArch")
    $lines.Add("Common Tools   : C2R Repair, Modern Auth WAM Reset, Process Killer, Clean Scrubber [READY]")
    return $lines.ToArray()
}

function Invoke-ToolkitSubmenuOfficeCommon {
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
        Write-ToolkitStatus -Message "Office Common submenu launched with -ExitImmediately flag. Returning." -Type 'INFO'
        return
    }

    $inSubmenu = $true
    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $infoLines = Get-OfficeCommonContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > OFFICE SUITE > COMMON OPERATIONS' `
            -Subtitle 'Suite-Wide Maintenance, Click-to-Run Repair, Identity Reset & Scrubber' `
            -ClearScreen:$clear `
            -InfoLines $infoLines

        $actions = @(
            @{ Key = '1'; Label = 'Repair Click-to-Run Service & Cache' },
            @{ Key = '2'; Label = 'Reset Office Identity & WAM Tokens' },
            @{ Key = '3'; Label = 'Terminate All Office Processes' },
            @{ Key = '4'; Label = 'Native Clean Uninstaller & Scrubber' }
        )
        $navActions = @(
            @{ Key = '0'; Label = 'Back to Office Hub' }
        )
        Show-ToolkitActionCatalog -Actions $actions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Office Common Operations'." -Type 'INFO'
            return
        }

        $categoryKeys = @('1', '2', '3', '4')
        $promptText = "  Select Action [1-4], or [0] Back"
        $selection = Read-ToolkitItemSelection -MaxIndex 0 -ValidHotkeys $categoryKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit' -or $selection.Value -eq '0') {
            return
        }

        $actionKey = "$($selection.Value)"
        switch ($actionKey) {
            '1' {
                if (Get-Command -Name 'Repair-OfficeClickToRunService' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Diagnosing and repairing Click-to-Run service and streaming cache..." -Type 'INFO'
                        $repairRes = Repair-OfficeClickToRunService
                        if ($repairRes -and $repairRes.Status -eq 'Success') {
                            $detailMsg = "ClickToRunSvc is Running."
                            if ($repairRes.Repaired) {
                                $detailMsg += " Streaming cache corruptions repaired."
                            }
                            Write-ToolkitStatus -Message "Office Click-to-Run repair successful: $detailMsg" -Type 'OK'
                        } elseif ($repairRes -and $repairRes.Status -eq 'Skipped') {
                            Write-ToolkitStatus -Message "ClickToRunSvc service is not installed on this system." -Type 'WARN'
                        } else {
                            $st = if ($repairRes) { $repairRes.ServiceStatus } else { 'Unknown' }
                            Write-ToolkitStatus -Message "Office Click-to-Run repair completed with warning (ServiceStatus: $st)." -Type 'WARN'
                        }
                    } catch {
                        Write-ToolkitStatus -Message "Repair-OfficeClickToRunService failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                } else {
                    Write-ToolkitStatus -Message "Repair-OfficeClickToRunService command unavailable." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            '2' {
                if (Get-Command -Name 'Reset-OfficeIdentityCache' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Resetting Office Identity cache, OneAuth, and WAM broker plugin tokens..." -Type 'INFO'
                        $idRes = Reset-OfficeIdentityCache -PurgeWamTokens
                        if ($idRes -and $idRes.Status -eq 'Success') {
                            $clearedCount = if ($idRes.CachesCleared) { $idRes.CachesCleared.Count } else { 0 }
                            Write-ToolkitStatus -Message "Office Identity and WAM modern auth tokens reset successfully ($clearedCount cache directory targets purged)." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "Office Identity cache reset completed." -Type 'OK'
                        }
                    } catch {
                        Write-ToolkitStatus -Message "Reset-OfficeIdentityCache failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                } else {
                    Write-ToolkitStatus -Message "Reset-OfficeIdentityCache command unavailable." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            '3' {
                if (Get-Command -Name 'Stop-OfficeProcess' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Terminating all running Microsoft Office suite processes..." -Type 'INFO'
                        $stopRes = Stop-OfficeProcess
                        if ($stopRes -and $stopRes.Terminated -and $stopRes.Terminated.Count -gt 0) {
                            Write-ToolkitStatus -Message "Terminated active Office processes: $($stopRes.Terminated -join ', ')" -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "No active Microsoft Office processes were running." -Type 'OK'
                        }
                    } catch {
                        Write-ToolkitStatus -Message "Stop-OfficeProcess failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                } else {
                    Write-ToolkitStatus -Message "Stop-OfficeProcess command unavailable." -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            '4' {
                $confirmed = if ($NonInteractive) { $true } else { (Read-Host "  Confirm deep clean uninstallation and scrub of Office suite? [y/N]") -match '^(?i)y(es)?$' }
                if ($confirmed) {
                    if (Get-Command -Name 'Uninstall-OfficeSuiteCleanly' -ErrorAction SilentlyContinue) {
                        try {
                            Write-ToolkitStatus -Message "Initiating pure-PowerShell Office clean uninstallation and scrub..." -Type 'INFO'
                            $scrubRes = Uninstall-OfficeSuiteCleanly -Force
                            if ($scrubRes -and $scrubRes.Status -in @('Success', 'Simulated')) {
                                $phases = if ($scrubRes.PhasesCompleted) { $scrubRes.PhasesCompleted -join ', ' } else { 'All' }
                                Write-ToolkitStatus -Message "Office Suite scrub complete. Completed phases: $phases" -Type 'OK'
                            } else {
                                Write-ToolkitStatus -Message "Office Suite scrub encountered warnings or errors." -Type 'WARN'
                            }
                        } catch {
                            Write-ToolkitStatus -Message "Clean uninstallation failed: $($_.Exception.Message)" -Type 'FAIL'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Uninstall-OfficeSuiteCleanly command unavailable." -Type 'WARN'
                    }
                } else {
                    Write-ToolkitStatus -Message "Office clean uninstallation cancelled by user." -Type 'INFO'
                }
                Wait-UserAcknowledge
            }
            '0' {
                return
            }
        }
    }
}

if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeCommon' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuOfficeCommon' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeCommon').ScriptBlock
}
if (Get-Command -Name 'Get-OfficeCommonContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-OfficeCommonContextInfoLines' -Value (Get-Command -Name 'Get-OfficeCommonContextInfoLines').ScriptBlock
}
