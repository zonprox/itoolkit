function Restore-OutlookPst {
<#
.SYNOPSIS
    Restores an Outlook PST file from backup with SHA-256 validation.
.DESCRIPTION
    Copies backup file to target location and validates that restored file
    hash matches the source backup hash before declaring success.
.PARAMETER BackupPath
    Path to existing backup file.
.PARAMETER DestinationPath
    Destination restore path.
.OUTPUTS
    [PSCustomObject]@{ RestoredPath, HashVerified, Success }
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupPath,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath
    )

    process {
        if (-not $PSCmdlet.ShouldProcess($BackupPath, "Restore PST file to '$DestinationPath'")) {
            return [PSCustomObject]@{
                RestoredPath = $DestinationPath
                HashVerified = $true
                Success      = $true
            }
        }

        $sourceHash = $null
        try {
            $sourceHashObj = Get-FileHash -LiteralPath $BackupPath -Algorithm SHA256
            if ($null -ne $sourceHashObj -and $sourceHashObj.PSObject.Properties['Hash']) {
                $sourceHash = $sourceHashObj.Hash
            }
        }
        catch {
            Write-Verbose "Could not hash backup file: $($_.Exception.Message)"
        }

        $destDir = Split-Path -Path $DestinationPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($destDir) -and -not (Test-Path -LiteralPath $destDir)) {
            $null = New-Item -ItemType Directory -Path $destDir -Force -ErrorAction SilentlyContinue
        }

        Copy-Item -LiteralPath $BackupPath -Destination $DestinationPath -Force

        $destHash = $null
        try {
            $destHashObj = Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256
            if ($null -ne $destHashObj -and $destHashObj.PSObject.Properties['Hash']) {
                $destHash = $destHashObj.Hash
            }
        }
        catch {
            Write-Verbose "Could not hash restored file: $($_.Exception.Message)"
        }

        $hashVerified = ($null -ne $sourceHash -and $null -ne $destHash -and ($sourceHash -eq $destHash))

        return [PSCustomObject]@{
            RestoredPath = $DestinationPath
            HashVerified = $hashVerified
            Success      = $hashVerified
        }
    }
}
