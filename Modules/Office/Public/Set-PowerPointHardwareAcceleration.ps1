function Set-PowerPointHardwareAcceleration {
<#
.SYNOPSIS
    Toggles PowerPoint hardware graphics acceleration in the Windows Registry.
.DESCRIPTION
    Configures DisableHardwareAcceleration and DisableSlideShowHardwareAcceleration under
    HKCU:\Software\Microsoft\Office\16.0\PowerPoint\Options to resolve presentation rendering freezes,
    black slides, and display driver crashes.
    Generates an automated .reg rollback backup file via Set-ToolkitRegistryValue.
    Supports -WhatIf for non-destructive dry-run preview.
.PARAMETER DisableAcceleration
    Switch parameter. When specified, disables hardware graphics acceleration (sets registry values to 1).
    To re-enable, specify -DisableAcceleration:$false or use -EnableAcceleration.
.PARAMETER EnableAcceleration
    Switch parameter. Re-enables hardware graphics acceleration (sets registry values to 0).
.PARAMETER Disable
    Positional boolean parameter for backward compatibility (e.g., -Disable $true).
.OUTPUTS
    [PSCustomObject] containing Status, Disabled, RegBackupFile, and TargetKey.
.EXAMPLE
    Set-PowerPointHardwareAcceleration -DisableAcceleration
.EXAMPLE
    Set-PowerPointHardwareAcceleration -EnableAcceleration
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
                $targetDisabled = $true
            }
        }

        $regValue = if ($targetDisabled) { 1 } else { 0 }
        $actionDesc = if ($targetDisabled) { 'Disable PowerPoint hardware acceleration (value = 1)' } else { 'Enable PowerPoint hardware acceleration (value = 0)' }

        $keyPath = 'HKCU:\Software\Microsoft\Office\16.0\PowerPoint\Options'

        if (-not $PSCmdlet.ShouldProcess($keyPath, $actionDesc)) {
            return [PSCustomObject]@{
                Status        = 'Simulated'
                Disabled      = $targetDisabled
                RegBackupFile = '[Simulated - WhatIf]'
                TargetKey     = $keyPath
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Configuring PowerPoint hardware acceleration: Disabled = $targetDisabled" -Level 'INFO' -Component 'Set-PowerPointHardwareAcceleration'
        }

        $regBackup = $null
        try {
            $res1 = Set-ToolkitRegistryValue -KeyPath $keyPath -ValueName 'DisableHardwareAcceleration' -Value $regValue -PropertyType 'DWord'
            if ($null -ne $res1 -and $res1.PSObject.Properties['RegBackupFile']) {
                $regBackup = $res1.RegBackupFile
            }
            $null = Set-ToolkitRegistryValue -KeyPath $keyPath -ValueName 'DisableSlideShowHardwareAcceleration' -Value $regValue -PropertyType 'DWord'
        }
        catch {
            Write-Verbose "Could not configure PowerPoint hardware acceleration: $($_.Exception.Message)"
        }

        return [PSCustomObject]@{
            Status        = 'Success'
            Disabled      = $targetDisabled
            RegBackupFile = $regBackup
            TargetKey     = $keyPath
        }
    }
}
