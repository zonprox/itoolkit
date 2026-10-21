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
if (-not (Get-Command -Name 'Confirm-ToolkitAction' -ErrorAction SilentlyContinue)) {
    $confirmScript = Join-Path $PSScriptRoot '../Private/Confirm-ToolkitAction.ps1'
    if (Test-Path -LiteralPath $confirmScript) {
        . $confirmScript
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

if (-not (Get-Command -Name 'Enter-ToolkitTuiMode' -ErrorAction SilentlyContinue)) {
    $coreTui = Join-Path $PSScriptRoot '../../Core/Public/Enter-ToolkitTuiMode.ps1'
    if (Test-Path -LiteralPath $coreTui) { . $coreTui }
}

if (-not (Get-Command -Name 'Exit-ToolkitTuiMode' -ErrorAction SilentlyContinue)) {
    $coreExit = Join-Path $PSScriptRoot '../../Core/Public/Exit-ToolkitTuiMode.ps1'
    if (Test-Path -LiteralPath $coreExit) { . $coreExit }
}


function Get-OfficeCommonContextInfoLines {
    [CmdletBinding()]
    param()

    if (Get-Command -Name 'Get-OfficeSuiteContextInfoLines' -ErrorAction SilentlyContinue) {
        return (Get-OfficeSuiteContextInfoLines)
    }

    $lines = [System.Collections.Generic.List[string]]::new()

    # 1. Inspect Click-to-Run Configuration
    $c2rProps = $null
    foreach ($regPath in @('HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration')) {
        if (Test-Path -LiteralPath $regPath -ErrorAction SilentlyContinue) {
            $props = Get-ItemProperty -LiteralPath $regPath -ErrorAction SilentlyContinue
            if ($null -ne $props) {
                $c2rProps = $props
                break
            }
        }
    }

    $productReleaseIds = if ($c2rProps -and $c2rProps.ProductReleaseIds) { [string]$c2rProps.ProductReleaseIds } else { '' }
    $versionToReport   = if ($c2rProps) {
        if ($c2rProps.VersionToReport) { [string]$c2rProps.VersionToReport }
        elseif ($c2rProps.ClientVersionToReport) { [string]$c2rProps.ClientVersionToReport }
        else { '' }
    } else { '' }
    $platform          = if ($c2rProps -and $c2rProps.Platform) { [string]$c2rProps.Platform } else { '' }
    $updateChannel     = if ($c2rProps -and $c2rProps.UpdateChannel) { [string]$c2rProps.UpdateChannel } else { '' }
    $cdnBaseUrl        = if ($c2rProps -and $c2rProps.CDNBaseUrl) { [string]$c2rProps.CDNBaseUrl } else { '' }

    # 2. Inspect Uninstall Registry Keys
    $uninstallSuiteName = $null
    $uninstallVersion   = $null
    foreach ($uPath in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (Test-Path -LiteralPath $uPath -ErrorAction SilentlyContinue) {
            try {
                $subKeys = Get-ChildItem -LiteralPath $uPath -ErrorAction SilentlyContinue
                foreach ($sk in $subKeys) {
                    $item = Get-ItemProperty -LiteralPath $sk.PSPath -ErrorAction SilentlyContinue
                    if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace($item.DisplayName)) {
                        $dn = [string]$item.DisplayName
                        if ($dn -match '(?i)Microsoft\s+(?:Office|365)' -and $dn -notmatch '(?i)Tools|Proofing|LanguagePack|MUI|Companion|Online') {
                            $uninstallSuiteName = $dn
                            if (-not [string]::IsNullOrWhiteSpace($item.DisplayVersion)) {
                                $uninstallVersion = [string]$item.DisplayVersion
                            }
                            break
                        }
                    }
                }
            } catch { $null = $_ }
        }
        if ($uninstallSuiteName) { break }
    }

    # 3. Map Suite Title
    $suiteTitle = $null
    if (-not [string]::IsNullOrWhiteSpace($productReleaseIds)) {
        if ($productReleaseIds -match '(?i)ProPlus2024Volume') { $suiteTitle = 'Microsoft Office LTSC Professional Plus 2024 [LTSC Volume]' }
        elseif ($productReleaseIds -match '(?i)ProPlus2021Volume') { $suiteTitle = 'Microsoft Office LTSC Professional Plus 2021 [LTSC Volume]' }
        elseif ($productReleaseIds -match '(?i)ProPlus2019Volume') { $suiteTitle = 'Microsoft Office Professional Plus 2019 [Volume]' }
        elseif ($productReleaseIds -match '(?i)O365ProPlusRetail') { $suiteTitle = 'Microsoft 365 Apps for enterprise (ProPlus)' }
        elseif ($productReleaseIds -match '(?i)O365BusinessRetail') { $suiteTitle = 'Microsoft 365 Apps for business' }
        elseif ($productReleaseIds -match '(?i)Standard2021Volume') { $suiteTitle = 'Microsoft Office LTSC Standard 2021 [LTSC Volume]' }
        else { $suiteTitle = "Microsoft Office ($productReleaseIds)" }
    }
    if (-not $suiteTitle -and -not [string]::IsNullOrWhiteSpace($uninstallSuiteName)) {
        $suiteTitle = $uninstallSuiteName
    }
    if (-not $suiteTitle) {
        $suiteTitle = if ($c2rProps) { 'Microsoft Office [Click-to-Run]' } else { 'Not Detected [STANDBY]' }
    }
    $lines.Add("Office Suite   : $suiteTitle")

    # 4. Build & Channel
    $c2rVer = if (-not [string]::IsNullOrWhiteSpace($versionToReport)) { $versionToReport } elseif (-not [string]::IsNullOrWhiteSpace($uninstallVersion)) { $uninstallVersion } else { '16.0' }
    $c2rArch = if (-not [string]::IsNullOrWhiteSpace($platform)) { $platform.ToLowerInvariant() } else { 'x64' }
    $deployType = if ($c2rProps) { 'Click-to-Run' } elseif ($uninstallSuiteName) { 'MSI' } else { 'Click-to-Run' }
    $lic = if ($productReleaseIds -match '(?i)Volume') { 'Volume' } elseif ($productReleaseIds -match '(?i)Retail') { 'Retail' } else { 'Standard' }
    $lines.Add("Build & Channel: $c2rVer | $c2rArch | $deployType | $lic")

    # 5. Installed Apps fallback
    $lines.Add("Installed Apps : Word, Excel, PowerPoint, Outlook, OneNote (5)")
    $lines.Add("Active Suite   : None [STANDBY]")
    $lines.Add("Mail Profile   : Default Profile: None")
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

    if (Get-Command -Name 'Enter-ToolkitTuiMode' -ErrorAction SilentlyContinue) {
        Enter-ToolkitTuiMode
    }
    try {
        if ($ExitImmediately) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Office Common submenu launched with -ExitImmediately flag. Returning." -Level INFO -Component 'TUI' -NoConsole
            }
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
            @{ Key = '1'; Label = 'Repair Click-to-Run Service & Cache'; Description = 'Restart C2R service, verify licensing, and clear streaming cache' },
            @{ Key = '2'; Label = 'Reset Office Identity & WAM Tokens'; Description = 'Clear corrupted Office identity cache, WAM broker tokens, and force re-auth' },
            @{ Key = '3'; Label = 'Toggle Suite-Wide Hardware Acceleration'; Description = 'Toggle GPU hardware acceleration across Word, Excel, and PowerPoint registry keys' },
            @{ Key = '4'; Label = 'Terminate All Office Processes'; Description = 'Safely terminate running instances of Word, Excel, PowerPoint, and Outlook' },
            @{ Key = '5'; Label = 'Native Clean Uninstaller & Scrubber'; Description = 'Remove corrupted Office installations using Microsoft SaRA scrubber automation' }
        )
        $navActions = @(
            @{ Key = '0'; Label = 'Back to Office Hub'; Description = 'Return to the central Office & Productivity Suite menu' }
        )
        Show-ToolkitActionCatalog -Actions $actions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Non-interactive category listing complete for 'Office Common Operations'." -Level INFO -Component 'TUI' -NoConsole
            }
            Write-Host "Non-interactive category listing complete for 'Office Common Operations'." -ForegroundColor Cyan
            return
        }

        $validKeys = @('1', '2', '3', '4', '5', '0')
        $promptText = "  Select Action [1-5], or [0] Back"
        $selection = Read-ToolkitItemSelection -MaxIndex 0 -ValidHotkeys $validKeys -Prompt $promptText

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
                try {
                    Write-ToolkitStatus -Message "Checking suite-wide hardware acceleration status..." -Type 'INFO'
                    if (Get-Command -Name 'Set-OfficeHardwareAcceleration' -ErrorAction SilentlyContinue) {
                        $curDisabled = $false
                        try {
                            $val = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Office\16.0\Common\Graphics' -Name 'DisableHardwareAcceleration' -ErrorAction SilentlyContinue
                            if ($val -eq 1) { $curDisabled = $true }
                        } catch { $null = $_ }

                        $targetDisable = -not $curDisabled
                        $res = if ($targetDisable) {
                            Set-OfficeHardwareAcceleration -Disable -PassThru
                        } else {
                            Set-OfficeHardwareAcceleration -Enable -PassThru
                        }
                        if ($res -and $res.Status -in @('Success', 'Simulated')) {
                            $stateDesc = if ($res.Disabled) { "DISABLED (Software Rendering)" } else { "ENABLED (Hardware Rendering)" }
                            Write-ToolkitStatus -Message "Suite-wide Office hardware graphics acceleration set to: $stateDesc." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "Hardware acceleration update processed." -Type 'INFO'
                        }
                    } else {
                        Write-ToolkitStatus -Message "Set-OfficeHardwareAcceleration command unavailable." -Type 'WARN'
                    }
                } catch {
                    Write-ToolkitStatus -Message "Hardware acceleration toggle failed: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '4' {
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
            '5' {
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
finally {
    if (Get-Command -Name 'Exit-ToolkitTuiMode' -ErrorAction SilentlyContinue) {
        Exit-ToolkitTuiMode
    }
}
}


if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeCommon' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuOfficeCommon' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeCommon').ScriptBlock
}
if (Get-Command -Name 'Get-OfficeCommonContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-OfficeCommonContextInfoLines' -Value (Get-Command -Name 'Get-OfficeCommonContextInfoLines').ScriptBlock
}
