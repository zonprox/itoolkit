# Tests/Adversarial/ChallengerContextMenuRoutingAndSessionStress.Tests.ps1
# Milestone 4 Challenger 2 Empirical Stress Test Suite
# Target Scope: Context Menu Actions 8, 9, 10, Alias Re-exporting, and Session State Isolation

$script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:TUIManifest = Join-Path $script:ProjectRoot 'Modules/TUI/TUI.psd1'
$isTUIAvailable = Test-Path $script:TUIManifest

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $itoolkitPsd1 = Join-Path $repoRoot 'IToolkit.psd1'
    $outlookPsd1 = Join-Path $repoRoot 'Modules/Outlook/Outlook.psd1'
    $tuiPsd1 = Join-Path $repoRoot 'Modules/TUI/TUI.psd1'
    $tuiScript = Join-Path $repoRoot 'Modules/TUI/Public/Invoke-ToolkitSubmenuOfficeOutlook.ps1'

    # Ensure clean initial state
    Remove-Item -Path Alias:Test-OutlookRule, Alias:Invoke-OutlookPstCompaction -Force -ErrorAction SilentlyContinue
    Remove-Module IToolkit, Outlook, TUI -ErrorAction SilentlyContinue

    # Load root module
    Import-Module $itoolkitPsd1 -Force
    if (Test-Path -LiteralPath $tuiScript) {
        . $tuiScript
    }
}

Describe 'Milestone 4 Challenger 2: Context Menu Actions 8, 9, 10, Alias Re-exporting & Session Isolation' {

    # =========================================================================
    # Context 1: Alias Re-exporting and Resolution Verification
    # =========================================================================
    Context '1. Alias Re-exporting and Command Resolution' {

        It 'IToolkit root module exports Test-OutlookRule alias mapped to Repair-OutlookRule' {
            $alias = Get-Alias -Name 'Test-OutlookRule' -ErrorAction SilentlyContinue
            $alias | Should -Not -BeNullOrEmpty
            $alias.Definition | Should -Be 'Repair-OutlookRule'
            $alias.Source | Should -Be 'IToolkit'
        }

        It 'IToolkit root module exports Invoke-OutlookPstCompaction alias mapped to Invoke-OutlookCompaction' {
            $alias = Get-Alias -Name 'Invoke-OutlookPstCompaction' -ErrorAction SilentlyContinue
            $alias | Should -Not -BeNullOrEmpty
            $alias.Definition | Should -Be 'Invoke-OutlookCompaction'
            $alias.Source | Should -Be 'IToolkit'
        }

        It 'Modules/Outlook exports Test-OutlookRule alias directly' {
            Remove-Item -Path Alias:Test-OutlookRule, Alias:Invoke-OutlookPstCompaction -Force -ErrorAction SilentlyContinue
            Remove-Module IToolkit, Outlook, TUI -ErrorAction SilentlyContinue
            Import-Module $outlookPsd1 -Force
            try {
                $mod = Get-Module -Name 'Outlook'
                $mod.ExportedAliases.ContainsKey('Test-OutlookRule') | Should -BeTrue
                $aliasCmd = $mod.ExportedAliases['Test-OutlookRule']
                $aliasCmd | Should -Not -BeNullOrEmpty
                $aliasCmd.Definition | Should -Be 'Repair-OutlookRule'
                $aliasCmd.ModuleName | Should -Be 'Outlook'
            } finally {
                Remove-Item -Path Alias:Test-OutlookRule, Alias:Invoke-OutlookPstCompaction -Force -ErrorAction SilentlyContinue
                Remove-Module Outlook -ErrorAction SilentlyContinue
                Import-Module $itoolkitPsd1 -Force
                . $tuiScript
            }
        }

        It 'Test-OutlookRule alias executes seamlessly with parameter binding and -WhatIf' {
            $res = Test-OutlookRule -StorePath 'C:\Test\Sample.pst' -ProfileName 'TestProfileX' -WhatIf
            $res | Should -Not -BeNullOrEmpty
            $res.Success | Should -BeTrue
            $res.Method | Should -Be 'WhatIf'
            $res.ProfileName | Should -Be 'TestProfileX'
        }

        It 'Test-OutlookRule alias supports pipeline input by property name' {
            $pipelineObj = [PSCustomObject]@{
                StorePath   = 'C:\Pipeline\Test.pst'
                ProfileName = 'PipelineProfile'
            }
            $res = $pipelineObj | Test-OutlookRule -WhatIf
            $res | Should -Not -BeNullOrEmpty
            $res.Success | Should -BeTrue
            $res.ProfileName | Should -Be 'PipelineProfile'
        }

        It 'Test-OutlookRule accepts all Repair-OutlookRule parameter switches' {
            $aliasCmd = Get-Command -Name 'Test-OutlookRule'
            $targetCmd = Get-Command -Name 'Repair-OutlookRule'
            $targetParams = $targetCmd.Parameters.Keys
            foreach ($p in @('StorePath', 'ProfileName', 'StoreName', 'AutoRepair', 'RemoveDuplicates', 'RemoveEmpty', 'DefaultFallbackFolder')) {
                $targetParams -contains $p | Should -BeTrue
            }
        }
    }

    # =========================================================================
    # Context 2: Session State Isolation & Private Helper Encapsulation
    # =========================================================================
    Context '2. Session State Isolation & Private Helper Encapsulation' {

        It 'Private Outlook functions are strictly hidden and not exported to session' {
            $privateFunctions = @(
                'Get-OutlookComApplication',
                'Ensure-FolderObject',
                'Find-ComObjectReference',
                'Get-OutlookDefaultDeliveryStorePath'
            )
            foreach ($fn in $privateFunctions) {
                $cmd = Get-Command -Name $fn -CommandType Function -ErrorAction SilentlyContinue
                # Either not found or not exported from IToolkit
                if ($null -ne $cmd) {
                    $cmd.ModuleName | Should -Not -Be 'IToolkit'
                }
            }
        }

        It 'Root module export whitelist matches IToolkit.psd1 definition and resolves commands' {
            $itoolkitModule = Get-Module -Name 'IToolkit'
            $itoolkitModule | Should -Not -BeNullOrEmpty
            $exportedAliases = $itoolkitModule.ExportedAliases.Keys
            $exportedAliases -contains 'Test-OutlookRule' | Should -BeTrue
            $exportedAliases -contains 'Invoke-OutlookPstCompaction' | Should -BeTrue

            $exportedFns = $itoolkitModule.ExportedFunctions.Keys
            $exportedFns -contains 'Export-OutlookRule' | Should -BeTrue
            $exportedFns -contains 'Import-OutlookRule' | Should -BeTrue
            $exportedFns -contains 'Repair-OutlookRule' | Should -BeTrue

            $profileCmd = Get-Command -Name 'Select-ToolkitOutlookProfile' -ErrorAction SilentlyContinue
            $profileCmd | Should -Not -BeNullOrEmpty
            $profileCmd.Source | Should -Be 'IToolkit'
        }

        It 'Re-importing IToolkit multiple times does not corrupt aliases or produce duplicate entries' {
            {
                1..3 | ForEach-Object { Import-Module $itoolkitPsd1 -Force }
            } | Should -Not -Throw

            $aliases = @(Get-Command -Name 'Test-OutlookRule' -CommandType Alias)
            $aliases.Count | Should -Be 1
        }
    }

    # =========================================================================
    # Context 3: Context Menu Action 8 (Export Rules for Store) Stress Testing
    # =========================================================================
    Context '3. Context Menu Action 8 (Export Rules for Store)' {

        BeforeEach {
            $script:mockFile = [PSCustomObject]@{
                Filename   = 'Executive.pst'
                Path       = 'C:\Special Path\Executive [2026].pst'
                Format     = 'PST'
                Status     = '[READY]'
                Profile    = 'Executive Profile (VIP)'
                Item       = 'Executive.pst'
                Type       = 'PST'
                Details    = 'C:\Special Path\Executive [2026].pst'
                SizeGB     = 4.5
                FileObject = $null
            }
        }

        It 'Action 8 correctly binds StorePath, ProfileName, and Force flags with special characters' -Skip:(-not $isTUIAvailable) {
            $script:exportCalls = @()
            Mock Confirm-ToolkitAction { return $true }
            Mock Read-Host { return '' } # Use default manifest path
            Mock Export-OutlookRule {
                param($Path, $ProfileName, $StorePath, [switch]$Force)
                $script:exportCalls += @{
                    Path        = $Path
                    ProfileName = $ProfileName
                    StorePath   = $StorePath
                    Force       = $Force.IsPresent
                }
                return [PSCustomObject]@{ Success = $true; RulesExported = 7 }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '8' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:mockFile } | Should -Not -Throw
            $script:exportCalls.Count | Should -Be 1
            $call = $script:exportCalls[0]
            $call.StorePath | Should -Be 'C:\Special Path\Executive [2026].pst'
            $call.ProfileName | Should -Be 'Executive Profile (VIP)'
            $call.Force | Should -BeTrue
            $call.Path | Should -Match 'Executive_Rules_\d{8}_\d{6}\.json$'
        }

        It 'Action 8 appends .json extension if user enters a custom path without extension' -Skip:(-not $isTUIAvailable) {
            $script:exportCalls = @()
            Mock Confirm-ToolkitAction { return $true }
            Mock Read-Host { return 'CustomRulesExport' } # No .json extension
            Mock Export-OutlookRule {
                param($Path, $ProfileName, $StorePath, [switch]$Force)
                $script:exportCalls += @{ Path = $Path }
                return [PSCustomObject]@{ Success = $true; RulesExported = 3 }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '8' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:mockFile } | Should -Not -Throw
            $script:exportCalls.Count | Should -Be 1
            $script:exportCalls[0].Path | Should -Match 'CustomRulesExport\.json$'
        }

        It 'Action 8 traps exceptions thrown by Export-OutlookRule without crashing the menu loop' -Skip:(-not $isTUIAvailable) {
            Mock Confirm-ToolkitAction { return $true }
            Mock Read-Host { return '' }
            Mock Export-OutlookRule { throw 'Simulated COM/Disk Failure during export' }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '8' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:mockFile } | Should -Not -Throw
        }

        It 'Action 8 handles Success=$false result gracefully' -Skip:(-not $isTUIAvailable) {
            Mock Confirm-ToolkitAction { return $true }
            Mock Read-Host { return '' }
            Mock Export-OutlookRule {
                return [PSCustomObject]@{ Success = $false; ErrorMessage = 'Store is currently locked by another process' }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '8' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:mockFile } | Should -Not -Throw
        }

        It 'Action 8 aborts immediately and does not call Export-OutlookRule when confirmation is declined' -Skip:(-not $isTUIAvailable) {
            $script:exportCalled = $false
            Mock Confirm-ToolkitAction { return $false }
            Mock Export-OutlookRule { $script:exportCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '8' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:mockFile } | Should -Not -Throw
            $script:exportCalled | Should -BeFalse
        }
    }

    # =========================================================================
    # Context 4: Context Menu Action 9 (Import & Remap Rules into Store) Stress Testing
    # =========================================================================
    Context '4. Context Menu Action 9 (Import & Auto-Remap Rules into Store)' {

        BeforeAll {
            $script:testManifest = [System.IO.Path]::GetTempFileName()
            Set-Content -Path $script:testManifest -Value '{"SchemaVersion":"1.0.0","Rules":[]}' -Encoding UTF8
        }

        AfterAll {
            if (Test-Path -LiteralPath $script:testManifest) {
                Remove-Item -LiteralPath $script:testManifest -Force -ErrorAction SilentlyContinue
            }
        }

        BeforeEach {
            $script:mockFile = [PSCustomObject]@{
                Filename   = 'Operations.ost'
                Path       = 'C:\Outlook Stores\Operations.ost'
                Format     = 'OST'
                Status     = '[READY]'
                Profile    = 'OperationsProfile'
                Item       = 'Operations.ost'
                Type       = 'OST'
                Details    = 'C:\Outlook Stores\Operations.ost'
                SizeGB     = 2.1
                FileObject = $null
            }
        }

        It 'Action 9 strips enclosing quotes from manifest path and binds TargetStorePath and ProfileName' -Skip:(-not $isTUIAvailable) {
            $script:importCalls = @()
            Mock Confirm-ToolkitAction { return $true }
            Mock Read-Host {
                param($Prompt)
                if ($Prompt -match 'Path to Rule Manifest') {
                    return "`"$($script:testManifest)`"" # Wrapped in double quotes
                }
                return ''
            }
            Mock Import-OutlookRule {
                param($Path, $TargetStorePath, $ProfileName, [switch]$AutoCreateFolders, [string]$DuplicateHandling)
                $script:importCalls += @{
                    Path              = $Path
                    TargetStorePath   = $TargetStorePath
                    ProfileName       = $ProfileName
                    AutoCreateFolders = $AutoCreateFolders.IsPresent
                    DuplicateHandling = $DuplicateHandling
                }
                return [PSCustomObject]@{ Success = $true; RulesImported = 5; RulesSkipped = 0; FoldersCreated = 2 }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '9' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:mockFile } | Should -Not -Throw
            $script:importCalls.Count | Should -Be 1
            $call = $script:importCalls[0]
            $call.Path | Should -Be $script:testManifest # Quotes stripped!
            $call.TargetStorePath | Should -Be 'C:\Outlook Stores\Operations.ost'
            $call.ProfileName | Should -Be 'OperationsProfile'
            $call.AutoCreateFolders | Should -BeTrue
            $call.DuplicateHandling | Should -Be 'Skip'
        }

        It 'Action 9 aborts with warning when empty or whitespace manifest path is given' -Skip:(-not $isTUIAvailable) {
            $script:importCalled = $false
            Mock Read-Host { return '   ' } # Only whitespace
            Mock Import-OutlookRule { $script:importCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '9' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:mockFile } | Should -Not -Throw
            $script:importCalled | Should -BeFalse
        }

        It 'Action 9 aborts when manifest file does not exist on disk' -Skip:(-not $isTUIAvailable) {
            $script:importCalled = $false
            Mock Read-Host { return 'C:\NoSuchFolder\MissingFile.json' }
            Mock Import-OutlookRule { $script:importCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '9' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:mockFile } | Should -Not -Throw
            $script:importCalled | Should -BeFalse
        }

        It 'Action 9 traps exceptions from Import-OutlookRule gracefully' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return $script:testManifest }
            Mock Confirm-ToolkitAction { return $true }
            Mock Import-OutlookRule { throw 'Fatal MAPI target store corruption' }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '9' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:mockFile } | Should -Not -Throw
        }
    }

    # =========================================================================
    # Context 5: Context Menu Action 10 (Diagnostics & Auto-Repair) Stress Testing
    # =========================================================================
    Context '5. Context Menu Action 10 (Diagnostics & Auto-Repair for Store)' {

        BeforeEach {
            $script:mockFile = [PSCustomObject]@{
                Filename   = 'Archive.pst'
                Path       = 'C:\Storage\Archive.pst'
                Format     = 'PST'
                Status     = '[READY]'
                Profile    = 'SecondaryProfile'
                Item       = 'Archive.pst'
                Type       = 'PST'
                Details    = 'C:\Storage\Archive.pst'
                SizeGB     = 10.0
                FileObject = $null
            }
        }

        It 'Action 10 invokes repair with AutoRepair=$true when user answers yes' -Skip:(-not $isTUIAvailable) {
            $script:diagCalls = @()
            Mock Read-Host {
                param($Prompt)
                if ($Prompt -match 'Enable Auto-Repair') { return 'YES' }
                return ''
            }
            Mock Confirm-ToolkitAction { return $true }
            Mock Repair-OutlookRule {
                param($StorePath, $ProfileName, [switch]$AutoRepair)
                $script:diagCalls += @{
                    StorePath   = $StorePath
                    ProfileName = $ProfileName
                    AutoRepair  = $AutoRepair.IsPresent
                }
                return [PSCustomObject]@{
                    Success            = $true
                    TotalRules         = 12
                    BrokenRules        = 2
                    DuplicateRules     = 1
                    EmptyRules         = 0
                    RepairedRulesCount = 2
                }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:mockFile } | Should -Not -Throw
            $script:diagCalls.Count | Should -Be 1
            $call = $script:diagCalls[0]
            $call.StorePath | Should -Be 'C:\Storage\Archive.pst'
            $call.ProfileName | Should -Be 'SecondaryProfile'
            $call.AutoRepair | Should -BeTrue
        }

        It 'Action 10 invokes scan-only mode when user answers no' -Skip:(-not $isTUIAvailable) {
            $script:diagCalls = @()
            Mock Read-Host {
                param($Prompt)
                if ($Prompt -match 'Enable Auto-Repair') { return 'no' }
                return ''
            }
            Mock Confirm-ToolkitAction { return $true }
            Mock Repair-OutlookRule {
                param($StorePath, $ProfileName, [switch]$AutoRepair)
                $script:diagCalls += @{
                    StorePath   = $StorePath
                    ProfileName = $ProfileName
                    AutoRepair  = $AutoRepair.IsPresent
                }
                return [PSCustomObject]@{
                    Success            = $true
                    TotalRules         = 12
                    BrokenRules        = 2
                    DuplicateRules     = 0
                    EmptyRules         = 1
                    RepairedRulesCount = 0
                }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:mockFile } | Should -Not -Throw
            $script:diagCalls.Count | Should -Be 1
            $script:diagCalls[0].AutoRepair | Should -BeFalse
        }

        It 'Action 10 can dispatch via Test-OutlookRule alias if Repair-OutlookRule is dispatched through alias' -Skip:(-not $isTUIAvailable) {
            $script:aliasCalled = $false
            Mock Read-Host { return 'n' }
            Mock Confirm-ToolkitAction { return $true }
            Mock Test-OutlookRule {
                $script:aliasCalled = $true
                return [PSCustomObject]@{ Success = $true; TotalRules = 3; BrokenRules = 0; DuplicateRules = 0; EmptyRules = 0 }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:mockFile } | Should -Not -Throw
        }

        It 'Action 10 aborts when user cancels confirmation prompt' -Skip:(-not $isTUIAvailable) {
            $script:repairCalled = $false
            Mock Read-Host { return 'y' }
            Mock Confirm-ToolkitAction { return $false }
            Mock Repair-OutlookRule { $script:repairCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:mockFile } | Should -Not -Throw
            $script:repairCalled | Should -BeFalse
        }

        It 'Action 10 traps exceptions gracefully without crashing' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return 'y' }
            Mock Confirm-ToolkitAction { return $true }
            Mock Repair-OutlookRule { throw 'Diagnostic subsystem internal exception' }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $script:mockFile } | Should -Not -Throw
        }
    }
}
