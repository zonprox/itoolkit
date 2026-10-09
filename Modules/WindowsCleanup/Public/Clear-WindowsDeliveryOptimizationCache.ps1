<#
.SYNOPSIS
    Purges Windows Delivery Optimization peer-to-peer and CDN download cache.
.DESCRIPTION
    Cleans cached update and app payloads stored in the Delivery Optimization cache directories.
    Leverages native Delete-DeliveryOptimizationCache if available, and purges standard DO
    cache locations while safely skipping locked files.
.PARAMETER Path
    Optional custom cache path. If not provided, scans standard Delivery Optimization locations.
.OUTPUTS
    [PSCustomObject] Containing Target, Path, ReclaimedBytes, ItemCount, SkippedCount, Status,
    Success, ErrorMessage.
#>
function Clear-WindowsDeliveryOptimizationCache {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path
    )

    process {
        # 1. Elevation check
        $isAdmin = $true
        if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
            $isAdmin = Test-IsAdmin
        }
        else {
            try {
                $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
                $principal = [Security.Principal.WindowsPrincipal]$identity
                $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            }
            catch {
                $isAdmin = $false
            }
        }

        if (-not $isAdmin) {
            Write-Warning "Administrative privileges are recommended for Delivery Optimization cache cleanup."
        }

        # 2. Resolve Candidate Paths
        $targetPaths = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($Path)) {
            $targetPaths.Add($Path)
        }
        else {
            $sysRoot = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
            $candidate1 = Join-Path $sysRoot 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'
            $candidate2 = Join-Path $sysRoot 'SoftwareDistribution\DeliveryOptimization'
            $targetPaths.Add($candidate1)
            $targetPaths.Add($candidate2)
        }

        $allPathsDisplay = ($targetPaths -join ';')

        # 3. WhatIf Space Analysis
        if (-not $PSCmdlet.ShouldProcess($allPathsDisplay, "Purge Delivery Optimization cache")) {
            $projectedBytes = [int64]0
            $projectedItems = 0

            foreach ($p in $targetPaths) {
                if (Test-Path -LiteralPath $p) {
                    $metrics = Get-DirectorySizeMetrics -Path $p
                    $projectedBytes += $metrics.TotalBytes
                    $projectedItems += $metrics.FileCount
                }
            }

            Write-Verbose "Simulation mode (-WhatIf): Projected $projectedBytes bytes across $projectedItems files."
            return [PSCustomObject]@{
                Target         = 'DeliveryOptimization'
                Path           = $allPathsDisplay
                ReclaimedBytes = $projectedBytes
                ItemCount      = $projectedItems
                SkippedCount   = 0
                Status         = 'Simulated - WhatIf'
                Success        = $true
                ErrorMessage   = $null
            }
        }

        # 4. Native Cmdlet Execution if Available
        if (Get-Command -Name 'Delete-DeliveryOptimizationCache' -ErrorAction SilentlyContinue) {
            try {
                Write-Verbose "Invoking native Delete-DeliveryOptimizationCache cmdlet"
                Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue
            }
            catch {
                Write-Verbose "Native Delete-DeliveryOptimizationCache notice: $($_.Exception.Message)"
            }
        }

        # 5. Filesystem Purge
        $reclaimedBytes = [int64]0
        $itemCount = 0
        $skippedCount = 0
        $encounteredErrors = [System.Collections.Generic.List[string]]::new()

        foreach ($dir in $targetPaths) {
            if (-not (Test-Path -LiteralPath $dir)) {
                continue
            }

            try {
                $childItems = Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue
                if ($null -ne $childItems) {
                    foreach ($item in $childItems) {
                        try {
                            $res = Remove-SafeItem -Item $item
                            if ($res.Deleted) {
                                $reclaimedBytes += $res.ReclaimedBytes
                                $itemCount++
                            }
                            else {
                                $skippedCount++
                            }
                        }
                        catch [System.IO.IOException] {
                            Write-Verbose "Skipped locked Delivery Optimization item: $($item.FullName)"
                            $skippedCount++
                        }
                        catch [System.UnauthorizedAccessException] {
                            Write-Verbose "Access denied for Delivery Optimization item: $($item.FullName)"
                            $skippedCount++
                        }
                        catch {
                            Write-Verbose "Error removing DO item: $($item.FullName) - $($_.Exception.Message)"
                            $skippedCount++
                        }
                    }
                }
            }
            catch {
                $encounteredErrors.Add($_.Exception.Message)
                Write-Warning "Delivery Optimization cache cleanup notice for $dir - $($_.Exception.Message)"
            }
        }

        $statusMsg = if ($skippedCount -gt 0) {
            "Completed with $skippedCount skipped item(s)"
        }
        else {
            "Success"
        }

        $errStr = if ($encounteredErrors.Count -gt 0) { $encounteredErrors -join '; ' } else { $null }

        return [PSCustomObject]@{
            Target         = 'DeliveryOptimization'
            Path           = $allPathsDisplay
            ReclaimedBytes = [int64]$reclaimedBytes
            ItemCount      = [int]$itemCount
            SkippedCount   = [int]$skippedCount
            Status         = $statusMsg
            Success        = $true
            ErrorMessage   = $errStr
        }
    }
}
