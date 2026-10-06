function Test-BackupIntegrityManifest {
<#
.SYNOPSIS
    Verifies destination files against a cryptographic SHA-256 backup manifest.
.DESCRIPTION
    Reads IToolkit_Backup_Manifest.json, calculates SHA-256 hashes of all files in
    TargetRoot, compares against manifest checksums, and returns an integrity report.
.PARAMETER ManifestPath
    Path to IToolkit_Backup_Manifest.json file.
.PARAMETER TargetRoot
    Root directory containing files to verify.
.OUTPUTS
    [PSCustomObject]@{ TotalFiles, MatchedCount, CorruptedCount, MissingCount, IsIntact }
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$ManifestPath,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetRoot
    )

    process {
        if (-not (Test-Path -LiteralPath $ManifestPath)) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Manifest file not found: '$ManifestPath'" -Level 'ERROR' -Component 'Backup:Integrity'
            }
            return [PSCustomObject]@{
                TotalFiles     = 0
                MatchedCount   = 0
                CorruptedCount = 0
                MissingCount   = 0
                IsIntact       = $false
            }
        }

        $manifestData = $null
        try {
            $manifestJson = Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop
            $manifestData = $manifestJson | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Write-Verbose "Backup manifest read or JSON parse failed: $($_.Exception.Message)"
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Backup manifest '$ManifestPath' is invalid or corrupt: $($_.Exception.Message)" -Level 'WARN' -Component 'Backup:Integrity'
            }
            return [PSCustomObject]@{
                TotalFiles     = 0
                MatchedCount   = 0
                CorruptedCount = 1
                MissingCount   = 0
                IsIntact       = $false
            }
        }

        if ($null -eq $manifestData -or -not $manifestData.PSObject.Properties['Files']) {
            return [PSCustomObject]@{
                TotalFiles     = 0
                MatchedCount   = 0
                CorruptedCount = 0
                MissingCount   = 0
                IsIntact       = $false
            }
        }

        $files = @($manifestData.Files)
        $total = $files.Count
        $matched = 0
        $corrupted = 0
        $missing = 0

        foreach ($entry in $files) {
            $targetFilePath = Join-Path -Path $TargetRoot -ChildPath $entry.RelativePath
            if (-not (Test-Path -LiteralPath $targetFilePath)) {
                $missing++
            }
            else {
                $hashObj = Get-FileHash -LiteralPath $targetFilePath -Algorithm SHA256 -ErrorAction SilentlyContinue
                if ($null -ne $hashObj -and $hashObj.Hash -eq $entry.Hash) {
                    $matched++
                }
                else {
                    $corrupted++
                }
            }
        }

        $isIntact = ($corrupted -eq 0 -and $missing -eq 0 -and ($total -eq 0 -or $matched -eq $total))

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            $status = 'FAILED'
            $logLevel = 'ERROR'
            if ($isIntact) {
                $status = 'INTACT'
                $logLevel = 'SUCCESS'
            }
            Write-ToolkitLog -Message "Manifest integrity check: $status (Matched: $matched, Corrupted: $corrupted, Missing: $missing)" -Level $logLevel -Component 'Backup:Integrity'
        }

        return [PSCustomObject]@{
            TotalFiles     = $total
            MatchedCount   = $matched
            CorruptedCount = $corrupted
            MissingCount   = $missing
            IsIntact       = $isIntact
        }
    }
}
