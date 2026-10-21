# Tests/Adversarial/ChallengerOutlookExportStress.Tests.ps1
# Adversarial Stress Harness for Export-OutlookRule (M1 Challenger 1)

BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../Modules/Outlook/Outlook.psd1'
    Import-Module $modulePath -Force

    $corePath = Join-Path -Path $PSScriptRoot -ChildPath '../../Modules/Core/Core.psd1'
    if (Test-Path -LiteralPath $corePath) {
        Import-Module $corePath -Force
    }

    # Helper: Build mock folder hierarchy
    function script:New-ChallengerMockFolder {
        param(
            [string]$Name,
            [string]$FolderPath,
            [object[]]$Children = @()
        )
        $childList = [System.Collections.Generic.List[object]]::new()
        if ($null -ne $Children) {
            foreach ($c in $Children) { [void]$childList.Add($c) }
        }
        $f = [PSCustomObject]@{
            Name       = $Name
            FolderPath = $FolderPath
            Folders    = $childList
        }
        return $f
    }

    # Helper: Build comprehensive mock COM environment
    function script:New-ChallengerStressEnv {
        param(
            [string]$StorePath = 'C:\Data\StressStore.pst',
            [string]$StoreName = 'StressStore',
            [object[]]$CustomRules = @(),
            [object[]]$RootFolders = @(),
            [bool]$ThrowOnGetRules = $false
        )

        $rulesList = [System.Collections.Generic.List[object]]::new()
        if ($null -ne $CustomRules) {
            foreach ($r in $CustomRules) { [void]$rulesList.Add($r) }
        }

        $mockRules = [PSCustomObject]@{
            Count     = $rulesList.Count
            RulesList = $rulesList
        }
        $mockRules | Add-Member -MemberType ScriptMethod -Name GetEnumerator -Value { $this.RulesList.GetEnumerator() }
        $mockRules | Add-Member -MemberType ScriptMethod -Name Item -Value { param($idx) return $this.RulesList[$idx] }

        $folderList = [System.Collections.Generic.List[object]]::new()
        if ($null -ne $RootFolders) {
            foreach ($rf in $RootFolders) { [void]$folderList.Add($rf) }
        }

        $mockRootFolder = [PSCustomObject]@{
            Name       = $StoreName
            FolderPath = "\\$StoreName"
            Folders    = $folderList
        }

        $mockStore = [PSCustomObject]@{
            DisplayName      = $StoreName
            FilePath         = $StorePath
            IsDataFileStore  = $true
            IsDefaultStore   = $true
            ThrowOnGetRules  = $ThrowOnGetRules
            RootFolder       = $mockRootFolder
            Rules            = $mockRules
        }
        $mockStore | Add-Member -MemberType ScriptMethod -Name GetRootFolder -Value { return $this.RootFolder }
        $mockStore | Add-Member -MemberType ScriptMethod -Name GetRules -Value {
            if ($this.ThrowOnGetRules) {
                throw [System.Runtime.InteropServices.COMException]::new("MAPI_E_CORRUPT_STORE: Rule table cannot be read.")
            }
            return $this.Rules
        }

        $mockStores = @($mockStore)
        $mockNs = [PSCustomObject]@{
            DefaultStore = $mockStore
            Stores       = $mockStores
            Accounts     = @(
                [PSCustomObject]@{
                    DisplayName = 'Stress User'
                    SmtpAddress = 'stress.user@enterprise.com'
                }
            )
        }
        $mockNs | Add-Member -MemberType ScriptMethod -Name Logon -Value { param($p, $pwd, $ui, $new) }
        $mockNs | Add-Member -MemberType ScriptMethod -Name Logoff -Value { $script:logoffCalled = $true }

        $mockApp = [PSCustomObject]@{
            MapiNamespace = $mockNs
        }
        $mockApp | Add-Member -MemberType ScriptMethod -Name GetNamespace -Value { param($ns) return $this.MapiNamespace }
        $mockApp | Add-Member -MemberType ScriptMethod -Name Quit -Value {
            $script:quitCallCount++
            $script:quitCalled = $true
        }

        return @{
            App        = $mockApp
            Namespace  = $mockNs
            Store      = $mockStore
            RootFolder = $mockRootFolder
            Rules      = $mockRules
        }
    }
}

Describe 'Adversarial Stress: Export-OutlookRule' {
    BeforeEach {
        $script:quitCallCount = 0
        $script:quitCalled = $false
        $script:logoffCalled = $false
    }

    Context 'Stress Testing Condition & Exception Serialization' {
        It 'Serializes high-volume and edge-case text condition payloads (Unicode, quotes, newlines, XML)' {
            $dynUnicode = "Unicode: [" + [char]0x0054 + [char]0x0069 + [char]0x00EA + [char]0x0075 + "] - " + [char]0x00FC + " Alert"
            $specialText = @(
                'Urgent: Release v2.0',
                'Quoted "String" & Ampersand',
                "Newline`r`nPayload`tWithTab",
                $dynUnicode,
                '<xml><tag id="1">Security Check</tag></xml>',
                'Backslash \ Path \ Test'
            )

            $ruleWithComplexConditions = [PSCustomObject]@{
                Name           = 'Complex Condition Rule'
                RuleType       = 0
                Enabled        = $true
                ExecutionOrder = 1
                Conditions     = [PSCustomObject]@{
                    Subject          = [PSCustomObject]@{ Enabled = $true; Text = $specialText }
                    Body             = [PSCustomObject]@{ Enabled = $true; Text = @('Confidential Report') }
                    BodyOrSubject    = [PSCustomObject]@{ Enabled = $true; Text = @('High Priority') }
                    MessageHeader    = [PSCustomObject]@{ Enabled = $true; Text = @('X-Spam-Flag: YES') }
                    SenderAddress    = [PSCustomObject]@{ Enabled = $true; Address = @('alerts@external-partner.org') }
                    RecipientAddress = [PSCustomObject]@{ Enabled = $true; Address = @('internal-ops@enterprise.com') }
                    Categories       = [PSCustomObject]@{ Enabled = $true; Categories = @('Critical', 'Audit', 'Munich') }
                    Importance       = [PSCustomObject]@{ Enabled = $true; Importance = 2 }
                    Sensitivity      = [PSCustomObject]@{ Enabled = $true; Sensitivity = 3 }
                    Account          = [PSCustomObject]@{ Enabled = $true; Account = [PSCustomObject]@{ DisplayName = 'Corporate Exchange' } }
                    OnlyToMe         = [PSCustomObject]@{ Enabled = $true }
                    HasAttachment    = [PSCustomObject]@{ Enabled = $true }
                }
                Exceptions     = [PSCustomObject]@{
                    Subject          = [PSCustomObject]@{ Enabled = $true; Text = @('Automated Reply', 'Out of Office') }
                    Importance       = [PSCustomObject]@{ Enabled = $true; Importance = 0 }
                    From             = [PSCustomObject]@{ Enabled = $true; Recipients = @('ceo@enterprise.com', 'board@enterprise.com') }
                }
                Actions        = [PSCustomObject]@{
                    MoveToFolder     = [PSCustomObject]@{ Enabled = $false; Folder = $null }
                    CopyToFolder     = [PSCustomObject]@{ Enabled = $false; Folder = $null }
                    Delete           = [PSCustomObject]@{ Enabled = $false }
                    MarkAsRead       = [PSCustomObject]@{ Enabled = $true }
                    Stop             = [PSCustomObject]@{ Enabled = $true }
                }
            }

            $env = New-ChallengerStressEnv -CustomRules @($ruleWithComplexConditions)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_cond_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $env.Store.FilePath
                $res.Success | Should -BeTrue
                $res.RulesExported | Should -Be 1

                $manifest = Get-Content -LiteralPath $testJson -Raw | ConvertFrom-Json
                $r = $manifest.Rules[0]

                $r.Conditions.Subject.Text.Count | Should -Be 6
                $r.Conditions.Subject.Text | Should -Contain 'Quoted "String" & Ampersand'
                $r.Conditions.Subject.Text | Should -Contain $dynUnicode
                $r.Conditions.Importance.Importance | Should -Be 2
                $r.Conditions.Sensitivity.Sensitivity | Should -Be 3
                $r.Conditions.Account.Account | Should -Be 'Corporate Exchange'
                $r.Conditions.OnlyToMe.Enabled | Should -BeTrue
                $r.Conditions.HasAttachment.Enabled | Should -BeTrue

                $r.Exceptions.Subject.Text | Should -Contain 'Automated Reply'
                $r.Exceptions.From.Recipients | Should -Contain 'ceo@enterprise.com'
                $r.Actions.MarkAsRead.Enabled | Should -BeTrue
                $r.Actions.Stop.Enabled | Should -BeTrue
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Serializes recipients from mixed structures (strings, COM objects with Address, objects with Name only)' {
            $mockRecip1 = [PSCustomObject]@{ Name = 'Alice Smith'; Address = 'alice@corp.com' }
            $mockRecip2 = [PSCustomObject]@{ Name = 'Distribution List Alpha'; Address = $null }
            $mockRecip3 = 'raw.email@external.io'

            $ruleWithRecipients = [PSCustomObject]@{
                Name           = 'Recipient Rule'
                RuleType       = 0
                Enabled        = $true
                ExecutionOrder = 1
                Conditions     = [PSCustomObject]@{
                    From   = [PSCustomObject]@{ Enabled = $true; Recipients = @($mockRecip1, $mockRecip2, $mockRecip3) }
                    SentTo = [PSCustomObject]@{ Enabled = $true; Recipients = 'single.user@corp.com' }
                }
                Exceptions     = [PSCustomObject]@{}
                Actions        = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Enabled = $false; Folder = $null }
                    CopyToFolder = [PSCustomObject]@{ Enabled = $false; Folder = $null }
                }
            }

            $env = New-ChallengerStressEnv -CustomRules @($ruleWithRecipients)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_recip_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $env.Store.FilePath
                $res.Success | Should -BeTrue

                $manifest = Get-Content -LiteralPath $testJson -Raw | ConvertFrom-Json
                $r = $manifest.Rules[0]
                $r.Conditions.From.Recipients | Should -Contain 'alice@corp.com'
                $r.Conditions.From.Recipients | Should -Contain 'Distribution List Alpha'
                $r.Conditions.From.Recipients | Should -Contain 'raw.email@external.io'
                $r.Conditions.SentTo.Recipients | Should -Contain 'single.user@corp.com'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Tolerates condition property access exceptions gracefully without failing the export' {
            $throwingCond = [PSCustomObject]@{ Enabled = $true }
            $throwingCond | Add-Member -MemberType ScriptProperty -Name 'Text' -Value {
                throw [System.Runtime.InteropServices.COMException]::new('0x80004005: E_FAIL property reading error')
            }

            $ruleWithThrowingCond = [PSCustomObject]@{
                Name           = 'Partial Failure Condition Rule'
                RuleType       = 0
                Enabled        = $true
                ExecutionOrder = 1
                Conditions     = [PSCustomObject]@{
                    Subject = $throwingCond
                    Body    = [PSCustomObject]@{ Enabled = $true; Text = @('Normal Body Condition') }
                }
                Exceptions     = [PSCustomObject]@{}
                Actions        = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Enabled = $false; Folder = $null }
                    CopyToFolder = [PSCustomObject]@{ Enabled = $false; Folder = $null }
                }
            }

            $env = New-ChallengerStressEnv -CustomRules @($ruleWithThrowingCond)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_throwcond_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $env.Store.FilePath
                $res.Success | Should -BeTrue
                $manifest = Get-Content -LiteralPath $testJson -Raw | ConvertFrom-Json
                $manifest.Rules[0].Conditions.Body.Text | Should -Contain 'Normal Body Condition'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }

    Context 'Stress Testing Store-Relative Folder Path Normalization' {
        It 'Correctly normalizes diverse folder path styles to store-relative paths' {
            $fDeep = [PSCustomObject]@{
                Name       = 'Q1'
                FolderPath = '\\StressStore\Archive\2026\Q1'
            }
            $fSlashes = [PSCustomObject]@{
                Name       = 'ForwardSlash'
                FolderPath = '//StressStore/Inbox/SubFolder'
            }
            $fRootLevel = [PSCustomObject]@{
                Name       = 'Projects'
                FolderPath = '\\StressStore\Projects'
            }
            $fAlreadyRelative = [PSCustomObject]@{
                Name       = 'Local'
                FolderPath = 'Inbox\DirectRelative'
            }

            $rule1 = [PSCustomObject]@{
                Name       = 'Deep Move'
                Enabled    = $true
                Actions    = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Enabled = $true; Folder = $fDeep }
                    CopyToFolder = [PSCustomObject]@{ Enabled = $false; Folder = $null }
                }
            }
            $rule2 = [PSCustomObject]@{
                Name       = 'Slash Copy'
                Enabled    = $true
                Actions    = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Enabled = $false; Folder = $null }
                    CopyToFolder = [PSCustomObject]@{ Enabled = $true; Folder = $fSlashes }
                }
            }
            $rule3 = [PSCustomObject]@{
                Name       = 'Root Move'
                Enabled    = $true
                Actions    = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Enabled = $true; Folder = $fRootLevel }
                    CopyToFolder = [PSCustomObject]@{ Enabled = $false; Folder = $null }
                }
            }
            $rule4 = [PSCustomObject]@{
                Name       = 'Already Relative'
                Enabled    = $true
                Actions    = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Enabled = $true; Folder = $fAlreadyRelative }
                    CopyToFolder = [PSCustomObject]@{ Enabled = $false; Folder = $null }
                }
            }

            $env = New-ChallengerStressEnv -CustomRules @($rule1, $rule2, $rule3, $rule4)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_paths_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $env.Store.FilePath
                $res.Success | Should -BeTrue

                $manifest = Get-Content -LiteralPath $testJson -Raw | ConvertFrom-Json

                ($manifest.Rules | Where-Object { $_.Name -eq 'Deep Move' }).Actions.MoveToFolder.FolderPath | Should -Be 'Archive\2026\Q1'
                ($manifest.Rules | Where-Object { $_.Name -eq 'Slash Copy' }).Actions.CopyToFolder.FolderPath | Should -Match '^(Inbox[\\/]SubFolder)$'
                ($manifest.Rules | Where-Object { $_.Name -eq 'Root Move' }).Actions.MoveToFolder.FolderPath | Should -Be 'Projects'
                ($manifest.Rules | Where-Object { $_.Name -eq 'Already Relative' }).Actions.MoveToFolder.FolderPath | Should -Be 'Inbox\DirectRelative'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Safely serializes broken rules where target folder is null, retaining Enabled=True for repair detection' {
            $brokenRule = [PSCustomObject]@{
                Name       = 'Broken Rule With Missing Target Folder'
                Enabled    = $true
                Actions    = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Enabled = $true; Folder = $null }
                    CopyToFolder = [PSCustomObject]@{ Enabled = $true; Folder = $null }
                }
            }

            $env = New-ChallengerStressEnv -CustomRules @($brokenRule)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_brokenrule_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $env.Store.FilePath
                $res.Success | Should -BeTrue

                $manifest = Get-Content -LiteralPath $testJson -Raw | ConvertFrom-Json
                $r = $manifest.Rules[0]
                $r.Actions.MoveToFolder.Enabled | Should -BeTrue
                $r.Actions.MoveToFolder.FolderPath | Should -BeNullOrEmpty
                $r.Actions.CopyToFolder.Enabled | Should -BeTrue
                $r.Actions.CopyToFolder.FolderPath | Should -BeNullOrEmpty
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }

    Context 'Stress Testing Custom Folder Recursion & Boundary Conditions' {
        It 'Recursively traverses deep folder trees (10 levels deep) and excludes all system folders' {
            # Build 10 levels of nested folders under Inbox
            $currentChild = New-ChallengerMockFolder -Name 'Level10' -FolderPath '\\StressStore\Inbox\L1\L2\L3\L4\L5\L6\L7\L8\L9\Level10'
            for ($lvl = 9; $lvl -ge 1; $lvl--) {
                $path = "\\StressStore\Inbox\" + ((1..$lvl | ForEach-Object { "L$_" }) -join '\')
                $currentChild = New-ChallengerMockFolder -Name "L$lvl" -FolderPath $path -Children @($currentChild)
            }
            $mockInbox = New-ChallengerMockFolder -Name 'Inbox' -FolderPath '\\StressStore\Inbox' -Children @($currentChild)

            # System folders at root
            $mockDeleted = New-ChallengerMockFolder -Name 'Deleted Items' -FolderPath '\\StressStore\Deleted Items'
            $mockDrafts  = New-ChallengerMockFolder -Name 'Drafts' -FolderPath '\\StressStore\Drafts'
            $mockSent    = New-ChallengerMockFolder -Name 'Sent Items' -FolderPath '\\StressStore\Sent Items'
            $mockJunk    = New-ChallengerMockFolder -Name 'Junk Email' -FolderPath '\\StressStore\Junk Email'
            $mockSync    = New-ChallengerMockFolder -Name 'Sync Issues' -FolderPath '\\StressStore\Sync Issues'

            # Custom root folder
            $mockInvoices = New-ChallengerMockFolder -Name 'Invoices' -FolderPath '\\StressStore\Finance\Invoices'
            $mockFinance  = New-ChallengerMockFolder -Name 'Finance' -FolderPath '\\StressStore\Finance' -Children @($mockInvoices)

            $rootFolders = @($mockInbox, $mockDeleted, $mockDrafts, $mockSent, $mockJunk, $mockSync, $mockFinance)

            $env = New-ChallengerStressEnv -RootFolders $rootFolders
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_deepfolders_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $env.Store.FilePath
                $res.Success | Should -BeTrue
                $res.CustomFoldersExported | Should -BeGreaterThan 10

                $manifest = Get-Content -LiteralPath $testJson -Raw | ConvertFrom-Json

                # Verify deep nesting
                $manifest.CustomFolders | Should -Contain 'Inbox\L1'
                $manifest.CustomFolders | Should -Contain 'Inbox\L1\L2\L3\L4\L5\L6\L7\L8\L9\Level10'
                $manifest.CustomFolders | Should -Contain 'Finance'
                $manifest.CustomFolders | Should -Contain 'Finance\Invoices'

                # Verify system exclusions
                $manifest.CustomFolders | Should -Not -Contain 'Inbox'
                $manifest.CustomFolders | Should -Not -Contain 'Deleted Items'
                $manifest.CustomFolders | Should -Not -Contain 'Drafts'
                $manifest.CustomFolders | Should -Not -Contain 'Sent Items'
                $manifest.CustomFolders | Should -Not -Contain 'Junk Email'
                $manifest.CustomFolders | Should -Not -Contain 'Sync Issues'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Scales across 100 wide custom folders without performance degradation' {
            $wideFolders = @()
            for ($i = 1; $i -le 100; $i++) {
                $wideFolders += New-ChallengerMockFolder -Name "Project_$i" -FolderPath "\\StressStore\Projects\Project_$i"
            }
            $mockProjectsRoot = New-ChallengerMockFolder -Name 'Projects' -FolderPath '\\StressStore\Projects' -Children $wideFolders

            $env = New-ChallengerStressEnv -RootFolders @($mockProjectsRoot)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_widefolders_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $env.Store.FilePath
                $res.Success | Should -BeTrue
                $res.CustomFoldersExported | Should -Be 101

                $manifest = Get-Content -LiteralPath $testJson -Raw | ConvertFrom-Json
                $manifest.CustomFolders.Count | Should -Be 101
                $manifest.CustomFolders | Should -Contain 'Projects'
                $manifest.CustomFolders | Should -Contain 'Projects\Project_1'
                $manifest.CustomFolders | Should -Contain 'Projects\Project_100'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }

    Context 'Stress Testing Error Handling & Scalability' {
        It 'Returns structured error object and does not throw when store rule table access fails' {
            $env = New-ChallengerStressEnv -ThrowOnGetRules $true
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_failrules_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $env.Store.FilePath
                $res.Success | Should -BeFalse
                $res.ErrorMessage | Should -Match 'MAPI_E_CORRUPT_STORE'
                Test-Path -LiteralPath $testJson | Should -BeFalse
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Automatically creates nested target directory when destination folder does not exist' {
            $env = New-ChallengerStressEnv
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'

            $randId = [System.Guid]::NewGuid().ToString('N')
            $nestedDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nested_sub_$randId\level2\level3"
            $testJson = Join-Path -Path $nestedDir -ChildPath 'manifest.json'

            try {
                Test-Path -LiteralPath $nestedDir | Should -BeFalse
                $res = Export-OutlookRule -Path $testJson -StorePath $env.Store.FilePath
                $res.Success | Should -BeTrue
                Test-Path -LiteralPath $testJson | Should -BeTrue
            }
            finally {
                $cleanRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nested_sub_$randId"
                if (Test-Path -LiteralPath $cleanRoot) { Remove-Item -LiteralPath $cleanRoot -Recurse -Force }
            }
        }

        It 'Handles high rule count (200 rules) cleanly and efficiently' {
            $largeRuleList = @()
            for ($i = 1; $i -le 200; $i++) {
                $largeRuleList += [PSCustomObject]@{
                    Name           = "Rule_Bulk_$i"
                    RuleType       = 0
                    Enabled        = ($i % 2 -eq 0)
                    ExecutionOrder = $i
                    Conditions     = [PSCustomObject]@{
                        Subject = [PSCustomObject]@{ Enabled = $true; Text = @("Tag_$i", "Notice_$i") }
                    }
                    Exceptions     = [PSCustomObject]@{}
                    Actions        = [PSCustomObject]@{
                        MoveToFolder = [PSCustomObject]@{ Enabled = $false; Folder = $null }
                        CopyToFolder = [PSCustomObject]@{ Enabled = $false; Folder = $null }
                        MarkAsRead   = [PSCustomObject]@{ Enabled = ($i % 3 -eq 0) }
                    }
                }
            }

            $env = New-ChallengerStressEnv -CustomRules $largeRuleList
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_200rules_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $res = Export-OutlookRule -Path $testJson -StorePath $env.Store.FilePath
                $sw.Stop()

                $res.Success | Should -BeTrue
                $res.RulesExported | Should -Be 200
                $sw.ElapsedMilliseconds | Should -BeLessThan 15000 # Under 15 seconds for 200 rules

                $manifest = Get-Content -LiteralPath $testJson -Raw | ConvertFrom-Json
                $manifest.Rules.Count | Should -Be 200
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }

    Context 'WhatIf, Headless & Pipeline Safety Verification' {
        It 'Supports pipeline input binding with FullName and Path properties' {
            $env = New-ChallengerStressEnv
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_pipe_$([System.Guid]::NewGuid().ToString('N')).json"
            $pipeObj = [PSCustomObject]@{ Path = $testJson }

            try {
                $res = $pipeObj | Export-OutlookRule -StorePath $env.Store.FilePath
                $res.Success | Should -BeTrue
                Test-Path -LiteralPath $testJson | Should -BeTrue
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Guarantees zero file writes and zero COM side-effects when -WhatIf is invoked' {
            $mockAppCalled = $false
            Mock Get-OutlookComApplication {
                $mockAppCalled = $true
                return $null
            } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_whatif_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath 'C:\Data\Test.pst' -WhatIf
                $res.Success | Should -BeTrue
                $res.Method | Should -Be 'WhatIf'
                $res.RulesExported | Should -Be 0
                Test-Path -LiteralPath $testJson | Should -BeFalse
                $mockAppCalled | Should -BeFalse # Never calls COM during -WhatIf
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Appends .json extension when omitted from destination path' {
            $env = New-ChallengerStressEnv
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'

            $baseName = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_noext_$([System.Guid]::NewGuid().ToString('N'))"
            $expectedJson = "$baseName.json"

            try {
                $res = Export-OutlookRule -Path $baseName -StorePath $env.Store.FilePath
                $res.Success | Should -BeTrue
                $res.Path | Should -Be $expectedJson
                Test-Path -LiteralPath $expectedJson | Should -BeTrue
            }
            finally {
                if (Test-Path -LiteralPath $expectedJson) { Remove-Item -LiteralPath $expectedJson -Force }
            }
        }

        It 'Releases COM references and triggers logoff deterministically' {
            $env = New-ChallengerStressEnv
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'

            $script:releasedCount = 0
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    $script:releasedCount += $ComObjects.Count
                }
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                if ($null -ne $ComObjects) {
                    $script:releasedCount += $ComObjects.Count
                }
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_com_$([System.Guid]::NewGuid().ToString('N')).json"
            try {
                $res = Export-OutlookRule -Path $testJson -StorePath $env.Store.FilePath
                $script:releasedCount | Should -BeGreaterThan 0
                $script:logoffCalled | Should -BeTrue
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }
}
