<#
.SYNOPSIS
    Safely deletes a file or directory item with age filtering and lock resilience.
.DESCRIPTION
    Attempts to remove the target item while strictly respecting age thresholds
    (preserving files younger than the threshold), catching IOException (file locks)
    and UnauthorizedAccessException without throwing terminating exceptions.
.PARAMETER Item
    The FileInfo, DirectoryInfo, or string path of the item to delete.
.PARAMETER OlderThan
    Optional DateTime threshold. Items modified or created on or after this timestamp
    are preserved.
.PARAMETER WhatIfSimulation
    When specified, simulates deletion and reports projected reclaimed bytes.
.OUTPUTS
    [PSCustomObject] Containing Path, Deleted, ReclaimedBytes, SkippedReason, ErrorMessage.
#>
function Remove-SafeItem {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [object]$Item,

        [Parameter(Mandatory = $false)]
        [Nullable[datetime]]$OlderThan = $null,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIfSimulation
    )

    process {
        $targetInfo = $null
        if ($Item -is [System.IO.FileSystemInfo]) {
            $targetInfo = $Item
        }
        elseif ($Item -is [string]) {
            if (Test-Path -LiteralPath $Item) {
                $targetInfo = Get-Item -LiteralPath $Item -Force -ErrorAction SilentlyContinue
            }
            else {
                return [PSCustomObject]@{
                    Path           = [string]$Item
                    Deleted        = $false
                    ReclaimedBytes = [int64]0
                    SkippedReason  = 'PathNotFound'
                    ErrorMessage   = $null
                }
            }
        }
        else {
            return [PSCustomObject]@{
                Path           = [string]$Item
                Deleted        = $false
                ReclaimedBytes = [int64]0
                SkippedReason  = 'InvalidItemType'
                ErrorMessage   = 'Item must be FileSystemInfo or string path'
            }
        }

        if ($null -eq $targetInfo) {
            return [PSCustomObject]@{
                Path           = [string]$Item
                Deleted        = $false
                ReclaimedBytes = [int64]0
                SkippedReason  = 'PathNotFound'
                ErrorMessage   = $null
            }
        }

        # Handling File items
        if (-not $targetInfo.PSIsContainer) {
            # Check age condition
            if ($null -ne $OlderThan) {
                if ($targetInfo.LastWriteTime -ge $OlderThan -or $targetInfo.CreationTime -ge $OlderThan) {
                    Write-Verbose "Preserving active file (<age threshold): $($targetInfo.FullName)"
                    return [PSCustomObject]@{
                        Path           = $targetInfo.FullName
                        Deleted        = $false
                        ReclaimedBytes = [int64]0
                        SkippedReason  = 'ActiveOrYoungerThanThreshold'
                        ErrorMessage   = $null
                    }
                }
            }

            $byteSize = [int64]$targetInfo.Length

            if ($WhatIfSimulation) {
                return [PSCustomObject]@{
                    Path           = $targetInfo.FullName
                    Deleted        = $true
                    ReclaimedBytes = $byteSize
                    SkippedReason  = 'None'
                    ErrorMessage   = $null
                }
            }

            try {
                Remove-Item -LiteralPath $targetInfo.FullName -Force -ErrorAction Stop
                return [PSCustomObject]@{
                    Path           = $targetInfo.FullName
                    Deleted        = $true
                    ReclaimedBytes = $byteSize
                    SkippedReason  = 'None'
                    ErrorMessage   = $null
                }
            }
            catch [System.IO.IOException] {
                Write-Verbose "Locked file skipped: $($targetInfo.FullName) - $($_.Exception.Message)"
                return [PSCustomObject]@{
                    Path           = $targetInfo.FullName
                    Deleted        = $false
                    ReclaimedBytes = [int64]0
                    SkippedReason  = 'LockedFile'
                    ErrorMessage   = $_.Exception.Message
                }
            }
            catch [System.UnauthorizedAccessException] {
                Write-Verbose "Access denied skipped: $($targetInfo.FullName) - $($_.Exception.Message)"
                return [PSCustomObject]@{
                    Path           = $targetInfo.FullName
                    Deleted        = $false
                    ReclaimedBytes = [int64]0
                    SkippedReason  = 'AccessDenied'
                    ErrorMessage   = $_.Exception.Message
                }
            }
            catch {
                Write-Verbose "Error deleting file: $($targetInfo.FullName) - $($_.Exception.Message)"
                return [PSCustomObject]@{
                    Path           = $targetInfo.FullName
                    Deleted        = $false
                    ReclaimedBytes = [int64]0
                    SkippedReason  = 'Exception'
                    ErrorMessage   = $_.Exception.Message
                }
            }
        }

        # Handling Directory items
        $reclaimed = [int64]0
        $filesDeleted = 0
        $filesSkipped = 0

        $childFiles = Get-ChildItem -LiteralPath $targetInfo.FullName -Recurse -File -Force -ErrorAction SilentlyContinue
        if ($null -ne $childFiles) {
            foreach ($child in $childFiles) {
                $childRes = Remove-SafeItem -Item $child -OlderThan $OlderThan -WhatIfSimulation:$WhatIfSimulation
                if ($childRes.Deleted) {
                    $reclaimed += $childRes.ReclaimedBytes
                    $filesDeleted++
                }
                else {
                    $filesSkipped++
                }
            }
        }

        if (-not $WhatIfSimulation -and $filesSkipped -eq 0) {
            try {
                Remove-Item -LiteralPath $targetInfo.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
            catch {
                Write-Verbose "Could not remove empty folder structure: $($targetInfo.FullName)"
            }
        }

        $allSuccess = ($filesSkipped -eq 0)
        return [PSCustomObject]@{
            Path           = $targetInfo.FullName
            Deleted        = $allSuccess
            ReclaimedBytes = $reclaimed
            SkippedReason  = if ($filesSkipped -gt 0) { 'ContainsSkippedFiles' } else { 'None' }
            ErrorMessage   = $null
        }
    }
}
