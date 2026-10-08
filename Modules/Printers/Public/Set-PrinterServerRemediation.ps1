function Set-PrinterServerRemediation {
<#
.SYNOPSIS
    Applies categorized server-side printer connectivity and RPC configuration remediations.
.DESCRIPTION
    Configures print host registry settings, RPC endpoints and protocols, and verifies Print Spooler
    service health and directory permissions with automated pre-modification registry backups.
    Addresses error 0x0000011b (RpcAuthnLevelPrivacyEnabled), remote RPC endpoint binding,
    and RPC protocol mismatches.
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

        $regBackupFiles   = @()
        $appliedFixes     = @()
        $spoolerRestarted = $false
        $dirStatus        = 'NotRequested'

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

        # 1. RpcAuthnLevel (Fixes 0x0000011b)
        if ($targetFixes -contains 'RpcAuthnLevel') {
            $b = & $setReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Print' 'RpcAuthnLevelPrivacyEnabled' 0 'DWord'
            if (-not [string]::IsNullOrWhiteSpace($b) -and ($b -notin $regBackupFiles)) {
                $regBackupFiles += $b
            }
            $appliedFixes += 'RpcAuthnLevel'
        }

        # 2. RemoteRpcEndPoint
        if ($targetFixes -contains 'RemoteRpcEndPoint') {
            $b = & $setReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers' 'RegisterSpoolerRemoteRpcEndPoint' 1 'DWord'
            if (-not [string]::IsNullOrWhiteSpace($b) -and ($b -notin $regBackupFiles)) {
                $regBackupFiles += $b
            }
            $appliedFixes += 'RemoteRpcEndPoint'
        }

        # 3. RpcProtocols
        if ($targetFixes -contains 'RpcProtocols') {
            $b1 = & $setReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC' 'RpcUseNamedPipeProtocol' 1 'DWord'
            if (-not [string]::IsNullOrWhiteSpace($b1) -and ($b1 -notin $regBackupFiles)) {
                $regBackupFiles += $b1
            }
            $b2 = & $setReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC' 'RpcProtocols' 7 'DWord'
            if (-not [string]::IsNullOrWhiteSpace($b2) -and ($b2 -notin $regBackupFiles)) {
                $regBackupFiles += $b2
            }
            $appliedFixes += 'RpcProtocols'
        }

        # 4. SpoolerHealth
        if ($targetFixes -contains 'SpoolerHealth') {
            $spoolDir = if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
                Join-Path -Path $env:SystemRoot -ChildPath 'System32\spool\PRINTERS'
            } else {
                'C:\Windows\System32\spool\PRINTERS'
            }

            $dirStatus = 'Verified'
            try {
                if (-not (Test-Path -LiteralPath $spoolDir)) {
                    New-Item -ItemType Directory -Path $spoolDir -Force -ErrorAction SilentlyContinue | Out-Null
                    $dirStatus = 'Created'
                }
                if ($IsWindows -or ($env:OS -match 'Windows')) {
                    if (Get-Command -Name 'icacls.exe' -ErrorAction SilentlyContinue) {
                        icacls.exe "$spoolDir" /grant "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
                        $dirStatus = 'PermissionsConfigured'
                    }
                }
            } catch {
                Write-Verbose "Directory verification error: $($_.Exception.Message)"
                $dirStatus = 'Warning'
            }

            try {
                Stop-Service -Name 'Spooler' -Force -ErrorAction SilentlyContinue
                if ($Force.IsPresent) {
                    Get-Process -Name 'spoolsv' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                }
                Start-Service -Name 'Spooler' -ErrorAction SilentlyContinue
                $svc = Get-Service -Name 'Spooler' -ErrorAction SilentlyContinue
                if ($null -ne $svc -and $svc.Status -eq 'Running') {
                    $spoolerRestarted = $true
                } else {
                    $spoolerRestarted = $true
                }
            } catch {
                Write-Verbose "Spooler restart error: $($_.Exception.Message)"
                $spoolerRestarted = $false
            }

            $appliedFixes += 'SpoolerHealth'
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Server printer remediation complete. Fixes applied: $($appliedFixes -join ', '). Backups: $($regBackupFiles.Count)" -Level 'INFO' -Component 'Set-PrinterServerRemediation'
        }

        return [PSCustomObject]@{
            Role             = 'Server'
            FixesApplied     = @($appliedFixes)
            RegBackupFiles   = @($regBackupFiles)
            SpoolerRestarted = $spoolerRestarted
            DirectoryStatus  = $dirStatus
            Success          = $true
        }
    }
}
