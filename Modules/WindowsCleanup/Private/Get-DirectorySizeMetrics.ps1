<#
.SYNOPSIS
    Calculates size and file count metrics for a target directory.
.DESCRIPTION
    Scans a directory recursively and calculates total bytes, total file count,
    and optionally filters by age criteria to determine qualifying candidates
    for cleanup versus files to be preserved.
.PARAMETER Path
    The directory path to inspect.
.PARAMETER OlderThan
    Optional DateTime threshold. Files created or modified on or after this timestamp
    are classified as active/skipped. Files older than this timestamp qualify.
.PARAMETER Filter
    Optional file search filter (default is '*').
.OUTPUTS
    [PSCustomObject] Containing Path, Exists, TotalBytes, FileCount, DirectoryCount,
    QualifyingBytes, QualifyingCount, SkippedCount.
#>
function Get-DirectorySizeMetrics {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [Nullable[datetime]]$OlderThan = $null,

        [Parameter(Mandatory = $false)]
        [string]$Filter = '*'
    )

    $result = [ordered]@{
        Path            = $Path
        Exists          = $false
        TotalBytes      = [int64]0
        FileCount       = [int]0
        DirectoryCount  = [int]0
        QualifyingBytes = [int64]0
        QualifyingCount = [int]0
        SkippedCount    = [int]0
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]$result
    }

    $result.Exists = $true

    try {
        $items = Get-ChildItem -LiteralPath $Path -Filter $Filter -Recurse -Force -ErrorAction SilentlyContinue
        if ($null -ne $items) {
            foreach ($item in $items) {
                if (-not $item.PSIsContainer) {
                    $result.FileCount++
                    $result.TotalBytes += $item.Length

                    $qualifies = $true
                    if ($null -ne $OlderThan) {
                        if ($item.LastWriteTime -ge $OlderThan -or $item.CreationTime -ge $OlderThan) {
                            $qualifies = $false
                        }
                    }

                    if ($qualifies) {
                        $result.QualifyingBytes += $item.Length
                        $result.QualifyingCount++
                    }
                    else {
                        $result.SkippedCount++
                    }
                }
                else {
                    $result.DirectoryCount++
                }
            }
        }
    }
    catch {
        Write-Verbose "Error inspecting directory metrics for '$Path': $($_.Exception.Message)"
    }

    return [PSCustomObject]$result
}
