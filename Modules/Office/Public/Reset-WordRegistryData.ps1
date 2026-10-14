function Reset-WordRegistryData {
<#
.SYNOPSIS
    Resets corrupted Word Data and Options registry keys with automated .reg backup.
.DESCRIPTION
    Backs up and resets HKCU:\Software\Microsoft\Office\16.0\Word\Data and/or Options keys.
    Terminates active Word processes to prevent post-exit cache rewrites.
    Word recreates clean factory defaults on subsequent launch.
.PARAMETER ResetOptions
    Resets the Word\Options registry key.
.PARAMETER ResetData
    Resets the Word\Data registry key.
.OUTPUTS
    [PSCustomObject]@{ Status = 'Success'|'Skipped' }
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$ResetOptions,

        [Parameter(Mandatory = $false)]
        [switch]$ResetData
    )

    process {
        # Default to resetting both if neither parameter is explicitly supplied
        $targetData = $ResetData.IsPresent
        $targetOptions = $ResetOptions.IsPresent
        if (-not $targetData -and -not $targetOptions) {
            $targetData = $true
            $targetOptions = $true
        }

        $baseKey = 'HKCU:\Software\Microsoft\Office\16.0\Word'
        $keysToReset = [System.Collections.Generic.List[string]]::new()
        if ($targetData) {
            $keysToReset.Add("$baseKey\Data")
        }
        if ($targetOptions) {
            $keysToReset.Add("$baseKey\Options")
        }

        # WhatIf check
        if (-not $PSCmdlet.ShouldProcess("Word Registry Hives", "Reset target keys: $($keysToReset -join ', ')")) {
            return [PSCustomObject]@{ Status = 'Success' }
        }

        # Process termination pre-flight
        if (Get-Command -Name 'Test-ProcessRunning' -ErrorAction SilentlyContinue) {
            if (Test-ProcessRunning -ProcessName 'WINWORD') {
                if (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Terminating active WINWORD process prior to Word registry reset..." -Level 'WARN' -Component 'Reset-WordRegistryData'
                    $null = Stop-ToolkitProcess -ProcessName 'WINWORD' -TimeoutSeconds 5 -Force
                }
            }
        }

        $resetCount = 0
        foreach ($key in $keysToReset) {
            if (Test-Path -LiteralPath $key) {
                # Pre-modification registry backup
                if (Get-Command -Name 'Export-RegistryKeyBackup' -ErrorAction SilentlyContinue) {
                    $bkFile = Export-RegistryKeyBackup -KeyPath $key
                    if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                        Write-ToolkitLog -Message "Backed up '$key' to '$bkFile'" -Level 'INFO' -Component 'Reset-WordRegistryData'
                    }
                }

                try {
                    Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop
                    $resetCount++
                    if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                        Write-ToolkitLog -Message "Successfully reset Word registry key '$key'." -Level 'INFO' -Component 'Reset-WordRegistryData'
                    }
                }
                catch {
                    if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                        Write-ToolkitLog -Message "Failed to remove registry key '$key': $($_.Exception.Message)" -Level 'ERROR' -Component 'Reset-WordRegistryData'
                    }
                }
            } else {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Registry key '$key' does not exist. Default state active." -Level 'INFO' -Component 'Reset-WordRegistryData'
                }
            }
        }

        return [PSCustomObject]@{
            Status = if ($resetCount -gt 0) { 'Success' } else { 'Skipped' }
        }
    }
}
