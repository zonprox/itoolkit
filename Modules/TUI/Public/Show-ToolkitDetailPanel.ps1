if (-not (Get-Command -Name 'Get-ToolkitLayoutWidth' -ErrorAction SilentlyContinue)) {
    $widthScript = Join-Path $PSScriptRoot 'Get-ToolkitLayoutWidth.ps1'
    if (Test-Path $widthScript) {
        . $widthScript
    }
}

function Show-ToolkitDetailPanel {
<#
.SYNOPSIS
    Renders the Actions & Commands panel with action descriptions, required elevation, and prerequisite status.
.DESCRIPTION
    Presents structured action descriptions and prerequisite telemetry badges ([READY], [BLOCKED], [SAFE], [FAIL])
    in a dedicated visual panel, concluding with optional navigation options and border.
.PARAMETER Details
    Array of detail items (hashtables, PSCustomObjects, or formatted strings). Supported properties:
    - Key: Action shortcut key (e.g. '1', '2')
    - Action / Label: Action title
    - Description: Concise description of the action
    - Prerequisite: Specific prerequisite condition and status badge
    - Elevation: Required privilege ('Administrator' or 'Standard')
.PARAMETER Title
    Panel header title. Default is 'ACTIONS & COMMANDS'.
.PARAMETER NavActions
    Optional collection of navigation action objects or hashtables (e.g. Back, Refresh, Exit).
.PARAMETER Width
    Total display width. Default is 0 (auto-fit to console).
.PARAMETER NoBottomBorder
    Switch to omit the closing double border line ('=' * Width).
.EXAMPLE
    $details = @(
        @{ Key = '1'; Action = 'Scan Data Files'; Description = 'Deep discovery across registry & disk.'; Prerequisite = 'None [READY]' },
        @{ Key = '2'; Action = 'Relocate PST'; Description = 'Move PST with SHA-256 validation.'; Prerequisite = 'Outlook must be stopped [SAFE]' }
    )
    Show-ToolkitDetailPanel -Details $details
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [array]$Details,

        [Parameter(Mandatory = $false)]
        [string]$Title = 'ACTIONS & COMMANDS',

        [Parameter(Mandatory = $false)]
        [array]$NavActions,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 300)]
        [int]$Width = 0,

        [Parameter(Mandatory = $false)]
        [switch]$NoBottomBorder
    )

    if ($Width -le 0) {
        if (Get-Command -Name 'Get-ToolkitLayoutWidth' -ErrorAction SilentlyContinue) {
            $Width = Get-ToolkitLayoutWidth
        }
        else {
            $Width = 78
        }
    }

    # Render Panel Title
    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        Write-Host "  $Title" -ForegroundColor Yellow
        if (Get-Command -Name 'Write-ToolkitMenuDivider' -ErrorAction SilentlyContinue) {
            Write-ToolkitMenuDivider -Width $Width
        }
        else {
            Write-Host ("  " + ('-' * [math]::Max(20, $Width - 2))) -ForegroundColor DarkGray
        }
    }

    if ($null -eq $Details -or $Details.Count -eq 0) {
        if (-not $NoBottomBorder) {
            Write-Host ('=' * $Width) -ForegroundColor Cyan
        }
        return
    }

    # Helper: Print text with highlighted badges
    function Write-TextWithBadges {
        param(
            [string]$Text,
            [System.ConsoleColor]$DefaultColor = [System.ConsoleColor]::Gray
        )

        if ([string]::IsNullOrEmpty($Text)) {
            Write-Host ""
            return
        }

        # Tokenize by bracketed badges [TAG]
        $pattern = '(\[[^\]]+\])'
        $tokens = [regex]::Split($Text, $pattern)

        foreach ($token in $tokens) {
            if ([string]::IsNullOrEmpty($token)) { continue }

            if ($token -match '^\[.+\]$') {
                $badgeText = $token
                if ($badgeText -match '(?i)\[(READY|SAFE|PASS|YES|OK|ONLINE|CLEAN)') {
                    Write-Host $badgeText -ForegroundColor Green -NoNewline
                }
                elseif ($badgeText -match '(?i)\[(BLOCKED|FAIL|ERROR|NO|OFFLINE)') {
                    Write-Host $badgeText -ForegroundColor Red -NoNewline
                }
                elseif ($badgeText -match '(?i)\[(WARN|WARNING|LIMITED|DEFAULT)') {
                    Write-Host $badgeText -ForegroundColor Yellow -NoNewline
                }
                elseif ($badgeText -match '(?i)\[(INFO|ADMIN|ELEVATED)') {
                    Write-Host $badgeText -ForegroundColor Cyan -NoNewline
                }
                else {
                    Write-Host $badgeText -ForegroundColor Cyan -NoNewline
                }
            }
            else {
                Write-Host $token -ForegroundColor $DefaultColor -NoNewline
            }
        }
        Write-Host ""
    }

    # Process items
    foreach ($item in $Details) {
        if ($item -is [string]) {
            # Direct string line
            Write-TextWithBadges -Text "  $item" -DefaultColor ([System.ConsoleColor]::Gray)
            continue
        }

        # Extract properties
        $k = ''
        $act = ''
        $desc = ''
        $prereq = ''
        $elev = ''

        if ($item -is [System.Collections.IDictionary]) {
            if ($item.ContainsKey('Key')) { $k = "$($item['Key'])" }
            if ($item.ContainsKey('Action')) { $act = "$($item['Action'])" }
            elseif ($item.ContainsKey('Label')) { $act = "$($item['Label'])" }
            if ($item.ContainsKey('Description')) { $desc = "$($item['Description'])" }
            if ($item.ContainsKey('Prerequisite')) { $prereq = "$($item['Prerequisite'])" }
            if ($item.ContainsKey('Elevation')) { $elev = "$($item['Elevation'])" }
        }
        elseif ($item -is [PSCustomObject] -or $item.PSObject) {
            if ($item.Key) { $k = "$($item.Key)" }
            if ($item.Action) { $act = "$($item.Action)" }
            elseif ($item.Label) { $act = "$($item.Label)" }
            if ($item.Description) { $desc = "$($item.Description)" }
            if ($item.Prerequisite) { $prereq = "$($item.Prerequisite)" }
            if ($item.Elevation) { $elev = "$($item.Elevation)" }
        }

        # Extract telemetry badge
        $badge = ''
        if ($prereq -match '(\[[^\]]+\])') {
            $badge = $Matches[1]
        }
        elseif (-not [string]::IsNullOrWhiteSpace($elev)) {
            $badge = "[$elev]"
        }

        # Aligned key bracket and action
        $keyPart = if (-not [string]::IsNullOrWhiteSpace($k)) { "[$k] " } else { "" }
        $actionHeader = "$keyPart$act"
        $pad = 25 - $actionHeader.Length
        if ($pad -lt 1) { $pad = 1 }

        # Calculate space for description if width constraints allow
        $badgeStr = if (-not [string]::IsNullOrWhiteSpace($badge)) { " $badge" } else { "" }
        $prefixLen = 2 + $actionHeader.Length + $pad + 2
        $availDesc = $Width - $prefixLen - $badgeStr.Length
        $renderDesc = $desc
        if ($availDesc -gt 10 -and $renderDesc.Length -gt $availDesc) {
            $renderDesc = $renderDesc.Substring(0, [math]::Max(0, $availDesc - 3)) + '...'
        }

        Write-Host "  " -NoNewline
        if (-not [string]::IsNullOrWhiteSpace($k)) {
            Write-Host "[$k] " -ForegroundColor Yellow -NoNewline
        }
        if (-not [string]::IsNullOrWhiteSpace($act)) {
            Write-Host "$act" -ForegroundColor White -NoNewline
        }
        Write-Host (' ' * $pad) -NoNewline
        Write-Host ": " -ForegroundColor DarkGray -NoNewline
        if (-not [string]::IsNullOrWhiteSpace($renderDesc)) {
            Write-Host "$renderDesc" -ForegroundColor Gray -NoNewline
        }
        if (-not [string]::IsNullOrWhiteSpace($badge)) {
            Write-Host " " -NoNewline
            if ($badge -match '(?i)\[(READY|SAFE|PASS|YES|OK|ONLINE|CLEAN)') {
                Write-Host $badge -ForegroundColor Green -NoNewline
            }
            elseif ($badge -match '(?i)\[(BLOCKED|FAIL|ERROR|NO|OFFLINE)') {
                Write-Host $badge -ForegroundColor Red -NoNewline
            }
            elseif ($badge -match '(?i)\[(WARN|WARNING|LIMITED|DEFAULT)') {
                Write-Host $badge -ForegroundColor Yellow -NoNewline
            }
            else {
                Write-Host $badge -ForegroundColor Cyan -NoNewline
            }
        }
        Write-Host ""
    }

    # Render Navigation Actions if provided
    if ($null -ne $NavActions -and $NavActions.Count -gt 0) {
        if (Get-Command -Name 'Write-ToolkitMenuDivider' -ErrorAction SilentlyContinue) {
            Write-ToolkitMenuDivider -Width $Width
        }
        else {
            Write-Host ("  " + ('-' * [math]::Max(20, $Width - 2))) -ForegroundColor DarkGray
        }

        $navItems = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($nav in $NavActions) {
            $nk = ''
            $nl = ''
            if ($nav -is [System.Collections.IDictionary]) {
                if ($nav.ContainsKey('Key')) { $nk = "$($nav['Key'])" }
                if ($nav.ContainsKey('Label')) { $nl = "$($nav['Label'])" }
                elseif ($nav.ContainsKey('Action')) { $nl = "$($nav['Action'])" }
            }
            elseif ($nav -is [PSCustomObject] -or $nav.PSObject) {
                if ($nav.Key) { $nk = "$($nav.Key)" }
                if ($nav.Label) { $nl = "$($nav.Label)" }
                elseif ($nav.Action) { $nl = "$($nav.Action)" }
            }
            elseif ($nav -is [string]) {
                if ($nav -match '^\s*\[?([^\]]+)\]?\s*[:\-\s]\s*(.*)$') {
                    $nk = $Matches[1].Trim()
                    $nl = $Matches[2].Trim()
                }
                else {
                    $nl = $nav.Trim()
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($nk) -or -not [string]::IsNullOrWhiteSpace($nl)) {
                $navItems.Add([PSCustomObject]@{ Key = $nk; Label = $nl })
            }
        }

        if ($navItems.Count -eq 1 -or $Width -lt 70) {
            foreach ($n in $navItems) {
                Write-Host "  " -NoNewline
                if ($n.Key) { Write-Host "[$($n.Key)] " -ForegroundColor Yellow -NoNewline }
                Write-Host "$($n.Label)" -ForegroundColor White
            }
        }
        elseif ($navItems.Count -eq 2) {
            $colW = [math]::Floor(($Width - 2) / 2)
            $leftStr = "  [$($navItems[0].Key)] $($navItems[0].Label)"
            Write-Host "  [$($navItems[0].Key)] " -ForegroundColor Yellow -NoNewline
            Write-Host "$($navItems[0].Label)" -ForegroundColor White -NoNewline
            $padL = $colW - $leftStr.Length
            if ($padL -gt 0) { Write-Host (' ' * $padL) -NoNewline }
            Write-Host "  [$($navItems[1].Key)] " -ForegroundColor Yellow -NoNewline
            Write-Host "$($navItems[1].Label)" -ForegroundColor White
        }
        else {
            $half = [math]::Ceiling($navItems.Count / 2)
            $colW = [math]::Floor(($Width - 2) / 2)
            for ($i = 0; $i -lt $half; $i++) {
                $left = $navItems[$i]
                $rightIdx = $i + $half
                $right = if ($rightIdx -lt $navItems.Count) { $navItems[$rightIdx] } else { $null }

                $leftStr = "  [$($left.Key)] $($left.Label)"
                Write-Host "  [$($left.Key)] " -ForegroundColor Yellow -NoNewline
                Write-Host "$($left.Label)" -ForegroundColor White -NoNewline
                if ($null -ne $right) {
                    $padW = $colW - $leftStr.Length
                    if ($padW -gt 0) { Write-Host (' ' * $padW) -NoNewline }
                    Write-Host "  [$($right.Key)] " -ForegroundColor Yellow -NoNewline
                    Write-Host "$($right.Label)" -ForegroundColor White
                }
                else {
                    Write-Host ""
                }
            }
        }
    }

    if (-not $NoBottomBorder) {
        Write-Host ('=' * $Width) -ForegroundColor Cyan
    }
}
