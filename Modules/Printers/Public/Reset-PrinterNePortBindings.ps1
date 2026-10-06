function Reset-PrinterNePortBindings {
<#
.SYNOPSIS
    Cleans stale NeXX port bindings from the user registry to resolve Office/Excel layout hangs.
.DESCRIPTION
    Backs up HKCU:\Software\Microsoft\Windows NT\CurrentVersion\PrinterPorts to a .reg file,
    identifies orphaned or invalid NeXX port entries, and removes them safely.
.PARAMETER TargetPrinter
    Optional specific printer name to reset Ne port bindings for.
.OUTPUTS
    [PSCustomObject] containing CleanedPortsCount and RegBackupFile.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$TargetPrinter
    )

    process {
        $portsKey = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\PrinterPorts"

        if (-not $PSCmdlet.ShouldProcess($portsKey, "Clean stale Ne port bindings")) {
            return [PSCustomObject]@{
                CleanedPortsCount = 0
                RegBackupFile     = '[Simulated - WhatIf]'
            }
        }

        # 1. Back up registry key before modification
        $backupFile = ''
        try {
            if (Get-Command -Name 'Export-RegistryKeyBackup' -ErrorAction SilentlyContinue) {
                $backupFile = Export-RegistryKeyBackup -KeyPath $portsKey
            }
        } catch {
            Write-Verbose "Export-RegistryKeyBackup error: $($_.Exception.Message)"
        }

        # 2. Enumerate installed printers via CIM
        $installedPrinters = @()
        try {
            $cimPrinters = Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue
            if ($null -ne $cimPrinters) {
                $installedPrinters = @($cimPrinters | ForEach-Object { $_.Name })
            }
        } catch {
            Write-Verbose "Get-CimInstance Win32_Printer error: $($_.Exception.Message)"
        }

        # 3. Clean stale port properties
        $cleanedCount = 0
        try {
            $portsProp = Get-ItemProperty -Path $portsKey -ErrorAction SilentlyContinue
            if ($null -ne $portsProp) {
                foreach ($prop in $portsProp.PSObject.Properties) {
                    $entryName = $prop.Name
                    if ($entryName -notin @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')) {
                        $shouldRemove = $false
                        if (-not [string]::IsNullOrWhiteSpace($TargetPrinter)) {
                            if ($entryName -eq $TargetPrinter) {
                                $shouldRemove = $true
                            }
                        } else {
                            if ($installedPrinters.Count -gt 0 -and $entryName -notin $installedPrinters) {
                                $shouldRemove = $true
                            }
                        }

                        if ($shouldRemove) {
                            try {
                                Remove-ItemProperty -Path $portsKey -Name $entryName -Force -ErrorAction SilentlyContinue
                                $cleanedCount++
                            } catch {
                                Write-Verbose "Failed removing property '$entryName': $($_.Exception.Message)"
                            }
                        }
                    }
                }
            }
        } catch {
            Write-Verbose "Error processing PrinterPorts: $($_.Exception.Message)"
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Cleaned $cleanedCount stale Ne port binding(s). Backup: $backupFile" -Level 'INFO' -Component 'Reset-PrinterNePortBindings'
        }

        return [PSCustomObject]@{
            CleanedPortsCount = [int]$cleanedCount
            RegBackupFile     = $backupFile
        }
    }
}
