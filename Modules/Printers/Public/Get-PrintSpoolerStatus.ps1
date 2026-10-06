function Get-PrintSpoolerStatus {
<#
.SYNOPSIS
    Retrieves Print Spooler service status, process PID, and print queue file statistics.
.DESCRIPTION
    Queries the 'Spooler' service state and startup type, identifies the active
    spoolsv.exe process ID, and inspects the spool queue directory for stuck print jobs.
.OUTPUTS
    [PSCustomObject] containing ServiceStatus, PID, QueueFileCount, QueueSizeBytes, StartupType.
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    process {
        # 1. Query Spooler Service
        $serviceStatus = 'Stopped'
        $startupType   = 'Unknown'
        try {
            $svc = Get-Service -Name 'Spooler' -ErrorAction SilentlyContinue
            if ($null -ne $svc) {
                $serviceStatus = $svc.Status.ToString()
                if ($svc.PSObject.Properties['StartType'] -and $null -ne $svc.StartType) {
                    $startupType = $svc.StartType.ToString()
                }
            }
        } catch {
            Write-Verbose "Error querying Spooler service: $($_.Exception.Message)"
        }

        # 2. Query spoolsv process
        $spoolerPid = $null
        try {
            $proc = Get-Process -Name 'spoolsv' -ErrorAction SilentlyContinue
            if ($null -ne $proc) {
                if ($proc -is [System.Array]) {
                    $spoolerPid = $proc[0].Id
                } else {
                    $spoolerPid = $proc.Id
                }
            }
        } catch {
            Write-Verbose "Error querying spoolsv process: $($_.Exception.Message)"
        }

        # 3. Resolve Spool Directory
        $spoolDir = "$env:SystemRoot\System32\spool\PRINTERS"
        try {
            $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Print\Printers"
            $regProp = Get-ItemProperty -Path $regPath -Name 'DefaultSpoolDirectory' -ErrorAction SilentlyContinue
            if ($null -ne $regProp -and -not [string]::IsNullOrWhiteSpace($regProp.DefaultSpoolDirectory)) {
                $spoolDir = $regProp.DefaultSpoolDirectory
            }
        } catch {
            Write-Verbose "Error reading DefaultSpoolDirectory: $($_.Exception.Message)"
        }

        # 4. Count and measure queue files
        $fileCount  = 0
        $totalBytes = [int64]0
        try {
            $files = @(Get-ChildItem -Path $spoolDir -ErrorAction SilentlyContinue)
            $fileCount = $files.Count
            foreach ($f in $files) {
                if ($null -ne $f -and $f.PSObject.Properties['Length'] -and $null -ne $f.Length) {
                    $totalBytes += [int64]$f.Length
                }
            }
        } catch {
            Write-Verbose "Error enumerating spool directory: $($_.Exception.Message)"
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Print Spooler Status: $serviceStatus (PID: $spoolerPid), Queue: $fileCount file(s), $totalBytes byte(s)" -Level 'INFO' -Component 'Get-PrintSpoolerStatus'
        }

        return [PSCustomObject]@{
            ServiceStatus  = $serviceStatus
            PID            = $spoolerPid
            QueueFileCount = [int]$fileCount
            QueueSizeBytes = [int64]$totalBytes
            StartupType    = $startupType
        }
    }
}
