function Set-OutlookPstThreshold {
<#
.SYNOPSIS
    Configures Outlook PST and OST file size thresholds in Windows Registry.
.DESCRIPTION
    Sets MaxLargeFileSize and WarnLargeFileSize registry values under Office Group
    Policy and user preference keys across Office 16.0 or 15.0, creating an automatic
    .reg rollback file before modification.
.PARAMETER MaxLargeFileSizeMB
    Maximum allowable file size in Megabytes (e.g. 102400 for 100 GB).
.PARAMETER WarnLargeFileSizeMB
    Warning file size threshold in Megabytes (must be strictly less than Max).
.PARAMETER OfficeVersion
    Office version string ('16.0' or '15.0'). Default is '16.0'.
.OUTPUTS
    [PSCustomObject]@{ MaxLargeFileSizeMB, WarnLargeFileSizeMB, RegBackupFile }
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateRange(1024, 4194304)]
        [int]$MaxLargeFileSizeMB,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateRange(1024, 4194304)]
        [int]$WarnLargeFileSizeMB,

        [Parameter(Mandatory = $false)]
        [ValidateSet('16.0', '15.0')]
        [string]$OfficeVersion = '16.0'
    )

    process {
        if ($WarnLargeFileSizeMB -ge $MaxLargeFileSizeMB) {
            throw "WarnLargeFileSizeMB ($WarnLargeFileSizeMB) must be strictly less than MaxLargeFileSizeMB ($MaxLargeFileSizeMB)."
        }

        $policyKey = "HKCU:\Software\Policies\Microsoft\Office\$OfficeVersion\Outlook\PST"
        $prefKey   = "HKCU:\Software\Microsoft\Office\$OfficeVersion\Outlook\PST"

        if (-not $PSCmdlet.ShouldProcess($policyKey, "Set MaxLargeFileSize=$MaxLargeFileSizeMB MB, WarnLargeFileSize=$WarnLargeFileSizeMB MB")) {
            return [PSCustomObject]@{
                MaxLargeFileSizeMB  = $MaxLargeFileSizeMB
                WarnLargeFileSizeMB = $WarnLargeFileSizeMB
                RegBackupFile       = '[Simulated - WhatIf]'
            }
        }

        $backupFile = $null

        # 1. Apply to Group Policy key
        $res1 = Set-ToolkitRegistryValue -KeyPath $policyKey -ValueName 'MaxLargeFileSize' -Value $MaxLargeFileSizeMB -PropertyType 'DWord'
        if ($null -ne $res1) {
            if ($res1.PSObject.Properties['RegBackupFile'] -and $null -ne $res1.RegBackupFile) {
                $backupFile = $res1.RegBackupFile
            }
            elseif ($res1.PSObject.Properties['BackupFile'] -and $null -ne $res1.BackupFile) {
                $backupFile = $res1.BackupFile
            }
        }

        $res2 = Set-ToolkitRegistryValue -KeyPath $policyKey -ValueName 'WarnLargeFileSize' -Value $WarnLargeFileSizeMB -PropertyType 'DWord'
        if ([string]::IsNullOrWhiteSpace($backupFile) -and $null -ne $res2) {
            if ($res2.PSObject.Properties['RegBackupFile'] -and $null -ne $res2.RegBackupFile) {
                $backupFile = $res2.RegBackupFile
            }
            elseif ($res2.PSObject.Properties['BackupFile'] -and $null -ne $res2.BackupFile) {
                $backupFile = $res2.BackupFile
            }
        }

        # 2. Also ensure User Preference key reflects threshold for non-GPO readers
        try {
            $null = Set-ToolkitRegistryValue -KeyPath $prefKey -ValueName 'MaxLargeFileSize' -Value $MaxLargeFileSizeMB -PropertyType 'DWord'
            $null = Set-ToolkitRegistryValue -KeyPath $prefKey -ValueName 'WarnLargeFileSize' -Value $WarnLargeFileSizeMB -PropertyType 'DWord'
        }
        catch {
            Write-Verbose "User preference sync notice: $($_.Exception.Message)"
        }

        return [PSCustomObject]@{
            MaxLargeFileSizeMB  = $MaxLargeFileSizeMB
            WarnLargeFileSizeMB = $WarnLargeFileSizeMB
            RegBackupFile       = $backupFile
        }
    }
}
