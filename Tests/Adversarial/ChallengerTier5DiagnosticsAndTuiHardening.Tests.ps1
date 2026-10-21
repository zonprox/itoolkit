# Tests/Adversarial/ChallengerTier5DiagnosticsAndTuiHardening.Tests.ps1
# Milestone 5 Tier 5 White-Box Adversarial Hardening Suite
# Focus: Rule Diagnostics & Auto-Repair, Profile Selector, and TUI Menu Routing

BeforeAll {
    $script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:IToolkitManifest = Join-Path $script:ProjectRoot 'IToolkit.psd1'
    $script:OutlookManifest  = Join-Path $script:ProjectRoot 'Modules/Outlook/Outlook.psd1'
    $script:TUIManifest      = Join-Path $script:ProjectRoot 'Modules/TUI/TUI.psd1'

    # Clean imports
    Remove-Module IToolkit, Outlook, TUI -ErrorAction SilentlyContinue
    Import-Module $script:IToolkitManifest -Force

    # Ensure C: PSDrive for cross-platform Linux compatibility
    if (-not (Get-PSDrive -Name 'C' -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name 'C' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -ErrorAction SilentlyContinue | Out-Null
    }

    # Ensure TEMP environment variable is populated on Linux
    $env:TEMP = [System.IO.Path]::GetTempPath().TrimEnd('/','\')

    # Ensure global TUI helper functions are initialized
    $tuiScript = Join-Path $script:ProjectRoot 'Modules/TUI/Public/Invoke-ToolkitSubmenuOfficeOutlook.ps1'
    if (Test-Path -LiteralPath $tuiScript) {
        . $tuiScript
    }

    function script:Get-NormalizedTestStorePath {
        param([string]$LeafName)
        return (Join-Path ([System.IO.Path]::GetTempPath()) $LeafName)
    }

    # Helper to construct a mock rule for Repair-OutlookRule
    function script:New-MockRule {
        param(
            [string]$Name = 'Rule1',
            [int]$ExecutionOrder = 1,
            [bool]$Enabled = $true,
            [int]$RuleType = 0,
            [string[]]$Subject = $null,
            [string[]]$Body = $null,
            [string[]]$From = $null,
            [string[]]$SentTo = $null,
            [string[]]$Categories = $null,
            [object]$Importance = $null,
            [object]$MoveToFolder = $null,
            [bool]$MoveEnabled = $false,
            [object]$CopyToFolder = $null,
            [bool]$CopyEnabled = $false,
            [bool]$Delete = $false,
            [bool]$DeletePermanently = $false,
            [bool]$MarkAsRead = $false,
            [bool]$Stop = $false,
            [string[]]$AssignCategories = $null
        )

        $subjArr = if ($null -ne $Subject) { $Subject } else { @() }
        $bodyArr = if ($null -ne $Body) { $Body } else { @() }
        $fromArr = if ($null -ne $From) { $From } else { @() }
        $toArr   = if ($null -ne $SentTo) { $SentTo } else { @() }
        $catArr  = if ($null -ne $Categories) { $Categories } else { @() }

        $condObj = [ordered]@{
            Subject    = [PSCustomObject]@{ Enabled = ($subjArr.Count -gt 0); Text = $subjArr }
            Body       = [PSCustomObject]@{ Enabled = ($bodyArr.Count -gt 0); Text = $bodyArr }
            From       = [PSCustomObject]@{ Enabled = ($fromArr.Count -gt 0); Recipients = $fromArr }
            SentTo     = [PSCustomObject]@{ Enabled = ($toArr.Count -gt 0); Recipients = $toArr }
            Categories = [PSCustomObject]@{ Enabled = ($catArr.Count -gt 0); Categories = $catArr }
        }
        if ($null -ne $Importance) {
            $condObj['Importance'] = [PSCustomObject]@{ Enabled = $true; Importance = $Importance }
        }

        $actObj = [ordered]@{
            MoveToFolder      = [PSCustomObject]@{ Folder = $MoveToFolder; Enabled = $MoveEnabled }
            CopyToFolder      = [PSCustomObject]@{ Folder = $CopyToFolder; Enabled = $CopyEnabled }
            Delete            = [PSCustomObject]@{ Enabled = $Delete }
            DeletePermanently = [PSCustomObject]@{ Enabled = $DeletePermanently }
            MarkAsRead        = [PSCustomObject]@{ Enabled = $MarkAsRead }
            Stop              = [PSCustomObject]@{ Enabled = $Stop }
        }
        if ($null -ne $AssignCategories) {
            $actObj['AssignToCategory'] = [PSCustomObject]@{ Enabled = ($AssignCategories.Count -gt 0); Categories = $AssignCategories }
        }

        return [PSCustomObject]@{
            Name           = $Name
            ExecutionOrder = $ExecutionOrder
            Enabled        = $Enabled
            RuleType       = $RuleType
            Conditions     = [PSCustomObject]$condObj
            Exceptions     = [PSCustomObject]@{}
            Actions        = [PSCustomObject]$actObj
        }
    }

    # Helper to construct a mock folder
    function script:New-MockFolder {
        param(
            [string]$Name,
            [string]$FolderPath
        )
        $childFolders = [System.Collections.Generic.List[object]]::new()
        $folder = [PSCustomObject]@{
            Name       = $Name
            FolderPath = $FolderPath
            Folders    = $childFolders
        }
        $folder | Add-Member -MemberType ScriptMethod -Name 'AddFolder' -Value {
            param([string]$FolderName)
            $subPath = "$($this.FolderPath)\$FolderName"
            $subChild = script:New-MockFolder -Name $FolderName -FolderPath $subPath
            $this.Folders.Add($subChild)
            return $subChild
        }
        return $folder
    }

    # Helper to construct a controllable mock Outlook COM environment
    function script:New-MockOutlookEnvironment {
        param(
            [string]$StorePath,
            [string]$StoreName = 'TestStore',
            [object[]]$Rules = @(),
            [string[]]$FolderNames = @('Inbox', 'Archive', 'Projects'),
            [bool]$ThrowOnSave = $false
        )

        if ([string]::IsNullOrWhiteSpace($StorePath)) {
            $StorePath = script:Get-NormalizedTestStorePath "$StoreName.pst"
        }

        $rulesList = [System.Collections.Generic.List[object]]::new()
        foreach ($r in $Rules) {
            $rulesList.Add($r)
        }

        $mockRulesCollection = [PSCustomObject]@{
            Count       = $rulesList.Count
            RulesList   = $rulesList
            ThrowOnSave = $ThrowOnSave
        }
        $mockRulesCollection | Add-Member -MemberType ScriptMethod -Name 'Item' -Value {
            param([int]$idx)
            if ($idx -ge 1 -and $idx -le $this.RulesList.Count) {
                return $this.RulesList[$idx - 1]
            }
            return $null
        }
        $mockRulesCollection | Add-Member -MemberType ScriptMethod -Name 'Remove' -Value {
            param([int]$idx)
            if ($idx -ge 1 -and $idx -le $this.RulesList.Count) {
                $this.RulesList.RemoveAt($idx - 1)
                $this.Count = $this.RulesList.Count
            }
        }
        $mockRulesCollection | Add-Member -MemberType ScriptMethod -Name 'Save' -Value {
            param([bool]$ShowProgress = $false)
            if ($this.ThrowOnSave) {
                throw "MAPI_E_EXTENDED_ERROR: Failed to save rules collection."
            }
        }

        $rootFolder = script:New-MockFolder -Name $StoreName -FolderPath "\\$StoreName"
        $inboxFolder = $null
        foreach ($fName in $FolderNames) {
            $created = $rootFolder.AddFolder($fName)
            if ($fName -ieq 'Inbox') {
                $inboxFolder = $created
            }
        }

        $mockStore = [PSCustomObject]@{
            DisplayName    = $StoreName
            Name           = $StoreName
            FilePath       = $StorePath
            Path           = $StorePath
            IsDefaultStore = $true
            RootFolder     = $rootFolder
            Rules          = $mockRulesCollection
        }
        $mockStore | Add-Member -MemberType ScriptMethod -Name 'GetRootFolder' -Value { return $this.RootFolder }
        $mockStore | Add-Member -MemberType ScriptMethod -Name 'GetRules' -Value { return $this.Rules }

        $storesList = [System.Collections.Generic.List[object]]::new()
        $storesList.Add($mockStore)

        $mockNamespace = [PSCustomObject]@{
            Stores       = $storesList
            DefaultStore = $mockStore
        }
        $mockNamespace | Add-Member -MemberType ScriptMethod -Name 'Logon' -Value {
            param($profile, $pass, $ui, $shared)
        }
        $mockNamespace | Add-Member -MemberType ScriptMethod -Name 'Logoff' -Value {}

        $mockComApp = [PSCustomObject]@{
            Namespace = $mockNamespace
        }
        $mockComApp | Add-Member -MemberType ScriptMethod -Name 'GetNamespace' -Value {
            param([string]$type)
            return $this.Namespace
        }
        $mockComApp | Add-Member -MemberType ScriptMethod -Name 'Quit' -Value {}

        return @{
            ComApp          = $mockComApp
            Namespace       = $mockNamespace
            Store           = $mockStore
            RulesCollection = $mockRulesCollection
            RootFolder      = $rootFolder
            InboxFolder     = $inboxFolder
        }
    }
}

Describe 'Tier 5 Challenger: Rule Diagnostics & Auto-Repair Advanced Coverage' {

    Context '1.1 Pipeline Binding & Environment Variable Expansion in StorePath' {

        It 'Accepts StorePath via pipeline property and expands %TEMP% environment variables' {
            $tempDir = [System.IO.Path]::GetTempPath().TrimEnd('/','\')
            $expectedResolved = Join-Path $tempDir 'PipelineTest.pst'
            $env = script:New-MockOutlookEnvironment -StorePath $expectedResolved -StoreName 'PipelineTest'
            Mock -CommandName 'Get-OutlookComApplication' -ModuleName 'Outlook' { return $env.ComApp }

            $rawStore = "%TEMP%$([System.IO.Path]::DirectorySeparatorChar)PipelineTest.pst"
            $pipelineInput = [PSCustomObject]@{
                StorePath   = $rawStore
                ProfileName = 'PipelineProfile'
            }

            $res = $pipelineInput | Repair-OutlookRule
            $res.Success | Should -BeTrue
            $res.StorePath | Should -Be $expectedResolved
            $res.ProfileName | Should -Be 'PipelineProfile'
        }

        It 'Trims surrounding whitespace from StorePath before resolution' {
            $storePath = script:Get-NormalizedTestStorePath 'PaddedStore.pst'
            $env = script:New-MockOutlookEnvironment -StorePath $storePath -StoreName 'PaddedStore'
            Mock -CommandName 'Get-OutlookComApplication' -ModuleName 'Outlook' { return $env.ComApp }

            $res = Repair-OutlookRule -StorePath "   $storePath   " -ProfileName 'Default'
            $res.Success | Should -BeTrue
            $res.StorePath | Should -Be $storePath
        }
    }

    Context '1.2 SupportsShouldProcess (-WhatIf) Simulation Matrix' {

        It 'Executes non-mutating simulation with -AutoRepair and -WhatIf' {
            $res = Repair-OutlookRule -StorePath 'C:\Data\WhatIfStore.pst' -AutoRepair -WhatIf
            $res | Should -Not -BeNullOrEmpty
            $res.Method | Should -Be 'WhatIf'
            $res.Success | Should -BeTrue
            $res.TotalRules | Should -Be 0
            $res.RulesScanned | Should -Be 0
            $res.RepairedRulesCount | Should -Be 0
            $res.RemovedDuplicatesCount | Should -Be 0
            $res.RemovedEmptyCount | Should -Be 0
        }

        It 'Executes non-mutating simulation with -RemoveDuplicates and -WhatIf' {
            $res = Repair-OutlookRule -StoreName 'SalesStore' -RemoveDuplicates -WhatIf
            $res.Method | Should -Be 'WhatIf'
            $res.Success | Should -BeTrue
        }

        It 'Executes non-mutating simulation with -RemoveEmpty and -WhatIf' {
            $res = Repair-OutlookRule -ProfileName 'HRProfile' -RemoveEmpty -WhatIf
            $res.Method | Should -Be 'WhatIf'
            $res.Success | Should -BeTrue
        }

        It 'Executes non-mutating simulation through Test-OutlookRule alias with -WhatIf' {
            $res = Test-OutlookRule -StorePath 'C:\Data\AliasWhatIf.pst' -WhatIf
            $res.Method | Should -Be 'WhatIf'
            $res.Success | Should -BeTrue
        }
    }

    Context '1.3 Non-Existent Store and Graceful Error Trapping' {

        It 'Returns structured failure object when specified StorePath does not exist in stores' {
            $existingPath = script:Get-NormalizedTestStorePath 'ExistingStore.pst'
            $nonExistentPath = script:Get-NormalizedTestStorePath 'NonExistentStore.pst'
            $env = script:New-MockOutlookEnvironment -StorePath $existingPath -StoreName 'ExistingStore'
            Mock -CommandName 'Get-OutlookComApplication' -ModuleName 'Outlook' { return $env.ComApp }

            $res = Repair-OutlookRule -StorePath $nonExistentPath -ProfileName 'TestProfile'
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'Outlook store was not found'
            $res.RulesScanned | Should -Be 0
        }

        It 'Returns structured failure object when specified StoreName does not exist in stores' {
            $existingPath = script:Get-NormalizedTestStorePath 'ExistingStore2.pst'
            $env = script:New-MockOutlookEnvironment -StorePath $existingPath -StoreName 'ExistingStore2'
            Mock -CommandName 'Get-OutlookComApplication' -ModuleName 'Outlook' { return $env.ComApp }

            $res = Repair-OutlookRule -StoreName 'GhostStore' -ProfileName 'TestProfile'
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'Outlook store was not found'
        }
    }

    Context '1.4 Missing Inbox Fallback to Root Folder' {

        It 'Falls back to RootFolder when store contains no Inbox folder' {
            $storePath = script:Get-NormalizedTestStorePath 'NoInboxStore.pst'
            $brokenRule = script:New-MockRule -Name 'Move to Reports' -MoveEnabled $true -MoveToFolder $null
            $env = script:New-MockOutlookEnvironment -StorePath $storePath -StoreName 'NoInboxStore' -Rules @($brokenRule) -FolderNames @('Archive')
            Mock -CommandName 'Get-OutlookComApplication' -ModuleName 'Outlook' { return $env.ComApp }

            $res = Repair-OutlookRule -StorePath $storePath -AutoRepair
            $res.Success | Should -BeTrue
            $res.RepairedRulesCount | Should -Be 1

            $createdFolder = $env.RootFolder.Folders | Where-Object { $_.Name -eq 'Reports' }
            $createdFolder | Should -Not -BeNullOrEmpty
            $brokenRule.Actions.MoveToFolder.Folder | Should -Be $createdFolder
        }
    }

    Context '1.5 Complex Canonical Signature Equivalence' {

        It 'Identifies duplicate rules regardless of recipient ordering, casing, or text casing' {
            $storePath = script:Get-NormalizedTestStorePath 'DupStore.pst'
            $rule1 = script:New-MockRule -Name 'VIP Alerts A' -Subject @('Urgent', 'Invoice') -From @('ceo@corp.com', 'cfo@corp.com') -MarkAsRead $true
            $rule2 = script:New-MockRule -Name 'VIP Alerts B' -Subject @('INVOICE', 'URGENT') -From @('cfo@corp.com', 'CEO@CORP.COM') -MarkAsRead $true

            $env = script:New-MockOutlookEnvironment -StorePath $storePath -Rules @($rule1, $rule2)
            Mock -CommandName 'Get-OutlookComApplication' -ModuleName 'Outlook' { return $env.ComApp }

            $res = Repair-OutlookRule -StorePath $storePath
            $res.DuplicateRules.Count | Should -Be 1
            $res.DuplicateRules[0].Name | Should -Be 'VIP Alerts B'
            $res.DuplicateRules[0].DuplicateOf | Should -Be 'VIP Alerts A'
        }
    }

    Context '1.6 Compound Auto-Repair: Pruning Empty & Duplicates While Rebinding Broken Rules' {

        It 'Simultaneously prunes empty rules, dedupes redundant rules, and rebinds broken rules in one pass' {
            $storePath = script:Get-NormalizedTestStorePath 'CompoundStore.pst'
            $r1 = script:New-MockRule -Name 'KeepMe' -Subject @('Status') -Delete $true
            $r2 = script:New-MockRule -Name 'Move into Invoices' -MoveEnabled $true -MoveToFolder $null
            $r3 = script:New-MockRule -Name 'EmptyZombie' -Enabled $false
            $r4 = script:New-MockRule -Name 'KeepMe Duplicate' -Subject @('status') -Delete $true

            $env = script:New-MockOutlookEnvironment -StorePath $storePath -Rules @($r1, $r2, $r3, $r4)
            Mock -CommandName 'Get-OutlookComApplication' -ModuleName 'Outlook' { return $env.ComApp }

            $res = Repair-OutlookRule -StorePath $storePath -AutoRepair
            $res.Success | Should -BeTrue
            $res.TotalRules | Should -Be 4
            $res.RepairedRulesCount | Should -Be 1
            $res.RemovedDuplicatesCount | Should -Be 1
            $res.RemovedEmptyCount | Should -Be 1

            $env.RulesCollection.Count | Should -Be 2
            $env.RulesCollection.RulesList[0].Name | Should -Be 'KeepMe'
            $env.RulesCollection.RulesList[1].Name | Should -Be 'Move into Invoices'
            $env.RulesCollection.RulesList[1].Actions.MoveToFolder.Folder | Should -Not -BeNullOrEmpty
        }
    }

    Context '1.7 Save Failure Graceful Handling' {

        It 'Traps Save failure and returns structured failure object without crashing' {
            $storePath = script:Get-NormalizedTestStorePath 'SaveFailStore.pst'
            $brokenRule = script:New-MockRule -Name 'Move to Test' -MoveEnabled $true -MoveToFolder $null
            $env = script:New-MockOutlookEnvironment -StorePath $storePath -Rules @($brokenRule) -ThrowOnSave $true
            Mock -CommandName 'Get-OutlookComApplication' -ModuleName 'Outlook' { return $env.ComApp }

            $res = Repair-OutlookRule -StorePath $storePath -AutoRepair
            $res.Success | Should -BeFalse
            $res.ErrorMessage | Should -Match 'Failed to commit rules collection'
        }
    }

    Context '1.8 Detached Target Store Broken Rule Audit' {

        It 'Flags rule as broken when target folder points to an unmounted store' {
            $storePath = script:Get-NormalizedTestStorePath 'MountedStore.pst'
            $detachedFolder = [PSCustomObject]@{
                Name       = 'OldProjects'
                FolderPath = '\\OldDetachedStore\OldProjects'
            }
            $ruleWithDetachedStore = script:New-MockRule -Name 'Archive to OldStore' -MoveEnabled $true -MoveToFolder $detachedFolder

            $env = script:New-MockOutlookEnvironment -StorePath $storePath -StoreName 'MountedStore' -Rules @($ruleWithDetachedStore)
            Mock -CommandName 'Get-OutlookComApplication' -ModuleName 'Outlook' { return $env.ComApp }

            $res = Repair-OutlookRule -StorePath $storePath
            $res.BrokenRules.Count | Should -Be 1
            $res.BrokenRules[0].Issue | Should -Match "Target store 'OldDetachedStore' is unmounted or detached"
        }
    }
}

Describe 'Tier 5 Challenger: Select-ToolkitOutlookProfile Deep Boundary & Adversarial Strings' {

    Context '2.1 Environment Variable and Headless Safeguards' {

        It 'Bypasses prompt and returns default profile when ITOOLKIT_NONINTERACTIVE=1 is set' {
            $prevEnv = $env:ITOOLKIT_NONINTERACTIVE
            try {
                $env:ITOOLKIT_NONINTERACTIVE = '1'
                $res = Select-ToolkitOutlookProfile -Profiles @('ProfA', 'ProfB') -DefaultProfile 'ProfA'
                $res | Should -Be 'ProfA'
            } finally {
                $env:ITOOLKIT_NONINTERACTIVE = $prevEnv
            }
        }

        It 'Handles 50+ profiles without prompting in -NonInteractive mode' {
            $largeProfiles = 1..50 | ForEach-Object { "EnterpriseProfile_$_" }
            $res = Select-ToolkitOutlookProfile -Profiles $largeProfiles -DefaultProfile 'EnterpriseProfile_42' -NonInteractive
            $res | Should -Be 'EnterpriseProfile_42'
        }
    }

    Context '2.2 Boundary Numeric Inputs and Custom Option Edge Strings' {

        It 'Accepts numeric selection with leading and trailing spaces (e.g. " 1 ")' {
            Mock -CommandName 'Read-Host' { return '  1  ' }
            Mock -CommandName 'Read-Host' -ModuleName 'TUI' { return '  1  ' }
            $res = Select-ToolkitOutlookProfile -Profiles @('Alpha', 'Beta') -DefaultProfile 'Alpha'
            $res | Should -Be 'Alpha'
        }

        It 'Falls back to effective default when user enters boundary 0 or negative index' {
            Mock -CommandName 'Read-Host' { return '0' }
            Mock -CommandName 'Read-Host' -ModuleName 'TUI' { return '0' }
            $res = Select-ToolkitOutlookProfile -Profiles @('Alpha', 'Beta') -DefaultProfile 'Alpha'
            $res | Should -Be 'Alpha'

            Mock -CommandName 'Read-Host' { return '-1' }
            Mock -CommandName 'Read-Host' -ModuleName 'TUI' { return '-1' }
            $res = Select-ToolkitOutlookProfile -Profiles @('Alpha', 'Beta') -DefaultProfile 'Alpha'
            $res | Should -Be 'Alpha'
        }

        It 'Treats 64-bit integer overflow string gracefully without error' {
            Mock -CommandName 'Read-Host' { return '99999999999999999999999' }
            Mock -CommandName 'Read-Host' -ModuleName 'TUI' { return '99999999999999999999999' }
            $res = Select-ToolkitOutlookProfile -Profiles @('Alpha', 'Beta') -DefaultProfile 'Alpha'
            $res | Should -Be '99999999999999999999999'
        }

        It 'Handles custom option [N+1] where user submits whitespace-only string, falling back to default' {
            $script:step = 0
            $sb = {
                $script:step++
                if ($script:step -eq 1) { return '3' }
                return '     '
            }
            Mock -CommandName 'Read-Host' -MockWith $sb
            Mock -CommandName 'Read-Host' -ModuleName 'TUI' -MockWith $sb
            $res = Select-ToolkitOutlookProfile -Profiles @('Prof1', 'Prof2') -DefaultProfile 'Prof1'
            $res | Should -Be 'Prof1'
        }

        It 'Preserves special characters in custom profile name entered via [N+1]' {
            $script:step = 0
            $sb = {
                $script:step++
                if ($script:step -eq 1) { return '2' }
                return 'Sales & Marketing (EMEA)'
            }
            Mock -CommandName 'Read-Host' -MockWith $sb
            Mock -CommandName 'Read-Host' -ModuleName 'TUI' -MockWith $sb
            $res = Select-ToolkitOutlookProfile -Profiles @('DefaultProf') -DefaultProfile 'DefaultProf'
            $res | Should -Be 'Sales & Marketing (EMEA)'
        }
    }

    Context '2.3 Fallback When System Context Returns Null or "None"' {

        It 'Defaults to "Outlook" when Get-OutlookSystemContext returns None and no profiles supplied' {
            Mock -CommandName 'Get-OutlookSystemContext' {
                return [PSCustomObject]@{
                    Profiles       = @()
                    DefaultProfile = 'None'
                }
            }
            $res = Select-ToolkitOutlookProfile -NonInteractive
            $res | Should -Be 'Outlook'
        }
    }
}

Describe 'Tier 5 Challenger: TUI Menu Action & Context Menu Advanced Routing Hardening' {

    Context '3.1 Main Menu Option 19 (Import Rules) Error and Cancellation Paths' {

        It 'Aborts cleanly with warning when manifest path is empty' {
            $script:lastStatusMsg = $null
            $script:lastStatusType = $null
            $statusSb = {
                param($Message, $Type)
                $script:lastStatusMsg = $Message
                $script:lastStatusType = $Type
            }
            $script:step = 0
            $sbSelection = {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '19' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            Mock -CommandName 'Read-ToolkitItemSelection' -MockWith $sbSelection
            Mock -CommandName 'Read-ToolkitItemSelection' -ModuleName 'TUI' -MockWith $sbSelection
            Mock -CommandName 'Select-ToolkitOutlookProfile' { return 'TestProfile' }
            Mock -CommandName 'Select-ToolkitOutlookProfile' -ModuleName 'TUI' { return 'TestProfile' }
            Mock -CommandName 'Read-Host' { return '' }
            Mock -CommandName 'Read-Host' -ModuleName 'TUI' { return '' }
            Mock -CommandName 'Wait-UserAcknowledge' {}
            Mock -CommandName 'Wait-UserAcknowledge' -ModuleName 'TUI' {}
            Mock -CommandName 'Write-ToolkitStatus' -MockWith $statusSb
            Mock -CommandName 'Write-ToolkitStatus' -ModuleName 'TUI' -MockWith $statusSb

            { Invoke-ToolkitSubmenuOfficeOutlook -MenuDepth 1 } | Should -Not -Throw
            $script:lastStatusMsg | Should -Match 'No rule manifest JSON path provided'
            $script:lastStatusType | Should -Be 'WARN'
        }

        It 'Aborts cleanly with error when manifest path points to non-existent file' {
            $script:lastStatusMsg = $null
            $script:lastStatusType = $null
            $statusSb = {
                param($Message, $Type)
                $script:lastStatusMsg = $Message
                $script:lastStatusType = $Type
            }
            $script:step = 0
            $sbSelection = {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '19' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            Mock -CommandName 'Read-ToolkitItemSelection' -MockWith $sbSelection
            Mock -CommandName 'Read-ToolkitItemSelection' -ModuleName 'TUI' -MockWith $sbSelection
            Mock -CommandName 'Select-ToolkitOutlookProfile' { return 'TestProfile' }
            Mock -CommandName 'Select-ToolkitOutlookProfile' -ModuleName 'TUI' { return 'TestProfile' }
            Mock -CommandName 'Read-Host' { return 'C:\Data\MissingManifest.json' }
            Mock -CommandName 'Read-Host' -ModuleName 'TUI' { return 'C:\Data\MissingManifest.json' }
            Mock -CommandName 'Wait-UserAcknowledge' {}
            Mock -CommandName 'Wait-UserAcknowledge' -ModuleName 'TUI' {}
            Mock -CommandName 'Write-ToolkitStatus' -MockWith $statusSb
            Mock -CommandName 'Write-ToolkitStatus' -ModuleName 'TUI' -MockWith $statusSb

            { Invoke-ToolkitSubmenuOfficeOutlook -MenuDepth 1 } | Should -Not -Throw
            $script:lastStatusMsg | Should -Match 'Rule manifest file not found'
            $script:lastStatusType | Should -Be 'FAIL'
        }

        It 'Cancels safely when user rejects confirmation prompt on Option 19' {
            $script:lastStatusMsg = $null
            $script:lastStatusType = $null
            $statusSb = {
                param($Message, $Type)
                $script:lastStatusMsg = $Message
                $script:lastStatusType = $Type
            }
            $manifestFile = Join-Path ([System.IO.Path]::GetTempPath()) 'DummyManifest.json'
            "{}" | Out-File -LiteralPath $manifestFile -Encoding ascii
            try {
                $script:step = 0
                $sbSelection = {
                    $script:step++
                    if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '19' } }
                    return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
                }
                Mock -CommandName 'Read-ToolkitItemSelection' -MockWith $sbSelection
                Mock -CommandName 'Read-ToolkitItemSelection' -ModuleName 'TUI' -MockWith $sbSelection
                Mock -CommandName 'Select-ToolkitOutlookProfile' { return 'TestProfile' }
                Mock -CommandName 'Select-ToolkitOutlookProfile' -ModuleName 'TUI' { return 'TestProfile' }
                Mock -CommandName 'Read-Host' { return $manifestFile }
                Mock -CommandName 'Read-Host' -ModuleName 'TUI' { return $manifestFile }
                Mock -CommandName 'Confirm-ToolkitAction' { return $false }
                Mock -CommandName 'Confirm-ToolkitAction' -ModuleName 'TUI' { return $false }
                Mock -CommandName 'Wait-UserAcknowledge' {}
                Mock -CommandName 'Wait-UserAcknowledge' -ModuleName 'TUI' {}
                Mock -CommandName 'Write-ToolkitStatus' -MockWith $statusSb
                Mock -CommandName 'Write-ToolkitStatus' -ModuleName 'TUI' -MockWith $statusSb

                { Invoke-ToolkitSubmenuOfficeOutlook -MenuDepth 1 } | Should -Not -Throw
                $script:lastStatusMsg | Should -Match 'Import Outlook rules cancelled by user'
                $script:lastStatusType | Should -Be 'INFO'
            } finally {
                Remove-Item -LiteralPath $manifestFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context '3.2 Main Menu Option 20 (Diagnostics & Auto-Repair) Interaction Branches' {

        It 'Invokes Repair-OutlookRule with -AutoRepair:$true when user enters "y"' {
            $script:lastStatusMsg = $null
            $script:lastStatusType = $null
            $statusSb = {
                param($Message, $Type)
                $script:lastStatusMsg = $Message
                $script:lastStatusType = $Type
            }
            $script:autoRepairFlag = $null
            $script:step = 0
            $sbSelection = {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '20' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            Mock -CommandName 'Read-ToolkitItemSelection' -MockWith $sbSelection
            Mock -CommandName 'Read-ToolkitItemSelection' -ModuleName 'TUI' -MockWith $sbSelection
            Mock -CommandName 'Select-ToolkitOutlookProfile' { return 'TestProfile' }
            Mock -CommandName 'Select-ToolkitOutlookProfile' -ModuleName 'TUI' { return 'TestProfile' }
            Mock -CommandName 'Read-Host' { return 'y' }
            Mock -CommandName 'Read-Host' -ModuleName 'TUI' { return 'y' }
            Mock -CommandName 'Confirm-ToolkitAction' { return $true }
            Mock -CommandName 'Confirm-ToolkitAction' -ModuleName 'TUI' { return $true }
            $repairSb = {
                param($ProfileName, [switch]$AutoRepair)
                $script:autoRepairFlag = [bool]$AutoRepair
                return [PSCustomObject]@{
                    Success                = $true
                    TotalRules             = 5
                    RepairedRulesCount     = 2
                    RemovedDuplicatesCount = 1
                    RemovedEmptyCount      = 1
                }
            }
            Mock -CommandName 'Repair-OutlookRule' -MockWith $repairSb
            Mock -CommandName 'Repair-OutlookRule' -ModuleName 'TUI' -MockWith $repairSb
            Mock -CommandName 'Wait-UserAcknowledge' {}
            Mock -CommandName 'Wait-UserAcknowledge' -ModuleName 'TUI' {}
            Mock -CommandName 'Write-ToolkitStatus' -MockWith $statusSb
            Mock -CommandName 'Write-ToolkitStatus' -ModuleName 'TUI' -MockWith $statusSb

            { Invoke-ToolkitSubmenuOfficeOutlook -MenuDepth 1 } | Should -Not -Throw
            $script:autoRepairFlag | Should -BeTrue
            $script:lastStatusMsg | Should -Match 'Diagnostics & Repair Complete'
            $script:lastStatusType | Should -Be 'OK'
        }

        It 'Invokes Repair-OutlookRule with -AutoRepair:$false when user enters "n"' {
            $script:lastStatusMsg = $null
            $script:lastStatusType = $null
            $statusSb = {
                param($Message, $Type)
                $script:lastStatusMsg = $Message
                $script:lastStatusType = $Type
            }
            $script:autoRepairFlag = $null
            $script:step = 0
            $sbSelection = {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '20' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            Mock -CommandName 'Read-ToolkitItemSelection' -MockWith $sbSelection
            Mock -CommandName 'Read-ToolkitItemSelection' -ModuleName 'TUI' -MockWith $sbSelection
            Mock -CommandName 'Select-ToolkitOutlookProfile' { return 'TestProfile' }
            Mock -CommandName 'Select-ToolkitOutlookProfile' -ModuleName 'TUI' { return 'TestProfile' }
            Mock -CommandName 'Read-Host' { return 'n' }
            Mock -CommandName 'Read-Host' -ModuleName 'TUI' { return 'n' }
            Mock -CommandName 'Confirm-ToolkitAction' { return $true }
            Mock -CommandName 'Confirm-ToolkitAction' -ModuleName 'TUI' { return $true }
            $repairSb = {
                param($ProfileName, [switch]$AutoRepair)
                $script:autoRepairFlag = [bool]$AutoRepair
                return [PSCustomObject]@{
                    Success        = $true
                    TotalRules     = 5
                    BrokenRules    = @('RuleB')
                    DuplicateRules = @()
                    EmptyRules     = @()
                    DisabledRules  = @()
                }
            }
            Mock -CommandName 'Repair-OutlookRule' -MockWith $repairSb
            Mock -CommandName 'Repair-OutlookRule' -ModuleName 'TUI' -MockWith $repairSb
            Mock -CommandName 'Wait-UserAcknowledge' {}
            Mock -CommandName 'Wait-UserAcknowledge' -ModuleName 'TUI' {}
            Mock -CommandName 'Write-ToolkitStatus' -MockWith $statusSb
            Mock -CommandName 'Write-ToolkitStatus' -ModuleName 'TUI' -MockWith $statusSb

            { Invoke-ToolkitSubmenuOfficeOutlook -MenuDepth 1 } | Should -Not -Throw
            $script:autoRepairFlag | Should -BeFalse
            $script:lastStatusMsg | Should -Match 'Diagnostics Scan Complete'
            $script:lastStatusType | Should -Be 'WARN'
        }
    }

    Context '3.3 Context Menu Option 9 (Store Import) Edge Paths' {

        It 'Cancels and continues menu loop when manifest file does not exist' {
            $script:lastStatusMsg = $null
            $script:lastStatusType = $null
            $statusSb = {
                param($Message, $Type)
                $script:lastStatusMsg = $Message
                $script:lastStatusType = $Type
            }
            $dummyDataFile = [PSCustomObject]@{
                Filename = 'Finance.pst'
                Path     = 'C:\Data\Finance.pst'
                Type     = 'PST'
                Profile  = 'FinanceProfile'
            }
            $script:step = 0
            $sbSelection = {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '9' } }
                return [PSCustomObject]@{ Type = 'Hotkey'; Value = '0' }
            }
            Mock -CommandName 'Read-ToolkitItemSelection' -MockWith $sbSelection
            Mock -CommandName 'Read-ToolkitItemSelection' -ModuleName 'TUI' -MockWith $sbSelection
            Mock -CommandName 'Read-Host' { return 'C:\NonExistent\Rules.json' }
            Mock -CommandName 'Read-Host' -ModuleName 'TUI' { return 'C:\NonExistent\Rules.json' }
            Mock -CommandName 'Wait-UserAcknowledge' {}
            Mock -CommandName 'Wait-UserAcknowledge' -ModuleName 'TUI' {}
            Mock -CommandName 'Write-ToolkitStatus' -MockWith $statusSb
            Mock -CommandName 'Write-ToolkitStatus' -ModuleName 'TUI' -MockWith $statusSb

            { Invoke-ToolkitDataFileContextMenu -DataFile $dummyDataFile } | Should -Not -Throw
            $script:lastStatusMsg | Should -Match 'Manifest file does not exist'
            $script:lastStatusType | Should -Be 'FAIL'
        }
    }

    Context '3.4 Context Menu Option 10 (Store Diagnostics) Edge Paths' {

        It 'Dispatches store diagnostics with AutoRepair and logs formatted summary' {
            $script:lastStatusMsg = $null
            $script:lastStatusType = $null
            $statusSb = {
                param($Message, $Type)
                $script:lastStatusMsg = $Message
                $script:lastStatusType = $Type
            }
            $dummyDataFile = [PSCustomObject]@{
                Filename = 'Finance.pst'
                Path     = 'C:\Data\Finance.pst'
                Type     = 'PST'
                Profile  = 'FinanceProfile'
            }
            $script:step = 0
            $sbSelection = {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' } }
                return [PSCustomObject]@{ Type = 'Hotkey'; Value = '0' }
            }
            Mock -CommandName 'Read-ToolkitItemSelection' -MockWith $sbSelection
            Mock -CommandName 'Read-ToolkitItemSelection' -ModuleName 'TUI' -MockWith $sbSelection
            Mock -CommandName 'Read-Host' { return 'y' }
            Mock -CommandName 'Read-Host' -ModuleName 'TUI' { return 'y' }
            Mock -CommandName 'Confirm-ToolkitAction' { return $true }
            Mock -CommandName 'Confirm-ToolkitAction' -ModuleName 'TUI' { return $true }
            $diagSb = {
                return [PSCustomObject]@{
                    Success            = $true
                    TotalRules         = 8
                    BrokenRules        = @()
                    DuplicateRules     = @()
                    EmptyRules         = @()
                    RepairedRulesCount = 2
                }
            }
            Mock -CommandName 'Repair-OutlookRule' -MockWith $diagSb
            Mock -CommandName 'Repair-OutlookRule' -ModuleName 'TUI' -MockWith $diagSb
            Mock -CommandName 'Wait-UserAcknowledge' {}
            Mock -CommandName 'Wait-UserAcknowledge' -ModuleName 'TUI' {}
            Mock -CommandName 'Write-ToolkitStatus' -MockWith $statusSb
            Mock -CommandName 'Write-ToolkitStatus' -ModuleName 'TUI' -MockWith $statusSb

            { Invoke-ToolkitDataFileContextMenu -DataFile $dummyDataFile } | Should -Not -Throw
            $script:lastStatusMsg | Should -Match 'Repaired: 2'
            $script:lastStatusType | Should -Be 'OK'
        }
    }
}

Describe 'Tier 5 Challenger: Root and Submodule Manifest Parity and Export Integrity' {

    Context '4.1 Root IToolkit Manifest Exports' {

        It 'Exports Repair-OutlookRule function from root IToolkit.psd1' {
            $manifest = Import-PowerShellDataFile -Path $script:IToolkitManifest
            $manifest.FunctionsToExport | Should -Contain 'Repair-OutlookRule'
        }

        It 'Exports Select-ToolkitOutlookProfile function from root IToolkit.psd1' {
            $manifest = Import-PowerShellDataFile -Path $script:IToolkitManifest
            $manifest.FunctionsToExport | Should -Contain 'Select-ToolkitOutlookProfile'
        }

        It 'Exports Test-OutlookRule alias from root IToolkit.psd1' {
            $manifest = Import-PowerShellDataFile -Path $script:IToolkitManifest
            $manifest.AliasesToExport | Should -Contain 'Test-OutlookRule'
        }

        It 'Exports Invoke-ToolkitSubmenuOfficeOutlook from root IToolkit.psd1' {
            $manifest = Import-PowerShellDataFile -Path $script:IToolkitManifest
            $manifest.FunctionsToExport | Should -Contain 'Invoke-ToolkitSubmenuOfficeOutlook'
        }
    }

    Context '4.2 Submodule Outlook.psd1 & TUI.psd1 Exports' {

        It 'Exports Repair-OutlookRule and Test-OutlookRule alias from Modules/Outlook/Outlook.psd1' {
            $manifest = Import-PowerShellDataFile -Path $script:OutlookManifest
            $manifest.FunctionsToExport | Should -Contain 'Repair-OutlookRule'
            $manifest.AliasesToExport | Should -Contain 'Test-OutlookRule'
        }

        It 'Exports Select-ToolkitOutlookProfile from Modules/TUI/TUI.psd1' {
            $manifest = Import-PowerShellDataFile -Path $script:TUIManifest
            $manifest.FunctionsToExport | Should -Contain 'Select-ToolkitOutlookProfile'
        }

        It 'Exports Invoke-ToolkitSubmenuOfficeOutlook from Modules/TUI/TUI.psd1' {
            $manifest = Import-PowerShellDataFile -Path $script:TUIManifest
            $manifest.FunctionsToExport | Should -Contain 'Invoke-ToolkitSubmenuOfficeOutlook'
        }
    }

    Context '4.3 Runtime Command and Alias Resolution' {

        It 'Resolves Test-OutlookRule alias to Repair-OutlookRule command' {
            $alias = Get-Alias -Name 'Test-OutlookRule' -ErrorAction SilentlyContinue
            $alias | Should -Not -BeNullOrEmpty
            $alias.Definition | Should -Be 'Repair-OutlookRule'
        }

        It 'Resolves Select-ToolkitOutlookProfile as an accessible function' {
            $cmd = Get-Command -Name 'Select-ToolkitOutlookProfile' -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.CommandType | Should -Be 'Function'
        }

        It 'Resolves Invoke-ToolkitDataFileContextMenu in global session scope' {
            $cmd = Get-Command -Name 'Invoke-ToolkitDataFileContextMenu' -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.CommandType | Should -Be 'Function'
        }
    }
}
