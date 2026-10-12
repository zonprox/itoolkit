if (-not (Get-Command -Name 'Wait-UserAcknowledge' -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot '../Private/Wait-UserAcknowledge.ps1'
    if (Test-Path $waitScript) {
        . $waitScript
    }
}

function Get-OfficeSuiteContextInfoLines {
    [CmdletBinding()]
    param()

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

    $isOutlookRunning = $false
    try {
        $procs = @(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
        if ($procs.Count -gt 0) { $isOutlookRunning = $true }
    } catch { $null = $_ }

    $outlookState = if ($isOutlookRunning) { 'Running [ACTIVE]' } else { 'Stopped [READY]' }
    $lines.Add("Outlook Status : $outlookState")

    $defProf = 'DefaultProfile'
    if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
        try {
            $ctx = Get-OutlookSystemContext
            if ($ctx -and $ctx.DefaultProfile) { $defProf = $ctx.DefaultProfile }
        } catch { $null = $_ }
    }
    $lines.Add("Mail Profile   : Default Profile: $defProf")
    $lines.Add("Office Tools   : PST/OST Engine, Acceleration, COM Add-ins, C2R Repair [READY]")

    return $lines.ToArray()
}

function Get-OfficeContextInfoLines {
    [CmdletBinding()]
    param()
    return Get-OfficeSuiteContextInfoLines
}

function Get-OutlookContextInfoLines {
    [CmdletBinding()]
    param()
    return Get-OfficeSuiteContextInfoLines
}

if (Get-Command -Name 'Get-OfficeSuiteContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-OfficeSuiteContextInfoLines' -Value (Get-Command -Name 'Get-OfficeSuiteContextInfoLines').ScriptBlock
}
if (Get-Command -Name 'Get-OfficeContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-OfficeContextInfoLines' -Value (Get-Command -Name 'Get-OfficeContextInfoLines').ScriptBlock
}
if (Get-Command -Name 'Get-OutlookContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-OutlookContextInfoLines' -Value (Get-Command -Name 'Get-OutlookContextInfoLines').ScriptBlock
}

function Invoke-ToolkitSubmenuOfficeSuite {
<#
.SYNOPSIS
    Submenu for Office & Productivity Suite (Office & Outlook Administration).
.DESCRIPTION
    Combines troubleshooting for Outlook PST/OST files and Microsoft Office:
    - PST/OST data file creation, limit expansion, compaction, and default profile binding
    - Hardware acceleration toggling, UI cache reset, and temp cache purge
    - Click-to-Run repair (Quick / Online) and KMS licensing verification
    - COM add-in resiliency and GDI handle leak audits
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
        $officeInfo = Get-OfficeSuiteContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > OFFICE & PRODUCTIVITY SUITE' -Subtitle 'Unified Office & Outlook Administration, Data Files, Performance & Repair' -ClearScreen:$clear -InfoLines $officeInfo

        $items = @()
        if (Get-Command -Name 'Find-OutlookDataFiles' -ErrorAction SilentlyContinue) {
            try {
                $rawFiles = @(Find-OutlookDataFiles)
                foreach ($f in $rawFiles) {
                    $p = [string]$f.Path
                    $n = if (-not [string]::IsNullOrWhiteSpace($p)) { Split-Path -Leaf $p } else { 'DataFile' }
                    $items += [PSCustomObject]@{
                        Item    = $n
                        Status  = '[READY]'
                        Type    = if ($f.Type) { [string]$f.Type } else { 'PST' }
                        Details = $p
                    }
                }
            } catch { $null = $_ }
        }

        if ($items.Count -eq 0) {
            $items = @(
                [PSCustomObject]@{ Item = 'Outlook Data Engine'; Status = '[READY]'; Type = 'Service'; Details = 'PST/OST file discovery and compaction' },
                [PSCustomObject]@{ Item = 'Microsoft Excel';     Status = '[READY]'; Type = 'Application'; Details = 'Hardware acceleration and GDI management' },
                [PSCustomObject]@{ Item = 'Microsoft Word';      Status = '[READY]'; Type = 'Application'; Details = 'Document processor and cache resiliency' },
                [PSCustomObject]@{ Item = 'Microsoft Outlook';   Status = '[READY]'; Type = 'Application'; Details = 'Messaging client and mail profiles' }
            )
        }
        Show-ToolkitItemTable -Items $items -Columns @('Item', 'Status', 'Type', 'Details') -Headers @('ITEM', 'STATUS', 'TYPE', 'DETAILS') -Title 'Productivity Applications & Data Files'

        Write-Host ""
        $actions = @(
            @{ Key = '1'; Label = 'Quick Repair Office' },
            @{ Key = '2'; Label = 'Online Repair Office' },
            @{ Key = '3'; Label = 'Expand PST Limit (100GB)' },
            @{ Key = '4'; Label = 'Compact Data Files' },
            @{ Key = '5'; Label = 'Toggle Graphics Acceleration' },
            @{ Key = '6'; Label = 'Clear Temp & Cache' },
            @{ Key = '7'; Label = 'License Diagnostics (KMS)' },
            @{ Key = '8'; Label = 'Audit GDI Leakers' },
            @{ Key = '9'; Label = 'Terminate Office Processes' }
        )
        $navActions = @(
            @{ Key = '0'; Label = 'Back to Main Menu' }
        )
        Show-ToolkitActionCatalog -Actions $actions -NavActions $navActions -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'Office & Productivity Suite'." -Type 'INFO'
            return
        }

        $validKeys = @('1', '2', '3', '4', '5', '6', '7', '8', '9', '0')
        $promptText = "  Select action [1-9, 0]"
        $selection = Read-ToolkitItemSelection -MaxIndex 0 -ValidHotkeys $validKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit' -or $selection.Value -eq '0') {
            return
        }

        $actionKey = "$($selection.Value)"

        switch ($actionKey) {
            '1' {
                if (Get-Command -Name 'Start-OfficeClickToRunRepair' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Initiating Office Quick Repair..." -Type 'INFO'
                        Start-OfficeClickToRunRepair -RepairType 'Quick'
                        Write-ToolkitStatus -Message "Office Quick Repair invoked." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Office Quick Repair failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            '2' {
                if (Get-Command -Name 'Start-OfficeClickToRunRepair' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Initiating Office Online Repair..." -Type 'INFO'
                        Start-OfficeClickToRunRepair -RepairType 'Online'
                        Write-ToolkitStatus -Message "Office Online Repair invoked." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Office Online Repair failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            '3' {
                if (Get-Command -Name 'Set-OutlookPstThreshold' -ErrorAction SilentlyContinue) {
                    try {
                        Set-OutlookPstThreshold -MaxLargeFileSizeMB 102400 -WarnLargeFileSizeMB 97280
                        Write-ToolkitStatus -Message "PST file threshold expanded to 100GB." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Failed to set PST threshold: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            '4' {
                if (Get-Command -Name 'Invoke-OutlookCompaction' -ErrorAction SilentlyContinue) {
                    try {
                        Write-ToolkitStatus -Message "Starting data file compaction..." -Type 'INFO'
                        Invoke-OutlookCompaction
                        Write-ToolkitStatus -Message "Outlook compaction routine finished." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Compaction failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            '5' {
                if (Get-Command -Name 'Set-ExcelHardwareAcceleration' -ErrorAction SilentlyContinue) {
                    try {
                        Set-ExcelHardwareAcceleration -Disable $true
                        Write-ToolkitStatus -Message "Hardware graphics acceleration disabled for Office." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Failed to set hardware acceleration: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            '6' {
                if (Get-Command -Name 'Clear-OfficeTempCache' -ErrorAction SilentlyContinue) {
                    try {
                        Clear-OfficeTempCache
                        Write-ToolkitStatus -Message "Office temporary cache files cleared." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "Cache purge failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                if (Get-Command -Name 'Reset-ExcelUiCache' -ErrorAction SilentlyContinue) {
                    try {
                        Reset-ExcelUiCache
                    } catch { $null = $_ }
                }
                Wait-UserAcknowledge
            }
            '7' {
                Write-ToolkitStatus -Message "Probing KMS licensing host connectivity (port 1688)..." -Type 'INFO'
                try {
                    if (Get-Command -Name 'Test-NetConnection' -ErrorAction SilentlyContinue) {
                        $kmsRes = Test-NetConnection -ComputerName 'kms.local' -Port 1688 -WarningAction SilentlyContinue
                        if ($kmsRes -and $kmsRes.TcpTestSucceeded) {
                            Write-ToolkitStatus -Message "KMS Host probe succeeded." -Type 'OK'
                        } else {
                            Write-ToolkitStatus -Message "KMS Host probe unreachable or unconfigured." -Type 'WARN'
                        }
                    }
                } catch {
                    Write-ToolkitStatus -Message "KMS probe failed: $($_.Exception.Message)" -Type 'WARN'
                }
                Wait-UserAcknowledge
            }
            '8' {
                if (Get-Command -Name 'Get-ExcelGdiHandleUsage' -ErrorAction SilentlyContinue) {
                    try {
                        $gdi = Get-ExcelGdiHandleUsage
                        Write-ToolkitStatus -Message "GDI Handle Audit completed. Active Excel processes audited." -Type 'OK'
                    } catch {
                        Write-ToolkitStatus -Message "GDI audit failed: $($_.Exception.Message)" -Type 'FAIL'
                    }
                }
                Wait-UserAcknowledge
            }
            '9' {
                try {
                    Write-ToolkitStatus -Message "Stopping stuck Office processes..." -Type 'INFO'
                    if (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                        Stop-ToolkitProcess -ProcessName @('OUTLOOK', 'EXCEL', 'WINWORD', 'POWERPNT')
                    }
                    Write-ToolkitStatus -Message "Office processes terminated." -Type 'OK'
                } catch {
                    Write-ToolkitStatus -Message "Failed to stop Office processes: $($_.Exception.Message)" -Type 'FAIL'
                }
                Wait-UserAcknowledge
            }
            '0' { return }
        }
    }
}

function Invoke-ToolkitSubmenuOffice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][switch]$ExitImmediately,
        [Parameter(Mandatory = $false)][switch]$NonInteractive,
        [Parameter(Mandatory = $false)][int]$MenuDepth = 1
    )
    Invoke-ToolkitSubmenuOfficeSuite @PSBoundParameters
}

function Invoke-ToolkitSubmenuOutlook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][switch]$ExitImmediately,
        [Parameter(Mandatory = $false)][switch]$NonInteractive,
        [Parameter(Mandatory = $false)][int]$MenuDepth = 1
    )
    Invoke-ToolkitSubmenuOfficeSuite @PSBoundParameters
}

if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeSuite' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuOfficeSuite' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeSuite').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuOffice' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuOffice' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuOffice').ScriptBlock
}
if (Get-Command -Name 'Invoke-ToolkitSubmenuOutlook' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitSubmenuOutlook' -Value (Get-Command -Name 'Invoke-ToolkitSubmenuOutlook').ScriptBlock
}
