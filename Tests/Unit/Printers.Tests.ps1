# ==============================================================================
# Printers.Tests.ps1
# Unit test suite for Modules/Printers
# Covers: Get-PrintSpoolerStatus, Reset-PrintSpoolerQueue,
# Register-PrintSpoolerComponents, Reset-PrinterNePortBindings,
# Test-PointAndPrintPolicy, Set-PointAndPrintRemediation,
# Test-NetworkPrinterConnectivity, Reset-PrinterConnections.
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
}
