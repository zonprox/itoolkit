function Reset-ExcelResiliency {
<#
.SYNOPSIS
    Clears disabled and crashed add-in records from Excel Resiliency list.
.DESCRIPTION
    Creates an atomic .reg backup and removes entries under
    HKCU:\Software\Microsoft\Office\16.0\Excel\Resiliency\DisabledItems,
    allowing crashed or blacklisted add-ins to load again.
.PARAMETER Force
    Terminates active EXCEL processes prior to clearing the resiliency list.
.OUTPUTS
    [PSCustomObject] containing Status, ClearedItemsCount, and RegBackupFile.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        $resiliencyKey = 'HKCU:\Software\Microsoft\Office\16.0\Excel\Resiliency\DisabledItems'

        if (-not $PSCmdlet.ShouldProcess($resiliencyKey, "Clear disabled items resiliency list")) {
            return [PSCustomObject]@{
                Status            = 'Simulated'
                ClearedItemsCount = 0
                RegBackupFile     = '[Simulated - WhatIf]'
            }
        }

        # Pre-execution process guard
        $runningProcs = @(Get-Process -Name 'EXCEL' -ErrorAction SilentlyContinue)
        if ($runningProcs.Count -gt 0) {
            if ($Force) {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Terminating active EXCEL process prior to resiliency reset..." -Level 'WARN' -Component 'Reset-ExcelResiliency'
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
                    Write-ToolkitLog -Message $warnMsg -Level 'WARN' -Component 'Reset-ExcelResiliency'
                }
                return [PSCustomObject]@{
                    Status            = 'Warning'
                    ClearedItemsCount = 0
                    RegBackupFile     = $null
                    ErrorMessage      = "Active EXCEL process detected. Mutating state while running causes lock conflicts or registry overwrites."
                }
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
            Status            = 'Success'
            ClearedItemsCount = $clearedCount
            RegBackupFile     = $regBackupFile
        }
    }
}
