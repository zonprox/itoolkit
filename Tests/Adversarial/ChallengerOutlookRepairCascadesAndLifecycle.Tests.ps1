# Tests/Adversarial/ChallengerOutlookRepairCascadesAndLifecycle.Tests.ps1
# Empirical Adversarial Stress Harness for Repair-OutlookRule & Test-OutlookRule (M3 Challenger 2)
#
# Focus areas:
# 1. 50+ rules with large duplicate cascades & reverse-index stability
# 2. Empty rule pruning & compound cascades
# 3. $rules.Save($false) UI prompt suppression & mutation gating
# 4. Deterministic COM lifecycle & exception handling in try/finally blocks

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $modulePath = Join-Path -Path $root 'Modules/Outlook/Outlook.psd1'
    Import-Module $modulePath -Force

    $corePath = Join-Path -Path $root 'Modules/Core/Core.psd1'
    if (Test-Path -LiteralPath $corePath) {
        Import-Module $corePath -Force
    }

    # Ensure C: drive alias exists for cross-platform Linux test runner
    if (-not (Get-PSDrive -Name 'C' -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name 'C' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -ErrorAction SilentlyContinue | Out-Null
    }

    # Helper: Build a mock rule object mirroring Outlook MAPI COM properties
    function script:New-Challenger2Rule {
        param(
            [string]$Name,
            [int]$ExecutionOrder = 1,
            [bool]$Enabled = $true,
            [int]$RuleType = 0,
            [string[]]$SubjectText = $null,
            [string[]]$FromRecipients = $null,
            [string[]]$Categories = $null,
            [object]$Importance = $null,
            [object]$MoveFolder = $null,
            [bool]$MoveEnabled = $false,
            [object]$CopyFolder = $null,
            [bool]$CopyEnabled = $false,
            [bool]$Delete = $false,
            [bool]$MarkAsRead = $false,
            [bool]$Stop = $false
        )

        $sText = if ($null -ne $SubjectText) { $SubjectText } else { @() }
        $fRecip = if ($null -ne $FromRecipients) { $FromRecipients } else { @() }
        $cCats = if ($null -ne $Categories) { $Categories } else { @() }
        $impVal = if ($null -ne $Importance) { $Importance } else { 1 }

        $condProps = [ordered]@{
            Subject    = [PSCustomObject]@{ Enabled = ($sText.Count -gt 0); Text = $sText }
            From       = [PSCustomObject]@{ Enabled = ($fRecip.Count -gt 0); Recipients = $fRecip }
            Categories = [PSCustomObject]@{ Enabled = ($cCats.Count -gt 0); Categories = $cCats }
            Importance = [PSCustomObject]@{ Enabled = ($null -ne $Importance); Importance = $impVal }
        }

        $actProps = [ordered]@{
            MoveToFolder = [PSCustomObject]@{ Folder = $MoveFolder; Enabled = $MoveEnabled }
            CopyToFolder = [PSCustomObject]@{ Folder = $CopyFolder; Enabled = $CopyEnabled }
            Delete       = [PSCustomObject]@{ Enabled = $Delete }
            MarkAsRead   = [PSCustomObject]@{ Enabled = $MarkAsRead }
            Stop         = [PSCustomObject]@{ Enabled = $Stop }
        }

        return [PSCustomObject]@{
            Name           = $Name
            ExecutionOrder = $ExecutionOrder
            Enabled        = $Enabled
            RuleType       = $RuleType
            Conditions     = [PSCustomObject]$condProps
            Exceptions     = [PSCustomObject]@{
                Subject = [PSCustomObject]@{ Enabled = $false; Text = @() }
            }
            Actions        = [PSCustomObject]$actProps
        }
    }

    # Helper: Build a configurable mock Outlook environment with telemetry & failure injection
    function script:New-Challenger2RepairEnv {
        param(
            [string]$StorePath = 'C:\Data\StressDiagnosticsStore2.pst',
            [string]$StoreName = 'Stress Store 2',
            [object[]]$Rules = @(),
            [bool]$ThrowOnSaveArg = $false,
            [bool]$ThrowOnSaveAll = $false,
            [bool]$ThrowOnGetRules = $false,
            [bool]$ThrowOnGetNamespace = $false,
            [bool]$ThrowOnGetRootFolder = $false
        )

        $tracker = [PSCustomObject]@{
            QuitCalls             = 0
            LogonCalls            = 0
            LogoffCalls           = 0
            SaveCalls             = 0
            SaveArguments         = [System.Collections.Generic.List[object]]::new()
            RemovedIndices        = [System.Collections.Generic.List[int]]::new()
            RemovedRules          = [System.Collections.Generic.List[object]]::new()
            ReleasedComReferences = [System.Collections.Generic.List[object]]::new()
        }

        # 1. Folders
        $rootFolders = [System.Collections.Generic.List[object]]::new()
        $mockRoot = [PSCustomObject]@{
            Name       = $StoreName
            FolderPath = "\\$StoreName"
            Folders    = $rootFolders
        }

        $script:challenger2FolderFactory = {
            param($fName)
            $childList = [System.Collections.Generic.List[object]]::new()
            $newF = [PSCustomObject]@{
                Name       = $fName
                FolderPath = "$($this.FolderPath)\$fName"
                Folders    = $childList
            }
            $newF | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $script:challenger2FolderFactory
            $this.Folders.Add($newF)
            return $newF
        }
        $mockRoot | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $script:challenger2FolderFactory

        $mockInbox = $mockRoot.AddFolder('Inbox')
        $null = $mockRoot.AddFolder('Deleted Items')
        $null = $mockRoot.AddFolder('Sent Items')

        # 2. Rules Collection
        $rulesList = [System.Collections.Generic.List[object]]::new()
        foreach ($r in $Rules) {
            $rulesList.Add($r)
        }

        $mockRules = [PSCustomObject]@{
            Count     = $rulesList.Count
            RulesList = $rulesList
            Tracker   = $tracker
        }

        $mockRules | Add-Member -MemberType ScriptMethod -Name Item -Value {
            param($idx)
            # 1-based index support
            if ($idx -ge 1 -and $idx -le $this.RulesList.Count) {
                return $this.RulesList[$idx - 1]
            }
            throw "Index out of range in Rules collection: $idx (Count: $($this.RulesList.Count))"
        }

        $mockRules | Add-Member -MemberType ScriptMethod -Name Remove -Value {
            param($idx)
            $this.Tracker.RemovedIndices.Add($idx)
            $targetIndex = $idx - 1
            if ($targetIndex -ge 0 -and $targetIndex -lt $this.RulesList.Count) {
                $removedRule = $this.RulesList[$targetIndex]
                $this.Tracker.RemovedRules.Add($removedRule)
                $this.RulesList.RemoveAt($targetIndex)
                $this.Count = $this.RulesList.Count
            } else {
                throw "Index out of range for Remove: $idx (Collection count: $($this.RulesList.Count))"
            }
        }

        if ($ThrowOnSaveAll) {
            $mockRules | Add-Member -MemberType ScriptMethod -Name Save -Value {
                param($showProgress)
                $this.Tracker.SaveCalls++
                $this.Tracker.SaveArguments.Add($showProgress)
                throw "COM Error: Save failed catastrophically (Store locked or disk full)."
            }
        } elseif ($ThrowOnSaveArg) {
            $mockRules | Add-Member -MemberType ScriptMethod -Name Save -Value {
                param($showProgress)
                $this.Tracker.SaveCalls++
                $this.Tracker.SaveArguments.Add($showProgress)
                if ($null -ne $showProgress) {
                    throw "COM Error: Save with parameter not supported on this Outlook version."
                }
            }
        } else {
            $mockRules | Add-Member -MemberType ScriptMethod -Name Save -Value {
                param($showProgress)
                $this.Tracker.SaveCalls++
                $this.Tracker.SaveArguments.Add($showProgress)
            }
        }

        # 3. Store
        $mockStore = [PSCustomObject]@{
            DisplayName     = $StoreName
            FilePath        = $StorePath
            IsDataFileStore = $true
            IsDefaultStore  = $true
            RootFolder      = $mockRoot
            Rules           = $mockRules
        }

        if ($ThrowOnGetRootFolder) {
            $mockStore | Add-Member -MemberType ScriptMethod -Name GetRootFolder -Value {
                throw "COM Error: Cannot access RootFolder on store."
            }
        } else {
            $mockStore | Add-Member -MemberType ScriptMethod -Name GetRootFolder -Value { return $this.RootFolder }
        }

        if ($ThrowOnGetRules) {
            $mockStore | Add-Member -MemberType ScriptMethod -Name GetRules -Value {
                throw "COM Error: Failed to open Rules collection from store (0x8004010F)."
            }
        } else {
            $mockStore | Add-Member -MemberType ScriptMethod -Name GetRules -Value { return $this.Rules }
        }

        # 4. Namespace
        $mockNs = [PSCustomObject]@{
            Stores        = @($mockStore)
            DefaultStore  = $mockStore
            ActiveProfile = 'StressProfile2'
            Tracker       = $tracker
        }
        $mockNs | Add-Member -MemberType ScriptMethod -Name Logon -Value {
            param($p, $w, $u, $n)
            $this.Tracker.LogonCalls++
            $this.ActiveProfile = $p
        }
        $mockNs | Add-Member -MemberType ScriptMethod -Name Logoff -Value {
            $this.Tracker.LogoffCalls++
        }

        # 5. Application
        $mockApp = [PSCustomObject]@{
            MapiNamespace = $mockNs
            Tracker       = $tracker
        }
        if ($ThrowOnGetNamespace) {
            $mockApp | Add-Member -MemberType ScriptMethod -Name GetNamespace -Value {
                param($t)
                throw "COM Error: GetNamespace('MAPI') threw fatal exception."
            }
        } else {
            $mockApp | Add-Member -MemberType ScriptMethod -Name GetNamespace -Value {
                param($t)
                return $this.MapiNamespace
            }
        }
        $mockApp | Add-Member -MemberType ScriptMethod -Name Quit -Value {
            $this.Tracker.QuitCalls++
        }

        return [PSCustomObject]@{
            App         = $mockApp
            Namespace   = $mockNs
            Store       = $mockStore
            RootFolder  = $mockRoot
            InboxFolder = $mockInbox
            Rules       = $mockRules
            RulesList   = $rulesList
            Tracker     = $tracker
        }
    }
}

Describe 'M3 Challenger 2: Repair-OutlookRule Cascades & Lifecycle Stress Harness' -Tag 'Adversarial', 'Stress', 'Challenger' {

    # =========================================================================
    # Context 1: 50+ Rules Duplicate Deduplication Cascades & Reverse-Index Stability
    # =========================================================================
    Context 'Duplicate Deduplication Cascades (50+ Rules) & Reverse-Index Stability' {

        It 'Correctly deduplicates a 60-rule collection with 3 distinct duplicate clusters interleaved with unique rules' {
            $rules = [System.Collections.Generic.List[object]]::new()
            $alphaFolder = [PSCustomObject]@{ Name = 'Alpha'; FolderPath = "\\Stress Store 2\Inbox\Alpha" }

            $uniqueCount = 0
            $clusterACount = 0
            $clusterBCount = 0
            $clusterCCount = 0

            for ($i = 1; $i -le 60; $i++) {
                if ($i % 4 -eq 0) {
                    $uniqueCount++
                    $rules.Add((New-Challenger2Rule -Name "Unique_Rule_$uniqueCount" -ExecutionOrder $i -SubjectText @("UniqueSubject_$uniqueCount") -MarkAsRead $true))
                } elseif ($clusterACount -lt 10) {
                    $clusterACount++
                    $rules.Add((New-Challenger2Rule -Name "ClusterA_Rule_$clusterACount" -ExecutionOrder $i -SubjectText @('Alpha Project') -MoveFolder $alphaFolder -MoveEnabled $true -Stop $true))
                } elseif ($clusterBCount -lt 15) {
                    $clusterBCount++
                    $rules.Add((New-Challenger2Rule -Name "ClusterB_Rule_$clusterBCount" -ExecutionOrder $i -SubjectText @('Beta Billing') -MarkAsRead $true))
                } else {
                    $clusterCCount++
                    $rules.Add((New-Challenger2Rule -Name "ClusterC_Rule_$clusterCCount" -ExecutionOrder $i -Categories @('Urgent') -Stop $true))
                }
            }

            $rules.Count | Should -Be 60
            $clusterACount | Should -Be 10
            $clusterBCount | Should -Be 15
            $clusterCCount | Should -Be 20
            $uniqueCount | Should -Be 15

            $env = New-Challenger2RepairEnv -Rules $rules
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile2' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -RemoveDuplicates

            $res.Success | Should -BeTrue
            $res.TotalRules | Should -Be 60
            # Duplicates to remove: (10-1) + (15-1) + (20-1) = 9 + 14 + 19 = 42 duplicates
            $res.DuplicateRules.Count | Should -Be 42
            $res.RemovedDuplicatesCount | Should -Be 42
            $res.RemovedDuplicates | Should -Be 42

            # Total remaining rules must be exactly 60 - 42 = 18 rules (1 ClusterA + 1 ClusterB + 1 ClusterC + 15 unique)
            $env.Rules.Count | Should -Be 18
            $env.RulesList.Count | Should -Be 18

            # Verify reverse-index stability:
            # First rule in collection must remain ClusterA_Rule_1 (Master)
            $env.RulesList[0].Name | Should -Be 'ClusterA_Rule_1'

            # Masters of Cluster B and Cluster C must exist
            $remainingNames = @($env.RulesList | ForEach-Object { $_.Name })
            $remainingNames | Should -Contain 'ClusterA_Rule_1'
            $remainingNames | Should -Contain 'ClusterB_Rule_1'
            $remainingNames | Should -Contain 'ClusterC_Rule_1'

            # None of the duplicates should remain
            for ($k = 2; $k -le 10; $k++) { $remainingNames | Should -Not -Contain "ClusterA_Rule_$k" }
            for ($k = 2; $k -le 15; $k++) { $remainingNames | Should -Not -Contain "ClusterB_Rule_$k" }
            for ($k = 2; $k -le 20; $k++) { $remainingNames | Should -Not -Contain "ClusterC_Rule_$k" }

            # All 15 unique rules must still exist and be intact
            for ($u = 1; $u -le 15; $u++) {
                $remainingNames | Should -Contain "Unique_Rule_$u"
            }

            # Verify removal order was strictly descending (reverse-index safety)
            $removedIdxs = @($env.Tracker.RemovedIndices)
            $removedIdxs.Count | Should -Be 42
            for ($j = 0; $j -lt ($removedIdxs.Count - 1); $j++) {
                $removedIdxs[$j] | Should -BeGreaterThan $removedIdxs[$j + 1]
            }

            # Verify Save($false) was invoked
            $env.Tracker.SaveCalls | Should -Be 1
            $env.Tracker.SaveArguments[0] | Should -BeFalse
        }

        It 'Handles a massive 100-rule duplicate flood (1 master + 99 identical duplicates) without index shifting corruption' {
            $rules = [System.Collections.Generic.List[object]]::new()
            for ($i = 1; $i -le 100; $i++) {
                $rules.Add((New-Challenger2Rule -Name "Flood_Rule_$i" -ExecutionOrder $i -SubjectText @('Cascade Alert') -MarkAsRead $true))
            }

            $env = New-Challenger2RepairEnv -Rules $rules
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile2' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -RemoveDuplicates

            $res.Success | Should -BeTrue
            $res.TotalRules | Should -Be 100
            $res.DuplicateRules.Count | Should -Be 99
            $res.RemovedDuplicatesCount | Should -Be 99

            # Exactly 1 rule left: the master Flood_Rule_1
            $env.Rules.Count | Should -Be 1
            $env.RulesList.Count | Should -Be 1
            $env.RulesList[0].Name | Should -Be 'Flood_Rule_1'

            # Verification of strictly descending removal sequence: 100, 99, 98, ..., 2
            $removedIdxs = @($env.Tracker.RemovedIndices)
            $removedIdxs.Count | Should -Be 99
            $removedIdxs[0] | Should -Be 100
            $removedIdxs[98] | Should -Be 2
        }

        It 'Accurately prunes boundary duplicates at collection head (1, 2) and collection tail (N-1, N)' {
            $rules = [System.Collections.Generic.List[object]]::new()

            # Index 1 & 2: Head duplicate pair
            $rules.Add((New-Challenger2Rule -Name 'Head_Master' -ExecutionOrder 1 -SubjectText @('Head') -Stop $true))
            $rules.Add((New-Challenger2Rule -Name 'Head_Duplicate' -ExecutionOrder 2 -SubjectText @('Head') -Stop $true))

            # Indices 3..48: Unique filler rules
            for ($i = 3; $i -le 48; $i++) {
                $rules.Add((New-Challenger2Rule -Name "Middle_Rule_$i" -ExecutionOrder $i -SubjectText @("Middle_$i") -MarkAsRead $true))
            }

            # Indices 49 & 50: Tail duplicate pair
            $rules.Add((New-Challenger2Rule -Name 'Tail_Master' -ExecutionOrder 49 -SubjectText @('Tail') -Delete $true))
            $rules.Add((New-Challenger2Rule -Name 'Tail_Duplicate' -ExecutionOrder 50 -SubjectText @('Tail') -Delete $true))

            $env = New-Challenger2RepairEnv -Rules $rules
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile2' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -RemoveDuplicates

            $res.Success | Should -BeTrue
            $res.TotalRules | Should -Be 50
            $res.RemovedDuplicatesCount | Should -Be 2
            $env.Rules.Count | Should -Be 48

            $remainingNames = @($env.RulesList | ForEach-Object { $_.Name })
            $remainingNames | Should -Contain 'Head_Master'
            $remainingNames | Should -Not -Contain 'Head_Duplicate'
            $remainingNames | Should -Contain 'Tail_Master'
            $remainingNames | Should -Not -Contain 'Tail_Duplicate'

            # Head master is at index 0, Tail master is at index 47 (last)
            $env.RulesList[0].Name | Should -Be 'Head_Master'
            $env.RulesList[47].Name | Should -Be 'Tail_Master'
        }

        It 'Treats condition text arrays and recipient addresses with differing casing and whitespace as identical duplicates' {
            $rules = [System.Collections.Generic.List[object]]::new()

            # Rule 1: Master with mixed casing & padding
            $rules.Add((New-Challenger2Rule -Name 'Master_Casing' -ExecutionOrder 1 -SubjectText @('  URGENT NOTICE  ', 'Security alert') -FromRecipients @('  Admin@Enterprise.ORG  ') -MarkAsRead $true))

            # 49 duplicates with varying whitespace, casing, and array order
            for ($i = 2; $i -le 50; $i++) {
                $rules.Add((New-Challenger2Rule -Name "Duplicate_Casing_$i" -ExecutionOrder $i -SubjectText @('security ALERT', 'urgent notice') -FromRecipients @('admin@enterprise.org') -MarkAsRead $true))
            }

            $env = New-Challenger2RepairEnv -Rules $rules
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile2' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -RemoveDuplicates

            $res.Success | Should -BeTrue
            $res.TotalRules | Should -Be 50
            $res.RemovedDuplicatesCount | Should -Be 49
            $env.Rules.Count | Should -Be 1
            $env.RulesList[0].Name | Should -Be 'Master_Casing'
        }
    }

    # =========================================================================
    # Context 2: Empty Rule Pruning & Interleaved Compound Cascades
    # =========================================================================
    Context 'Empty Rule Pruning & Interleaved Compound Cascades' {

        It 'Prunes 25 empty zombie rules from a 50-rule collection while preserving all 25 active rules' {
            $rules = [System.Collections.Generic.List[object]]::new()

            # 50 rules alternating: even index = empty zombie rule, odd index = active rule
            for ($i = 1; $i -le 50; $i++) {
                if ($i % 2 -eq 0) {
                    # Empty zombie rule: zero active conditions, zero active actions
                    $rules.Add((New-Challenger2Rule -Name "Zombie_Rule_$i" -ExecutionOrder $i -Enabled $false))
                } else {
                    # Active rule: has subject condition and MarkAsRead action
                    $rules.Add((New-Challenger2Rule -Name "Active_Rule_$i" -ExecutionOrder $i -SubjectText @("Active_$i") -MarkAsRead $true))
                }
            }

            $env = New-Challenger2RepairEnv -Rules $rules
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile2' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -RemoveEmpty

            $res.Success | Should -BeTrue
            $res.TotalRules | Should -Be 50
            $res.EmptyRules.Count | Should -Be 25
            $res.RemovedEmptyCount | Should -Be 25
            $env.Rules.Count | Should -Be 25

            # All remaining rules must be Active_Rule_*
            foreach ($remRule in $env.RulesList) {
                $remRule.Name | Should -Match '^Active_Rule_'
            }

            # Verification of strictly descending removal indices: 50, 48, 46, ..., 2
            $removedIdxs = @($env.Tracker.RemovedIndices)
            $removedIdxs.Count | Should -Be 25
            $removedIdxs[0] | Should -Be 50
            $removedIdxs[24] | Should -Be 2
        }

        It 'Does NOT prune disabled rules that have active conditions and actions configured' {
            $rules = [System.Collections.Generic.List[object]]::new()

            # 10 disabled rules with conditions/actions
            for ($i = 1; $i -le 10; $i++) {
                $rules.Add((New-Challenger2Rule -Name "Disabled_Active_$i" -ExecutionOrder $i -Enabled $false -SubjectText @("DisabledTrigger_$i") -MarkAsRead $true))
            }
            # 10 truly empty rules
            for ($i = 11; $i -le 20; $i++) {
                $rules.Add((New-Challenger2Rule -Name "True_Empty_$i" -ExecutionOrder $i -Enabled $false))
            }

            $env = New-Challenger2RepairEnv -Rules $rules
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile2' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -RemoveEmpty

            $res.Success | Should -BeTrue
            $res.TotalRules | Should -Be 20
            # Only the 10 true empty rules are pruned
            $res.EmptyRules.Count | Should -Be 10
            $res.RemovedEmptyCount | Should -Be 10
            $res.DisabledRules.Count | Should -Be 20 # All 20 were Enabled=$false

            $env.Rules.Count | Should -Be 10
            $remainingNames = @($env.RulesList | ForEach-Object { $_.Name })
            for ($k = 1; $k -le 10; $k++) {
                $remainingNames | Should -Contain "Disabled_Active_$k"
            }
        }

        It 'Executes a complex 60-rule compound cascade: auto-repairs 5 broken rules, prunes 10 empty rules, and deduplicates 15 rules without collision' {
            $rules = [System.Collections.Generic.List[object]]::new()

            # 1. Cluster X Master (Index 1)
            $rules.Add((New-Challenger2Rule -Name 'ClusterX_Master' -ExecutionOrder 1 -SubjectText @('ClusterX') -Stop $true))

            # 2. 10 Empty rules at indices 2..11
            for ($i = 2; $i -le 11; $i++) {
                $rules.Add((New-Challenger2Rule -Name "Empty_Zombie_$i" -ExecutionOrder $i -Enabled $false))
            }

            # 3. 5 Broken MoveToFolder rules at indices 12..16 (Folder is $null, name hints at folder)
            for ($i = 12; $i -le 16; $i++) {
                $rules.Add((New-Challenger2Rule -Name "Move to Projects_$i" -ExecutionOrder $i -SubjectText @("Project $i") -MoveFolder $null -MoveEnabled $true))
            }

            # 4. 15 Duplicates of Cluster X at indices 17..31
            for ($i = 17; $i -le 31; $i++) {
                $rules.Add((New-Challenger2Rule -Name "ClusterX_Duplicate_$i" -ExecutionOrder $i -SubjectText @('ClusterX') -Stop $true))
            }

            # 5. 29 Unique active rules at indices 32..60
            for ($i = 32; $i -le 60; $i++) {
                $rules.Add((New-Challenger2Rule -Name "Unique_Active_$i" -ExecutionOrder $i -SubjectText @("Unique_$i") -MarkAsRead $true))
            }

            $rules.Count | Should -Be 60

            $env = New-Challenger2RepairEnv -Rules $rules
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile2' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -AutoRepair

            $res.Success | Should -BeTrue
            $res.TotalRules | Should -Be 60
            $res.BrokenRules.Count | Should -Be 5
            $res.EmptyRules.Count | Should -Be 10
            $res.DuplicateRules.Count | Should -Be 15
            $res.RepairedRulesCount | Should -Be 5
            $res.RemovedEmptyCount | Should -Be 10
            $res.RemovedDuplicatesCount | Should -Be 15

            # Total removed: 10 empty + 15 duplicates = 25 rules removed
            # Remaining rules: 60 - 25 = 35 rules
            $env.Rules.Count | Should -Be 35
            $env.RulesList.Count | Should -Be 35

            # Verify that the 5 broken rules were repaired and have non-null folders bound
            $repairedRules = @($env.RulesList | Where-Object { $_.Name -match '^Move to Projects_' })
            $repairedRules.Count | Should -Be 5
            foreach ($r in $repairedRules) {
                $r.Actions.MoveToFolder.Folder | Should -Not -BeNullOrEmpty
                $r.Actions.MoveToFolder.Enabled | Should -BeTrue
            }

            # Verify that ClusterX_Master is preserved and all duplicates removed
            $remainingNames = @($env.RulesList | ForEach-Object { $_.Name })
            $remainingNames | Should -Contain 'ClusterX_Master'
            for ($i = 17; $i -le 31; $i++) {
                $remainingNames | Should -Not -Contain "ClusterX_Duplicate_$i"
            }

            # Verify all 10 empty rules removed
            for ($i = 2; $i -le 11; $i++) {
                $remainingNames | Should -Not -Contain "Empty_Zombie_$i"
            }

            # Verify all 29 unique rules preserved
            for ($i = 32; $i -le 60; $i++) {
                $remainingNames | Should -Contain "Unique_Active_$i"
            }

            # Total removals tracked = 25
            $env.Tracker.RemovedIndices.Count | Should -Be 25
        }
    }

    # =========================================================================
    # Context 3: $rules.Save($false) UI Prompt Suppression & Mutation Gating
    # =========================================================================
    Context '$rules.Save($false) UI Prompt Suppression & Mutation Gating' {

        It 'Suppresses UI prompts by strictly passing $false to Save($false) when AutoRepair performs mutations' {
            $brokenRule = New-Challenger2Rule -Name 'Route to Finance' -MoveFolder $null -MoveEnabled $true -SubjectText @('Finance')
            $env = New-Challenger2RepairEnv -Rules @($brokenRule)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile2' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -AutoRepair

            $res.Success | Should -BeTrue
            $env.Tracker.SaveCalls | Should -Be 1
            # Verify the exact argument passed to Save was [bool]$false
            $env.Tracker.SaveArguments.Count | Should -Be 1
            $env.Tracker.SaveArguments[0] | Should -BeOfType [bool]
            $env.Tracker.SaveArguments[0] | Should -BeFalse
        }

        It 'Suppresses UI prompts by strictly passing $false to Save($false) when RemoveDuplicates prunes rules' {
            $master = New-Challenger2Rule -Name 'Master' -SubjectText @('A') -Stop $true
            $dup = New-Challenger2Rule -Name 'Dup' -SubjectText @('A') -Stop $true
            $env = New-Challenger2RepairEnv -Rules @($master, $dup)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile2' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -RemoveDuplicates

            $res.Success | Should -BeTrue
            $env.Tracker.SaveCalls | Should -Be 1
            $env.Tracker.SaveArguments[0] | Should -BeFalse
        }

        It 'Suppresses UI prompts by strictly passing $false to Save($false) when RemoveEmpty prunes rules' {
            $empty = New-Challenger2Rule -Name 'Empty' -Enabled $false
            $env = New-Challenger2RepairEnv -Rules @($empty)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile2' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -RemoveEmpty

            $res.Success | Should -BeTrue
            $env.Tracker.SaveCalls | Should -Be 1
            $env.Tracker.SaveArguments[0] | Should -BeFalse
        }

        It 'Strictly NEVER invokes Save() in ScanOnly mode even when broken, duplicate, or empty rules exist' {
            $broken = New-Challenger2Rule -Name 'Broken' -MoveFolder $null -MoveEnabled $true -SubjectText @('A')
            $master = New-Challenger2Rule -Name 'Master' -SubjectText @('B') -Stop $true
            $dup = New-Challenger2Rule -Name 'Dup' -SubjectText @('B') -Stop $true
            $empty = New-Challenger2Rule -Name 'Empty' -Enabled $false
            $env = New-Challenger2RepairEnv -Rules @($broken, $master, $dup, $empty)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile2' } } -ModuleName 'Outlook'

            # Default mode (no -AutoRepair / -RemoveDuplicates / -RemoveEmpty)
            $res = Repair-OutlookRule -StorePath $env.Store.FilePath

            $res.Success | Should -BeTrue
            $res.Method | Should -Be 'ScanOnly'
            $res.BrokenRules.Count | Should -Be 1
            $res.DuplicateRules.Count | Should -Be 1
            $res.EmptyRules.Count | Should -Be 1
            # Save must NEVER be called
            $env.Tracker.SaveCalls | Should -Be 0
        }

        It 'Strictly NEVER invokes Save() when -AutoRepair is passed on an already healthy clean store' {
            $cleanRule1 = New-Challenger2Rule -Name 'Clean1' -SubjectText @('Test1') -MarkAsRead $true
            $cleanRule2 = New-Challenger2Rule -Name 'Clean2' -SubjectText @('Test2') -Delete $true
            $env = New-Challenger2RepairEnv -Rules @($cleanRule1, $cleanRule2)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile2' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -AutoRepair

            $res.Success | Should -BeTrue
            $res.RepairedRulesCount | Should -Be 0
            $res.RemovedDuplicatesCount | Should -Be 0
            $res.RemovedEmptyCount | Should -Be 0
            # No mutations performed -> zero Save calls
            $env.Tracker.SaveCalls | Should -Be 0
        }

        It 'Falls back to Save() without arguments if Save($false) throws an argument-unsupported COM exception' {
            $master = New-Challenger2Rule -Name 'Master' -SubjectText @('A') -Stop $true
            $dup = New-Challenger2Rule -Name 'Dup' -SubjectText @('A') -Stop $true
            $env = New-Challenger2RepairEnv -Rules @($master, $dup) -ThrowOnSaveArg $true
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile2' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -RemoveDuplicates

            $res.Success | Should -BeTrue
            # Primary call Save($false) failed, followed by fallback Save()
            $env.Tracker.SaveCalls | Should -Be 2
            $env.Tracker.SaveArguments[0] | Should -BeFalse
            $env.Tracker.SaveArguments[1] | Should -BeNullOrEmpty
        }

        It 'Handles failure gracefully and returns structured error object if both Save($false) and Save() fail' {
            $master = New-Challenger2Rule -Name 'Master' -SubjectText @('A') -Stop $true
            $dup = New-Challenger2Rule -Name 'Dup' -SubjectText @('A') -Stop $true
            $env = New-Challenger2RepairEnv -Rules @($master, $dup) -ThrowOnSaveAll $true
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile2' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath -RemoveDuplicates

            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'Failed to commit rules collection'
        }
    }

    # =========================================================================
    # Context 4: Deterministic COM Lifecycle & Exception Handling in Try/Finally
    # =========================================================================
    Context 'Deterministic COM Lifecycle & Exception Handling in Try/Finally' {

        It 'Deterministically releases COM application via Quit() when exception occurs in GetNamespace()' {
            $env = New-Challenger2RepairEnv -ThrowOnGetNamespace $true
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook' # Outlook not running prior
            Mock Get-Process { return @() }
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile2' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath

            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match "GetNamespace\('MAPI'\) threw fatal exception"

            # Finally block must execute Quit()
            $env.Tracker.QuitCalls | Should -Be 1
        }

        It 'Deterministically logs off and calls Quit() when exception occurs during GetRules()' {
            $env = New-Challenger2RepairEnv -ThrowOnGetRules $true
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook' # Outlook not running prior
            Mock Get-Process { return @() }
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile2' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath

            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'Failed to open Rules collection'

            # Finally block must execute Logoff() and Quit()
            $env.Tracker.LogonCalls | Should -Be 1
            $env.Tracker.LogoffCalls | Should -Be 1
            $env.Tracker.QuitCalls | Should -Be 1
        }

        It 'Deterministically cleans up COM objects when exception occurs during GetRootFolder()' {
            $env = New-Challenger2RepairEnv -ThrowOnGetRootFolder $true
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile2' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath

            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'Cannot access RootFolder'
            $env.Tracker.QuitCalls | Should -Be 1
            $env.Tracker.LogoffCalls | Should -Be 1
        }

        It 'Strictly preserves existing Outlook process by skipping Quit() when Outlook WAS running before execution, even on exception' {
            $env = New-Challenger2RepairEnv -ThrowOnGetRules $true
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            # Simulate pre-existing Outlook process
            Mock Get-Process { return @([PSCustomObject]@{ Id = 4321; ProcessName = 'OUTLOOK' }) } -ModuleName 'Outlook'
            Mock Get-Process { return @([PSCustomObject]@{ Id = 4321; ProcessName = 'OUTLOOK' }) }
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile2' } } -ModuleName 'Outlook'

            $res = Repair-OutlookRule -StorePath $env.Store.FilePath

            $res.Success | Should -BeFalse
            # Logoff still executes, but Quit() is strictly SKIPPED to avoid terminating the user's running Outlook
            $env.Tracker.LogoffCalls | Should -Be 1
            $env.Tracker.QuitCalls | Should -Be 0
        }

        It 'Passes all initialized COM references to Remove-ToolkitComObject on both success and exception paths' {
            $script:challengerReleasedObjs = [System.Collections.Generic.List[object]]::new()
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { if ($null -ne $o) { $script:challengerReleasedObjs.Add($o) } }
                }
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    foreach ($o in $ComObjects) { if ($null -ne $o) { $script:challengerReleasedObjs.Add($o) } }
                }
            }

            # 1. Success path
            $rule1 = New-Challenger2Rule -Name 'Test' -SubjectText @('A') -MarkAsRead $true
            $env1 = New-Challenger2RepairEnv -Rules @($rule1)
            Mock Get-OutlookComApplication { return $env1.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile2' } } -ModuleName 'Outlook'

            $res1 = Repair-OutlookRule -StorePath $env1.Store.FilePath
            $res1.Success | Should -BeTrue
            # Should have passed COM objects: rules, inbox, root, store, stores, ns, comApp
            $script:challengerReleasedObjs | Should -Contain $env1.App
            $script:challengerReleasedObjs | Should -Contain $env1.Namespace
            $script:challengerReleasedObjs | Should -Contain $env1.Store
            $script:challengerReleasedObjs | Should -Contain $env1.Rules

            # 2. Exception path
            $script:challengerReleasedObjs.Clear()
            $env2 = New-Challenger2RepairEnv -ThrowOnGetRules $true
            Mock Get-OutlookComApplication { return $env2.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile2' } } -ModuleName 'Outlook'

            $res2 = Repair-OutlookRule -StorePath $env2.Store.FilePath
            $res2.Success | Should -BeFalse
            # Even on exception, initialized objects are passed to Remove-ToolkitComObject
            $script:challengerReleasedObjs | Should -Contain $env2.App
            $script:challengerReleasedObjs | Should -Contain $env2.Namespace
            $script:challengerReleasedObjs | Should -Contain $env2.Store
        }
    }
}
