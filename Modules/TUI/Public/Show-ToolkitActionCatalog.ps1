if (-not (Get-Command -Name 'Get-ToolkitLayoutWidth' -ErrorAction SilentlyContinue)) {
    $widthScript = Join-Path $PSScriptRoot 'Get-ToolkitLayoutWidth.ps1'
    if (Test-Path $widthScript) {
        . $widthScript
    }
}

function Show-ToolkitActionCatalog {
<#
.SYNOPSIS
    Renders a clean, concise action catalog layout with aligned hotkeys and optional navigation options.
.DESCRIPTION
    Displays a structured matrix of concise menu actions in two aligned columns (or single column on narrow
    consoles), followed by optional navigation options (e.g. Back, Exit) separated by dividers.
.PARAMETER Actions
    Collection of action objects or hashtables containing 'Key' and 'Label' properties.
.PARAMETER NavActions
    Optional collection of navigation action objects or hashtables (e.g. Back, Refresh, Exit).
.PARAMETER Title
    Section header title. Defaults to 'ACTIONS & COMMANDS'.
.PARAMETER Columns
    Number of columns to format (1 or 2). Default is 2 when terminal width allows.
.PARAMETER Width
    Total display width. Defaults to 0 (auto-fit to console window).
.EXAMPLE
    $actions = @(
        @{ Key = '1'; Label = 'Scan Data Files' },
        @{ Key = '2'; Label = 'Relocate PST' }
    )
    Show-ToolkitActionCatalog -Actions $actions
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [array]$Actions,

        [Parameter(Mandatory = $false)]
        [array]$NavActions,

        [Parameter(Mandatory = $false)]
        [string]$Title = 'ACTIONS & COMMANDS',

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 4)]
        [int]$Columns = 2,

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

    # Render Section Title
    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        Write-Host "  $Title" -ForegroundColor Yellow
        if (Get-Command -Name 'Write-ToolkitMenuDivider' -ErrorAction SilentlyContinue) {
            Write-ToolkitMenuDivider -Width $Width
        }
        else {
            Write-Host ("  " + ('-' * [math]::Max(20, $Width - 2))) -ForegroundColor DarkGray
        }
    }

    if ($null -eq $Actions -or $Actions.Count -eq 0) {
        return
    }

    # Helper: Normalize action item to Key and Label
    function Get-ActionEntry {
        param($Item)
        $k = ''
        $l = ''
        if ($Item -is [System.Collections.IDictionary]) {
            $k = "$($Item['Key'])"
            $l = "$($Item['Label'])"
            if ([string]::IsNullOrWhiteSpace($l) -and $Item.ContainsKey('Title')) {
                $l = "$($Item['Title'])"
            }
        }
        elseif ($Item -is [PSCustomObject] -or $Item.PSObject) {
            if ($Item.Key) { $k = "$($Item.Key)" }
            if ($Item.Label) { $l = "$($Item.Label)" }
            elseif ($Item.Title) { $l = "$($Item.Title)" }
        }
        elseif ($Item -is [string]) {
            if ($Item -match '^\s*\[?([^\]]+)\]?\s*[:\-\s]\s*(.*)$') {
                $k = $Matches[1].Trim()
                $l = $Matches[2].Trim()
            }
            else {
                $l = $Item.Trim()
            }
        }
        return [PSCustomObject]@{ Key = $k; Label = $l }
    }

    $normalizedActions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($act in $Actions) {
        $entry = Get-ActionEntry -Item $act
        if (-not [string]::IsNullOrWhiteSpace($entry.Key) -or -not [string]::IsNullOrWhiteSpace($entry.Label)) {
            $normalizedActions.Add($entry)
        }
    }

    # Format helper: Render a single action cell with aligned key bracket
    function Render-ActionCell {
        param(
            [PSCustomObject]$Action,
            [int]$TargetWidth,
            [bool]$IsLastColumn
        )

        if ($null -eq $Action) {
            if (-not $IsLastColumn) {
                Write-Host (' ' * $TargetWidth) -NoNewline
            }
            return
        }

        $keyBracket = "[$($Action.Key)]"
        # Aligned key bracket width: standard 5 chars (e.g. "[1]  ", "[10] ")
        $keyPad = 5 - $keyBracket.Length
        if ($keyPad -lt 1) { $keyPad = 1 }

        Write-Host "  $keyBracket" -ForegroundColor Yellow -NoNewline
        Write-Host (' ' * $keyPad) -NoNewline

        $prefixLen = 2 + $keyBracket.Length + $keyPad
        $labelAvail = $TargetWidth - $prefixLen
        if ($labelAvail -lt 5) { $labelAvail = 5 }

        $lbl = $Action.Label
        if ($lbl.Length -gt $labelAvail) {
            $lbl = $lbl.Substring(0, [math]::Max(0, $labelAvail - 3)) + '...'
        }

        Write-Host "$lbl" -ForegroundColor White -NoNewline

        if (-not $IsLastColumn) {
            $currentLen = $prefixLen + $lbl.Length
            $cellPad = $TargetWidth - $currentLen
            if ($cellPad -gt 0) {
                Write-Host (' ' * $cellPad) -NoNewline
            }
        }
    }

    # Decide layout columns (switch to 1 column if narrow)
    $actualCols = $Columns
    if ($Width -lt 70 -and $actualCols -gt 1) {
        $actualCols = 1
    }

    if ($actualCols -eq 1 -or $normalizedActions.Count -le 2) {
        foreach ($a in $normalizedActions) {
            Render-ActionCell -Action $a -TargetWidth $Width -IsLastColumn $true
            Write-Host ""
        }
    }
    else {
        # 2-column layout
        $half = [math]::Ceiling($normalizedActions.Count / 2)
        $colWidth = [math]::Floor(($Width - 2) / 2)

        for ($i = 0; $i -lt $half; $i++) {
            $leftAction = $normalizedActions[$i]
            $rightIdx = $i + $half
            $rightAction = if ($rightIdx -lt $normalizedActions.Count) { $normalizedActions[$rightIdx] } else { $null }

            Render-ActionCell -Action $leftAction -TargetWidth $colWidth -IsLastColumn $false
            Render-ActionCell -Action $rightAction -TargetWidth $colWidth -IsLastColumn $true
            Write-Host ""
        }
    }

    # Render Navigation Actions if provided
    if ($null -ne $NavActions -and $NavActions.Count -gt 0) {
        $normalizedNav = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($nav in $NavActions) {
            $entry = Get-ActionEntry -Item $nav
            if (-not [string]::IsNullOrWhiteSpace($entry.Key) -or -not [string]::IsNullOrWhiteSpace($entry.Label)) {
                $normalizedNav.Add($entry)
            }
        }

        if (Get-Command -Name 'Write-ToolkitMenuDivider' -ErrorAction SilentlyContinue) {
            Write-ToolkitMenuDivider -Width $Width
        }
        else {
            Write-Host ("  " + ('-' * [math]::Max(20, $Width - 2))) -ForegroundColor DarkGray
        }

        if ($normalizedNav.Count -eq 1 -or $Width -lt 70) {
            foreach ($n in $normalizedNav) {
                Render-ActionCell -Action $n -TargetWidth $Width -IsLastColumn $true
                Write-Host ""
            }
        }
        else {
            $halfNav = [math]::Ceiling($normalizedNav.Count / 2)
            $colWidth = [math]::Floor(($Width - 2) / 2)

            for ($j = 0; $j -lt $halfNav; $j++) {
                $leftNav = $normalizedNav[$j]
                $rightNavIdx = $j + $halfNav
                $rightNav = if ($rightNavIdx -lt $normalizedNav.Count) { $normalizedNav[$rightNavIdx] } else { $null }

                Render-ActionCell -Action $leftNav -TargetWidth $colWidth -IsLastColumn $false
                Render-ActionCell -Action $rightNav -TargetWidth $colWidth -IsLastColumn $true
                Write-Host ""
            }
        }
    }
}
