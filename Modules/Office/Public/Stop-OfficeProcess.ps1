function Stop-OfficeProcess {
<#
.SYNOPSIS
    Terminates running or stuck Microsoft Office suite processes.
.DESCRIPTION
    Scans for active Office processes (WINWORD, EXCEL, POWERPNT, OUTLOOK, ONENOTE, OFFICECLICKTORUN).
    Executes graceful shutdown via CloseMainWindow() with configurable timeout and force fallback.
.PARAMETER ProcessNames
    Optional custom array of process names. Defaults to standard Office suite processes.
.PARAMETER Force
    Forcefully terminates remaining processes if graceful termination times out.
.PARAMETER TimeoutSeconds
    Maximum seconds to wait for graceful exit. Default is 5 seconds.
.OUTPUTS
    [PSCustomObject]@{ Status = 'Success'; Terminated = <string[]> }
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [Alias('TargetProcess', 'ProcessName')]
        [string[]]$ProcessNames = @('WINWORD', 'EXCEL', 'POWERPNT', 'OUTLOOK', 'ONENOTE', 'OFFICECLICKTORUN', 'MSACCESS', 'MSPUB'),

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 60)]
        [int]$TimeoutSeconds = 5
    )

    process {
        if (-not $PSCmdlet.ShouldProcess("Office Applications", "Terminate running Office processes: $($ProcessNames -join ', ')")) {
            return [PSCustomObject]@{
                Status     = 'Success'
                Terminated = @('[Simulated - WhatIf]')
            }
        }

        $terminatedList = [System.Collections.Generic.List[string]]::new()

        foreach ($procName in $ProcessNames) {
            $cleanName = [System.IO.Path]::GetFileNameWithoutExtension($procName)
            $running = @(Get-Process -Name $cleanName -ErrorAction SilentlyContinue)

            if ($running.Count -gt 0) {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Terminating active process '$cleanName' ($($running.Count) instance(s))..." -Level 'INFO' -Component 'Stop-OfficeProcess'
                }

                $termSuccess = $false
                if (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                    $stopRes = Stop-ToolkitProcess -ProcessName $cleanName -TimeoutSeconds $TimeoutSeconds -Force:$Force
                    if ($null -ne $stopRes -and $stopRes.Terminated) {
                        $termSuccess = $true
                    }
                } else {
                    if ($Force) {
                        Stop-Process -Name $cleanName -Force -ErrorAction SilentlyContinue
                        $termSuccess = $true
                    } else {
                        foreach ($p in $running) {
                            if ($p.CloseMainWindow()) {
                                $null = $p.WaitForExit($TimeoutSeconds * 1000)
                            }
                        }
                        $stillAlive = @(Get-Process -Name $cleanName -ErrorAction SilentlyContinue)
                        $termSuccess = ($stillAlive.Count -eq 0)
                    }
                }

                if ($termSuccess) {
                    $terminatedList.Add($cleanName)
                }
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Stop-OfficeProcess finished. Terminated: $($terminatedList -join ', ')" -Level 'INFO' -Component 'Stop-OfficeProcess'
        }

        return [PSCustomObject]@{
            Status     = 'Success'
            Terminated = @($terminatedList)
        }
    }
}
