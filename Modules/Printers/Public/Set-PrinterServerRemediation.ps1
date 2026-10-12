function Set-PrinterServerRemediation {
<#
.SYNOPSIS
    Applies categorized server-side printer connectivity and RPC configuration remediations.
.DESCRIPTION
    Configures print host registry settings, RPC endpoints and protocols, and verifies Print Spooler
    service health and directory permissions with automated pre-modification registry backups.
    Addresses error 0x0000011b (RpcAuthnLevelPrivacyEnabled), remote RPC endpoint binding,
    and RPC protocol mismatches. Delegated to Set-PrinterRemediation engine.
.PARAMETER All
    Batch flag to execute all server remediations sequentially.
.PARAMETER Fix
    Specific fix or fixes to apply. Valid values:
    - 'All': Executes all server fixes.
    - 'RpcAuthnLevel': Sets RpcAuthnLevelPrivacyEnabled = 0 to fix 0x0000011b.
    - 'RemoteRpcEndPoint': Sets RegisterSpoolerRemoteRpcEndPoint = 1 to allow client RPC binds.
    - 'RpcProtocols': Sets RpcUseNamedPipeProtocol = 1 and RpcProtocols = 7 (TCP, Named Pipes, LPC).
    - 'SpoolerHealth': Verifies spool directory existence/permissions and restarts Spooler service.
.PARAMETER BackupDirectory
    Optional custom directory path where pre-modification .reg backup files are stored.
.PARAMETER Force
    Forces termination of any lingering spoolsv processes during spooler restart.
.OUTPUTS
    [PSCustomObject] containing Role, FixesApplied, RegBackupFiles, SpoolerRestarted, DirectoryStatus, Success.
.EXAMPLE
    Set-PrinterServerRemediation -All
.EXAMPLE
    Set-PrinterServerRemediation -Fix RpcAuthnLevel
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$All,

        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('All', 'RpcAuthnLevel', 'RemoteRpcEndPoint', 'RpcProtocols', 'SpoolerHealth')]
        [string[]]$Fix = @('All'),

        [Parameter(Mandatory = $false)]
        [string]$BackupDirectory,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        $targetFixes = @()
        if ($All.IsPresent -or ($Fix -contains 'All')) {
            $targetFixes = @('RpcAuthnLevel', 'RemoteRpcEndPoint', 'RpcProtocols', 'SpoolerHealth')
        } else {
            foreach ($f in $Fix) {
                if ($f -notin $targetFixes) {
                    $targetFixes += $f
                }
            }
        }

        if (-not $PSCmdlet.ShouldProcess("Print Server", "Apply server remediation: $($targetFixes -join ', ')")) {
            return [PSCustomObject]@{
                Role             = 'Server'
                FixesApplied     = @($targetFixes)
                RegBackupFiles   = @('[Simulated - WhatIf]')
                SpoolerRestarted = $false
                DirectoryStatus  = 'Simulated'
                Success          = $true
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Applying server printer remediation: $($targetFixes -join ', ')..." -Level 'INFO' -Component 'Set-PrinterServerRemediation'
        }

        $remParams = @{
            Role = 'Server'
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
            Write-ToolkitLog -Message "Server printer remediation complete. Fixes applied: $($res.FixesApplied -join ', '). Backups: $($res.RegBackupFiles.Count)" -Level 'INFO' -Component 'Set-PrinterServerRemediation'
        }

        return [PSCustomObject]@{
            Role             = 'Server'
            FixesApplied     = @($res.FixesApplied)
            RegBackupFiles   = @($res.RegBackupFiles)
            SpoolerRestarted = $res.SpoolerRestarted
            DirectoryStatus  = $res.DirectoryStatus
            Success          = $res.Success
        }
    }
}
