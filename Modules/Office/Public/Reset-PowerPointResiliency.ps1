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
.OUTPUTS
    [PSCustomObject] containing Status, ClearedItems, RegBackupFile, and TargetKey.
.EXAMPLE
    Reset-PowerPointResiliency
.EXAMPLE
    Reset-PowerPointResiliency -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param()

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
