function Read-ToolkitItemSelection {
<#
.SYNOPSIS
    Prompts the user for an item index selection or action hotkey in item-centric TUI workflows.
.DESCRIPTION
    Reads user console input and discriminates between numeric item selection (1..MaxIndex),
    registered action hotkeys, and exit requests. Implements a 5-attempt safeguard against
    infinite loops in non-interactive, headless, or piped console sessions.
.PARAMETER MaxIndex
    Maximum valid numeric item index (1-based).
.PARAMETER ValidHotkeys
    Optional array of allowed action hotkey characters (e.g. '1', '2', '0').
.PARAMETER Prompt
    Custom prompt string displayed to the user. Defaults to "  Select item [1-$MaxIndex] or action".
.OUTPUTS
    [PSCustomObject] with properties:
    - Type: 'Index' | 'Hotkey' | 'Exit'
    - Value: [int] for Index, [string] for Hotkey or Exit
.EXAMPLE
    $choice = Read-ToolkitItemSelection -MaxIndex 5 -ValidHotkeys @('1', '2')
    if ($choice.Type -eq 'Index') { ... }
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [int]$MaxIndex,

        [Parameter(Mandatory = $false, Position = 1)]
        [string[]]$ValidHotkeys,

        [Parameter(Mandatory = $false, Position = 2)]
        [string]$Prompt = "  Select item [1-$MaxIndex] or action"
    )

    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        $Prompt = "  Select item [1-$MaxIndex] or action"
    }

    # Safeguard loop: maximum 5 attempts to prevent hanging in headless sessions
    $maxAttempts = 5
    $attempt = 0

    while ($attempt -lt $maxAttempts) {
        $attempt++

        $rawInput = Read-Host -Prompt $Prompt

        # Handle EOF or null input immediately
        if ($null -eq $rawInput) {
            return [PSCustomObject]@{
                Type  = 'Exit'
                Value = '0'
            }
        }

        $trimmed = $rawInput.Trim()
        $cleanNumber = $trimmed.Trim('[', ']').Trim()

        # Handle numeric exit key '0' or '[0]' (strictly numeric navigation, no letter aliases)
        if ($trimmed -eq '0' -or $cleanNumber -eq '0') {
            return [PSCustomObject]@{
                Type  = 'Exit'
                Value = '0'
            }
        }

        # Pure numeric enforcement: strictly reject letters and non-digit characters
        if ($cleanNumber -match '^\d+$') {
            $parsedIndex = [int]$cleanNumber

            # Prioritize item index check (1..MaxIndex) BEFORE hotkey check
            if ($MaxIndex -gt 0 -and $parsedIndex -ge 1 -and $parsedIndex -le $MaxIndex) {
                return [PSCustomObject]@{
                    Type  = 'Index'
                    Value = $parsedIndex
                }
            }

            # Check registered action hotkeys (purely numeric, e.g. '9', '10', '11', '12')
            if ($null -ne $ValidHotkeys -and $ValidHotkeys.Count -gt 0) {
                foreach ($k in $ValidHotkeys) {
                    if ($null -ne $k) {
                        $kStr = $k.ToString().Trim().Trim('[', ']').Trim()
                        if ($kStr -eq $cleanNumber) {
                            return [PSCustomObject]@{
                                Type  = 'Hotkey'
                                Value = $kStr
                            }
                        }
                    }
                }
            }
        }

        # Informative retry warning displaying full valid choices
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $options = [System.Collections.Generic.List[string]]::new()
            if ($MaxIndex -gt 0) { $options.Add("1-$MaxIndex") }
            if ($null -ne $ValidHotkeys -and $ValidHotkeys.Count -gt 0) {
                foreach ($h in $ValidHotkeys) {
                    if ($null -ne $h) {
                        $hClean = $h.ToString().Trim().Trim('[', ']').Trim()
                        if (-not [string]::IsNullOrWhiteSpace($hClean) -and -not $options.Contains($hClean)) {
                            $options.Add($hClean)
                        }
                    }
                }
            }
            $options.Add('0')
            $hint = $options -join ', '
            Write-Host "  Invalid selection '$trimmed'. Valid options: $hint" -ForegroundColor Yellow
        }
    }

    # Safeguard fallback after 5 attempts
    return [PSCustomObject]@{
        Type  = 'Exit'
        Value = '0'
    }
}

if (Get-Command -Name 'Read-ToolkitItemSelection' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Read-ToolkitItemSelection' -Value (Get-Command -Name 'Read-ToolkitItemSelection').ScriptBlock
}
