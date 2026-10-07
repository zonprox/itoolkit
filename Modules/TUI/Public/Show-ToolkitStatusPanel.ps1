if (-not (Get-Command -Name 'Get-ToolkitLayoutWidth' -ErrorAction SilentlyContinue)) {
    $widthScript = Join-Path $PSScriptRoot 'Get-ToolkitLayoutWidth.ps1'
    if (Test-Path $widthScript) {
        . $widthScript
    }
}

function Show-ToolkitStatusPanel {
<#
.SYNOPSIS
    Renders the Live Contextual Status & Telemetry panel displaying system context and operational badges.
.DESCRIPTION
    Presents real-time operational context, service states, and operational badges ([READY], [BLOCKED],
    [SAFE], [FAIL]) in a dedicated visual panel, concluding with a standard terminal boundary.
.PARAMETER StatusItems
    Array of status telemetry lines or key-value objects/hashtables.
.PARAMETER Title
    Panel header title. Default is 'LIVE CONTEXTUAL STATUS & TELEMETRY'.
.PARAMETER Width
    Total display width. Default is 0 (auto-fit to console).
.PARAMETER NoBottomBorder
    Switch to omit the closing double border line ('=' * Width).
.EXAMPLE
    $status = @(
        'Outlook State  : Stopped [SAFE TO MOVE DATA FILES]',
        'Default Profile: Outlook (Office 16.0 / 365)',
        'PST Policy     : Default limit (~50 GB threshold)'
    )
    Show-ToolkitStatusPanel -StatusItems $status
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [array]$StatusItems,

        [Parameter(Mandatory = $false)]
        [string]$Title = 'LIVE CONTEXTUAL STATUS & TELEMETRY',

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
        Write-Host ""
        Write-Host "  $Title" -ForegroundColor Yellow
        if (Get-Command -Name 'Write-ToolkitMenuDivider' -ErrorAction SilentlyContinue) {
            Write-ToolkitMenuDivider -Width $Width
        }
        else {
            Write-Host ("  " + ('-' * [math]::Max(20, $Width - 2))) -ForegroundColor DarkGray
        }
    }

    if ($null -eq $StatusItems -or $StatusItems.Count -eq 0) {
        if (-not $NoBottomBorder) {
            Write-Host ('=' * $Width) -ForegroundColor Cyan
        }
        return
    }

    # Helper: Print text with highlighted badges
    function Write-StatusLineWithBadges {
        param(
            [string]$Label,
            [string]$Value
        )

        # Print label with aligned spacing
        $pad = 16 - $Label.Length
        if ($pad -lt 1) { $pad = 1 }

        Write-Host "  $Label" -ForegroundColor DarkCyan -NoNewline
        Write-Host (' ' * $pad) -NoNewline
        Write-Host ": " -ForegroundColor DarkGray -NoNewline

        if ([string]::IsNullOrEmpty($Value)) {
            Write-Host ""
            return
        }

        # Tokenize value by bracketed badges [TAG]
        $pattern = '(\[[^\]]+\])'
        $tokens = [regex]::Split($Value, $pattern)

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
                # Highlighting keywords outside brackets if appropriate
                $color = [System.ConsoleColor]::White
                if ($token -match '(?i)(Stopped|Clean|Enabled|Running|Expanded)') {
                    $color = [System.ConsoleColor]::White
                }
                Write-Host $token -ForegroundColor $color -NoNewline
            }
        }
        Write-Host ""
    }

    # Process items
    foreach ($item in $StatusItems) {
        if ($item -is [string]) {
            $colonIdx = $item.IndexOf(':')
            if ($colonIdx -gt 0) {
                $lbl = $item.Substring(0, $colonIdx).Trim()
                $val = $item.Substring($colonIdx + 1).Trim()
                Write-StatusLineWithBadges -Label $lbl -Value $val
            }
            else {
                Write-Host "  $item" -ForegroundColor White
            }
            continue
        }

        $lbl = ''
        $val = ''
        if ($item -is [System.Collections.IDictionary]) {
            if ($item.ContainsKey('Label')) { $lbl = "$($item['Label'])" }
            elseif ($item.ContainsKey('Key')) { $lbl = "$($item['Key'])" }
            if ($item.ContainsKey('Value')) { $val = "$($item['Value'])" }
        }
        elseif ($item -is [PSCustomObject] -or $item.PSObject) {
            if ($item.Label) { $lbl = "$($item.Label)" }
            elseif ($item.Key) { $lbl = "$($item.Key)" }
            if ($item.Value) { $val = "$($item.Value)" }
        }

        if (-not [string]::IsNullOrWhiteSpace($lbl)) {
            Write-StatusLineWithBadges -Label $lbl -Value $val
        }
    }

    if (-not $NoBottomBorder) {
        Write-Host ('=' * $Width) -ForegroundColor Cyan
    }
}
