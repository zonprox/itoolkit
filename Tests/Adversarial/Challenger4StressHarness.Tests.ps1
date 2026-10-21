# Tests/Adversarial/Challenger4StressHarness.Tests.ps1
# Milestone 4 Challenger 4 Empirical Stress Test Suite
# Scope: Context Menu Actions 8, 9, 10, Alias Re-exporting, and Session State Isolation

$script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:TUIManifest = Join-Path $script:ProjectRoot 'Modules/TUI/TUI.psd1'
$isTUIAvailable = Test-Path $script:TUIManifest

BeforeAll {
    $script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $repoRoot = $script:ProjectRoot
    $script:itoolkitPsd1 = Join-Path $repoRoot 'IToolkit.psd1'
    $script:outlookPsd1 = Join-Path $repoRoot 'Modules/Outlook/Outlook.psd1'
    $script:tuiScript = Join-Path $repoRoot 'Modules/TUI/Public/Invoke-ToolkitSubmenuOfficeOutlook.ps1'

    # Clean session
    Remove-Item -Path Alias:Test-OutlookRule, Alias:Invoke-OutlookPstCompaction -Force -ErrorAction SilentlyContinue
    Remove-Module IToolkit, Outlook, TUI -ErrorAction SilentlyContinue

    # Load root module
    Import-Module $script:itoolkitPsd1 -Force
    if (Test-Path -LiteralPath $script:tuiScript) {
        . $script:tuiScript
    }
}

Describe 'Milestone 4 Challenger 4: Empirical Stress Test Suite' {

    # =========================================================================
    # Context 1: Alias Re-exporting and Resolution Verification
    # =========================================================================
    Context '1. Alias Re-exporting & Command Resolution' {

        It 'Root IToolkit module exports Test-OutlookRule alias to Repair-OutlookRule' {
            $alias = Get-Alias -Name 'Test-OutlookRule' -ErrorAction SilentlyContinue
            $alias | Should -Not -BeNullOrEmpty
            $alias.Definition | Should -Be 'Repair-OutlookRule'
            $alias.Source | Should -Be 'IToolkit'
        }

        It 'Outlook module directly exports Test-OutlookRule alias to Repair-OutlookRule' {
            & {
                Remove-Module IToolkit, Outlook, TUI -ErrorAction SilentlyContinue
                Import-Module $script:outlookPsd1 -Force
                try {
                    $mod = Get-Module -Name 'Outlook'
                    $mod.ExportedAliases.ContainsKey('Test-OutlookRule') | Should -BeTrue
                    $mod.ExportedAliases['Test-OutlookRule'].Definition | Should -Be 'Repair-OutlookRule'
                } finally {
                    Remove-Module Outlook -ErrorAction SilentlyContinue
                    Import-Module $script:itoolkitPsd1 -Force
                    . $script:tuiScript
                }
            }
        }

        It 'Test-OutlookRule alias executes seamlessly with -WhatIf and parameter binding' {
            $res = Test-OutlookRule -StorePath 'C:\Test\Store.pst' -ProfileName 'ChallengerProfile' -WhatIf
            $res | Should -Not -BeNullOrEmpty
            $res.Success | Should -BeTrue
            $res.ProfileName | Should -Be 'ChallengerProfile'
        }

        It 'Test-OutlookRule alias binds pipeline parameters by property name' {
            $inputObj = [PSCustomObject]@{
                StorePath   = 'C:\Pipeline\Test.pst'
                ProfileName = 'PipelineProf'
            }
            $res = $inputObj | Test-OutlookRule -WhatIf
            $res | Should -Not -BeNullOrEmpty
            $res.Success | Should -BeTrue
            $res.ProfileName | Should -Be 'PipelineProf'
        }
    }

    # =========================================================================
    # Context 2: Session State Isolation & Root Module Import Parity
    # =========================================================================
    Context '2. Session State Isolation & Module Root Import' {

        It 'Private Outlook functions are strictly hidden and not exported' {
            $privateFns = @('Get-OutlookComApplication', 'Ensure-FolderObject', 'Find-ComObjectReference', 'Get-OutlookDefaultDeliveryStorePath')
            foreach ($fn in $privateFns) {
                $cmd = Get-Command -Name $fn -CommandType Function -ErrorAction SilentlyContinue
                if ($null -ne $cmd) {
                    $cmd.ModuleName | Should -Not -Be 'IToolkit'
                }
            }
        }

        It 'Production code contains zero test mock synchronization hacks (callerStep / Scope 1)' {
            $profileSelector = Join-Path $script:ProjectRoot 'Modules/TUI/Public/Select-ToolkitOutlookProfile.ps1'
            $matches = Get-Content $profileSelector | Select-String 'callerStep|Scope 1'
            $matches | Should -BeNullOrEmpty
        }

        It 'Select-ToolkitOutlookProfile is properly exported by IToolkit root module' {
            $itoolkitModule = Get-Module -Name 'IToolkit'
            $itoolkitModule | Should -Not -BeNullOrEmpty
            $itoolkitModule.ExportedFunctions.ContainsKey('Select-ToolkitOutlookProfile') | Should -BeTrue
        }

        It 'Select-ToolkitOutlookProfile command source resolves to IToolkit upon root import' {
            $cmd = Get-Command -Name 'Select-ToolkitOutlookProfile' -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.Source | Should -Be 'IToolkit'
        }
    }

    # =========================================================================
    # Context 3: Context Action 8 - Export Rules for Store
    # =========================================================================
    Context '3. Context Action 8 (Export Rules for Store)' {

        BeforeEach {
            $script:dataFile = [PSCustomObject]@{
                Filename = 'Finance [Q4].pst'
                Path     = 'D:\Corp Data\Finance [Q4].pst'
                Profile  = 'Finance Department'
                Item     = 'Finance [Q4].pst'
            }
        }

        It 'Binds StorePath and ProfileName correctly with spaces and brackets' -Skip:(-not $isTUIAvailable) {
            $script:captured = @{}
            Mock Confirm-ToolkitAction { return $true }
            Mock Read-Host { return '' }
            Mock Export-OutlookRule {
                param($Path, $ProfileName, $StorePath, [switch]$Force)
                $script:captured['Path'] = $Path
                $script:captured['ProfileName'] = $ProfileName
                $script:captured['StorePath'] = $StorePath
                $script:captured['Force'] = $Force.IsPresent
                return [PSCustomObject]@{ Success = $true; RulesExported = 4 }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '8' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:dataFile } | Should -Not -Throw
            $script:captured['StorePath'] | Should -Be 'D:\Corp Data\Finance [Q4].pst'
            $script:captured['ProfileName'] | Should -Be 'Finance Department'
            $script:captured['Force'] | Should -BeTrue
            $script:captured['Path'] | Should -Match 'Finance \[Q4\]_Rules_\d{8}_\d{6}\.json$'
        }

        It 'Appends .json extension if user omits it' -Skip:(-not $isTUIAvailable) {
            $script:targetPath = $null
            Mock Confirm-ToolkitAction { return $true }
            Mock Read-Host { return 'MyCustomExport' }
            Mock Export-OutlookRule {
                param($Path, $ProfileName, $StorePath, [switch]$Force)
                $script:targetPath = $Path
                return [PSCustomObject]@{ Success = $true; RulesExported = 2 }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '8' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:dataFile } | Should -Not -Throw
            $script:targetPath | Should -Match 'MyCustomExport\.json$'
        }

        It 'Handles export failure gracefully without crashing menu loop' -Skip:(-not $isTUIAvailable) {
            Mock Confirm-ToolkitAction { return $true }
            Mock Read-Host { return '' }
            Mock Export-OutlookRule {
                return [PSCustomObject]@{ Success = $false; ErrorMessage = 'Disk quota exceeded' }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '8' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:dataFile } | Should -Not -Throw
        }

        It 'Traps exceptions thrown by Export-OutlookRule' -Skip:(-not $isTUIAvailable) {
            Mock Confirm-ToolkitAction { return $true }
            Mock Read-Host { return '' }
            Mock Export-OutlookRule { throw 'Simulated COM catastrophic failure' }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '8' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:dataFile } | Should -Not -Throw
        }
    }

    # =========================================================================
    # Context 4: Context Action 9 - Import & Auto-Remap Rules into Store
    # =========================================================================
    Context '4. Context Action 9 (Import & Auto-Remap Rules into Store)' {

        BeforeAll {
            $script:validManifest = [System.IO.Path]::GetTempFileName()
            Set-Content -Path $script:validManifest -Value '{"SchemaVersion":"1.0.0","Rules":[]}' -Encoding UTF8
        }

        AfterAll {
            if (Test-Path -LiteralPath $script:validManifest) {
                Remove-Item -LiteralPath $script:validManifest -Force -ErrorAction SilentlyContinue
            }
        }

        BeforeEach {
            $script:dataFile = [PSCustomObject]@{
                Filename = 'Project.ost'
                Path     = 'C:\Mailboxes\Project.ost'
                Profile  = 'ProjectProfile'
                Item     = 'Project.ost'
            }
        }

        It 'Strips surrounding quotes and binds TargetStorePath and ProfileName' -Skip:(-not $isTUIAvailable) {
            $script:captured = @{}
            Mock Read-Host {
                param($Prompt)
                if ($Prompt -match 'Path to Rule Manifest') { return "`"$($script:validManifest)`"" }
                return ''
            }
            Mock Confirm-ToolkitAction { return $true }
            Mock Import-OutlookRule {
                param($Path, $TargetStorePath, $ProfileName, [switch]$AutoCreateFolders, [string]$DuplicateHandling)
                $script:captured['Path'] = $Path
                $script:captured['TargetStorePath'] = $TargetStorePath
                $script:captured['ProfileName'] = $ProfileName
                $script:captured['AutoCreateFolders'] = $AutoCreateFolders.IsPresent
                $script:captured['DuplicateHandling'] = $DuplicateHandling
                return [PSCustomObject]@{ Success = $true; RulesImported = 3; RulesSkipped = 1; FoldersCreated = 2 }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '9' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:dataFile } | Should -Not -Throw
            $script:captured['Path'] | Should -Be $script:validManifest
            $script:captured['TargetStorePath'] | Should -Be 'C:\Mailboxes\Project.ost'
            $script:captured['ProfileName'] | Should -Be 'ProjectProfile'
            $script:captured['AutoCreateFolders'] | Should -BeTrue
            $script:captured['DuplicateHandling'] | Should -Be 'Skip'
        }

        It 'Aborts safely when manifest path does not exist' -Skip:(-not $isTUIAvailable) {
            $script:importCalled = $false
            Mock Read-Host { return 'C:\NonExistent\Rules.json' }
            Mock Import-OutlookRule { $script:importCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '9' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:dataFile } | Should -Not -Throw
            $script:importCalled | Should -BeFalse
        }

        It 'Traps exceptions from Import-OutlookRule without crashing' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return $script:validManifest }
            Mock Confirm-ToolkitAction { return $true }
            Mock Import-OutlookRule { throw 'Fatal store corruption during import' }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '9' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:dataFile } | Should -Not -Throw
        }
    }

    # =========================================================================
    # Context 5: Context Action 10 - Diagnostics, Counts & Auto-Repair
    # =========================================================================
    Context '5. Context Action 10 (Diagnostics & Rule Count Representation)' {

        BeforeEach {
            $script:dataFile = [PSCustomObject]@{
                Filename = 'Archive_Store.pst'
                Path     = 'E:\Archives\Archive_Store.pst'
                Profile  = 'ArchiveProfile'
                Item     = 'Archive_Store.pst'
            }
        }

        It 'Accurately computes counts when BrokenRules, DuplicateRules, EmptyRules are arrays of objects' -Skip:(-not $isTUIAvailable) {
            $script:statusMessage = $null
            Mock Read-Host { return 'yes' } # AutoRepair = true
            Mock Confirm-ToolkitAction { return $true }
            Mock Repair-OutlookRule {
                param($StorePath, $ProfileName, [switch]$AutoRepair)
                return [PSCustomObject]@{
                    Success            = $true
                    TotalRules         = 8
                    BrokenRules        = @(
                        [PSCustomObject]@{ Name = 'Broken1'; Issue = 'Null folder' },
                        [PSCustomObject]@{ Name = 'Broken2'; Issue = 'Missing folder' }
                    )
                    DuplicateRules     = @(
                        [PSCustomObject]@{ Name = 'Dup1'; Signature = 'SigA' }
                    )
                    EmptyRules         = @(
                        [PSCustomObject]@{ Name = 'Empty1'; Issue = 'Zero actions' }
                    )
                    RepairedRulesCount = 2
                }
            }
            Mock Write-ToolkitStatus {
                param($Message, $Type)
                if ($Message -match 'Store rules scanned:') {
                    $script:statusMessage = $Message
                }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:dataFile } | Should -Not -Throw
            $script:statusMessage | Should -Not -BeNullOrEmpty
            $script:statusMessage | Should -Be 'Store rules scanned: 8 | Broken: 2 | Duplicates: 1 | Empty: 1 | Repaired: 2'
            $script:statusMessage | Should -Not -Match 'System\.Management\.Automation\.PSCustomObject'
        }

        It 'Accurately displays 0 counts when rule arrays are empty @()' -Skip:(-not $isTUIAvailable) {
            $script:statusMessage = $null
            Mock Read-Host { return 'no' } # AutoRepair = false
            Mock Confirm-ToolkitAction { return $true }
            Mock Repair-OutlookRule {
                param($StorePath, $ProfileName, [switch]$AutoRepair)
                return [PSCustomObject]@{
                    Success            = $true
                    TotalRules         = 5
                    BrokenRules        = @()
                    DuplicateRules     = @()
                    EmptyRules         = @()
                    RepairedRulesCount = 0
                }
            }
            Mock Write-ToolkitStatus {
                param($Message, $Type)
                if ($Message -match 'Store rules scanned:') {
                    $script:statusMessage = $Message
                }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:dataFile } | Should -Not -Throw
            $script:statusMessage | Should -Not -BeNullOrEmpty
            $script:statusMessage | Should -Be 'Store rules scanned: 5 | Broken: 0 | Duplicates: 0 | Empty: 0'
        }

        It 'Accurately displays counts when rule properties are direct integers' -Skip:(-not $isTUIAvailable) {
            $script:statusMessage = $null
            Mock Read-Host { return 'no' }
            Mock Confirm-ToolkitAction { return $true }
            Mock Repair-OutlookRule {
                param($StorePath, $ProfileName, [switch]$AutoRepair)
                return [PSCustomObject]@{
                    Success            = $true
                    TotalRules         = 10
                    BrokenRules        = 3
                    DuplicateRules     = 2
                    EmptyRules         = 1
                    RepairedRulesCount = 0
                }
            }
            Mock Write-ToolkitStatus {
                param($Message, $Type)
                if ($Message -match 'Store rules scanned:') {
                    $script:statusMessage = $Message
                }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:dataFile } | Should -Not -Throw
            $script:statusMessage | Should -Not -BeNullOrEmpty
            $script:statusMessage | Should -Be 'Store rules scanned: 10 | Broken: 3 | Duplicates: 2 | Empty: 1'
        }

        It 'Traps exceptions from Repair-OutlookRule gracefully' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return 'no' }
            Mock Confirm-ToolkitAction { return $true }
            Mock Repair-OutlookRule { throw 'MAPI memory leak error' }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:dataFile } | Should -Not -Throw
        }
    }
}
