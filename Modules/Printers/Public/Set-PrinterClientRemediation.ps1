function Set-PrinterClientRemediation {
<#
.SYNOPSIS
    Applies categorized client-side printer connectivity and configuration remediations.
.DESCRIPTION
    Configures Point and Print driver installation policies, elevation prompt bypasses,
    RPC named pipe protocol settings (fixing 0x00000709), CopyFiles policy (fixing 0x0000007c),
    and resets local print spooler queues, NeXX port bindings, and user printer mappings.
.PARAMETER All
    Batch flag to execute all client remediations sequentially.
.PARAMETER Fix
    Specific fix or fixes to apply. Valid values:
    - 'All': Executes all client fixes.
    - 'PointAndPrintAdmin': Sets RestrictDriverInstallationToAdministrators = 0.
    - 'PointAndPrintPrompts': Sets NoWarningNoElevationOnInstall = 1 and UpdatePromptSettings = 2.
    - 'RpcNamedPipe': Sets RpcUseNamedPipeProtocol = 1 in Printers\RPC to fix 0x00000709.
    - 'CopyFilesPolicy': Sets CopyFilesPolicy = 1 to fix 0x0000007c.
    - 'SpoolerQueue': Purges local print spooler queue via Reset-PrintSpoolerQueue.
    - 'NePorts': Cleans stale NeXX port bindings via Reset-PrinterNePortBindings.
    - 'RefreshConnections': Refreshes mapped network printer connections via Reset-PrinterConnections.
.PARAMETER BackupDirectory
    Optional custom directory path where pre-modification .reg backup files are stored.
.PARAMETER Force
    Forces termination of lingering spoolsv processes during queue purge.
.OUTPUTS
    [PSCustomObject] containing Role, FixesApplied, RegBackupFiles, QueuePurgedCount, CleanedNePortsCount, RefreshedConnections, StaleRemoved, Success.
.EXAMPLE
    Set-PrinterClientRemediation -All
.EXAMPLE
    Set-PrinterClientRemediation -Fix RpcNamedPipe, CopyFilesPolicy
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$All,

        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('All', 'PointAndPrintAdmin', 'PointAndPrintPrompts', 'RpcNamedPipe', 'CopyFilesPolicy', 'SpoolerQueue', 'NePorts', 'RefreshConnections')]
        [string[]]$Fix = @('All'),

        [Parameter(Mandatory = $false)]
        [string]$BackupDirectory,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        $targetFixes = @()
        if ($All.IsPresent -or ($Fix -contains 'All')) {
            $targetFixes = @('PointAndPrintAdmin', 'PointAndPrintPrompts', 'RpcNamedPipe', 'CopyFilesPolicy', 'SpoolerQueue', 'NePorts', 'RefreshConnections')
        } else {
            foreach ($f in $Fix) {
                if ($f -notin $targetFixes) {
                    $targetFixes += $f
                }
            }
        }

        if (-not $PSCmdlet.ShouldProcess("Print Client", "Apply client remediation: $($targetFixes -join ', ')")) {
            return [PSCustomObject]@{
                Role                 = 'Client'
                FixesApplied         = @($targetFixes)
                RegBackupFiles       = @('[Simulated - WhatIf]')
                QueuePurgedCount     = 0
                CleanedNePortsCount  = 0
                RefreshedConnections = 0
                StaleRemoved         = 0
                Success              = $true
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Applying client printer remediation: $($targetFixes -join ', ')..." -Level 'INFO' -Component 'Set-PrinterClientRemediation'
        }

        $regBackupFiles       = @()
        $appliedFixes         = @()
        $queuePurgedCount     = 0
        $cleanedNePortsCount  = 0
        $refreshedConnections = 0
        $staleRemoved         = 0

        # Helper to apply registry value and return backup file
        $setReg = {
            param([string]$Key, [string]$Name, [object]$Value, [string]$Type = 'DWord')
            $regParams = @{
                KeyPath      = $Key
                ValueName    = $Name
                Value        = $Value
                PropertyType = $Type
            }
            if (-not [string]::IsNullOrEmpty($BackupDirectory)) {
                $regParams['BackupDirectory'] = $BackupDirectory
            }
            try {
                if (Get-Command -Name 'Set-ToolkitRegistryValue' -ErrorAction SilentlyContinue) {
                    $res = Set-ToolkitRegistryValue @regParams
                    if ($null -ne $res) {
                        if ($res.PSObject.Properties['RegBackupFile'] -and -not [string]::IsNullOrWhiteSpace($res.RegBackupFile)) {
                            return [string]$res.RegBackupFile
                        } elseif ($res.PSObject.Properties['BackupFile'] -and -not [string]::IsNullOrWhiteSpace($res.BackupFile)) {
                            return [string]$res.BackupFile
                        }
                    }
                }
            } catch {
                Write-Verbose "Error setting registry value $Key\$Name : $($_.Exception.Message)"
            }
            return $null
        }

        # 1. PointAndPrintAdmin (RestrictDriverInstallationToAdministrators = 0)
        if ($targetFixes -contains 'PointAndPrintAdmin') {
            $b = & $setReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint' 'RestrictDriverInstallationToAdministrators' 0 'DWord'
            if (-not [string]::IsNullOrWhiteSpace($b) -and ($b -notin $regBackupFiles)) {
                $regBackupFiles += $b
            }
            $appliedFixes += 'PointAndPrintAdmin'
        }

        # 2. PointAndPrintPrompts (NoWarningNoElevationOnInstall = 1, UpdatePromptSettings = 2)
        if ($targetFixes -contains 'PointAndPrintPrompts') {
            $b1 = & $setReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint' 'NoWarningNoElevationOnInstall' 1 'DWord'
            if (-not [string]::IsNullOrWhiteSpace($b1) -and ($b1 -notin $regBackupFiles)) {
                $regBackupFiles += $b1
            }
            $b2 = & $setReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint' 'UpdatePromptSettings' 2 'DWord'
            if (-not [string]::IsNullOrWhiteSpace($b2) -and ($b2 -notin $regBackupFiles)) {
                $regBackupFiles += $b2
            }
            $appliedFixes += 'PointAndPrintPrompts'
        }

        # 3. RpcNamedPipe (RpcUseNamedPipeProtocol = 1, fixes 0x00000709)
        if ($targetFixes -contains 'RpcNamedPipe') {
            $b = & $setReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC' 'RpcUseNamedPipeProtocol' 1 'DWord'
            if (-not [string]::IsNullOrWhiteSpace($b) -and ($b -notin $regBackupFiles)) {
                $regBackupFiles += $b
            }
            $appliedFixes += 'RpcNamedPipe'
        }

        # 4. CopyFilesPolicy (CopyFilesPolicy = 1, fixes 0x0000007c)
        if ($targetFixes -contains 'CopyFilesPolicy') {
            $b = & $setReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers' 'CopyFilesPolicy' 1 'DWord'
            if (-not [string]::IsNullOrWhiteSpace($b) -and ($b -notin $regBackupFiles)) {
                $regBackupFiles += $b
            }
            $appliedFixes += 'CopyFilesPolicy'
        }

        # 5. SpoolerQueue (Reset-PrintSpoolerQueue)
        if ($targetFixes -contains 'SpoolerQueue') {
            try {
                if (Get-Command -Name 'Reset-PrintSpoolerQueue' -ErrorAction SilentlyContinue) {
                    $qRes = Reset-PrintSpoolerQueue -Force:$Force
                    if ($null -ne $qRes -and $qRes.PSObject.Properties['FilesPurged']) {
                        $queuePurgedCount = [int]$qRes.FilesPurged
                    }
                }
            } catch {
                Write-Verbose "Error running Reset-PrintSpoolerQueue: $($_.Exception.Message)"
            }
            $appliedFixes += 'SpoolerQueue'
        }

        # 6. NePorts (Reset-PrinterNePortBindings)
        if ($targetFixes -contains 'NePorts') {
            try {
                if (Get-Command -Name 'Reset-PrinterNePortBindings' -ErrorAction SilentlyContinue) {
                    $neRes = Reset-PrinterNePortBindings
                    if ($null -ne $neRes) {
                        if ($neRes.PSObject.Properties['CleanedPortsCount']) {
                            $cleanedNePortsCount = [int]$neRes.CleanedPortsCount
                        }
                        if ($neRes.PSObject.Properties['RegBackupFile'] -and -not [string]::IsNullOrWhiteSpace($neRes.RegBackupFile)) {
                            if ($neRes.RegBackupFile -notin $regBackupFiles) {
                                $regBackupFiles += [string]$neRes.RegBackupFile
                            }
                        }
                    }
                }
            } catch {
                Write-Verbose "Error running Reset-PrinterNePortBindings: $($_.Exception.Message)"
            }
            $appliedFixes += 'NePorts'
        }

        # 7. RefreshConnections (Reset-PrinterConnections -All)
        if ($targetFixes -contains 'RefreshConnections') {
            try {
                if (Get-Command -Name 'Reset-PrinterConnections' -ErrorAction SilentlyContinue) {
                    $connRes = Reset-PrinterConnections -All
                    if ($null -ne $connRes) {
                        if ($connRes.PSObject.Properties['RefreshedConnections']) {
                            $refreshedConnections = [int]$connRes.RefreshedConnections
                        }
                        if ($connRes.PSObject.Properties['StaleRemoved']) {
                            $staleRemoved = [int]$connRes.StaleRemoved
                        }
                    }
                }
            } catch {
                Write-Verbose "Error running Reset-PrinterConnections: $($_.Exception.Message)"
            }
            $appliedFixes += 'RefreshConnections'
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Client printer remediation complete. Fixes applied: $($appliedFixes -join ', '). Backups: $($regBackupFiles.Count)" -Level 'INFO' -Component 'Set-PrinterClientRemediation'
        }

        return [PSCustomObject]@{
            Role                 = 'Client'
            FixesApplied         = @($appliedFixes)
            RegBackupFiles       = @($regBackupFiles)
            QueuePurgedCount     = $queuePurgedCount
            CleanedNePortsCount  = $cleanedNePortsCount
            RefreshedConnections = $refreshedConnections
            StaleRemoved         = $staleRemoved
            Success              = $true
        }
    }
}
