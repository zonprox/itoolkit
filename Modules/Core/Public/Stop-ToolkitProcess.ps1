function Stop-ToolkitProcess {
<#
.SYNOPSIS
    Gracefully terminates a running process with timeout and force fallback.
.DESCRIPTION
    Attempts a graceful shutdown by calling CloseMainWindow() on running instances
    with a main window. Waits up to TimeoutSeconds for instances to exit. If instances
    remain active after timeout or cannot be closed gracefully, forcefully terminates
    them if -Force is specified. Supports targeting by process name or specific PID (-Id).
.PARAMETER ProcessName
    The process name or path (e.g. "OUTLOOK", "excel.exe").
.PARAMETER Id
    Specific process ID to terminate. When specified, only this instance is targeted.
.PARAMETER TimeoutSeconds
    Maximum seconds to wait for graceful exit before fallback. Default is 10 seconds.
.PARAMETER Force
    Forcefully terminates remaining instances if graceful termination fails or times out.
.OUTPUTS
    [PSCustomObject] containing ProcessName, Terminated, and ForceUsed.
.EXAMPLE
    Stop-ToolkitProcess -ProcessName "OUTLOOK" -TimeoutSeconds 10 -Force
.EXAMPLE
    Stop-ToolkitProcess -Id 1234 -Force
.EXAMPLE
    Stop-ToolkitProcess -ProcessName "EXCEL" -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ProcessName,

        [Parameter(Mandatory = $false)]
        [int]$Id,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 300)]
        [int]$TimeoutSeconds = 10,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        $cleanName = if ($ProcessName) { [System.IO.Path]::GetFileNameWithoutExtension($ProcessName) } else { '' }

        $targetDesc = if ($cleanName -and $Id -gt 0) {
            "$cleanName (PID $Id)"
        } elseif ($Id -gt 0) {
            "PID $Id"
        } else {
            $cleanName
        }

        if (-not $PSCmdlet.ShouldProcess($targetDesc, "Terminate running process instance")) {
            return [PSCustomObject]@{
                ProcessName = $cleanName
                Terminated  = $false
                ForceUsed   = $false
            }
        }

        $initialProcs = $null
        try {
            if ($Id -gt 0) {
                $initialProcs = @(Get-Process -Id $Id -ErrorAction SilentlyContinue)
                if ($initialProcs.Count -gt 0 -and [string]::IsNullOrWhiteSpace($cleanName)) {
                    $cleanName = $initialProcs[0].ProcessName
                }
            } elseif (-not [string]::IsNullOrWhiteSpace($cleanName)) {
                $initialProcs = @(Get-Process -Name $cleanName -ErrorAction SilentlyContinue)
            } else {
                $initialProcs = @()
            }
        } catch {
            Write-Verbose "Could not query processes for '$targetDesc': $($_.Exception.Message)"
            $initialProcs = @()
        }

        if ($null -eq $initialProcs -or $initialProcs.Count -eq 0) {
            Write-Verbose "Process '$targetDesc' is not running."
            return [PSCustomObject]@{
                ProcessName = $cleanName
                Terminated  = $false
                ForceUsed   = $false
            }
        }

        $forceUsed = $false
        $gracefulAttempted = $false

        # Attempt graceful close if process exposes CloseMainWindow
        if ($TimeoutSeconds -gt 0) {
            foreach ($proc in $initialProcs) {
                try {
                    $hasClose = $false
                    if ($proc.PSObject.Methods.Match('CloseMainWindow').Count -gt 0) {
                        $hasClose = $true
                        $null = $proc.CloseMainWindow()
                        $gracefulAttempted = $true
                    }
                    elseif ($proc.PSObject.Properties['CloseMainWindow'] -and $proc.CloseMainWindow -is [scriptblock]) {
                        $hasClose = $true
                        $null = & $proc.CloseMainWindow
                        $gracefulAttempted = $true
                    }

                    if ($hasClose) {
                        Write-Verbose "Sent CloseMainWindow to PID $($proc.Id) ($cleanName)."
                    }
                } catch {
                    Write-Verbose "CloseMainWindow failed on '$cleanName': $($_.Exception.Message)"
                }
            }

            # If graceful was attempted, wait with stopwatch
            if ($gracefulAttempted) {
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $timeoutMs = $TimeoutSeconds * 1000
                while ($stopwatch.ElapsedMilliseconds -lt $timeoutMs) {
                    $alive = @($initialProcs | Where-Object {
                        if ($_.PSObject.Properties['HasExited']) {
                            return (-not $_.HasExited)
                        } else {
                            return $true
                        }
                    })
                    if ($alive.Count -eq 0) {
                        break
                    }
                    Start-Sleep -Milliseconds 200
                }
                $stopwatch.Stop()
            }
        }

        # Check if force kill is needed
        if ($Force) {
            $needsForce = $false
            if (-not $gracefulAttempted) {
                $needsForce = $true
            } else {
                $stillRunning = @($initialProcs | Where-Object {
                    if ($_.PSObject.Properties['HasExited']) {
                        return (-not $_.HasExited)
                    } else {
                        return $true
                    }
                })
                if ($stillRunning.Count -gt 0) {
                    $needsForce = $true
                }
            }

            if ($needsForce) {
                $forceUsed = $true
                Write-Verbose "Forcefully terminating process '$cleanName'..."
                foreach ($proc in $initialProcs) {
                    try {
                        if ($proc.PSObject.Properties['Id'] -and $null -ne $proc.Id) {
                            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                        } else {
                            Stop-Process -Name $cleanName -Force -ErrorAction SilentlyContinue
                        }
                    } catch {
                        Write-Verbose "Stop-Process failed on '$cleanName': $($_.Exception.Message)"
                    }
                    if ($proc.PSObject.Properties['Kill'] -and $proc.Kill -is [scriptblock]) {
                        try {
                            $null = & $proc.Kill
                        } catch {
                            Write-Verbose "Kill scriptblock failed on '$cleanName': $($_.Exception.Message)"
                        }
                    }
                }
            }
        }

        # Evaluate termination success
        $isTerminated = $false
        if ($forceUsed -or $gracefulAttempted) {
            $isTerminated = $true
            foreach ($proc in $initialProcs) {
                if ($proc.PSObject.Properties['HasExited']) {
                    if (-not $proc.HasExited) {
                        $isTerminated = $false
                        break
                    }
                }
            }
        }

        return [PSCustomObject]@{
            ProcessName = $cleanName
            Terminated  = $isTerminated
            ForceUsed   = $forceUsed
        }
    }
}
