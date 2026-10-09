<#
.SYNOPSIS
    Cleans system and user temporary directories with age and lock safety guards.
.DESCRIPTION
    Purges temporary files from user (%TEMP%) and Windows system (%SystemRoot%\Temp)
    directories. Enforces a strict age threshold (default 24 hours) preserving all files
    created or modified within that window to protect active installer sessions and running apps.
    Safely catches and bypasses open/locked files without throwing terminating errors.
.PARAMETER AgeHours
    Minimum age in hours for a file to qualify for deletion (default: 24, range: 0-720).
    Files modified or created more recently than this value are preserved.
.PARAMETER IncludeUserTemp
    Purges current user temp folder (%TEMP%).
.PARAMETER IncludeSystemTemp
    Purges Windows system temp folder (%SystemRoot%\Temp).
.PARAMETER AllUsers
    When running elevated, scans all user profiles under C:\Users\*\AppData\Local\Temp.
.OUTPUTS
    [PSCustomObject] Containing Target, Path, ReclaimedBytes, ItemCount, SkippedCount, Status,
    Success, ErrorMessage.
#>
function Clear-WindowsTempCache {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [Alias('MinAgeHours')]
        [ValidateRange(0, 720)]
        [int]$AgeHours = 24,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeUserTemp,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeSystemTemp,

        [Parameter(Mandatory = $false)]
        [switch]$AllUsers
    )

    process {
        # 1. Resolve Target Directories
        $doUser = $IncludeUserTemp
        $doSystem = $IncludeSystemTemp
        if (-not $IncludeUserTemp -and -not $IncludeSystemTemp) {
            $doUser = $true
            $doSystem = $true
        }

        $targetDirs = [System.Collections.Generic.List[string]]::new()

        if ($doUser) {
            if ($env:TEMP -and (Test-Path -LiteralPath $env:TEMP)) {
                if (-not $targetDirs.Contains($env:TEMP)) { $targetDirs.Add($env:TEMP) }
            }
            if ($env:TMP -and (Test-Path -LiteralPath $env:TMP)) {
                if (-not $targetDirs.Contains($env:TMP)) { $targetDirs.Add($env:TMP) }
            }
        }

        if ($doSystem) {
            $sysRoot = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
            $sysTemp = Join-Path $sysRoot 'Temp'
            if (Test-Path -LiteralPath $sysTemp) {
                if (-not $targetDirs.Contains($sysTemp)) { $targetDirs.Add($sysTemp) }
            }
        }

        if ($AllUsers) {
            $usersRoot = 'C:\Users'
            if (Test-Path -LiteralPath $usersRoot) {
                $userProfiles = Get-ChildItem -LiteralPath $usersRoot -Directory -Force -ErrorAction SilentlyContinue
                if ($null -ne $userProfiles) {
                    foreach ($profile in $userProfiles) {
                        $profTemp = Join-Path $profile.FullName 'AppData\Local\Temp'
                        if (Test-Path -LiteralPath $profTemp) {
                            if (-not $targetDirs.Contains($profTemp)) { $targetDirs.Add($profTemp) }
                        }
                    }
                }
            }
        }

        $dirsDisplay = ($targetDirs -join ';')
        $cutoffTime = (Get-Date).AddHours(-$AgeHours)

        # 2. WhatIf Space Analysis
        if (-not $PSCmdlet.ShouldProcess($dirsDisplay, "Clean temporary files older than $AgeHours hours")) {
            $projectedBytes = [int64]0
            $projectedItems = 0
            $projectedSkipped = 0

            foreach ($dir in $targetDirs) {
                $metrics = Get-DirectorySizeMetrics -Path $dir -OlderThan $cutoffTime
                $projectedBytes += $metrics.QualifyingBytes
                $projectedItems += $metrics.QualifyingCount
                $projectedSkipped += $metrics.SkippedCount
            }

            Write-Verbose "Simulation mode (-WhatIf): Projected $projectedBytes bytes across $projectedItems files ($projectedSkipped files preserved <$AgeHours h)."
            return [PSCustomObject]@{
                Target         = 'TemporaryFiles'
                Path           = $dirsDisplay
                ReclaimedBytes = $projectedBytes
                ItemCount      = $projectedItems
                SkippedCount   = $projectedSkipped
                Status         = 'Simulated - WhatIf'
                Success        = $true
                ErrorMessage   = $null
            }
        }

        # 3. Execute Cleanup Safely
        $reclaimedBytes = [int64]0
        $itemCount = 0
        $skippedCount = 0

        foreach ($dir in $targetDirs) {
            if (-not (Test-Path -LiteralPath $dir)) {
                continue
            }

            $items = Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue
            if ($null -eq $items) {
                continue
            }

            foreach ($item in $items) {
                if (-not $item.PSIsContainer) {
                    # File Item Check
                    if ($item.LastWriteTime -ge $cutoffTime -or $item.CreationTime -ge $cutoffTime) {
                        Write-Verbose "Preserving active file (<$AgeHours hours): $($item.FullName)"
                        $skippedCount++
                        continue
                    }

                    $fileSize = [int64]$item.Length
                    try {
                        Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
                        $reclaimedBytes += $fileSize
                        $itemCount++
                    }
                    catch [System.IO.IOException] {
                        Write-Verbose "Skipped locked file: $($item.FullName)"
                        $skippedCount++
                    }
                    catch [System.UnauthorizedAccessException] {
                        Write-Verbose "Access denied for file: $($item.FullName)"
                        $skippedCount++
                    }
                    catch {
                        Write-Verbose "Error deleting file: $($item.FullName) - $($_.Exception.Message)"
                        $skippedCount++
                    }
                }
                else {
                    # Directory Item: Scan and delete qualifying files inside directory
                    $subFiles = Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue
                    $dirCanBeRemoved = $true
                    $dirHadFiles = $false

                    if ($null -ne $subFiles -and $subFiles.Count -gt 0) {
                        $dirHadFiles = $true
                        foreach ($subFile in $subFiles) {
                            if ($subFile.LastWriteTime -ge $cutoffTime -or $subFile.CreationTime -ge $cutoffTime) {
                                $skippedCount++
                                $dirCanBeRemoved = $false
                                continue
                            }

                            $subSize = [int64]$subFile.Length
                            try {
                                Remove-Item -LiteralPath $subFile.FullName -Force -ErrorAction Stop
                                $reclaimedBytes += $subSize
                                $itemCount++
                            }
                            catch [System.IO.IOException] {
                                Write-Verbose "Skipped locked file in folder: $($subFile.FullName)"
                                $skippedCount++
                                $dirCanBeRemoved = $false
                            }
                            catch [System.UnauthorizedAccessException] {
                                Write-Verbose "Access denied in folder: $($subFile.FullName)"
                                $skippedCount++
                                $dirCanBeRemoved = $false
                            }
                            catch {
                                Write-Verbose "Error deleting file in folder: $($subFile.FullName) - $($_.Exception.Message)"
                                $skippedCount++
                                $dirCanBeRemoved = $false
                            }
                        }
                    }

                    # If directory had all qualifying files deleted (or was empty), attempt to remove directory
                    if ($dirCanBeRemoved) {
                        if ($item.LastWriteTime -lt $cutoffTime -and $item.CreationTime -lt $cutoffTime) {
                            try {
                                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
                            }
                            catch {
                                Write-Verbose "Could not remove empty folder: $($item.FullName)"
                            }
                        }
                        else {
                            # Folder itself is newer than cutoff
                            $skippedCount++
                        }
                    }
                }
            }
        }

        $statusMsg = if ($skippedCount -gt 0) {
            "Completed ($skippedCount item(s) retained: locked or <$AgeHours hours)"
        }
        else {
            "Success"
        }

        return [PSCustomObject]@{
            Target         = 'TemporaryFiles'
            Path           = $dirsDisplay
            ReclaimedBytes = [int64]$reclaimedBytes
            ItemCount      = [int]$itemCount
            SkippedCount   = [int]$skippedCount
            Status         = $statusMsg
            Success        = $true
            ErrorMessage   = $null
        }
    }
}
