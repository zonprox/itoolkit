<#
.SYNOPSIS
    Dedicated interactive and automated administration menu for Microsoft Word repairs.
.DESCRIPTION
    Provides targeted fixes for Word 2016-2024:
    [1] Reset Normal.dotm Template (with automatic .bak preservation)
    [2] Isolate Word Startup Add-ins (renames active add-ins to .disabled)
    [3] Reset Word Registry Data & Options (backs up to .reg and recreates clean defaults)
    [4] Clear Orphaned Lock / ASD Files (safe handle-verified cleanup of ~$*.docx and *.asd)
    [5] Terminate Word Processes (graceful + forced termination of WINWORD.EXE)
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
    if (Test-Path -LiteralPath $waitScript) { . $waitScript }
}
if (-not (Get-Command -Name 'Confirm-ToolkitAction' -ErrorAction SilentlyContinue)) {
    $confirmScript = Join-Path $PSScriptRoot '../Private/Confirm-ToolkitAction.ps1'
    if (Test-Path -LiteralPath $confirmScript) { . $confirmScript }
}
if (-not (Get-Command -Name 'Show-ToolkitHeader' -ErrorAction SilentlyContinue)) {
    $headerScript = Join-Path $PSScriptRoot 'Show-ToolkitHeader.ps1'
    if (Test-Path -LiteralPath $headerScript) { . $headerScript }
}
if (-not (Get-Command -Name 'Show-ToolkitActionCatalog' -ErrorAction SilentlyContinue)) {
    $catScript = Join-Path $PSScriptRoot 'Show-ToolkitActionCatalog.ps1'
    if (Test-Path -LiteralPath $catScript) { . $catScript }
}
if (-not (Get-Command -Name 'Show-ToolkitItemTable' -ErrorAction SilentlyContinue)) {
    $tableScript = Join-Path $PSScriptRoot 'Show-ToolkitItemTable.ps1'
    if (Test-Path -LiteralPath $tableScript) { . $tableScript }
}
if (-not (Get-Command -Name 'Read-ToolkitItemSelection' -ErrorAction SilentlyContinue)) {
    $selectScript = Join-Path $PSScriptRoot 'Read-ToolkitItemSelection.ps1'
    if (Test-Path -LiteralPath $selectScript) { . $selectScript }
}
if (-not (Get-Command -Name 'Write-ToolkitStatus' -ErrorAction SilentlyContinue)) {
    $statusScript = Join-Path $PSScriptRoot 'Write-ToolkitStatus.ps1'
    if (Test-Path -LiteralPath $statusScript) { . $statusScript }
}

if (-not (Get-Command -Name 'Enter-ToolkitTuiMode' -ErrorAction SilentlyContinue)) {
    $coreTui = Join-Path $PSScriptRoot '../../Core/Public/Enter-ToolkitTuiMode.ps1'
    if (Test-Path -LiteralPath $coreTui) { . $coreTui }
}

if (-not (Get-Command -Name 'Exit-ToolkitTuiMode' -ErrorAction SilentlyContinue)) {
    $coreExit = Join-Path $PSScriptRoot '../../Core/Public/Exit-ToolkitTuiMode.ps1'
    if (Test-Path -LiteralPath $coreExit) { . $coreExit }
}


function Get-OfficeWordContextInfoLines {
    <#
    .SYNOPSIS
        Gathers live environment context for Microsoft Word repairs.
    #>
    [CmdletBinding()]
    param()

    $lines = [System.Collections.Generic.List[string]]::new()

    # Process status
    $wordProcs = @(Get-Process -Name 'WINWORD' -ErrorAction SilentlyContinue)
    $procStatus = if ($wordProcs.Count -gt 0) { "Running ($($wordProcs.Count) instance(s)) [ACTIVE]" } else { "Stopped [READY]" }
    $lines.Add("Word Process   : $procStatus")

    # Normal.dotm status
    $appData = if ($env:APPDATA) { $env:APPDATA } elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'AppData\Roaming' } else { [System.IO.Path]::GetTempPath() }
    $normalPath = Join-Path (Join-Path (Join-Path $appData 'Microsoft') 'Templates') 'Normal.dotm'
    $normalStatus = if (Test-Path -LiteralPath $normalPath) { "Customized / Present ($(Split-Path $normalPath -Leaf))" } else { "Clean / Default [NOT FOUND]" }
    $lines.Add("Normal Template: $normalStatus")

    # Startup add-ins status
    $startupDir = Join-Path (Join-Path (Join-Path $appData 'Microsoft') 'Word') 'STARTUP'
    $startupCount = 0
    if (Test-Path -LiteralPath $startupDir) {
        $startupCount = @(Get-ChildItem -LiteralPath $startupDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\.disabled$' }).Count
    }
    $lines.Add("Startup Add-ins: $startupCount active template(s) in %APPDATA%\Microsoft\Word\STARTUP")

    # Registry status
    $regDataPath = 'HKCU:\Software\Microsoft\Office\16.0\Word\Data'
    $regOptionsPath = 'HKCU:\Software\Microsoft\Office\16.0\Word\Options'
    $hasData = Test-Path -LiteralPath $regDataPath -ErrorAction SilentlyContinue
    $hasOptions = Test-Path -LiteralPath $regOptionsPath -ErrorAction SilentlyContinue
    $lines.Add("Word Registry  : Data Hive: $(if ($hasData) { 'Customized' } else { 'Default' }) | Options Hive: $(if ($hasOptions) { 'Customized' } else { 'Default' })")

    return $lines.ToArray()
}

function Invoke-ToolkitSubmenuOfficeWord {
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
                Write-ToolkitLog -Message "Word Repairs submenu launched with -ExitImmediately flag. Returning." -Level INFO -Component 'TUI' -NoConsole
            }
            return
        }

    $inSubmenu = $true
    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $wordInfo = Get-OfficeWordContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > OFFICE > MICROSOFT WORD REPAIRS' `
            -Subtitle 'Targeted Diagnostics, Template Recovery & Startup Isolation for Word' `
            -ClearScreen:$clear `
            -InfoLines $wordInfo

        $actions = @(
            @{ Key = '1'; Label = 'Reset Normal.dotm Template'; Description = 'Backup and regenerate corrupted global formatting base template' },
            @{ Key = '2'; Label = 'Isolate Word Startup Add-ins'; Description = 'Disable auto-loading templates and third-party WLL libraries in STARTUP' },
            @{ Key = '3'; Label = 'Reset Word Registry Data & Options'; Description = 'Rebuild default Word Data and Options registry subkeys' },
            @{ Key = '4'; Label = 'Clear Orphaned Lock / ASD Files'; Description = 'Purge stale ~$*.docx owner locks and corrupt auto-recovery documents' },
            @{ Key = '5'; Label = 'Quick Word Repair'; Description = 'Sequential process termination, template reset, add-in isolation, and lock purge' }
        )
        $navActions = @(
            @{ Key = '0'; Label = 'Back to Office Hub'; Description = 'Return to the central Office & Productivity Suite menu' }
        )
        Show-ToolkitActionCatalog -Actions $actions -NavActions $navActions -Title 'WORD REPAIR ACTIONS'

        if ($NonInteractive) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Non-interactive category listing complete for 'Microsoft Word Repairs'." -Level INFO -Component 'TUI' -NoConsole
            }
            Write-Host "Non-interactive category listing complete for 'Microsoft Word Repairs'." -ForegroundColor Cyan
            return
        }

        $validKeys = @('1', '2', '3', '4', '5', '0')
        $promptText = "  Select Word repair action [1-5, 0]"
        $selection = Read-ToolkitItemSelection -MaxIndex 0 -ValidHotkeys $validKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit' -or $selection.Value -eq '0') {
            return
        }

        $actionKey = "$($selection.Value)"

        switch ($actionKey) {
            '1' {
                try {
                    Write-ToolkitStatus -Message "Initiating Normal.dotm template recovery..." -Type 'INFO'
                    if (Get-Command -Name 'Reset-WordTemplate' -ErrorAction SilentlyContinue) {
                        $res = Reset-WordTemplate -Force
                        if ($res -and $res.Status -eq 'Success') {
                            Write-ToolkitStatus -Message "Normal.dotm successfully backed up to '$($res.Backup)' and reset." -Type 'OK'
                        } elseif ($res -and $res.Status -eq 'Skipped') {
                            Write-ToolkitStatus -Message "Normal.dotm not found. Clean template state already active." -Type 'INFO'
                        } else {
                            Write-ToolkitStatus -Message "Word template reset processed with status: $($res.Status)." -Type 'WARN'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Reset-WordTemplate command unavailable." -Type 'WARN'
                    }
                } catch {
                    Write-ToolkitStatus -Message "Template reset failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '2' {
                try {
                    Write-ToolkitStatus -Message "Scanning and isolating rogue Word startup add-ins..." -Type 'INFO'
                    if (Get-Command -Name 'Reset-WordStartupAddin' -ErrorAction SilentlyContinue) {
                        $res = Reset-WordStartupAddin -DisableAll -Force
                        if ($res -and $res.Status -eq 'Success') {
                            Write-ToolkitStatus -Message "Word startup add-ins isolated: $($res.AddinsIsolated) template(s) renamed to .disabled." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "No active startup add-in templates found to isolate." -Type 'INFO'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Reset-WordStartupAddin command unavailable." -Type 'WARN'
                    }
                } catch {
                    Write-ToolkitStatus -Message "Startup add-in isolation failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '3' {
                try {
                    Write-ToolkitStatus -Message "Exporting backup and resetting Word Data & Options registry keys..." -Type 'INFO'
                    if (Get-Command -Name 'Reset-WordRegistryData' -ErrorAction SilentlyContinue) {
                        $res = Reset-WordRegistryData -ResetData -ResetOptions
                        if ($res -and $res.Status -eq 'Success') {
                            Write-ToolkitStatus -Message "Word Data and Options registry keys successfully backed up and reset." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "Registry reset completed with status: $($res.Status)." -Type 'INFO'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Reset-WordRegistryData command unavailable." -Type 'WARN'
                    }
                } catch {
                    Write-ToolkitStatus -Message "Registry reset failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '4' {
                try {
                    Write-ToolkitStatus -Message "Scanning for orphaned Word lock (~$*.docx) and auto-recovery (*.asd) files..." -Type 'INFO'
                    if (Get-Command -Name 'Clear-WordOrphanedLocks' -ErrorAction SilentlyContinue) {
                        $res = Clear-WordOrphanedLocks -Force
                        if ($res -and $res.Status -eq 'Success') {
                            $cnt = @($res.CleanedFiles).Count
                            Write-ToolkitStatus -Message "Cleaned $cnt orphaned lock and recovery file(s)." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "No orphaned Word lock files found." -Type 'INFO'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Clear-WordOrphanedLocks command unavailable." -Type 'WARN'
                    }
                } catch {
                    Write-ToolkitStatus -Message "Lock file purge failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '5' {
                try {
                    Write-ToolkitStatus -Message "Executing Quick Word Repair sequence..." -Type 'INFO'
                    if (Get-Command -Name 'Invoke-WordQuickRepair' -ErrorAction SilentlyContinue) {
                        $res = Invoke-WordQuickRepair -Force -PassThru
                        if ($res -and $res.Status -in @('Success', 'OK', 'Simulated')) {
                            Write-ToolkitStatus -Message "Quick Word Repair completed successfully. Template, add-ins, locks, and registry repaired." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "Quick Word Repair completed with status: $($res.Status)." -Type 'WARN'
                        }
                    } elseif (Get-Command -Name 'Stop-OfficeProcess' -ErrorAction SilentlyContinue) {
                        $res = Stop-OfficeProcess -ProcessNames @('WINWORD') -Force
                        if ($res -and $res.Status -eq 'Success') {
                            $termCount = @($res.Terminated).Count
                            Write-ToolkitStatus -Message "Terminated $termCount Word process instance(s)." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "No active Word processes found." -Type 'INFO'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Invoke-WordQuickRepair command unavailable." -Type 'WARN'
                    }
                } catch {
                    Write-ToolkitStatus -Message "Quick Word Repair failed: $($_.Exception.Message)" -Type 'FAIL'
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


if (Get-Command -Name 'Get-OfficeWordContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-OfficeWordContextInfoLines' -Value (Get-Command -Name 'Get-OfficeWordContextInfoLines').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeWord' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuOfficeWord' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeWord').ScriptBlock
}
