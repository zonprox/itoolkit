# Tests/Adversarial/ChallengerOutlookEdgeCases.Tests.ps1
# Adversarial Challenger Stress Harness for Outlook Folder Cloning, Rule Migration, and Edge Cases

BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../Modules/Outlook/Outlook.psd1'
    Import-Module $modulePath -Force

    $corePath = Join-Path -Path $PSScriptRoot -ChildPath '../../Modules/Core/Core.psd1'
    if (Test-Path -LiteralPath $corePath) {
        Import-Module $corePath -Force
    }

    # Factory for a comprehensive mock COM environment
    function script:New-ChallengerMockEnvironment {
        param(
            [string]$OldPstPath = 'C:\Data\SourceStore.pst',
            [string]$NewPstPath = 'C:\Data\TargetStore.pst'
        )

        # 1. Source Store Folders:
        # - Inbox
        #   - Level1
        #     - Level2
        #       - Level3
        #         - Level4
        # - System folders (Deleted Items, Sent Items, Junk Email)
        # - Custom Root Folder (Finance)
        #   - Invoices

        $mockLevel4 = [PSCustomObject]@{
            Name = 'Level4'
            FolderPath = "\\SourceStore\Inbox\Level1\Level2\Level3\Level4"
            Folders = [System.Collections.Generic.List[object]]::new()
        }
        $mockLevel3 = [PSCustomObject]@{
            Name = 'Level3'
            FolderPath = "\\SourceStore\Inbox\Level1\Level2\Level3"
            Folders = [System.Collections.Generic.List[object]]@($mockLevel4)
        }
        $mockLevel2 = [PSCustomObject]@{
            Name = 'Level2'
            FolderPath = "\\SourceStore\Inbox\Level1\Level2"
            Folders = [System.Collections.Generic.List[object]]@($mockLevel3)
        }
        $mockLevel1 = [PSCustomObject]@{
            Name = 'Level1'
            FolderPath = "\\SourceStore\Inbox\Level1"
            Folders = [System.Collections.Generic.List[object]]@($mockLevel2)
        }
        $mockInbox = [PSCustomObject]@{
            Name = 'Inbox'
            FolderPath = "\\SourceStore\Inbox"
            Folders = [System.Collections.Generic.List[object]]@($mockLevel1)
        }

        # System folders
        $mockDeleted = [PSCustomObject]@{
            Name = 'Deleted Items'
            FolderPath = "\\SourceStore\Deleted Items"
            Folders = [System.Collections.Generic.List[object]]::new()
        }
        $mockSent = [PSCustomObject]@{
            Name = 'Sent Items'
            FolderPath = "\\SourceStore\Sent Items"
            Folders = [System.Collections.Generic.List[object]]::new()
        }
        $mockJunk = [PSCustomObject]@{
            Name = 'Junk Email'
            FolderPath = "\\SourceStore\Junk Email"
            Folders = [System.Collections.Generic.List[object]]::new()
        }

        # Custom Root Folder
        $mockInvoices = [PSCustomObject]@{
            Name = 'Invoices'
            FolderPath = "\\SourceStore\Finance\Invoices"
            Folders = [System.Collections.Generic.List[object]]::new()
        }
        $mockFinance = [PSCustomObject]@{
            Name = 'Finance'
            FolderPath = "\\SourceStore\Finance"
            Folders = [System.Collections.Generic.List[object]]@($mockInvoices)
        }

        $mockSourceRoot = [PSCustomObject]@{
            Name = 'SourceStore'
            FolderPath = "\\SourceStore"
            Folders = [System.Collections.Generic.List[object]]@($mockInbox, $mockDeleted, $mockSent, $mockJunk, $mockFinance)
        }

        # 2. Target Store (initially empty folder structure)
        $mockTargetRoot = [PSCustomObject]@{
            Name = 'TargetStore'
            FolderPath = "\\TargetStore"
            Folders = [System.Collections.Generic.List[object]]::new()
        }

        $script:folderFactory = {
            param($FolderName)
            $childList = [System.Collections.Generic.List[object]]::new()
            $newChild = [PSCustomObject]@{
                Name = $FolderName
                FolderPath = "$($this.FolderPath)\$FolderName"
                Folders = $childList
            }
            $newChild | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $script:folderFactory
            $this.Folders.Add($newChild)
            return $newChild
        }
        $mockTargetRoot | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $script:folderFactory

        # 3. Source Rules
        # Rule A: MoveToFolder deeply nested Level4
        $mockRuleA = [PSCustomObject]@{
            Name = 'Move Deep'
            RuleType = 0
            Enabled = $true
            Conditions = [PSCustomObject]@{
                Subject = [PSCustomObject]@{ Enabled = $true; Text = @('DeepNested') }
            }
            Exceptions = [PSCustomObject]@{
                Subject = [PSCustomObject]@{ Enabled = $false; Text = @() }
            }
            Actions = [PSCustomObject]@{
                MoveToFolder = [PSCustomObject]@{ Folder = $mockLevel4; Enabled = $true }
                CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                Delete = [PSCustomObject]@{ Enabled = $false }
            }
        }

        # Rule B: CopyToFolder custom root subfolder Invoices
        $mockRuleB = [PSCustomObject]@{
            Name = 'Copy Invoices'
            RuleType = 0
            Enabled = $true
            Conditions = [PSCustomObject]@{
                From = [PSCustomObject]@{ Enabled = $true; Recipients = @('vendor@test.com') }
            }
            Exceptions = [PSCustomObject]@{
                Subject = [PSCustomObject]@{ Enabled = $true; Text = @('Spam') }
            }
            Actions = [PSCustomObject]@{
                MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                CopyToFolder = [PSCustomObject]@{ Folder = $mockInvoices; Enabled = $true }
                Delete = [PSCustomObject]@{ Enabled = $false }
            }
        }

        # Rule C: Rule WITHOUT MoveToFolder or CopyToFolder (e.g. Delete email action)
        $mockRuleC = [PSCustomObject]@{
            Name = 'Delete Phishing'
            RuleType = 0
            Enabled = $true
            Conditions = [PSCustomObject]@{
                Subject = [PSCustomObject]@{ Enabled = $true; Text = @('Suspicious Link') }
            }
            Exceptions = [PSCustomObject]@{
                Subject = [PSCustomObject]@{ Enabled = $false; Text = @() }
            }
            Actions = [PSCustomObject]@{
                MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                Delete = [PSCustomObject]@{ Enabled = $true }
            }
        }

        $mockSourceRulesList = [System.Collections.Generic.List[object]]@($mockRuleA, $mockRuleB, $mockRuleC)
        $mockSourceRules = [PSCustomObject]@{
            Count = $mockSourceRulesList.Count
            RulesList = $mockSourceRulesList
        }
        $mockSourceRules | Add-Member -MemberType ScriptMethod -Name GetEnumerator -Value { $this.RulesList.GetEnumerator() }
        $mockSourceRules | Add-Member -MemberType ScriptMethod -Name Item -Value { param($i) return $this.RulesList[$i] }

        # 4. Target Store Rules Collection (INITIALLY EMPTY)
        $mockTargetRulesList = [System.Collections.Generic.List[object]]::new()
        $mockTargetRules = [PSCustomObject]@{
            Count = 0
            RulesList = $mockTargetRulesList
        }
        $mockTargetRules | Add-Member -MemberType ScriptMethod -Name GetEnumerator -Value { $this.RulesList.GetEnumerator() }
        $mockTargetRules | Add-Member -MemberType ScriptMethod -Name Item -Value { param($i) return $this.RulesList[$i] }
        $mockTargetRules | Add-Member -MemberType ScriptMethod -Name Create -Value {
            param($Name, $RuleType)
            $createdRule = [PSCustomObject]@{
                Name = $Name
                RuleType = $RuleType
                Enabled = $false
                Conditions = [PSCustomObject]@{
                    Subject = [PSCustomObject]@{ Enabled = $false; Text = @() }
                    From    = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                }
                Exceptions = [PSCustomObject]@{
                    Subject = [PSCustomObject]@{ Enabled = $false; Text = @() }
                }
                Actions = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                    CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                    Delete = [PSCustomObject]@{ Enabled = $false }
                }
            }
            $this.RulesList.Add($createdRule)
            $this.Count = $this.RulesList.Count
            return $createdRule
        }
        $mockTargetRules | Add-Member -MemberType ScriptMethod -Name Save -Value { param($show) $script:targetRulesSaved = $true }

        # Stores
        $mockSourceStore = [PSCustomObject]@{
            DisplayName = 'Source Store'
            FilePath = $OldPstPath
            RootFolder = $mockSourceRoot
            Rules = $mockSourceRules
        }
        $mockSourceStore | Add-Member -MemberType ScriptMethod -Name GetRootFolder -Value { return $this.RootFolder }
        $mockSourceStore | Add-Member -MemberType ScriptMethod -Name GetRules -Value { return $this.Rules }

        $mockTargetStore = [PSCustomObject]@{
            DisplayName = 'Target Store'
            FilePath = $NewPstPath
            RootFolder = $mockTargetRoot
            Rules = $mockTargetRules
        }
        $mockTargetStore | Add-Member -MemberType ScriptMethod -Name GetRootFolder -Value { return $this.RootFolder }
        $mockTargetStore | Add-Member -MemberType ScriptMethod -Name GetRules -Value { return $this.Rules }

        $mockNs = [PSCustomObject]@{
            Stores = @($mockSourceStore, $mockTargetStore)
            DefaultStore = $mockSourceStore
        }
        $mockNs | Add-Member -MemberType ScriptMethod -Name AddStoreEx -Value { param($p, $t) }

        $mockApp = [PSCustomObject]@{
            MapiNamespace = $mockNs
        }
        $mockApp | Add-Member -MemberType ScriptMethod -Name GetNamespace -Value { param($n) return $this.MapiNamespace }
        $mockApp | Add-Member -MemberType ScriptMethod -Name Quit -Value { }

        return @{
            App = $mockApp
            Namespace = $mockNs
            SourceStore = $mockSourceStore
            TargetStore = $mockTargetStore
            SourceRoot = $mockSourceRoot
            TargetRoot = $mockTargetRoot
            SourceRules = $mockSourceRules
            TargetRules = $mockTargetRules
            RuleA = $mockRuleA
            RuleB = $mockRuleB
            RuleC = $mockRuleC
            Level4 = $mockLevel4
            Invoices = $mockInvoices
        }
    }
}

Describe 'Adversarial Challenge: Outlook Hierarchy Cloning & Rule Migration Edge Cases' {

    Context 'Edge Case 1: Rule with no MoveToFolder or CopyToFolder action' {
        It 'Preserves non-folder actions (such as Delete) when migrating rules' {
            $env = New-ChallengerMockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'

            $hierRes = Copy-OutlookFolderHierarchy -SourceStorePath $env.SourceStore.FilePath -TargetStorePath $env.TargetStore.FilePath
            $ruleRes = Copy-OutlookRule -SourceStorePath $env.SourceStore.FilePath -TargetStorePath $env.TargetStore.FilePath -FolderMap $hierRes.FolderMap

            $ruleRes.Success | Should -BeTrue
            $targetRuleC = $env.TargetRules.RulesList | Where-Object { $_.Name -eq 'Delete Phishing' }
            $targetRuleC | Should -Not -BeNullOrEmpty
            $targetRuleC.Actions.Delete.Enabled | Should -BeTrue
        }
    }

    Context 'Edge Case 2: Deeply nested subfolders (3+ levels)' {
        It 'Correctly clones 4-level deep hierarchy and remaps rule targeting Level 4' {
            $env = New-ChallengerMockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'

            $hierRes = Copy-OutlookFolderHierarchy -SourceStorePath $env.SourceStore.FilePath -TargetStorePath $env.TargetStore.FilePath
            $hierRes.Success | Should -BeTrue
            $hierRes.FolderMap.ContainsKey('Inbox\Level1\Level2\Level3\Level4') | Should -BeTrue

            $targetL4 = $hierRes.FolderMap['Inbox\Level1\Level2\Level3\Level4']
            $targetL4.FolderPath | Should -Be '\\TargetStore\Inbox\Level1\Level2\Level3\Level4'

            $ruleRes = Copy-OutlookRule -SourceStorePath $env.SourceStore.FilePath -TargetStorePath $env.TargetStore.FilePath -FolderMap $hierRes.FolderMap
            $ruleRes.Success | Should -BeTrue

            $targetRuleA = $env.TargetRules.RulesList | Where-Object { $_.Name -eq 'Move Deep' }
            $targetRuleA | Should -Not -BeNullOrEmpty
            $targetRuleA.Actions.MoveToFolder.Folder.FolderPath | Should -Be '\\TargetStore\Inbox\Level1\Level2\Level3\Level4'
        }
    }

    Context 'Edge Case 3: Standard system folders in source store' {
        It 'Skips system folders (Deleted Items, Sent Items, Junk Email) without duplicating them' {
            $env = New-ChallengerMockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'

            $hierRes = Copy-OutlookFolderHierarchy -SourceStorePath $env.SourceStore.FilePath -TargetStorePath $env.TargetStore.FilePath
            $hierRes.Success | Should -BeTrue

            $targetFolderNames = $env.TargetRoot.Folders | ForEach-Object { $_.Name }
            $targetFolderNames | Should -Not -Contain 'Deleted Items'
            $targetFolderNames | Should -Not -Contain 'Sent Items'
            $targetFolderNames | Should -Not -Contain 'Junk Email'
            $targetFolderNames | Should -Contain 'Inbox'
            $targetFolderNames | Should -Contain 'Finance'
        }
    }

    Context 'Edge Case 4: Rule condition and exception preservation when cloning to empty target store' {
        It 'Empirically verifies whether conditions (Subject, From) and exceptions are cloned to target store' {
            $env = New-ChallengerMockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'

            $hierRes = Copy-OutlookFolderHierarchy -SourceStorePath $env.SourceStore.FilePath -TargetStorePath $env.TargetStore.FilePath
            $ruleRes = Copy-OutlookRule -SourceStorePath $env.SourceStore.FilePath -TargetStorePath $env.TargetStore.FilePath -FolderMap $hierRes.FolderMap

            $targetRuleA = $env.TargetRules.RulesList | Where-Object { $_.Name -eq 'Move Deep' }
            $targetRuleA | Should -Not -BeNullOrEmpty
            $targetRuleA.Conditions.Subject.Enabled | Should -BeTrue
            $targetRuleA.Conditions.Subject.Text | Should -Contain 'DeepNested'

            $targetRuleB = $env.TargetRules.RulesList | Where-Object { $_.Name -eq 'Copy Invoices' }
            $targetRuleB | Should -Not -BeNullOrEmpty
            $targetRuleB.Conditions.From.Enabled | Should -BeTrue
            $targetRuleB.Exceptions.Subject.Enabled | Should -BeTrue
        }
    }

    Context 'Edge Case 5: -WhatIf mode verification' {
        It 'Does not modify folders or save rules in -WhatIf mode' {
            $env = New-ChallengerMockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            $script:targetRulesSaved = $false

            $hierWhatIf = Copy-OutlookFolderHierarchy -SourceStorePath $env.SourceStore.FilePath -TargetStorePath $env.TargetStore.FilePath -WhatIf
            $hierWhatIf.Method | Should -Be 'WhatIf'
            $env.TargetRoot.Folders.Count | Should -Be 0

            $ruleWhatIf = Copy-OutlookRule -SourceStorePath $env.SourceStore.FilePath -TargetStorePath $env.TargetStore.FilePath -WhatIf
            $ruleWhatIf.Method | Should -Be 'WhatIf'
            $env.TargetRules.RulesList.Count | Should -Be 0
            $script:targetRulesSaved | Should -BeFalse
        }
    }

    Context 'Edge Case 6: COM cleanup and object release' {
        It 'Releases COM objects via Remove-ToolkitComObject in both hierarchy and rule functions' {
            $env = New-ChallengerMockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            $script:comReleasedCount = 0
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($ComObjects) {
                    $script:comReleasedCount += $ComObjects.Count
                }
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($ComObjects) {
                    $script:comReleasedCount += $ComObjects.Count
                }
            }

            $hierRes = Copy-OutlookFolderHierarchy -SourceStorePath $env.SourceStore.FilePath -TargetStorePath $env.TargetStore.FilePath
            $script:comReleasedCount | Should -BeGreaterThan 0

            $beforeRules = $script:comReleasedCount
            $ruleRes = Copy-OutlookRule -SourceStorePath $env.SourceStore.FilePath -TargetStorePath $env.TargetStore.FilePath
            $script:comReleasedCount | Should -BeGreaterThan $beforeRules
        }
    }
}
