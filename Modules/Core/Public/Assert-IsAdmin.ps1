function Assert-IsAdmin {
<#
.SYNOPSIS
    Asserts that the current session is running with elevated administrative privileges.
.DESCRIPTION
    Calls Test-IsAdmin and throws a terminating PermissionDenied error record if the session
    is not elevated. Ensures critical operations fail-closed before modifying system state.
.PARAMETER ErrorMessage
    Custom error message to display when privilege check fails.
.OUTPUTS
    None. Throws terminating error on failure.
.EXAMPLE
    Assert-IsAdmin
.EXAMPLE
    Assert-IsAdmin -ErrorMessage "Elevation required to purge print spooler queues."
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ErrorMessage = "Administrative privileges are required to perform this operation. Please restart PowerShell as Administrator."
    )

    if (-not (Test-IsAdmin)) {
        if (Get-Command -Name Write-ToolkitLog -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message $ErrorMessage -Level 'ERROR' -Component 'Assert-IsAdmin'
        }

        $exception = New-Object -TypeName System.Security.SecurityException -ArgumentList $ErrorMessage
        $errorRecord = New-Object -TypeName System.Management.Automation.ErrorRecord -ArgumentList @(
            $exception,
            'ElevationRequired',
            [System.Management.Automation.ErrorCategory]::PermissionDenied,
            $null
        )
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }
}
