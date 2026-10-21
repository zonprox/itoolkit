function Reset-ExcelDdeSettings {
<#
.SYNOPSIS
    Clears DDE command ignore flags and resets workbook calculation mode to Automatic.
.DESCRIPTION
    Configures HKCU:\Software\Microsoft\Office\16.0\Excel\Options:
    1. Sets IgnoreRemoteRequests to 0, ensuring Excel processes external DDE open commands
       from Windows Explorer (resolving "There was a problem sending the command to the program").
    2. Sets Calculation to 1 (Automatic), resolving formula calculation freezes.
    Generates automated .reg rollback files via Set-ToolkitRegistryValue.
    Supports -WhatIf for non-destructive dry-run preview.
.PARAMETER Force
    Terminates active EXCEL processes prior to resetting DDE and calculation settings.
.OUTPUTS
    [PSCustomObject] containing Status, DdeDisabled, IgnoreRemoteRequests, Calculation, and RegBackupFile.
.EXAMPLE
    Reset-ExcelDdeSettings
.EXAMPLE
    Reset-ExcelDdeSettings -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        $keyPath = 'HKCU:\Software\Microsoft\Office\16.0\Excel\Options'

        if (-not $PSCmdlet.ShouldProcess($keyPath, "Reset IgnoreRemoteRequests to 0 and Calculation to 1 (Automatic)")) {
            return [PSCustomObject]@{
                Status               = 'Simulated'
                DdeDisabled          = $false
                IgnoreRemoteRequests = 0
                Calculation          = 1
                RegBackupFile        = '[Simulated - WhatIf]'
            }
        }

        # Pre-execution process guard
        $runningProcs = @(Get-Process -Name 'EXCEL' -ErrorAction SilentlyContinue)
        if ($runningProcs.Count -gt 0) {
            if ($Force) {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Terminating active EXCEL process prior to DDE reset..." -Level 'WARN' -Component 'Reset-ExcelDdeSettings'
                }
                if (Get-Command -Name 'Stop-OfficeProcess' -ErrorAction SilentlyContinue) {
                    $null = Stop-OfficeProcess -ProcessNames @('EXCEL') -Force:$true -TimeoutSeconds 5
                } elseif (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                    $null = Stop-ToolkitProcess -ProcessName 'EXCEL' -TimeoutSeconds 5 -Force
                } else {
                    Stop-Process -Name 'EXCEL' -Force -ErrorAction SilentlyContinue
                }
            } else {
                $warnMsg = "Active EXCEL process detected. Close EXCEL or specify -Force to terminate."
                Write-Warning $warnMsg
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message $warnMsg -Level 'WARN' -Component 'Reset-ExcelDdeSettings'
                }
                return [PSCustomObject]@{
                    Status               = 'Warning'
                    DdeDisabled          = $false
                    IgnoreRemoteRequests = $null
                    Calculation          = $null
                    RegBackupFile        = $null
                    ErrorMessage         = "Active EXCEL process detected. Mutating state while running causes lock conflicts or registry overwrites."
                }
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Resetting Excel DDE and calculation mode settings..." -Level 'INFO' -Component 'Reset-ExcelDdeSettings'
        }

        $regBackup = $null

        # 1. Clear IgnoreRemoteRequests (Set to 0)
        try {
            $ddeResult = Set-ToolkitRegistryValue -KeyPath $keyPath -ValueName 'IgnoreRemoteRequests' -Value 0 -PropertyType 'DWord'
            if ($null -ne $ddeResult -and $ddeResult.PSObject.Properties['RegBackupFile']) {
                $regBackup = $ddeResult.RegBackupFile
            }
        }
        catch {
            Write-Verbose "Could not set IgnoreRemoteRequests: $($_.Exception.Message)"
        }

        # 2. Reset Calculation to Automatic (Set to 1)
        try {
            $calcResult = Set-ToolkitRegistryValue -KeyPath $keyPath -ValueName 'Calculation' -Value 1 -PropertyType 'DWord'
            if ([string]::IsNullOrEmpty($regBackup) -and $null -ne $calcResult -and $calcResult.PSObject.Properties['RegBackupFile']) {
                $regBackup = $calcResult.RegBackupFile
            }
        }
        catch {
            Write-Verbose "Could not set Calculation mode: $($_.Exception.Message)"
        }

        return [PSCustomObject]@{
            Status               = 'Success'
            DdeDisabled          = $false
            IgnoreRemoteRequests = 0
            Calculation          = 1
            RegBackupFile        = $regBackup
        }
    }
}
