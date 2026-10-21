# Tests/Adversarial/ChallengerOutlookImportEdgeCases.Tests.ps1
# Adversarial Challenger Stress Harness for Import-OutlookRule (M2 Challenger 1)
# Testing: Nested Folder Trees, Corrupt/Empty Manifests, Missing Folders Without Auto-Create, Overlapping Address Maps

BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../Modules/Outlook/Outlook.psd1'
    Import-Module $modulePath -Force

    $corePath = Join-Path -Path $PSScriptRoot -ChildPath '../../Modules/Core/Core.psd1'
    if (Test-Path -LiteralPath $corePath) {
        Import-Module $corePath -Force
    }

    $script:c1FolderFactory = {
        param($childName)
        $childList = [System.Collections.Generic.List[object]]::new()
        $childPath = "$($this.FolderPath)\$childName"
        $child = [PSCustomObject]@{
            Name       = $childName
            FolderPath = $childPath
            Folders    = $childList
        }
        $child | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $script:c1FolderFactory
        $this.Folders.Add($child)
        return $child
    }

    function script:New-C1MockEnvironment {
        param(
            [string]$StorePath = 'C:\Data\C1StressStore.pst',
            [string]$StoreName = 'C1StressStore',
            [object[]]$InitialRules = @(),
            [switch]$OmitInbox
        )

        $targetFolders = [System.Collections.Generic.List[object]]::new()
        $mockRootFolder = [PSCustomObject]@{
            Name       = $StoreName
            FolderPath = "\\$StoreName"
            Folders    = $targetFolders
        }
        $mockRootFolder | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $script:c1FolderFactory

        $mockInbox = $null
        if (-not $OmitInbox) {
            $mockInbox = $mockRootFolder.AddFolder('Inbox')
        }
        $null = $mockRootFolder.AddFolder('Sent Items')
        $null = $mockRootFolder.AddFolder('Deleted Items')

        $rulesList = [System.Collections.Generic.List[object]]::new()
        if ($null -ne $InitialRules) {
            foreach ($ir in $InitialRules) { [void]$rulesList.Add($ir) }
        }

        $mockRules = [PSCustomObject]@{
            Count                = $rulesList.Count
            RulesList            = $rulesList
            SaveCalled           = $false
            LastSaveShowProgress = $null
            SaveCallCount        = 0
        }
        $mockRules | Add-Member -MemberType ScriptMethod -Name GetEnumerator -Value { $this.RulesList.GetEnumerator() }
        $mockRules | Add-Member -MemberType ScriptMethod -Name Item -Value { param($idx) return $this.RulesList[$idx] }
        $mockRules | Add-Member -MemberType ScriptMethod -Name Save -Value {
            param($showProgress)
            $this.SaveCalled = $true
            $this.LastSaveShowProgress = $showProgress
            $this.SaveCallCount++
        }
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
                    AssignToCategory = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                    Forward          = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                    Redirect         = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                    Cc               = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                }
            }
            $this.RulesList.Add($createdRule)
            $this.Count = $this.RulesList.Count
            return $createdRule
        }

        $mockStore = [PSCustomObject]@{
            DisplayName     = $StoreName
            FilePath        = $StorePath
            IsDataFileStore = $true
            IsDefaultStore  = $true
            RootFolder      = $mockRootFolder
            Rules           = $mockRules
        }
        $mockStore | Add-Member -MemberType ScriptMethod -Name GetRootFolder -Value { return $this.RootFolder }
        $mockStore | Add-Member -MemberType ScriptMethod -Name GetRules -Value { return $this.Rules }

        $mockStores = @($mockStore)
        $mockNs = [PSCustomObject]@{
            DefaultStore = $mockStore
            Stores       = $mockStores
            Accounts     = @(
                [PSCustomObject]@{
                    DisplayName = 'C1 Enterprise Account'
                    SmtpAddress = 'c1@enterprise.com'
                    Name        = 'C1 Enterprise Account'
                }
            )
            LoggedOff    = $false
        }
        $mockNs | Add-Member -MemberType ScriptMethod -Name Logon -Value { param($p, $pwd, $ui, $new) }
        $mockNs | Add-Member -MemberType ScriptMethod -Name Logoff -Value {
            $this.LoggedOff = $true
            $script:c1LogoffCount++
        }

        $mockApp = [PSCustomObject]@{
            MapiNamespace = $mockNs
        }
        $mockApp | Add-Member -MemberType ScriptMethod -Name GetNamespace -Value { param($ns) return $this.MapiNamespace }
        $mockApp | Add-Member -MemberType ScriptMethod -Name Quit -Value {
            $script:c1QuitCount++
        }

        return @{
            App        = $mockApp
            Namespace  = $mockNs
            Store      = $mockStore
            RootFolder = $mockRootFolder
            Inbox      = $mockInbox
            Rules      = $mockRules
            RulesList  = $rulesList
        }
    }
}

Describe 'Adversarial Challenge: Import-OutlookRule Stress Verification' {
    BeforeEach {
        $script:c1QuitCount = 0
        $script:c1LogoffCount = 0
    }

    Context '1. Stress Testing Nested Folder Trees & Irregular Paths' {
        It 'Correctly reconstructs a 10-level deep nested hierarchy under Inbox and binds MoveToFolder' {
            $env = New-C1MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $deepRelPath = "Inbox\L1\L2\L3\L4\L5\L6\L7\L8\L9\L10"
            $manifestObj = [ordered]@{
                ManifestVersion = '1.0.0'
                SchemaVersion   = '1.0.0'
                CustomFolders   = @($deepRelPath)
                Rules           = @(
                    [ordered]@{
                        Name       = 'Deep Nested Rule'
                        RuleType   = 0
                        Enabled    = $true
                        Actions    = [ordered]@{
                            MoveToFolder = [ordered]@{ Enabled = $true; FolderPath = $deepRelPath }
                        }
                    }
                )
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "c1_deep_inbox_$([System.Guid]::NewGuid().ToString('N')).json"
            $manifestObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testJson -Encoding UTF8

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath
                $res.Success | Should -BeTrue
                $res.RulesImported | Should -Be 1
                $res.FoldersCreated | Should -Be 10

                $createdRule = $env.RulesList | Where-Object { $_.Name -eq 'Deep Nested Rule' }
                $createdRule | Should -Not -BeNullOrEmpty
                $createdRule.Actions.MoveToFolder.Enabled | Should -BeTrue
                $createdRule.Actions.MoveToFolder.Folder | Should -Not -BeNullOrEmpty
                $createdRule.Actions.MoveToFolder.Folder.Name | Should -Be 'L10'
                $createdRule.Actions.MoveToFolder.Folder.FolderPath | Should -Match 'L1\\L2\\L3\\L4\\L5\\L6\\L7\\L8\\L9\\L10'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Creates custom root trees outside Inbox and handles forward-slash notation' {
            $env = New-C1MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $forwardPath = "Archive/2026/Q1/Tax/Receipts"
            $manifestObj = [ordered]@{
                ManifestVersion = '1.0.0'
                CustomFolders   = @($forwardPath)
                Rules           = @(
                    [ordered]@{
                        Name    = 'Forward Slash Tree Rule'
                        Actions = [ordered]@{
                            CopyToFolder = [ordered]@{ Enabled = $true; FolderPath = $forwardPath }
                        }
                    }
                )
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "c1_fwd_slash_$([System.Guid]::NewGuid().ToString('N')).json"
            $manifestObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testJson -Encoding UTF8

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath
                $res.Success | Should -BeTrue
                $res.FoldersCreated | Should -Be 5

                $createdRule = $env.RulesList | Where-Object { $_.Name -eq 'Forward Slash Tree Rule' }
                $createdRule.Actions.CopyToFolder.Enabled | Should -BeTrue
                $createdRule.Actions.CopyToFolder.Folder.Name | Should -Be 'Receipts'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Handles redundant parent-child specifications without double counting FoldersCreated' {
            $env = New-C1MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $manifestObj = [ordered]@{
                ManifestVersion = '1.0.0'
                CustomFolders   = @(
                    'Finance',
                    'Finance\Invoices',
                    'Finance',
                    'Finance\Invoices',
                    'Finance\Invoices\2026'
                )
                Rules           = @()
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "c1_redundant_folders_$([System.Guid]::NewGuid().ToString('N')).json"
            $manifestObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testJson -Encoding UTF8

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath
                $res.Success | Should -BeTrue
                $res.FoldersCreated | Should -Be 3
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Reconstructs Inbox automatically when target store lacks Inbox and auto-create is enabled' {
            $env = New-C1MockEnvironment -OmitInbox
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $manifestObj = [ordered]@{
                ManifestVersion = '1.0.0'
                CustomFolders   = @('Inbox\Urgent')
                Rules           = @(
                    [ordered]@{
                        Name    = 'Urgent Inbox Rule'
                        Actions = [ordered]@{
                            MoveToFolder = [ordered]@{ Enabled = $true; FolderPath = 'Inbox\Urgent' }
                        }
                    }
                )
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "c1_omit_inbox_$([System.Guid]::NewGuid().ToString('N')).json"
            $manifestObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testJson -Encoding UTF8

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath
                $res.Success | Should -BeTrue
                $res.FoldersCreated | Should -Be 2
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }

    Context '2. Stress Testing Corrupt, Empty, and Malformed Manifests' {
        It 'Rejects 0-byte empty file with structured error and zero COM commits' {
            $env = New-C1MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "c1_empty_0b_$([System.Guid]::NewGuid().ToString('N')).json"
            [System.IO.File]::WriteAllBytes($testJson, @())

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath
                $res.Success | Should -BeFalse
                $res.RulesImported | Should -Be 0
                $res.ErrorMessage | Should -Match 'empty or null'
                $env.Rules.SaveCalled | Should -BeFalse
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Rejects whitespace-only file with structured error' {
            $env = New-C1MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "c1_whitespace_$([System.Guid]::NewGuid().ToString('N')).json"
            [System.IO.File]::WriteAllText($testJson, "   `r`n`t`r`n   ", [System.Text.Encoding]::UTF8)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath
                $res.Success | Should -BeFalse
                $res.ErrorMessage | Should -Match 'empty or null'
                $env.Rules.SaveCalled | Should -BeFalse
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Rejects corrupt JSON syntax with structured error without throwing unhandled exceptions' {
            $env = New-C1MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "c1_corrupt_json_$([System.Guid]::NewGuid().ToString('N')).json"
            [System.IO.File]::WriteAllText($testJson, '{"ManifestVersion": "1.0.0", "Rules": [{"Name":', [System.Text.Encoding]::UTF8)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath
                $res.Success | Should -BeFalse
                $res.ErrorMessage | Should -Match 'Failed to parse JSON rule manifest'
                $env.Rules.SaveCalled | Should -BeFalse
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Safely handles empty JSON object `{}` with 0 rules imported and 0 folders created' {
            $env = New-C1MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "c1_empty_obj_$([System.Guid]::NewGuid().ToString('N')).json"
            [System.IO.File]::WriteAllText($testJson, '{}', [System.Text.Encoding]::UTF8)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath
                $res.Success | Should -BeTrue
                $res.RulesImported | Should -Be 0
                $res.FoldersCreated | Should -Be 0
                $env.Rules.SaveCalled | Should -BeTrue
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Safely ignores null elements and empty-name rules in the Rules array' {
            $env = New-C1MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $manifestObj = [ordered]@{
                ManifestVersion = '1.0.0'
                Rules           = @(
                    $null,
                    [ordered]@{ Name = '' },
                    [ordered]@{ Name = '   ' },
                    [ordered]@{ Name = 'Valid Rule 1'; Enabled = $true }
                )
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "c1_null_rules_$([System.Guid]::NewGuid().ToString('N')).json"
            $manifestObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testJson -Encoding UTF8

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath
                $res.Success | Should -BeTrue
                $res.RulesImported | Should -Be 1
                $env.RulesList.Count | Should -Be 1
                $env.RulesList[0].Name | Should -Be 'Valid Rule 1'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Returns structured error when manifest file path does not exist' {
            $env = New-C1MockEnvironment
            $nonExistentPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "c1_nonexistent_$([System.Guid]::NewGuid().ToString('N')).json"

            $res = Import-OutlookRule -Path $nonExistentPath -TargetStorePath $env.Store.FilePath
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'Rule manifest file not found'
        }

        It 'Auto-appends .json extension when omitted and matching file exists' {
            $env = New-C1MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $basePath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "c1_noext_$([System.Guid]::NewGuid().ToString('N'))"
            $fullJsonPath = "$basePath.json"

            $manifestObj = [ordered]@{
                ManifestVersion = '1.0.0'
                Rules           = @([ordered]@{ Name = 'Auto Ext Rule' })
            }
            $manifestObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fullJsonPath -Encoding UTF8

            try {
                # Invoke with basePath (no .json)
                $res = Import-OutlookRule -Path $basePath -TargetStorePath $env.Store.FilePath
                $res.Success | Should -BeTrue
                $res.Path | Should -Be $fullJsonPath
                $res.RulesImported | Should -Be 1
            }
            finally {
                if (Test-Path -LiteralPath $fullJsonPath) { Remove-Item -LiteralPath $fullJsonPath -Force }
            }
        }
    }

    Context '3. Stress Testing Missing Folders Without Auto-Create (-AutoCreateFolders:$false)' {
        It 'Leaves MoveToFolder and CopyToFolder unbound and disabled when folders are missing with AutoCreateFolders false' {
            $env = New-C1MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $manifestObj = [ordered]@{
                ManifestVersion = '1.0.0'
                Rules           = @(
                    [ordered]@{
                        Name    = 'Unbound Rule'
                        Enabled = $true
                        Actions = [ordered]@{
                            MoveToFolder = [ordered]@{ Enabled = $true; FolderPath = 'Inbox\MissingSub' }
                            CopyToFolder = [ordered]@{ Enabled = $true; FolderPath = 'MissingRoot' }
                            MarkAsRead   = [ordered]@{ Enabled = $true }
                        }
                    }
                )
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "c1_noautocreate_$([System.Guid]::NewGuid().ToString('N')).json"
            $manifestObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testJson -Encoding UTF8

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -AutoCreateFolders:$false
                $res.Success | Should -BeTrue
                $res.FoldersCreated | Should -Be 0
                $res.RulesImported | Should -Be 1

                $rule = $env.RulesList | Where-Object { $_.Name -eq 'Unbound Rule' }
                $rule.Actions.MoveToFolder.Folder | Should -BeNullOrEmpty
                $rule.Actions.MoveToFolder.Enabled | Should -BeFalse
                $rule.Actions.CopyToFolder.Folder | Should -BeNullOrEmpty
                $rule.Actions.CopyToFolder.Enabled | Should -BeFalse
                $rule.Actions.MarkAsRead.Enabled | Should -BeTrue
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Clears stale folder references during Overwrite mode when incoming target folder is missing and auto-create is disabled' {
            $dummyOldFolder = [PSCustomObject]@{ Name = 'OldFolder'; FolderPath = '\\C1StressStore\OldFolder' }
            $existingRule = [PSCustomObject]@{
                Name       = 'Stale Folder Rule'
                Enabled    = $true
                Conditions = [PSCustomObject]@{}
                Exceptions = [PSCustomObject]@{}
                Actions    = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Folder = $dummyOldFolder; Enabled = $true }
                    CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                }
            }

            $env = New-C1MockEnvironment -InitialRules @($existingRule)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $manifestObj = [ordered]@{
                ManifestVersion = '1.0.0'
                Rules           = @(
                    [ordered]@{
                        Name    = 'Stale Folder Rule'
                        Enabled = $true
                        Actions = [ordered]@{
                            MoveToFolder = [ordered]@{ Enabled = $true; FolderPath = 'Inbox\Missing' }
                        }
                    }
                )
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "c1_overwrite_stale_$([System.Guid]::NewGuid().ToString('N')).json"
            $manifestObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testJson -Encoding UTF8

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'Overwrite' -AutoCreateFolders:$false
                $res.Success | Should -BeTrue
                $res.RulesOverwritten | Should -Be 1

                $existingRule.Actions.MoveToFolder.Folder | Should -BeNullOrEmpty
                $existingRule.Actions.MoveToFolder.Enabled | Should -BeFalse
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }

    Context '4. Stress Testing Overlapping & Complex Address Maps' {
        It 'Correctly prioritizes specific email address mapping over general domain suffix mapping' {
            $env = New-C1MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $addrMap = [ordered]@{
                'ceo@legacy.com' = 'executive@modern.org'
                '@legacy.com'    = '@migrated.org'
            }

            $manifestObj = [ordered]@{
                ManifestVersion = '1.0.0'
                Rules           = @(
                    [ordered]@{
                        Name       = 'Priority Address Rule'
                        Conditions = [ordered]@{
                            From = [ordered]@{
                                Enabled    = $true
                                Recipients = @('ceo@legacy.com', 'developer@legacy.com')
                            }
                        }
                    }
                )
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "c1_addr_prio_$([System.Guid]::NewGuid().ToString('N')).json"
            $manifestObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testJson -Encoding UTF8

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -AddressMap $addrMap
                $res.Success | Should -BeTrue

                $rule = $env.RulesList | Where-Object { $_.Name -eq 'Priority Address Rule' }
                $rule.Conditions.From.Recipients | Should -Contain 'executive@modern.org'
                $rule.Conditions.From.Recipients | Should -Contain 'developer@migrated.org'
                $rule.Conditions.From.Recipients | Should -Not -Contain 'executive@migrated.org'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Remaps exact email within bracketed display name format without corrupting display name' {
            $env = New-C1MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $addrMap = @{
                'alice@legacy.com' = 'alice@newcorp.com'
            }

            $manifestObj = [ordered]@{
                ManifestVersion = '1.0.0'
                Rules           = @(
                    [ordered]@{
                        Name       = 'Bracketed Address Rule'
                        Conditions = [ordered]@{
                            From = [ordered]@{
                                Enabled    = $true
                                Recipients = @('Alice Smith <alice@legacy.com>')
                            }
                        }
                    }
                )
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "c1_bracket_addr_$([System.Guid]::NewGuid().ToString('N')).json"
            $manifestObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testJson -Encoding UTF8

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -AddressMap $addrMap
                $res.Success | Should -BeTrue

                $rule = $env.RulesList | Where-Object { $_.Name -eq 'Bracketed Address Rule' }
                $rule.Conditions.From.Recipients | Should -Contain 'Alice Smith <alice@newcorp.com>'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Remaps action recipients (Forward, Redirect, Cc) and SenderAddress/RecipientAddress conditions' {
            $env = New-C1MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $addrMap = @{
                '@oldcorp.com' = '@newcorp.com'
            }

            $manifestObj = [ordered]@{
                ManifestVersion = '1.0.0'
                Rules           = @(
                    [ordered]@{
                        Name       = 'Multi-Target Remap Rule'
                        Conditions = [ordered]@{
                            SenderAddress    = [ordered]@{ Enabled = $true; Address = @('billing@oldcorp.com') }
                            RecipientAddress = [ordered]@{ Enabled = $true; Address = @('support@oldcorp.com') }
                        }
                        Actions    = [ordered]@{
                            Forward  = [ordered]@{ Enabled = $true; Recipients = @('audit@oldcorp.com') }
                            Redirect = [ordered]@{ Enabled = $true; Recipients = @('ops@oldcorp.com') }
                            Cc       = [ordered]@{ Enabled = $true; Recipients = @('archive@oldcorp.com') }
                        }
                    }
                )
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "c1_action_remap_$([System.Guid]::NewGuid().ToString('N')).json"
            $manifestObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testJson -Encoding UTF8

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -AddressMap $addrMap
                $res.Success | Should -BeTrue

                $rule = $env.RulesList | Where-Object { $_.Name -eq 'Multi-Target Remap Rule' }
                $rule.Conditions.SenderAddress.Address | Should -Contain 'billing@newcorp.com'
                $rule.Conditions.RecipientAddress.Address | Should -Contain 'support@newcorp.com'
                $rule.Actions.Forward.Recipients | Should -Contain 'audit@newcorp.com'
                $rule.Actions.Redirect.Recipients | Should -Contain 'ops@newcorp.com'
                $rule.Actions.Cc.Recipients | Should -Contain 'archive@newcorp.com'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Remaps account names using AccountMap and AutoRemapAccounts' {
            $env = New-C1MockEnvironment
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'StressProfile' } } -ModuleName 'Outlook'

            $manifestObj = [ordered]@{
                ManifestVersion = '1.0.0'
                Rules           = @(
                    [ordered]@{
                        Name       = 'Account Remap Rule 1'
                        Conditions = [ordered]@{
                            Account = [ordered]@{ Enabled = $true; Account = 'Source Account' }
                        }
                    },
                    [ordered]@{
                        Name       = 'Account Remap Rule 2'
                        Conditions = [ordered]@{
                            Account = [ordered]@{ Enabled = $true; Account = 'Source Account 2' }
                        }
                    }
                )
            }

            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "c1_account_remap_$([System.Guid]::NewGuid().ToString('N')).json"
            $manifestObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testJson -Encoding UTF8

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -AccountMap @{ 'Source Account' = 'Target Account' } -AutoRemapAccounts
                $res.Success | Should -BeTrue
                $res.RulesImported | Should -Be 2

                $r1 = $env.RulesList | Where-Object { $_.Name -eq 'Account Remap Rule 1' }
                $r2 = $env.RulesList | Where-Object { $_.Name -eq 'Account Remap Rule 2' }
                $r1.Conditions.Account.Account | Should -Be 'Target Account'
                # r2 auto-remapped to target primary account
                $r2.Conditions.Account.Account | Should -Not -BeNullOrEmpty
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }

    Context '5. Stress Testing Safety & Simulation' {
        It 'Performs zero mutations and makes zero COM calls when -WhatIf is passed' {
            $env = New-C1MockEnvironment
            $mockAppCalled = $false
            Mock Get-OutlookComApplication {
                $mockAppCalled = $true
                return $env.App
            } -ModuleName 'Outlook'

            $manifestObj = [ordered]@{
                ManifestVersion = '1.0.0'
                Rules           = @([ordered]@{ Name = 'WhatIf Rule' })
            }
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "c1_whatif_$([System.Guid]::NewGuid().ToString('N')).json"
            $manifestObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testJson -Encoding UTF8

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -WhatIf
                $res.Success | Should -BeTrue
                $res.Method | Should -Be 'WhatIf'
                $res.RulesImported | Should -Be 0
                $res.FoldersCreated | Should -Be 0
                $env.Rules.SaveCalled | Should -BeFalse
                $mockAppCalled | Should -BeFalse
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }
}
