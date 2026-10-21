# ==============================================================================
# ChallengerM1OfficeStress.Tests.ps1
# Adversarial Stress Testing for Milestone 1:
# - One-Click Quick App Repairs (Word, Excel, PowerPoint)
# - Suite-Wide Hardware Acceleration (Set-OfficeHardwareAcceleration)
# - Process-Safe Pre-Execution Guards under Hung and Active Processes
# ==============================================================================

BeforeAll {
    $script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:OfficeManifest = Join-Path $script:ProjectRoot 'Modules/Office/Office.psd1'
    $script:CoreManifest = Join-Path $script:ProjectRoot 'Modules/Core/Core.psd1'

    if (Test-Path -LiteralPath $script:CoreManifest) {
        Import-Module $script:CoreManifest -Force -DisableNameChecking
    }
    if (Test-Path -LiteralPath $script:OfficeManifest) {
        Import-Module $script:OfficeManifest -Force -DisableNameChecking
    }
}

Describe 'Milestone 1 Challenger: One-Click Quick App Repairs & Process Guards' {

    # --------------------------------------------------------------------------
    # 1. Hung Process Simulation & Forced Termination (-Force)
    # --------------------------------------------------------------------------
    Context 'Hung Process Simulation & Termination with -Force' {

        It 'Invoke-WordQuickRepair forcibly terminates hung WINWORD and completes all steps' {
            $terminatedProcs = [System.Collections.Generic.List[string]]::new()
            Mock Stop-OfficeProcess {
                param($ProcessNames, $Force, $TimeoutSeconds)
                if ($Force) {
                    foreach ($p in $ProcessNames) {
                        $terminatedProcs.Add($p)
                    }
                    return [PSCustomObject]@{ Status = 'Success'; Terminated = @($ProcessNames) }
                }
                return [PSCustomObject]@{ Status = 'Success'; Terminated = @() }
            }
            Mock Reset-WordTemplate { return [PSCustomObject]@{ Status = 'Success'; Backup = 'C:\Templates\Normal.dotm.bak' } }
            Mock Reset-WordStartupAddin { return [PSCustomObject]@{ Status = 'Success'; AddinsIsolated = 2 } }
            Mock Clear-WordOrphanedLocks { return [PSCustomObject]@{ Status = 'Success'; CleanedFiles = @('~$doc1.docx', '~$doc2.docx') } }
            Mock Reset-WordRegistryData { return [PSCustomObject]@{ Status = 'Success' } }

            $res = Invoke-WordQuickRepair -Force -PassThru

            $res | Should -Not -BeNullOrEmpty
            $res.Status | Should -Be 'Success'
            $terminatedProcs | Should -Contain 'WINWORD'
            $res.ProcessStopped.Terminated | Should -Contain 'WINWORD'
            $res.TemplateReset.Status | Should -Be 'Success'
            $res.AddinsIsolated.AddinsIsolated | Should -Be 2
            $res.LocksCleared.CleanedFiles.Count | Should -Be 2
            $res.RegistryReset.Status | Should -Be 'Success'
        }

        It 'Invoke-ExcelQuickRepair forcibly terminates hung EXCEL and completes all steps' {
            $terminatedProcs = [System.Collections.Generic.List[string]]::new()
            Mock Stop-OfficeProcess {
                param($ProcessNames, $Force, $TimeoutSeconds)
                if ($Force) {
                    foreach ($p in $ProcessNames) {
                        $terminatedProcs.Add($p)
                    }
                    return [PSCustomObject]@{ Status = 'Success'; Terminated = @($ProcessNames) }
                }
                return [PSCustomObject]@{ Status = 'Success'; Terminated = @() }
            }
            Mock Clear-ExcelStartupFolder { return [PSCustomObject]@{ Status = 'Success'; RemovedFiles = @('bad.xlam'); PersonalBackupPath = 'C:\Personal.xlsb.bak' } }
            Mock Reset-ExcelUiCache { return [PSCustomObject]@{ Status = 'Success'; QuarantinedFiles = @('Excel16.xlb') } }
            Mock Reset-ExcelDdeSettings { return [PSCustomObject]@{ Status = 'Success'; IgnoreRemoteRequests = 0; Calculation = 1 } }
            Mock Reset-ExcelResiliency { return [PSCustomObject]@{ Status = 'Success'; ClearedItemsCount = 3 } }

            $res = Invoke-ExcelQuickRepair -Force -PassThru

            $res | Should -Not -BeNullOrEmpty
            $res.Status | Should -Be 'Success'
            $terminatedProcs | Should -Contain 'EXCEL'
            $res.ProcessStopped.Terminated | Should -Contain 'EXCEL'
            $res.XlStartCleared.PersonalBackupPath | Should -Be 'C:\Personal.xlsb.bak'
            $res.UiCacheReset.QuarantinedFiles | Should -Contain 'Excel16.xlb'
            $res.DdeReset.Calculation | Should -Be 1
            $res.ResiliencyReset.ClearedItemsCount | Should -Be 3
        }

        It 'Invoke-PowerPointQuickRepair forcibly terminates hung POWERPNT and completes all steps' {
            $terminatedProcs = [System.Collections.Generic.List[string]]::new()
            Mock Stop-OfficeProcess {
                param($ProcessNames, $Force, $TimeoutSeconds)
                if ($Force) {
                    foreach ($p in $ProcessNames) {
                        $terminatedProcs.Add($p)
                    }
                    return [PSCustomObject]@{ Status = 'Success'; Terminated = @($ProcessNames) }
                }
                return [PSCustomObject]@{ Status = 'Success'; Terminated = @() }
            }
            Mock Reset-PowerPointCache { return [PSCustomObject]@{ Status = 'Success'; CleanedFilesCount = 5; BytesFreed = 10240 } }
            Mock Reset-PowerPointResiliency { return [PSCustomObject]@{ Status = 'Success'; ClearedItems = 2 } }

            $res = Invoke-PowerPointQuickRepair -Force -PassThru

            $res | Should -Not -BeNullOrEmpty
            $res.Status | Should -Be 'Success'
            $terminatedProcs | Should -Contain 'POWERPNT'
            $res.ProcessStopped.Terminated | Should -Contain 'POWERPNT'
            $res.CacheReset.CleanedFilesCount | Should -Be 5
            $res.ResiliencyReset.ClearedItems | Should -Be 2
        }
    }

    # --------------------------------------------------------------------------
    # 2. Active Process without -Force (Must Warn and Not Crash)
    # --------------------------------------------------------------------------
    Context 'Active / Hung Process without -Force Safety' {

        It 'Invoke-WordQuickRepair returns Warning status and does not throw when template reports active process' {
            Mock Stop-OfficeProcess { return [PSCustomObject]@{ Status = 'Success'; Terminated = @() } }
            Mock Reset-WordTemplate { return [PSCustomObject]@{ Status = 'Warning'; Backup = $null; ErrorMessage = 'Cannot reset Normal.dotm while Word is running.' } }
            Mock Reset-WordStartupAddin { return [PSCustomObject]@{ Status = 'Skipped'; AddinsIsolated = 0 } }
            Mock Clear-WordOrphanedLocks { return [PSCustomObject]@{ Status = 'Success'; CleanedFiles = @() } }
            Mock Reset-WordRegistryData { return [PSCustomObject]@{ Status = 'Success' } }

            $script:res = $null
            { $script:res = Invoke-WordQuickRepair } | Should -Not -Throw

            $script:res | Should -Not -BeNullOrEmpty
            $script:res.Status | Should -Be 'Warning'
            $script:res.TemplateReset.Status | Should -Be 'Warning'
        }

        It 'Invoke-ExcelQuickRepair returns Warning status and does not throw when DDE reports active process' {
            Mock Stop-OfficeProcess { return [PSCustomObject]@{ Status = 'Success'; Terminated = @() } }
            Mock Clear-ExcelStartupFolder { return [PSCustomObject]@{ Status = 'Success'; RemovedFiles = @() } }
            Mock Reset-ExcelUiCache { return [PSCustomObject]@{ Status = 'Success'; QuarantinedFiles = @() } }
            Mock Reset-ExcelDdeSettings { return [PSCustomObject]@{ Status = 'Warning'; ErrorMessage = 'Active EXCEL process detected.' } }
            Mock Reset-ExcelResiliency { return [PSCustomObject]@{ Status = 'Warning'; ErrorMessage = 'Active EXCEL process detected.' } }

            $script:res = $null
            { $script:res = Invoke-ExcelQuickRepair } | Should -Not -Throw

            $script:res | Should -Not -BeNullOrEmpty
            $script:res.Status | Should -Be 'Warning'
            $script:res.DdeReset.Status | Should -Be 'Warning'
        }

        It 'Invoke-PowerPointQuickRepair returns Warning status and does not throw when Resiliency reports active process' {
            Mock Stop-OfficeProcess { return [PSCustomObject]@{ Status = 'Success'; Terminated = @() } }
            Mock Reset-PowerPointCache { return [PSCustomObject]@{ Status = 'Success'; CleanedFilesCount = 0 } }
            Mock Reset-PowerPointResiliency { return [PSCustomObject]@{ Status = 'Warning'; ErrorMessage = 'Active POWERPNT process detected.' } }

            $script:res = $null
            { $script:res = Invoke-PowerPointQuickRepair } | Should -Not -Throw

            $script:res | Should -Not -BeNullOrEmpty
            $script:res.Status | Should -Be 'Warning'
            $script:res.ResiliencyReset.Status | Should -Be 'Warning'
        }
    }

    # --------------------------------------------------------------------------
    # 3. Telemetry Schema & Return Object Integrity
    # --------------------------------------------------------------------------
    Context 'PSCustomObject Telemetry Schema Integrity' {

        It 'Invoke-WordQuickRepair produces all expected telemetry properties' {
            Mock Stop-OfficeProcess { return [PSCustomObject]@{ Status = 'Success'; Terminated = @('WINWORD') } }
            Mock Reset-WordTemplate { return [PSCustomObject]@{ Status = 'Success'; Backup = 'C:\Normal.dotm.bak' } }
            Mock Reset-WordStartupAddin { return [PSCustomObject]@{ Status = 'Success'; AddinsIsolated = 0 } }
            Mock Clear-WordOrphanedLocks { return [PSCustomObject]@{ Status = 'Success'; CleanedFiles = @() } }
            Mock Reset-WordRegistryData { return [PSCustomObject]@{ Status = 'Success' } }

            $res = Invoke-WordQuickRepair -Force
            $res.PSObject.Properties.Name | Should -Contain 'Status'
            $res.PSObject.Properties.Name | Should -Contain 'ProcessStopped'
            $res.PSObject.Properties.Name | Should -Contain 'TemplateReset'
            $res.PSObject.Properties.Name | Should -Contain 'AddinsIsolated'
            $res.PSObject.Properties.Name | Should -Contain 'LocksCleared'
            $res.PSObject.Properties.Name | Should -Contain 'RegistryReset'
        }

        It 'Invoke-ExcelQuickRepair produces all expected telemetry properties' {
            Mock Stop-OfficeProcess { return [PSCustomObject]@{ Status = 'Success'; Terminated = @('EXCEL') } }
            Mock Clear-ExcelStartupFolder { return [PSCustomObject]@{ Status = 'Success'; RemovedFiles = @() } }
            Mock Reset-ExcelUiCache { return [PSCustomObject]@{ Status = 'Success'; QuarantinedFiles = @() } }
            Mock Reset-ExcelDdeSettings { return [PSCustomObject]@{ Status = 'Success'; IgnoreRemoteRequests = 0 } }
            Mock Reset-ExcelResiliency { return [PSCustomObject]@{ Status = 'Success'; ClearedItemsCount = 0 } }

            $res = Invoke-ExcelQuickRepair -Force
            $res.PSObject.Properties.Name | Should -Contain 'Status'
            $res.PSObject.Properties.Name | Should -Contain 'ProcessStopped'
            $res.PSObject.Properties.Name | Should -Contain 'XlStartCleared'
            $res.PSObject.Properties.Name | Should -Contain 'UiCacheReset'
            $res.PSObject.Properties.Name | Should -Contain 'DdeReset'
            $res.PSObject.Properties.Name | Should -Contain 'ResiliencyReset'
        }

        It 'Invoke-PowerPointQuickRepair produces all expected telemetry properties' {
            Mock Stop-OfficeProcess { return [PSCustomObject]@{ Status = 'Success'; Terminated = @('POWERPNT') } }
            Mock Reset-PowerPointCache { return [PSCustomObject]@{ Status = 'Success'; CleanedFilesCount = 0 } }
            Mock Reset-PowerPointResiliency { return [PSCustomObject]@{ Status = 'Success'; ClearedItems = 0 } }

            $res = Invoke-PowerPointQuickRepair -Force
            $res.PSObject.Properties.Name | Should -Contain 'Status'
            $res.PSObject.Properties.Name | Should -Contain 'ProcessStopped'
            $res.PSObject.Properties.Name | Should -Contain 'CacheReset'
            $res.PSObject.Properties.Name | Should -Contain 'ResiliencyReset'
        }
    }

    # --------------------------------------------------------------------------
    # 4. -WhatIf Dry-Run Simulation Guarantees
    # --------------------------------------------------------------------------
    Context '-WhatIf / ShouldProcess Invariance' {

        It 'Invoke-WordQuickRepair -WhatIf returns Simulated and makes zero calls to child cmdlets' {
            Mock Stop-OfficeProcess { throw "Stop-OfficeProcess must not be called under WhatIf" }
            Mock Reset-WordTemplate { throw "Reset-WordTemplate must not be called under WhatIf" }
            Mock Reset-WordStartupAddin { throw "Reset-WordStartupAddin must not be called under WhatIf" }
            Mock Clear-WordOrphanedLocks { throw "Clear-WordOrphanedLocks must not be called under WhatIf" }
            Mock Reset-WordRegistryData { throw "Reset-WordRegistryData must not be called under WhatIf" }

            $res = Invoke-WordQuickRepair -WhatIf
            $res.Status | Should -Be 'Simulated'
            $res.ProcessStopped | Should -Be '[Simulated - WhatIf]'
            $res.TemplateReset | Should -Be '[Simulated - WhatIf]'
            $res.AddinsIsolated | Should -Be '[Simulated - WhatIf]'
            $res.LocksCleared | Should -Be '[Simulated - WhatIf]'
            $res.RegistryReset | Should -Be '[Simulated - WhatIf]'
        }

        It 'Invoke-ExcelQuickRepair -WhatIf returns Simulated and makes zero calls to child cmdlets' {
            Mock Stop-OfficeProcess { throw "Stop-OfficeProcess must not be called under WhatIf" }
            Mock Clear-ExcelStartupFolder { throw "Clear-ExcelStartupFolder must not be called under WhatIf" }
            Mock Reset-ExcelUiCache { throw "Reset-ExcelUiCache must not be called under WhatIf" }
            Mock Reset-ExcelDdeSettings { throw "Reset-ExcelDdeSettings must not be called under WhatIf" }
            Mock Reset-ExcelResiliency { throw "Reset-ExcelResiliency must not be called under WhatIf" }

            $res = Invoke-ExcelQuickRepair -WhatIf
            $res.Status | Should -Be 'Simulated'
            $res.ProcessStopped | Should -Be '[Simulated - WhatIf]'
            $res.XlStartCleared | Should -Be '[Simulated - WhatIf]'
            $res.UiCacheReset | Should -Be '[Simulated - WhatIf]'
            $res.DdeReset | Should -Be '[Simulated - WhatIf]'
            $res.ResiliencyReset | Should -Be '[Simulated - WhatIf]'
        }

        It 'Invoke-PowerPointQuickRepair -WhatIf returns Simulated and makes zero calls to child cmdlets' {
            Mock Stop-OfficeProcess { throw "Stop-OfficeProcess must not be called under WhatIf" }
            Mock Reset-PowerPointCache { throw "Reset-PowerPointCache must not be called under WhatIf" }
            Mock Reset-PowerPointResiliency { throw "Reset-PowerPointResiliency must not be called under WhatIf" }

            $res = Invoke-PowerPointQuickRepair -WhatIf
            $res.Status | Should -Be 'Simulated'
            $res.ProcessStopped | Should -Be '[Simulated - WhatIf]'
            $res.CacheReset | Should -Be '[Simulated - WhatIf]'
            $res.ResiliencyReset | Should -Be '[Simulated - WhatIf]'
        }
    }

    # --------------------------------------------------------------------------
    # 5. Set-OfficeHardwareAcceleration Rigorous Verification
    # --------------------------------------------------------------------------
    Context 'Set-OfficeHardwareAcceleration State & Registry Verification' {

        It 'Default call (no parameters) sets DisableHardwareAcceleration = 1 across all 4 keys' {
            $recordedCalls = [System.Collections.Generic.List[psobject]]::new()
            Mock Set-ToolkitRegistryValue {
                param($KeyPath, $ValueName, $Value, $PropertyType)
                $recordedCalls.Add([PSCustomObject]@{ KeyPath = $KeyPath; ValueName = $ValueName; Value = $Value })
                return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\OfficeGfx.reg' }
            }

            $res = Set-OfficeHardwareAcceleration -PassThru

            $res.Status | Should -Be 'Success'
            $res.Disabled | Should -BeTrue
            $res.RegBackupFile | Should -Be 'C:\Backups\OfficeGfx.reg'

            # Must configure Common\Graphics, Word\Options, Excel\Options, PowerPoint\Options
            $recordedCalls | Where-Object { $_.KeyPath -like '*Common\Graphics' -and $_.ValueName -eq 'DisableHardwareAcceleration' -and $_.Value -eq 1 } | Should -Not -BeNullOrEmpty
            $recordedCalls | Where-Object { $_.KeyPath -like '*Word\Options' -and $_.ValueName -eq 'DisableHardwareAcceleration' -and $_.Value -eq 1 } | Should -Not -BeNullOrEmpty
            $recordedCalls | Where-Object { $_.KeyPath -like '*Excel\Options' -and $_.ValueName -eq 'DisableHardwareAcceleration' -and $_.Value -eq 1 } | Should -Not -BeNullOrEmpty
            $recordedCalls | Where-Object { $_.KeyPath -like '*PowerPoint\Options' -and $_.ValueName -eq 'DisableHardwareAcceleration' -and $_.Value -eq 1 } | Should -Not -BeNullOrEmpty
            # PowerPoint slide show acceleration must also be disabled (1)
            $recordedCalls | Where-Object { $_.KeyPath -like '*PowerPoint\Options' -and $_.ValueName -eq 'DisableSlideShowHardwareAcceleration' -and $_.Value -eq 1 } | Should -Not -BeNullOrEmpty
        }

        It 'Explicit -Disable switch sets values to 1' {
            $recordedCalls = [System.Collections.Generic.List[psobject]]::new()
            Mock Set-ToolkitRegistryValue {
                param($KeyPath, $ValueName, $Value, $PropertyType)
                $recordedCalls.Add([PSCustomObject]@{ KeyPath = $KeyPath; ValueName = $ValueName; Value = $Value })
                return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\OfficeGfx.reg' }
            }

            $res = Set-OfficeHardwareAcceleration -Disable -PassThru

            $res.Status | Should -Be 'Success'
            $res.Disabled | Should -BeTrue
            $recordedCalls | Where-Object { $_.KeyPath -like '*Common\Graphics' -and $_.Value -eq 1 } | Should -Not -BeNullOrEmpty
        }

        It 'Explicit -Enable switch sets values to 0 across all keys' {
            $recordedCalls = [System.Collections.Generic.List[psobject]]::new()
            Mock Set-ToolkitRegistryValue {
                param($KeyPath, $ValueName, $Value, $PropertyType)
                $recordedCalls.Add([PSCustomObject]@{ KeyPath = $KeyPath; ValueName = $ValueName; Value = $Value })
                return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\OfficeGfx.reg' }
            }

            $res = Set-OfficeHardwareAcceleration -Enable -PassThru

            $res.Status | Should -Be 'Success'
            $res.Disabled | Should -BeFalse
            $recordedCalls | Where-Object { $_.KeyPath -like '*Common\Graphics' -and $_.Value -eq 0 } | Should -Not -BeNullOrEmpty
            $recordedCalls | Where-Object { $_.KeyPath -like '*Word\Options' -and $_.Value -eq 0 } | Should -Not -BeNullOrEmpty
            $recordedCalls | Where-Object { $_.KeyPath -like '*Excel\Options' -and $_.Value -eq 0 } | Should -Not -BeNullOrEmpty
            $recordedCalls | Where-Object { $_.KeyPath -like '*PowerPoint\Options' -and $_.Value -eq 0 } | Should -Not -BeNullOrEmpty
            $recordedCalls | Where-Object { $_.KeyPath -like '*PowerPoint\Options' -and $_.ValueName -eq 'DisableSlideShowHardwareAcceleration' -and $_.Value -eq 0 } | Should -Not -BeNullOrEmpty
        }

        It '-Disable:$false enables hardware acceleration (value = 0)' {
            $recordedCalls = [System.Collections.Generic.List[psobject]]::new()
            Mock Set-ToolkitRegistryValue {
                param($KeyPath, $ValueName, $Value, $PropertyType)
                $recordedCalls.Add([PSCustomObject]@{ KeyPath = $KeyPath; Value = $Value })
                return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\OfficeGfx.reg' }
            }

            $res = Set-OfficeHardwareAcceleration -Disable:$false -PassThru
            $res.Disabled | Should -BeFalse
        }

        It '-Enable:$false disables hardware acceleration (value = 1)' {
            $recordedCalls = [System.Collections.Generic.List[psobject]]::new()
            Mock Set-ToolkitRegistryValue {
                param($KeyPath, $ValueName, $Value, $PropertyType)
                $recordedCalls.Add([PSCustomObject]@{ KeyPath = $KeyPath; Value = $Value })
                return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\OfficeGfx.reg' }
            }

            $res = Set-OfficeHardwareAcceleration -Enable:$false -PassThru
            $res.Disabled | Should -BeTrue
        }

        It 'Set-OfficeHardwareAcceleration -WhatIf performs zero registry writes' {
            Mock Set-ToolkitRegistryValue { throw "Set-ToolkitRegistryValue must not be called under WhatIf" }

            $res = Set-OfficeHardwareAcceleration -WhatIf
            $res.Status | Should -Be 'Simulated'
            $res.RegBackupFile | Should -Be '[Simulated - WhatIf]'
        }
    }

    # --------------------------------------------------------------------------
    # 6. Process Guard Behavior in Mutating Domain Cmdlets
    # --------------------------------------------------------------------------
    Context 'Domain Cmdlets Process Guard Under Active & Terminated Processes' {

        It 'Reset-ExcelDdeSettings warns without modifying registry when EXCEL is active without -Force' {
            Mock Get-Process {
                param($Name)
                if ($Name -eq 'EXCEL') { return @([PSCustomObject]@{ Id = 2001; ProcessName = 'EXCEL' }) }
                return @()
            }
            Mock Set-ToolkitRegistryValue { throw "Registry must not be written when active process detected without Force" }

            $res = Reset-ExcelDdeSettings -WarningAction SilentlyContinue

            $res.Status | Should -Be 'Warning'
            $res.ErrorMessage | Should -Match 'Active EXCEL process detected'
            $res.IgnoreRemoteRequests | Should -BeNullOrEmpty
        }

        It 'Reset-ExcelDdeSettings terminates EXCEL and succeeds when -Force is passed' {
            $procsKilled = [System.Collections.Generic.List[string]]::new()
            Mock Get-Process {
                param($Name)
                if ($Name -eq 'EXCEL') { return @([PSCustomObject]@{ Id = 2001; ProcessName = 'EXCEL' }) }
                return @()
            }
            Mock Stop-OfficeProcess {
                param($ProcessNames, $Force)
                foreach ($p in $ProcessNames) { $procsKilled.Add($p) }
                return [PSCustomObject]@{ Status = 'Success'; Terminated = @($ProcessNames) }
            }
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\Dde.reg' } }

            $res = Reset-ExcelDdeSettings -Force
            $res.Status | Should -Be 'Success'
            $procsKilled | Should -Contain 'EXCEL'
            $res.IgnoreRemoteRequests | Should -Be 0
            $res.Calculation | Should -Be 1
        }

        It 'Reset-ExcelResiliency warns without modifying registry when EXCEL is active without -Force' {
            Mock Get-Process {
                param($Name)
                if ($Name -eq 'EXCEL') { return @([PSCustomObject]@{ Id = 2001; ProcessName = 'EXCEL' }) }
                return @()
            }
            Mock Remove-ItemProperty { throw "Registry must not be written when active process detected without Force" }

            $res = Reset-ExcelResiliency -WarningAction SilentlyContinue
            $res.Status | Should -Be 'Warning'
            $res.ErrorMessage | Should -Match 'Active EXCEL process detected'
            $res.ClearedItemsCount | Should -Be 0
        }

        It 'Reset-PowerPointResiliency warns without modifying registry when POWERPNT is active without -Force' {
            Mock Get-Process {
                param($Name)
                if ($Name -eq 'POWERPNT') { return @([PSCustomObject]@{ Id = 3001; ProcessName = 'POWERPNT' }) }
                return @()
            }
            Mock Remove-ItemProperty { throw "Registry must not be written when active process detected without Force" }

            $res = Reset-PowerPointResiliency -WarningAction SilentlyContinue
            $res.Status | Should -Be 'Warning'
            $res.ErrorMessage | Should -Match 'Active POWERPNT process detected'
            $res.ClearedItems | Should -Be 0
        }

        It 'Clear-OfficeTempCache warns without deleting files when multiple Office apps are active without -Force' {
            Mock Get-Process {
                param($Name)
                if ($Name -in @('WINWORD', 'EXCEL')) { return @([PSCustomObject]@{ Id = 4001; ProcessName = $Name }) }
                return @()
            }
            Mock Remove-Item { throw "Files must not be deleted when active process detected without Force" }

            $res = Clear-OfficeTempCache -WarningAction SilentlyContinue
            $res.Status | Should -Be 'Warning'
            $res.ErrorMessage | Should -Match 'Active Office process'
            $res.CleanedFilesCount | Should -Be 0
        }

        It 'Clear-OfficeTempCache terminates all active Office apps when -Force is passed' {
            $procsKilled = [System.Collections.Generic.List[string]]::new()
            Mock Get-Process {
                param($Name)
                if ($Name -in @('WINWORD', 'EXCEL', 'POWERPNT')) { return @([PSCustomObject]@{ Id = 4001; ProcessName = $Name }) }
                return @()
            }
            Mock Stop-OfficeProcess {
                param($ProcessNames, $Force)
                foreach ($p in $ProcessNames) { $procsKilled.Add($p) }
                return [PSCustomObject]@{ Status = 'Success'; Terminated = @($ProcessNames) }
            }
            Mock Test-Path { return $true }
            Mock Get-ChildItem { return @([PSCustomObject]@{ Length = 2048; FullName = '/tmp/test_cache.tmp' }) }
            Mock Remove-Item { }

            $res = Clear-OfficeTempCache -Force
            $res.Status | Should -Be 'Success'
            $procsKilled | Should -Contain 'WINWORD'
            $procsKilled | Should -Contain 'EXCEL'
            $procsKilled | Should -Contain 'POWERPNT'
            $res.CleanedFilesCount | Should -BeGreaterThan 0
        }
    }

    # --------------------------------------------------------------------------
    # 7. Unhandled Child Step Exceptions & Pipeline Safety
    # --------------------------------------------------------------------------
    Context 'Child Step Exception Handling & Pipeline Streaming' {

        It 'Invoke-WordQuickRepair catches unexpected exception in child step and returns Warning status' {
            Mock Stop-OfficeProcess { throw "Catastrophic process inspection failure" }
            Mock Reset-WordTemplate { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Reset-WordStartupAddin { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Clear-WordOrphanedLocks { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Reset-WordRegistryData { return [PSCustomObject]@{ Status = 'Success' } }

            $script:res = $null
            { $script:res = Invoke-WordQuickRepair -Force } | Should -Not -Throw

            $script:res.Status | Should -Be 'Warning'
            $script:res.ProcessStopped.Status | Should -Be 'Warning'
            $script:res.ProcessStopped.ErrorMessage | Should -Match 'Catastrophic process inspection failure'
        }

        It 'Invoke-ExcelQuickRepair catches unexpected exception in child step and returns Warning status' {
            Mock Stop-OfficeProcess { return [PSCustomObject]@{ Status = 'Success'; Terminated = @('EXCEL') } }
            Mock Clear-ExcelStartupFolder { throw "IO lock failure in XLSTART" }
            Mock Reset-ExcelUiCache { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Reset-ExcelDdeSettings { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Reset-ExcelResiliency { return [PSCustomObject]@{ Status = 'Success' } }

            $script:res = $null
            { $script:res = Invoke-ExcelQuickRepair -Force } | Should -Not -Throw

            $script:res.Status | Should -Be 'Warning'
            $script:res.XlStartCleared.Status | Should -Be 'Warning'
            $script:res.XlStartCleared.ErrorMessage | Should -Match 'IO lock failure'
        }

        It 'Invoke-PowerPointQuickRepair catches unexpected exception in child step and returns Warning status' {
            Mock Stop-OfficeProcess { return [PSCustomObject]@{ Status = 'Success'; Terminated = @('POWERPNT') } }
            Mock Reset-PowerPointCache { throw "Cache directory access denied" }
            Mock Reset-PowerPointResiliency { return [PSCustomObject]@{ Status = 'Success' } }

            $script:res = $null
            { $script:res = Invoke-PowerPointQuickRepair -Force } | Should -Not -Throw

            $script:res.Status | Should -Be 'Warning'
            $script:res.CacheReset.Status | Should -Be 'Warning'
            $script:res.CacheReset.ErrorMessage | Should -Match 'Cache directory access denied'
        }

        It 'Pipeline streaming properly passes output objects downstream' {
            Mock Stop-OfficeProcess { return [PSCustomObject]@{ Status = 'Success'; Terminated = @() } }
            Mock Reset-WordTemplate { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Reset-WordStartupAddin { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Clear-WordOrphanedLocks { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Reset-WordRegistryData { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Set-ToolkitRegistryValue { return [PSCustomObject]@{ RegBackupFile = 'C:\Backups\OfficeGfx.reg' } }

            $wordStatus = Invoke-WordQuickRepair -Force | Select-Object -ExpandProperty Status
            $wordStatus | Should -Be 'Success'

            $gfxDisabled = Set-OfficeHardwareAcceleration | Select-Object -ExpandProperty Disabled
            $gfxDisabled | Should -BeTrue
        }
    }
}
