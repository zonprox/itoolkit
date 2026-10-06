function Test-IsAdmin {
<#
.SYNOPSIS
    Checks if the current PowerShell session has elevated administrative privileges.
.DESCRIPTION
    Inspects the current process security token using .NET WindowsPrincipal and
    evaluates membership in the built-in Administrator role. Compatible with both
    Windows PowerShell 5.1 and PowerShell 7+. Includes fallback for Unix-like CI test hosts.
.OUTPUTS
    [bool] True if elevated as Administrator (or root on Unix); otherwise False.
.EXAMPLE
    if (-not (Test-IsAdmin)) {
        Write-Warning "Administrative privileges required."
    }
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    # Fallback for non-Windows environments (e.g. CI testing on Linux/macOS)
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        try {
            $uid = & id -u 2>$null
            if ($uid -eq 0 -or $uid -eq '0') {
                return $true
            } else {
                return $false
            }
        } catch {
            Write-Verbose "Non-Windows UID check failed: $($_.Exception.Message)"
            return $false
        }
    }

    $identity = $null
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $identity
        return [bool]$principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        Write-Verbose "Failed to determine administrative token: $($_.Exception.Message)"
        return $false
    } finally {
        if ($null -ne $identity) {
            $identity.Dispose()
        }
    }
}
