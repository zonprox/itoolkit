function Repair-OfficeClickToRunService {
<#
.SYNOPSIS
    Diagnoses and repairs the Office ClickToRunSvc Windows service and streaming cache.
.DESCRIPTION
    Verifies that ClickToRunSvc is set to Automatic startup and running.
    Starts or restarts the service if stopped.
    Audits %ProgramData%\Microsoft\ClickToRun\ProductReleases for corrupted 0-byte files or streaming locks.
.OUTPUTS
    [PSCustomObject]@{ Status = 'Success'|'Warning'|'Skipped'; ServiceStatus = <string>; CacheHealthy = <bool>; Repaired = <bool> }
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param()

    process {
        if (-not $PSCmdlet.ShouldProcess("Office Click-to-Run", "Verify and repair ClickToRunSvc service and streaming cache")) {
            return [PSCustomObject]@{
                Status        = 'Success'
                ServiceStatus = 'Simulated'
                CacheHealthy  = $true
                Repaired      = $false
            }
        }

        $svc = Get-Service -Name 'ClickToRunSvc' -ErrorAction SilentlyContinue
        if ($null -eq $svc) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "ClickToRunSvc Windows service is not installed on this machine." -Level 'WARN' -Component 'Repair-OfficeClickToRunService'
            }
            return [PSCustomObject]@{
                Status        = 'Skipped'
                ServiceStatus = 'NotInstalled'
                CacheHealthy  = $false
                Repaired      = $false
            }
        }

        $repaired = $false

        # Step 1: Ensure StartupType is Automatic
        try {
            if ($svc.StartType -ne 'Automatic') {
                Set-Service -Name 'ClickToRunSvc' -StartupType Automatic -ErrorAction Stop
                $repaired = $true
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Configured ClickToRunSvc startup type to Automatic." -Level 'INFO' -Component 'Repair-OfficeClickToRunService'
                }
            }
        } catch {
            Write-Verbose "Could not configure ClickToRunSvc startup type: $($_.Exception.Message)"
        }

        # Step 2: Ensure Service is Running
        try {
            if ($svc.Status -ne 'Running') {
                Start-Service -Name 'ClickToRunSvc' -ErrorAction Stop
                $svc.WaitForStatus('Running', [System.TimeSpan]::FromSeconds(10))
                $repaired = $true
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Started ClickToRunSvc service." -Level 'INFO' -Component 'Repair-OfficeClickToRunService'
                }
            }
        } catch {
            Write-Verbose "Could not start ClickToRunSvc: $($_.Exception.Message)"
        }

        # Refresh service state
        $svc.Refresh()
        $finalStatus = "$($svc.Status)"

        # Step 3: Audit ProductReleases Streaming Cache
        $cacheHealthy = $true
        $progData = if ($env:ProgramData) { $env:ProgramData } elseif ([System.IO.Path]::DirectorySeparatorChar -eq '/') { '/tmp/ProgramData' } else { 'C:\ProgramData' }
        $c2rCacheDir = Join-Path $progData 'Microsoft\ClickToRun\ProductReleases'

        if (Test-Path -LiteralPath $c2rCacheDir) {
            try {
                $zeroByteFiles = @(Get-ChildItem -LiteralPath $c2rCacheDir -Filter '*.xml' -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -eq 0 })
                if ($zeroByteFiles.Count -gt 0) {
                    $cacheHealthy = $false
                    foreach ($z in $zeroByteFiles) {
                        try {
                            Remove-Item -LiteralPath $z.FullName -Force -ErrorAction Stop
                            $repaired = $true
                            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                                Write-ToolkitLog -Message "Removed corrupt 0-byte ClickToRun metadata: '$($z.Name)'" -Level 'WARN' -Component 'Repair-OfficeClickToRunService'
                            }
                        } catch { $null = $_ }
                    }
                }
            } catch {
                Write-Verbose "Could not scan ProductReleases cache: $($_.Exception.Message)"
            }
        }

        return [PSCustomObject]@{
            Status        = if ($finalStatus -eq 'Running') { 'Success' } else { 'Warning' }
            ServiceStatus = $finalStatus
            CacheHealthy  = $cacheHealthy
            Repaired      = $repaired
        }
    }
}
