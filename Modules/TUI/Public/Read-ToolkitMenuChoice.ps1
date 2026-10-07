function Read-ToolkitMenuChoice {
<#
.SYNOPSIS
    Prompts the user for a console menu selection and validates against allowed keys.
.DESCRIPTION
    Prompts for input via Read-Host, validates selection against -ValidKeys case-insensitively,
    and returns the selected key string. Includes safety counter to avoid infinite loops
    in automated or non-interactive test harnesses.
.PARAMETER Prompt
    Prompt text displayed to user. Default is 'Select Option'.
.PARAMETER ValidKeys
    Array of allowed key selections (e.g. @('1', '2', 'Q')).
.PARAMETER Default
    Default key returned if user presses Enter with empty input.
.OUTPUTS
    [string] Selected menu choice.
.EXAMPLE
    $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', 'Q')
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Prompt = 'Select',

        [Parameter(Mandatory = $false, Position = 1)]
        [string[]]$ValidKeys = @('1', '2', '3', '4', '5', '6', 'Q'),

        [Parameter(Mandatory = $false)]
        [string]$Default
    )

    $cleanPrompt = $Prompt.TrimEnd(':', ' ')
    if ([string]::IsNullOrWhiteSpace($cleanPrompt) -or $cleanPrompt -match '^(?i)Select(\s+[^\[:]+)?(\s*\[.*\])?$') {
        $cleanPrompt = 'Select'
    }
    $promptString = "  $cleanPrompt"
    if (-not [string]::IsNullOrWhiteSpace($Default)) {
        $promptString = "$promptString (Default: $Default)"
    }

    # Safeguard loop: maximum 5 attempts to prevent hanging in headless sessions
    $maxAttempts = 5
    $attempt = 0

    while ($attempt -lt $maxAttempts) {
        $attempt++

        $rawInput = Read-Host -Prompt $promptString

        # Handle empty input with default
        if ([string]::IsNullOrWhiteSpace($rawInput) -and -not [string]::IsNullOrWhiteSpace($Default)) {
            return $Default
        }

        if ($null -eq $rawInput) {
            return ''
        }

        $trimmed = $rawInput.Trim()

        # If no validation set specified, return input directly
        if ($null -eq $ValidKeys -or $ValidKeys.Count -eq 0) {
            return $trimmed
        }

        # Case-insensitive validation against allowed keys
        $matched = $false
        foreach ($k in $ValidKeys) {
            if ($k.ToString().Equals($trimmed, [System.StringComparison]::OrdinalIgnoreCase)) {
                $matched = $true
                break
            }
        }

        if ($matched) {
            return $trimmed
        }

        Write-Host "  Invalid selection '$trimmed'. Valid options: $($ValidKeys -join ', ')" -ForegroundColor Yellow
    }

    # Fallback to avoid infinite loop
    return $trimmed
}
