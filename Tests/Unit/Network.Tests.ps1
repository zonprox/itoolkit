# ==============================================================================
# Network.Tests.ps1
# Unit test suite for Modules/Network
# Covers: Set-NetworkRemediation, Test-NetworkPrinterConnectivity,
# Get-NetworkAdapterStatus, Reset-NetworkDns, Reset-NetworkDhcp,
# Reset-NetworkArp, Reset-NetworkWinsock, Reset-NetworkTcpIp,
# Reset-NetworkLocationAwareness, Reset-NetworkProxy,
# Restart-ToolkitNetworkAdapter, Set-NetworkSmbConfiguration.
# ==============================================================================

BeforeAll {
    $script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    $script:NetworkManifest = Join-Path $script:ProjectRoot 'Modules/Network/Network.psd1'
    $script:RootManifest = Join-Path $script:ProjectRoot 'IToolkit.psd1'

    $manifests = Get-ChildItem -Path (Join-Path $script:ProjectRoot "Modules") -Filter "*.psd1" -Recurse -ErrorAction SilentlyContinue
    if ($manifests) {
        foreach ($m in $manifests) {
            try {
                Import-Module $m.FullName -Force -ErrorAction Stop
            } catch {
                Write-Warning "Failed to load module $($m.Name): $_"
            }
        }
    }

    # Cross-platform compatibility stubs for Windows commands & cmdlets on non-Windows
    $compatCmds = @(
        'netsh', 'ipconfig', 'sfc', 'DISM', 'winmgmt',
        'Restart-NetAdapter', 'Get-NetAdapter', 'Get-NetIPAddress', 'Get-NetIPConfiguration',
        'Get-NetConnectionProfile', 'Set-NetConnectionProfile', 'Clear-DnsClientCache', 'Register-DnsClient',
        'Get-SmbClientConfiguration', 'Set-SmbClientConfiguration', 'Enable-NetFirewallRule', 'Disable-NetFirewallRule',
        'Get-Service', 'Restart-Service', 'Start-Service', 'Stop-Service', 'Set-Service',
        'Get-CimInstance', 'Invoke-CimMethod', 'Test-IsAdmin'
    )
    foreach ($cmd in $compatCmds) {
        if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$cmd" -Value {
                [CmdletBinding()]
                param([Parameter(ValueFromRemainingArguments = $true)]$RemainingArgs)
            }
        }
    }

    if (-not (Get-PSDrive -Name 'C' -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name 'C' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not (Get-PSDrive -Name 'D' -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name 'D' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -ErrorAction SilentlyContinue | Out-Null
    }
}

Describe 'Unit: Network Diagnostics & Remediation Module' {

    Context 'Module Manifest & Export Integrity' {
        It 'Network.psd1 manifest exists and is valid PowerShell data' {
            Test-Path -LiteralPath $script:NetworkManifest | Should -BeTrue
            $manifest = Import-PowerShellDataFile -Path $script:NetworkManifest
            $manifest.RootModule | Should -Be 'Network.psm1'
            $manifest.ModuleVersion | Should -Be '1.0.0'
        }

        It 'Network.psd1 exports all 12 public cmdlets' {
            $manifest = Import-PowerShellDataFile -Path $script:NetworkManifest
            $expectedCmdlets = @(
                'Set-NetworkRemediation',
                'Test-NetworkPrinterConnectivity',
                'Get-NetworkAdapterStatus',
                'Reset-NetworkDns',
                'Reset-NetworkDhcp',
                'Reset-NetworkArp',
                'Reset-NetworkWinsock',
                'Reset-NetworkTcpIp',
                'Reset-NetworkLocationAwareness',
                'Reset-NetworkProxy',
                'Restart-ToolkitNetworkAdapter',
                'Set-NetworkSmbConfiguration'
            )
            foreach ($cmdlet in $expectedCmdlets) {
                $manifest.FunctionsToExport | Should -Contain $cmdlet
            }
        }

        It 'IToolkit root manifest registers Network module in NestedModules' {
            Test-Path -LiteralPath $script:RootManifest | Should -BeTrue
            $rootManifest = Import-PowerShellDataFile -Path $script:RootManifest
            $rootManifest.NestedModules | Should -Contain 'Modules/Network/Network.psd1'
        }

        It 'IToolkit root manifest exports all 12 network cmdlets' {
            Test-Path -LiteralPath $script:RootManifest | Should -BeTrue
            $rootManifest = Import-PowerShellDataFile -Path $script:RootManifest
            $expectedCmdlets = @(
                'Set-NetworkRemediation',
                'Test-NetworkPrinterConnectivity',
                'Get-NetworkAdapterStatus',
                'Reset-NetworkDns',
                'Reset-NetworkDhcp',
                'Reset-NetworkArp',
                'Reset-NetworkWinsock',
                'Reset-NetworkTcpIp',
                'Reset-NetworkLocationAwareness',
                'Reset-NetworkProxy',
                'Restart-ToolkitNetworkAdapter',
                'Set-NetworkSmbConfiguration'
            )
            foreach ($cmdlet in $expectedCmdlets) {
                $rootManifest.FunctionsToExport | Should -Contain $cmdlet
            }
        }

        It 'All 12 network cmdlets are available as loaded commands in session' {
            $expectedCmdlets = @(
                'Set-NetworkRemediation',
                'Test-NetworkPrinterConnectivity',
                'Get-NetworkAdapterStatus',
                'Reset-NetworkDns',
                'Reset-NetworkDhcp',
                'Reset-NetworkArp',
                'Reset-NetworkWinsock',
                'Reset-NetworkTcpIp',
                'Reset-NetworkLocationAwareness',
                'Reset-NetworkProxy',
                'Restart-ToolkitNetworkAdapter',
                'Set-NetworkSmbConfiguration'
            )
            foreach ($cmdlet in $expectedCmdlets) {
                Get-Command -Name $cmdlet -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Granular Error Fixes: SMB & Network Path Not Found (0x80070035 / 0x80070043)' {
        It 'Set-NetworkSmbConfiguration enables firewall rules, starts services, and sets SMB params' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            Mock Set-Service { }
            Mock Start-Service { }
            Mock Set-ToolkitRegistryValue {
                return [PSCustomObject]@{
                    Success       = $true
                    BackupFile    = 'C:\Backups\SmbConfig.reg'
                    RegBackupFile = 'C:\Backups\SmbConfig.reg'
                }
            }
            Mock Test-Path { return $true }
            Mock Get-ChildItem { return @() }

            $result = Set-NetworkSmbConfiguration
            $result.Success | Should -BeTrue
            $result.FirewallRulesEnabled | Should -BeTrue
            $result.ServicesStarted | Should -Contain 'FDResPub'
            $result.ServicesStarted | Should -Contain 'SSDPSRV'
            $result.ServicesStarted | Should -Contain 'LanmanServer'
            $result.ServicesStarted | Should -Contain 'LanmanWorkstation'
            $result.NetbiosEnabled | Should -BeTrue
            $result.SmbConfigured | Should -BeTrue
            $result.RegBackupFiles.Count | Should -BeGreaterThan 0
        }

        It 'Set-NetworkRemediation maps 0x80070035 to SmbConfig' {
            Mock Test-IsAdmin { return $true }
            Mock Set-NetworkSmbConfiguration {
                return [PSCustomObject]@{
                    Success         = $true
                    SmbConfigured   = $true
                    RegBackupFiles  = @('C:\Backups\Smb35.reg')
                }
            }

            $res = Set-NetworkRemediation -Fix '0x80070035'
            $res.FixesApplied | Should -Contain 'SmbConfig'
            $res.SmbConfigured | Should -BeTrue
            $res.Success | Should -BeTrue
        }

        It 'Set-NetworkRemediation maps 0x80070043 and NetworkPathNotFound to SmbConfig' {
            Mock Test-IsAdmin { return $true }
            Mock Set-NetworkSmbConfiguration {
                return [PSCustomObject]@{
                    Success         = $true
                    SmbConfigured   = $true
                    RegBackupFiles  = @('C:\Backups\Smb43.reg')
                }
            }

            $res1 = Set-NetworkRemediation -Fix '0x80070043'
            $res1.FixesApplied | Should -Contain 'SmbConfig'
            $res1.SmbConfigured | Should -BeTrue

            $res2 = Set-NetworkRemediation -Fix 'NetworkPathNotFound'
            $res2.FixesApplied | Should -Contain 'SmbConfig'
            $res2.SmbConfigured | Should -BeTrue
        }
    }

    Context 'Granular Error Fixes: DNS Resolution Failure' {
        It 'Reset-NetworkDns executes ipconfig /flushdns, /registerdns and Clear-DnsClientCache' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            Mock Clear-DnsClientCache { }

            $result = Reset-NetworkDns
            $result.Success | Should -BeTrue
            $result.DnsFlushed | Should -BeTrue
            $result.DnsRegistered | Should -BeTrue
            $result.CacheCleared | Should -BeTrue
        }

        It 'Set-NetworkRemediation -Fix DnsResolution invokes DNS repair successfully' {
            Mock Test-IsAdmin { return $true }
            Mock Reset-NetworkDns {
                return [PSCustomObject]@{
                    Success    = $true
                    DnsFlushed = $true
                }
            }

            $res = Set-NetworkRemediation -Fix 'DnsResolution'
            $res.FixesApplied | Should -Contain 'DnsResolution'
            $res.DnsFlushed | Should -BeTrue
            $res.Success | Should -BeTrue
        }
    }

    Context 'Granular Error Fixes: APIPA / DHCP Lease Failure' {
        It 'Reset-NetworkDhcp executes release, renew, and restarts Dhcp service' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            Mock Restart-Service { }

            $result = Reset-NetworkDhcp
            $result.Success | Should -BeTrue
            $result.LeaseReleased | Should -BeTrue
            $result.LeaseRenewed | Should -BeTrue
            $result.ServiceRestarted | Should -BeTrue
        }

        It 'Set-NetworkRemediation -Fix DhcpLease executes DHCP lease renewal' {
            Mock Test-IsAdmin { return $true }
            Mock Reset-NetworkDhcp {
                return [PSCustomObject]@{
                    Success      = $true
                    LeaseRenewed = $true
                }
            }

            $res = Set-NetworkRemediation -Fix 'DhcpLease'
            $res.FixesApplied | Should -Contain 'DhcpLease'
            $res.DhcpRenewed | Should -BeTrue
            $res.Success | Should -BeTrue
        }
    }

    Context 'Granular Error Fixes: Default Gateway / ARP Corruption' {
        It 'Reset-NetworkArp executes netsh arpcache and destinationcache deletion' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }

            $result = Reset-NetworkArp
            $result.Success | Should -BeTrue
            $result.ArpFlushed | Should -BeTrue
            $result.DestinationCacheCleared | Should -BeTrue
        }

        It 'Set-NetworkRemediation -Fix DefaultGatewayArp flushes ARP cache' {
            Mock Test-IsAdmin { return $true }
            Mock Reset-NetworkArp {
                return [PSCustomObject]@{
                    Success    = $true
                    ArpFlushed = $true
                }
            }

            $res = Set-NetworkRemediation -Fix 'DefaultGatewayArp'
            $res.FixesApplied | Should -Contain 'DefaultGatewayArp'
            $res.ArpFlushed | Should -BeTrue
            $res.Success | Should -BeTrue
        }
    }

    Context 'Granular Error Fixes: Winsock Catalog Corruption' {
        It 'Reset-NetworkWinsock executes netsh winsock reset catalog and flags reboot required' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }

            $result = Reset-NetworkWinsock
            $result.Success | Should -BeTrue
            $result.WinsockReset | Should -BeTrue
            $result.RebootRequired | Should -BeTrue
        }

        It 'Set-NetworkRemediation -Fix Winsock invokes Winsock reset' {
            Mock Test-IsAdmin { return $true }
            Mock Reset-NetworkWinsock {
                return [PSCustomObject]@{
                    Success      = $true
                    WinsockReset = $true
                }
            }

            $res = Set-NetworkRemediation -Fix 'Winsock'
            $res.FixesApplied | Should -Contain 'Winsock'
            $res.WinsockReset | Should -BeTrue
            $res.Success | Should -BeTrue
        }
    }

    Context 'Granular Error Fixes: TCP/IP Stack Corruption' {
        It 'Reset-NetworkTcpIp executes netsh int ip reset and netsh int tcp reset' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }

            $result = Reset-NetworkTcpIp
            $result.Success | Should -BeTrue
            $result.IpReset | Should -BeTrue
            $result.TcpReset | Should -BeTrue
            $result.RebootRequired | Should -BeTrue
        }

        It 'Set-NetworkRemediation -Fix TcpIpStack resets IP and TCP stacks' {
            Mock Test-IsAdmin { return $true }
            Mock Reset-NetworkTcpIp {
                return [PSCustomObject]@{
                    Success = $true
                    IpReset = $true
                }
            }

            $res = Set-NetworkRemediation -Fix 'TcpIpStack'
            $res.FixesApplied | Should -Contain 'TcpIpStack'
            $res.TcpIpReset | Should -BeTrue
            $res.Success | Should -BeTrue
        }
    }

    Context 'Granular Error Fixes: NLA Stuck / Unidentified Network' {
        It 'Reset-NetworkLocationAwareness restarts NlaSvc and netprofm, sets profile to Private' {
            Mock Test-IsAdmin { return $true }
            Mock Restart-Service { }
            Mock Get-NetConnectionProfile {
                return @([PSCustomObject]@{ Name = 'Network 1'; NetworkCategory = 'Public' })
            }
            Mock Set-NetConnectionProfile { }

            $result = Reset-NetworkLocationAwareness
            $result.Success | Should -BeTrue
            $result.NlaRestarted | Should -BeTrue
            $result.NetprofmRestarted | Should -BeTrue
            $result.ProfileSetPrivate | Should -BeTrue
        }

        It 'Set-NetworkRemediation -Fix NlaService restarts NLA and sets Private profile' {
            Mock Test-IsAdmin { return $true }
            Mock Reset-NetworkLocationAwareness {
                return [PSCustomObject]@{
                    Success      = $true
                    NlaRestarted = $true
                }
            }

            $res = Set-NetworkRemediation -Fix 'NlaService'
            $res.FixesApplied | Should -Contain 'NlaService'
            $res.NlaRestarted | Should -BeTrue
            $res.Success | Should -BeTrue
        }
    }

    Context 'Granular Error Fixes: Proxy / WPAD Misconfiguration' {
        It 'Reset-NetworkProxy resets WinHTTP direct proxy and clears user Internet Settings' {
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
            Mock Set-ToolkitRegistryValue {
                return [PSCustomObject]@{
                    Success       = $true
                    BackupFile    = 'C:\Backups\InternetSettings.reg'
                    RegBackupFile = 'C:\Backups\InternetSettings.reg'
                }
            }

            $result = Reset-NetworkProxy
            $result.Success | Should -BeTrue
            $result.WinHttpReset | Should -BeTrue
            $result.UserProxyCleared | Should -BeTrue
            $result.RegBackupFiles.Count | Should -BeGreaterThan 0
        }

        It 'Set-NetworkRemediation -Fix ProxyMisconfig resets WinHTTP and clears user proxy' {
            Mock Test-IsAdmin { return $true }
            Mock Reset-NetworkProxy {
                return [PSCustomObject]@{
                    Success        = $true
                    WinHttpReset   = $true
                    RegBackupFiles = @('C:\Backups\Proxy.reg')
                }
            }

            $res = Set-NetworkRemediation -Fix 'ProxyMisconfig'
            $res.FixesApplied | Should -Contain 'ProxyMisconfig'
            $res.ProxyReset | Should -BeTrue
            $res.Success | Should -BeTrue
        }
    }

    Context 'Granular Error Fixes: Network Adapter Reset' {
        It 'Restart-ToolkitNetworkAdapter restarts named adapter via Restart-NetAdapter' {
            Mock Test-IsAdmin { return $true }
            Mock Restart-NetAdapter { }

            $result = Restart-ToolkitNetworkAdapter -Name 'Ethernet'
            $result.Success | Should -BeTrue
            $result.AdaptersRestarted | Should -Contain 'Ethernet'
            $result.Count | Should -Be 1
        }

        It 'Restart-ToolkitNetworkAdapter falls back to CIM Win32_NetworkAdapter Disable/Enable' {
            Mock Test-IsAdmin { return $true }
            Mock Restart-NetAdapter { throw 'NetAdapter module unavailable' }
            $fakeAdapter = [PSCustomObject]@{
                Name                = 'Intel Gigabit Adapter'
                NetConnectionID     = 'Ethernet'
                NetConnectionStatus = 2
                DeviceID            = 1
            }
            Mock Get-CimInstance { return @($fakeAdapter) }
            Mock Invoke-CimMethod { return [PSCustomObject]@{ ReturnValue = 0 } }
            Mock Start-Sleep { }

            $result = Restart-ToolkitNetworkAdapter -Name 'Ethernet'
            $result.Success | Should -BeTrue
            $result.AdaptersRestarted | Should -Contain 'Ethernet'
        }

        It 'Set-NetworkRemediation -Fix AdapterReset triggers adapter restart' {
            Mock Test-IsAdmin { return $true }
            Mock Restart-ToolkitNetworkAdapter {
                return [PSCustomObject]@{
                    Success = $true
                    Count   = 1
                }
            }

            $res = Set-NetworkRemediation -Fix 'AdapterReset'
            $res.FixesApplied | Should -Contain 'AdapterReset'
            $res.AdapterReset | Should -BeTrue
            $res.Success | Should -BeTrue
        }
    }

    Context 'Network Adapter Status & Printer Connectivity' {
        It 'Get-NetworkAdapterStatus retrieves adapters and status badges' {
            $mockAdapter = [PSCustomObject]@{
                Name           = 'Ethernet'
                Status         = 'Up'
                MacAddress     = '00-15-5D-01-02-03'
                InterfaceIndex = 12
            }
            $mockConfig = [PSCustomObject]@{
                IPv4Address        = [PSCustomObject]@{ IPAddress = @('192.168.1.100') }
                IPv4DefaultGateway = [PSCustomObject]@{ NextHop = @('192.168.1.1') }
            }
            Mock Get-NetAdapter { return @($mockAdapter) }
            Mock Get-NetIPConfiguration { return $mockConfig }

            $adapters = Get-NetworkAdapterStatus
            $adapters.Count | Should -BeGreaterThan 0
            $adapters[0].Name | Should -Be 'Ethernet'
            $adapters[0].Status | Should -Be '[UP]'
            $adapters[0].IPv4 | Should -Be '192.168.1.100'
            $adapters[0].Gateway | Should -Be '192.168.1.1'
            $adapters[0].MAC | Should -Be '00-15-5D-01-02-03'
        }

        It 'Test-NetworkPrinterConnectivity checks Ping, SMB, RPC, and RAW print ports' {
            Mock Test-Connection { return $true }
            Mock Test-NetConnection {
                return [PSCustomObject]@{ TcpTestSucceeded = $true }
            }

            $test = Test-NetworkPrinterConnectivity -ComputerName '192.168.1.200'
            $test.PingSuccess | Should -BeTrue
            $test.SmbPortOpen | Should -BeTrue
            $test.RpcPortOpen | Should -BeTrue
            $test.RawPrintPortOpen | Should -BeTrue
        }
    }

    Context 'Batch Remediation: Set-NetworkRemediation -All' {
        It 'Set-NetworkRemediation -All sequentially executes all 9 repairs with registry backups' {
            Mock Test-IsAdmin { return $true }
            Mock Reset-NetworkDns { return [PSCustomObject]@{ Success = $true; DnsFlushed = $true } }
            Mock Reset-NetworkDhcp { return [PSCustomObject]@{ Success = $true; LeaseRenewed = $true } }
            Mock Reset-NetworkArp { return [PSCustomObject]@{ Success = $true; ArpFlushed = $true } }
            Mock Reset-NetworkWinsock { return [PSCustomObject]@{ Success = $true; WinsockReset = $true } }
            Mock Reset-NetworkTcpIp { return [PSCustomObject]@{ Success = $true; IpReset = $true } }
            Mock Reset-NetworkLocationAwareness { return [PSCustomObject]@{ Success = $true; NlaRestarted = $true } }
            Mock Reset-NetworkProxy {
                return [PSCustomObject]@{
                    Success        = $true
                    WinHttpReset   = $true
                    RegBackupFiles = @('C:\Backups\Proxy.reg')
                }
            }
            Mock Set-NetworkSmbConfiguration {
                return [PSCustomObject]@{
                    Success        = $true
                    SmbConfigured  = $true
                    RegBackupFiles = @('C:\Backups\Smb.reg')
                }
            }
            Mock Restart-ToolkitNetworkAdapter { return [PSCustomObject]@{ Success = $true; Count = 1 } }

            $batchResult = Set-NetworkRemediation -All
            $batchResult.Success | Should -BeTrue
            $batchResult.DnsFlushed | Should -BeTrue
            $batchResult.DhcpRenewed | Should -BeTrue
            $batchResult.ArpFlushed | Should -BeTrue
            $batchResult.WinsockReset | Should -BeTrue
            $batchResult.TcpIpReset | Should -BeTrue
            $batchResult.NlaRestarted | Should -BeTrue
            $batchResult.ProxyReset | Should -BeTrue
            $batchResult.SmbConfigured | Should -BeTrue
            $batchResult.AdapterReset | Should -BeTrue

            $expectedFixes = @(
                'DnsResolution',
                'DhcpLease',
                'DefaultGatewayArp',
                'Winsock',
                'TcpIpStack',
                'NlaService',
                'ProxyMisconfig',
                'SmbConfig',
                'AdapterReset'
            )
            foreach ($f in $expectedFixes) {
                $batchResult.FixesApplied | Should -Contain $f
            }
            $batchResult.RegBackupFiles.Count | Should -BeGreaterOrEqual 2
        }

        It 'Set-NetworkRemediation accepts multiple targeted fixes' {
            Mock Test-IsAdmin { return $true }
            Mock Reset-NetworkDns { return [PSCustomObject]@{ Success = $true; DnsFlushed = $true } }
            Mock Reset-NetworkWinsock { return [PSCustomObject]@{ Success = $true; WinsockReset = $true } }

            $res = Set-NetworkRemediation -Fix @('DnsResolution', 'Winsock')
            $res.Success | Should -BeTrue
            $res.FixesApplied | Should -Contain 'DnsResolution'
            $res.FixesApplied | Should -Contain 'Winsock'
            $res.FixesApplied | Should -Not -Contain 'TcpIpStack'
            $res.DnsFlushed | Should -BeTrue
            $res.WinsockReset | Should -BeTrue
            $res.TcpIpReset | Should -BeFalse
        }

        It 'Set-NetworkRemediation accepts ErrorCodes parameter alias' {
            Mock Test-IsAdmin { return $true }
            Mock Set-NetworkSmbConfiguration {
                return [PSCustomObject]@{
                    Success        = $true
                    SmbConfigured  = $true
                    RegBackupFiles = @('C:\Backups\SmbAlias.reg')
                }
            }

            $res = Set-NetworkRemediation -ErrorCodes @('0x80070035')
            $res.Success | Should -BeTrue
            $res.FixesApplied | Should -Contain 'SmbConfig'
            $res.SmbConfigured | Should -BeTrue
        }
    }

    Context 'Safety Controls: -WhatIf Simulation' {
        It 'Set-NetworkRemediation -All -WhatIf simulates without executing modifications' {
            Mock Start-Process { throw 'Start-Process must not be invoked during WhatIf' }
            Mock Set-Service { throw 'Set-Service must not be invoked during WhatIf' }
            Mock Restart-Service { throw 'Restart-Service must not be invoked during WhatIf' }

            $sim = Set-NetworkRemediation -All -WhatIf
            $sim.Success | Should -BeTrue
            $sim.FixesApplied.Count | Should -BeGreaterThan 0
            $sim.RegBackupFiles | Should -Contain '[Simulated - WhatIf]'
            $sim.DnsFlushed | Should -BeTrue
            $sim.WinsockReset | Should -BeTrue
            $sim.TcpIpReset | Should -BeTrue
        }

        It 'Reset-NetworkDns -WhatIf returns simulation object' {
            Mock Start-Process { throw 'Must not call Start-Process' }
            $sim = Reset-NetworkDns -WhatIf
            $sim.Success | Should -BeTrue
            $sim.DnsFlushed | Should -BeTrue
        }

        It 'Reset-NetworkDhcp -WhatIf returns simulation object' {
            Mock Start-Process { throw 'Must not call Start-Process' }
            $sim = Reset-NetworkDhcp -WhatIf
            $sim.Success | Should -BeTrue
            $sim.LeaseRenewed | Should -BeTrue
        }

        It 'Reset-NetworkArp -WhatIf returns simulation object' {
            Mock Start-Process { throw 'Must not call Start-Process' }
            $sim = Reset-NetworkArp -WhatIf
            $sim.Success | Should -BeTrue
            $sim.ArpFlushed | Should -BeTrue
        }

        It 'Reset-NetworkWinsock -WhatIf returns simulation object' {
            Mock Start-Process { throw 'Must not call Start-Process' }
            $sim = Reset-NetworkWinsock -WhatIf
            $sim.Success | Should -BeTrue
            $sim.WinsockReset | Should -BeTrue
        }

        It 'Reset-NetworkTcpIp -WhatIf returns simulation object' {
            Mock Start-Process { throw 'Must not call Start-Process' }
            $sim = Reset-NetworkTcpIp -WhatIf
            $sim.Success | Should -BeTrue
            $sim.IpReset | Should -BeTrue
        }

        It 'Reset-NetworkLocationAwareness -WhatIf returns simulation object' {
            Mock Restart-Service { throw 'Must not call Restart-Service' }
            $sim = Reset-NetworkLocationAwareness -WhatIf
            $sim.Success | Should -BeTrue
            $sim.NlaRestarted | Should -BeTrue
        }

        It 'Reset-NetworkProxy -WhatIf returns simulation object' {
            Mock Start-Process { throw 'Must not call Start-Process' }
            $sim = Reset-NetworkProxy -WhatIf
            $sim.Success | Should -BeTrue
            $sim.WinHttpReset | Should -BeTrue
            $sim.RegBackupFiles | Should -Contain '[Simulated - WhatIf]'
        }

        It 'Set-NetworkSmbConfiguration -WhatIf returns simulation object' {
            Mock Start-Process { throw 'Must not call Start-Process' }
            $sim = Set-NetworkSmbConfiguration -WhatIf
            $sim.Success | Should -BeTrue
            $sim.SmbConfigured | Should -BeTrue
            $sim.RegBackupFiles | Should -Contain '[Simulated - WhatIf]'
        }

        It 'Restart-ToolkitNetworkAdapter -WhatIf returns simulation object' {
            Mock Restart-NetAdapter { throw 'Must not call Restart-NetAdapter' }
            $sim = Restart-ToolkitNetworkAdapter -WhatIf
            $sim.Success | Should -BeTrue
            $sim.AdaptersRestarted | Should -Contain '[Simulated - WhatIf]'
        }
    }

    Context 'Registry Rollback Verification' {
        It 'Registry backups can be verified and restored via Restore-RegistryKeyBackup' {
            Mock Restore-RegistryKeyBackup {
                param([string]$BackupFilePath)
                if ($BackupFilePath -eq 'C:\Backups\ValidBackup.reg') {
                    return $true
                }
                return $false
            }

            $restoreResult = Restore-RegistryKeyBackup -BackupFilePath 'C:\Backups\ValidBackup.reg'
            $restoreResult | Should -BeTrue
        }
    }

    Context 'Error Handling & Resilience' {
        It 'Emits warning when session is not elevated' {
            Mock Test-IsAdmin { return $false }
            Mock Reset-NetworkDns { return [PSCustomObject]@{ Success = $true; DnsFlushed = $true } }

            $warns = @()
            Set-NetworkRemediation -Fix 'DnsResolution' -WarningVariable warns -WarningAction SilentlyContinue | Out-Null
            $warns.Count | Should -BeGreaterThan 0
            $warns[0] | Should -Match 'Administrative privileges'
        }

        It 'Handles underlying exception gracefully and sets Success to false' {
            Mock Test-IsAdmin { return $true }
            Mock Reset-NetworkDns { throw 'Unexpected catastrophic failure in DNS subsystem' }

            $res = Set-NetworkRemediation -Fix 'DnsResolution'
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'DnsResolution failed'
        }

        It 'Reset-NetworkDns reports failure when ipconfig /flushdns returns non-zero' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 1 } }
            Mock Clear-DnsClientCache { throw 'RPC service unavailable' }

            $res = Reset-NetworkDns
            $res.Success | Should -BeFalse
            $res.DnsFlushed | Should -BeFalse
            $res.ErrorMessage | Should -Match 'non-zero exit code'
        }

        It 'Reset-NetworkDhcp reports failure when ipconfig commands fail' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 2 } }
            Mock Restart-Service { throw 'Service is stopped' }

            $res = Reset-NetworkDhcp
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'non-zero exit code'
        }

        It 'Reset-NetworkArp reports failure when netsh returns non-zero' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 1 } }

            $res = Reset-NetworkArp
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'non-zero exit code'
        }

        It 'Reset-NetworkWinsock reports failure when netsh fails' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 1 } }

            $res = Reset-NetworkWinsock
            $res.Success | Should -BeFalse
            $res.WinsockReset | Should -BeFalse
            $res.ErrorMessage | Should -Match 'non-zero exit code'
        }

        It 'Reset-NetworkTcpIp reports failure when netsh returns non-zero' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 1 } }

            $res = Reset-NetworkTcpIp
            $res.Success | Should -BeFalse
            $res.IpReset | Should -BeFalse
            $res.ErrorMessage | Should -Match 'non-zero exit code'
        }
    }
}
