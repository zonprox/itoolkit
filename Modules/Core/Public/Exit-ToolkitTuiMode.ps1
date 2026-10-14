function Exit-ToolkitTuiMode {
<#
.SYNOPSIS
    Decrements the re-entrant TUI session depth counter and restores CLI logging upon exit.
.DESCRIPTION
    Decrements $global:ToolkitTuiDepth. When the depth reaches 0 (or when -Force is
    specified), sets $global:ToolkitTuiActive, $global:ToolkitTUIMode, and
    $global:ToolkitSuppressConsoleLog to $false,
    restoring normal console log emission. Guarantees safe cleanup in try/finally blocks.
.PARAMETER Force
    Immediately resets TUI depth to 0 and clears all TUI active flags regardless of depth.
.PARAMETER PassThru
    Returns the remaining TUI session depth after decrementing.
.OUTPUTS
    [int] The remaining TUI session depth when -PassThru is specified; otherwise None.
.EXAMPLE
    Exit-ToolkitTuiMode
.EXAMPLE
    Exit-ToolkitTuiMode -Force
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    process {
        [int]$currentDepth = 0
        if ($null -ne $global:ToolkitTuiDepth) {
            [void][int]::TryParse([string]$global:ToolkitTuiDepth, [ref]$currentDepth)
        }

        $newDepth = $currentDepth - 1
        if ($Force -or $newDepth -le 0) {
            $global:ToolkitTuiDepth = 0
            $global:ToolkitTuiActive = $false
            $global:ToolkitTUIMode = $false
            $global:ToolkitSuppressConsoleLog = $false
            $env:ITOOLKIT_TUI_MODE = $null
            Remove-Item -Path 'env:ITOOLKIT_TUI_MODE' -ErrorAction SilentlyContinue
        }
        else {
            $global:ToolkitTuiDepth = $newDepth
            $global:ToolkitTuiActive = $true
            $global:ToolkitTUIMode = $true
            $global:ToolkitSuppressConsoleLog = $true
            $env:ITOOLKIT_TUI_MODE = '1'
        }

        if ($PassThru) {
            return [int]$global:ToolkitTuiDepth
        }
    }
}
