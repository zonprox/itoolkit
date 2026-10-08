# ==============================================================================
# PrinterRemediationAdversarial.Tests.ps1
# Adversarial Stress Testing & Empirical Contract Verification Suite for R2
# Covers: Set-PrinterServerRemediation and Set-PrinterClientRemediation
# Tests: Return contracts, batch vs individual fixes, parameter validation,
#        -WhatIf side-effect suppression, backup collection, and rollback.
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

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

Describe 'Adversarial: Categorized Network Printer Connection Remediation (R2)' {

    # ==========================================================================
    # Context 1: Return Object Contract Verification
    # ==========================================================================
    Context '1. Return Object Contract Verification' {

        It 'Set-PrinterServerRemediation returns complete contract schema in normal mode' {
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\srv.reg' } }
            Mock Stop-Service { }
            Mock Start-Service { }
            Mock Get-Service { return [PSCustomObject]@{ Status = 'Running' } }

            $res = Set-PrinterServerRemediation -All
            $res | Should -Not -BeNullOrEmpty
            $res.PSObject.Properties.Name | Should -Contain 'Role'
            $res.PSObject.Properties.Name | Should -Contain 'FixesApplied'
            $res.PSObject.Properties.Name | Should -Contain 'RegBackupFiles'
            $res.PSObject.Properties.Name | Should -Contain 'SpoolerRestarted'
            $res.PSObject.Properties.Name | Should -Contain 'DirectoryStatus'
            $res.PSObject.Properties.Name | Should -Contain 'Success'

            $res.Role | Should -Be 'Server'
            $res.FixesApplied -is [array] | Should -BeTrue
            $res.RegBackupFiles -is [array] | Should -BeTrue
            $res.SpoolerRestarted -is [bool] | Should -BeTrue
            $res.DirectoryStatus -is [string] | Should -BeTrue
            $res.Success -is [bool] | Should -BeTrue
            $res.Success | Should -BeTrue
        }

        It 'Set-PrinterServerRemediation returns complete contract schema in -WhatIf mode' {
            $res = Set-PrinterServerRemediation -All -WhatIf
            $res | Should -Not -BeNullOrEmpty
            $res.Role | Should -Be 'Server'
            $res.FixesApplied -is [array] | Should -BeTrue
            $res.RegBackupFiles -is [array] | Should -BeTrue
            $res.RegBackupFiles | Should -Contain '[Simulated - WhatIf]'
            $res.SpoolerRestarted | Should -BeFalse
            $res.DirectoryStatus | Should -Be 'Simulated'
            $res.Success | Should -BeTrue
        }

        It 'Set-PrinterClientRemediation returns complete contract schema in normal mode' {
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\cli.reg' } }
            Mock Reset-PrintSpoolerQueue { return [PSCustomObject]@{ FilesPurged = 2; ServiceRestarted = $true } }
            Mock Reset-PrinterNePortBindings { return [PSCustomObject]@{ CleanedPortsCount = 1; RegBackupFile = 'C:\Backups\ne.reg' } }
            Mock Reset-PrinterConnections { return [PSCustomObject]@{ RefreshedConnections = 3; StaleRemoved = 0 } }

            $res = Set-PrinterClientRemediation -All
            $res | Should -Not -BeNullOrEmpty
            $res.PSObject.Properties.Name | Should -Contain 'Role'
            $res.PSObject.Properties.Name | Should -Contain 'FixesApplied'
            $res.PSObject.Properties.Name | Should -Contain 'RegBackupFiles'
            $res.PSObject.Properties.Name | Should -Contain 'QueuePurgedCount'
            $res.PSObject.Properties.Name | Should -Contain 'CleanedNePortsCount'
            $res.PSObject.Properties.Name | Should -Contain 'RefreshedConnections'
            $res.PSObject.Properties.Name | Should -Contain 'StaleRemoved'
            $res.PSObject.Properties.Name | Should -Contain 'Success'

            $res.Role | Should -Be 'Client'
            $res.FixesApplied -is [array] | Should -BeTrue
            $res.RegBackupFiles -is [array] | Should -BeTrue
            $res.QueuePurgedCount -is [int] | Should -BeTrue
            $res.CleanedNePortsCount -is [int] | Should -BeTrue
            $res.RefreshedConnections -is [int] | Should -BeTrue
            $res.StaleRemoved -is [int] | Should -BeTrue
            $res.Success -is [bool] | Should -BeTrue
            $res.Success | Should -BeTrue
        }

        It 'Set-PrinterClientRemediation returns complete contract schema in -WhatIf mode' {
            $res = Set-PrinterClientRemediation -All -WhatIf
            $res | Should -Not -BeNullOrEmpty
            $res.Role | Should -Be 'Client'
            $res.FixesApplied -is [array] | Should -BeTrue
            $res.RegBackupFiles -is [array] | Should -BeTrue
            $res.RegBackupFiles | Should -Contain '[Simulated - WhatIf]'
            $res.QueuePurgedCount | Should -Be 0
            $res.CleanedNePortsCount | Should -Be 0
            $res.RefreshedConnections | Should -Be 0
            $res.StaleRemoved | Should -Be 0
            $res.Success | Should -BeTrue
        }
    }

    # ==========================================================================
    # Context 2: Server Remediation - Batch vs Individual Execution
    # ==========================================================================
    Context '2. Server Remediation - Batch vs Individual Fixes' {

        It 'Server -All applies exactly all four server fixes' {
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\srv.reg' } }
            Mock Stop-Service { }
            Mock Start-Service { }
            Mock Get-Service { return [PSCustomObject]@{ Status = 'Running' } }

            $res = Set-PrinterServerRemediation -All
            $expected = @('RpcAuthnLevel', 'RemoteRpcEndPoint', 'RpcProtocols', 'SpoolerHealth')
            $res.FixesApplied.Count | Should -Be 4
            foreach ($exp in $expected) {
                $res.FixesApplied | Should -Contain $exp
            }
        }

        It 'Server -Fix All applies exactly all four server fixes' {
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\srv.reg' } }
            Mock Stop-Service { }
            Mock Start-Service { }
            Mock Get-Service { return [PSCustomObject]@{ Status = 'Running' } }

            $res = Set-PrinterServerRemediation -Fix 'All'
            $res.FixesApplied.Count | Should -Be 4
            $res.FixesApplied | Should -Contain 'RpcAuthnLevel'
            $res.FixesApplied | Should -Contain 'RemoteRpcEndPoint'
            $res.FixesApplied | Should -Contain 'RpcProtocols'
            $res.FixesApplied | Should -Contain 'SpoolerHealth'
        }

        It 'Server -Fix RpcAuthnLevel touches ONLY RpcAuthnLevelPrivacyEnabled' {
            $calls = [System.Collections.Generic.List[string]]::new()
            Mock Set-ToolkitRegistryValue {
                $calls.Add("$KeyPath\$ValueName=$Value")
                return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\authn.reg' }
            }
            Mock Stop-Service { $calls.Add("Stop-Service") }
            Mock Start-Service { $calls.Add("Start-Service") }

            $res = Set-PrinterServerRemediation -Fix 'RpcAuthnLevel'
            $res.FixesApplied | Should -Be @('RpcAuthnLevel')
            $calls.Count | Should -Be 1
            $calls[0] | Should -Be 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\RpcAuthnLevelPrivacyEnabled=0'
            $res.SpoolerRestarted | Should -BeFalse
        }

        It 'Server -Fix RemoteRpcEndPoint touches ONLY RegisterSpoolerRemoteRpcEndPoint' {
            $calls = [System.Collections.Generic.List[string]]::new()
            Mock Set-ToolkitRegistryValue {
                $calls.Add("$KeyPath\$ValueName=$Value")
                return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\endpoint.reg' }
            }
            Mock Stop-Service { $calls.Add("Stop-Service") }
            Mock Start-Service { $calls.Add("Start-Service") }

            $res = Set-PrinterServerRemediation -Fix 'RemoteRpcEndPoint'
            $res.FixesApplied | Should -Be @('RemoteRpcEndPoint')
            $calls.Count | Should -Be 1
            $calls[0] | Should -Be 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RegisterSpoolerRemoteRpcEndPoint=1'
            $res.SpoolerRestarted | Should -BeFalse
        }

        It 'Server -Fix RpcProtocols touches RpcUseNamedPipeProtocol and RpcProtocols' {
            $calls = [System.Collections.Generic.List[string]]::new()
            Mock Set-ToolkitRegistryValue {
                $calls.Add("$KeyPath\$ValueName=$Value")
                return [PSCustomObject]@{ RegBackupFile = "C:\Backups\$ValueName.reg" }
            }
            Mock Stop-Service { $calls.Add("Stop-Service") }

            $res = Set-PrinterServerRemediation -Fix 'RpcProtocols'
            $res.FixesApplied | Should -Be @('RpcProtocols')
            $calls.Count | Should -Be 2
            $calls | Should -Contain 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC\RpcUseNamedPipeProtocol=1'
            $calls | Should -Contain 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC\RpcProtocols=7'
            $res.SpoolerRestarted | Should -BeFalse
        }

        It 'Server -Fix SpoolerHealth restarts spooler without modifying registry keys' {
            $regCalled = $false
            Mock Set-ToolkitRegistryValue { $regCalled = $true; return $null }
            Mock Stop-Service { }
            Mock Start-Service { }
            Mock Get-Service { return [PSCustomObject]@{ Status = 'Running' } }

            $res = Set-PrinterServerRemediation -Fix 'SpoolerHealth'
            $res.FixesApplied | Should -Be @('SpoolerHealth')
            $regCalled | Should -BeFalse
            $res.SpoolerRestarted | Should -BeTrue
        }

        It 'Server deduplicates redundant fix arguments' {
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\authn.reg' } }

            $res = Set-PrinterServerRemediation -Fix 'RpcAuthnLevel', 'RpcAuthnLevel'
            $res.FixesApplied.Count | Should -Be 1
            $res.FixesApplied[0] | Should -Be 'RpcAuthnLevel'
        }

        It 'Server -All flag overrides targeted -Fix argument' {
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\srv.reg' } }
            Mock Stop-Service { }
            Mock Start-Service { }
            Mock Get-Service { return [PSCustomObject]@{ Status = 'Running' } }

            $res = Set-PrinterServerRemediation -All -Fix 'RpcAuthnLevel'
            $res.FixesApplied.Count | Should -Be 4
        }
    }

    # ==========================================================================
    # Context 3: Client Remediation - Batch vs Individual Execution
    # ==========================================================================
    Context '3. Client Remediation - Batch vs Individual Fixes' {

        It 'Client -All applies exactly all seven client fixes' {
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\cli.reg' } }
            Mock Reset-PrintSpoolerQueue { return [PSCustomObject]@{ FilesPurged = 0; ServiceRestarted = $true } }
            Mock Reset-PrinterNePortBindings { return [PSCustomObject]@{ CleanedPortsCount = 0; RegBackupFile = 'C:\Backups\ne.reg' } }
            Mock Reset-PrinterConnections { return [PSCustomObject]@{ RefreshedConnections = 0; StaleRemoved = 0 } }

            $res = Set-PrinterClientRemediation -All
            $expected = @('PointAndPrintAdmin', 'PointAndPrintPrompts', 'RpcNamedPipe', 'CopyFilesPolicy', 'SpoolerQueue', 'NePorts', 'RefreshConnections')
            $res.FixesApplied.Count | Should -Be 7
            foreach ($exp in $expected) {
                $res.FixesApplied | Should -Contain $exp
            }
        }

        It 'Client -Fix PointAndPrintAdmin touches ONLY RestrictDriverInstallationToAdministrators' {
            $calls = [System.Collections.Generic.List[string]]::new()
            Mock Set-ToolkitRegistryValue {
                $calls.Add("$KeyPath\$ValueName=$Value")
                return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\pnp.reg' }
            }
            Mock Reset-PrintSpoolerQueue { $calls.Add("Reset-PrintSpoolerQueue") }
            Mock Reset-PrinterNePortBindings { $calls.Add("Reset-PrinterNePortBindings") }
            Mock Reset-PrinterConnections { $calls.Add("Reset-PrinterConnections") }

            $res = Set-PrinterClientRemediation -Fix 'PointAndPrintAdmin'
            $res.FixesApplied | Should -Be @('PointAndPrintAdmin')
            $calls.Count | Should -Be 1
            $calls[0] | Should -Be 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint\RestrictDriverInstallationToAdministrators=0'
            $res.QueuePurgedCount | Should -Be 0
            $res.CleanedNePortsCount | Should -Be 0
            $res.RefreshedConnections | Should -Be 0
        }

        It 'Client -Fix PointAndPrintPrompts sets NoWarningNoElevationOnInstall and UpdatePromptSettings' {
            $calls = [System.Collections.Generic.List[string]]::new()
            Mock Set-ToolkitRegistryValue {
                $calls.Add("$KeyPath\$ValueName=$Value")
                return [PSCustomObject]@{ RegBackupFile = "C:\Backups\$ValueName.reg" }
            }

            $res = Set-PrinterClientRemediation -Fix 'PointAndPrintPrompts'
            $res.FixesApplied | Should -Be @('PointAndPrintPrompts')
            $calls.Count | Should -Be 2
            $calls | Should -Contain 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint\NoWarningNoElevationOnInstall=1'
            $calls | Should -Contain 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint\UpdatePromptSettings=2'
        }

        It 'Client -Fix RpcNamedPipe fixes 0x00000709 via Printers\RPC\RpcUseNamedPipeProtocol' {
            $calls = [System.Collections.Generic.List[string]]::new()
            Mock Set-ToolkitRegistryValue {
                $calls.Add("$KeyPath\$ValueName=$Value")
                return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\rpcpipe.reg' }
            }

            $res = Set-PrinterClientRemediation -Fix 'RpcNamedPipe'
            $res.FixesApplied | Should -Be @('RpcNamedPipe')
            $calls.Count | Should -Be 1
            $calls[0] | Should -Be 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC\RpcUseNamedPipeProtocol=1'
        }

        It 'Client -Fix CopyFilesPolicy fixes 0x0000007c via CopyFilesPolicy=1' {
            $calls = [System.Collections.Generic.List[string]]::new()
            Mock Set-ToolkitRegistryValue {
                $calls.Add("$KeyPath\$ValueName=$Value")
                return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\copyfiles.reg' }
            }

            $res = Set-PrinterClientRemediation -Fix 'CopyFilesPolicy'
            $res.FixesApplied | Should -Be @('CopyFilesPolicy')
            $calls.Count | Should -Be 1
            $calls[0] | Should -Be 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\CopyFilesPolicy=1'
        }

        It 'Client -Fix SpoolerQueue calls Reset-PrintSpoolerQueue and captures purged files' {
            Mock Reset-PrintSpoolerQueue {
                return [PSCustomObject]@{ FilesPurged = 7; ServiceRestarted = $true }
            }

            $res = Set-PrinterClientRemediation -Fix 'SpoolerQueue'
            $res.FixesApplied | Should -Be @('SpoolerQueue')
            $res.QueuePurgedCount | Should -Be 7
        }

        It 'Client -Fix NePorts calls Reset-PrinterNePortBindings and captures cleaned count' {
            Mock Reset-PrinterNePortBindings {
                return [PSCustomObject]@{ CleanedPortsCount = 4; RegBackupFile = 'C:\Backups\ne4.reg' }
            }

            $res = Set-PrinterClientRemediation -Fix 'NePorts'
            $res.FixesApplied | Should -Be @('NePorts')
            $res.CleanedNePortsCount | Should -Be 4
            $res.RegBackupFiles | Should -Contain 'C:\Backups\ne4.reg'
        }

        It 'Client -Fix RefreshConnections calls Reset-PrinterConnections and captures statistics' {
            Mock Reset-PrinterConnections {
                return [PSCustomObject]@{ RefreshedConnections = 5; StaleRemoved = 2 }
            }

            $res = Set-PrinterClientRemediation -Fix 'RefreshConnections'
            $res.FixesApplied | Should -Be @('RefreshConnections')
            $res.RefreshedConnections | Should -Be 5
            $res.StaleRemoved | Should -Be 2
        }

        It 'Client deduplicates redundant fix arguments' {
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\rpc.reg' } }

            $res = Set-PrinterClientRemediation -Fix 'RpcNamedPipe', 'RpcNamedPipe'
            $res.FixesApplied.Count | Should -Be 1
            $res.FixesApplied[0] | Should -Be 'RpcNamedPipe'
        }
    }

    # ==========================================================================
    # Context 4: Parameter Validation & Invalid Input Rejection
    # ==========================================================================
    Context '4. Parameter Validation & Invalid Input Rejection' {

        It 'Set-PrinterServerRemediation rejects invalid fix name via ValidateSet' {
            { Set-PrinterServerRemediation -Fix 'NonExistentFix' } | Should -Throw
        }

        It 'Set-PrinterClientRemediation rejects invalid fix name via ValidateSet' {
            { Set-PrinterClientRemediation -Fix 'BogusClientFix' } | Should -Throw
        }
    }

    # ==========================================================================
    # Context 5: -WhatIf Simulation Zero Side-Effect Guarantee
    # ==========================================================================
    Context '5. -WhatIf Simulation Zero Side-Effect Guarantee' {

        It 'Server -WhatIf executes zero registry modifications and zero service stops' {
            $regExecuted = $false
            $svcExecuted = $false
            Mock Set-ToolkitRegistryValue { $regExecuted = $true; return $null }
            Mock Stop-Service { $svcExecuted = $true }
            Mock Start-Service { $svcExecuted = $true }

            $res = Set-PrinterServerRemediation -All -WhatIf
            $regExecuted | Should -BeFalse
            $svcExecuted | Should -BeFalse
            $res.RegBackupFiles | Should -Contain '[Simulated - WhatIf]'
            $res.SpoolerRestarted | Should -BeFalse
        }

        It 'Client -WhatIf executes zero registry modifications and zero queue purges' {
            $regExecuted = $false
            $purgeExecuted = $false
            $neExecuted = $false
            $connExecuted = $false
            Mock Set-ToolkitRegistryValue { $regExecuted = $true; return $null }
            Mock Reset-PrintSpoolerQueue { $purgeExecuted = $true; return $null }
            Mock Reset-PrinterNePortBindings { $neExecuted = $true; return $null }
            Mock Reset-PrinterConnections { $connExecuted = $true; return $null }

            $res = Set-PrinterClientRemediation -All -WhatIf
            $regExecuted | Should -BeFalse
            $purgeExecuted | Should -BeFalse
            $neExecuted | Should -BeFalse
            $connExecuted | Should -BeFalse
            $res.RegBackupFiles | Should -Contain '[Simulated - WhatIf]'
            $res.QueuePurgedCount | Should -Be 0
        }
    }

    # ==========================================================================
    # Context 6: BackupDirectory Custom Routing
    # ==========================================================================
    Context '6. BackupDirectory Custom Routing' {

        It 'Server passes custom BackupDirectory to Set-ToolkitRegistryValue' {
            $script:passedBackupDir = $null
            Mock Set-ToolkitRegistryValue {
                param($KeyPath, $ValueName, $Value, $PropertyType, $BackupDirectory)
                $script:passedBackupDir = $BackupDirectory
                return [PSCustomObject]@{ RegBackupFile = "$BackupDirectory\test.reg" }
            }

            $customDir = 'C:\CustomBackups\Server'
            $res = Set-PrinterServerRemediation -Fix 'RpcAuthnLevel' -BackupDirectory $customDir
            $script:passedBackupDir | Should -Be $customDir
            $res.RegBackupFiles | Should -Contain "$customDir\test.reg"
        }

        It 'Client passes custom BackupDirectory to Set-ToolkitRegistryValue' {
            $script:passedBackupDir = $null
            Mock Set-ToolkitRegistryValue {
                param($KeyPath, $ValueName, $Value, $PropertyType, $BackupDirectory)
                $script:passedBackupDir = $BackupDirectory
                return [PSCustomObject]@{ RegBackupFile = "$BackupDirectory\client.reg" }
            }

            $customDir = 'C:\CustomBackups\Client'
            $res = Set-PrinterClientRemediation -Fix 'RpcNamedPipe' -BackupDirectory $customDir
            $script:passedBackupDir | Should -Be $customDir
            $res.RegBackupFiles | Should -Contain "$customDir\client.reg"
        }
    }
}
