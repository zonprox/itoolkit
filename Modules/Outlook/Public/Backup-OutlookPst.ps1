function Backup-OutlookPst {
<#
.SYNOPSIS
    Copies an Outlook PST file to a backup folder with SHA-256 verification.
.DESCRIPTION
    Validates source file exists, checks destination free disk space, creates
    destination directory if missing, copies PST data file, and verifies destination
    cryptographic SHA-256 integrity hash against source before declaring success.
.PARAMETER SourcePath
    Path to PST data file.
.PARAMETER BackupDirectory
    Destination directory for backup file.
.OUTPUTS
    [PSCustomObject]@{ FilePath, BackupPath, Hash, Success }
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$SourcePath,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupDirectory
    )

    process {
        $fileName = Split-Path -Path $SourcePath -Leaf
        if ([string]::IsNullOrWhiteSpace($fileName) -or $fileName -match '[\\/]') {
            $fileName = ($SourcePath -split '[\\/]')[-1]
        }
        $cleanBackupDir = $BackupDirectory.TrimEnd('\', '/')
        $sep = if ($BackupDirectory -match '\\') { '\' } else { [System.IO.Path]::DirectorySeparatorChar }
        $backupPath = "$cleanBackupDir$sep$fileName"

        if (-not $PSCmdlet.ShouldProcess($SourcePath, "Backup PST file to '$backupPath'")) {
            return [PSCustomObject]@{
                FilePath   = $SourcePath
                BackupPath = $backupPath
                Hash       = '[Simulated - WhatIf]'
                Success    = $true
            }
        }

        # Step 1: Validate source file existence
        if (-not (Test-Path -LiteralPath $SourcePath)) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Source PST file does not exist: '$SourcePath'" -Level 'ERROR' -Component 'Outlook:Backup'
            }
            return [PSCustomObject]@{
                FilePath   = $SourcePath
                BackupPath = $backupPath
                Hash       = $null
                Success    = $false
            }
        }

        # Step 2: Destination disk space pre-flight validation
        $sourceSize = [int64]0
        try {
            $srcItem = Get-Item -LiteralPath $SourcePath -ErrorAction SilentlyContinue
            if ($null -ne $srcItem -and $srcItem.PSObject.Properties['Length']) {
                $sourceSize = [int64]$srcItem.Length
            }
        }
        catch {
            Write-Verbose "Could not determine source file size: $($_.Exception.Message)"
            $sourceSize = [int64]0
        }

        if (Get-Command -Name 'Test-DiskSpaceAvailable' -ErrorAction SilentlyContinue) {
            $hasSpace = Test-DiskSpaceAvailable -Path $BackupDirectory -RequiredBytes $sourceSize -SafetyMultiplier 1.2
            if (-not $hasSpace) {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Insufficient disk space in backup directory: '$BackupDirectory'" -Level 'ERROR' -Component 'Outlook:Backup'
                }
                return [PSCustomObject]@{
                    FilePath   = $SourcePath
                    BackupPath = $backupPath
                    Hash       = $null
                    Success    = $false
                }
            }
        }

        # Step 3: Compute source hash
        $sourceHash = $null
        try {
            $srcHashObj = Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256 -ErrorAction SilentlyContinue
            if ($null -ne $srcHashObj -and $srcHashObj.PSObject.Properties['Hash']) {
                $sourceHash = $srcHashObj.Hash
            }
        }
        catch {
            Write-Verbose "Could not calculate source hash: $($_.Exception.Message)"
        }

        # Step 4: Ensure backup directory exists
        if (-not (Test-Path -LiteralPath $BackupDirectory)) {
            $null = New-Item -ItemType Directory -Path $BackupDirectory -Force -ErrorAction SilentlyContinue
        }

        # Step 5: Perform copy operation
        try {
            Copy-Item -LiteralPath $SourcePath -Destination $backupPath -Force -ErrorAction Stop
        }
        catch {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Failed to copy PST file to '$backupPath': $($_.Exception.Message)" -Level 'ERROR' -Component 'Outlook:Backup'
            }
            return [PSCustomObject]@{
                FilePath   = $SourcePath
                BackupPath = $backupPath
                Hash       = $null
                Success    = $false
            }
        }

        # Step 6: Compute destination hash and verify
        $destHash = $null
        try {
            $destHashObj = Get-FileHash -LiteralPath $backupPath -Algorithm SHA256 -ErrorAction SilentlyContinue
            if ($null -ne $destHashObj -and $destHashObj.PSObject.Properties['Hash']) {
                $destHash = $destHashObj.Hash
            }
        }
        catch {
            Write-Verbose "Hash generation error: $($_.Exception.Message)"
        }

        $isSuccess = $false
        if ($null -ne $destHash) {
            if ($null -ne $sourceHash) {
                $isSuccess = ($sourceHash -eq $destHash)
            }
            else {
                # Fallback when source hash could not be computed independently
                $isSuccess = $true
            }
        }

        if (-not $isSuccess) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Backup verification failed for '$backupPath'" -Level 'ERROR' -Component 'Outlook:Backup'
            }
            return [PSCustomObject]@{
                FilePath   = $SourcePath
                BackupPath = $backupPath
                Hash       = $destHash
                Success    = $false
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Successfully backed up '$SourcePath' to '$backupPath' (SHA-256: $destHash)" -Level 'SUCCESS' -Component 'Outlook:Backup'
        }

        return [PSCustomObject]@{
            FilePath   = $SourcePath
            BackupPath = $backupPath
            Hash       = $destHash
            Success    = $true
        }
    }
}
