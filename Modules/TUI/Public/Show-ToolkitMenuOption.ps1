if (-not (Get-Command -Name 'Get-ToolkitLayoutWidth' -ErrorAction SilentlyContinue)) {
    $widthScript = Join-Path $PSScriptRoot 'Get-ToolkitLayoutWidth.ps1'
    if (Test-Path $widthScript) {
        . $widthScript
    }
}

function Show-ToolkitMenuOption {
<#
.SYNOPSIS
    Displays a formatted menu option item with key, label, category badge, and status indicator.
.DESCRIPTION
    Renders a structured, aligned console menu line with bracketed shortcut key,
    optional category badge, descriptive label, and optional status indicator tag ([OK], [WARN], [FAIL]).
.PARAMETER Key
    Shortcut key or option number (e.g. '1', '2', 'Q').
.PARAMETER Label
    Descriptive text for the menu action.
.PARAMETER Status
    Optional status indicator ('OK', 'WARN', 'FAIL', or custom string).
.PARAMETER Width
    Total width of the menu display for status alignment. Default is 0 (auto-fit to window).
.PARAMETER Category
    Optional category tag shown before the label.
.EXAMPLE
    Show-ToolkitMenuOption -Key '1' -Label 'Outlook & PST Management' -Status 'OK' -Category 'OUTLOOK'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Key,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Label,

        [Parameter(Mandatory = $false, Position = 2)]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 300)]
        [int]$Width = 0,

        [Parameter(Mandatory = $false)]
        [string]$Category
    )

    if ($Width -le 0) {
        if (Get-Command -Name 'Get-ToolkitLayoutWidth' -ErrorAction SilentlyContinue) {
            $Width = Get-ToolkitLayoutWidth
        }
        else {
            $Width = 78
        }
    }

    # Render key bracket with aligned spacing
    $keyDisplay = "  [$Key]"
    $pad = 7 - $keyDisplay.Length
    if ($pad -lt 1) {
        $pad = 1
    }
    Write-Host $keyDisplay -ForegroundColor Yellow -NoNewline
    Write-Host (' ' * $pad) -NoNewline

    # Optional category badge
    if (-not [string]::IsNullOrWhiteSpace($Category)) {
        Write-Host "$Category " -ForegroundColor Cyan -NoNewline
        Write-Host "* " -ForegroundColor DarkGray -NoNewline
    }

    Write-Host "$Label" -ForegroundColor White -NoNewline

    # Render optional status indicator
    if (-not [string]::IsNullOrWhiteSpace($Status)) {
        $normStatus = $Status.ToUpperInvariant()
        $statusColor = [System.ConsoleColor]::Cyan

        if ($normStatus -eq 'OK' -or $normStatus -eq 'SUCCESS') {
            $statusColor = [System.ConsoleColor]::Green
            $tagText = '[OK]'
        }
        elseif ($normStatus -eq 'WARN' -or $normStatus -eq 'WARNING') {
            $statusColor = [System.ConsoleColor]::Yellow
            $tagText = '[WARN]'
        }
        elseif ($normStatus -eq 'FAIL' -or $normStatus -eq 'ERROR') {
            $statusColor = [System.ConsoleColor]::Red
            $tagText = '[FAIL]'
        }
        else {
            $statusColor = [System.ConsoleColor]::Cyan
            $tagText = "[$normStatus]"
        }

        # Calculate alignment spacing
        $currentLength = 7 + $Label.Length
        if (-not [string]::IsNullOrWhiteSpace($Category)) {
            $currentLength += $Category.Length + 3
        }
        $targetCol = $Width - 10
        $padSpaces = 2
        if ($targetCol -gt $currentLength) {
            $padSpaces = $targetCol - $currentLength
        }

        Write-Host (' ' * $padSpaces) -NoNewline
        Write-Host "$tagText" -ForegroundColor $statusColor
    }
    else {
        Write-Host ""
    }
}
