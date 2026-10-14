<#
.SYNOPSIS
    Central Dispatcher Hub for Pillar 2: Office & Productivity Suite.
.DESCRIPTION
    Renders high-level administration categories and routes to dedicated submenus:
    [1] Office Suite & General Maintenance (Invoke-ToolkitSubmenuOfficeCommon)
    [2] Microsoft Word Repairs (Invoke-ToolkitSubmenuOfficeWord)
    [3] Microsoft Excel Repairs (Invoke-ToolkitSubmenuOfficeExcel)
    [4] Microsoft PowerPoint Repairs (Invoke-ToolkitSubmenuOfficePowerPoint)
    [5] Microsoft Outlook & Data Files (Invoke-ToolkitSubmenuOfficeOutlook)
    [0] Back to Main Menu
.PARAMETER ExitImmediately
    Bypasses interactive loop and returns immediately (used for automated testing).
.PARAMETER NonInteractive
    Headless automation mode: renders menu once and returns cleanly.
.PARAMETER MenuDepth
    Menu recursion depth. Default is 1.
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

# 1. Dependency Resolution & Submenu Pre-Loading
if (-not (Get-Command -Name 'Wait-UserAcknowledge' -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot '../Private/Wait-UserAcknowledge.ps1'
    if (Test-Path -LiteralPath $waitScript) { . $waitScript }
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


# Pre-load dedicated submenus if not yet loaded in current session
$subCommon = Join-Path $PSScriptRoot 'Invoke-ToolkitSubmenuOfficeCommon.ps1'
if ((-not (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeCommon' -ErrorAction SilentlyContinue)) -and (Test-Path -LiteralPath $subCommon)) {
    . $subCommon
}
$subWord = Join-Path $PSScriptRoot 'Invoke-ToolkitSubmenuOfficeWord.ps1'
if ((-not (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeWord' -ErrorAction SilentlyContinue)) -and (Test-Path -LiteralPath $subWord)) {
    . $subWord
}
$subExcel = Join-Path $PSScriptRoot 'Invoke-ToolkitSubmenuOfficeExcel.ps1'
if ((-not (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeExcel' -ErrorAction SilentlyContinue)) -and (Test-Path -LiteralPath $subExcel)) {
    . $subExcel
}
$subPowerPoint = Join-Path $PSScriptRoot 'Invoke-ToolkitSubmenuOfficePowerPoint.ps1'
if ((-not (Get-Command -Name 'Invoke-ToolkitSubmenuOfficePowerPoint' -ErrorAction SilentlyContinue)) -and (Test-Path -LiteralPath $subPowerPoint)) {
    . $subPowerPoint
}
$subOutlook = Join-Path $PSScriptRoot 'Invoke-ToolkitSubmenuOfficeOutlook.ps1'
if ((-not (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeOutlook' -ErrorAction SilentlyContinue)) -and (Test-Path -LiteralPath $subOutlook)) {
    . $subOutlook
}

# 2. Context Information Helper: Get-OfficeSuiteContextInfoLines
function Get-OfficeSuiteContextInfoLines {
    <#
    .SYNOPSIS
        Gathers live environment context for the Main Office Suite Hub.
    #>
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

    $lines.Add("Office Platform: Microsoft Office $c2rVer | $c2rArch | Click-to-Run (16.0)")

    # Enumerate running Office applications
    $runningApps = [System.Collections.Generic.List[string]]::new()
    foreach ($proc in @('WINWORD', 'EXCEL', 'POWERPNT', 'OUTLOOK', 'ONENOTE')) {
        try {
            $procs = @(Get-Process -Name $proc -ErrorAction SilentlyContinue)
            if ($procs.Count -gt 0) { $runningApps.Add("$proc ($($procs.Count))") }
        } catch { $null = $_ }
    }

    $activeStr = if ($runningApps.Count -gt 0) { $runningApps -join ', ' } else { 'None [STANDBY]' }
    $lines.Add("Active Suite   : $activeStr")

    $defProf = 'DefaultProfile'
    if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
        try {
            $ctx = Get-OutlookSystemContext
            if ($ctx -and $ctx.DefaultProfile) { $defProf = $ctx.DefaultProfile }
        } catch { $null = $_ }
    }
    $lines.Add("Mail Profile   : Default Profile: $defProf")
    $lines.Add("Console Hub    : Pillar 2 Dispatcher | Pure Numeric 1-Handed Navigation [READY]")

    return $lines.ToArray()
}

function Get-OfficeContextInfoLines {
    [CmdletBinding()]
    param()
    return Get-OfficeSuiteContextInfoLines
}

# 3. Main Dispatcher Function: Invoke-ToolkitSubmenuOfficeSuite
function Invoke-ToolkitSubmenuOfficeSuite {
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
                Write-ToolkitLog -Message "Office Suite Hub launched with -ExitImmediately flag. Returning." -Level INFO -Component 'TUI' -NoConsole
            }
            return
        }

    $inSubmenu = $true
    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $officeInfo = Get-OfficeSuiteContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > OFFICE & PRODUCTIVITY SUITE' `
            -Subtitle 'Central Administration Hub: Suite Health, Word, Excel, PowerPoint & Outlook' `
            -ClearScreen:$clear `
            -InfoLines $officeInfo

        # Informational overview table with -NoIndex to avoid hotkey collisions
        $domains = @(
            [PSCustomObject]@{ Domain = 'Office Suite Common';   Status = '[READY]'; Scope = 'C2R Repair, WAM Identity, Global Cache, Pure Scrubber' },
            [PSCustomObject]@{ Domain = 'Microsoft Word';        Status = '[READY]'; Scope = 'Normal.dotm, Startup Add-ins, Registry Data, Lock Files' },
            [PSCustomObject]@{ Domain = 'Microsoft Excel';       Status = '[READY]'; Scope = 'Hardware Acceleration, XLSTART, UI Cache, DDE, GDI Audit' },
            [PSCustomObject]@{ Domain = 'Microsoft PowerPoint';  Status = '[READY]'; Scope = 'Hardware Acceleration, Font & Slide Cache, Resiliency' },
            [PSCustomObject]@{ Domain = 'Microsoft Outlook';     Status = '[READY]'; Scope = 'PST/OST Data Files, Compaction, SRS Reset, Stuck Outbox' }
        )
        Show-ToolkitItemTable -Items $domains -Columns @('Domain', 'Status', 'Scope') -Headers @('OFFICE DOMAIN', 'STATUS', 'MANAGEMENT SCOPE') -Title 'Productivity Architecture & Application Domains' -NoIndex

        Write-Host ""
        $actions = @(
            @{ Key = '1'; Label = 'Office Suite & General Maintenance' },
            @{ Key = '2'; Label = 'Microsoft Word Repairs' },
            @{ Key = '3'; Label = 'Microsoft Excel Repairs' },
            @{ Key = '4'; Label = 'Microsoft PowerPoint Repairs' },
            @{ Key = '5'; Label = 'Microsoft Outlook & Data Files' }
        )
        $navActions = @(
            @{ Key = '0'; Label = 'Back to Main Menu' }
        )
        Show-ToolkitActionCatalog -Actions $actions -NavActions $navActions -Title 'PRODUCTIVITY SUITE DOMAINS'

        if ($NonInteractive) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Non-interactive category listing complete for 'Office & Productivity Suite'." -Level INFO -Component 'TUI' -NoConsole
            }
            Write-Host "Non-interactive category listing complete for 'Office & Productivity Suite'." -ForegroundColor Cyan
            return
        }

        $validKeys = @('1', '2', '3', '4', '5', '0')
        $promptText = "  Select Office domain [1-5, 0]"
        $selection = Read-ToolkitItemSelection -MaxIndex 0 -ValidHotkeys $validKeys -Prompt $promptText

        if ($null -eq $selection -or $selection.Type -eq 'Exit' -or $selection.Value -eq '0') {
            return
        }

        $actionKey = "$($selection.Value)"
        $subParams = @{
            NonInteractive  = $NonInteractive
            ExitImmediately = $ExitImmediately
            MenuDepth       = $MenuDepth + 1
        }

        switch ($actionKey) {
            '1' {
                if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeCommon' -ErrorAction SilentlyContinue) {
                    Invoke-ToolkitSubmenuOfficeCommon @subParams
                } else {
                    Write-ToolkitStatus -Message "Office Suite Common submenu is not yet loaded." -Type 'WARN'
                    Wait-UserAcknowledge
                }
            }
            '2' {
                if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeWord' -ErrorAction SilentlyContinue) {
                    Invoke-ToolkitSubmenuOfficeWord @subParams
                } else {
                    Write-ToolkitStatus -Message "Microsoft Word submenu is not yet loaded." -Type 'WARN'
                    Wait-UserAcknowledge
                }
            }
            '3' {
                if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeExcel' -ErrorAction SilentlyContinue) {
                    Invoke-ToolkitSubmenuOfficeExcel @subParams
                } else {
                    Write-ToolkitStatus -Message "Microsoft Excel submenu is not yet loaded." -Type 'WARN'
                    Wait-UserAcknowledge
                }
            }
            '4' {
                if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficePowerPoint' -ErrorAction SilentlyContinue) {
                    Invoke-ToolkitSubmenuOfficePowerPoint @subParams
                } else {
                    Write-ToolkitStatus -Message "Microsoft PowerPoint submenu is not yet loaded." -Type 'WARN'
                    Wait-UserAcknowledge
                }
            }
            '5' {
                if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeOutlook' -ErrorAction SilentlyContinue) {
                    Invoke-ToolkitSubmenuOfficeOutlook @subParams
                } else {
                    Write-ToolkitStatus -Message "Microsoft Outlook submenu is not yet loaded." -Type 'WARN'
                    Wait-UserAcknowledge
                }
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


# 4. Backward Compatibility Aliases
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
    if (Get-Command -Name 'Invoke-ToolkitSubmenuOfficeOutlook' -ErrorAction SilentlyContinue) {
        Invoke-ToolkitSubmenuOfficeOutlook @PSBoundParameters
    } else {
        Invoke-ToolkitSubmenuOfficeSuite @PSBoundParameters
    }
}

# 5. Global Session Scope Exports
if (Get-Command -Name 'Get-OfficeSuiteContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-OfficeSuiteContextInfoLines' -Value (Get-Command -Name 'Get-OfficeSuiteContextInfoLines').ScriptBlock
}
if (Get-Command -Name 'Get-OfficeContextInfoLines' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-OfficeContextInfoLines' -Value (Get-Command -Name 'Get-OfficeContextInfoLines').ScriptBlock
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
