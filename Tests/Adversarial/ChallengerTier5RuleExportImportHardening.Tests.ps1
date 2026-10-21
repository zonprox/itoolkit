# ==============================================================================
# Tests/Adversarial/ChallengerTier5RuleExportImportHardening.Tests.ps1
# Milestone 5 Challenger Tier 5 Adversarial Coverage Hardening
# Targets:
#   1. Export-OutlookRule (Public/Export-OutlookRule.ps1)
#   2. Import-OutlookRule (Public/Import-OutlookRule.ps1)
#   3. Set-OutlookDefaultDataFile (Public/Set-OutlookDefaultDataFile.ps1)
#   4. Clear-OutlookStuckOutbox (Public/Clear-OutlookStuckOutbox.ps1)
# ==============================================================================

BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../Modules/Outlook/Outlook.psd1'
    Import-Module $modulePath -Force

    $corePath = Join-Path -Path $PSScriptRoot -ChildPath '../../Modules/Core/Core.psd1'
    if (Test-Path -LiteralPath $corePath) {
        Import-Module $corePath -Force
    }

    # Ensure C: drive alias exists for cross-platform test environments
    if (-not (Get-PSDrive -Name 'C' -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name 'C' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -ErrorAction SilentlyContinue | Out-Null
    }

    # Folder creation scriptblock for mock hierarchies
    $script:tier5FolderFactory = {
        param($childName)
        $childList = [System.Collections.Generic.List[object]]::new()
        $childPath = "$($this.FolderPath)\$childName"
        $child = [PSCustomObject]@{
            Name       = $childName
            FolderPath = $childPath
            Folders    = $childList
        }
        $child | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $script:tier5FolderFactory
        $this.Folders.Add($child)
        return $child
    }

    # Helper: Build mock COM environment for Export and Import
    function script:New-Tier5MockEnvironment {
        param(
            [string]$StorePath = 'C:\Data\Tier5Store.pst',
            [string]$StoreName = 'Tier5 Corporate Store',
            [object[]]$Rules = @(),
            [bool]$IsDefault = $true,
            [bool]$ThrowOnGetRules = $false,
            [bool]$ThrowOnSaveAll = $false
        )

        $tracker = [PSCustomObject]@{
            QuitCalls         = 0
            LogonCalls        = 0
            LogoffCalls       = 0
            SaveCalls         = 0
            LastSaveParam     = $null
            DeletedItemCount  = 0
        }

        # Folders
        $rootFolders = [System.Collections.Generic.List[object]]::new()
        $mockRootFolder = [PSCustomObject]@{
            Name       = $StoreName
            FolderPath = "\\$StoreName"
            Folders    = $rootFolders
        }
        $mockRootFolder | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $script:tier5FolderFactory

        $mockInbox = $mockRootFolder.AddFolder('Inbox')
        $null = $mockRootFolder.AddFolder('Sent Items')
        $null = $mockRootFolder.AddFolder('Deleted Items')

        # Rules
        $rulesList = [System.Collections.Generic.List[object]]::new()
        if ($null -ne $Rules) {
            foreach ($r in $Rules) { [void]$rulesList.Add($r) }
        }

        $mockRules = [PSCustomObject]@{
            Count     = $rulesList.Count
            RulesList = $rulesList
        }
        $mockRules | Add-Member -MemberType ScriptMethod -Name GetEnumerator -Value { $this.RulesList.GetEnumerator() }
        $mockRules | Add-Member -MemberType ScriptMethod -Name Item -Value { param($idx) return $this.RulesList[$idx] }
        $mockRules | Add-Member -MemberType ScriptMethod -Name Save -Value ({
            param($showProgress)
            $tracker.SaveCalls++
            $tracker.LastSaveParam = $showProgress
            if ($ThrowOnSaveAll) {
                throw [System.Runtime.InteropServices.COMException]::new("MAPI_E_FAILONEPROVIDER: Fatal store commit error.")
            }
        }.GetNewClosure())

        $mockRules | Add-Member -MemberType ScriptMethod -Name Create -Value {
            param($RuleName, $RuleType)
            $createdRule = [PSCustomObject]@{
                Name           = $RuleName
                RuleType       = $RuleType
                Enabled        = $false
                ExecutionOrder = $this.RulesList.Count + 1
                Conditions     = [PSCustomObject]@{
                    Subject          = [PSCustomObject]@{ Enabled = $false; Text = @() }
                    Body             = [PSCustomObject]@{ Enabled = $false; Text = @() }
                    BodyOrSubject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                    MessageHeader    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                    From             = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                    SentTo           = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                    SenderAddress    = [PSCustomObject]@{ Enabled = $false; Address = @() }
                    RecipientAddress = [PSCustomObject]@{ Enabled = $false; Address = @() }
                    Categories       = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                    Importance       = [PSCustomObject]@{ Enabled = $false; Importance = 1 }
                    Sensitivity      = [PSCustomObject]@{ Enabled = $false; Sensitivity = 0 }
                    Account          = [PSCustomObject]@{ Enabled = $false; Account = $null }
                    OnlyToMe         = [PSCustomObject]@{ Enabled = $false }
                    ToOrCc           = [PSCustomObject]@{ Enabled = $false }
                    Cc               = [PSCustomObject]@{ Enabled = $false }
                    SentOnlyToMe     = [PSCustomObject]@{ Enabled = $false }
                    NotToMe          = [PSCustomObject]@{ Enabled = $false }
                    HasAttachment    = [PSCustomObject]@{ Enabled = $false }
                }
                Exceptions     = [PSCustomObject]@{
                    Subject          = [PSCustomObject]@{ Enabled = $false; Text = @() }
                    From             = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                    SenderAddress    = [PSCustomObject]@{ Enabled = $false; Address = @() }
                    RecipientAddress = [PSCustomObject]@{ Enabled = $false; Address = @() }
                    Categories       = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                    Importance       = [PSCustomObject]@{ Enabled = $false; Importance = 1 }
                }
                Actions        = [PSCustomObject]@{
                    MoveToFolder     = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                    CopyToFolder     = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                    Delete           = [PSCustomObject]@{ Enabled = $false }
                    DeletePermanently= [PSCustomObject]@{ Enabled = $false }
                    MarkAsRead       = [PSCustomObject]@{ Enabled = $false }
                    Stop             = [PSCustomObject]@{ Enabled = $false }
                    ClearCategories  = [PSCustomObject]@{ Enabled = $false }
                    AssignToCategory = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                    PlaySound        = [PSCustomObject]@{ Enabled = $false; FilePath = $null }
                    NewItemAlert     = [PSCustomObject]@{ Enabled = $false; Text = $null }
                    MarkAsTask       = [PSCustomObject]@{ Enabled = $false; FlagTo = $null }
                    Forward          = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                    Redirect         = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                    Cc               = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                }
            }
            $this.RulesList.Add($createdRule)
            $this.Count = $this.RulesList.Count
            return $createdRule
        }

        # Store
        $mockStore = [PSCustomObject]@{
            DisplayName     = $StoreName
            Name            = $StoreName
            FilePath        = $StorePath
            IsDataFileStore = $true
            IsDefaultStore  = $IsDefault
            RootFolder      = $mockRootFolder
            Rules           = $mockRules
        }
        $mockStore | Add-Member -MemberType ScriptMethod -Name GetRootFolder -Value { return $this.RootFolder }
        $mockStore | Add-Member -MemberType ScriptMethod -Name GetRules -Value ({
            if ($ThrowOnGetRules) {
                throw [System.Runtime.InteropServices.COMException]::new("MAPI_E_CORRUPT_STORE: Rules table corrupt.")
            }
            return $this.Rules
        }.GetNewClosure())

        $mockStores = @($mockStore)

        # Namespace
        $mockNs = [PSCustomObject]@{
            DefaultStore = $mockStore
            Stores       = $mockStores
            Accounts     = @(
                [PSCustomObject]@{
                    DisplayName = 'Tier5 User'
                    Name        = 'Tier5 User'
                    SmtpAddress = 'tier5.user@corp.com'
                }
            )
        }
        $mockNs | Add-Member -MemberType ScriptMethod -Name Logon -Value ({
            param($p, $pwd, $ui, $new)
            $tracker.LogonCalls++
        }.GetNewClosure())
        $mockNs | Add-Member -MemberType ScriptMethod -Name Logoff -Value ({
            $tracker.LogoffCalls++
        }.GetNewClosure())

        # Application
        $mockApp = [PSCustomObject]@{
            MapiNamespace = $mockNs
        }
        $mockApp | Add-Member -MemberType ScriptMethod -Name GetNamespace -Value { param($ns) return $this.MapiNamespace }
        $mockApp | Add-Member -MemberType ScriptMethod -Name Quit -Value ({
            $tracker.QuitCalls++
        }.GetNewClosure())

        return @{
            Tracker    = $tracker
            App        = $mockApp
            Namespace  = $mockNs
            Store      = $mockStore
            RootFolder = $mockRootFolder
            Inbox      = $mockInbox
            Rules      = $mockRules
        }
    }
}

# ==============================================================================
# Suite 1: Export-OutlookRule Adversarial Coverage Hardening
# ==============================================================================
Describe 'Tier 5 Adversarial: Export-OutlookRule Edge Coverage' {

    Context 'Store Selection & Matching Variations' {
        It 'Matches store by StoreName when StorePath is not provided' {
            $env = New-Tier5MockEnvironment -StoreName 'Marketing Department PST' -StorePath 'C:\Data\Marketing.pst'
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "t5_export_storename_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StoreName 'Marketing Department PST'
                $res.Success | Should -BeTrue
                $res.Store | Should -Be 'Marketing Department PST'
                Test-Path -LiteralPath $testJson | Should -BeTrue
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Throws descriptive error when StoreName does not match any store in profile' {
            $env = New-Tier5MockEnvironment -StoreName 'Sales PST'
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "t5_export_ghost_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StoreName 'NonExistentStore'
                $res.Success | Should -BeFalse
                $res.ErrorMessage | Should -Match "name 'NonExistentStore'"
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }

    Context 'Sparse, Asymmetric & Flag-Only Rules Serialization' {
        It 'Serializes rule with only boolean condition flags (OnlyToMe, ToOrCc, HasAttachment)' {
            $flagRule = [PSCustomObject]@{
                Name           = 'Flag Only Rule'
                RuleType       = 0
                Enabled        = $true
                ExecutionOrder = 1
                Conditions     = [PSCustomObject]@{
                    OnlyToMe      = [PSCustomObject]@{ Enabled = $true }
                    ToOrCc        = [PSCustomObject]@{ Enabled = $true }
                    HasAttachment = [PSCustomObject]@{ Enabled = $true }
                }
                Exceptions     = [PSCustomObject]@{}
                Actions        = [PSCustomObject]@{
                    MarkAsRead = [PSCustomObject]@{ Enabled = $true }
                }
            }

            $env = New-Tier5MockEnvironment -Rules @($flagRule)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "t5_flag_rule_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $env.Store.FilePath
                $res.Success | Should -BeTrue
                $res.RulesExported | Should -Be 1

                $manifest = Get-Content -LiteralPath $testJson -Raw | ConvertFrom-Json
                $manifest.Rules[0].Conditions.OnlyToMe.Enabled | Should -BeTrue
                $manifest.Rules[0].Conditions.ToOrCc.Enabled | Should -BeTrue
                $manifest.Rules[0].Conditions.HasAttachment.Enabled | Should -BeTrue
                $manifest.Rules[0].Actions.MarkAsRead.Enabled | Should -BeTrue
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Serializes rule with non-folder actions (DeletePermanently, ClearCategories, AssignToCategory, PlaySound, NewItemAlert)' {
            $specialActionRule = [PSCustomObject]@{
                Name           = 'Action Heavy Rule'
                RuleType       = 0
                Enabled        = $true
                ExecutionOrder = 2
                Conditions     = [PSCustomObject]@{
                    Subject = [PSCustomObject]@{ Enabled = $true; Text = @('AlertNotification') }
                }
                Exceptions     = [PSCustomObject]@{}
                Actions        = [PSCustomObject]@{
                    DeletePermanently = [PSCustomObject]@{ Enabled = $true }
                    ClearCategories   = [PSCustomObject]@{ Enabled = $true }
                    AssignToCategory  = [PSCustomObject]@{ Enabled = $true; Categories = @('Tier5Alert', 'Automation') }
                    PlaySound         = [PSCustomObject]@{ Enabled = $true; FilePath = 'C:\Sounds\alert.wav' }
                    NewItemAlert      = [PSCustomObject]@{ Enabled = $true; Text = 'New critical item received' }
                }
            }

            $env = New-Tier5MockEnvironment -Rules @($specialActionRule)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "t5_special_actions_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $env.Store.FilePath
                $res.Success | Should -BeTrue

                $manifest = Get-Content -LiteralPath $testJson -Raw | ConvertFrom-Json
                $manifest.Rules[0].Actions.DeletePermanently.Enabled | Should -BeTrue
                $manifest.Rules[0].Actions.ClearCategories.Enabled | Should -BeTrue
                $manifest.Rules[0].Actions.AssignToCategory.Categories | Should -Contain 'Tier5Alert'
                $manifest.Rules[0].Actions.PlaySound.FilePath | Should -Be 'C:\Sounds\alert.wav'
                $manifest.Rules[0].Actions.NewItemAlert.Text | Should -Be 'New critical item received'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Exports empty rule table cleanly without throwing and outputs Rules array' {
            $env = New-Tier5MockEnvironment -Rules @()
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "t5_empty_rules_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $env.Store.FilePath
                $res.Success | Should -BeTrue
                $res.RulesExported | Should -Be 0

                $manifest = Get-Content -LiteralPath $testJson -Raw | ConvertFrom-Json
                $manifest.Rules.Count | Should -Be 0
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }

    Context 'File Collision, Force & Pipeline Hardening' {
        It 'Refuses to overwrite existing JSON file without -Force and does not mutate it' {
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "t5_collision_$([System.Guid]::NewGuid().ToString('N')).json"
            Set-Content -LiteralPath $testJson -Value '{"Original": "Untouched"}' -Encoding UTF8

            $env = New-Tier5MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $env.Store.FilePath
                $res.Success | Should -BeFalse
                $res.ErrorMessage | Should -Match "already exists"

                $content = Get-Content -LiteralPath $testJson -Raw
                $content | Should -Match '"Original": "Untouched"'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Overwrites existing JSON file cleanly when -Force is passed' {
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "t5_force_overwrite_$([System.Guid]::NewGuid().ToString('N')).json"
            Set-Content -LiteralPath $testJson -Value '{"Original": "ToReplace"}' -Encoding UTF8

            $env = New-Tier5MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $env.Store.FilePath -Force
                $res.Success | Should -BeTrue

                $manifest = Get-Content -LiteralPath $testJson -Raw | ConvertFrom-Json
                $manifest.ExportedBy | Should -Be 'IToolkit'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Accepts string path directly from pipeline' {
            $env = New-Tier5MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "t5_string_pipe_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = $testJson | Export-OutlookRule -StorePath $env.Store.FilePath
                $res.Success | Should -BeTrue
                Test-Path -LiteralPath $testJson | Should -BeTrue
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }
}

# ==============================================================================
# Suite 2: Import-OutlookRule Duplicate Policies & Deep Folder Hardening
# ==============================================================================
Describe 'Tier 5 Adversarial: Import-OutlookRule Duplicate & Remapping Hardening' {

    # Helper: Build a minimal manifest file on disk
    function script:New-Tier5ManifestFile {
        param(
            [string]$Path,
            [object[]]$Rules = @(),
            [string[]]$CustomFolders = @()
        )
        $manifestObj = [ordered]@{
            ManifestVersion = '1.0.0'
            SchemaVersion   = '1.0.0'
            ExportTimestamp = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            ExportedBy      = 'IToolkit'
            SourceContext   = [ordered]@{
                ProfileName        = 'SourceProfile'
                StoreName          = 'SourceStore'
                StoreDisplayName   = 'SourceStore'
                StoreFilePath      = 'C:\Data\Source.pst'
                AccountName        = 'SourceUser'
                PrimarySmtpAddress = 'source.user@oldcorp.com'
                OfficeVersion      = '16.0'
            }
            CustomFolders   = $CustomFolders
            Rules           = $Rules
        }
        $json = $manifestObj | ConvertTo-Json -Depth 10
        Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
    }

    Context 'Collision Cascades Across All Duplicate Policies' {
        It 'Policy Rename: Disambiguates collision cascade to (Imported 3) when (Imported 2) already exists' {
            $ruleName = 'SecurityAlert'
            $existingR1 = [PSCustomObject]@{ Name = $ruleName; RuleType = 0; Enabled = $true; Conditions = [PSCustomObject]@{}; Actions = [PSCustomObject]@{} }
            $existingR2 = [PSCustomObject]@{ Name = "$ruleName (Imported)"; RuleType = 0; Enabled = $true; Conditions = [PSCustomObject]@{}; Actions = [PSCustomObject]@{} }
            $existingR3 = [PSCustomObject]@{ Name = "$ruleName (Imported 2)"; RuleType = 0; Enabled = $true; Conditions = [PSCustomObject]@{}; Actions = [PSCustomObject]@{} }

            $env = New-Tier5MockEnvironment -Rules @($existingR1, $existingR2, $existingR3)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            $incomingRule = [ordered]@{
                Name       = $ruleName
                RuleType   = 0
                Enabled    = $true
                Conditions = [ordered]@{ Subject = [ordered]@{ Enabled = $true; Text = @('Security') } }
                Actions    = [ordered]@{ MarkAsRead = [ordered]@{ Enabled = $true } }
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "t5_rename_cascade_$([System.Guid]::NewGuid().ToString('N')).json"
            New-Tier5ManifestFile -Path $testJson -Rules @($incomingRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'Rename'
                $res.Success | Should -BeTrue
                $res.RulesRenamed | Should -Be 1
                $res.RulesImported | Should -Be 1

                # Verify created rule was named (Imported 3)
                $env.Rules.RulesList[-1].Name | Should -Be "$ruleName (Imported 3)"
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Policy KeepBoth: Disambiguates collision cascade to (3) when (2) already exists' {
            $ruleName = 'BillingNotice'
            $existingR1 = [PSCustomObject]@{ Name = $ruleName; RuleType = 0; Enabled = $true; Conditions = [PSCustomObject]@{}; Actions = [PSCustomObject]@{} }
            $existingR2 = [PSCustomObject]@{ Name = "$ruleName (1)"; RuleType = 0; Enabled = $true; Conditions = [PSCustomObject]@{}; Actions = [PSCustomObject]@{} }
            $existingR3 = [PSCustomObject]@{ Name = "$ruleName (2)"; RuleType = 0; Enabled = $true; Conditions = [PSCustomObject]@{}; Actions = [PSCustomObject]@{} }

            $env = New-Tier5MockEnvironment -Rules @($existingR1, $existingR2, $existingR3)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            $incomingRule = [ordered]@{
                Name       = $ruleName
                RuleType   = 0
                Enabled    = $true
                Conditions = [ordered]@{ Subject = [ordered]@{ Enabled = $true; Text = @('Invoice') } }
                Actions    = [ordered]@{ MarkAsRead = [ordered]@{ Enabled = $true } }
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "t5_keepboth_cascade_$([System.Guid]::NewGuid().ToString('N')).json"
            New-Tier5ManifestFile -Path $testJson -Rules @($incomingRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'KeepBoth'
                $res.Success | Should -BeTrue
                $res.RulesRenamed | Should -Be 1
                $res.RulesImported | Should -Be 1

                # Verify created rule was named (3)
                $env.Rules.RulesList[-1].Name | Should -Be "$ruleName (3)"
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Policy Overwrite: Accurately updates existing rule in-place and clears previous action folder' {
            $ruleName = 'ProjectSync'
            $oldFolder = [PSCustomObject]@{ Name = 'OldFolder'; FolderPath = '\\Store\OldFolder' }
            $existingRule = [PSCustomObject]@{
                Name       = $ruleName
                RuleType   = 0
                Enabled    = $true
                Conditions = [PSCustomObject]@{
                    Subject = [PSCustomObject]@{ Enabled = $true; Text = @('OldTag') }
                }
                Exceptions = [PSCustomObject]@{}
                Actions    = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Enabled = $true; Folder = $oldFolder }
                    MarkAsRead   = [PSCustomObject]@{ Enabled = $false }
                }
            }

            $env = New-Tier5MockEnvironment -Rules @($existingRule)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            $incomingRule = [ordered]@{
                Name       = $ruleName
                RuleType   = 0
                Enabled    = $true
                Conditions = [ordered]@{
                    Subject = [ordered]@{ Enabled = $true; Text = @('NewTag') }
                }
                Actions    = [ordered]@{
                    MarkAsRead = [ordered]@{ Enabled = $true }
                }
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "t5_overwrite_inplace_$([System.Guid]::NewGuid().ToString('N')).json"
            New-Tier5ManifestFile -Path $testJson -Rules @($incomingRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'Overwrite'
                $res.Success | Should -BeTrue
                $res.RulesOverwritten | Should -Be 1
                $res.RulesImported | Should -Be 1

                # Check in-place reset: MoveToFolder should be disabled and folder null
                $existingRule.Actions.MoveToFolder.Enabled | Should -BeFalse
                $existingRule.Actions.MoveToFolder.Folder | Should -BeNullOrEmpty
                $existingRule.Actions.MarkAsRead.Enabled | Should -BeTrue
                $existingRule.Conditions.Subject.Text | Should -Contain 'NewTag'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Policy Skip: Strictly keeps existing rule intact and increments RulesSkipped' {
            $ruleName = 'DoNotTouch'
            $existingRule = [PSCustomObject]@{
                Name       = $ruleName
                RuleType   = 0
                Enabled    = $true
                Conditions = [PSCustomObject]@{ Subject = [PSCustomObject]@{ Enabled = $true; Text = @('Original') } }
                Actions    = [PSCustomObject]@{ MarkAsRead = [PSCustomObject]@{ Enabled = $false } }
            }

            $env = New-Tier5MockEnvironment -Rules @($existingRule)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            $incomingRule = [ordered]@{
                Name       = $ruleName
                RuleType   = 0
                Enabled    = $true
                Conditions = [ordered]@{ Subject = [ordered]@{ Enabled = $true; Text = @('Modified') } }
                Actions    = [ordered]@{ MarkAsRead = [ordered]@{ Enabled = $true } }
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "t5_skip_strict_$([System.Guid]::NewGuid().ToString('N')).json"
            New-Tier5ManifestFile -Path $testJson -Rules @($incomingRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'Skip'
                $res.Success | Should -BeTrue
                $res.RulesSkipped | Should -Be 1
                $res.RulesImported | Should -Be 0

                $existingRule.Conditions.Subject.Text | Should -Contain 'Original'
                $existingRule.Actions.MarkAsRead.Enabled | Should -BeFalse
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }

    Context 'Deep Multi-Tier Folder Reconstruction & Slash Formats' {
        It 'Reconstructs a 5-level deep folder branch and binds MoveToFolder action accurately' {
            $env = New-Tier5MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            $deepPath = 'Reports\APAC\Regional\Quarterly\Q4'
            $incomingRule = [ordered]@{
                Name       = 'Route Deep Reports'
                RuleType   = 0
                Enabled    = $true
                Conditions = [ordered]@{ Subject = [ordered]@{ Enabled = $true; Text = @('Quarterly Report') } }
                Actions    = [ordered]@{ MoveToFolder = [ordered]@{ Enabled = $true; FolderPath = $deepPath } }
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "t5_deep_reconstruct_$([System.Guid]::NewGuid().ToString('N')).json"
            New-Tier5ManifestFile -Path $testJson -Rules @($incomingRule) -CustomFolders @($deepPath)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -AutoCreateFolders
                $res.Success | Should -BeTrue
                $res.FoldersCreated | Should -Be 5
                $res.RulesImported | Should -Be 1

                # Check created rule MoveToFolder folder binding
                $importedRule = $env.Rules.RulesList[0]
                $importedRule.Actions.MoveToFolder.Folder | Should -Not -BeNullOrEmpty
                $importedRule.Actions.MoveToFolder.Folder.Name | Should -Be 'Q4'
                $importedRule.Actions.MoveToFolder.Enabled | Should -BeTrue
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Normalizes forward slashes in target folder paths (e.g. Inbox/Project/Logs)' {
            $env = New-Tier5MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            $slashPath = 'Inbox/Project/Logs'
            $incomingRule = [ordered]@{
                Name       = 'Forward Slash Rule'
                RuleType   = 0
                Enabled    = $true
                Conditions = [ordered]@{ Subject = [ordered]@{ Enabled = $true; Text = @('Log File') } }
                Actions    = [ordered]@{ MoveToFolder = [ordered]@{ Enabled = $true; FolderPath = $slashPath } }
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "t5_slash_path_$([System.Guid]::NewGuid().ToString('N')).json"
            New-Tier5ManifestFile -Path $testJson -Rules @($incomingRule) -CustomFolders @($slashPath)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -AutoCreateFolders
                $res.Success | Should -BeTrue
                $res.FoldersCreated | Should -Be 2 # 'Project' and 'Logs' under Inbox

                $importedRule = $env.Rules.RulesList[0]
                $importedRule.Actions.MoveToFolder.Folder | Should -Not -BeNullOrEmpty
                $importedRule.Actions.MoveToFolder.Folder.Name | Should -Be 'Logs'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Leaves folder action disabled when target folder does not exist and -AutoCreateFolders is $false' {
            $env = New-Tier5MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            $missingPath = 'MissingCategory\SubMissing'
            $incomingRule = [ordered]@{
                Name       = 'No Auto Create Rule'
                RuleType   = 0
                Enabled    = $true
                Conditions = [ordered]@{ Subject = [ordered]@{ Enabled = $true; Text = @('Audit') } }
                Actions    = [ordered]@{ MoveToFolder = [ordered]@{ Enabled = $true; FolderPath = $missingPath } }
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "t5_no_autocreate_$([System.Guid]::NewGuid().ToString('N')).json"
            New-Tier5ManifestFile -Path $testJson -Rules @($incomingRule) -CustomFolders @($missingPath)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -AutoCreateFolders:$false
                $res.Success | Should -BeTrue
                $res.FoldersCreated | Should -Be 0
                $res.RulesImported | Should -Be 1

                # Rule is created, but MoveToFolder action remains unbound
                $importedRule = $env.Rules.RulesList[0]
                $importedRule.Actions.MoveToFolder.Folder | Should -BeNullOrEmpty
                $importedRule.Actions.MoveToFolder.Enabled | Should -BeFalse
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }

    Context 'Complex Parameter Remapping & Force Enable' {
        It 'Remaps wildcards and bracketed emails across conditions, exceptions, and action recipients' {
            $env = New-Tier5MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            $incomingRule = [ordered]@{
                Name       = 'Address Remapping Test'
                RuleType   = 0
                Enabled    = $true
                Conditions = [ordered]@{
                    From             = [ordered]@{ Enabled = $true; Recipients = @('Billing Team <billing@oldcorp.com>') }
                    RecipientAddress = [ordered]@{ Enabled = $true; Address = @('support@oldcorp.com') }
                }
                Exceptions = [ordered]@{
                    From = [ordered]@{ Enabled = $true; Recipients = @('vip@oldcorp.com') }
                }
                Actions    = [ordered]@{
                    Forward = [ordered]@{ Enabled = $true; Recipients = @('archive@oldcorp.com') }
                }
            }

            $addrMap = @{
                'billing@oldcorp.com' = 'billing@newcorp.org'
                '@oldcorp.com'        = '@newcorp.org'
                'vip@oldcorp.com'     = 'vip@newcorp.org'
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "t5_addr_remap_$([System.Guid]::NewGuid().ToString('N')).json"
            New-Tier5ManifestFile -Path $testJson -Rules @($incomingRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -AddressMap $addrMap
                $res.Success | Should -BeTrue

                $importedRule = $env.Rules.RulesList[0]
                $importedRule.Conditions.From.Recipients | Should -Contain 'Billing Team <billing@newcorp.org>'
                $importedRule.Conditions.RecipientAddress.Address | Should -Contain 'support@newcorp.org'
                $importedRule.Exceptions.From.Recipients | Should -Contain 'vip@newcorp.org'
                $importedRule.Actions.Forward.Recipients | Should -Contain 'archive@newcorp.org'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Forces rule to Enabled state when -EnableImportedRules is passed, even if rule was disabled' {
            $env = New-Tier5MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            $disabledRule = [ordered]@{
                Name       = 'Disabled Source Rule'
                RuleType   = 0
                Enabled    = $false
                Conditions = [ordered]@{ Subject = [ordered]@{ Enabled = $true; Text = @('Disabled') } }
                Actions    = [ordered]@{ MarkAsRead = [ordered]@{ Enabled = $true } }
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "t5_force_enable_$([System.Guid]::NewGuid().ToString('N')).json"
            New-Tier5ManifestFile -Path $testJson -Rules @($disabledRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -EnableImportedRules
                $res.Success | Should -BeTrue

                $importedRule = $env.Rules.RulesList[0]
                $importedRule.Enabled | Should -BeTrue
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }
}

# ==============================================================================
# Suite 3: Set-OutlookDefaultDataFile & Clear-OutlookStuckOutbox COM Hardening
# ==============================================================================
Describe 'Tier 5 Adversarial: Default DataFile & Outbox COM Hardening' {

    Context 'Set-OutlookDefaultDataFile Validation & COM Lifecycle' {
        It 'Rejects non-pst/ost extensions with terminating error without touching COM' {
            $mockAppCalled = $false
            Mock Get-OutlookComApplication {
                $mockAppCalled = $true
                return $null
            } -ModuleName 'Outlook'

            { Set-OutlookDefaultDataFile -Path 'C:\Data\InvalidFile.docx' } | Should -Throw "*must have a .pst or .ost extension*"
            $mockAppCalled | Should -BeFalse
        }

        It 'Detects store already default via COM and avoids launching profile GUI' {
            $env = New-Tier5MockEnvironment -IsDefault $true
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            $startProcCalled = $false
            Mock Start-Process {
                $startProcCalled = $true
                return [PSCustomObject]@{ Id = 9999 }
            }

            $res = Set-OutlookDefaultDataFile -Path $env.Store.FilePath
            $res.Success | Should -BeTrue
            $res.Method | Should -Be 'COM'
            $res.FallbackTriggered | Should -BeFalse
            $startProcCalled | Should -BeFalse
            $env.Tracker.QuitCalls | Should -Be 1
        }
    }

    Context 'Clear-OutlookStuckOutbox Multi-Item Reverse Purge & Safety' {
        It 'Warns and aborts when Outlook is running without -Force switch' {
            Mock Get-Process { return @([PSCustomObject]@{ ProcessName = 'OUTLOOK'; Id = 1234 }) } -ModuleName 'Outlook'
            Mock Get-Process { return @([PSCustomObject]@{ ProcessName = 'OUTLOOK'; Id = 1234 }) }

            $res = Clear-OutlookStuckOutbox -ProfileName 'CorporateProfile'
            $res.Status | Should -Be 'Warning'
            $res.ClearedMessages | Should -Be 0
            $res.ErrorMessage | Should -Match 'holding Outbox message locks'
        }

        It 'Purges multiple stuck messages in reverse index order when -Force is passed' {
            $script:procCalls = 0
            Mock Get-Process {
                param($Name)
                $script:procCalls++
                if ($script:procCalls -eq 1) { return @([PSCustomObject]@{ ProcessName = 'OUTLOOK'; Id = 2345 }) }
                return @()
            } -ModuleName 'Outlook'
            Mock Get-Process {
                param($Name)
                $script:procCalls++
                if ($script:procCalls -eq 1) { return @([PSCustomObject]@{ ProcessName = 'OUTLOOK'; Id = 2345 }) }
                return @()
            }
            Mock Stop-ToolkitProcess { [PSCustomObject]@{ Terminated = $true } }
            Mock Set-ToolkitRegistryValue { }

            # Create 3 stuck messages in outbox
            $deletedIds = [System.Collections.Generic.List[int]]::new()
            $mockItem1 = [PSCustomObject]@{ Id = 1 }
            $mockItem1 | Add-Member -MemberType ScriptMethod -Name Delete -Value ({ $deletedIds.Add(1) }.GetNewClosure())
            $mockItem2 = [PSCustomObject]@{ Id = 2 }
            $mockItem2 | Add-Member -MemberType ScriptMethod -Name Delete -Value ({ $deletedIds.Add(2) }.GetNewClosure())
            $mockItem3 = [PSCustomObject]@{ Id = 3 }
            $mockItem3 | Add-Member -MemberType ScriptMethod -Name Delete -Value ({ $deletedIds.Add(3) }.GetNewClosure())

            $mockOutbox = [PSCustomObject]@{
                Name  = 'Outbox'
                Items = [System.Collections.Generic.List[object]]@($mockItem1, $mockItem2, $mockItem3)
            }

            $tracker = [PSCustomObject]@{ QuitCalls = 0; LogoffCalls = 0 }
            $mockNs = [PSCustomObject]@{
                Outbox = $mockOutbox
            }
            $mockNs | Add-Member -MemberType ScriptMethod -Name Logon -Value { param($p, $pwd, $ui, $new) }
            $mockNs | Add-Member -MemberType ScriptMethod -Name Logoff -Value ({ $tracker.LogoffCalls++ }.GetNewClosure())
            $mockNs | Add-Member -MemberType ScriptMethod -Name GetDefaultFolder -Value { param($f) return $this.Outbox }

            $mockApp = [PSCustomObject]@{ MapiNamespace = $mockNs }
            $mockApp | Add-Member -MemberType ScriptMethod -Name GetNamespace -Value { param($n) return $this.MapiNamespace }
            $mockApp | Add-Member -MemberType ScriptMethod -Name Quit -Value ({ $tracker.QuitCalls++ }.GetNewClosure())

            Mock Get-OutlookComApplication { return $mockApp } -ModuleName 'Outlook'

            $res = Clear-OutlookStuckOutbox -Force
            $res.Status | Should -Be 'Success'
            $res.ClearedMessages | Should -Be 3
            $tracker.QuitCalls | Should -Be 1
            $tracker.LogoffCalls | Should -Be 1

            # Reverse deletion order: 3 then 2 then 1
            $deletedIds[0] | Should -Be 3
            $deletedIds[1] | Should -Be 2
            $deletedIds[2] | Should -Be 1
        }
    }
}
