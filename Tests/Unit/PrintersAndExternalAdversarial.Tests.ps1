# ==============================================================================
# PrintersAndExternalAdversarial.Tests.ps1
# Adversarial stress test suite for Modules/Printers and Modules/ExternalTools
# Challenger M3.1 - Empirical Verification & Adversarial Stress Testing
# Covers: Offline resilience, invalid printer ports, corrupt Point & Print keys,
# debloat safety confirmations, complete -WhatIf behavior, queue purging edge cases,
# and port binding reset boundary conditions.
# ==============================================================================

if (-not $script:ProjectRoot) {
    $script:ProjectRoot = if ($ProjectRoot) { $ProjectRoot } elseif ($PSScriptRoot) { (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path } else { (Get-Location).Path }
}
$ProjectRoot = $script:ProjectRoot
$script:PrintersManifest = Join-Path $script:ProjectRoot 'Modules/Printers/Printers.psd1'
$script:ExtToolsManifest = Join-Path $script:ProjectRoot 'Modules/ExternalTools/ExternalTools.psd1'
$isPrintersAvailable = Test-Path $script:PrintersManifest
$isExtToolsAvailable = Test-Path $script:ExtToolsManifest

BeforeAll {
    if (-not $script:ProjectRoot) {
        $script:ProjectRoot = if ($ProjectRoot) { $ProjectRoot } elseif ($PSScriptRoot) { (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path } else { (Get-Location).Path }
    }
    $ProjectRoot = $script:ProjectRoot
    $root = $script:ProjectRoot
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

Describe 'Adversarial: Printers & ExternalTools Module Stress Testing' {

    # ==========================================================================
    # Context 1: Offline Conditions & Network Failures
    # ==========================================================================
    Context '1. Offline Conditions & Network Unreachability' {
        It 'Test-InternetConnectivity returns false when all ICMP and HTTP endpoints fail' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-Connection { throw "Network unreachable" }
            Mock Invoke-WebRequest { throw "Connection refused / timeout" }

            $online = Test-InternetConnectivity
            $online | Should -BeFalse
        }

        It 'Test-InternetConnectivity returns false for custom unreachable TargetHosts' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-Connection { throw "Name resolution failure" }
            Mock Invoke-WebRequest { throw "HTTP 504 Gateway Timeout" }

            $online = Test-InternetConnectivity -TargetHosts @('192.0.2.1', 'invalid.nowhere.corp')
            $online | Should -BeFalse
        }

        It 'Test-InternetConnectivity falls back to HTTP when ICMP is blocked by firewall' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-Connection { return $false } # ICMP blocked
            Mock Invoke-WebRequest { return [PSCustomObject]@{ StatusCode = 200 } } # HTTP succeeds

            $online = Test-InternetConnectivity -TargetHosts @('github.com')
            $online | Should -BeTrue
        }

        It 'Invoke-Win11Debloat throws pre-flight error when offline without prompting or launching' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-InternetConnectivity { return $false }
            Mock Show-ToolkitConfirmation { throw "Should NOT prompt when offline" }
            Mock Start-Process { throw "Should NOT launch process when offline" }

            { Invoke-Win11Debloat } | Should -Throw -ExpectedMessage '*Internet connectivity is required*'
        }

        It 'Invoke-BrowserDebloat throws pre-flight error when offline without prompting or launching' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-InternetConnectivity { return $false }
            Mock Show-ToolkitConfirmation { throw "Should NOT prompt when offline" }
            Mock Start-Process { throw "Should NOT launch process when offline" }

            { Invoke-BrowserDebloat } | Should -Throw -ExpectedMessage '*Internet connectivity is required*'
        }

        It 'Test-NetworkPrinterConnectivity handles completely offline host without throwing' -Skip:(-not $isPrintersAvailable) {
            Mock Test-Connection { throw "Host unreachable" }
            Mock Test-NetConnection { return [PSCustomObject]@{ TcpTestSucceeded = $false } }

            $result = Test-NetworkPrinterConnectivity -ComputerName '10.254.254.254'
            $result.PingSuccess | Should -BeFalse
            $result.SmbPortOpen | Should -BeFalse
            $result.RpcPortOpen | Should -BeFalse
            $result.RawPrintPortOpen | Should -BeFalse
        }

        It 'Test-NetworkPrinterConnectivity handles DNS failure gracefully' -Skip:(-not $isPrintersAvailable) {
            Mock Test-Connection { throw [System.Net.Sockets.SocketException]::new() }
            Mock Test-NetConnection { return [PSCustomObject]@{ TcpTestSucceeded = $false } }

            $result = Test-NetworkPrinterConnectivity -ComputerName 'nonexistent-printer.local'
            $result.PingSuccess | Should -BeFalse
        }
    }

    # ==========================================================================
    # Context 2: Invalid Printer Ports & Corrupt Registry Keys
    # ==========================================================================
    Context '2. Invalid Printer Ports & Corrupt Point and Print Registry' {
        It 'Reset-PrinterNePortBindings handles empty PrinterPorts registry key' -Skip:(-not $isPrintersAvailable) {
            Mock Export-RegistryKeyBackup { return 'C:\Backups\PrinterPorts.reg' }
            Mock Get-CimInstance { return @([PSCustomObject]@{ Name = 'DefaultPrinter' }) }
            Mock Get-ItemProperty {
                # Only standard PowerShell properties, no printer port properties
                return [PSCustomObject]@{
                    PSPath = 'Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER\...'
                    PSChildName = 'PrinterPorts'
                }
            }

            $res = Reset-PrinterNePortBindings
            $res.CleanedPortsCount | Should -Be 0
            $res.RegBackupFile | Should -Be 'C:\Backups\PrinterPorts.reg'
        }

        It 'Reset-PrinterNePortBindings safely preserves active installed printers' -Skip:(-not $isPrintersAvailable) {
            Mock Export-RegistryKeyBackup { return 'C:\Backups\PrinterPorts.reg' }
            Mock Get-CimInstance {
                return @(
                    [PSCustomObject]@{ Name = 'ActiveOfficePrinter' },
                    [PSCustomObject]@{ Name = 'PDFCreator' }
                )
            }
            Mock Get-ItemProperty {
                return [PSCustomObject]@{
                    'ActiveOfficePrinter' = 'winspool,Ne01:,15,45'
                    'PDFCreator'          = 'winspool,Ne02:,15,45'
                    'OrphanedPrinter'     = 'winspool,Ne03:,15,45'
                }
            }
            $removedPorts = [System.Collections.Generic.List[string]]::new()
            Mock Remove-ItemProperty {
                param($Path, $Name)
                $removedPorts.Add($Name)
            }

            $res = Reset-PrinterNePortBindings
            $res.CleanedPortsCount | Should -Be 1
            $removedPorts | Should -Contain 'OrphanedPrinter'
            $removedPorts | Should -Not -Contain 'ActiveOfficePrinter'
            $removedPorts | Should -Not -Contain 'PDFCreator'
        }

        It 'Reset-PrinterNePortBindings with TargetPrinter cleans only the targeted printer port' -Skip:(-not $isPrintersAvailable) {
            Mock Export-RegistryKeyBackup { return 'C:\Backups\PrinterPorts.reg' }
            Mock Get-CimInstance { return @() }
            Mock Get-ItemProperty {
                return [PSCustomObject]@{
                    'TargetPrinter' = 'winspool,Ne01:,15,45'
                    'OtherPrinter'  = 'winspool,Ne02:,15,45'
                }
            }
            $removedPorts = [System.Collections.Generic.List[string]]::new()
            Mock Remove-ItemProperty {
                param($Path, $Name)
                $removedPorts.Add($Name)
            }

            $res = Reset-PrinterNePortBindings -TargetPrinter 'TargetPrinter'
            $res.CleanedPortsCount | Should -Be 1
            $removedPorts | Should -Contain 'TargetPrinter'
            $removedPorts | Should -Not -Contain 'OtherPrinter'
        }

        It 'Reset-PrinterNePortBindings does NOT wipe ports if CIM query fails or returns zero printers' -Skip:(-not $isPrintersAvailable) {
            Mock Export-RegistryKeyBackup { return 'C:\Backups\PrinterPorts.reg' }
            Mock Get-CimInstance { throw "WMI / CIM Repository Failure" }
            Mock Get-ItemProperty {
                return [PSCustomObject]@{
                    'PrinterA' = 'winspool,Ne01:,15,45'
                    'PrinterB' = 'winspool,Ne02:,15,45'
                }
            }
            $removedPorts = [System.Collections.Generic.List[string]]::new()
            Mock Remove-ItemProperty {
                param($Path, $Name)
                $removedPorts.Add($Name)
            }

            $res = Reset-PrinterNePortBindings
            $res.CleanedPortsCount | Should -Be 0
            $removedPorts.Count | Should -Be 0
        }

        It 'Test-PointAndPrintPolicy handles missing registry keys gracefully' -Skip:(-not $isPrintersAvailable) {
            Mock Get-ItemProperty { return $null }

            $audit = Test-PointAndPrintPolicy
            $audit.RpcAuthnLevelPrivacyEnabled | Should -BeNullOrEmpty
            $audit.RestrictDriverInstallationToAdministrators | Should -BeNullOrEmpty
            $audit.Vulnerabilities.Count | Should -Be 0
        }

        It 'Test-PointAndPrintPolicy handles corrupt non-numeric registry data without crashing' -Skip:(-not $isPrintersAvailable) {
            Mock Get-ItemProperty {
                return [PSCustomObject]@{
                    RpcAuthnLevelPrivacyEnabled = 'CORRUPTED_STRING_VALUE'
                }
            }

            $audit = Test-PointAndPrintPolicy
            # Catches conversion exception and leaves RpcAuthn as null
            $audit.RpcAuthnLevelPrivacyEnabled | Should -BeNullOrEmpty
        }

        It 'Test-PointAndPrintPolicy flags PrintNightmare CVE-2021-1678 when RpcAuthn is 0' -Skip:(-not $isPrintersAvailable) {
            Mock Get-ItemProperty {
                return [PSCustomObject]@{
                    RpcAuthnLevelPrivacyEnabled = 0
                    RestrictDriverInstallationToAdministrators = 1
                }
            }

            $audit = Test-PointAndPrintPolicy
            $audit.Vulnerabilities.Count | Should -BeGreaterThan 0
            $audit.Vulnerabilities[0] | Should -Match 'RpcAuthnLevelPrivacyEnabled is 0'
        }

        It 'Test-PointAndPrintPolicy flags driver installation vulnerability when RestrictAdmin is 0' -Skip:(-not $isPrintersAvailable) {
            Mock Get-ItemProperty {
                return [PSCustomObject]@{
                    RpcAuthnLevelPrivacyEnabled = 1
                    RestrictDriverInstallationToAdministrators = 0
                }
            }

            $audit = Test-PointAndPrintPolicy
            $audit.Vulnerabilities.Count | Should -BeGreaterThan 0
            $audit.Vulnerabilities[0] | Should -Match 'RestrictDriverInstallationToAdministrators is 0'
        }

        It 'Test-PointAndPrintPolicy reports zero vulnerabilities when both keys are properly secured' -Skip:(-not $isPrintersAvailable) {
            Mock Get-ItemProperty {
                return [PSCustomObject]@{
                    RpcAuthnLevelPrivacyEnabled = 1
                    RestrictDriverInstallationToAdministrators = 1
                }
            }

            $audit = Test-PointAndPrintPolicy
            $audit.Vulnerabilities.Count | Should -Be 0
        }
    }

    # ==========================================================================
    # Context 3: Debloat Tool Safety & Confirmation Prompts
    # ==========================================================================
    Context '3. Debloat Tool Safety Confirmations & Parameters' {
        It 'Invoke-Win11Debloat respects user cancellation and halts launch' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Show-ToolkitConfirmation { return $false } # User rejects
            Mock Start-Process { throw "Process must not launch when user cancels" }

            $res = Invoke-Win11Debloat
            $res.Launched | Should -BeFalse
            $res.ExitCode | Should -BeNullOrEmpty
            $res.ToolName | Should -Be 'Win11Debloat'
        }

        It 'Invoke-BrowserDebloat respects user cancellation and halts launch' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Show-ToolkitConfirmation { return $false } # User rejects
            Mock Start-Process { throw "Process must not launch when user cancels" }

            $res = Invoke-BrowserDebloat
            $res.Launched | Should -BeFalse
            $res.ExitCode | Should -BeNullOrEmpty
            $res.ToolName | Should -Be 'BrowserDebloat'
        }

        It 'Invoke-Win11Debloat targets canonical script URL' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Show-ToolkitConfirmation { return $false }

            $resRaphire = Invoke-Win11Debloat -Variant 'Raphire'
            $resRaphire.ScriptUrl | Should -Be 'https://debloat.raphi.re/'

            $resDefault = Invoke-Win11Debloat -Variant 'Default'
            $resDefault.ScriptUrl | Should -Be 'https://debloat.raphi.re/'
        }

        It 'Invoke-Win11Debloat rejects invalid Variant parameter' -Skip:(-not $isExtToolsAvailable) {
            { Invoke-Win11Debloat -Variant 'MaliciousOrInvalidVariant' } | Should -Throw
        }

        It 'Invoke-BrowserDebloat targets canonical URL' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Show-ToolkitConfirmation { return $false }

            $res = Invoke-BrowserDebloat
            $res.ScriptUrl | Should -Be 'https://debloat.yashg.dev/install.ps1'
        }
    }

    # ==========================================================================
    # Context 4: Complete -WhatIf / Dry-Run Guarantees
    # ==========================================================================
    Context '4. Dry-Run / -WhatIf Guarantees Across Mutating Cmdlets' {
        It 'Reset-PrintSpoolerQueue -WhatIf performs no modifications' -Skip:(-not $isPrintersAvailable) {
            Mock Stop-Service { throw "Stop-Service should not be called under WhatIf" }
            Mock Remove-Item { throw "Remove-Item should not be called under WhatIf" }
            Mock Start-Service { throw "Start-Service should not be called under WhatIf" }

            $res = Reset-PrintSpoolerQueue -WhatIf
            $res.FilesPurged | Should -Be 0
            $res.ServiceRestarted | Should -BeFalse
        }

        It 'Register-PrintSpoolerComponents -WhatIf executes no processes' -Skip:(-not $isPrintersAvailable) {
            Mock Start-Process { throw "Start-Process should not be called under WhatIf" }

            $res = Register-PrintSpoolerComponents -WhatIf
            $res.DllsRegistered | Should -BeFalse
            $res.WmiRecompiled | Should -BeFalse
            $res.DependencyRestored | Should -BeFalse
        }

        It 'Reset-PrinterNePortBindings -WhatIf performs no registry mutations' -Skip:(-not $isPrintersAvailable) {
            Mock Remove-ItemProperty { throw "Remove-ItemProperty should not be called under WhatIf" }

            $res = Reset-PrinterNePortBindings -WhatIf
            $res.CleanedPortsCount | Should -Be 0
            $res.RegBackupFile | Should -Be '[Simulated - WhatIf]'
        }

        It 'Set-PointAndPrintRemediation -WhatIf performs no registry modifications' -Skip:(-not $isPrintersAvailable) {
            Mock Set-ToolkitRegistryValue { throw "Set-ToolkitRegistryValue should not be called under WhatIf" }

            $res = Set-PointAndPrintRemediation -Preset 'StrictAdminOnly' -WhatIf
            $res.PresetApplied | Should -Be 'StrictAdminOnly'
            $res.RegBackupFile | Should -Be '[Simulated - WhatIf]'
        }

        It 'Reset-PrinterConnections -WhatIf does not modify printer mappings' -Skip:(-not $isPrintersAvailable) {
            $res = Reset-PrinterConnections -WhatIf
            $res.RefreshedConnections | Should -Be 0
            $res.StaleRemoved | Should -Be 0
        }

        It 'Invoke-Win11Debloat -WhatIf validates internet but skips confirmation and execution' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Show-ToolkitConfirmation { throw "Confirmation should not be shown under WhatIf" }
            Mock Start-Process { throw "Process should not be launched under WhatIf" }

            $res = Invoke-Win11Debloat -WhatIf
            $res.Launched | Should -BeFalse
            $res.ExitCode | Should -BeNullOrEmpty
        }

        It 'Invoke-BrowserDebloat -WhatIf validates internet but skips confirmation and execution' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Show-ToolkitConfirmation { throw "Confirmation should not be shown under WhatIf" }
            Mock Start-Process { throw "Process should not be launched under WhatIf" }

            $res = Invoke-BrowserDebloat -WhatIf
            $res.Launched | Should -BeFalse
            $res.ExitCode | Should -BeNullOrEmpty
        }
    }

    # ==========================================================================
    # Context 5: Queue Purging & Service Reset Edge Cases
    # ==========================================================================
    Context '5. Spooler Queue Purge & Service Reset Edge Cases' {
        It 'Reset-PrintSpoolerQueue succeeds cleanly when spool queue is already empty' -Skip:(-not $isPrintersAvailable) {
            Mock Stop-Service { }
            Mock Get-ChildItem { return @() } # Empty queue
            Mock Start-Service { }

            $res = Reset-PrintSpoolerQueue
            $res.FilesPurged | Should -Be 0
            $res.ServiceRestarted | Should -BeTrue
        }

        It 'Reset-PrintSpoolerQueue handles locked spool files gracefully' -Skip:(-not $isPrintersAvailable) {
            Mock Stop-Service { }
            Mock Get-ChildItem { return @([PSCustomObject]@{ FullName = 'C:\spool\PRINTERS\locked.SHD' }) }
            Mock Remove-Item { throw [System.IO.IOException]::new("The process cannot access the file because it is being used by another process.") }
            Mock Start-Service { }

            $res = Reset-PrintSpoolerQueue
            # File failed to remove, service restart should still be attempted
            $res.ServiceRestarted | Should -BeTrue
        }

        It 'Reset-PrintSpoolerQueue with -Force terminates lingering spoolsv process' -Skip:(-not $isPrintersAvailable) {
            Mock Stop-Service { }
            Mock Get-ChildItem { return @() }
            Mock Start-Service { }
            Mock Get-Process { return [PSCustomObject]@{ Id = 4321; ProcessName = 'spoolsv' } }
            $script:processKilled = $false
            Mock Stop-Process {
                param($Name, [switch]$Force)
                if ($Name -eq 'spoolsv') {
                    $script:processKilled = $true
                }
            }

            $res = Reset-PrintSpoolerQueue -Force
            $script:processKilled | Should -BeTrue
            $res.ServiceRestarted | Should -BeTrue
        }

        It 'Reset-PrintSpoolerQueue without -Force does not call Stop-Process' -Skip:(-not $isPrintersAvailable) {
            Mock Stop-Service { }
            Mock Get-ChildItem { return @() }
            Mock Start-Service { }
            Mock Stop-Process { throw "Stop-Process should not be invoked without -Force" }

            $res = Reset-PrintSpoolerQueue
            $res.ServiceRestarted | Should -BeTrue
        }

        It 'Register-PrintSpoolerComponents detects and returns failure when registration binaries fail' -Skip:(-not $isPrintersAvailable) {
            Mock Start-Process {
                param($FilePath)
                if ($FilePath -match 'regsvr32') {
                    return [PSCustomObject]@{ ExitCode = 1 } # Failure
                }
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $res = Register-PrintSpoolerComponents
            $res.DllsRegistered | Should -BeFalse
            $res.WmiRecompiled | Should -BeTrue
            $res.DependencyRestored | Should -BeTrue
        }

        It 'Set-PointAndPrintRemediation applies 0 values for Compatibility / Compat preset' -Skip:(-not $isPrintersAvailable) {
            $appliedValues = [System.Collections.Generic.Dictionary[string, int]]::new()
            Mock Set-ToolkitRegistryValue {
                param($KeyPath, $ValueName, $Value)
                $appliedValues[$ValueName] = $Value
                return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\PnP.reg' }
            }

            $res = Set-PointAndPrintRemediation -Preset 'Compatibility'
            $res.PresetApplied | Should -Be 'Compatibility'
            $appliedValues['RpcAuthnLevelPrivacyEnabled'] | Should -Be 0
            $appliedValues['RestrictDriverInstallationToAdministrators'] | Should -Be 0
        }

        It 'Set-PointAndPrintRemediation applies 1 values for StrictAdminOnly / Secure preset' -Skip:(-not $isPrintersAvailable) {
            $appliedValues = [System.Collections.Generic.Dictionary[string, int]]::new()
            Mock Set-ToolkitRegistryValue {
                param($KeyPath, $ValueName, $Value)
                $appliedValues[$ValueName] = $Value
                return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\PnP.reg' }
            }

            $res = Set-PointAndPrintRemediation -Preset 'StrictAdminOnly'
            $res.PresetApplied | Should -Be 'StrictAdminOnly'
            $appliedValues['RpcAuthnLevelPrivacyEnabled'] | Should -Be 1
            $appliedValues['RestrictDriverInstallationToAdministrators'] | Should -Be 1
        }

        It 'Set-PointAndPrintRemediation rejects arbitrary non-whitelisted presets' -Skip:(-not $isPrintersAvailable) {
            { Set-PointAndPrintRemediation -Preset 'InsecureHackPreset' } | Should -Throw
        }

        It 'Reset-PrinterConnections refreshes UNC and named printers' -Skip:(-not $isPrintersAvailable) {
            if (-not (Get-Command -Name 'Add-Printer' -ErrorAction SilentlyContinue)) {
                function global:Add-Printer { param($ConnectionName) }
            }
            Mock Get-CimInstance {
                return @(
                    [PSCustomObject]@{ Name = '\\printserver01\LaserJet4' },
                    [PSCustomObject]@{ Name = '\\printserver02\ColorDeskjet' },
                    [PSCustomObject]@{ Name = 'LocalXerox' }
                )
            }
            Mock Test-Connection { return $true }
            Mock Add-Printer { }

            $resAll = Reset-PrinterConnections -All
            $resAll.RefreshedConnections | Should -Be 2

            $resNamed = Reset-PrinterConnections -PrinterName 'LocalXerox'
            $resNamed.RefreshedConnections | Should -Be 1
            $resNamed.StaleRemoved | Should -Be 0
        }

        It 'Reset-PrinterConnections identifies and removes unreachable stale connections' -Skip:(-not $isPrintersAvailable) {
            if (-not (Get-Command -Name 'Remove-Printer' -ErrorAction SilentlyContinue)) {
                function global:Remove-Printer { param($Name) }
            }
            Mock Get-CimInstance {
                return @([PSCustomObject]@{ Name = '\\unreachable-server\broken-printer' })
            }
            Mock Test-Connection { return $false }
            Mock Test-NetConnection { return [PSCustomObject]@{ TcpTestSucceeded = $false } }
            $removedList = [System.Collections.Generic.List[string]]::new()
            Mock Remove-Printer {
                param($Name)
                $removedList.Add($Name)
            }

            $res = Reset-PrinterConnections -All
            $res.RefreshedConnections | Should -Be 0
            $res.StaleRemoved | Should -Be 1
            $removedList | Should -Contain '\\unreachable-server\broken-printer'
        }

        It 'Register-PrintSpoolerComponents returns failure when Start-Process returns null' -Skip:(-not $isPrintersAvailable) {
            Mock Start-Process { return $null }
            $res = Register-PrintSpoolerComponents
            $res.DllsRegistered | Should -BeFalse
            $res.WmiRecompiled | Should -BeFalse
            $res.DependencyRestored | Should -BeFalse
        }

        It 'Reset-PrintSpoolerQueue returns ServiceRestarted false when Start-Service throws' -Skip:(-not $isPrintersAvailable) {
            Mock Stop-Service { }
            Mock Get-ChildItem { return @() }
            Mock Start-Service { throw "Service failed to start" }

            $res = Reset-PrintSpoolerQueue
            $res.ServiceRestarted | Should -BeFalse
        }
    }

    # ==========================================================================
    # Context 6: Milestone 3 Round 2 Adversarial Hardening
    # ==========================================================================
    Context '6. Round 2 Stress Tests: Reachability, Custom Ports, Fallback Confirmations & Restart Failures' {
        
        # 6.1 Reachability testing under offline/unreachable conditions
        It 'Reset-PrinterConnections correctly handles mixed online and offline print servers in batch' -Skip:(-not $isPrintersAvailable) {
            if (-not (Get-Command -Name 'Add-Printer' -ErrorAction SilentlyContinue)) {
                function global:Add-Printer { param($ConnectionName) }
            }
            if (-not (Get-Command -Name 'Remove-Printer' -ErrorAction SilentlyContinue)) {
                function global:Remove-Printer { param($Name) }
            }

            Mock Get-CimInstance {
                return @(
                    [PSCustomObject]@{ Name = '\\online-srv1\printer1' },
                    [PSCustomObject]@{ Name = '\\online-srv2\printer2' },
                    [PSCustomObject]@{ Name = '\\offline-srv1\printer3' },
                    [PSCustomObject]@{ Name = '\\offline-srv2\printer4' }
                )
            }
            Mock Test-Connection {
                param($TargetName, $ComputerName)
                $t = if ($TargetName) { $TargetName } elseif ($ComputerName) { $ComputerName } else { $args[0] }
                if ($t -match 'online') { return $true }
                return $false
            }
            Mock Test-NetConnection {
                param($ComputerName, $Port)
                if ($ComputerName -match 'online') { return [PSCustomObject]@{ TcpTestSucceeded = $true } }
                return [PSCustomObject]@{ TcpTestSucceeded = $false }
            }
            $removedList = [System.Collections.Generic.List[string]]::new()
            Mock Remove-Printer { param($Name) $removedList.Add($Name) }
            Mock Add-Printer { }

            $res = Reset-PrinterConnections -All
            $res.RefreshedConnections | Should -Be 2
            $res.StaleRemoved | Should -Be 2
            $removedList | Should -Contain '\\offline-srv1\printer3'
            $removedList | Should -Contain '\\offline-srv2\printer4'
        }

        It 'Reset-PrinterConnections targeted at unreachable printer removes it and increments StaleRemoved' -Skip:(-not $isPrintersAvailable) {
            if (-not (Get-Command -Name 'Remove-Printer' -ErrorAction SilentlyContinue)) {
                function global:Remove-Printer { param($Name) }
            }
            Mock Get-CimInstance {
                return @(
                    [PSCustomObject]@{ Name = '\\offline-srv\badprinter' },
                    [PSCustomObject]@{ Name = '\\online-srv\goodprinter' }
                )
            }
            Mock Test-Connection { return $false }
            Mock Test-NetConnection { return [PSCustomObject]@{ TcpTestSucceeded = $false } }
            $removedList = [System.Collections.Generic.List[string]]::new()
            Mock Remove-Printer { param($Name) $removedList.Add($Name) }

            $res = Reset-PrinterConnections -PrinterName '\\offline-srv\badprinter'
            $res.RefreshedConnections | Should -Be 0
            $res.StaleRemoved | Should -Be 1
            $removedList | Should -Contain '\\offline-srv\badprinter'
            $removedList | Should -Not -Contain '\\online-srv\goodprinter'
        }

        It 'Reset-PrinterConnections handles socket exceptions during reachability check and removes stale printer' -Skip:(-not $isPrintersAvailable) {
            if (-not (Get-Command -Name 'Remove-Printer' -ErrorAction SilentlyContinue)) {
                function global:Remove-Printer { param($Name) }
            }
            Mock Get-CimInstance {
                return @([PSCustomObject]@{ Name = '\\deadhost.corp\unreachable' })
            }
            Mock Test-Connection { throw [System.Net.Sockets.SocketException]::new() }
            Mock Test-NetConnection { throw [System.Net.Sockets.SocketException]::new() }
            $removedList = [System.Collections.Generic.List[string]]::new()
            Mock Remove-Printer { param($Name) $removedList.Add($Name) }

            $res = Reset-PrinterConnections -All
            $res.RefreshedConnections | Should -Be 0
            $res.StaleRemoved | Should -Be 1
            $removedList | Should -Contain '\\deadhost.corp\unreachable'
        }

        It 'Reset-PrinterConnections increments StaleRemoved even when Remove-Printer throws access denied' -Skip:(-not $isPrintersAvailable) {
            if (-not (Get-Command -Name 'Remove-Printer' -ErrorAction SilentlyContinue)) {
                function global:Remove-Printer { param($Name) }
            }
            Mock Get-CimInstance {
                return @([PSCustomObject]@{ Name = '\\offline-srv\locked-printer' })
            }
            Mock Test-Connection { return $false }
            Mock Test-NetConnection { return [PSCustomObject]@{ TcpTestSucceeded = $false } }
            Mock Remove-Printer { throw [System.UnauthorizedAccessException]::new('Access denied') }

            $res = Reset-PrinterConnections -All
            $res.RefreshedConnections | Should -Be 0
            $res.StaleRemoved | Should -Be 1
        }

        # 6.2 Custom -Ports parameter testing with valid and invalid port numbers
        It 'Test-NetworkPrinterConnectivity tests custom valid ports array' -Skip:(-not $isPrintersAvailable) {
            Mock Test-Connection { return $true }
            Mock Test-NetConnection {
                param($ComputerName, $Port)
                if ($Port -in @(80, 443, 631)) {
                    return [PSCustomObject]@{ TcpTestSucceeded = $true }
                }
                return [PSCustomObject]@{ TcpTestSucceeded = $false }
            }

            $res = Test-NetworkPrinterConnectivity -ComputerName 'print-srv.corp' -Ports @(80, 443, 631, 8080)
            $res.CustomPortResults[80] | Should -BeTrue
            $res.CustomPortResults[443] | Should -BeTrue
            $res.CustomPortResults[631] | Should -BeTrue
            $res.CustomPortResults[8080] | Should -BeFalse
        }

        It 'Test-NetworkPrinterConnectivity handles invalid out-of-range ports without crashing' -Skip:(-not $isPrintersAvailable) {
            Mock Test-Connection { return $true }
            Mock Test-NetConnection {
                param($ComputerName, $Port)
                if ($Port -le 0 -or $Port -gt 65535) {
                    throw [System.ArgumentOutOfRangeException]::new('Port', 'Port out of range')
                }
                if ($Port -eq 445) {
                    return [PSCustomObject]@{ TcpTestSucceeded = $true }
                }
                return [PSCustomObject]@{ TcpTestSucceeded = $false }
            }

            $res = Test-NetworkPrinterConnectivity -ComputerName 'print-srv.corp' -Ports @(-1, 0, 445, 70000)
            $res.CustomPortResults[-1] | Should -BeFalse
            $res.CustomPortResults[0] | Should -BeFalse
            $res.CustomPortResults[445] | Should -BeTrue
            $res.CustomPortResults[70000] | Should -BeFalse
            $res.SmbPortOpen | Should -BeTrue
        }

        # 6.3 Confirmation prompt behavior when Show-ToolkitConfirmation is absent
        It 'Invoke-Win11Debloat safely aborts and avoids remote code execution when Show-ToolkitConfirmation is absent and host rejects' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Start-Process { throw "FATAL: Start-Process must NEVER be called when confirmation fails" }

            # Temporarily remove Core module so Show-ToolkitConfirmation is absent
            $coreLoaded = [bool](Get-Module -Name 'Core')
            if ($coreLoaded) { Remove-Module -Name 'Core' -Force }

            try {
                # Override PromptForChoice on $Host.UI to return 1 (&No)
                $Host.UI | Add-Member -MemberType ScriptMethod -Name 'PromptForChoice' -Value { param($c, $m, $ch, $d) return 1 } -Force

                $res = Invoke-Win11Debloat
                $res.Launched | Should -BeFalse
                $res.ExitCode | Should -BeNullOrEmpty
            } finally {
                # Restore Core module
                if ($coreLoaded) {
                    $root = if ($script:ProjectRoot) { $script:ProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } elseif ($PSScriptRoot) { (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path } else { '.' }
                    $coreManifest = Join-Path $root 'Modules/Core/Core.psd1'
                    if (Test-Path $coreManifest) {
                        Import-Module $coreManifest -Force
                    }
                }
            }
        }

        It 'Invoke-Win11Debloat safely aborts when Show-ToolkitConfirmation is absent and host PromptForChoice throws' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Start-Process { throw "FATAL: Start-Process must NEVER be called when confirmation fails" }

            $coreLoaded = [bool](Get-Module -Name 'Core')
            if ($coreLoaded) { Remove-Module -Name 'Core' -Force }

            try {
                $Host.UI | Add-Member -MemberType ScriptMethod -Name 'PromptForChoice' -Value { throw "Non-interactive host" } -Force

                $res = Invoke-Win11Debloat
                $res.Launched | Should -BeFalse
                $res.ExitCode | Should -BeNullOrEmpty
            } finally {
                if ($coreLoaded) {
                    $root = if ($script:ProjectRoot) { $script:ProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } elseif ($PSScriptRoot) { (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path } else { '.' }
                    $coreManifest = Join-Path $root 'Modules/Core/Core.psd1'
                    if (Test-Path $coreManifest) {
                        Import-Module $coreManifest -Force
                    }
                }
            }
        }

        It 'Invoke-BrowserDebloat safely aborts and avoids remote code execution when Show-ToolkitConfirmation is absent and host rejects' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Start-Process { throw "FATAL: Start-Process must NEVER be called when confirmation fails" }

            $coreLoaded = [bool](Get-Module -Name 'Core')
            if ($coreLoaded) { Remove-Module -Name 'Core' -Force }

            try {
                $Host.UI | Add-Member -MemberType ScriptMethod -Name 'PromptForChoice' -Value { param($c, $m, $ch, $d) return 1 } -Force

                $res = Invoke-BrowserDebloat
                $res.Launched | Should -BeFalse
                $res.ExitCode | Should -BeNullOrEmpty
            } finally {
                if ($coreLoaded) {
                    $root = if ($script:ProjectRoot) { $script:ProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } elseif ($PSScriptRoot) { (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path } else { '.' }
                    $coreManifest = Join-Path $root 'Modules/Core/Core.psd1'
                    if (Test-Path $coreManifest) {
                        Import-Module $coreManifest -Force
                    }
                }
            }
        }

        It 'Invoke-BrowserDebloat safely aborts when Show-ToolkitConfirmation is absent and host PromptForChoice throws' -Skip:(-not $isExtToolsAvailable) {
            Mock Test-InternetConnectivity { return $true }
            Mock Start-Process { throw "FATAL: Start-Process must NEVER be called when confirmation fails" }

            $coreLoaded = [bool](Get-Module -Name 'Core')
            if ($coreLoaded) { Remove-Module -Name 'Core' -Force }

            try {
                $Host.UI | Add-Member -MemberType ScriptMethod -Name 'PromptForChoice' -Value { throw "Non-interactive host" } -Force

                $res = Invoke-BrowserDebloat
                $res.Launched | Should -BeFalse
                $res.ExitCode | Should -BeNullOrEmpty
            } finally {
                if ($coreLoaded) {
                    $root = if ($script:ProjectRoot) { $script:ProjectRoot } elseif ($ProjectRoot) { $ProjectRoot } elseif ($PSScriptRoot) { (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path } else { '.' }
                    $coreManifest = Join-Path $root 'Modules/Core/Core.psd1'
                    if (Test-Path $coreManifest) {
                        Import-Module $coreManifest -Force
                    }
                }
            }
        }

        # 6.4 Spooler restart failure handling
        It 'Reset-PrintSpoolerQueue returns ServiceRestarted false when Start-Service succeeds but service remains Stopped' -Skip:(-not $isPrintersAvailable) {
            Mock Stop-Service { }
            Mock Get-ChildItem { return @() }
            Mock Start-Service { }
            Mock Get-Service { return [PSCustomObject]@{ Status = 'Stopped' } }

            $res = Reset-PrintSpoolerQueue
            $res.ServiceRestarted | Should -BeFalse
        }

        It 'Reset-PrintSpoolerQueue returns ServiceRestarted false when Start-Service succeeds but service remains Paused' -Skip:(-not $isPrintersAvailable) {
            Mock Stop-Service { }
            Mock Get-ChildItem { return @() }
            Mock Start-Service { }
            Mock Get-Service { return [PSCustomObject]@{ Status = 'Paused' } }

            $res = Reset-PrintSpoolerQueue
            $res.ServiceRestarted | Should -BeFalse
        }

        It 'Reset-PrintSpoolerQueue handles both Stop-Service and Start-Service failing gracefully' -Skip:(-not $isPrintersAvailable) {
            Mock Stop-Service { throw "Stop-Service failed: Access Denied" }
            Mock Get-ChildItem { return @() }
            Mock Start-Service { throw "Start-Service failed: System error" }

            $res = Reset-PrintSpoolerQueue
            $res.ServiceRestarted | Should -BeFalse
        }
    }
}
