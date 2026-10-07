function Get-ToolkitLayoutWidth {
<#
.SYNOPSIS
    Calculates the dynamic layout width fitted to the current console host window.
.DESCRIPTION
    Inspects host RawUI window size and environment variables to return an optimal layout width
    that expands across wider windows while preventing edge-wrapping.
.PARAMETER Default
    Fallback width when running headless or redirected. Default is 78.
.PARAMETER Min
    Minimum width constraint. Default is 40.
.PARAMETER Max
    Maximum width constraint to avoid over-stretching on ultra-wide monitors. Default is 160.
.OUTPUTS
    [int] Effective layout width in columns.
.EXAMPLE
    $width = Get-ToolkitLayoutWidth
#>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $false)]
        [int]$Default = 78,

        [Parameter(Mandatory = $false)]
        [int]$Min = 40,

        [Parameter(Mandatory = $false)]
        [int]$Max = 160
    )

    try {
        if (-not [Console]::IsOutputRedirected -and $null -ne $Host -and $null -ne $Host.UI -and $null -ne $Host.UI.RawUI) {
            $rawW = $Host.UI.RawUI.WindowSize.Width
            if ($rawW -gt 0) {
                # Leave 2 columns margin so full-width border characters never trigger auto-wrap
                $target = $rawW - 2
                return [math]::Max($Min, [math]::Min($Max, $target))
            }
        }
    }
    catch {
        $null = $_
    }

    if (-not [string]::IsNullOrWhiteSpace($env:COLUMNS)) {
        $parsed = 0
        if ([int]::TryParse($env:COLUMNS, [ref]$parsed) -and $parsed -gt 0) {
            return [math]::Max($Min, [math]::Min($Max, $parsed - 2))
        }
    }

    return $Default
}

if (Get-Command -Name 'Get-ToolkitLayoutWidth' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-ToolkitLayoutWidth' -Value (Get-Command -Name 'Get-ToolkitLayoutWidth').ScriptBlock
}
