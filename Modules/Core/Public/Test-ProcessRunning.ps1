function Test-ProcessRunning {
<#
.SYNOPSIS
    Determines whether a process with the specified name is currently running.
.DESCRIPTION
    Normalizes the process name by removing file extensions and directory paths,
    then queries active processes without throwing terminating errors.
.PARAMETER ProcessName
    The process name or path (e.g. "OUTLOOK", "excel.exe", "C:\Path\spoolsv.exe").
.OUTPUTS
    [bool] True if at least one instance of the process is running; otherwise False.
.EXAMPLE
    Test-ProcessRunning -ProcessName "OUTLOOK"
.EXAMPLE
    "excel.exe" | Test-ProcessRunning
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ProcessName
    )

    process {
        $cleanName = [System.IO.Path]::GetFileNameWithoutExtension($ProcessName)
        try {
            $procs = @(Get-Process -Name $cleanName -ErrorAction SilentlyContinue)
            if ($null -ne $procs -and $procs.Count -gt 0) {
                return $true
            } else {
                return $false
            }
        } catch {
            Write-Verbose "Process query failed for '$cleanName': $($_.Exception.Message)"
            return $false
        }
    }
}
