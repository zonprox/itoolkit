function ConvertFrom-MapiBinaryProperty {
<#
.SYNOPSIS
    Decodes MAPI binary property byte arrays into sanitized strings.
.DESCRIPTION
    Decodes null-terminated UTF-16LE (Unicode, 001f*) and ANSI (001e*) byte arrays.
    Terminates strictly at the first null boundary (2-byte null at even offset for Unicode,
    1-byte null for ANSI) to protect against buffer padding and trailing memory garbage.
    Expands environment variables and returns sanitized string or $null.
.PARAMETER Bytes
    Raw byte array representing the MAPI binary property value.
.PARAMETER PropertyName
    Optional MAPI property name tag (e.g. '001f6700', '001e6700', '001f6620').
.OUTPUTS
    [string] Decoded and expanded string, or $null if empty or invalid.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [object]$Bytes,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$PropertyName
    )

    if ($null -eq $Bytes) {
        return $null
    }

    # If already a string, expand and return
    if ($Bytes -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Bytes)) {
            return $null
        }
        return [System.Environment]::ExpandEnvironmentVariables($Bytes.Trim())
    }

    # Convert to byte array safely
    $raw = $null
    try {
        $raw = [byte[]]$Bytes
    }
    catch {
        return $null
    }

    if ($null -eq $raw -or $raw.Length -eq 0) {
        return $null
    }

    # Helper scriptblock for UTF-16LE decoding (stop at first 2-byte null at even boundary)
    $decodeUnicode = {
        param([byte[]]$buffer)
        if ($null -eq $buffer -or $buffer.Length -lt 2) { return $null }
        $nullIndex = -1
        for ($i = 0; $i -le ($buffer.Length - 2); $i += 2) {
            if ($buffer[$i] -eq 0 -and $buffer[$i + 1] -eq 0) {
                $nullIndex = $i
                break
            }
        }
        $len = if ($nullIndex -ge 0) { $nullIndex } else { $buffer.Length - ($buffer.Length % 2) }
        if ($len -le 0) { return $null }
        return [System.Text.Encoding]::Unicode.GetString($buffer, 0, $len)
    }

    # Helper scriptblock for ANSI decoding (stop at first 1-byte null)
    $decodeAnsi = {
        param([byte[]]$buffer)
        if ($null -eq $buffer -or $buffer.Length -lt 1) { return $null }
        $nullIndex = [System.Array]::IndexOf($buffer, [byte]0)
        $len = if ($nullIndex -ge 0) { $nullIndex } else { $buffer.Length }
        if ($len -le 0) { return $null }
        return [System.Text.Encoding]::Default.GetString($buffer, 0, $len)
    }

    $candidate = $null

    # Tag-directed decoding
    if (-not [string]::IsNullOrWhiteSpace($PropertyName)) {
        if ($PropertyName -like '001f*') {
            $candidate = & $decodeUnicode $raw
        }
        elseif ($PropertyName -like '001e*') {
            $candidate = & $decodeAnsi $raw
        }
    }

    # Heuristic fallback if tag was unspecified or failed to resolve
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $uStr = & $decodeUnicode $raw
        $aStr = & $decodeAnsi $raw

        $isPathLike = {
            param([string]$s)
            if ([string]::IsNullOrWhiteSpace($s)) { return $false }
            return ($s -match '(?i)\.(pst|ost)$' -or $s -match '^[a-zA-Z]:\\' -or $s -match '^\\\\')
        }

        if (& $isPathLike $uStr) {
            $candidate = $uStr
        }
        elseif (& $isPathLike $aStr) {
            $candidate = $aStr
        }
        else {
            $candidate = if (-not [string]::IsNullOrWhiteSpace($uStr)) { $uStr } else { $aStr }
        }
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $null
    }

    return [System.Environment]::ExpandEnvironmentVariables($candidate.Trim())
}
