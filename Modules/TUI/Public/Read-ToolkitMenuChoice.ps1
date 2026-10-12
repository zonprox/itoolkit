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
    Array of allowed key selections (e.g. @('1', '2', '0')).
.PARAMETER Default
    Default key returned if user presses Enter with empty input.
.OUTPUTS
    [string] Selected menu choice.
.EXAMPLE
    $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', '0')
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Prompt = 'Select',

        [Parameter(Mandatory = $false, Position = 1)]
        [string[]]$ValidKeys = @('1', '2', '3', '4', '5', '9', '0'),

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

        # Handle empty input with default (normalized against ValidKeys)
        if ([string]::IsNullOrWhiteSpace($rawInput) -and -not [string]::IsNullOrWhiteSpace($Default)) {
            $cleanDefault = $Default.Trim().Trim('[', ']').Trim()
            if ($null -ne $ValidKeys -and $ValidKeys.Count -gt 0) {
                foreach ($k in $ValidKeys) {
                    $kStr = $k.ToString().Trim().Trim('[', ']').Trim()
                    if ($kStr.Equals($cleanDefault, [System.StringComparison]::OrdinalIgnoreCase) -or
                        $k.ToString().Equals($Default.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
                        return $k.ToString()
                    }
                }
            }
            return $cleanDefault
        }

        if ($null -eq $rawInput) {
            return ''
        }

        $trimmed = $rawInput.Trim()
        $cleanNumber = $trimmed.Trim('[', ']').Trim()

        # If no validation set specified, return input directly
        if ($null -eq $ValidKeys -or $ValidKeys.Count -eq 0) {
            return $cleanNumber
        }

        # Case-insensitive validation against allowed keys (supports both '1' and bracketed '[1]')
        $matched = $false
        $matchedKey = $null
        foreach ($k in $ValidKeys) {
            $kStr = $k.ToString().Trim().Trim('[', ']').Trim()
            if ($kStr.Equals($cleanNumber, [System.StringComparison]::OrdinalIgnoreCase) -or
                $k.ToString().Equals($trimmed, [System.StringComparison]::OrdinalIgnoreCase)) {
                $matched = $true
                $matchedKey = $k.ToString()
                break
            }
        }

        if ($matched) {
            return $matchedKey
        }

        Write-Host "  Invalid selection '$trimmed'. Valid options: $($ValidKeys -join ', ')" -ForegroundColor Yellow
    }

    # Fallback to avoid infinite loop
    return $trimmed
}
