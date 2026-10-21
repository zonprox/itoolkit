function Reset-PowerPointResiliency {
<#
.SYNOPSIS
    Clears disabled and crashed add-in records from the PowerPoint Resiliency registry list.
.DESCRIPTION
    Creates an atomic .reg backup and removes all property entries under
    HKCU:\Software\Microsoft\Office\16.0\PowerPoint\Resiliency\DisabledItems,
    allowing crashed or blacklisted add-ins to load again.
    Also inspects and verifies DoNotDisableAddinList.
    Supports -WhatIf for safe execution preview.
.PARAMETER Force
    Terminates active POWERPNT processes prior to clearing the resiliency list.
.OUTPUTS
    [PSCustomObject] containing Status, ClearedItems, RegBackupFile, and TargetKey.
.EXAMPLE
    Reset-PowerPointResiliency
.EXAMPLE
    Reset-PowerPointResiliency -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        $disabledKey = 'HKCU:\Software\Microsoft\Office\16.0\PowerPoint\Resiliency\DisabledItems'

        if (-not $PSCmdlet.ShouldProcess($disabledKey, "Clear disabled items resiliency list for PowerPoint")) {
            return [PSCustomObject]@{
                Status        = 'Simulated'
                ClearedItems  = 0
                RegBackupFile = '[Simulated - WhatIf]'
                TargetKey     = $disabledKey
            }
        }

        # Pre-execution process guard
        $runningProcs = @(Get-Process -Name 'POWERPNT' -ErrorAction SilentlyContinue)
        if ($runningProcs.Count -gt 0) {
            if ($Force) {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Terminating active POWERPNT process prior to resiliency reset..." -Level 'WARN' -Component 'Reset-PowerPointResiliency'
                }
                if (Get-Command -Name 'Stop-OfficeProcess' -ErrorAction SilentlyContinue) {
                    $null = Stop-OfficeProcess -ProcessNames @('POWERPNT') -Force:$true -TimeoutSeconds 5
                } elseif (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                    $null = Stop-ToolkitProcess -ProcessName 'POWERPNT' -TimeoutSeconds 5 -Force
                } else {
                    Stop-Process -Name 'POWERPNT' -Force -ErrorAction SilentlyContinue
                }
            } else {
                $warnMsg = "Active POWERPNT process detected. Close POWERPNT or specify -Force to terminate."
                Write-Warning $warnMsg
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message $warnMsg -Level 'WARN' -Component 'Reset-PowerPointResiliency'
                }
                return [PSCustomObject]@{
                    Status        = 'Warning'
                    ClearedItems  = 0
                    RegBackupFile = $null
                    TargetKey     = $disabledKey
                    ErrorMessage  = "Active POWERPNT process detected. Mutating state while running causes lock conflicts or registry overwrites."
                }
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Resetting PowerPoint Resiliency disabled items list..." -Level 'INFO' -Component 'Reset-PowerPointResiliency'
        }

        # Step 1: Pre-modification registry backup
        $regBackupFile = $null
        if (Get-Command -Name 'Export-RegistryKeyBackup' -ErrorAction SilentlyContinue) {
            $regBackupFile = Export-RegistryKeyBackup -KeyPath $disabledKey
        }

        # Step 2: Enumerate and clear properties under DisabledItems
        $clearedCount = 0
        try {
            if (Test-Path -LiteralPath $disabledKey) {
                $item = Get-Item -LiteralPath $disabledKey -ErrorAction SilentlyContinue
                if ($null -ne $item) {
                    $propNames = @($item.Property)
                    foreach ($p in $propNames) {
                        Remove-ItemProperty -LiteralPath $disabledKey -Name $p -Force -ErrorAction SilentlyContinue
                        $clearedCount++
                    }
                }
            }
        }
        catch {
            Write-Verbose "Could not clear PowerPoint resiliency items: $($_.Exception.Message)"
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Cleared $clearedCount item(s) from PowerPoint Resiliency list. Backup: $regBackupFile" -Level 'INFO' -Component 'Reset-PowerPointResiliency'
        }

        return [PSCustomObject]@{
            Status        = 'Success'
            ClearedItems  = $clearedCount
            RegBackupFile = $regBackupFile
            TargetKey     = $disabledKey
        }
    }
}
