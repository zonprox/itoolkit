function Set-ToolkitRegistryValue {
<#
.SYNOPSIS
    Modifies a registry value with mandatory pre-modification backup and WhatIf support.
.DESCRIPTION
    Wraps Set-ItemProperty with automatic .reg backup generation before applying any change.
    Queries previous value, creates parent key if missing, sets new value, verifies write,
    and returns a structured change summary object.
.PARAMETER KeyPath
    The target registry key path (e.g. HKLM:\Software\Policies\Microsoft\Office\16.0\Outlook\PST).
.PARAMETER ValueName
    The name of the registry property/value to set.
.PARAMETER Value
    The value to assign to the registry property.
.PARAMETER PropertyType
    Registry data type: 'String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord', 'Unknown'.
    Default is 'DWord'.
.PARAMETER BackupDirectory
    Optional directory path where the pre-modification .reg backup file will be created.
.OUTPUTS
    [PSCustomObject] with properties KeyPath, ValueName, PreviousValue, NewValue, BackupFile.
.EXAMPLE
    Set-ToolkitRegistryValue -KeyPath "HKCU:\Software\Microsoft\Office\16.0\Common\Graphics" -ValueName "DisableHardwareAcceleration" -Value 1 -PropertyType DWord
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$KeyPath,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$ValueName,

        [Parameter(Mandatory = $true, Position = 2)]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $false, Position = 3)]
        [ValidateSet('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord', 'Unknown')]
        [string]$PropertyType = 'DWord',

        [Parameter(Mandatory = $false)]
        [string]$BackupDirectory
    )

    process {
        $psPath = Normalize-RegistryPath -Path $KeyPath -Format 'PowerShell'

        # Query existing value state
        $previousValue = $null
        try {
            $existingProp = Get-ItemProperty -LiteralPath $psPath -Name $ValueName -ErrorAction SilentlyContinue
            if ($null -ne $existingProp -and ($existingProp.PSObject.Properties.Name -contains $ValueName)) {
                $previousValue = $existingProp.$ValueName
            }
        } catch {
            Write-Verbose "Could not query existing registry property: $($_.Exception.Message)"
        }

        # Handle simulation mode (-WhatIf)
        $actionDesc = "Set registry value '$ValueName' to '$Value' ($PropertyType) on key '$psPath'"
        if (-not $PSCmdlet.ShouldProcess($psPath, $actionDesc)) {
            return [PSCustomObject]@{
                KeyPath       = $psPath
                ValueName     = $ValueName
                PreviousValue = $previousValue
                NewValue      = $Value
                BackupFile    = '[Simulated - WhatIf]'
            }
        }

        # Step 1: Automatic Pre-Modification Backup
        $backupParams = @{ KeyPath = $KeyPath }
        if (-not [string]::IsNullOrEmpty($BackupDirectory)) {
            $backupParams['BackupDirectory'] = $BackupDirectory
        }
        $backupFile = Export-RegistryKeyBackup @backupParams

        # Step 2: Ensure Parent Key Exists
        try {
            if (-not (Test-Path -LiteralPath $psPath)) {
                $null = New-Item -Path $psPath -Force -ErrorAction SilentlyContinue
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Created missing parent registry key '$psPath'" -Level 'DEBUG' -Component 'Core:Registry'
                }
            }
        } catch {
            Write-Verbose "New-Item for registry key encountered error: $($_.Exception.Message)"
        }

        # Step 3: Apply Registry Value
        Set-ItemProperty -LiteralPath $psPath -Name $ValueName -Value $Value -Type $PropertyType -Force

        # Step 4: Verify Written Value
        $newValue = $Value
        try {
            $verifiedProp = Get-ItemProperty -LiteralPath $psPath -Name $ValueName -ErrorAction SilentlyContinue
            if ($null -ne $verifiedProp -and ($verifiedProp.PSObject.Properties.Name -contains $ValueName)) {
                $newValue = $verifiedProp.$ValueName
            }
        } catch {
            Write-Verbose "Could not re-read registry property: $($_.Exception.Message)"
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Updated registry '$psPath\$ValueName' from '$previousValue' to '$newValue'. Backup: '$backupFile'" -Level 'INFO' -Component 'Core:Registry'
        }

        # Step 5: Return Structured Object Matching Interface Contract
        return [PSCustomObject]@{
            KeyPath       = $psPath
            ValueName     = $ValueName
            PreviousValue = $previousValue
            NewValue      = $newValue
            BackupFile    = $backupFile
        }
    }
}
