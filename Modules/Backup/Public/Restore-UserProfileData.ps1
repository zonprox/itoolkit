function Restore-UserProfileData {
<#
.SYNOPSIS
    Restores user profile data from backup with cryptographic integrity verification.
.DESCRIPTION
    Validates backup integrity via Test-BackupIntegrityManifest, resolves target user
    directories via Get-UserProfileDirectoryMap, and copies restored data back safely.
.PARAMETER BackupRoot
    Root directory of the backup containing files and IToolkit_Backup_Manifest.json.
.PARAMETER Categories
    Array of categories to restore (default: Desktop, Documents, Downloads, Favorites, Pictures, Bookmarks).
.PARAMETER CertPassword
    Optional SecureString password to import certificates if present.
.OUTPUTS
    [PSCustomObject]@{ RestoredCategories, Success }
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupRoot,

        [Parameter(Mandatory = $false)]
        [string[]]$Categories = @('Desktop', 'Documents', 'Downloads', 'Favorites', 'Pictures', 'Bookmarks'),

        [Parameter(Mandatory = $false)]
        [System.Security.SecureString]$CertPassword
    )

    process {
        if (-not $PSCmdlet.ShouldProcess($BackupRoot, "Restore user profile data")) {
            return [PSCustomObject]@{
                RestoredCategories = $Categories
                Success            = $true
            }
        }

        # 1. Cryptographic integrity pre-flight verification
        $manifestPath = Join-Path -Path $BackupRoot -ChildPath 'IToolkit_Backup_Manifest.json' -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($manifestPath)) {
            $sep = '\'
            if ($BackupRoot -match '/') {
                $sep = '/'
            }
            $manifestPath = "$($BackupRoot.TrimEnd('/\'))${sep}IToolkit_Backup_Manifest.json"
        }
        if (Get-Command -Name 'Test-BackupIntegrityManifest' -ErrorAction SilentlyContinue) {
            $integrity = $null
            try {
                $integrity = Test-BackupIntegrityManifest -ManifestPath $manifestPath -TargetRoot $BackupRoot -ErrorAction Stop
            }
            catch {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Integrity manifest check encountered error for '$BackupRoot': $($_.Exception.Message). Aborting restore." -Level 'ERROR' -Component 'Backup:Restore'
                }
                return [PSCustomObject]@{
                    RestoredCategories = @()
                    Success            = $false
                }
            }

            if ($null -eq $integrity -or -not $integrity.IsIntact) {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Integrity manifest verification failed for '$BackupRoot'. Aborting restore." -Level 'ERROR' -Component 'Backup:Restore'
                }
                return [PSCustomObject]@{
                    RestoredCategories = @()
                    Success            = $false
                }
            }
        }

        # 2. Resolve destination directories
        $destMap = $null
        if (Get-Command -Name 'Get-UserProfileDirectoryMap' -ErrorAction SilentlyContinue) {
            $destMap = Get-UserProfileDirectoryMap
        }

        $userProfile = ''
        if ($env:USERPROFILE) {
            $userProfile = $env:USERPROFILE
        } elseif ($env:HOME) {
            $userProfile = $env:HOME
        }

        $restored = [System.Collections.Generic.List[string]]::new()

        foreach ($cat in $Categories) {
            $srcCatDir = Join-Path -Path $BackupRoot -ChildPath $cat -ErrorAction SilentlyContinue
            if ([string]::IsNullOrWhiteSpace($srcCatDir)) {
                $sep = '\'
                if ($BackupRoot -match '/') {
                    $sep = '/'
                }
                $srcCatDir = "$($BackupRoot.TrimEnd('/\'))${sep}$cat"
            }
            $targetDir = ''

            if ($null -ne $destMap -and $destMap.PSObject.Properties[$cat]) {
                $targetDir = [string]$destMap.$cat
            }
            else {
                $targetDir = Join-Path -Path $userProfile -ChildPath $cat
            }

            try {
                if (Test-Path -LiteralPath $srcCatDir) {
                    if (-not (Test-Path -LiteralPath $targetDir)) {
                        $null = New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction SilentlyContinue
                    }
                    Copy-Item -Path "$srcCatDir/*" -Destination $targetDir -Recurse -Force -ErrorAction SilentlyContinue
                    $restored.Add($cat)
                }
            }
            catch {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Warning: Failed to restore category '$cat': $($_.Exception.Message)" -Level 'WARN' -Component 'Backup:Restore'
                }
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Profile restore completed successfully for: $($restored -join ', ')" -Level 'SUCCESS' -Component 'Backup:Restore'
        }

        return [PSCustomObject]@{
            RestoredCategories = @($restored)
            Success            = $true
        }
    }
}
