function Enter-ToolkitTuiMode {
<#
.SYNOPSIS
    Enables TUI mode and increments the re-entrant TUI session depth counter.
.DESCRIPTION
    Increments $global:ToolkitTuiDepth and sets $global:ToolkitTuiActive to $true.
    Suppresses console log emission across Write-ToolkitLog and Write-AppInstallerLog
    while preserving full file-based logging. Supports re-entrant invocation across
    nested submenus and contextual action dialogs.
.PARAMETER PassThru
    Returns the current TUI session depth after incrementing.
.OUTPUTS
    [int] The current TUI session depth when -PassThru is specified; otherwise None.
.EXAMPLE
    Enter-ToolkitTuiMode
.EXAMPLE
    $depth = Enter-ToolkitTuiMode -PassThru
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    process {
        [int]$currentDepth = 0
        if ($null -ne $global:ToolkitTuiDepth) {
            [void][int]::TryParse([string]$global:ToolkitTuiDepth, [ref]$currentDepth)
            if ($currentDepth -lt 0) {
                $currentDepth = 0
            }
        }

        $currentDepth++
        $global:ToolkitTuiDepth = $currentDepth
        $global:ToolkitTuiActive = $true
        $global:ToolkitTUIMode = $true
        $global:ToolkitSuppressConsoleLog = $true
        $env:ITOOLKIT_TUI_MODE = '1'

        if ($PassThru) {
            return $currentDepth
        }
    }
}
