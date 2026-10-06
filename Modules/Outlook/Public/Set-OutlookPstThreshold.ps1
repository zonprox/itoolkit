function Set-OutlookPstThreshold {
<#
.SYNOPSIS
    Configures Outlook PST and OST file size thresholds in Windows Registry.
.DESCRIPTION
    Sets MaxLargeFileSize and WarnLargeFileSize registry values under Office 16.0
    policies, creating an automatic .reg rollback file before modification.
.PARAMETER MaxLargeFileSizeMB
    Maximum allowable file size in Megabytes (e.g. 102400 for 100 GB).
.PARAMETER WarnLargeFileSizeMB
    Warning file size threshold in Megabytes (must be strictly less than Max).
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
        [int]$WarnLargeFileSizeMB
    )

    process {
        if ($WarnLargeFileSizeMB -ge $MaxLargeFileSizeMB) {
            throw "WarnLargeFileSizeMB ($WarnLargeFileSizeMB) must be strictly less than MaxLargeFileSizeMB ($MaxLargeFileSizeMB)."
        }

        $policyKey = 'HKCU:\Software\Policies\Microsoft\Office\16.0\Outlook\PST'

        if (-not $PSCmdlet.ShouldProcess($policyKey, "Set MaxLargeFileSize=$MaxLargeFileSizeMB MB, WarnLargeFileSize=$WarnLargeFileSizeMB MB")) {
            return [PSCustomObject]@{
                MaxLargeFileSizeMB  = $MaxLargeFileSizeMB
                WarnLargeFileSizeMB = $WarnLargeFileSizeMB
                RegBackupFile       = '[Simulated - WhatIf]'
            }
        }

        $backupFile = $null

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

        return [PSCustomObject]@{
            MaxLargeFileSizeMB  = $MaxLargeFileSizeMB
            WarnLargeFileSizeMB = $WarnLargeFileSizeMB
            RegBackupFile       = $backupFile
        }
    }
}
