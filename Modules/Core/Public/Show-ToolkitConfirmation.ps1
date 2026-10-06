function Show-ToolkitConfirmation {
<#
.SYNOPSIS
    Displays an interactive confirmation prompt with standard Y/N and mandatory YES modes.
.DESCRIPTION
    Provides standardized confirmation prompts for user actions:
    1. Standard Mode: Prompts user with [Y/N] with a configurable default choice.
    2. Mandatory Mode (-Mandatory): Designed for destructive or high-impact actions
       (domain disjoin, profile reset, account deletion). Renders a high-visibility
       warning box and strictly requires typing 'YES' to proceed.
    3. Headless / Automation Support: Supports -Force to bypass prompts in scripts.
       Handles non-interactive environments safely.
.PARAMETER Prompt
    The confirmation question or prompt message.
.PARAMETER ActionName
    Name of the destructive action (used in Mandatory mode warning box).
.PARAMETER Target
    Target system entity, file, or account being modified.
.PARAMETER Impact
    Description of the potential operational impact or irreversibility.
.PARAMETER Default
    Default response when Enter is pressed in Standard mode: $true (Yes) or $false (No).
    Default is $false for safety.
.PARAMETER Mandatory
    Enforces typing 'YES' (case-insensitive) rather than simple single-key input.
.PARAMETER Force
    Switch to bypass confirmation and immediately return $true.
.OUTPUTS
    [bool] Returns $true if confirmed, $false otherwise.
.EXAMPLE
    if (Show-ToolkitConfirmation -Prompt "Do you want to purge temporary files?" -Default $true) {
        # Proceed with cleanup
    }
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Prompt,

        [Parameter(Mandatory = $false)]
        [string]$ActionName,

        [Parameter(Mandatory = $false)]
        [string]$Target,

        [Parameter(Mandatory = $false)]
        [string]$Impact,

        [Parameter(Mandatory = $false)]
        [bool]$Default = $false,

        [Parameter(Mandatory = $false)]
        [switch]$Mandatory,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    # 1. Unattended / Automated Execution Bypass (-Force)
    if ($Force) {
        if (Get-Command -Name Write-ToolkitLog -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Confirmation bypassed via -Force switch: $Prompt" -Level INFO -NoConsole
        }
        return $true
    }

    # 2. Mandatory Destructive Confirmation Mode
    if ($Mandatory) {
        $boxWidth = 76
        $starLine = '*' * $boxWidth

        Write-Host ""
        Write-Host $starLine -ForegroundColor [System.ConsoleColor]::Red
        Write-Host "  CRITICAL / HIGH-IMPACT OPERATION CONFIRMATION" -ForegroundColor [System.ConsoleColor]::Yellow

        if (-not [string]::IsNullOrWhiteSpace($ActionName)) {
            Write-Host "  Action : $ActionName" -ForegroundColor [System.ConsoleColor]::White
        }
        if (-not [string]::IsNullOrWhiteSpace($Target)) {
            Write-Host "  Target : $Target" -ForegroundColor [System.ConsoleColor]::White
        }
        if (-not [string]::IsNullOrWhiteSpace($Impact)) {
            Write-Host "  Impact : $Impact" -ForegroundColor [System.ConsoleColor]::Red
        }

        Write-Host $starLine -ForegroundColor [System.ConsoleColor]::Red
        Write-Host ""
        Write-Host "  To proceed, you MUST explicitly type 'YES' (without quotes)." -ForegroundColor [System.ConsoleColor]::Yellow
        Write-Host "  Press Enter without typing 'YES' to cancel safely." -ForegroundColor [System.ConsoleColor]::Gray

        $response = $null
        try {
            $response = Read-Host -Prompt "  Type 'YES' to confirm"
        } catch {
            Write-Verbose "Read-Host failed in mandatory confirmation: $($_.Exception.Message)"
            return $false
        }

        if ($null -ne $response -and $response.Trim().ToUpperInvariant() -eq 'YES') {
            if (Get-Command -Name Write-ToolkitLog -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Mandatory operation confirmed by user: $ActionName on $Target" -Level INFO -NoConsole
            }
            return $true
        }
        else {
            Write-Host "  [INFO] Operation cancelled by user." -ForegroundColor [System.ConsoleColor]::Yellow
            if (Get-Command -Name Write-ToolkitLog -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Mandatory operation cancelled by user: $ActionName on $Target" -Level WARN -NoConsole
            }
            return $false
        }
    }

    # 3. Standard Confirmation Mode (Y/N)
    $defaultHint = '[y/N]'
    if ($Default) {
        $defaultHint = '[Y/n]'
    }
    $fullPrompt = "  $Prompt $defaultHint"

    $response = $null
    try {
        $response = Read-Host -Prompt $fullPrompt
    } catch {
        Write-Verbose "Read-Host failed in standard confirmation: $($_.Exception.Message)"
        return $Default
    }

    if ([string]::IsNullOrWhiteSpace($response)) {
        return $Default
    }

    $trimmed = $response.Trim().ToUpperInvariant()
    if ($trimmed -eq 'Y' -or $trimmed -eq 'YES') {
        return $true
    }
    elseif ($trimmed -eq 'N' -or $trimmed -eq 'NO') {
        return $false
    }
    else {
        return $Default
    }
}
