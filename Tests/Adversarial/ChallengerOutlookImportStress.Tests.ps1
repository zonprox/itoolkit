# Tests/Adversarial/ChallengerOutlookImportStress.Tests.ps1
# Adversarial Stress Harness for Import-OutlookRule (M2 Challenger 2)

BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../Modules/Outlook/Outlook.psd1'
    Import-Module $modulePath -Force

    $corePath = Join-Path -Path $PSScriptRoot -ChildPath '../../Modules/Core/Core.psd1'
    if (Test-Path -LiteralPath $corePath) {
        Import-Module $corePath -Force
    }

    # Helper: Build mock manifest file
    function script:New-ChallengerImportManifest {
        param(
            [string]$Path,
            [object[]]$Rules = @(),
            [string[]]$CustomFolders = @()
        )

        $manifest = [ordered]@{
            ManifestVersion = '1.0.0'
            SchemaVersion   = '1.0.0'
            ExportTimestamp = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            ExportedBy      = 'IToolkit'
            SourceContext   = [ordered]@{
                ProfileName        = 'StressSourceProfile'
                StoreName          = 'StressSourceStore'
                StoreDisplayName   = 'StressSourceStore'
                StoreFilePath      = 'C:\Data\StressSource.pst'
                AccountName        = 'SourceUser'
                PrimarySmtpAddress = 'source.user@enterprise.com'
                OfficeVersion      = '16.0'
            }
            CustomFolders   = $CustomFolders
            Rules           = $Rules
        }

        $jsonContent = ConvertTo-Json -InputObject $manifest -Depth 10
        Set-Content -LiteralPath $Path -Value $jsonContent -Encoding UTF8
    }

    # Helper: Create rule definition object for manifest
    function script:New-ChallengerRuleDef {
        param(
            [string]$Name,
            [int]$ExecutionOrder = 1,
            [bool]$Enabled = $true,
            [string[]]$SubjectText = @(),
            [string]$MoveToFolder = $null,
            [string]$CopyToFolder = $null,
            [bool]$MarkAsRead = $false,
            [bool]$Delete = $false,
            [bool]$Stop = $false
        )

        return [ordered]@{
            Name           = $Name
            RuleType       = 0
            ExecutionOrder = $ExecutionOrder
            Enabled        = $Enabled
            Conditions     = [ordered]@{
                Subject    = [ordered]@{ Enabled = ($SubjectText.Count -gt 0); Text = $SubjectText }
                From       = [ordered]@{ Enabled = $false; Recipients = @() }
                Categories = [ordered]@{ Enabled = $false; Categories = @() }
                Importance = [ordered]@{ Enabled = $false; Importance = 1 }
                Account    = [ordered]@{ Enabled = $false; Account = $null }
            }
            Exceptions     = [ordered]@{
                Subject    = [ordered]@{ Enabled = $false; Text = @() }
                From       = [ordered]@{ Enabled = $false; Recipients = @() }
            }
            Actions        = [ordered]@{
                MoveToFolder = [ordered]@{ Enabled = (-not [string]::IsNullOrWhiteSpace($MoveToFolder)); FolderPath = $MoveToFolder }
                CopyToFolder = [ordered]@{ Enabled = (-not [string]::IsNullOrWhiteSpace($CopyToFolder)); FolderPath = $CopyToFolder }
                Delete       = [ordered]@{ Enabled = $Delete }
                MarkAsRead   = [ordered]@{ Enabled = $MarkAsRead }
                Stop         = [ordered]@{ Enabled = $Stop }
            }
        }
    }

    # Helper: Create mock target COM environment with controllable behavior
    function script:New-ChallengerImportEnv {
        param(
            [string]$StorePath = 'C:\Data\TargetStore.pst',
            [string]$StoreName = 'TargetStore',
            [object[]]$InitialRules = @(),
            [bool]$ThrowOnSaveWithArg = $false,
            [bool]$ThrowOnSaveAll = $false,
            [bool]$ThrowOnGetRules = $false,
            [bool]$ThrowOnGetRootFolder = $false,
            [bool]$ThrowOnFolderAdd = $false,
            [bool]$ThrowOnLogon = $false,
            [bool]$ThrowOnGetNamespace = $false
        )

        # 1. Folders
        $targetFolders = [System.Collections.Generic.List[object]]::new()
        $mockRootFolder = [PSCustomObject]@{
            Name            = $StoreName
            FolderPath      = "\\$StoreName"
            Folders         = $targetFolders
            ThrowOnAdd      = $false
        }

        $folderFactory = {
            param($FolderName)
            if ($this.ThrowOnAdd) {
                throw [System.Runtime.InteropServices.COMException]::new("MAPI_E_DISK_ERROR: Cannot create folder '$FolderName'.")
            }
            $childList = [System.Collections.Generic.List[object]]::new()
            $child = [PSCustomObject]@{
                Name       = $FolderName
                FolderPath = "$($this.FolderPath)\$FolderName"
                Folders    = $childList
                ThrowOnAdd = $this.ThrowOnAdd
            }
            $child | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $folderFactory
            $this.Folders.Add($child)
            return $child
        }
        $mockRootFolder | Add-Member -MemberType ScriptMethod -Name AddFolder -Value $folderFactory

        # Default system folders (created without throwing)
        $mockInbox = $mockRootFolder.AddFolder('Inbox')
        $null = $mockRootFolder.AddFolder('Sent Items')
        $null = $mockRootFolder.AddFolder('Deleted Items')

        # Arm the ThrowOnAdd flag after base folders exist
        if ($ThrowOnFolderAdd) {
            $mockRootFolder.ThrowOnAdd = $true
            $mockInbox.ThrowOnAdd = $true
        }

        # 2. Rules List
        $rulesList = [System.Collections.Generic.List[object]]::new()
        foreach ($ir in $InitialRules) {
            [void]$rulesList.Add($ir)
        }

        $mockRules = [PSCustomObject]@{
            Count                = $rulesList.Count
            RulesList            = $rulesList
            SaveCallCount        = 0
            SaveWithArgCallCount = 0
            SaveNoArgCallCount   = 0
            LastSaveArg          = $null
            ThrowOnSaveWithArg   = $ThrowOnSaveWithArg
            ThrowOnSaveAll       = $ThrowOnSaveAll
        }
        $mockRules | Add-Member -MemberType ScriptMethod -Name GetEnumerator -Value { $this.RulesList.GetEnumerator() }
        $mockRules | Add-Member -MemberType ScriptMethod -Name Item -Value { param($idx) return $this.RulesList[$idx] }
        $mockRules | Add-Member -MemberType ScriptMethod -Name Save -Value {
            param($showProgress)
            $this.SaveCallCount++
            $script:saveCallCountTotal++

            if ($PSBoundParameters.ContainsKey('showProgress')) {
                $this.SaveWithArgCallCount++
                $this.LastSaveArg = $showProgress
                if ($this.ThrowOnSaveWithArg) {
                    throw [System.Runtime.InteropServices.COMException]::new("E_INVALIDARG: Save parameter not supported in this provider.")
                }
            } else {
                $this.SaveNoArgCallCount++
            }

            if ($this.ThrowOnSaveAll) {
                throw [System.Runtime.InteropServices.COMException]::new("MAPI_E_STORE_READ_ONLY: Failed to write rule table to store.")
            }
        }
        $mockRules | Add-Member -MemberType ScriptMethod -Name Create -Value {
            param($RuleName, $RuleType)
            $createdRule = [PSCustomObject]@{
                Name           = $RuleName
                RuleType       = $RuleType
                Enabled        = $false
                ExecutionOrder = $this.RulesList.Count + 1
                Conditions     = [PSCustomObject]@{
                    Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                    From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                    SentTo     = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                    Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                    Importance = [PSCustomObject]@{ Enabled = $false; Importance = 1 }
                    Account    = [PSCustomObject]@{ Enabled = $false; Account = $null }
                }
                Exceptions     = [PSCustomObject]@{
                    Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                    From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                    Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                }
                Actions        = [PSCustomObject]@{
                    MoveToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                    CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                    Delete       = [PSCustomObject]@{ Enabled = $false }
                    MarkAsRead   = [PSCustomObject]@{ Enabled = $false }
                    Stop         = [PSCustomObject]@{ Enabled = $false }
                }
            }
            $this.RulesList.Add($createdRule)
            $this.Count = $this.RulesList.Count
            return $createdRule
        }

        # 3. Store
        $mockStore = [PSCustomObject]@{
            DisplayName          = $StoreName
            FilePath             = $StorePath
            IsDataFileStore      = $true
            IsDefaultStore       = $true
            RootFolder           = $mockRootFolder
            Rules                = $mockRules
            ThrowOnGetRules      = $ThrowOnGetRules
            ThrowOnGetRootFolder = $ThrowOnGetRootFolder
        }
        $mockStore | Add-Member -MemberType ScriptMethod -Name GetRootFolder -Value {
            if ($this.ThrowOnGetRootFolder) {
                throw [System.Runtime.InteropServices.COMException]::new("MAPI_E_NOT_FOUND: Root folder is missing or corrupt.")
            }
            return $this.RootFolder
        }
        $mockStore | Add-Member -MemberType ScriptMethod -Name GetRules -Value {
            if ($this.ThrowOnGetRules) {
                throw [System.Runtime.InteropServices.COMException]::new("MAPI_E_CORRUPT_STORE: Rule dictionary is corrupted.")
            }
            return $this.Rules
        }

        # 4. Namespace
        $mockNs = [PSCustomObject]@{
            DefaultStore       = $mockStore
            Stores             = @($mockStore)
            Accounts           = @([PSCustomObject]@{ DisplayName = 'Target Account'; SmtpAddress = 'target@enterprise.com' })
            ThrowOnLogon       = $ThrowOnLogon
            LogoffCallCount    = 0
            LogonCallCount     = 0
        }
        $mockNs | Add-Member -MemberType ScriptMethod -Name Logon -Value {
            param($p, $pwd, $ui, $new)
            $this.LogonCallCount++
            $script:logonCallCountTotal++
            if ($this.ThrowOnLogon) {
                throw [System.Runtime.InteropServices.COMException]::new("MAPI_E_LOGON_FAILED: Profile cannot be opened.")
            }
        }
        $mockNs | Add-Member -MemberType ScriptMethod -Name Logoff -Value {
            $this.LogoffCallCount++
            $script:logoffCallCountTotal++
        }

        # 5. Application
        $mockApp = [PSCustomObject]@{
            MapiNamespace       = $mockNs
            ThrowOnGetNamespace = $ThrowOnGetNamespace
            QuitCallCount       = 0
        }
        $mockApp | Add-Member -MemberType ScriptMethod -Name GetNamespace -Value {
            param($name)
            if ($this.ThrowOnGetNamespace) {
                throw [System.Runtime.InteropServices.COMException]::new("E_FAIL: MAPI subsystem initialization failed.")
            }
            return $this.MapiNamespace
        }
        $mockApp | Add-Member -MemberType ScriptMethod -Name Quit -Value {
            $this.QuitCallCount++
            $script:quitCallCountTotal++
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

    # Helper: Build existing target rule instance
    function script:New-ChallengerTargetRule {
        param(
            [string]$Name,
            [int]$ExecutionOrder = 1,
            [bool]$Enabled = $true,
            [string[]]$SubjectText = @(),
            [object]$MoveFolder = $null,
            [bool]$Delete = $false
        )

        return [PSCustomObject]@{
            Name           = $Name
            RuleType       = 0
            Enabled        = $Enabled
            ExecutionOrder = $ExecutionOrder
            Conditions     = [PSCustomObject]@{
                Subject    = [PSCustomObject]@{ Enabled = ($SubjectText.Count -gt 0); Text = $SubjectText }
                From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                SentTo     = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
                Importance = [PSCustomObject]@{ Enabled = $false; Importance = 1 }
                Account    = [PSCustomObject]@{ Enabled = $false; Account = $null }
            }
            Exceptions     = [PSCustomObject]@{
                Subject    = [PSCustomObject]@{ Enabled = $false; Text = @() }
                From       = [PSCustomObject]@{ Enabled = $false; Recipients = @() }
                Categories = [PSCustomObject]@{ Enabled = $false; Categories = @() }
            }
            Actions        = [PSCustomObject]@{
                MoveToFolder = [PSCustomObject]@{ Folder = $MoveFolder; Enabled = ($null -ne $MoveFolder) }
                CopyToFolder = [PSCustomObject]@{ Folder = $null; Enabled = $false }
                Delete       = [PSCustomObject]@{ Enabled = $Delete }
                MarkAsRead   = [PSCustomObject]@{ Enabled = $false }
                Stop         = [PSCustomObject]@{ Enabled = $false }
            }
        }
    }
}

Describe 'Adversarial Stress: Import-OutlookRule Duplicate Policies & COM Lifecycle' {
    BeforeEach {
        $script:saveCallCountTotal = 0
        $script:logoffCallCountTotal = 0
        $script:logonCallCountTotal = 0
        $script:quitCallCountTotal = 0
        $script:capturedObjects = $null
    }

    Context 'Stress Testing Duplicate Policy: Skip' {
        It 'Preserves pre-existing target rule completely and skips matching manifest rule' {
            $existingRule = New-ChallengerTargetRule -Name 'Project Alpha' -SubjectText @('Original Subject') -Enabled $true
            $env = New-ChallengerImportEnv -InitialRules @($existingRule)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $manifestRule = New-ChallengerRuleDef -Name 'Project Alpha' -SubjectText @('Manifest Subject Changed') -MarkAsRead $true
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_skip1_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($manifestRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'Skip'
                $res.Success | Should -BeTrue
                $res.RulesSkipped | Should -Be 1
                $res.RulesImported | Should -Be 0
                $res.RulesOverwritten | Should -Be 0

                # Existing rule remains in original state
                $targetRule = $env.RulesList | Where-Object { $_.Name -eq 'Project Alpha' }
                $targetRule.Conditions.Subject.Text | Should -Contain 'Original Subject'
                $targetRule.Conditions.Subject.Text | Should -Not -Contain 'Manifest Subject Changed'
                $targetRule.Actions.MarkAsRead.Enabled | Should -BeFalse
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Skips multiple duplicates while importing distinct non-duplicate rules' {
            $ruleA = New-ChallengerTargetRule -Name 'Rule Alpha'
            $ruleB = New-ChallengerTargetRule -Name 'Rule Beta'
            $env = New-ChallengerImportEnv -InitialRules @($ruleA, $ruleB)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $defA = New-ChallengerRuleDef -Name 'Rule Alpha' -SubjectText @('A')
            $defB = New-ChallengerRuleDef -Name 'Rule Beta' -SubjectText @('B')
            $defC = New-ChallengerRuleDef -Name 'Rule Gamma' -SubjectText @('C')
            $defD = New-ChallengerRuleDef -Name 'Rule Delta' -SubjectText @('D')
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_skip2_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($defA, $defB, $defC, $defD)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'Skip'
                $res.Success | Should -BeTrue
                $res.RulesSkipped | Should -Be 2
                $res.RulesImported | Should -Be 2
                $env.RulesList.Count | Should -Be 4
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Performs case-insensitive matching when detecting duplicates to skip' {
            $existingRule = New-ChallengerTargetRule -Name 'URGENT SECURITY ALERTS'
            $env = New-ChallengerImportEnv -InitialRules @($existingRule)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $defLower = New-ChallengerRuleDef -Name 'urgent security alerts' -SubjectText @('New Alert')
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_skip3_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($defLower)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'Skip'
                $res.Success | Should -BeTrue
                $res.RulesSkipped | Should -Be 1
                $res.RulesImported | Should -Be 0
                $env.RulesList.Count | Should -Be 1
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Detects intra-manifest duplicates when target store is initially empty' {
            $env = New-ChallengerImportEnv
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $def1 = New-ChallengerRuleDef -Name 'SharedRule' -SubjectText @('Version 1')
            $def2 = New-ChallengerRuleDef -Name 'SharedRule' -SubjectText @('Version 2')
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_skip4_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($def1, $def2)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'Skip'
                $res.Success | Should -BeTrue
                $res.RulesImported | Should -Be 1
                $res.RulesSkipped | Should -Be 1

                $target = $env.RulesList | Where-Object { $_.Name -eq 'SharedRule' }
                $target.Conditions.Subject.Text | Should -Contain 'Version 1'
                $target.Conditions.Subject.Text | Should -Not -Contain 'Version 2'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Succeeds and commits cleanly when all manifest rules are duplicates under Skip' {
            $r1 = New-ChallengerTargetRule -Name 'Rule 1'
            $r2 = New-ChallengerTargetRule -Name 'Rule 2'
            $env = New-ChallengerImportEnv -InitialRules @($r1, $r2)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $def1 = New-ChallengerRuleDef -Name 'Rule 1'
            $def2 = New-ChallengerRuleDef -Name 'Rule 2'
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_skip5_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($def1, $def2)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'Skip'
                $res.Success | Should -BeTrue
                $res.RulesSkipped | Should -Be 2
                $res.RulesImported | Should -Be 0
                $env.Rules.SaveCallCount | Should -Be 1
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }

    Context 'Stress Testing Duplicate Policy: Overwrite' {
        It 'Thoroughly resets stale actions and conditions in-place before applying manifest definitions' {
            $oldFolder = [PSCustomObject]@{ Name = 'StaleFolder'; FolderPath = '\StaleFolder' }
            $existingRule = New-ChallengerTargetRule -Name 'Billing Filter' -SubjectText @('Old Invoice') -MoveFolder $oldFolder -Delete $true
            $env = New-ChallengerImportEnv -InitialRules @($existingRule)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            # Manifest rule defines ONLY MarkAsRead action and no folder action, no delete
            $manifestRule = New-ChallengerRuleDef -Name 'Billing Filter' -SubjectText @('New Clean Subject') -MarkAsRead $true
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_ow1_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($manifestRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'Overwrite'
                $res.Success | Should -BeTrue
                $res.RulesOverwritten | Should -Be 1

                $updated = $env.RulesList | Where-Object { $_.Name -eq 'Billing Filter' }
                $updated.Conditions.Subject.Text | Should -Contain 'New Clean Subject'
                $updated.Conditions.Subject.Text | Should -Not -Contain 'Old Invoice'

                # Verify stale actions were wiped
                $updated.Actions.MoveToFolder.Enabled | Should -BeFalse
                $updated.Actions.MoveToFolder.Folder | Should -BeNullOrEmpty
                $updated.Actions.Delete.Enabled | Should -BeFalse
                $updated.Actions.MarkAsRead.Enabled | Should -BeTrue
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Preserves exact COM rule instance in-place when overwriting' {
            $existingRule = New-ChallengerTargetRule -Name 'Persistent Rule'
            $env = New-ChallengerImportEnv -InitialRules @($existingRule)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $manifestRule = New-ChallengerRuleDef -Name 'Persistent Rule' -SubjectText @('Ref Check')
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_ow2_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($manifestRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'Overwrite'
                $res.Success | Should -BeTrue
                $env.RulesList.Count | Should -Be 1
                [System.Object]::ReferenceEquals($env.RulesList[0], $existingRule) | Should -BeTrue
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Handles intra-manifest overwrite when multiple definitions exist for same rule' {
            $env = New-ChallengerImportEnv
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $def1 = New-ChallengerRuleDef -Name 'EvolvingRule' -SubjectText @('Iteration 1')
            $def2 = New-ChallengerRuleDef -Name 'EvolvingRule' -SubjectText @('Iteration 2')
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_ow3_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($def1, $def2)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'Overwrite'
                $res.Success | Should -BeTrue
                $res.RulesOverwritten | Should -Be 1
                $env.RulesList.Count | Should -Be 1

                $rule = $env.RulesList[0]
                $rule.Conditions.Subject.Text | Should -Contain 'Iteration 2'
                $rule.Conditions.Subject.Text | Should -Not -Contain 'Iteration 1'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Performs case-insensitive in-place overwrite' {
            $existingRule = New-ChallengerTargetRule -Name 'CASE INSENSITIVE RULE'
            $env = New-ChallengerImportEnv -InitialRules @($existingRule)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $manifestRule = New-ChallengerRuleDef -Name 'case insensitive rule' -SubjectText @('Overwritten Content')
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_ow4_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($manifestRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'Overwrite'
                $res.Success | Should -BeTrue
                $res.RulesOverwritten | Should -Be 1
                $env.RulesList.Count | Should -Be 1
                $env.RulesList[0].Conditions.Subject.Text | Should -Contain 'Overwritten Content'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }

    Context 'Stress Testing Duplicate Policy: Rename' {
        It 'Disambiguates duplicate rule to (Imported) suffix' {
            $existingRule = New-ChallengerTargetRule -Name 'Route Mails'
            $env = New-ChallengerImportEnv -InitialRules @($existingRule)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $manifestRule = New-ChallengerRuleDef -Name 'Route Mails' -SubjectText @('Imported Content')
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_ren1_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($manifestRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'Rename'
                $res.Success | Should -BeTrue
                $res.RulesRenamed | Should -Be 1
                $res.RulesImported | Should -Be 1

                $env.RulesList.Count | Should -Be 2
                $names = @($env.RulesList | ForEach-Object { $_.Name })
                $names | Should -Contain 'Route Mails'
                $names | Should -Contain 'Route Mails (Imported)'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Cascades disambiguation to (Imported 2) when (Imported) already exists in target store' {
            $r1 = New-ChallengerTargetRule -Name 'Route Mails'
            $r2 = New-ChallengerTargetRule -Name 'Route Mails (Imported)'
            $env = New-ChallengerImportEnv -InitialRules @($r1, $r2)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $manifestRule = New-ChallengerRuleDef -Name 'Route Mails' -SubjectText @('Third Occurrence')
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_ren2_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($manifestRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'Rename'
                $res.Success | Should -BeTrue
                $res.RulesRenamed | Should -Be 1

                $env.RulesList.Count | Should -Be 3
                $names = @($env.RulesList | ForEach-Object { $_.Name })
                $names | Should -Contain 'Route Mails'
                $names | Should -Contain 'Route Mails (Imported)'
                $names | Should -Contain 'Route Mails (Imported 2)'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Disambiguates high-frequency collision cascades up to (Imported 4)' {
            $r1 = New-ChallengerTargetRule -Name 'Cascade'
            $r2 = New-ChallengerTargetRule -Name 'Cascade (Imported)'
            $r3 = New-ChallengerTargetRule -Name 'Cascade (Imported 2)'
            $r4 = New-ChallengerTargetRule -Name 'Cascade (Imported 3)'
            $env = New-ChallengerImportEnv -InitialRules @($r1, $r2, $r3, $r4)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $manifestRule = New-ChallengerRuleDef -Name 'Cascade' -SubjectText @('Cascade Test')
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_ren3_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($manifestRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'Rename'
                $res.Success | Should -BeTrue
                $res.RulesRenamed | Should -Be 1

                $names = @($env.RulesList | ForEach-Object { $_.Name })
                $names | Should -Contain 'Cascade (Imported 4)'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Sequentially disambiguates multiple intra-manifest duplicates with identical names' {
            $env = New-ChallengerImportEnv -InitialRules @((New-ChallengerTargetRule -Name 'BulkStream'))
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $def1 = New-ChallengerRuleDef -Name 'BulkStream' -SubjectText @('Stream 1')
            $def2 = New-ChallengerRuleDef -Name 'BulkStream' -SubjectText @('Stream 2')
            $def3 = New-ChallengerRuleDef -Name 'BulkStream' -SubjectText @('Stream 3')
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_ren4_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($def1, $def2, $def3)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'Rename'
                $res.Success | Should -BeTrue
                $res.RulesRenamed | Should -Be 3
                $res.RulesImported | Should -Be 3

                $names = @($env.RulesList | ForEach-Object { $_.Name })
                $names | Should -Contain 'BulkStream'
                $names | Should -Contain 'BulkStream (Imported)'
                $names | Should -Contain 'BulkStream (Imported 2)'
                $names | Should -Contain 'BulkStream (Imported 3)'
                $env.RulesList.Count | Should -Be 4
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }

    Context 'Stress Testing Duplicate Policy: KeepBoth' {
        It 'Disambiguates duplicate rule to (1) numeric suffix' {
            $existingRule = New-ChallengerTargetRule -Name 'Sync Calendar'
            $env = New-ChallengerImportEnv -InitialRules @($existingRule)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $manifestRule = New-ChallengerRuleDef -Name 'Sync Calendar' -SubjectText @('Sync Manifest')
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_both1_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($manifestRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'KeepBoth'
                $res.Success | Should -BeTrue
                $res.RulesRenamed | Should -Be 1
                $res.RulesImported | Should -Be 1

                $names = @($env.RulesList | ForEach-Object { $_.Name })
                $names | Should -Contain 'Sync Calendar'
                $names | Should -Contain 'Sync Calendar (1)'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Cascades numeric disambiguation when (1) already exists in target store' {
            $r1 = New-ChallengerTargetRule -Name 'Sync Calendar'
            $r2 = New-ChallengerTargetRule -Name 'Sync Calendar (1)'
            $env = New-ChallengerImportEnv -InitialRules @($r1, $r2)
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $manifestRule = New-ChallengerRuleDef -Name 'Sync Calendar' -SubjectText @('Sync Manifest 2')
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_both2_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($manifestRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'KeepBoth'
                $res.Success | Should -BeTrue
                $res.RulesRenamed | Should -Be 1

                $names = @($env.RulesList | ForEach-Object { $_.Name })
                $names | Should -Contain 'Sync Calendar'
                $names | Should -Contain 'Sync Calendar (1)'
                $names | Should -Contain 'Sync Calendar (2)'
                $env.RulesList.Count | Should -Be 3
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Sequentially disambiguates multiple intra-manifest duplicates with KeepBoth' {
            $env = New-ChallengerImportEnv -InitialRules @((New-ChallengerTargetRule -Name 'LogStream'))
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $def1 = New-ChallengerRuleDef -Name 'LogStream' -SubjectText @('L1')
            $def2 = New-ChallengerRuleDef -Name 'LogStream' -SubjectText @('L2')
            $def3 = New-ChallengerRuleDef -Name 'LogStream' -SubjectText @('L3')
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_both3_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($def1, $def2, $def3)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath -DuplicateHandling 'KeepBoth'
                $res.Success | Should -BeTrue
                $res.RulesRenamed | Should -Be 3
                $res.RulesImported | Should -Be 3

                $names = @($env.RulesList | ForEach-Object { $_.Name })
                $names | Should -Contain 'LogStream'
                $names | Should -Contain 'LogStream (1)'
                $names | Should -Contain 'LogStream (2)'
                $names | Should -Contain 'LogStream (3)'
                $env.RulesList.Count | Should -Be 4
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }

    Context 'Stress Testing UI Prompt Suppression: $targetRules.Save($false)' {
        It 'Strictly passes boolean $false to $targetRules.Save to suppress UI dialogs' {
            $env = New-ChallengerImportEnv
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $manifestRule = New-ChallengerRuleDef -Name 'Silent Rule' -SubjectText @('Silent Save Test')
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_save1_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($manifestRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath
                $res.Success | Should -BeTrue

                # Verify Save was called with exactly $false
                $env.Rules.SaveCallCount | Should -Be 1
                $env.Rules.SaveWithArgCallCount | Should -Be 1
                $env.Rules.LastSaveArg | Should -BeFalse
                ($env.Rules.LastSaveArg -is [bool]) | Should -BeTrue
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Gracefully falls back to parameterless Save() when Save($false) throws COMException' {
            # Throw on SaveWithArg, but allow parameterless Save()
            $env = New-ChallengerImportEnv -ThrowOnSaveWithArg $true -ThrowOnSaveAll $false
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $manifestRule = New-ChallengerRuleDef -Name 'Fallback Save Rule' -SubjectText @('Fallback Test')
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_save2_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($manifestRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath
                $res.Success | Should -BeTrue

                # Verify Save was called with $false first, then fell back to parameterless Save()
                $env.Rules.SaveWithArgCallCount | Should -Be 1
                $env.Rules.SaveNoArgCallCount | Should -Be 1
                $env.Rules.SaveCallCount | Should -Be 2
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Catches fatal Save error when both Save($false) and Save() fail, returning structured error' {
            $env = New-ChallengerImportEnv -ThrowOnSaveWithArg $true -ThrowOnSaveAll $true
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'TargetProfile' } } -ModuleName 'Outlook'

            $manifestRule = New-ChallengerRuleDef -Name 'Fatal Save Rule' -SubjectText @('Fatal Save Test')
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_save3_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($manifestRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath
                $res.Success | Should -BeFalse
                $res.Method | Should -Be 'None'
                $res.ErrorMessage | Should -Match 'Failed to commit rules to store via Save'
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }

    Context 'Stress Testing COM Lifecycle & Reference Cleanup Under Exceptions' {
        It 'Releases COM references and calls Quit() when GetNamespace fails' {
            $env = New-ChallengerImportEnv -ThrowOnGetNamespace $true
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            Mock Remove-ToolkitComObject {
                param($ComObjects)
                $script:capturedObjects = $ComObjects
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                $script:capturedObjects = $ComObjects
            }

            $manifestRule = New-ChallengerRuleDef -Name 'Fail NS Rule'
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_com1_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($manifestRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath
                $res.Success | Should -BeFalse
                $res.ErrorMessage | Should -Match 'MAPI'

                # Verify COM cleanup ran in finally
                $null -ne $script:capturedObjects | Should -BeTrue
                $script:capturedObjects | Should -Contain $env.App
                $script:quitCallCountTotal | Should -Be 1
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Releases COM references and calls Logoff() and Quit() when GetRootFolder fails' {
            $env = New-ChallengerImportEnv -ThrowOnGetRootFolder $true
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            Mock Remove-ToolkitComObject {
                param($ComObjects)
                $script:capturedObjects = $ComObjects
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                $script:capturedObjects = $ComObjects
            }

            $manifestRule = New-ChallengerRuleDef -Name 'Fail Root Rule'
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_com2_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($manifestRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath
                $res.Success | Should -BeFalse
                $res.ErrorMessage | Should -Match 'root folder'

                # Finally block executed
                $null -ne $script:capturedObjects | Should -BeTrue
                $script:capturedObjects | Should -Contain $env.App
                $script:capturedObjects | Should -Contain $env.Namespace
                $script:capturedObjects | Should -Contain $env.Store
                $script:logoffCallCountTotal | Should -Be 1
                $script:quitCallCountTotal | Should -Be 1
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Releases COM references when GetRules throws MAPI_E_CORRUPT_STORE' {
            $env = New-ChallengerImportEnv -ThrowOnGetRules $true
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            Mock Remove-ToolkitComObject {
                param($ComObjects)
                $script:capturedObjects = $ComObjects
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                $script:capturedObjects = $ComObjects
            }

            $manifestRule = New-ChallengerRuleDef -Name 'Corrupt Rules Rule'
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_com3_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($manifestRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath
                $res.Success | Should -BeFalse
                $res.ErrorMessage | Should -Match 'MAPI_E_CORRUPT_STORE|Rules collection'

                $null -ne $script:capturedObjects | Should -BeTrue
                $script:capturedObjects | Should -Contain $env.App
                $script:capturedObjects | Should -Contain $env.Namespace
                $script:capturedObjects | Should -Contain $env.Store
                $script:capturedObjects | Should -Contain $env.RootFolder
                $script:logoffCallCountTotal | Should -Be 1
                $script:quitCallCountTotal | Should -Be 1
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Releases COM references when folder pre-creation throws disk/permission exception' {
            $env = New-ChallengerImportEnv -ThrowOnFolderAdd $true
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            Mock Remove-ToolkitComObject {
                param($ComObjects)
                $script:capturedObjects = $ComObjects
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                $script:capturedObjects = $ComObjects
            }

            $manifestRule = New-ChallengerRuleDef -Name 'Folder Fail Rule' -MoveToFolder 'Inbox\SubF1\SubF2'
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_com4_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($manifestRule) -CustomFolders @('Inbox\SubF1\SubF2')

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath
                $res.Success | Should -BeFalse
                $res.ErrorMessage | Should -Match 'Cannot create folder'

                $null -ne $script:capturedObjects | Should -BeTrue
                $script:capturedObjects | Should -Contain $env.Rules
                $script:capturedObjects | Should -Contain $env.RootFolder
                $script:capturedObjects | Should -Contain $env.Store
                $script:capturedObjects | Should -Contain $env.Namespace
                $script:capturedObjects | Should -Contain $env.App
                $script:logoffCallCountTotal | Should -Be 1
                $script:quitCallCountTotal | Should -Be 1
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Releases COM references when Save fails fatal error' {
            $env = New-ChallengerImportEnv -ThrowOnSaveWithArg $true -ThrowOnSaveAll $true
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }

            Mock Remove-ToolkitComObject {
                param($ComObjects)
                $script:capturedObjects = $ComObjects
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                $script:capturedObjects = $ComObjects
            }

            $manifestRule = New-ChallengerRuleDef -Name 'Save Fail Rule'
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_com5_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($manifestRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath
                $res.Success | Should -BeFalse

                $null -ne $script:capturedObjects | Should -BeTrue
                $script:capturedObjects | Should -Contain $env.Rules
                $script:capturedObjects | Should -Contain $env.RootFolder
                $script:capturedObjects | Should -Contain $env.Store
                $script:capturedObjects | Should -Contain $env.Namespace
                $script:capturedObjects | Should -Contain $env.App
                $script:quitCallCountTotal | Should -Be 1
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'STRICTLY SKIPS calling Quit() when Outlook WAS already running before exception occurs' {
            $env = New-ChallengerImportEnv -ThrowOnGetRules $true
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            # Simulate pre-existing Outlook process
            Mock Get-Process { return @([PSCustomObject]@{ Id = 8888; ProcessName = 'OUTLOOK' }) } -ModuleName 'Outlook'
            Mock Get-Process { return @([PSCustomObject]@{ Id = 8888; ProcessName = 'OUTLOOK' }) }

            Mock Remove-ToolkitComObject {
                param($ComObjects)
                $script:capturedObjects = $ComObjects
            } -ModuleName 'Outlook'
            Mock Remove-ToolkitComObject {
                param($ComObjects)
                $script:capturedObjects = $ComObjects
            }

            $manifestRule = New-ChallengerRuleDef -Name 'Process Running Rule'
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_com6_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($manifestRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath
                $res.Success | Should -BeFalse

                # Crucial assertion: Quit was NOT called because Outlook was running before!
                $script:quitCallCountTotal | Should -Be 0
                # But COM references WERE cleaned up!
                $null -ne $script:capturedObjects | Should -BeTrue
                $script:capturedObjects | Should -Contain $env.Store
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }

        It 'Executes fallback COM reference cleanup when Remove-ToolkitComObject is unavailable' {
            $env = New-ChallengerImportEnv -ThrowOnGetRules $true
            Mock Get-OutlookComApplication { return $env.App } -ModuleName 'Outlook'
            Mock Get-Process { return @() } -ModuleName 'Outlook'
            Mock Get-Process { return @() }
            # Hide Remove-ToolkitComObject so fallback branch is exercised
            Mock Get-Command { return $null } -ModuleName 'Outlook' -ParameterFilter { $Name -eq 'Remove-ToolkitComObject' }

            $manifestRule = New-ChallengerRuleDef -Name 'Fallback Cleanup Rule'
            $testJson = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "stress_com7_$([System.Guid]::NewGuid().ToString('N')).json"
            New-ChallengerImportManifest -Path $testJson -Rules @($manifestRule)

            try {
                $res = Import-OutlookRule -Path $testJson -TargetStorePath $env.Store.FilePath
                $res.Success | Should -BeFalse
                $script:quitCallCountTotal | Should -Be 1
                $script:logoffCallCountTotal | Should -Be 1
            }
            finally {
                if (Test-Path -LiteralPath $testJson) { Remove-Item -LiteralPath $testJson -Force }
            }
        }
    }
}
