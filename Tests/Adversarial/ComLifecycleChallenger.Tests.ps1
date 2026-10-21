# ==============================================================================
# ComLifecycleChallenger.Tests.ps1
# Empirical Adversarial Challenge Suite: COM Lifecycle & RCW Release
# Targets:
#   1. Set-OutlookDefaultDataFile.ps1
#   2. Clear-OutlookStuckOutbox.ps1
#   3. Export-OutlookRule.ps1
# ==============================================================================

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $modulePath = Join-Path -Path $root 'Modules/Outlook/Outlook.psd1'
    Import-Module $modulePath -Force

    $corePath = Join-Path -Path $root 'Modules/Core/Core.psd1'
    if (Test-Path -LiteralPath $corePath) {
        Import-Module $corePath -Force
    }

    # Ensure C: drive alias exists for cross-platform test environments
    if (-not (Get-PSDrive -Name 'C' -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name 'C' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -ErrorAction SilentlyContinue | Out-Null
    }

    # Helper: Build an observable mock COM tree with call trackers using closures
    function script:New-ChallengerComHarness {
        param(
            [string]$StorePath = 'C:\Data\TestStore.pst',
            [string]$StoreName = 'Test Corporate Store'
        )

        $tracker = [PSCustomObject]@{
            QuitCalls         = 0
            LogonCalls        = 0
            LogoffCalls       = 0
            DeletedItemCount  = 0
            QuitShouldThrow   = $false
            LogoffShouldThrow = $false
        }

        # Outbox item mock
        $mockItem1 = [PSCustomObject]@{ Subject = 'Stuck Message 1' }
        $mockItem1 | Add-Member -MemberType ScriptMethod -Name Delete -Value ({
            $tracker.DeletedItemCount++
        }.GetNewClosure())

        # Outbox folder mock
        $mockOutbox = [PSCustomObject]@{
            Name  = 'Outbox'
            Items = [System.Collections.Generic.List[object]]@($mockItem1)
        }

        # Folder hierarchy mock
        $mockChildFolder = [PSCustomObject]@{
            Name       = 'SubFolder'
            FolderPath = "\\$StoreName\Inbox\SubFolder"
            Folders    = [System.Collections.Generic.List[object]]::new()
        }
        $mockInbox = [PSCustomObject]@{
            Name       = 'Inbox'
            FolderPath = "\\$StoreName\Inbox"
            Folders    = [System.Collections.Generic.List[object]]@($mockChildFolder)
        }
        $mockRootFolder = [PSCustomObject]@{
            Name    = $StoreName
            Folders = [System.Collections.Generic.List[object]]@($mockInbox)
        }

        # Rules mock
        $mockRule = [PSCustomObject]@{
            Name           = 'Test Rule'
            RuleType       = 0
            Enabled        = $true
            ExecutionOrder = 1
            Conditions     = [PSCustomObject]@{
                Subject = [PSCustomObject]@{ Enabled = $true; Text = @('Test') }
            }
            Exceptions     = [PSCustomObject]@{}
            Actions        = [PSCustomObject]@{
                MoveToFolder = [PSCustomObject]@{
                    Enabled = $true
                    Folder  = $mockChildFolder
                }
            }
        }
        $mockRulesList = [System.Collections.Generic.List[object]]@($mockRule)
        $mockRules = [PSCustomObject]@{
            Count     = $mockRulesList.Count
            RulesList = $mockRulesList
        }
        $mockRules | Add-Member -MemberType ScriptMethod -Name GetEnumerator -Value { $this.RulesList.GetEnumerator() }
        $mockRules | Add-Member -MemberType ScriptMethod -Name Item -Value { param($idx) return $this.RulesList[$idx] }

        # Store mock
        $mockStore = [PSCustomObject]@{
            DisplayName    = $StoreName
            FilePath       = $StorePath
            IsDefaultStore = $true
            RootFolder     = $mockRootFolder
            Rules          = $mockRules
        }
        $mockStore | Add-Member -MemberType ScriptMethod -Name GetRootFolder -Value { return $this.RootFolder }
        $mockStore | Add-Member -MemberType ScriptMethod -Name GetRules -Value { return $this.Rules }

        $mockStores = @($mockStore)

        # Namespace mock
        $mockNs = [PSCustomObject]@{
            DefaultStore = $mockStore
            Stores       = $mockStores
            Outbox       = $mockOutbox
        }
        $mockNs | Add-Member -MemberType ScriptMethod -Name Logon -Value ({
            param($profile, $pwd, $ui, $newSession)
            $tracker.LogonCalls++
        }.GetNewClosure())
        $mockNs | Add-Member -MemberType ScriptMethod -Name Logoff -Value ({
            $tracker.LogoffCalls++
            if ($tracker.LogoffShouldThrow) {
                throw [System.Runtime.InteropServices.COMException]::new("RPC server unavailable during logoff.")
            }
        }.GetNewClosure())
        $mockNs | Add-Member -MemberType ScriptMethod -Name GetDefaultFolder -Value {
            param($folderType)
            return $this.Outbox
        }

        # Application mock
        $mockApp = [PSCustomObject]@{
            MapiNamespace = $mockNs
        }
        $mockApp | Add-Member -MemberType ScriptMethod -Name GetNamespace -Value {
            param($type)
            return $this.MapiNamespace
        }
        $mockApp | Add-Member -MemberType ScriptMethod -Name Quit -Value ({
            $tracker.QuitCalls++
            if ($tracker.QuitShouldThrow) {
                throw [System.Runtime.InteropServices.COMException]::new("The RPC server is unavailable. (Exception from HRESULT: 0x800706BA)")
            }
        }.GetNewClosure())

        return @{
            Tracker    = $tracker
            App        = $mockApp
            Namespace  = $mockNs
            Store      = $mockStore
            Stores     = $mockStores
            RootFolder = $mockRootFolder
            Rules      = $mockRules
            Outbox     = $mockOutbox
        }
    }
}

# ==============================================================================
# Suite 1: Set-OutlookDefaultDataFile COM Lifecycle & Exception Robustness
# ==============================================================================
Describe 'Adversarial: Set-OutlookDefaultDataFile COM Lifecycle' {

    Context 'Conditional Quit() Execution' {
        It 'Calls Quit() when Outlook was NOT running prior to invocation' {
            $harness = New-ChallengerComHarness
            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Test-Path { return $true }

            $res = Set-OutlookDefaultDataFile -Path $harness.Store.FilePath
            $harness.Tracker.QuitCalls | Should -Be 1
        }

        It 'Skips calling Quit() when Outlook WAS already running before invocation' {
            $harness = New-ChallengerComHarness
            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @([PSCustomObject]@{ Id = 1001; ProcessName = 'OUTLOOK' }) } -ModuleName 'Outlook'
            Mock Get-Process { return @([PSCustomObject]@{ Id = 1001; ProcessName = 'OUTLOOK' }) }
            Mock Test-Path { return $true }

            $res = Set-OutlookDefaultDataFile -Path $harness.Store.FilePath
            $harness.Tracker.QuitCalls | Should -Be 0
        }

        It 'Survives and suppresses exceptions if Quit() throws during cleanup' {
            $harness = New-ChallengerComHarness
            $harness.Tracker.QuitShouldThrow = $true
            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Test-Path { return $true }

            { $res = Set-OutlookDefaultDataFile -Path $harness.Store.FilePath } | Should -Not -Throw
            $harness.Tracker.QuitCalls | Should -Be 1
        }
    }

    Context 'RCW Reference Release' {
        It 'Passes store, stores, ns, and comApp to Remove-ToolkitComObject' {
            $harness = New-ChallengerComHarness
            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Test-Path { return $true }

            $releasedObjs = [System.Collections.Generic.List[object]]::new()
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { $releasedObjs.Add($o) }
                }
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { $releasedObjs.Add($o) }
                }
            }

            $res = Set-OutlookDefaultDataFile -Path $harness.Store.FilePath
            $releasedObjs | Should -Contain $harness.App
            $releasedObjs | Should -Contain $harness.Namespace
            $releasedObjs | Should -Contain $harness.Store
            $releasedObjs | Should -Contain $harness.Stores
        }

        It 'Executes fallback release cleanly when Remove-ToolkitComObject command is unavailable' {
            $harness = New-ChallengerComHarness
            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Test-Path { return $true }
            Mock Get-Command {
                param($Name)
                if ($Name -eq 'Remove-ToolkitComObject') { return $null }
                return (Microsoft.PowerShell.Core\Get-Command @PSBoundParameters)
            } -ModuleName 'Outlook'

            { $res = Set-OutlookDefaultDataFile -Path $harness.Store.FilePath } | Should -Not -Throw
        }
    }

    Context 'Fault Injection: Exception in Try Block' {
        It 'Executes finally cleanup and releases comApp when GetNamespace throws' {
            $harness = New-ChallengerComHarness
            $harness.App | Add-Member -MemberType ScriptMethod -Name GetNamespace -Value {
                throw [System.InvalidOperationException]::new("Simulated MAPI failure")
            } -Force
            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Test-Path { return $true }

            $releasedObjs = [System.Collections.Generic.List[object]]::new()
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { $releasedObjs.Add($o) }
                }
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { $releasedObjs.Add($o) }
                }
            }

            # Should catch error in try and proceed to guided fallback without throwing unhandled
            $res = Set-OutlookDefaultDataFile -Path $harness.Store.FilePath
            $harness.Tracker.QuitCalls | Should -Be 1
            $releasedObjs | Should -Contain $harness.App
        }

        It 'Executes finally cleanup and releases objects when store enumeration throws' {
            $harness = New-ChallengerComHarness
            $harness.Namespace.Stores[0] | Add-Member -MemberType ScriptProperty -Name FilePath -Value {
                throw [System.Runtime.InteropServices.COMException]::new("Corrupted store property")
            } -Force
            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Test-Path { return $true }

            $releasedObjs = [System.Collections.Generic.List[object]]::new()
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { $releasedObjs.Add($o) }
                }
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { $releasedObjs.Add($o) }
                }
            }

            $res = Set-OutlookDefaultDataFile -Path 'C:\Data\TestStore.pst'
            $harness.Tracker.QuitCalls | Should -Be 1
            $releasedObjs | Should -Contain $harness.App
            $releasedObjs | Should -Contain $harness.Namespace
        }
    }
}

# ==============================================================================
# Suite 2: Clear-OutlookStuckOutbox COM Lifecycle & Exception Robustness
# ==============================================================================
Describe 'Adversarial: Clear-OutlookStuckOutbox COM Lifecycle' {

    Context 'Conditional Quit() Execution' {
        It 'Calls Quit() when Outlook was NOT running before invocation' {
            $harness = New-ChallengerComHarness
            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Test-Path { return $true }

            $res = Clear-OutlookStuckOutbox -ProfileName 'CorporateProfile'
            $harness.Tracker.QuitCalls | Should -Be 1
            $harness.Tracker.LogoffCalls | Should -Be 1
        }

        It 'Skips calling Quit() when Outlook WAS running before invocation' {
            # Outlook is running, -Force is not passed -> warns and returns early
            $harness = New-ChallengerComHarness
            Mock Get-Process { return @([PSCustomObject]@{ Id = 2002; ProcessName = 'OUTLOOK' }) } -ModuleName 'Outlook'
            Mock Get-Process { return @([PSCustomObject]@{ Id = 2002; ProcessName = 'OUTLOOK' }) }

            $res = Clear-OutlookStuckOutbox -ProfileName 'CorporateProfile'
            $res.Status | Should -Be 'Warning'
            $harness.Tracker.QuitCalls | Should -Be 0
        }

        It 'Calls Quit() when Outlook was running but successfully stopped via -Force' {
            $harness = New-ChallengerComHarness
            $script:procCount = 0
            Mock Get-Process {
                param($Name)
                $script:procCount++
                if ($script:procCount -eq 1) {
                    return @([PSCustomObject]@{ Id = 2002; ProcessName = 'OUTLOOK' })
                }
                return @()
            }
            Mock Stop-ToolkitProcess { [PSCustomObject]@{ Terminated = $true } }
            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject { }
            Mock Set-ToolkitRegistryValue { }

            $res = Clear-OutlookStuckOutbox -ProfileName 'CorporateProfile' -Force
            $harness.Tracker.QuitCalls | Should -Be 1
            $harness.Tracker.LogoffCalls | Should -Be 1
        }

        It 'Survives when Quit() throws and ensures Logoff() was called beforehand' {
            $harness = New-ChallengerComHarness
            $harness.Tracker.QuitShouldThrow = $true
            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Test-Path { return $true }

            { $res = Clear-OutlookStuckOutbox -ProfileName 'CorporateProfile' } | Should -Not -Throw
            $harness.Tracker.LogoffCalls | Should -Be 1
            $harness.Tracker.QuitCalls | Should -Be 1
        }
    }

    Context 'RCW Reference Release' {
        It 'Releases outbox, ns, and comApp COM references' {
            $harness = New-ChallengerComHarness
            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Test-Path { return $true }

            $releasedObjs = [System.Collections.Generic.List[object]]::new()
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { $releasedObjs.Add($o) }
                }
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { $releasedObjs.Add($o) }
                }
            }

            $res = Clear-OutlookStuckOutbox -ProfileName 'CorporateProfile'
            $releasedObjs | Should -Contain $harness.App
            $releasedObjs | Should -Contain $harness.Namespace
            $releasedObjs | Should -Contain $harness.Outbox
        }

        It 'Executes fallback release cleanly when Remove-ToolkitComObject is unavailable' {
            $harness = New-ChallengerComHarness
            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Test-Path { return $true }
            Mock Get-Command {
                param($Name)
                if ($Name -eq 'Remove-ToolkitComObject') { return $null }
                return (Microsoft.PowerShell.Core\Get-Command @PSBoundParameters)
            } -ModuleName 'Outlook'

            { $res = Clear-OutlookStuckOutbox -ProfileName 'CorporateProfile' } | Should -Not -Throw
        }
    }

    Context 'Fault Injection: Exception in Try Block' {
        It 'Executes finally Logoff(), Quit(), and RCW release when outbox folder retrieval throws' {
            $harness = New-ChallengerComHarness
            $harness.Namespace | Add-Member -MemberType ScriptMethod -Name GetDefaultFolder -Value {
                throw [System.Runtime.InteropServices.COMException]::new("Folder not found")
            } -Force

            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Test-Path { return $true }

            $releasedObjs = [System.Collections.Generic.List[object]]::new()
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { $releasedObjs.Add($o) }
                }
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { $releasedObjs.Add($o) }
                }
            }

            $res = Clear-OutlookStuckOutbox -ProfileName 'CorporateProfile'
            $harness.Tracker.LogonCalls | Should -Be 1
            $harness.Tracker.LogoffCalls | Should -Be 1
            $harness.Tracker.QuitCalls | Should -Be 1
            $releasedObjs | Should -Contain $harness.App
            $releasedObjs | Should -Contain $harness.Namespace
        }

        It 'Skips Logoff() if Logon threw an exception' {
            $harness = New-ChallengerComHarness
            $harness.Namespace | Add-Member -MemberType ScriptMethod -Name Logon -Value {
                throw [System.Runtime.InteropServices.COMException]::new("Logon failed")
            } -Force

            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Test-Path { return $true }

            $res = Clear-OutlookStuckOutbox -ProfileName 'CorporateProfile'
            # didLogon remains $false, so Logoff() should not be called
            $harness.Tracker.LogoffCalls | Should -Be 0
            # Quit() should still be called
            $harness.Tracker.QuitCalls | Should -Be 1
        }

        It 'Continues cleanup if Logoff() throws an exception' {
            $harness = New-ChallengerComHarness
            $harness.Tracker.LogoffShouldThrow = $true

            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Test-Path { return $true }

            $releasedObjs = [System.Collections.Generic.List[object]]::new()
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { $releasedObjs.Add($o) }
                }
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { $releasedObjs.Add($o) }
                }
            }

            { $res = Clear-OutlookStuckOutbox -ProfileName 'CorporateProfile' } | Should -Not -Throw
            $harness.Tracker.QuitCalls | Should -Be 1
            $releasedObjs | Should -Contain $harness.App
            $releasedObjs | Should -Contain $harness.Namespace
        }
    }
}

# ==============================================================================
# Suite 3: Export-OutlookRule COM Lifecycle & Exception Robustness
# ==============================================================================
Describe 'Adversarial: Export-OutlookRule COM Lifecycle' {

    Context 'Conditional Quit() Execution' {
        It 'Calls Quit() when Outlook was NOT running prior to Export-OutlookRule' {
            $harness = New-ChallengerComHarness
            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Get-OutlookSystemContext { [PSCustomObject]@{ DefaultProfile = 'CorporateProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_chal_quit1_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $harness.Store.FilePath
                $harness.Tracker.QuitCalls | Should -Be 1
                $harness.Tracker.LogoffCalls | Should -Be 1
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Skips calling Quit() when Outlook WAS running prior to Export-OutlookRule' {
            $harness = New-ChallengerComHarness
            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @([PSCustomObject]@{ Id = 3003; ProcessName = 'OUTLOOK' }) } -ModuleName 'Outlook'
            Mock Get-Process { return @([PSCustomObject]@{ Id = 3003; ProcessName = 'OUTLOOK' }) }
            Mock Get-OutlookSystemContext { [PSCustomObject]@{ DefaultProfile = 'CorporateProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_chal_quit2_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $harness.Store.FilePath
                $harness.Tracker.QuitCalls | Should -Be 0
                $harness.Tracker.LogoffCalls | Should -Be 1
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Survives when Quit() throws and ensures manifest was written' {
            $harness = New-ChallengerComHarness
            $harness.Tracker.QuitShouldThrow = $true
            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Get-OutlookSystemContext { [PSCustomObject]@{ DefaultProfile = 'CorporateProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_chal_quit3_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                { $res = Export-OutlookRule -Path $testJson -StorePath $harness.Store.FilePath } | Should -Not -Throw
                $harness.Tracker.QuitCalls | Should -Be 1
                Test-Path -LiteralPath $testJson | Should -BeTrue
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }

    Context 'RCW Reference Release' {
        It 'Releases rules, rootFolder, store, stores, ns, and comApp' {
            $harness = New-ChallengerComHarness
            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Get-OutlookSystemContext { [PSCustomObject]@{ DefaultProfile = 'CorporateProfile' } } -ModuleName 'Outlook'

            $releasedObjs = [System.Collections.Generic.List[object]]::new()
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { $releasedObjs.Add($o) }
                }
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { $releasedObjs.Add($o) }
                }
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_chal_rcw_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $harness.Store.FilePath
                $releasedObjs | Should -Contain $harness.App
                $releasedObjs | Should -Contain $harness.Namespace
                $releasedObjs | Should -Contain $harness.Stores
                $releasedObjs | Should -Contain $harness.Store
                $releasedObjs | Should -Contain $harness.RootFolder
                $releasedObjs | Should -Contain $harness.Rules
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Executes fallback release cleanly when Remove-ToolkitComObject is unavailable' {
            $harness = New-ChallengerComHarness
            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Get-OutlookSystemContext { [PSCustomObject]@{ DefaultProfile = 'CorporateProfile' } } -ModuleName 'Outlook'
            Mock Get-Command {
                param($Name)
                if ($Name -eq 'Remove-ToolkitComObject') { return $null }
                return (Microsoft.PowerShell.Core\Get-Command @PSBoundParameters)
            } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_chal_fallback_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                { $res = Export-OutlookRule -Path $testJson -StorePath $harness.Store.FilePath } | Should -Not -Throw
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }

    Context 'Fault Injection: Exception in Try Block' {
        It 'Executes finally Logoff(), Quit(), and releases COM objects when GetRules throws' {
            $harness = New-ChallengerComHarness
            $harness.Store | Add-Member -MemberType ScriptMethod -Name GetRules -Value {
                throw [System.Runtime.InteropServices.COMException]::new("Cannot access rule store")
            } -Force

            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Get-OutlookSystemContext { [PSCustomObject]@{ DefaultProfile = 'CorporateProfile' } } -ModuleName 'Outlook'

            $releasedObjs = [System.Collections.Generic.List[object]]::new()
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { $releasedObjs.Add($o) }
                }
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { $releasedObjs.Add($o) }
                }
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_chal_err1_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $harness.Store.FilePath
                $res.Success | Should -BeFalse
                $res.ErrorMessage | Should -Match 'Cannot access rule store'
                $harness.Tracker.LogoffCalls | Should -Be 1
                $harness.Tracker.QuitCalls | Should -Be 1
                $releasedObjs | Should -Contain $harness.App
                $releasedObjs | Should -Contain $harness.Namespace
                $releasedObjs | Should -Contain $harness.Store
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Executes finally Logoff(), Quit(), and releases COM objects when store path is invalid' {
            $harness = New-ChallengerComHarness
            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Get-OutlookSystemContext { [PSCustomObject]@{ DefaultProfile = 'CorporateProfile' } } -ModuleName 'Outlook'

            $releasedObjs = [System.Collections.Generic.List[object]]::new()
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { $releasedObjs.Add($o) }
                }
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { $releasedObjs.Add($o) }
                }
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_chal_err2_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath 'C:\NonExistent\Ghost.pst'
                $res.Success | Should -BeFalse
                $res.ErrorMessage | Should -Match 'not found'
                $harness.Tracker.LogoffCalls | Should -Be 1
                $harness.Tracker.QuitCalls | Should -Be 1
                $releasedObjs | Should -Contain $harness.App
                $releasedObjs | Should -Contain $harness.Namespace
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Continues cleanup if Logoff() throws an exception' {
            $harness = New-ChallengerComHarness
            $harness.Tracker.LogoffShouldThrow = $true
            Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Get-OutlookSystemContext { [PSCustomObject]@{ DefaultProfile = 'CorporateProfile' } } -ModuleName 'Outlook'

            $releasedObjs = [System.Collections.Generic.List[object]]::new()
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { $releasedObjs.Add($o) }
                }
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { $releasedObjs.Add($o) }
                }
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_chal_err3_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                { $res = Export-OutlookRule -Path $testJson -StorePath $harness.Store.FilePath } | Should -Not -Throw
                $harness.Tracker.QuitCalls | Should -Be 1
                $releasedObjs | Should -Contain $harness.App
                $releasedObjs | Should -Contain $harness.Namespace
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }
}

# ==============================================================================
# Suite 4: Pipeline Execution & Sequential Reentrancy Lifecycle
# ==============================================================================
Describe 'Adversarial: Pipeline Reentrancy & Independent Cleanup' {

    It 'Independently manages COM lifecycle across multiple piped paths in Export-OutlookRule' {
        $harness = New-ChallengerComHarness
        Mock Get-OutlookComApplication { return $harness.App } -ModuleName 'Outlook'
        Mock Get-Process { return @() } -ModuleName 'Outlook'
        Mock Get-Process { return @() }
        Mock Get-OutlookSystemContext { [PSCustomObject]@{ DefaultProfile = 'CorporateProfile' } } -ModuleName 'Outlook'

        $json1 = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_pipe1_$([System.Guid]::NewGuid().ToString('N')).json"
        $json2 = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test_pipe2_$([System.Guid]::NewGuid().ToString('N')).json"

        try {
            $results = @($json1, $json2) | Export-OutlookRule -StorePath $harness.Store.FilePath
            $results.Count | Should -Be 2
            $harness.Tracker.QuitCalls | Should -Be 2
            $harness.Tracker.LogoffCalls | Should -Be 2
        }
        finally {
            if (Test-Path -LiteralPath $json1) { Remove-Item -LiteralPath $json1 -Force }
            if (Test-Path -LiteralPath $json2) { Remove-Item -LiteralPath $json2 -Force }
        }
    }
}
