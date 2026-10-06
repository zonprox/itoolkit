function Set-ExcelHardwareAcceleration {
<#
.SYNOPSIS
    Toggles Excel and Office hardware graphics acceleration in the registry.
.DESCRIPTION
    Configures DisableHardwareAcceleration under HKCU:\Software\Microsoft\Office\16.0\Common\Graphics.
    Generates an automated .reg rollback backup file via Set-ToolkitRegistryValue.
    Supports -WhatIf for non-destructive dry-run preview.
.PARAMETER Disable
    Set to $true to disable hardware acceleration (fixes display glitches, crashes).
    Set to $false to enable hardware acceleration.
.OUTPUTS
    [PSCustomObject] containing Disabled and RegBackupFile.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [bool]$Disable
    )

    process {
        $regValue = 0
        if ($Disable) {
            $regValue = 1
        }

        $keyPath = 'HKCU:\Software\Microsoft\Office\16.0\Common\Graphics'
        $valueName = 'DisableHardwareAcceleration'

        if (-not $PSCmdlet.ShouldProcess($keyPath, "Set $valueName to $regValue")) {
            return [PSCustomObject]@{
                Disabled      = $Disable
                RegBackupFile = '[Simulated - WhatIf]'
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Configuring Excel hardware acceleration: Disable = $Disable" -Level 'INFO' -Component 'Set-ExcelHardwareAcceleration'
        }

        $regResult = Set-ToolkitRegistryValue -KeyPath $keyPath -ValueName $valueName -Value $regValue -PropertyType 'DWord'

        $backupFile = $null
        if ($null -ne $regResult) {
            if ($regResult.PSObject.Properties['RegBackupFile'] -and $null -ne $regResult.RegBackupFile) {
                $backupFile = $regResult.RegBackupFile
            }
            elseif ($regResult.PSObject.Properties['BackupFile'] -and $null -ne $regResult.BackupFile) {
                $backupFile = $regResult.BackupFile
            }
        }

        return [PSCustomObject]@{
            Disabled      = $Disable
            RegBackupFile = $backupFile
        }
    }
}
