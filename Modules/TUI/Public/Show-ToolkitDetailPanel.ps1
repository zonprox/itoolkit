if (-not (Get-Command -Name 'Get-ToolkitLayoutWidth' -ErrorAction SilentlyContinue)) {
    $widthScript = Join-Path $PSScriptRoot 'Get-ToolkitLayoutWidth.ps1'
    if (Test-Path $widthScript) {
        . $widthScript
    }
}

function Show-ToolkitDetailPanel {
<#
.SYNOPSIS
    Renders the Action Details & Prerequisites panel with action descriptions, required elevation, and prerequisite status.
.DESCRIPTION
    Presents structured action descriptions and prerequisite telemetry badges ([READY], [BLOCKED], [SAFE], [FAIL])
    in a dedicated visual panel, ensuring administrators understand action impact and requirements before execution.
.PARAMETER Details
    Array of detail items (hashtables, PSCustomObjects, or formatted strings). Supported properties:
    - Key: Action shortcut key (e.g. '1', '2')
    - Action / Label: Action title
    - Description: Concise description of the action
    - Prerequisite: Specific prerequisite condition and status badge
    - Elevation: Required privilege ('Administrator' or 'Standard')
.PARAMETER Title
    Panel header title. Default is 'ACTION DETAILS & PREREQUISITES'.
.PARAMETER Width
    Total display width. Default is 0 (auto-fit to console).
.EXAMPLE
    $details = @(
        @{ Key = '1'; Action = 'Scan Data Files'; Description = 'Deep discovery across registry & disk.'; Prerequisite = 'None [READY]' },
        @{ Key = '2'; Action = 'Relocate PST'; Description = 'Move PST with SHA-256 validation.'; Prerequisite = 'Outlook must be stopped [READY]' }
    )
    Show-ToolkitDetailPanel -Details $details
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [array]$Details,

        [Parameter(Mandatory = $false)]
        [string]$Title = 'ACTION DETAILS & PREREQUISITES',

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 300)]
        [int]$Width = 0
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
        Write-Host ""
        Write-Host "  $Title" -ForegroundColor Yellow
        if (Get-Command -Name 'Write-ToolkitMenuDivider' -ErrorAction SilentlyContinue) {
            Write-ToolkitMenuDivider -Width $Width
        }
        else {
            Write-Host ("  " + ('-' * [math]::Max(20, $Width - 2))) -ForegroundColor DarkGray
        }
    }

    if ($null -eq $Details -or $Details.Count -eq 0) {
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

        # Build prefix e.g. "  [1] Scan Data Files     : "
        $keyPart = if (-not [string]::IsNullOrWhiteSpace($k)) { "[$k] " } else { "" }
        $actionHeader = "$keyPart$act"
        # Standardize prefix alignment to 25 chars
        $pad = 25 - $actionHeader.Length
        if ($pad -lt 1) { $pad = 1 }

        # Render first line
        Write-Host "  " -NoNewline
        if (-not [string]::IsNullOrWhiteSpace($k)) {
            Write-Host "[$k] " -ForegroundColor Yellow -NoNewline
        }
        if (-not [string]::IsNullOrWhiteSpace($act)) {
            Write-Host "$act" -ForegroundColor White -NoNewline
        }
        Write-Host (' ' * $pad) -NoNewline
        Write-Host ": " -ForegroundColor DarkGray -NoNewline

        # Description text
        Write-TextWithBadges -Text $desc -DefaultColor ([System.ConsoleColor]::Gray)

        # Render Prerequisite or Elevation if present
        if (-not [string]::IsNullOrWhiteSpace($prereq) -or -not [string]::IsNullOrWhiteSpace($elev)) {
            $indentSpaces = ' ' * 29
            Write-Host $indentSpaces -NoNewline
            Write-Host "Prerequisite: " -ForegroundColor DarkGray -NoNewline

            $prereqFull = $prereq
            if (-not [string]::IsNullOrWhiteSpace($elev) -and [string]::IsNullOrWhiteSpace($prereq)) {
                $prereqFull = "$elev elevation required [READY]"
            }
            Write-TextWithBadges -Text $prereqFull -DefaultColor ([System.ConsoleColor]::DarkCyan)
        }
    }
}
