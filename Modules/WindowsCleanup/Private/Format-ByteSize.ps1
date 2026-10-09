<#
.SYNOPSIS
    Formats a byte count into a human-readable size string.
.DESCRIPTION
    Converts an int64 byte value into standard units (B, KB, MB, GB, TB, PB)
    with two decimal places of precision, or integer for bytes.
.PARAMETER Bytes
    The numeric byte value to format.
.OUTPUTS
    [string] Formatted size representation, e.g. '1.50 GB' or '0 B'.
#>
function Format-ByteSize {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [int64]$Bytes
    )

    process {
        if ($Bytes -le 0) {
            return "0 B"
        }

        $units = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
        $order = 0
        $len = [double]$Bytes

        while ($len -ge 1024.0 -and $order -lt ($units.Count - 1)) {
            $order++
            $len = $len / 1024.0
        }

        if ($order -eq 0) {
            return "{0:N0} {1}" -f $len, $units[$order]
        }
        else {
            return "{0:N2} {1}" -f $len, $units[$order]
        }
    }
}
