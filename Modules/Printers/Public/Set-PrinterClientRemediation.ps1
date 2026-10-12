function Set-PrinterClientRemediation {
<#
.SYNOPSIS
    Applies categorized client-side printer connectivity and configuration remediations.
.DESCRIPTION
    Configures Point and Print driver installation policies, elevation prompt bypasses,
    RPC named pipe protocol settings (fixing 0x00000709), CopyFiles policy (fixing 0x0000007c),
    and resets local print spooler queues, NeXX port bindings, and user printer mappings.
    Delegated to Set-PrinterRemediation engine.
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

        $remParams = @{
            Role = 'Client'
            Fix  = $targetFixes
        }
        if (-not [string]::IsNullOrEmpty($BackupDirectory)) {
            $remParams['BackupDirectory'] = $BackupDirectory
        }
        if ($Force.IsPresent) {
            $remParams['Force'] = $true
        }

        $res = Set-PrinterRemediation @remParams

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Client printer remediation complete. Fixes applied: $($res.FixesApplied -join ', '). Backups: $($res.RegBackupFiles.Count)" -Level 'INFO' -Component 'Set-PrinterClientRemediation'
        }

        return [PSCustomObject]@{
            Role                 = 'Client'
            FixesApplied         = @($res.FixesApplied)
            RegBackupFiles       = @($res.RegBackupFiles)
            QueuePurgedCount     = $res.QueuePurgedCount
            CleanedNePortsCount  = $res.CleanedNePortsCount
            RefreshedConnections = $res.RefreshedConnections
            StaleRemoved         = $res.StaleRemoved
            Success              = $res.Success
        }
    }
}
