function Show-ToolkitHeader {
<#
.SYNOPSIS
    Renders a consistent enterprise console header banner with title and optional subtitle.
.DESCRIPTION
    Draws a formatted ASCII banner with border lines, system environment info,
    and high-visibility coloring. Optionally clears the console host when running in an interactive terminal.
.PARAMETER Title
    The primary banner title text.
.PARAMETER Subtitle
    Optional subtitle or status description.
.PARAMETER Width
    Width of the banner in characters. Default is 78.
.PARAMETER ClearScreen
    Switch to clear host screen before drawing the banner.
.PARAMETER NoSystemInfo
    Switch to omit the system info status bar.
.PARAMETER InfoLines
    Array of diagnostic information lines to render inside the banner box.
.EXAMPLE
    Show-ToolkitHeader -Title 'IToolkit Main Menu' -Subtitle 'Enterprise IT Support' -ClearScreen -InfoLines @('CPU: 8 Cores', 'RAM: 16 GB')
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Title,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$Subtitle,

        [Parameter(Mandatory = $false)]
        [ValidateRange(40, 120)]
        [int]$Width = 78,

        [Parameter(Mandatory = $false)]
        [switch]$ClearScreen,

        [Parameter(Mandatory = $false)]
        [switch]$NoSystemInfo,

        [Parameter(Mandatory = $false)]
        [string[]]$InfoLines
    )

    if ($ClearScreen) {
        try {
            if (-not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected) {
                Clear-Host
            }
        }
        catch {
            # In non-interactive or Linux test environments, ignore Clear-Host failure
            $null = $_
        }
    }

    $borderLine = '=' * $Width
    $subBorderLine = '-' * $Width

    Write-Host ""
    Write-Host $borderLine -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
        Write-Host "  $Subtitle" -ForegroundColor DarkCyan
    }

    if ($null -ne $InfoLines -and $InfoLines.Count -gt 0) {
        Write-Host $subBorderLine -ForegroundColor DarkGray
        foreach ($line in $InfoLines) {
            $colonIdx = $line.IndexOf(':')
            if ($colonIdx -gt 0) {
                $keyPart = $line.Substring(0, $colonIdx + 1)
                $valPart = $line.Substring($colonIdx + 1)
                Write-Host "  $keyPart" -ForegroundColor DarkCyan -NoNewline

                $valColor = [System.ConsoleColor]::White
                if ($valPart -match '(?i)\[Elevated|\[YES\]|\[Safe|Clean|Online|Running|Expanded') {
                    $valColor = [System.ConsoleColor]::Green
                }
                elseif ($valPart -match '(?i)\[Non-Elevated|\[NO\]|\[Default|Stopped|Stuck|Offline|Low') {
                    $valColor = [System.ConsoleColor]::Yellow
                }
                Write-Host "$valPart" -ForegroundColor $valColor
            }
            else {
                Write-Host "  $line" -ForegroundColor DarkCyan
            }
        }
    }
    elseif (-not $NoSystemInfo) {
        $hostName = $env:COMPUTERNAME
        if ([string]::IsNullOrWhiteSpace($hostName)) {
            $hostName = [System.Environment]::MachineName
        }
        $userName = $env:USERNAME
        if ([string]::IsNullOrWhiteSpace($userName)) {
            $userName = [System.Environment]::UserName
        }
        $psVer = "PS " + $PSVersionTable.PSVersion.Major + "." + $PSVersionTable.PSVersion.Minor

        $adminTag = "Admin: [?]"
        if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
            try {
                $isAdmin = Test-IsAdmin
                if ($isAdmin) {
                    $adminTag = "Admin: [YES]"
                }
                else {
                    $adminTag = "Admin: [NO]"
                }
            }
            catch {
                $adminTag = "Admin: [?]"
            }
        }

        Write-Host $subBorderLine -ForegroundColor DarkGray
        Write-Host "  Host: $hostName | User: $userName | $adminTag | $psVer" -ForegroundColor DarkCyan
    }

    Write-Host $borderLine -ForegroundColor Cyan
    Write-Host ""
}
