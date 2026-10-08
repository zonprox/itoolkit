function Get-OutlookComApplication {
<#
.SYNOPSIS
    Returns an Outlook.Application COM object instance on Windows.
.DESCRIPTION
    Safely creates and returns a new instance of the Outlook.Application COM object
    on supported Windows platforms. On non-Windows platforms (e.g. Linux, macOS) or
    if COM instantiation fails, returns $null without throwing terminating errors.
.OUTPUTS
    Outlook.Application COM object or $null.
#>
    [CmdletBinding()]
    param()

    $isWindows = $false
    try {
        if ([System.OperatingSystem]::IsWindows()) { $isWindows = $true }
    }
    catch {
        if ($PSVersionTable.PSEdition -eq 'Desktop' -or $env:OS -match 'Windows') { $isWindows = $true }
    }

    if (-not $isWindows) { return $null }

    try {
        return (New-Object -ComObject 'Outlook.Application')
    }
    catch {
        Write-Verbose "Could not instantiate Outlook.Application COM object: $($_.Exception.Message)"
        return $null
    }
}
