function Set-ExcelHardwareAcceleration {
<#
.SYNOPSIS
    Toggles Excel and Office hardware graphics acceleration in the Windows Registry.
.DESCRIPTION
    Configures DisableHardwareAcceleration under both HKCU:\Software\Microsoft\Office\16.0\Common\Graphics
    and HKCU:\Software\Microsoft\Office\16.0\Excel\Options to resolve rendering freezes, black screens,
    and display driver crashes across all Office 16.0 editions (MSI, Volume, Click-to-Run, M365).
    Generates automated .reg rollback backup files via Set-ToolkitRegistryValue.
    Supports -WhatIf for non-destructive dry-run preview.
.PARAMETER DisableAcceleration
    Switch parameter. When specified, disables hardware graphics acceleration (sets registry values to 1).
    To re-enable, specify -DisableAcceleration:$false or use -EnableAcceleration.
.PARAMETER EnableAcceleration
    Switch parameter. Re-enables hardware graphics acceleration (sets registry values to 0).
.PARAMETER Disable
    Positional boolean parameter for backward compatibility (e.g., -Disable $true / -Disable $false).
.OUTPUTS
    [PSCustomObject] containing Status, Disabled, RegBackupFile, and TargetKeys.
.EXAMPLE
    Set-ExcelHardwareAcceleration -DisableAcceleration
.EXAMPLE
    Set-ExcelHardwareAcceleration -Disable $true
.EXAMPLE
    Set-ExcelHardwareAcceleration -EnableAcceleration
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Switch')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(ParameterSetName = 'Switch')]
        [switch]$DisableAcceleration,

        [Parameter(ParameterSetName = 'SwitchEnable')]
        [switch]$EnableAcceleration,

        [Parameter(ParameterSetName = 'Explicit', Position = 0)]
        [Alias('Disable')]
        [bool]$DisableValue
    )

    process {
        # Determine intended state
        $targetDisabled = $true
        if ($PSCmdlet.ParameterSetName -eq 'Explicit') {
            $targetDisabled = $DisableValue
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'SwitchEnable') {
            $targetDisabled = (-not $EnableAcceleration.IsPresent)
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'Switch') {
            if ($PSBoundParameters.ContainsKey('DisableAcceleration')) {
                $targetDisabled = $DisableAcceleration.ToBool()
            }
            else {
                # Default repair action: disable acceleration
                $targetDisabled = $true
            }
        }

        $regValue = if ($targetDisabled) { 1 } else { 0 }
        $actionDesc = if ($targetDisabled) { 'Disable hardware acceleration (value = 1)' } else { 'Enable hardware acceleration (value = 0)' }

        $targetKeys = @(
            'HKCU:\Software\Microsoft\Office\16.0\Common\Graphics',
            'HKCU:\Software\Microsoft\Office\16.0\Excel\Options'
        )
        $valueName = 'DisableHardwareAcceleration'

        if (-not $PSCmdlet.ShouldProcess("Excel & Office Graphics Settings", $actionDesc)) {
            return [PSCustomObject]@{
                Status        = 'Simulated'
                Disabled      = $targetDisabled
                RegBackupFile = '[Simulated - WhatIf]'
                TargetKeys    = $targetKeys
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Configuring Excel hardware acceleration: Disabled = $targetDisabled" -Level 'INFO' -Component 'Set-ExcelHardwareAcceleration'
        }

        $primaryBackup = $null
        foreach ($key in $targetKeys) {
            try {
                $regResult = Set-ToolkitRegistryValue -KeyPath $key -ValueName $valueName -Value $regValue -PropertyType 'DWord'
                if ($null -ne $regResult -and [string]::IsNullOrEmpty($primaryBackup)) {
                    if ($regResult.PSObject.Properties['RegBackupFile'] -and $null -ne $regResult.RegBackupFile) {
                        $primaryBackup = $regResult.RegBackupFile
                    }
                    elseif ($regResult.PSObject.Properties['BackupFile'] -and $null -ne $regResult.BackupFile) {
                        $primaryBackup = $regResult.BackupFile
                    }
                }
            }
            catch {
                Write-Verbose "Could not update registry key '$key': $($_.Exception.Message)"
            }
        }

        return [PSCustomObject]@{
            Status        = 'Success'
            Disabled      = $targetDisabled
            RegBackupFile = $primaryBackup
            TargetKeys    = $targetKeys
        }
    }
}
