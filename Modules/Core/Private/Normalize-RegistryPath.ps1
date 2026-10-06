function Normalize-RegistryPath {
<#
.SYNOPSIS
    Normalizes arbitrary registry path formats into consistent native, PowerShell, or canonical syntax.
.DESCRIPTION
    Accepts registry paths formatted with PowerShell drive colons (HKLM:\), native roots (HKLM\),
    canonical hive names (HKEY_LOCAL_MACHINE\), forward slashes, or PowerShell provider prefixes,
    and returns the standardized path in the requested format.
.PARAMETER Path
    The registry key path to normalize.
.PARAMETER Format
    Target format:
    - 'Native': Standard format required by reg.exe (e.g. HKLM\Software\...)
    - 'PowerShell': Standard PSDrive format required by PowerShell provider (e.g. HKLM:\Software\...)
    - 'Standard': Canonical hive name format (e.g. HKEY_LOCAL_MACHINE\Software\...)
.OUTPUTS
    [string] Normalized registry path.
.EXAMPLE
    Normalize-RegistryPath -Path "HKLM:\Software\Microsoft" -Format Native
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $false, Position = 1)]
        [ValidateSet('Native', 'PowerShell', 'Standard')]
        [string]$Format = 'Native'
    )

    process {
        # Strip PowerShell registry provider prefix if present
        $clean = $Path -replace '^(?:[A-Za-z0-9_.]+\\)?Registry::', ''

        # Normalize slashes and redundant separators
        $clean = $clean -replace '/', '\'
        $clean = $clean -replace '\\+', '\'
        $clean = $clean.TrimEnd('\')

        # Match root hive prefix and optional subpath
        $pattern = '^(HKLM|HKEY_LOCAL_MACHINE|HKCU|HKEY_CURRENT_USER|HKCR|HKEY_CLASSES_ROOT|HKU|HKEY_USERS|HKCC|HKEY_CURRENT_CONFIG):?(?:\\(.*))?$'
        if ($clean -notmatch $pattern) {
            throw [System.ArgumentException]::new("Invalid or unsupported registry hive prefix in path '$Path'. Expected HKLM, HKCU, HKCR, HKU, or HKCC.")
        }

        $rootMatch = $Matches[1].ToUpperInvariant()
        $subPath = ''
        if ($Matches.Count -gt 2 -and -not [string]::IsNullOrEmpty($Matches[2])) {
            $subPath = $Matches[2]
        }

        $nativeRoot = $null
        $psRoot     = $null
        $fullRoot   = $null

        switch -Regex ($rootMatch) {
            '^(HKLM|HKEY_LOCAL_MACHINE)$' {
                $nativeRoot = 'HKLM'
                $psRoot     = 'HKLM:'
                $fullRoot   = 'HKEY_LOCAL_MACHINE'
            }
            '^(HKCU|HKEY_CURRENT_USER)$' {
                $nativeRoot = 'HKCU'
                $psRoot     = 'HKCU:'
                $fullRoot   = 'HKEY_CURRENT_USER'
            }
            '^(HKCR|HKEY_CLASSES_ROOT)$' {
                $nativeRoot = 'HKCR'
                $psRoot     = 'HKCR:'
                $fullRoot   = 'HKEY_CLASSES_ROOT'
            }
            '^(HKU|HKEY_USERS)$' {
                $nativeRoot = 'HKU'
                $psRoot     = 'HKU:'
                $fullRoot   = 'HKEY_USERS'
            }
            '^(HKCC|HKEY_CURRENT_CONFIG)$' {
                $nativeRoot = 'HKCC'
                $psRoot     = 'HKCC:'
                $fullRoot   = 'HKEY_CURRENT_CONFIG'
            }
            default {
                throw [System.ArgumentException]::new("Unsupported registry hive prefix '$rootMatch'.")
            }
        }

        if ($Format -eq 'Native') {
            if (-not [string]::IsNullOrEmpty($subPath)) {
                return "$nativeRoot\$subPath"
            } else {
                return $nativeRoot
            }
        }
        elseif ($Format -eq 'PowerShell') {
            if (-not [string]::IsNullOrEmpty($subPath)) {
                return "$psRoot\$subPath"
            } else {
                return "$psRoot\"
            }
        }
        elseif ($Format -eq 'Standard') {
            if (-not [string]::IsNullOrEmpty($subPath)) {
                return "$fullRoot\$subPath"
            } else {
                return $fullRoot
            }
        }
    }
}
