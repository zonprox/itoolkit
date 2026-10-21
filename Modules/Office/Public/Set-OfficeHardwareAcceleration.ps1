function Set-OfficeHardwareAcceleration {
<#
.SYNOPSIS
    Centralizes suite-wide hardware graphics acceleration across Microsoft Office applications.
.DESCRIPTION
    Configures DisableHardwareAcceleration under HKCU:\Software\Microsoft\Office\16.0\Common\Graphics
    and synchronizes hardware acceleration options across Word, Excel, and PowerPoint.
    Generates automated .reg rollback backup files via Set-ToolkitRegistryValue.
    Supports -WhatIf for non-destructive dry-run preview.
.PARAMETER Disable
    Switch parameter. When specified, disables hardware graphics acceleration (sets registry values to 1).
    This is the default action.
.PARAMETER Enable
    Switch parameter. Re-enables hardware graphics acceleration (sets registry values to 0).
.PARAMETER PassThru
    Returns the status PSCustomObject to the pipeline.
.OUTPUTS
    [PSCustomObject] containing Status, Disabled, RegistryPath, TargetKeys, and RegBackupFile.
.EXAMPLE
    Set-OfficeHardwareAcceleration -Disable
.EXAMPLE
    Set-OfficeHardwareAcceleration -Enable
.EXAMPLE
    Set-OfficeHardwareAcceleration -PassThru
.EXAMPLE
    Set-OfficeHardwareAcceleration -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Disable')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(ParameterSetName = 'Disable', Mandatory = $false)]
        [switch]$Disable,

        [Parameter(ParameterSetName = 'Enable', Mandatory = $false)]
        [switch]$Enable,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    process {
        # Determine intended state: default is Disable ($true)
        $targetDisabled = $true
        if ($PSCmdlet.ParameterSetName -eq 'Enable') {
            if ($PSBoundParameters.ContainsKey('Enable')) {
                $targetDisabled = (-not $Enable.ToBool())
            } else {
                $targetDisabled = $false
            }
        } elseif ($PSCmdlet.ParameterSetName -eq 'Disable') {
            if ($PSBoundParameters.ContainsKey('Disable')) {
                $targetDisabled = $Disable.ToBool()
            } else {
                $targetDisabled = $true
            }
        }

        $regValue = if ($targetDisabled) { 1 } else { 0 }
        $actionDesc = if ($targetDisabled) { 'Disable hardware acceleration (value = 1)' } else { 'Enable hardware acceleration (value = 0)' }

        $commonKey = 'HKCU:\Software\Microsoft\Office\16.0\Common\Graphics'
        $targetKeys = @(
            $commonKey,
            'HKCU:\Software\Microsoft\Office\16.0\Word\Options',
            'HKCU:\Software\Microsoft\Office\16.0\Excel\Options',
            'HKCU:\Software\Microsoft\Office\16.0\PowerPoint\Options'
        )
        $valueName = 'DisableHardwareAcceleration'

        if (-not $PSCmdlet.ShouldProcess("Office Graphics Settings", $actionDesc)) {
            $simResult = [PSCustomObject]@{
                Status        = 'Simulated'
                Disabled      = $targetDisabled
                RegistryPath  = $commonKey
                TargetKeys    = $targetKeys
                RegBackupFile = '[Simulated - WhatIf]'
            }
            return $simResult
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Configuring suite-wide Office hardware acceleration: Disabled = $targetDisabled" -Level 'INFO' -Component 'Set-OfficeHardwareAcceleration'
        }

        $primaryBackup = $null
        $keysConfigured = 0

        foreach ($key in $targetKeys) {
            try {
                if (Get-Command -Name 'Set-ToolkitRegistryValue' -ErrorAction SilentlyContinue) {
                    $regResult = Set-ToolkitRegistryValue -KeyPath $key -ValueName $valueName -Value $regValue -PropertyType 'DWord'
                    if ($null -ne $regResult -and [string]::IsNullOrEmpty($primaryBackup)) {
                        if ($regResult.PSObject.Properties['RegBackupFile'] -and $null -ne $regResult.RegBackupFile) {
                            $primaryBackup = $regResult.RegBackupFile
                        } elseif ($regResult.PSObject.Properties['BackupFile'] -and $null -ne $regResult.BackupFile) {
                            $primaryBackup = $regResult.BackupFile
                        }
                    }
                } else {
                    if (-not (Test-Path -LiteralPath $key)) {
                        $null = New-Item -Path $key -Force -ErrorAction SilentlyContinue
                    }
                    Set-ItemProperty -LiteralPath $key -Name $valueName -Value $regValue -Type DWord -Force -ErrorAction SilentlyContinue
                }
                $keysConfigured++

                # Synchronize slide show acceleration for PowerPoint
                if ($key -like '*PowerPoint\Options*') {
                    if (Get-Command -Name 'Set-ToolkitRegistryValue' -ErrorAction SilentlyContinue) {
                        $null = Set-ToolkitRegistryValue -KeyPath $key -ValueName 'DisableSlideShowHardwareAcceleration' -Value $regValue -PropertyType 'DWord'
                    } else {
                        Set-ItemProperty -LiteralPath $key -Name 'DisableSlideShowHardwareAcceleration' -Value $regValue -Type DWord -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            catch {
                Write-Verbose "Could not update registry key '$key': $($_.Exception.Message)"
            }
        }

        $status = if ($keysConfigured -gt 0) { 'Success' } else { 'Warning' }

        $resultObj = [PSCustomObject]@{
            Status        = $status
            Disabled      = $targetDisabled
            RegistryPath  = $commonKey
            TargetKeys    = $targetKeys
            RegBackupFile = $primaryBackup
        }

        return $resultObj
    }
}
