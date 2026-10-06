function Stop-ExcelGdiLeakers {
<#
.SYNOPSIS
    Terminates Excel processes exceeding GDI handle leak thresholds.
.DESCRIPTION
    Identifies leaking Excel processes via Get-ExcelGdiHandleUsage and terminates only
    the specific leaking process IDs to prevent system-wide desktop heap exhaustion
    without impacting unaffected Excel sessions.
.PARAMETER Threshold
    GDI handle count threshold to consider a process leaking. Default is 8000.
.PARAMETER Force
    When specified, forcefully terminates the processes without waiting for graceful exit.
.OUTPUTS
    [PSCustomObject] containing TerminatedPIDs and Count.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [int]$Threshold = 8000,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        if (-not $PSCmdlet.ShouldProcess("Excel Leaking Processes", "Terminate processes exceeding $Threshold GDI handles")) {
            return [PSCustomObject]@{
                TerminatedPIDs = @()
                Count          = 0
            }
        }

        $terminatedList = [System.Collections.Generic.List[int]]::new()

        try {
            $usage = @(Get-ExcelGdiHandleUsage -WarningThreshold $Threshold)
            $leakers = @($usage | Where-Object { $_.IsLeaking -eq $true })

            foreach ($item in $leakers) {
                $pidVal = [int]$item.PID
                if ($PSCmdlet.ShouldProcess("PID $pidVal ($($item.ProcessName))", "Terminate leaking Excel process")) {
                    if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                        Write-ToolkitLog -Message "Terminating leaking Excel process PID $pidVal ($($item.GdiHandles) handles)..." -Level 'WARN' -Component 'Stop-ExcelGdiLeakers'
                    }

                    $terminated = $false

                    # Target specifically by PID using Stop-ToolkitProcess
                    if (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                        $stopRes = Stop-ToolkitProcess -ProcessName 'EXCEL' -Id $pidVal -TimeoutSeconds 3 -Force:$Force
                        if ($null -ne $stopRes -and $stopRes.Terminated) {
                            $terminated = $true
                        }
                    }

                    # Fallback directly to Stop-Process by PID if Stop-ToolkitProcess is unavailable or did not terminate
                    if (-not $terminated) {
                        try {
                            Stop-Process -Id $pidVal -Force -ErrorAction SilentlyContinue
                            $terminated = $true
                        }
                        catch {
                            Write-Verbose "Stop-Process on PID $pidVal encountered: $($_.Exception.Message)"
                        }
                    }

                    if ($terminated) {
                        $terminatedList.Add($pidVal)
                    }
                }
            }
        }
        catch {
            Write-Verbose "Error detecting or terminating GDI leakers: $($_.Exception.Message)"
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Terminated $($terminatedList.Count) leaking Excel process(es)." -Level 'INFO' -Component 'Stop-ExcelGdiLeakers'
        }

        return [PSCustomObject]@{
            TerminatedPIDs = @($terminatedList)
            Count          = $terminatedList.Count
        }
    }
}
