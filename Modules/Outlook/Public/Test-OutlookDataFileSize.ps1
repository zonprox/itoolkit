function Test-OutlookDataFileSize {
<#
.SYNOPSIS
    Tests Outlook PST and OST file sizes against active size threshold policies.
.DESCRIPTION
    Inspects physical file size on disk and compares against configured MaxLargeFileSize
    and WarnLargeFileSize registry policies, reporting threshold percentages and recommendations.
.PARAMETER FilePath
    Path to the PST or OST data file.
.OUTPUTS
    [PSCustomObject]@{ Path, SizeGB, SizeMB, WarnThresholdGB, MaxThresholdGB, PercentOfMax, Status, NeedsCompaction, NeedsExpansion }
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath
    )

    process {
        if (-not (Test-Path -LiteralPath $FilePath)) {
            throw "Target Outlook data file does not exist: '$FilePath'"
        }

        $fileItem = Get-Item -LiteralPath $FilePath -ErrorAction Stop
        $sizeBytes = [int64]$fileItem.Length
        $sizeMB = [Math]::Round([double]$sizeBytes / 1048576.0, 2)
        $sizeGB = [Math]::Round([double]$sizeBytes / 1073741824.0, 2)

        $thresholdPolicy = if (Get-Command -Name 'Get-OutlookPstThreshold' -ErrorAction SilentlyContinue) {
            Get-OutlookPstThreshold
        } else {
            [PSCustomObject]@{ MaxLargeFileSizeMB = 51200; WarnLargeFileSizeMB = 48640 }
        }

        $maxMB = if ($thresholdPolicy.MaxLargeFileSizeMB) { [double]$thresholdPolicy.MaxLargeFileSizeMB } else { 51200.0 }
        $warnMB = if ($thresholdPolicy.WarnLargeFileSizeMB) { [double]$thresholdPolicy.WarnLargeFileSizeMB } else { 48640.0 }

        $warnGB = [Math]::Round($warnMB / 1024.0, 2)
        $maxGB = [Math]::Round($maxMB / 1024.0, 2)

        $percentOfMax = [Math]::Round(($sizeMB / $maxMB) * 100.0, 1)

        $status = 'Healthy'
        if ($sizeMB -ge $maxMB) {
            $status = 'Critical'
        } elseif ($sizeMB -ge $warnMB) {
            $status = 'Warning'
        }

        return [PSCustomObject]@{
            Path            = $fileItem.FullName
            SizeGB          = $sizeGB
            SizeMB          = $sizeMB
            WarnThresholdGB = $warnGB
            MaxThresholdGB  = $maxGB
            PercentOfMax    = $percentOfMax
            Status          = $status
            NeedsCompaction = ($percentOfMax -ge 80.0)
            NeedsExpansion  = ($percentOfMax -ge 90.0)
        }
    }
}
