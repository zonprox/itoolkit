function Set-PointAndPrintRemediation {
<#
.SYNOPSIS
    Applies targeted Point and Print registry remediation presets with automated rollback backups.
.DESCRIPTION
    Configures PrintNightmare registry keys according to specified preset:
    - 'StrictAdminOnly' / 'Secure': Enforces RpcAuthnLevelPrivacyEnabled = 1 and RestrictDriverInstallationToAdministrators = 1.
    - 'Compatibility' / 'Compat': Sets RpcAuthnLevelPrivacyEnabled = 0 to fix 0x0000011b on legacy shared printers.
    - 'Default': Restores standard secure defaults.
.PARAMETER Preset
    Target remediation preset name.
.OUTPUTS
    [PSCustomObject] containing PresetApplied and RegBackupFile.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('StrictAdminOnly', 'Compatibility', 'Default', 'Secure', 'Compat')]
        [string]$Preset
    )

    process {
        if (-not $PSCmdlet.ShouldProcess("Point and Print Policy", "Apply remediation preset '$Preset'")) {
            return [PSCustomObject]@{
                PresetApplied = $Preset
                RegBackupFile = '[Simulated - WhatIf]'
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Applying Point and Print remediation preset '$Preset'..." -Level 'INFO' -Component 'Set-PointAndPrintRemediation'
        }

        $rpcValue = 1
        $restrictAdminValue = 1

        if ($Preset -eq 'Compatibility' -or $Preset -eq 'Compat') {
            $rpcValue = 0
            $restrictAdminValue = 0
        }

        $regBackup = ''

        # Apply RpcAuthnLevelPrivacyEnabled via Set-ToolkitRegistryValue
        try {
            $printKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Print"
            if (Get-Command -Name 'Set-ToolkitRegistryValue' -ErrorAction SilentlyContinue) {
                $res = Set-ToolkitRegistryValue -KeyPath $printKey -ValueName 'RpcAuthnLevelPrivacyEnabled' -Value $rpcValue -PropertyType 'DWord'
                if ($null -ne $res) {
                    if ($res.PSObject.Properties['RegBackupFile'] -and $null -ne $res.RegBackupFile) {
                        $regBackup = $res.RegBackupFile
                    } elseif ($res.PSObject.Properties['BackupFile'] -and $null -ne $res.BackupFile) {
                        $regBackup = $res.BackupFile
                    }
                }
            }
            if ([string]::IsNullOrWhiteSpace($regBackup)) {
                $resFallback = Set-ToolkitRegistryValue -KeyPath $printKey -ValueName 'RpcAuthnLevelPrivacyEnabled' -Value $rpcValue -PropertyType 'DWord' -ErrorAction SilentlyContinue
                if ($null -ne $resFallback) {
                    if ($resFallback.PSObject.Properties['RegBackupFile'] -and $null -ne $resFallback.RegBackupFile) {
                        $regBackup = $resFallback.RegBackupFile
                    } elseif ($resFallback.PSObject.Properties['BackupFile'] -and $null -ne $resFallback.BackupFile) {
                        $regBackup = $resFallback.BackupFile
                    }
                }
            }
        } catch {
            Write-Verbose "Error setting RpcAuthnLevelPrivacyEnabled: $($_.Exception.Message)"
        }

        # Apply RestrictDriverInstallationToAdministrators
        try {
            $pnpKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint"
            if (Get-Command -Name 'Set-ToolkitRegistryValue' -ErrorAction SilentlyContinue) {
                $resPnp = Set-ToolkitRegistryValue -KeyPath $pnpKey -ValueName 'RestrictDriverInstallationToAdministrators' -Value $restrictAdminValue -PropertyType 'DWord'
                if ([string]::IsNullOrWhiteSpace($regBackup) -and $null -ne $resPnp) {
                    if ($resPnp.PSObject.Properties['RegBackupFile'] -and $null -ne $resPnp.RegBackupFile) {
                        $regBackup = $resPnp.RegBackupFile
                    } elseif ($resPnp.PSObject.Properties['BackupFile'] -and $null -ne $resPnp.BackupFile) {
                        $regBackup = $resPnp.BackupFile
                    }
                }
            }
        } catch {
            Write-Verbose "Error setting RestrictDriverInstallationToAdministrators: $($_.Exception.Message)"
        }

        return [PSCustomObject]@{
            PresetApplied = $Preset
            RegBackupFile = $regBackup
        }
    }
}
