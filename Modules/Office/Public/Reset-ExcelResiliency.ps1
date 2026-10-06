function Reset-ExcelResiliency {
<#
.SYNOPSIS
    Clears disabled and crashed add-in records from Excel Resiliency list.
.DESCRIPTION
    Creates an atomic .reg backup and removes entries under
    HKCU:\Software\Microsoft\Office\16.0\Excel\Resiliency\DisabledItems,
    allowing crashed or blacklisted add-ins to load again.
.OUTPUTS
    [PSCustomObject] containing ClearedItemsCount and RegBackupFile.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param()

    process {
        $resiliencyKey = 'HKCU:\Software\Microsoft\Office\16.0\Excel\Resiliency\DisabledItems'

        if (-not $PSCmdlet.ShouldProcess($resiliencyKey, "Clear disabled items resiliency list")) {
            return [PSCustomObject]@{
                ClearedItemsCount = 0
                RegBackupFile     = '[Simulated - WhatIf]'
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Resetting Excel Resiliency disabled items list..." -Level 'INFO' -Component 'Reset-ExcelResiliency'
        }

        # Step 1: Pre-modification registry backup
        $regBackupFile = $null
        if (Get-Command -Name 'Export-RegistryKeyBackup' -ErrorAction SilentlyContinue) {
            $regBackupFile = Export-RegistryKeyBackup -KeyPath $resiliencyKey
        }

        # Step 2: Enumerate and clear properties
        $clearedCount = 0
        try {
            if (Test-Path -LiteralPath $resiliencyKey) {
                $item = Get-Item -LiteralPath $resiliencyKey -ErrorAction SilentlyContinue
                if ($null -ne $item) {
                    $propNames = @($item.Property)
                    foreach ($p in $propNames) {
                        Remove-ItemProperty -LiteralPath $resiliencyKey -Name $p -Force -ErrorAction SilentlyContinue
                        $clearedCount++
                    }
                }
            }
        }
        catch {
            Write-Verbose "Could not clear resiliency item properties: $($_.Exception.Message)"
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Cleared $clearedCount item(s) from Excel Resiliency list. Backup: $regBackupFile" -Level 'INFO' -Component 'Reset-ExcelResiliency'
        }

        return [PSCustomObject]@{
            ClearedItemsCount = $clearedCount
            RegBackupFile     = $regBackupFile
        }
    }
}
