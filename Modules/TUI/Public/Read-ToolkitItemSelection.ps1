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
    Optional array of allowed action hotkey characters (e.g. 'A', 'B', 'R', 'Q').
.PARAMETER Prompt
    Custom prompt string displayed to the user. Defaults to "  Select item [1-$MaxIndex] or action".
.OUTPUTS
    [PSCustomObject] with properties:
    - Type: 'Index' | 'Hotkey' | 'Exit'
    - Value: [int] for Index, [string] for Hotkey or Exit
.EXAMPLE
    $choice = Read-ToolkitItemSelection -MaxIndex 5 -ValidHotkeys @('B', 'R')
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
                Value = 'Q'
            }
        }

        $trimmed = $rawInput.Trim()

        # Handle numeric index selection (supports both '1' and bracketed '[1]')
        $cleanNumber = $trimmed.Trim('[', ']').Trim()
        $parsedIndex = 0
        if ([int]::TryParse($cleanNumber, [ref]$parsedIndex)) {
            if ($parsedIndex -ge 1 -and $parsedIndex -le $MaxIndex) {
                return [PSCustomObject]@{
                    Type  = 'Index'
                    Value = $parsedIndex
                }
            }
        }

        # Handle registered action hotkeys (case-insensitive)
        if ($null -ne $ValidHotkeys -and $ValidHotkeys.Count -gt 0) {
            $upperTrimmed = $trimmed.ToUpper()
            foreach ($k in $ValidHotkeys) {
                if ($null -ne $k) {
                    $kStr = $k.ToString().Trim().Trim('[', ']').Trim()
                    if ($kStr.Equals($cleanNumber, [System.StringComparison]::OrdinalIgnoreCase) -or
                        $kStr.Equals($upperTrimmed, [System.StringComparison]::OrdinalIgnoreCase)) {
                        return [PSCustomObject]@{
                            Type  = 'Hotkey'
                            Value = $upperTrimmed
                        }
                    }
                }
            }
        }

        # Handle standard exit commands
        if ($trimmed.Equals('Q', [System.StringComparison]::OrdinalIgnoreCase) -or
            $trimmed.Equals('QUIT', [System.StringComparison]::OrdinalIgnoreCase) -or
            $trimmed.Equals('EXIT', [System.StringComparison]::OrdinalIgnoreCase)) {
            return [PSCustomObject]@{
                Type  = 'Exit'
                Value = 'Q'
            }
        }

        # Provide helpful hint on invalid input if not empty
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $hint = ''
            if ($null -ne $ValidHotkeys -and $ValidHotkeys.Count -gt 0) {
                $hint = "1-$MaxIndex, $($ValidHotkeys -join ', ')"
            }
            else {
                $hint = "1-$MaxIndex, Q"
            }
            Write-Host "  Invalid selection '$trimmed'. Valid options: $hint" -ForegroundColor Yellow
        }
    }

    # Safeguard fallback after 5 attempts
    return [PSCustomObject]@{
        Type  = 'Exit'
        Value = 'Q'
    }
}

if (Get-Command -Name 'Read-ToolkitItemSelection' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Read-ToolkitItemSelection' -Value (Get-Command -Name 'Read-ToolkitItemSelection').ScriptBlock
}
