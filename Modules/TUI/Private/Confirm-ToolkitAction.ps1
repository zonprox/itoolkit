<#
.SYNOPSIS
    Prompts the user for interactive confirmation before executing potentially destructive actions.
.DESCRIPTION
    Prompts via Read-Host with [y/N] when running interactively. Defaults to No ($false)
    if the user presses Enter (empty input), 'n', $null, or any input other than 'y' / 'yes'.
    Automatically bypasses confirmation ($true) in non-interactive mode (-NonInteractive).
#>
function Confirm-ToolkitAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$ActionDescription,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    if ($NonInteractive) {
        return $true
    }

    try {
        $raw = Read-Host -Prompt "  Confirm $ActionDescription? [y/N]"
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $false
        }
        return [bool]($raw.Trim() -match '^(?i)y(?:es)?$')
    }
    catch {
        return $false
    }
}

if (Get-Command -Name 'Confirm-ToolkitAction' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Confirm-ToolkitAction' -Value (Get-Command -Name 'Confirm-ToolkitAction').ScriptBlock
}
