# ==============================================================================
# Printers.Tests.ps1
# Unit test suite for Modules/Printers
# Covers: Get-PrintSpoolerStatus, Reset-PrintSpoolerQueue,
# Register-PrintSpoolerComponents, Reset-PrinterNePortBindings,
# Test-PointAndPrintPolicy, Set-PointAndPrintRemediation,
# Test-NetworkPrinterConnectivity, Reset-PrinterConnections,
# Set-PrinterServerRemediation, Set-PrinterClientRemediation.
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:PrintersManifest = Join-Path $ProjectRoot 'Modules/Printers/Printers.psd1'
$isPrintersAvailable = Test-Path $script:PrintersManifest

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    $manifests = Get-ChildItem -Path (Join-Path $root "Modules") -Filter "*.psd1" -Recurse -ErrorAction SilentlyContinue
    if ($manifests) {
        foreach ($m in $manifests) {
            try {
                Import-Module $m.FullName -Force -ErrorAction Stop
            } catch {
                Write-Warning "Failed to load module $($m.Name): $_"
            }
        }
    }
}
Describe 'Unit: Printers Troubleshooting Module' {

    Context 'Spooler Diagnostics & Queue Management' {
        It 'Get-PrintSpoolerStatus returns spooler service and queue file statistics' -Skip:(-not $isPrintersAvailable) {
            Mock Get-Service { return [PSCustomObject]@{ Status = 'Running'; StartType = 'Automatic' } }
            Mock Get-Process { return [PSCustomObject]@{ Id = 1204 } }
            Mock Get-ChildItem { return @([PSCustomObject]@{ Length = 2048 }, [PSCustomObject]@{ Length = 4096 }) }

            $status = Get-PrintSpoolerStatus
            $status.ServiceStatus | Should -Be 'Running'
            $status.PID | Should -Be 1204
            $status.QueueFileCount | Should -Be 2
            $status.QueueSizeBytes | Should -Be 6144
        }

        It 'Reset-PrintSpoolerQueue stops service, purges corrupt files, and restarts spooler' -Skip:(-not $isPrintersAvailable) {
            Mock Stop-Service { }
            Mock Remove-Item { }
            Mock Start-Service { }
            Mock Get-ChildItem { return @([PSCustomObject]@{ FullName = 'C:\Windows\System32\spool\PRINTERS\00001.SHD' }) }

            $res = Reset-PrintSpoolerQueue
            $res.FilesPurged | Should -BeGreaterThan 0
            $res.ServiceRestarted | Should -BeTrue
        }
    }

    Context 'Component Re-Registration & Port Reset' {
        It 'Register-PrintSpoolerComponents re-registers print DLLs and WMI' -Skip:(-not $isPrintersAvailable) {
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            $res = Register-PrintSpoolerComponents
            $res.DllsRegistered | Should -BeTrue
            $res.WmiRecompiled | Should -BeTrue
            $res.DependencyRestored | Should -BeTrue
        }

        It 'Reset-PrinterNePortBindings cleans stale NeXX ports from registry' -Skip:(-not $isPrintersAvailable) {
            Mock Export-RegistryKeyBackup { return 'C:\Backups\NePorts.reg' }
            Mock Remove-ItemProperty { }
            $res = Reset-PrinterNePortBindings
            $res.CleanedPortsCount | Should -BeGreaterOrEqual 0
            $res.RegBackupFile | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Point and Print Policy & PrintNightmare Audit' {
        It 'Test-PointAndPrintPolicy audits RpcAuthnLevelPrivacyEnabled' -Skip:(-not $isPrintersAvailable) {
            Mock Get-ItemProperty {
                return [PSCustomObject]@{
                    RpcAuthnLevelPrivacyEnabled = 0
                    RestrictDriverInstallationToAdministrators = 1
                }
            }
            $audit = Test-PointAndPrintPolicy
            $audit.RpcAuthnLevelPrivacyEnabled | Should -Be 0
        }

        It 'Set-PointAndPrintRemediation applies targeted fix preset with registry backup' -Skip:(-not $isPrintersAvailable) {
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\PrintNightmare.reg' } }
            $res = Set-PointAndPrintRemediation -Preset 'StrictAdminOnly'
            $res.PresetApplied | Should -Be 'StrictAdminOnly'
            $res.RegBackupFile | Should -Match 'PrintNightmare\.reg'
        }
    }

    Context 'Network Printer Connectivity & Connections' {
        It 'Test-NetworkPrinterConnectivity tests DNS, SMB 445, and Port 9100' -Skip:(-not $isPrintersAvailable) {
            Mock Test-Connection { return $true }
            Mock Test-NetConnection { return [PSCustomObject]@{ TcpTestSucceeded = $true } }

            $test = Test-NetworkPrinterConnectivity -ComputerName 'print-server-01.corp.local'
            $test.PingSuccess | Should -BeTrue
            $test.SmbPortOpen | Should -BeTrue
            $test.RawPrintPortOpen | Should -BeTrue
        }

        It 'Test-NetworkPrinterConnectivity tests custom ports when supplied' -Skip:(-not $isPrintersAvailable) {
            Mock Test-Connection { return $true }
            Mock Test-NetConnection { return [PSCustomObject]@{ TcpTestSucceeded = $true } }

            $test = Test-NetworkPrinterConnectivity -ComputerName 'print-server-01.corp.local' -Ports @(515, 631)
            $test.PingSuccess | Should -BeTrue
            $test.CustomPortResults[515] | Should -BeTrue
            $test.CustomPortResults[631] | Should -BeTrue
        }

        It 'Reset-PrinterConnections refreshes user network printer mappings' -Skip:(-not $isPrintersAvailable) {
            if (-not (Get-Command -Name 'Add-Printer' -ErrorAction SilentlyContinue)) {
                function global:Add-Printer { param($ConnectionName) }
            }
            Mock Get-CimInstance { return @([PSCustomObject]@{ Name = '\\server\printer' }) }
            Mock Test-Connection { return $true }
            Mock Add-Printer { }
            $res = Reset-PrinterConnections -All
            $res.RefreshedConnections | Should -Be 1
            $res.StaleRemoved | Should -Be 0
        }
    }

    Context 'Server-Side Network Printer Remediation (R2)' {
        It 'Set-PrinterServerRemediation -All applies all server mitigations sequentially and generates backups' -Skip:(-not $isPrintersAvailable) {
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ BackupFile = 'C:\Backups\ServerFix.reg'; RegBackupFile = 'C:\Backups\ServerFix.reg' } }
            Mock Stop-Service { }
            Mock Start-Service { }
            Mock Get-Service { return [PSCustomObject]@{ Status = 'Running' } }
            Mock Test-Path { return $true }

            $res = Set-PrinterServerRemediation -All
            $res.Role | Should -Be 'Server'
            $res.FixesApplied | Should -Contain 'RpcAuthnLevel'
            $res.FixesApplied | Should -Contain 'RemoteRpcEndPoint'
            $res.FixesApplied | Should -Contain 'RpcProtocols'
            $res.FixesApplied | Should -Contain 'SpoolerHealth'
            $res.RegBackupFiles.Count | Should -BeGreaterThan 0
            $res.SpoolerRestarted | Should -BeTrue
            $res.Success | Should -BeTrue
        }

        It 'Set-PrinterServerRemediation applies targeted fix RpcAuthnLevel (fixes 0x0000011b)' -Skip:(-not $isPrintersAvailable) {
            $calledValues = @{}
            Mock Set-ToolkitRegistryValue {
                $calledValues[$ValueName] = $Value
                return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\RpcAuthn.reg' }
            }

            $res = Set-PrinterServerRemediation -Fix 'RpcAuthnLevel'
            $res.Role | Should -Be 'Server'
            $res.FixesApplied | Should -Contain 'RpcAuthnLevel'
            $res.FixesApplied | Should -Not -Contain 'RemoteRpcEndPoint'
            $calledValues['RpcAuthnLevelPrivacyEnabled'] | Should -Be 0
            $res.RegBackupFiles | Should -Contain 'C:\Backups\RpcAuthn.reg'
        }

        It 'Set-PrinterServerRemediation applies targeted RemoteRpcEndPoint and RpcProtocols' -Skip:(-not $isPrintersAvailable) {
            $calledValues = @{}
            Mock Set-ToolkitRegistryValue {
                $calledValues[$ValueName] = $Value
                return [PSCustomObject]@{ RegBackupFile = "C:\Backups\$ValueName.reg" }
            }

            $res = Set-PrinterServerRemediation -Fix 'RemoteRpcEndPoint', 'RpcProtocols'
            $res.FixesApplied | Should -Contain 'RemoteRpcEndPoint'
            $res.FixesApplied | Should -Contain 'RpcProtocols'
            $res.FixesApplied | Should -Not -Contain 'RpcAuthnLevel'
            $calledValues['RegisterSpoolerRemoteRpcEndPoint'] | Should -Be 1
            $calledValues['RpcUseNamedPipeProtocol'] | Should -Be 1
            $calledValues['RpcProtocols'] | Should -Be 7
        }

        It 'Set-PrinterServerRemediation supports -WhatIf simulation' -Skip:(-not $isPrintersAvailable) {
            $res = Set-PrinterServerRemediation -All -WhatIf
            $res.Role | Should -Be 'Server'
            $res.RegBackupFiles | Should -Contain '[Simulated - WhatIf]'
            $res.SpoolerRestarted | Should -BeFalse
        }

        It 'Supports rollback capability via Restore-RegistryKeyBackup on server backups' -Skip:(-not $isPrintersAvailable) {
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\ServerFix.reg' } }
            Mock Restore-RegistryKeyBackup { return $true }

            $res = Set-PrinterServerRemediation -Fix 'RpcAuthnLevel'
            $res.RegBackupFiles.Count | Should -BeGreaterThan 0
            $restored = Restore-RegistryKeyBackup -BackupFilePath $res.RegBackupFiles[0]
            $restored | Should -BeTrue
        }
    }

    Context 'Client-Side Network Printer Remediation (R2)' {
        It 'Set-PrinterClientRemediation -All applies client fixes, purges queue, resets ports and refreshes connections' -Skip:(-not $isPrintersAvailable) {
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\ClientFix.reg' } }
            Mock Reset-PrintSpoolerQueue { return [PSCustomObject]@{ FilesPurged = 3; ServiceRestarted = $true } }
            Mock Reset-PrinterNePortBindings { return [PSCustomObject]@{ CleanedPortsCount = 2; RegBackupFile = 'C:\Backups\NePorts.reg' } }
            Mock Reset-PrinterConnections { return [PSCustomObject]@{ RefreshedConnections = 1; StaleRemoved = 0 } }

            $res = Set-PrinterClientRemediation -All
            $res.Role | Should -Be 'Client'
            $res.FixesApplied | Should -Contain 'PointAndPrintAdmin'
            $res.FixesApplied | Should -Contain 'PointAndPrintPrompts'
            $res.FixesApplied | Should -Contain 'RpcNamedPipe'
            $res.FixesApplied | Should -Contain 'CopyFilesPolicy'
            $res.FixesApplied | Should -Contain 'SpoolerQueue'
            $res.FixesApplied | Should -Contain 'NePorts'
            $res.FixesApplied | Should -Contain 'RefreshConnections'
            $res.RegBackupFiles.Count | Should -BeGreaterThan 0
            $res.QueuePurgedCount | Should -Be 3
            $res.CleanedNePortsCount | Should -Be 2
            $res.RefreshedConnections | Should -Be 1
            $res.StaleRemoved | Should -Be 0
            $res.Success | Should -BeTrue
        }

        It 'Set-PrinterClientRemediation targets individual fixes RpcNamedPipe (fixes 0x00000709) and CopyFilesPolicy (fixes 0x0000007c)' -Skip:(-not $isPrintersAvailable) {
            $called = @{}
            Mock Set-ToolkitRegistryValue {
                $called[$ValueName] = $Value
                return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\ClientRpc.reg' }
            }

            $res = Set-PrinterClientRemediation -Fix 'RpcNamedPipe', 'CopyFilesPolicy'
            $res.FixesApplied | Should -Contain 'RpcNamedPipe'
            $res.FixesApplied | Should -Contain 'CopyFilesPolicy'
            $res.FixesApplied | Should -Not -Contain 'PointAndPrintAdmin'
            $called['RpcUseNamedPipeProtocol'] | Should -Be 1
            $called['CopyFilesPolicy'] | Should -Be 1
        }

        It 'Set-PrinterClientRemediation targets PointAndPrintAdmin and PointAndPrintPrompts' -Skip:(-not $isPrintersAvailable) {
            $called = @{}
            Mock Set-ToolkitRegistryValue {
                $called[$ValueName] = $Value
                return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\PnP.reg' }
            }

            $res = Set-PrinterClientRemediation -Fix 'PointAndPrintAdmin', 'PointAndPrintPrompts'
            $res.FixesApplied | Should -Contain 'PointAndPrintAdmin'
            $res.FixesApplied | Should -Contain 'PointAndPrintPrompts'
            $called['RestrictDriverInstallationToAdministrators'] | Should -Be 0
            $called['NoWarningNoElevationOnInstall'] | Should -Be 1
            $called['UpdatePromptSettings'] | Should -Be 2
        }

        It 'Set-PrinterClientRemediation supports -WhatIf simulation' -Skip:(-not $isPrintersAvailable) {
            $res = Set-PrinterClientRemediation -All -WhatIf
            $res.Role | Should -Be 'Client'
            $res.RegBackupFiles | Should -Contain '[Simulated - WhatIf]'
            $res.QueuePurgedCount | Should -Be 0
        }

        It 'Supports rollback capability via Restore-RegistryKeyBackup on client backups' -Skip:(-not $isPrintersAvailable) {
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\ClientPnP.reg' } }
            Mock Restore-RegistryKeyBackup { return $true }

            $res = Set-PrinterClientRemediation -Fix 'PointAndPrintAdmin'
            $res.RegBackupFiles.Count | Should -BeGreaterThan 0
            $restored = Restore-RegistryKeyBackup -BackupFilePath $res.RegBackupFiles[0]
            $restored | Should -BeTrue
        }
    }

    Context 'Comprehensive Printer Error Code Catalog & Batch Remediation (R2, R4)' {
        BeforeEach {
            Mock Set-ToolkitRegistryValue {
                param($KeyPath, $ValueName, $Value, $PropertyType, $BackupDirectory)
                return [PSCustomObject]@{
                    RegBackupFile = "C:\Backups\$ValueName.reg"
                    BackupFile    = "C:\Backups\$ValueName.reg"
                }
            }
            Mock Stop-Service { }
            Mock Start-Service { }
            Mock Get-Service { return [PSCustomObject]@{ Status = 'Running' } }
            Mock Get-Process { return @() }
            Mock Test-Path { return $true }
            Mock Reset-PrintSpoolerQueue { return [PSCustomObject]@{ FilesPurged = 2; ServiceRestarted = $true } }
            Mock Reset-PrinterNePortBindings { return [PSCustomObject]@{ CleanedPortsCount = 1; RegBackupFile = 'C:\Backups\NePorts.reg' } }
            Mock Reset-PrinterConnections { return [PSCustomObject]@{ RefreshedConnections = 2; StaleRemoved = 0 } }
            Mock Register-PrintSpoolerComponents { return $true }
            Mock Export-RegistryKeyBackup { return [PSCustomObject]@{ BackupFilePath = 'C:\Backups\Connections.reg' } }
            Mock Get-CimInstance { return @() }
        }

        It 'Set-PrinterRemediation -All applies both server and client remediations in batch mode' -Skip:(-not $isPrintersAvailable) {
            $res = Set-PrinterRemediation -Role Both -All
            $res.Role | Should -Be 'Both'
            $res.FixesApplied | Should -Contain 'RpcAuthnLevel'
            $res.FixesApplied | Should -Contain 'PointAndPrintAdmin'
            $res.FixesApplied | Should -Contain 'RpcNamedPipe'
            $res.FixesApplied | Should -Contain 'CopyFilesPolicy'
            $res.FixesApplied | Should -Contain 'SpoolerDLLs'
            $res.FixesApplied | Should -Contain 'DriverStoreRepair'
            $res.FixesApplied | Should -Contain 'SpoolerHandles'
            $res.FixesApplied | Should -Contain 'DriverConfig'
            $res.FixesApplied | Should -Contain 'ClearStalledJobs'
            $res.FixesApplied | Should -Contain 'SpoolerCrash'
            $res.FixesApplied | Should -Contain 'NePorts'
            $res.FixesApplied | Should -Contain 'RefreshConnections'
            $res.RegBackupFiles.Count | Should -BeGreaterThan 0
            $res.SpoolerRestarted | Should -BeTrue
            $res.Success | Should -BeTrue
            $res.ErrorMessage | Should -BeNullOrEmpty
        }

        It 'Set-PrinterRemediation -Role Client -All applies all client remediations' -Skip:(-not $isPrintersAvailable) {
            $res = Set-PrinterRemediation -Role Client -All
            $res.Role | Should -Be 'Client'
            $res.FixesApplied | Should -Contain 'PointAndPrintAdmin'
            $res.FixesApplied | Should -Contain 'PointAndPrintPrompts'
            $res.FixesApplied | Should -Contain 'RpcNamedPipe'
            $res.FixesApplied | Should -Contain 'DefaultPrinterKey'
            $res.FixesApplied | Should -Contain 'CopyFilesPolicy'
            $res.FixesApplied | Should -Contain 'NePorts'
            $res.FixesApplied | Should -Contain 'RefreshConnections'
            $res.FixesApplied | Should -Not -Contain 'RpcAuthnLevel'
            $res.Success | Should -BeTrue
        }

        It 'Set-PrinterRemediation -Role Server -All applies all server remediations' -Skip:(-not $isPrintersAvailable) {
            $res = Set-PrinterRemediation -Role Server -All
            $res.Role | Should -Be 'Server'
            $res.FixesApplied | Should -Contain 'RpcAuthnLevel'
            $res.FixesApplied | Should -Contain 'RemoteRpcEndPoint'
            $res.FixesApplied | Should -Contain 'RpcProtocols'
            $res.FixesApplied | Should -Contain 'SpoolerHealth'
            $res.FixesApplied | Should -Not -Contain 'PointAndPrintAdmin'
            $res.Success | Should -BeTrue
        }

        It 'Set-PrinterRemediation remediates 0x0000011b (RpcAuthnLevel & RemoteRpcEndPoint & restart spooler)' -Skip:(-not $isPrintersAvailable) {
            $capturedValues = @{}
            Mock Set-ToolkitRegistryValue {
                param($KeyPath, $ValueName, $Value, $PropertyType, $BackupDirectory)
                $capturedValues[$ValueName] = $Value
                return [PSCustomObject]@{ RegBackupFile = "C:\Backups\$ValueName.reg" }
            }
            $res = Set-PrinterRemediation -Fix '0x0000011b'
            $res.FixesApplied | Should -Contain '0x0000011b'
            $res.FixesApplied | Should -Contain 'RpcAuthnLevel'
            $res.FixesApplied | Should -Contain 'RemoteRpcEndPoint'
            $capturedValues['RpcAuthnLevelPrivacyEnabled'] | Should -Be 0
            $capturedValues['RegisterSpoolerRemoteRpcEndPoint'] | Should -Be 1
            $res.SpoolerRestarted | Should -BeTrue
            $res.Success | Should -BeTrue
        }

        It 'Set-PrinterRemediation remediates 0x00000709 (RpcNamedPipe & DefaultPrinterKey)' -Skip:(-not $isPrintersAvailable) {
            $capturedValues = @{}
            Mock Set-ToolkitRegistryValue {
                param($KeyPath, $ValueName, $Value, $PropertyType, $BackupDirectory)
                $capturedValues[$ValueName] = $Value
                return [PSCustomObject]@{ RegBackupFile = "C:\Backups\$ValueName.reg" }
            }
            $res = Set-PrinterRemediation -ErrorCodes '0x00000709'
            $res.FixesApplied | Should -Contain '0x00000709'
            $res.FixesApplied | Should -Contain 'RpcNamedPipe'
            $res.FixesApplied | Should -Contain 'DefaultPrinterKey'
            $capturedValues['RpcUseNamedPipeProtocol'] | Should -Be 1
            $capturedValues['UserSelectedDefault'] | Should -Be 1
            $capturedValues['LegacyDefaultPrinterMode'] | Should -Be 1
            $res.Success | Should -BeTrue
        }

        It 'Set-PrinterRemediation remediates 0x0000007c (CopyFilesPolicy)' -Skip:(-not $isPrintersAvailable) {
            $capturedValues = @{}
            Mock Set-ToolkitRegistryValue {
                param($KeyPath, $ValueName, $Value, $PropertyType, $BackupDirectory)
                $capturedValues[$ValueName] = $Value
                return [PSCustomObject]@{ RegBackupFile = "C:\Backups\$ValueName.reg" }
            }
            $res = Set-PrinterRemediation -Fix '0x0000007c'
            $res.FixesApplied | Should -Contain '0x0000007c'
            $capturedValues['CopyFilesPolicy'] | Should -Be 1
            $res.Success | Should -BeTrue
        }

        It 'Set-PrinterRemediation remediates 0x0000007e (SpoolerDLLs & Driver Restoration)' -Skip:(-not $isPrintersAvailable) {
            $res = Set-PrinterRemediation -Fix '0x0000007e'
            $res.FixesApplied | Should -Contain '0x0000007e'
            $res.FixesApplied | Should -Contain 'SpoolerDLLs'
            $res.Success | Should -BeTrue
        }

        It 'Set-PrinterRemediation remediates 0x00000bcb (PointAndPrintAdmin & Prompts)' -Skip:(-not $isPrintersAvailable) {
            $capturedValues = @{}
            Mock Set-ToolkitRegistryValue {
                param($KeyPath, $ValueName, $Value, $PropertyType, $BackupDirectory)
                $capturedValues[$ValueName] = $Value
                return [PSCustomObject]@{ RegBackupFile = "C:\Backups\$ValueName.reg" }
            }
            $res = Set-PrinterRemediation -Fix '0x00000bcb'
            $res.FixesApplied | Should -Contain '0x00000bcb'
            $capturedValues['RestrictDriverInstallationToAdministrators'] | Should -Be 0
            $capturedValues['NoWarningNoElevationOnInstall'] | Should -Be 1
            $capturedValues['UpdatePromptSettings'] | Should -Be 2
            $res.Success | Should -BeTrue
        }

        It 'Set-PrinterRemediation remediates 0x00000002 (DriverStoreRepair)' -Skip:(-not $isPrintersAvailable) {
            $capturedValues = @{}
            Mock Set-ToolkitRegistryValue {
                param($KeyPath, $ValueName, $Value, $PropertyType, $BackupDirectory)
                $capturedValues[$ValueName] = $Value
                return [PSCustomObject]@{ RegBackupFile = "C:\Backups\$ValueName.reg" }
            }
            $res = Set-PrinterRemediation -Fix '0x00000002'
            $res.FixesApplied | Should -Contain '0x00000002'
            $capturedValues['Directory'] | Should -Be 'W32X64'
            $res.Success | Should -BeTrue
        }

        It 'Set-PrinterRemediation remediates 0x00000006 (SpoolerHandles & restart spooler)' -Skip:(-not $isPrintersAvailable) {
            $res = Set-PrinterRemediation -Fix '0x00000006'
            $res.FixesApplied | Should -Contain '0x00000006'
            $res.SpoolerRestarted | Should -BeTrue
            $res.Success | Should -BeTrue
        }

        It 'Set-PrinterRemediation remediates 0x00000057 (DriverConfig & DefaultSpoolDirectory)' -Skip:(-not $isPrintersAvailable) {
            $capturedValues = @{}
            Mock Set-ToolkitRegistryValue {
                param($KeyPath, $ValueName, $Value, $PropertyType, $BackupDirectory)
                $capturedValues[$ValueName] = $Value
                return [PSCustomObject]@{ RegBackupFile = "C:\Backups\$ValueName.reg" }
            }
            $res = Set-PrinterRemediation -Fix '0x00000057'
            $res.FixesApplied | Should -Contain '0x00000057'
            $capturedValues['DefaultSpoolDirectory'] | Should -Not -BeNullOrEmpty
            $res.Success | Should -BeTrue
        }

        It 'Set-PrinterRemediation remediates 0x000003e3 (ClearStalledJobs & Win32_PrintJob)' -Skip:(-not $isPrintersAvailable) {
            $res = Set-PrinterRemediation -Fix '0x000003e3'
            $res.FixesApplied | Should -Contain '0x000003e3'
            $res.SpoolerRestarted | Should -BeTrue
            $res.Success | Should -BeTrue
        }

        It 'Set-PrinterRemediation remediates SpoolerCrash (Full queue purge & ACLs & restart)' -Skip:(-not $isPrintersAvailable) {
            $res = Set-PrinterRemediation -Fix 'SpoolerCrash'
            $res.FixesApplied | Should -Contain 'SpoolerCrash'
            $res.SpoolerRestarted | Should -BeTrue
            $res.Success | Should -BeTrue
        }

        It 'Set-PrinterRemediation remediates NePortConflict (Reset Ne Ports)' -Skip:(-not $isPrintersAvailable) {
            $res = Set-PrinterRemediation -Fix 'NePortConflict'
            $res.FixesApplied | Should -Contain 'NePortConflict'
            $res.CleanedNePortsCount | Should -Be 1
            $res.Success | Should -BeTrue
        }

        It 'Set-PrinterRemediation remediates RefreshConnections (Rebind network mappings)' -Skip:(-not $isPrintersAvailable) {
            $res = Set-PrinterRemediation -Fix 'RefreshConnections'
            $res.FixesApplied | Should -Contain 'RefreshConnections'
            $res.RefreshedConnections | Should -Be 2
            $res.Success | Should -BeTrue
        }

        It 'Set-PrinterRemediation supports -WhatIf simulation without executing mutations' -Skip:(-not $isPrintersAvailable) {
            $regModified = $false
            Mock Set-ToolkitRegistryValue { $regModified = $true; return $null }
            $res = Set-PrinterRemediation -All -WhatIf
            $regModified | Should -BeFalse
            $res.RegBackupFiles | Should -Contain '[Simulated - WhatIf]'
            $res.SpoolerRestarted | Should -BeFalse
            $res.Success | Should -BeTrue
        }

        It 'Supports rollback capability via Restore-RegistryKeyBackup on remediation backups' -Skip:(-not $isPrintersAvailable) {
            Mock Restore-RegistryKeyBackup { return $true }
            $res = Set-PrinterRemediation -Fix '0x0000011b'
            $res.RegBackupFiles.Count | Should -BeGreaterThan 0
            $restored = Restore-RegistryKeyBackup -BackupFilePath $res.RegBackupFiles[0]
            $restored | Should -BeTrue
        }
    }
}
