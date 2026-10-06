function New-BackupIntegrityManifest {
<#
.SYNOPSIS
    Generates a cryptographic SHA-256 JSON manifest for all files in a backup root.
.DESCRIPTION
    Scans the backup directory recursively, computes SHA-256 hashes, and writes
    IToolkit_Backup_Manifest.json containing file relative paths, hashes, and byte sizes.
.PARAMETER BackupRoot
    Root directory of the backup files to catalog.
.OUTPUTS
    [string] Path to the generated IToolkit_Backup_Manifest.json file.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupRoot
    )

    process {
        if (-not (Test-Path -LiteralPath $BackupRoot)) {
            throw "Backup root directory does not exist: '$BackupRoot'"
        }

        $resolvedRoot = (Resolve-Path -LiteralPath $BackupRoot).Path
        $manifestFileName = 'IToolkit_Backup_Manifest.json'
        $manifestPath = Join-Path -Path $resolvedRoot -ChildPath $manifestFileName

        $files = Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne $manifestFileName }

        $manifestEntries = [System.Collections.Generic.List[PSCustomObject]]::new()

        if ($null -ne $files) {
            foreach ($f in $files) {
                $hashVal = $null
                $hashObj = Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue
                if ($null -ne $hashObj -and $hashObj.PSObject.Properties['Hash']) {
                    $hashVal = $hashObj.Hash
                }

                $relPath = $f.FullName.Substring($resolvedRoot.Length).TrimStart('/', '\')
                $manifestEntries.Add([PSCustomObject]@{
                    RelativePath = $relPath
                    Hash         = $hashVal
                    SizeBytes    = [int64]$f.Length
                })
            }
        }

        $manifestData = [PSCustomObject]@{
            CreatedAt = (Get-Date).ToUniversalTime().ToString('o')
            Files     = @($manifestEntries)
        }

        $manifestJson = $manifestData | ConvertTo-Json -Depth 5
        Set-Content -Path $manifestPath -Value $manifestJson -Encoding UTF8

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Created backup integrity manifest at '$manifestPath' ($($manifestEntries.Count) files)" -Level 'SUCCESS' -Component 'Backup:Manifest'
        }

        return $manifestPath
    }
}
