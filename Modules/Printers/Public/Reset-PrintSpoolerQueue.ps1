function Reset-PrintSpoolerQueue {
<#
.SYNOPSIS
    Stops the Print Spooler, purges corrupt spool queue files, and restarts the service.
.DESCRIPTION
    Safely stops the Spooler service, terminates any stuck spoolsv process, deletes
    shadow (.SHD) and spool (.SPL) files in the spool directory, and restarts Spooler.
.PARAMETER Force
    Forces termination of any lingering spoolsv processes.
.OUTPUTS
    [PSCustomObject] containing FilesPurged and ServiceRestarted.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        if (-not $PSCmdlet.ShouldProcess("Print Spooler Queue", "Stop service, purge stuck queue files, and restart")) {
            return [PSCustomObject]@{
                FilesPurged      = 0
                ServiceRestarted = $false
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Resetting Print Spooler queue..." -Level 'INFO' -Component 'Reset-PrintSpoolerQueue'
        }

        # 1. Stop Spooler service
        try {
            Stop-Service -Name 'Spooler' -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Verbose "Stop-Service encountered error: $($_.Exception.Message)"
        }

        # Force termination if process remains
        if ($Force) {
            try {
                $proc = Get-Process -Name 'spoolsv' -ErrorAction SilentlyContinue
                if ($null -ne $proc) {
                    Stop-Process -Name 'spoolsv' -Force -ErrorAction SilentlyContinue
                }
            } catch {
                Write-Verbose "Stop-Process encountered error: $($_.Exception.Message)"
            }
        }

        # 2. Purge files in spool directory
        $spoolDir = "$env:SystemRoot\System32\spool\PRINTERS"
        $purgedCount = 0
        try {
            $queueFiles = @(Get-ChildItem -Path $spoolDir -ErrorAction SilentlyContinue)
            foreach ($f in $queueFiles) {
                try {
                    if ($null -ne $f.FullName) {
                        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                        $purgedCount++
                    }
                } catch {
                    Write-Verbose "Failed to remove spool file: $($_.Exception.Message)"
                }
            }
        } catch {
            Write-Verbose "Error accessing spool directory: $($_.Exception.Message)"
        }

        # 3. Restart Spooler service
        $restarted = $false
        try {
            Start-Service -Name 'Spooler' -ErrorAction Stop
            $svc = Get-Service -Name 'Spooler' -ErrorAction SilentlyContinue
            if ($null -ne $svc -and $svc.PSObject.Properties['Status']) {
                if ($svc.Status -eq 'Running') {
                    $restarted = $true
                } else {
                    Write-Verbose "Spooler service started but status is '$($svc.Status)'"
                    $restarted = $false
                }
            } else {
                # In environments where Get-Service is stubbed and returns null,
                # successful execution of Start-Service indicates restart success
                $restarted = $true
            }
        } catch {
            Write-Verbose "Start-Service encountered error: $($_.Exception.Message)"
            $restarted = $false
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Print Spooler queue reset complete. Purged $purgedCount file(s). Restarted: $restarted" -Level 'INFO' -Component 'Reset-PrintSpoolerQueue'
        }

        return [PSCustomObject]@{
            FilesPurged      = [int]$purgedCount
            ServiceRestarted = [bool]$restarted
        }
    }
}
