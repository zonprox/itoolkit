function Format-ToolkitTimestamp {
<#
.SYNOPSIS
    Formats a DateTime object into standardized enterprise timestamp strings.
.DESCRIPTION
    Private helper function for IToolkit Core. Generates standardized timestamp
    strings for log records, backup filenames, display summaries, and ISO-8601 formatting.
.PARAMETER DateTime
    The DateTime object to format. Defaults to the current system time.
.PARAMETER Format
    Predefined format pattern:
    - 'Log'      : 'yyyy-MM-dd HH:mm:ss.fff' (default for log records)
    - 'DateOnly' : 'yyyyMMdd' (daily log file suffix)
    - 'File'     : 'yyyyMMdd_HHmmss' (backup filenames)
    - 'Display'  : 'yyyy-MM-dd HH:mm:ss' (console summary display)
    - 'Iso8601'  : 'yyyy-MM-ddTHH:mm:ss.fffZ' (ISO-8601 UTC standard)
.OUTPUTS
    [string] Formatted timestamp.
.EXAMPLE
    Format-ToolkitTimestamp -Format Log
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [datetime]$DateTime = (Get-Date),

        [Parameter(Mandatory = $false, Position = 1)]
        [ValidateSet('Log', 'DateOnly', 'File', 'Display', 'Iso8601')]
        [string]$Format = 'Log'
    )

    $formatPattern = switch ($Format) {
        'Log'      { 'yyyy-MM-dd HH:mm:ss.fff' }
        'DateOnly' { 'yyyyMMdd' }
        'File'     { 'yyyyMMdd_HHmmss' }
        'Display'  { 'yyyy-MM-dd HH:mm:ss' }
        'Iso8601'  { "yyyy-MM-dd'T'HH:mm:ss.fffK" }
        default    { 'yyyy-MM-dd HH:mm:ss.fff' }
    }

    return $DateTime.ToString($formatPattern, [System.Globalization.CultureInfo]::InvariantCulture)
}
