function Reset-PowerPointCache {
<#
.SYNOPSIS
    Clears PowerPoint font cache, slide layout preview cache, and temporary render artifacts.
.DESCRIPTION
    Purges cached files in %LOCALAPPDATA%\Microsoft\Office\16.0\PowerPoint\Cache to resolve
    slide layout glitches, corrupted font rendering, and white box placeholder anomalies.
    Terminates active POWERPNT.EXE processes prior to clearing files.
    Supports -WhatIf for safe execution preview.
.PARAMETER Force
    When specified, forcibly terminates running POWERPNT.EXE processes to release file locks.
.OUTPUTS
    [PSCustomObject] containing Status, CleanedFilesCount, BytesFreed, and CachePath.
.EXAMPLE
    Reset-PowerPointCache
.EXAMPLE
    Reset-PowerPointCache -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        $localAppData = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $env:LOCALAPPDATA } elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { Join-Path $env:USERPROFILE 'AppData\Local' } else { [System.IO.Path]::GetTempPath() }
        $cacheDir = Join-Path (Join-Path $localAppData 'Microsoft\Office\16.0\PowerPoint') 'Cache'

        if (-not $PSCmdlet.ShouldProcess($cacheDir, "Purge PowerPoint font and slide layout cache")) {
            return [PSCustomObject]@{
                Status            = 'Simulated'
                CleanedFilesCount = 0
                BytesFreed        = 0
                CachePath         = $cacheDir
            }
        }

        # Step 1: Pre-flight process lock check
        if (Get-Command -Name 'Test-ProcessRunning' -ErrorAction SilentlyContinue) {
            if (Test-ProcessRunning -ProcessName 'POWERPNT') {
                if (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Terminating active POWERPNT.EXE process prior to cache purge..." -Level 'WARN' -Component 'Reset-PowerPointCache'
                    $null = Stop-ToolkitProcess -ProcessName 'POWERPNT' -TimeoutSeconds 5 -Force
                }
                else {
                    Stop-Process -Name 'POWERPNT' -Force -ErrorAction SilentlyContinue
                }
            }
        }

        $cleanedCount = 0
        $bytesFreed = 0

        if (Test-Path -LiteralPath $cacheDir) {
            try {
                $cacheFiles = @(Get-ChildItem -LiteralPath $cacheDir -File -Recurse -ErrorAction SilentlyContinue)
                foreach ($f in $cacheFiles) {
                    try {
                        $len = $f.Length
                        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                        $cleanedCount++
                        $bytesFreed += $len
                    }
                    catch {
                        Write-Verbose "Could not remove cache file '$($f.FullName)': $($_.Exception.Message)"
                    }
                }
            }
            catch {
                Write-Verbose "Could not enumerate cache directory '$cacheDir': $($_.Exception.Message)"
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "PowerPoint cache reset completed: $cleanedCount file(s) removed, $bytesFreed bytes freed." -Level 'INFO' -Component 'Reset-PowerPointCache'
        }

        return [PSCustomObject]@{
            Status            = 'Success'
            CleanedFilesCount = $cleanedCount
            BytesFreed        = $bytesFreed
            CachePath         = $cacheDir
        }
    }
}
