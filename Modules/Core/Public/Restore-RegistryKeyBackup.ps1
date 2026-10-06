function Restore-RegistryKeyBackup {
<#
.SYNOPSIS
    Restores a target registry key or executes rollback from an auto-generated .reg backup file.
.DESCRIPTION
    Validates the specified .reg backup file and imports it using native reg.exe import.
    Handles standard exported registry snapshots and [-Key] deletion sentinels identically.
.PARAMETER BackupFilePath
    Path to the .reg backup file to restore.
.OUTPUTS
    [bool] $true if restore succeeded with exit code 0; otherwise $false.
.EXAMPLE
    Restore-RegistryKeyBackup -BackupFilePath "C:\Backups\Registry\RegistryBackup_123.reg"
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupFilePath
    )

    process {
        if (-not (Test-Path -LiteralPath $BackupFilePath -PathType Leaf)) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Registry backup file not found: '$BackupFilePath'" -Level 'ERROR' -Component 'Core:Registry'
            }
            return $false
        }

        $resolvedPath = (Resolve-Path -LiteralPath $BackupFilePath).Path

        if (-not $PSCmdlet.ShouldProcess($resolvedPath, "Restore registry from backup file")) {
            return $true
        }

        try {
            $regExe = 'reg.exe'
            if ($env:SystemRoot) {
                $candidateReg = Join-Path -Path $env:SystemRoot -ChildPath 'System32\reg.exe'
                if (Test-Path -LiteralPath $candidateReg) {
                    $regExe = $candidateReg
                }
            }

            $proc = Start-Process -FilePath $regExe -ArgumentList @('import', "`"$resolvedPath`"") -NoNewWindow -Wait -PassThru -ErrorAction Stop
            if ($null -ne $proc -and $proc.PSObject.Properties['ExitCode'] -and $proc.ExitCode -eq 0) {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Successfully restored registry backup from '$resolvedPath'" -Level 'INFO' -Component 'Core:Registry'
                }
                return $true
            }
            else {
                $code = if ($null -ne $proc -and $proc.PSObject.Properties['ExitCode']) { $proc.ExitCode } else { -1 }
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "reg.exe import failed for '$resolvedPath' with exit code $code" -Level 'ERROR' -Component 'Core:Registry'
                }
                return $false
            }
        }
        catch {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Exception during registry restore of '$resolvedPath': $($_.Exception.Message)" -Level 'ERROR' -Component 'Core:Registry'
            }
            return $false
        }
    }
}
