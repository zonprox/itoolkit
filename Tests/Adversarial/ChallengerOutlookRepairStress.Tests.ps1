# Tests/Adversarial/ChallengerOutlookRepairStress.Tests.ps1
# Adversarial Stress & Edge-Case Harness for Repair-OutlookRule and Test-OutlookRule (M3 Challenger 1)

BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../Modules/Outlook/Outlook.psd1'
    Import-Module $modulePath -Force

    $corePath = Join-Path -Path $PSScriptRoot -ChildPath '../../Modules/Core/Core.psd1'
    if (Test-Path -LiteralPath $corePath) {
        Import-Module $corePath -Force
    }

    $script:createdFolderPaths = [System.Collections.Generic.List[string]]::new()
    $script:saveCallCount = 0
    $script:lastSaveShowProgress = $null

    $script:repairFolderFactory = {
        param($FolderName)
        $childList = [System.Collections.Generic.List[object]]::new()
        $newPath = "$($this.FolderPath)\$FolderName"
        $newChild = [PSCustomObject]@{
            Name       = $FolderName
            FolderPath = $newPath
            Folders    = $childList
        }
        $newChild | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $script:repairFolderFactory
        $this.Folders.Add($newChild)
        $script:createdFolderPaths.Add($newPath)
        return $newChild
    }

    # Helper: Create controllable mock Outlook COM environment for Repair-OutlookRule
    function script:New-ChallengerRepairEnv {
        param(
            [string]$StorePath = 'C:\Data\StressRepairStore.pst',
            [string]$StoreName = 'StressRepairStore',
            [object[]]$InitialRules = @(),
            [string[]]$InitialFolders = @('Inbox', 'Deleted Items', 'Sent Items'),
            [bool]$ThrowOnSave = $false,
            [bool]$ThrowOnGetRules = $false,
            [bool]$ThrowOnGetRootFolder = $false
        )

        $script:createdFolderPaths.Clear()
        $script:saveCallCount = 0
        $script:lastSaveShowProgress = $null

        # 1. Folders Tree
        $mockRootFolders = [System.Collections.Generic.List[object]]::new()
        $mockRoot = [PSCustomObject]@{
            Name       = $StoreName
            FolderPath = "\\$StoreName"
            Folders    = $mockRootFolders
        }
        $mockRoot | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $script:repairFolderFactory

        # Helper to recursively create existing initial folders
        foreach ($fPath in $InitialFolders) {
            $parts = $fPath -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $curr = $mockRoot
            foreach ($p in $parts) {
                $existing = $null
                foreach ($child in $curr.Folders) {
                    if ($child.Name -ieq $p) { $existing = $child; break }
                }
                if ($null -ne $existing) {
                    $curr = $existing
                } else {
                    $curr = $curr.AddFolder($p)
                }
            }
        }
        $script:createdFolderPaths.Clear()

        # Find mock Inbox
        $mockInbox = $null
        foreach ($f in $mockRoot.Folders) {
            if ($f.Name -ieq 'Inbox') { $mockInbox = $f; break }
        }
        if ($null -eq $mockInbox) {
            $mockInbox = $mockRoot.AddFolder('Inbox')
            $script:createdFolderPaths.Clear()
        }

        # 2. Rules List
        $rulesList = [System.Collections.Generic.List[object]]::new()
        foreach ($r in $InitialRules) {
            $rulesList.Add($r)
        }

        $mockRules = [PSCustomObject]@{
            Count     = $rulesList.Count
            RulesList = $rulesList
        }
        $mockRules | Add-Member -MemberType ScriptMethod -Name Item -Value {
            param($idx)
            return $this.RulesList[$idx - 1]
        }
        $mockRules | Add-Member -MemberType ScriptMethod -Name Remove -Value {
            param($idx)
            $this.RulesList.RemoveAt($idx - 1)
            $this.Count = $this.RulesList.Count
        }
        $mockRules | Add-Member -MemberType ScriptMethod -Name Save -Value {
            param($showProgress)
            if ($this.ThrowSave) {
                throw [System.Runtime.InteropServices.COMException]::new("0x80004005: E_FAIL saving rules")
            }
            $script:saveCallCount++
            $script:lastSaveShowProgress = $showProgress
        }
        $mockRules | Add-Member -MemberType NoteProperty -Name ThrowSave -Value $ThrowOnSave

        # 3. Store
        $mockStore = [PSCustomObject]@{
            DisplayName     = $StoreName
            FilePath        = $StorePath
            IsDataFileStore = $true
            IsDefaultStore  = $true
            RootFolder      = $mockRoot
            Rules           = $mockRules
            ThrowRoot       = $ThrowOnGetRootFolder
            ThrowRules      = $ThrowOnGetRules
        }
        $mockStore | Add-Member -MemberType ScriptMethod -Name GetRootFolder -Value {
            if ($this.ThrowRoot) {
                throw [System.Runtime.InteropServices.COMException]::new("0x8004010F: MAPI_E_NOT_FOUND root folder")
            }
            return $this.RootFolder
        }
        $mockStore | Add-Member -MemberType ScriptMethod -Name GetRules -Value {
            if ($this.ThrowRules) {
                throw [System.Runtime.InteropServices.COMException]::new("0x80004005: E_FAIL accessing rules collection")
            }
            return $this.Rules
        }

        # 4. Namespace
        $mockNs = [PSCustomObject]@{
            Stores        = @($mockStore)
            DefaultStore  = $mockStore
            ActiveProfile = 'StressProfile'
        }
        $mockNs | Add-Member -MemberType ScriptMethod -Name Logon -Value { param($p, $w, $u, $n) $this.ActiveProfile = $p }
        $mockNs | Add-Member -MemberType ScriptMethod -Name Logoff -Value { }

        # 5. Application
        $mockApp = [PSCustomObject]@{
            MapiNamespace = $mockNs
            QuitCalled    = $false
        }
        $mockApp | Add-Member -MemberType ScriptMethod -Name GetNamespace -Value { param($t) return $this.MapiNamespace }
        $mockApp | Add-Member -MemberType ScriptMethod -Name Quit -Value { $this.QuitCalled = $true }

        return [PSCustomObject]@{
            App            = $mockApp
            Namespace      = $mockNs
            Store          = $mockStore
            RootFolder     = $mockRoot
            InboxFolder    = $mockInbox
            Rules          = $mockRules
            RulesList      = $rulesList
            CreatedFolders = $script:createdFolderPaths
        }
    }

    # Helper: Create rule object
    function script:New-ChallengerRule {
        param(
            [string]$Name,
            [int]$ExecutionOrder = 1,
            [bool]$Enabled = $true,
            [string[]]$Subject = @(),
            [string[]]$From = @(),
            $MoveToFolder = $null,
            [bool]$MoveEnabled = $false,
            $CopyToFolder = $null,
            [bool]$CopyEnabled = $false,
            [bool]$Delete = $false,
            [bool]$MarkAsRead = $false,
            [bool]$Stop = $false
        )

        return [PSCustomObject]@{
            Name           = $Name
            RuleType       = 0
            Enabled        = $Enabled
            ExecutionOrder = $ExecutionOrder
            Conditions     = [PSCustomObject]@{
                Subject = [PSCustomObject]@{ Enabled = ($Subject.Count -gt 0); Text = $Subject }
                From    = [PSCustomObject]@{ Enabled = ($From.Count -gt 0); Recipients = $From }
            }
            Exceptions     = [PSCustomObject]@{
                Subject = [PSCustomObject]@{ Enabled = $false; Text = @() }
                From    = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
            }
            Actions        = [PSCustomObject]@{
                MoveToFolder = [PSCustomObject]@{ Folder = $MoveToFolder; Enabled = $MoveEnabled }
                CopyToFolder = [PSCustomObject]@{ Folder = $CopyToFolder; Enabled = $CopyEnabled }
                Delete       = [PSCustomObject]@{ Enabled = $Delete }
                MarkAsRead   = [PSCustomObject]@{ Enabled = $MarkAsRead }
                Stop         = [PSCustomObject]@{ Enabled = $Stop }
            }
        }
    }
}

Describe 'Adversarial Stress: Repair-OutlookRule & Test-OutlookRule' {

    # =========================================================================
    # Context 1: Multi-Broken Actions on a Single Rule
    # =========================================================================
    Context '1. Multi-Broken Actions on a Single Rule' {

        It 'Detects and reports broken actions when a rule has both MoveToFolder and CopyToFolder broken' {
            $ruleDualBroken = New-ChallengerRule -Name 'Sort & Backup Invoices' -Subject @('Invoice') `
                -MoveToFolder $null -MoveEnabled $true `
                -CopyToFolder $null -CopyEnabled $true

            $env = New-ChallengerRepairEnv -InitialRules @($ruleDualBroken)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath
            $res.Success | Should -BeTrue
            $res.TotalRules | Should -Be 1
            $res.BrokenRules.Count | Should -Be 1
            $res.BrokenRules[0].Name | Should -Be 'Sort & Backup Invoices'
            # Note: Single-pass audit breaks after MoveToFolder, flagging MoveToFolder as the primary broken action
            $res.BrokenRules[0].ActionType | Should -Be 'MoveToFolder'
        }

        It 'AutoRepair heals the first broken action and requires multi-pass execution for second action' {
            $ruleDualBroken = New-ChallengerRule -Name 'Route to Project Alpha and Copy to Beta' -Subject @('Project') `
                -MoveToFolder $null -MoveEnabled $true `
                -CopyToFolder $null -CopyEnabled $true

            $env = New-ChallengerRepairEnv -InitialRules @($ruleDualBroken)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            # Pass 1: AutoRepair heals MoveToFolder
            $res1 = Repair-OutlookRule -StorePath $env.Store.FilePath -AutoRepair
            $res1.Success | Should -BeTrue
            $res1.RepairedRulesCount | Should -Be 1
            $ruleDualBroken.Actions.MoveToFolder.Folder | Should -Not -BeNullOrEmpty

            # Pass 2: Second run of AutoRepair detects and heals the remaining CopyToFolder
            $res2 = Repair-OutlookRule -StorePath $env.Store.FilePath -AutoRepair
            $res2.Success | Should -BeTrue
            $res2.RepairedRulesCount | Should -Be 1
            $ruleDualBroken.Actions.CopyToFolder.Folder | Should -Not -BeNullOrEmpty
        }

        It 'Handles mixed valid MoveToFolder with broken CopyToFolder on a single rule' {
            $env = New-ChallengerRepairEnv
            $ruleMixed = New-ChallengerRule -Name 'Archive to Inbox and Copy to Ghost' -Subject @('Report') `
                -MoveToFolder $env.InboxFolder -MoveEnabled $true `
                -CopyToFolder $null -CopyEnabled $true

            $env.RulesList.Add($ruleMixed)
            $env.Rules.Count = $env.RulesList.Count
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath
            $res.Success | Should -BeTrue
            $res.BrokenRules.Count | Should -Be 1
            $res.BrokenRules[0].ActionType | Should -Be 'CopyToFolder'
            $res.BrokenRules[0].Issue | Should -Match 'null'
        }
    }

    # =========================================================================
    # Context 2: COM Property Exceptions on Folder Objects
    # =========================================================================
    Context '2. COM Property Exceptions on Folder Objects' {

        It 'Gracefully flags rule as broken when target folder Name throws COMException' {
            $nameExceptionFolder = [PSCustomObject]@{
                FolderPath = '\\StressRepairStore\Orphaned'
            }
            $nameExceptionFolder | Add-Member -MemberType ScriptProperty -Name 'Name' -Value {
                throw [System.Runtime.InteropServices.COMException]::new("0x80004005: E_FAIL reading folder name")
            }

            $ruleWithNameException = New-ChallengerRule -Name 'Move to Ghost Named Folder' -Subject @('Urgent') `
                -MoveToFolder $nameExceptionFolder -MoveEnabled $true

            $env = New-ChallengerRepairEnv -InitialRules @($ruleWithNameException)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath
            $res.Success | Should -BeTrue
            $res.BrokenRules.Count | Should -Be 1
            # Property exception results in empty/inaccessible Name detection
            $res.BrokenRules[0].Issue | Should -Match 'empty or inaccessible'
        }

        It 'Gracefully flags rule as broken when act.Folder access throws COMException' {
            $throwingActionRule = [PSCustomObject]@{
                Name           = 'Action Throws Folder COM Exception'
                RuleType       = 0
                Enabled        = $true
                ExecutionOrder = 1
                Conditions     = [PSCustomObject]@{
                    Subject = [PSCustomObject]@{ Enabled = $true; Text = @('Alert') }
                }
                Exceptions     = [PSCustomObject]@{
                    Subject = [PSCustomObject]@{ Enabled = $false; Text = @() }
                }
                Actions        = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Enabled = $true }
                    CopyToFolder = [PSCustomObject]@{ Enabled = $false }
                    Delete       = [PSCustomObject]@{ Enabled = $false }
                }
            }
            $throwingActionRule.Actions.MoveToFolder | Add-Member -MemberType ScriptProperty -Name 'Folder' -Value {
                throw [System.Runtime.InteropServices.COMException]::new("0x80010108: The object invoked has disconnected from its clients.")
            }

            $env = New-ChallengerRepairEnv -InitialRules @($throwingActionRule)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath
            $res.Success | Should -BeTrue
            $res.BrokenRules.Count | Should -Be 1
            $res.BrokenRules[0].Issue | Should -Match 'null'
        }

        It 'AutoRepair successfully heals rules whose target folder threw COMException' {
            $nameExceptionFolder = [PSCustomObject]@{
                FolderPath = '\\StressRepairStore\Detached'
            }
            $nameExceptionFolder | Add-Member -MemberType ScriptProperty -Name 'Name' -Value {
                throw [System.Runtime.InteropServices.COMException]::new("0x8004010F: MAPI_E_NOT_FOUND")
            }

            # Rule target folder threw exception on Name, but FolderPath was captured as \\StressRepairStore\Detached
            $rule = New-ChallengerRule -Name 'Move into Finance' -Subject @('Invoice') `
                -MoveToFolder $nameExceptionFolder -MoveEnabled $true

            $env = New-ChallengerRepairEnv -InitialRules @($rule)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -AutoRepair
            $res.Success | Should -BeTrue
            $res.RepairedRulesCount | Should -Be 1
            $rule.Actions.MoveToFolder.Folder | Should -Not -BeNullOrEmpty
            # Repair-OutlookRule prioritizes captured relative FolderPath ('Detached') over name regex guessing
            $rule.Actions.MoveToFolder.Folder.Name | Should -Be 'Detached'
        }

        It 'Reveals limitation: COM exception on FolderPath is bypassed when Name is valid without Stop ErrorAction' {
            # Target folder where FolderPath throws COMException but Name returns a valid string
            $comExceptionFolder = [PSCustomObject]@{
                Name = 'ValidNameCorruptedPath'
            }
            $comExceptionFolder | Add-Member -MemberType ScriptProperty -Name 'FolderPath' -Value {
                throw [System.Runtime.InteropServices.COMException]::new("0x8004010F: MAPI_E_NOT_FOUND folder detached")
            }

            $rule = New-ChallengerRule -Name 'Move to Detached Folder' -Subject @('Important') `
                -MoveToFolder $comExceptionFolder -MoveEnabled $true

            $env = New-ChallengerRepairEnv -InitialRules @($rule)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath
            $res.Success | Should -BeTrue
            # Empirical Challenger Observation: Because Repair-OutlookRule lacks $ErrorActionPreference='Stop',
            # non-terminating property getter exceptions on FolderPath do not trip the catch block when Name is populated.
            # Thus, BrokenRules count is 0.
            $res.BrokenRules.Count | Should -Be 0
        }
    }

    # =========================================================================
    # Context 3: Deeply Nested Missing Relative Folders
    # =========================================================================
    Context '3. Deeply Nested Missing Relative Folders' {

        It 'Recursively creates 5-level deep missing hierarchy and binds action to leaf folder' {
            $ruleDeep = New-ChallengerRule -Name 'Move to Inbox\Projects\DivisionA\TeamAlpha\Sprint10\Archive2026' -Subject @('DeepProject') `
                -MoveToFolder $null -MoveEnabled $true

            $env = New-ChallengerRepairEnv -InitialRules @($ruleDeep)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -AutoRepair
            $res.Success | Should -BeTrue
            $res.RepairedRulesCount | Should -Be 1

            $boundFolder = $ruleDeep.Actions.MoveToFolder.Folder
            $boundFolder | Should -Not -BeNullOrEmpty
            $boundFolder.Name | Should -Be 'Archive2026'
            $boundFolder.FolderPath | Should -Be '\\StressRepairStore\Inbox\Projects\DivisionA\TeamAlpha\Sprint10\Archive2026'
        }

        It 'Handles deeply nested forward-slash paths and spaces without error' {
            $ruleSlash = New-ChallengerRule -Name 'Move to Clients/North America/Key Accounts/Active Projects' -Subject @('ClientDoc') `
                -MoveToFolder $null -MoveEnabled $true

            $env = New-ChallengerRepairEnv -InitialRules @($ruleSlash)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -AutoRepair
            $res.Success | Should -BeTrue
            $res.RepairedRulesCount | Should -Be 1

            $boundFolder = $ruleSlash.Actions.MoveToFolder.Folder
            $boundFolder | Should -Not -BeNullOrEmpty
            $boundFolder.Name | Should -Be 'Active Projects'
        }

        It 'Creates non-Inbox root-relative multi-level folders when specified' {
            $ruleRootRel = New-ChallengerRule -Name '[Compliance\Audit\2026\Q3\Final]' -Subject @('Audit') `
                -MoveToFolder $null -MoveEnabled $true

            $env = New-ChallengerRepairEnv -InitialRules @($ruleRootRel)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -AutoRepair
            $res.Success | Should -BeTrue
            $res.RepairedRulesCount | Should -Be 1

            $boundFolder = $ruleRootRel.Actions.MoveToFolder.Folder
            $boundFolder | Should -Not -BeNullOrEmpty
            $boundFolder.Name | Should -Be 'Final'
        }
    }

    # =========================================================================
    # Context 4: Strict Zero-Mutation Invariant in Scan-Only and -WhatIf Modes
    # =========================================================================
    Context '4. Strict Zero-Mutation Invariant in Scan-Only and -WhatIf Modes' {

        It 'Guarantees strictly 0 mutations on rules and 0 folders created in ScanOnly mode' {
            $r1 = New-ChallengerRule -Name 'Broken Rule 1' -Subject @('A') -MoveToFolder $null -MoveEnabled $true
            $r2 = New-ChallengerRule -Name 'Duplicate Master' -Subject @('B') -Delete $true
            $r3 = New-ChallengerRule -Name 'Duplicate Copy' -Subject @('B') -Delete $true
            $r4 = New-ChallengerRule -Name 'Empty Zombie' -Enabled $false
            $r5 = New-ChallengerRule -Name 'Disabled Valid' -Subject @('C') -Delete $true -Enabled $false

            $env = New-ChallengerRepairEnv -InitialRules @($r1, $r2, $r3, $r4, $r5)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath
            $res.Success | Should -BeTrue
            $res.Method | Should -Be 'ScanOnly'
            $res.RulesScanned | Should -Be 5
            $res.BrokenRules.Count | Should -Be 1
            $res.DuplicateRules.Count | Should -Be 1
            $res.EmptyRules.Count | Should -Be 1
            $res.DisabledRules.Count | Should -Be 2

            # STRICT MUTATION CHECKS:
            # 1. Zero folders created
            $script:createdFolderPaths.Count | Should -Be 0
            # 2. Zero rules removed
            $env.Rules.Count | Should -Be 5
            $env.RulesList.Count | Should -Be 5
            # 3. Broken rule action folder remains $null
            $r1.Actions.MoveToFolder.Folder | Should -BeNullOrEmpty
            # 4. Save was NEVER called
            $script:saveCallCount | Should -Be 0
        }

        It 'Guarantees strictly 0 mutations and returns structured object under -WhatIf' {
            $r1 = New-ChallengerRule -Name 'Broken Rule 1' -Subject @('A') -MoveToFolder $null -MoveEnabled $true
            $r2 = New-ChallengerRule -Name 'Duplicate Copy' -Subject @('A') -MoveToFolder $null -MoveEnabled $true
            $r3 = New-ChallengerRule -Name 'Empty Zombie' -Enabled $false

            $env = New-ChallengerRepairEnv -InitialRules @($r1, $r2, $r3)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -AutoRepair -RemoveDuplicates -RemoveEmpty -WhatIf
            $res.Success | Should -BeTrue
            $res.Method | Should -Be 'WhatIf'

            # STRICT MUTATION CHECKS:
            $script:createdFolderPaths.Count | Should -Be 0
            $env.Rules.Count | Should -Be 3
            $env.RulesList.Count | Should -Be 3
            $script:saveCallCount | Should -Be 0
        }

        It 'Test-OutlookRule alias strictly preserves zero mutations in scan-only and -WhatIf modes' {
            $r1 = New-ChallengerRule -Name 'Broken Rule 1' -Subject @('A') -MoveToFolder $null -MoveEnabled $true
            $env = New-ChallengerRepairEnv -InitialRules @($r1)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            # 1. Alias in ScanOnly mode
            $resScan = Test-OutlookRule -StorePath $env.Store.FilePath
            $resScan.Success | Should -BeTrue
            $resScan.Method | Should -Be 'ScanOnly'
            $script:createdFolderPaths.Count | Should -Be 0
            $script:saveCallCount | Should -Be 0
            $env.Rules.Count | Should -Be 1

            # 2. Alias with -WhatIf
            $resWhatIf = Test-OutlookRule -StorePath $env.Store.FilePath -AutoRepair -WhatIf
            $resWhatIf.Success | Should -BeTrue
            $resWhatIf.Method | Should -Be 'WhatIf'
            $script:createdFolderPaths.Count | Should -Be 0
            $script:saveCallCount | Should -Be 0
        }
    }

    # =========================================================================
    # Context 5: Reverse-Index Deduplication and Empty Pruning Stress
    # =========================================================================
    Context '5. Reverse-Index Deduplication and Empty Pruning Stress' {

        It 'Prunes interleaved duplicates and empty rules correctly without index shifting corruption' {
            # Build list: [Empty1, MasterA, DupA1, Empty2, DupA2, MasterB, DupB1]
            $empty1  = New-ChallengerRule -Name 'Empty 1' -Enabled $false
            $masterA = New-ChallengerRule -Name 'Master A' -Subject @('Alpha') -Delete $true
            $dupA1   = New-ChallengerRule -Name 'Dup A1' -Subject @('Alpha') -Delete $true
            $empty2  = New-ChallengerRule -Name 'Empty 2' -Enabled $false
            $dupA2   = New-ChallengerRule -Name 'Dup A2' -Subject @('Alpha') -Delete $true
            $masterB = New-ChallengerRule -Name 'Master B' -From @('boss@org.com') -MarkAsRead $true
            $dupB1   = New-ChallengerRule -Name 'Dup B1' -From @('boss@org.com') -MarkAsRead $true

            $env = New-ChallengerRepairEnv -InitialRules @($empty1, $masterA, $dupA1, $empty2, $dupA2, $masterB, $dupB1)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -RemoveDuplicates -RemoveEmpty
            $res.Success | Should -BeTrue
            $res.RemovedDuplicatesCount | Should -Be 3
            $res.RemovedEmptyCount | Should -Be 2

            # Exactly 2 rules should remain: Master A and Master B
            $env.Rules.Count | Should -Be 2
            $remainingNames = @($env.RulesList | ForEach-Object { $_.Name })
            $remainingNames | Should -Contain 'Master A'
            $remainingNames | Should -Contain 'Master B'
            $remainingNames | Should -Not -Contain 'Dup A1'
            $remainingNames | Should -Not -Contain 'Dup A2'
            $remainingNames | Should -Not -Contain 'Dup B1'
            $remainingNames | Should -Not -Contain 'Empty 1'
            $remainingNames | Should -Not -Contain 'Empty 2'
            $script:saveCallCount | Should -Be 1
            $script:lastSaveShowProgress | Should -BeFalse
        }

        It 'Preserves disabled rules that have active conditions and actions during -RemoveEmpty' {
            $disabledRuleWithCond = New-ChallengerRule -Name 'Paused Urgent Alert' -Subject @('URGENT') -MarkAsRead $true -Enabled $false
            $emptyZombie = New-ChallengerRule -Name 'Actual Empty Zombie' -Enabled $false

            $env = New-ChallengerRepairEnv -InitialRules @($disabledRuleWithCond, $emptyZombie)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -RemoveEmpty
            $res.Success | Should -BeTrue
            $res.RemovedEmptyCount | Should -Be 1
            $res.DisabledRules | Should -Contain 'Paused Urgent Alert'

            $remainingNames = @($env.RulesList | ForEach-Object { $_.Name })
            $remainingNames | Should -Contain 'Paused Urgent Alert'
            $remainingNames | Should -Not -Contain 'Actual Empty Zombie'
        }
    }

    # =========================================================================
    # Context 6: Fault Tolerance & Boundary Handling
    # =========================================================================
    Context '6. Fault Tolerance & Boundary Handling' {

        It 'Handles empty store with 0 rules cleanly without exceptions' {
            $env = New-ChallengerRepairEnv -InitialRules @()
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath
            $res.Success | Should -BeTrue
            $res.TotalRules | Should -Be 0
            $res.RulesScanned | Should -Be 0
            $res.BrokenRules.Count | Should -Be 0
            $res.DuplicateRules.Count | Should -Be 0
            $res.EmptyRules.Count | Should -Be 0
            $script:saveCallCount | Should -Be 0
        }

        It 'Returns structured error object and does not throw when store cannot be found' {
            $env = New-ChallengerRepairEnv
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath 'Z:\NonExistent\GhostStore.pst'
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'store.*not found'
            $script:saveCallCount | Should -Be 0
        }

        It 'Gracefully handles COM exception when GetRules throws' {
            $env = New-ChallengerRepairEnv -ThrowOnGetRules $true
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'E_FAIL accessing rules collection'
        }

        It 'Gracefully handles COM exception when GetRootFolder throws' {
            $env = New-ChallengerRepairEnv -ThrowOnGetRootFolder $true
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'MAPI_E_NOT_FOUND root folder'
        }

        It 'Handles store where no Inbox folder exists under root folder' {
            $env = New-ChallengerRepairEnv -InitialFolders @('Deleted Items', 'Sent Items')
            $r = New-ChallengerRule -Name 'Broken Rule Without Inbox' -Subject @('Hello') -MoveToFolder $null -MoveEnabled $true
            $env.RulesList.Add($r)
            $env.Rules.Count = $env.RulesList.Count

            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -AutoRepair
            $res.Success | Should -BeTrue
            $res.RepairedRulesCount | Should -Be 1
            $r.Actions.MoveToFolder.Folder | Should -Not -BeNullOrEmpty
        }
    }
}
