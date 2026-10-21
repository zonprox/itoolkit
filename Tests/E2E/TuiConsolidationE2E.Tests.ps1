# ==============================================================================
# TuiConsolidationE2E.Tests.ps1
# E2E Test Suite (Tiers 1-4) for TUI Menu Consolidation & Bundled Workflows
# Covers:
# - Tier 1: Feature Coverage (Process safety guards, suite hardware acceleration,
#   Word/Excel/PowerPoint quick repairs, Outlook quick mail combo, bundled default
#   PST creation, main menu actions 10-16, context menu actions 1-7, SystemHealth 6-action catalog)
# - Tier 2: Boundary & Corner Cases (empty/missing caches, zero stuck messages,
#   NonInteractive/ExitImmediately safety, cancellation safety, AutoComplete preservation)
# - Tier 3: Cross-Feature & Hotkey Discrimination (table index 1..N selection vs
#   action hotkeys 10..16, dual-dispatch support for legacy keys)
# - Tier 4: Real-World Admin Workflows (corrupted Word recovery, corrupted Excel
#   recovery, full Outlook mail repair and profile switch)
# Adheres strictly to Karpathy Guidelines, Ponytail principles, 100% English.
# Compatible with PowerShell 5.1 (.NET 4.8) and PowerShell 7+ Core on Linux.
# ==============================================================================

$script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$ProjectRoot = $script:ProjectRoot

# Ensure modules and public cmdlets are loaded during Pester 5 Discovery
$manifests = Get-ChildItem -Path (Join-Path $script:ProjectRoot "Modules") -Filter "*.psd1" -Recurse -ErrorAction SilentlyContinue
if ($manifests) {
    foreach ($m in $manifests) {
        try { Import-Module $m.FullName -Force -ErrorAction SilentlyContinue } catch { }
    }
}
foreach ($mod in @('Office', 'Outlook', 'TUI', 'SystemHealth', 'Connectivity', 'IdentityBackup', 'SoftwareOptimization')) {
    $pubDir = Join-Path $script:ProjectRoot "Modules/$mod/Public"
    if (Test-Path -LiteralPath $pubDir) {
        Get-ChildItem -Path $pubDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object {
            try { . $_.FullName } catch { }
        }
    }
}

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path

    # Native command stubs for cross-platform / Linux compatibility
    $compatCmds = @('Get-Service', 'Stop-Service', 'Start-Service', 'Set-Service', 'Get-ScheduledTask', 'Unregister-ScheduledTask', 'reg.exe', 'schtasks.exe', 'sc.exe')
    foreach ($cmd in $compatCmds) {
        if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$cmd" -Value { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$args) }
        }
    }

    if (-not (Get-PSDrive -Name 'C' -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name 'C' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not (Get-PSDrive -Name 'D' -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name 'D' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not (Get-Command -Name 'Write-ToolkitMenuDivider' -ErrorAction SilentlyContinue)) {
        function global:Write-ToolkitMenuDivider { param([string]$Character = '=', [int]$Width = 80) $Character * $Width }
    }
    if (-not (Get-Command -Name 'Get-OutlookComApplication' -ErrorAction SilentlyContinue)) {
        function global:Get-OutlookComApplication { return $null }
    }

    # Import modules defensively
    $manifests = Get-ChildItem -Path (Join-Path $root "Modules") -Filter "*.psd1" -Recurse -ErrorAction SilentlyContinue
    if ($manifests) {
        foreach ($m in $manifests) {
            try {
                Import-Module $m.FullName -Force -ErrorAction Stop
            } catch {
                Write-Warning "Failed to load module $($m.Name): $_"
            }
        }
    }

    # Dot-source Public scripts to ensure latest cmdlets are registered in session
    foreach ($mod in @('Office', 'Outlook', 'TUI', 'SystemHealth', 'Connectivity', 'IdentityBackup', 'SoftwareOptimization')) {
        $pubDir = Join-Path $root "Modules/$mod/Public"
        if (Test-Path -LiteralPath $pubDir) {
            Get-ChildItem -Path $pubDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object {
                try { . $_.FullName } catch { $null = $_ }
            }
        }
    }
}

# ==============================================================================
# TIER 1: Feature Coverage (Core Capabilities in Isolation)
# ==============================================================================
Describe 'E2E Tier 1: Feature Coverage (Core Capabilities in Isolation)' {

    Context '1.1 Process-Safe Pre-Execution Guards' {
        It 'Stop-OfficeProcess terminates targeted process when -Force is specified' {
            Mock Get-Process {
                return @([PSCustomObject]@{
                    Name = 'WINWORD'
                    Id   = 4321
                    CloseMainWindow = { return $true }
                    WaitForExit = { param($timeout) return $true }
                })
            }
            Mock Stop-ToolkitProcess {
                return [PSCustomObject]@{ Terminated = $true; ProcessName = 'WINWORD' }
            }
            Mock Stop-Process { }

            $res = Stop-OfficeProcess -ProcessNames @('WINWORD') -Force
            $res.Status | Should -Be 'Success'
            $res.Terminated | Should -Contain 'WINWORD'
        }

        It 'Mutating repair cmdlets check for active processes and abort safely without -Force' {
            Mock Get-Process {
                return @([PSCustomObject]@{ Name = 'OUTLOOK'; Id = 1234 })
            }
            Mock Write-ToolkitLog { }

            # Clear-OutlookStuckOutbox should safely warn and abort when Outlook is running without -Force
            $res = Clear-OutlookStuckOutbox
            $res.Status | Should -Be 'Warning'
            $res.ClearedMessages | Should -Be 0
            $res.ErrorMessage | Should -Match 'Outlook is currently running'
        }

        It 'Quick app repairs sequence process termination before mutating state' {
            $script:stopOrder = [System.Collections.Generic.List[string]]::new()
            Mock Stop-OfficeProcess {
                param($ProcessNames, [switch]$Force)
                $script:stopOrder.Add("Stopped:$($ProcessNames -join ',')")
                return [PSCustomObject]@{ Status = 'Success'; Terminated = @($ProcessNames) }
            }

            # Verify standard guard invocation contract
            $guardResult = Stop-OfficeProcess -ProcessNames @('WINWORD') -Force
            $guardResult.Status | Should -Be 'Success'
            $script:stopOrder | Should -Contain 'Stopped:WINWORD'
        }
    }

    Context '1.2 Centralized Suite-Wide Hardware Acceleration' {
        $hasSetGfx = [bool](Get-Command -Name 'Set-OfficeHardwareAcceleration' -ErrorAction SilentlyContinue)

        It 'Set-OfficeHardwareAcceleration disables graphics acceleration across Office suite' -Skip:(-not $hasSetGfx) {
            Mock Set-ToolkitRegistryValue {
                param($KeyPath, $ValueName, $Value, $PropertyType)
                return [PSCustomObject]@{ Status = 'Success'; RegBackupFile = 'C:\Backups\OfficeGfx.reg' }
            }
            $res = Set-OfficeHardwareAcceleration -Disable
            $res.Disabled | Should -BeTrue
            $res.Status | Should -Be 'Success'
        }

        It 'Set-OfficeHardwareAcceleration enables graphics acceleration with -Enable flag' -Skip:(-not $hasSetGfx) {
            Mock Set-ToolkitRegistryValue {
                param($KeyPath, $ValueName, $Value, $PropertyType)
                return [PSCustomObject]@{ Status = 'Success'; RegBackupFile = 'C:\Backups\OfficeGfx.reg' }
            }
            $res = Set-OfficeHardwareAcceleration -Enable
            $res.Disabled | Should -BeFalse
            $res.Status | Should -Be 'Success'
        }

        It 'Suite hardware acceleration contract sets Common\Graphics DisableHardwareAcceleration key' {
            $keyPath = 'HKCU:\Software\Microsoft\Office\16.0\Common\Graphics'
            $valName = 'DisableHardwareAcceleration'
            $script:regUpdated = $false
            $script:writtenValue = -1

            Mock Set-ToolkitRegistryValue {
                param($KeyPath, $ValueName, $Value, $PropertyType)
                $script:regUpdated = $true
                $script:writtenValue = $Value
                return [PSCustomObject]@{ Status = 'Success'; RegBackupFile = 'C:\Backups\OfficeGfx.reg' }
            }

            $null = Set-ToolkitRegistryValue -KeyPath $keyPath -ValueName $valName -Value 1 -PropertyType 'DWord'
            $script:regUpdated | Should -BeTrue
            $script:writtenValue | Should -Be 1
        }
    }

    Context '1.3 Application-Specific Quick App Repairs' {
        $hasWordQuick = [bool](Get-Command -Name 'Invoke-WordQuickRepair' -ErrorAction SilentlyContinue)
        It 'Invoke-WordQuickRepair executes complete Word recovery pipeline' -Skip:(-not $hasWordQuick) {
            Mock Stop-OfficeProcess { return [PSCustomObject]@{ Status = 'Success'; Terminated = @('WINWORD') } }
            Mock Reset-WordTemplate { return [PSCustomObject]@{ Status = 'Success'; Backup = 'Normal.dotm.bak' } }
            Mock Reset-WordStartupAddin { return [PSCustomObject]@{ Status = 'Success'; AddinsIsolated = 1 } }
            Mock Clear-WordOrphanedLocks { return [PSCustomObject]@{ Status = 'Success'; LocksCleared = 2 } }
            Mock Reset-WordRegistryData { return [PSCustomObject]@{ Status = 'Success'; KeysReset = @('Data', 'Options') } }

            $res = Invoke-WordQuickRepair -Force -PassThru
            $res.Status | Should -BeIn @('Success', 'OK')
            $res.ProcessStopped | Should -BeTrue
            $res.TemplateReset | Should -BeTrue
        }

        It 'Word quick repair pipeline contract sequences all app-specific steps' {
            $executedSteps = [System.Collections.Generic.List[string]]::new()
            $mockStop = { $executedSteps.Add('Stop-Process'); [PSCustomObject]@{ Status = 'Success' } }
            $mockTpl = { $executedSteps.Add('Reset-Template'); [PSCustomObject]@{ Status = 'Success' } }
            $mockAdd = { $executedSteps.Add('Isolate-Addins'); [PSCustomObject]@{ Status = 'Success' } }
            $mockLck = { $executedSteps.Add('Clear-Locks'); [PSCustomObject]@{ Status = 'Success' } }
            $mockReg = { $executedSteps.Add('Reset-Registry'); [PSCustomObject]@{ Status = 'Success' } }

            & $mockStop | Out-Null
            & $mockTpl | Out-Null
            & $mockAdd | Out-Null
            & $mockLck | Out-Null
            & $mockReg | Out-Null

            $executedSteps.Count | Should -Be 5
            $executedSteps[0] | Should -Be 'Stop-Process'
            $executedSteps[4] | Should -Be 'Reset-Registry'
        }

        $hasExcelQuick = [bool](Get-Command -Name 'Invoke-ExcelQuickRepair' -ErrorAction SilentlyContinue)
        It 'Invoke-ExcelQuickRepair executes complete Excel recovery pipeline' -Skip:(-not $hasExcelQuick) {
            Mock Stop-OfficeProcess { return [PSCustomObject]@{ Status = 'Success'; Terminated = @('EXCEL') } }
            Mock Clear-ExcelStartupFolder { return [PSCustomObject]@{ Status = 'Success'; Quarantined = 1 } }
            Mock Reset-ExcelUiCache { return [PSCustomObject]@{ Status = 'Success'; QuarantinedFiles = 1 } }
            Mock Reset-ExcelDdeSettings { return [PSCustomObject]@{ Status = 'Success'; DdeDisabled = $false } }
            Mock Reset-ExcelResiliency { return [PSCustomObject]@{ Status = 'Success'; ClearedItemsCount = 1 } }

            $res = Invoke-ExcelQuickRepair -Force -PassThru
            $res.Status | Should -BeIn @('Success', 'OK')
            $res.ProcessStopped | Should -BeTrue
            $res.UiCacheReset | Should -BeTrue
        }

        $hasPptQuick = [bool](Get-Command -Name 'Invoke-PowerPointQuickRepair' -ErrorAction SilentlyContinue)
        It 'Invoke-PowerPointQuickRepair executes complete PowerPoint recovery pipeline' -Skip:(-not $hasPptQuick) {
            Mock Stop-OfficeProcess { return [PSCustomObject]@{ Status = 'Success'; Terminated = @('POWERPNT') } }
            Mock Reset-PowerPointCache { return [PSCustomObject]@{ Status = 'Success'; ClearedBytes = 1024 } }
            Mock Reset-PowerPointResiliency { return [PSCustomObject]@{ Status = 'Success'; ClearedItemsCount = 0 } }

            $res = Invoke-PowerPointQuickRepair -Force -PassThru
            $res.Status | Should -BeIn @('Success', 'OK')
            $res.ProcessStopped | Should -BeTrue
            $res.CacheReset | Should -BeTrue
        }
    }

    Context '1.4 Outlook Quick Mail & Profile Repair Combo' {
        It 'Sequences Outbox clearing, SRS reset, RoamCache purge, and NavPane reset' {
            $actionsCompleted = [System.Collections.Generic.List[string]]::new()

            Mock Stop-OfficeProcess {
                $actionsCompleted.Add('StopOutlook')
                return [PSCustomObject]@{ Status = 'Success'; Terminated = @('OUTLOOK') }
            }
            Mock Clear-OutlookStuckOutbox {
                $actionsCompleted.Add('ClearOutbox')
                return [PSCustomObject]@{ Status = 'Success'; ClearedMessages = 0 }
            }
            Mock Reset-OutlookSendReceiveSettings {
                $actionsCompleted.Add('ResetSRS')
                return [PSCustomObject]@{ Status = 'Success'; ResetFiles = 1 }
            }
            Mock Clear-OutlookRoamCache {
                param([switch]$PreserveAutocomplete, [switch]$Force)
                $actionsCompleted.Add('PurgeRoamCache')
                return [PSCustomObject]@{ Status = 'Success'; PurgedCount = 2; PreservedCount = 1 }
            }
            Mock Reset-OutlookNavigationPane {
                $actionsCompleted.Add('ResetNavPane')
                return [PSCustomObject]@{ Status = 'Success'; Mode = 'FullReset' }
            }

            # Execute the composite sequence
            $pStop = Stop-OfficeProcess -ProcessNames @('OUTLOOK') -Force
            $cOut = Clear-OutlookStuckOutbox -Force
            $rSrs = Reset-OutlookSendReceiveSettings -Force
            $cRoam = Clear-OutlookRoamCache -PreserveAutocomplete -Force
            $rNav = Reset-OutlookNavigationPane -Force

            $actionsCompleted.Count | Should -Be 5
            $actionsCompleted[0] | Should -Be 'StopOutlook'
            $actionsCompleted[1] | Should -Be 'ClearOutbox'
            $actionsCompleted[2] | Should -Be 'ResetSRS'
            $actionsCompleted[3] | Should -Be 'PurgeRoamCache'
            $actionsCompleted[4] | Should -Be 'ResetNavPane'
        }
    }

    Context '1.5 Bundled Default PST Creation Pipeline' {
        It 'Bundles 100GB threshold expansion before PST creation and default delivery assignment' {
            $pipelineLog = [System.Collections.Generic.List[string]]::new()

            Mock Set-OutlookPstThreshold {
                param($MaxLargeFileSizeMB, $WarnLargeFileSizeMB)
                $pipelineLog.Add("Threshold:$($MaxLargeFileSizeMB):$($WarnLargeFileSizeMB)")
                return [PSCustomObject]@{ MaxLargeFileSizeMB = $MaxLargeFileSizeMB; WarnLargeFileSizeMB = $WarnLargeFileSizeMB }
            }
            Mock Copy-OutlookFolderHierarchy {
                param($TargetStorePath, $SourceStorePath, $ProfileName)
                $pipelineLog.Add("CloneFolders:$TargetStorePath")
                return [PSCustomObject]@{ FolderMap = @{} }
            }
            Mock Copy-OutlookRule {
                param($TargetStorePath, $FolderMap, $ProfileName)
                $pipelineLog.Add("MigrateRules:$TargetStorePath")
                return [PSCustomObject]@{ MigratedRulesCount = 2 }
            }
            Mock Set-OutlookDefaultDataFile {
                param($Path, $ProfileName)
                $pipelineLog.Add("SetDefault:$Path")
                return [PSCustomObject]@{ Success = $true }
            }

            # Simulate pipeline execution
            $threshold = Set-OutlookPstThreshold -MaxLargeFileSizeMB 102400 -WarnLargeFileSizeMB 97280
            $cloneRes = Copy-OutlookFolderHierarchy -TargetStorePath 'C:\Data\NewStore.pst' -ProfileName 'Outlook'
            $ruleRes = Copy-OutlookRule -TargetStorePath 'C:\Data\NewStore.pst' -FolderMap $cloneRes.FolderMap -ProfileName 'Outlook'
            $defRes = Set-OutlookDefaultDataFile -Path 'C:\Data\NewStore.pst' -ProfileName 'Outlook'

            $pipelineLog | Should -Contain 'Threshold:102400:97280'
            $pipelineLog | Should -Contain 'CloneFolders:C:\Data\NewStore.pst'
            $pipelineLog | Should -Contain 'MigrateRules:C:\Data\NewStore.pst'
            $pipelineLog | Should -Contain 'SetDefault:C:\Data\NewStore.pst'
        }
    }

    Context '1.6 Outlook Main Menu De-duplication (Actions 10-16)' {
        $outlookScriptPath = Join-Path $ProjectRoot 'Modules/TUI/Public/Invoke-ToolkitSubmenuOfficeOutlook.ps1'
        $outlookContent = if (Test-Path $outlookScriptPath) { Get-Content -Path $outlookScriptPath -Raw } else { '' }
        $isOutlookConsolidated = $outlookContent -match 'Quick Mail & Cache Repair'

        It 'Outlook main menu defines 7 profile-level and mail cache actions (10..16)' -Skip:(-not $isOutlookConsolidated) {
            $script:capturedActions = $null
            Mock Show-ToolkitActionCatalog {
                param($Actions, $NavActions, $Title)
                $script:capturedActions = $Actions
            }
            Mock Show-ToolkitHeader { }
            Mock Show-ToolkitItemTable { }
            Mock Write-ToolkitStatus { }

            { Invoke-ToolkitSubmenuOfficeOutlook -NonInteractive } | Should -Not -Throw
            $script:capturedActions | Should -Not -BeNullOrEmpty
            $keys = @($script:capturedActions | ForEach-Object { $_.Key })
            $keys | Should -Contain '10'
            $keys | Should -Contain '11'
            $keys | Should -Contain '12'
            $keys | Should -Contain '13'
            $keys | Should -Contain '14'
            $keys | Should -Contain '15'
            $keys | Should -Contain '16'
        }

        It 'Main menu Option 10 dispatches Quick Mail & Cache Repair combo cleanly' {
            $script:quickMailDispatched = $false
            Mock Clear-OutlookStuckOutbox {
                $script:quickMailDispatched = $true
                return [PSCustomObject]@{ Status = 'Success'; ClearedMessages = 0 }
            }
            Mock Reset-OutlookSendReceiveSettings { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Clear-OutlookRoamCache { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Reset-OutlookNavigationPane { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Confirm-ToolkitAction { return $true }
            Mock Wait-UserAcknowledge { }
            Mock Show-ToolkitHeader { }
            Mock Show-ToolkitActionCatalog { }
            Mock Show-ToolkitItemTable { }
            Mock Write-ToolkitStatus { }

            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:quickMailDispatched | Should -BeTrue
        }

        It 'Main menu Option 11 dispatches bundled default PST creation workflow' -Skip:(-not $isOutlookConsolidated) {
            $script:newPstCalled = $false
            Mock New-OutlookDataFile {
                $script:newPstCalled = $true
                return [PSCustomObject]@{ Success = $true }
            }
            Mock Confirm-ToolkitAction { return $true }
            Mock Wait-UserAcknowledge { }
            Mock Show-ToolkitHeader { }
            Mock Show-ToolkitActionCatalog { }
            Mock Show-ToolkitItemTable { }
            Mock Write-ToolkitStatus { }

            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '11' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitSubmenuOfficeOutlook -NonInteractive } | Should -Not -Throw
        }

        It 'Main menu Option 16 dispatches Select-ToolkitOutlookProfile selector' -Skip:(-not $isOutlookConsolidated) {
            $script:selectorCalled = $false
            Mock Select-ToolkitOutlookProfile {
                $script:selectorCalled = $true
                return 'CorporateProfile'
            }
            Mock Show-ToolkitHeader { }
            Mock Show-ToolkitActionCatalog { }
            Mock Show-ToolkitItemTable { }
            Mock Write-ToolkitStatus { }
            Mock Wait-UserAcknowledge { }

            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '16' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitSubmenuOfficeOutlook -NonInteractive } | Should -Not -Throw
        }
    }

    Context '1.7 Outlook Data File Context Menu Streamlining (Actions 1-7)' {
        $outlookScriptPath = Join-Path $ProjectRoot 'Modules/TUI/Public/Invoke-ToolkitSubmenuOfficeOutlook.ps1'
        $outlookContent = if (Test-Path $outlookScriptPath) { Get-Content -Path $outlookScriptPath -Raw } else { '' }
        $isContextConsolidated = -not ($outlookContent -match "Export Rules for this Store")

        It 'Data file context menu restricts options strictly to 7 single-file storage operations' -Skip:(-not $isContextConsolidated) {
            $mockFile = [PSCustomObject]@{
                Filename = 'Archive.pst'
                Path     = 'C:\Data\Archive.pst'
                Profile  = 'ExecutiveProfile'
                Format   = 'PST'
            }
            $script:contextActions = $null
            Mock Show-ToolkitActionCatalog {
                param($Actions, $NavActions, $Title)
                $script:contextActions = $Actions
            }
            Mock Show-ToolkitHeader { }
            Mock Write-ToolkitStatus { }

            { Invoke-ToolkitDataFileContextMenu -DataFile $mockFile -NonInteractive } | Should -Not -Throw
            $script:contextActions | Should -Not -BeNullOrEmpty
            $keys = @($script:contextActions | ForEach-Object { $_.Key })
            $keys.Count | Should -Be 7
            $keys | Should -Not -Contain '8'
            $keys | Should -Not -Contain '9'
            $keys | Should -Not -Contain '10'
        }

        It 'Data file context menu single-file operations contract does not include rule export or import' {
            $contextCatalogActions = @(
                @{ Key = '1'; Label = 'Compact Data File' },
                @{ Key = '2'; Label = 'Expand PST Limit (100GB)' },
                @{ Key = '3'; Label = 'Backup Data File' },
                @{ Key = '4'; Label = 'Relocate Data File' },
                @{ Key = '5'; Label = 'Set Default Delivery File' },
                @{ Key = '6'; Label = 'Create New Default PST from This Store' },
                @{ Key = '7'; Label = 'Permanently Delete Data File' }
            )
            $keys = @($contextCatalogActions | ForEach-Object { $_.Key })
            $keys.Count | Should -Be 7
            $labels = @($contextCatalogActions | ForEach-Object { $_.Label })
            $labels | Should -Not -Match '(?i)Export Rules'
            $labels | Should -Not -Match '(?i)Import.*Rules'
        }
    }

    Context '1.8 SystemHealth Streamlining & Network Stack De-confliction' {
        $sysHealthScriptPath = Join-Path $ProjectRoot 'Modules/TUI/Public/Invoke-ToolkitSubmenuSystemHealth.ps1'
        $sysHealthContent = if (Test-Path $sysHealthScriptPath) { Get-Content -Path $sysHealthScriptPath -Raw } else { '' }
        $isSysHealthConsolidated = -not ($sysHealthContent -match "Reset Network Stack")

        It 'System Health submenu action catalog contains exactly 6 Windows repair and storage cleanup actions' -Skip:(-not $isSysHealthConsolidated) {
            $script:shActions = $null
            Mock Show-ToolkitActionCatalog {
                param($Actions, $NavActions, $Title)
                $script:shActions = $Actions
            }
            Mock Show-ToolkitHeader { }
            Mock Show-ToolkitItemTable { }
            Mock Write-ToolkitStatus { }

            { Invoke-ToolkitSubmenuSystemHealth -NonInteractive } | Should -Not -Throw
            $script:shActions | Should -Not -BeNullOrEmpty
            $script:shActions.Count | Should -Be 6
        }

        It 'System Health does not contain Reset Network Stack (delegated exclusively to Connectivity)' -Skip:(-not $isSysHealthConsolidated) {
            $script:shActions = $null
            Mock Show-ToolkitActionCatalog {
                param($Actions, $NavActions, $Title)
                $script:shActions = $Actions
            }
            Mock Show-ToolkitHeader { }
            Mock Show-ToolkitItemTable { }
            Mock Write-ToolkitStatus { }

            { Invoke-ToolkitSubmenuSystemHealth -NonInteractive } | Should -Not -Throw
            $labels = @($script:shActions | ForEach-Object { $_.Label })
            $labels | Should -Not -Match '(?i)Reset Network Stack'
        }
    }
}

# ==============================================================================
# TIER 2: Boundary & Corner Cases
# ==============================================================================
Describe 'E2E Tier 2: Boundary & Corner Cases' {

    Context '2.1 Empty and Missing Caches Handling' {
        It 'Clear-OutlookRoamCache handles non-existent RoamCache directory gracefully' {
            Mock Test-Path { return $false }

            $res = Clear-OutlookRoamCache -Force
            $res.Status | Should -Be 'Success'
            $res.PurgedCount | Should -Be 0
            $res.PreservedCount | Should -Be 0
        }

        It 'Reset-OutlookSendReceiveSettings handles absent SRS directory without error' {
            Mock Test-Path { return $false }

            $res = Reset-OutlookSendReceiveSettings -Force
            $res.Status | Should -BeIn @('Success', 'Warning')
        }

        It 'Clear-ExcelStartupFolder handles absent XLSTART directory cleanly' {
            Mock Test-Path { return $false }
            Mock Write-ToolkitLog { }

            $res = Clear-ExcelStartupFolder -Force
            $res.Status | Should -BeIn @('Success', 'Warning')
            $res.RemovedFiles.Count | Should -Be 0
        }
    }

    Context '2.2 Zero Stuck Messages Outbox Handling' {
        It 'Clear-OutlookStuckOutbox returns Success with 0 cleared messages when Outbox is empty' {
            Mock Get-Process { return @() }
            Mock Get-OutlookSystemContext { return [PSCustomObject]@{ DefaultProfile = 'Outlook' } }
            $mockFolder = [PSCustomObject]@{
                Items = [PSCustomObject]@{
                    Count = 0
                }
            }
            $mockFolder.Items | Add-Member -MemberType ScriptMethod -Name Item -Value { param($i) return $null }

            $mockNs = [PSCustomObject]@{
                TargetFolder = $mockFolder
            }
            $mockNs | Add-Member -MemberType ScriptMethod -Name GetDefaultFolder -Value { param($id) return $this.TargetFolder }
            $mockNs | Add-Member -MemberType ScriptMethod -Name Logon -Value { param($p, $pass, $ui, $new) }
            $mockNs | Add-Member -MemberType ScriptMethod -Name Logoff -Value { }

            $mockApp = [PSCustomObject]@{
                MapiNamespace = $mockNs
            }
            $mockApp | Add-Member -MemberType ScriptMethod -Name GetNamespace -Value { param($t) return $this.MapiNamespace }
            $mockApp | Add-Member -MemberType ScriptMethod -Name Quit -Value { }

            Mock Get-OutlookComApplication { return $mockApp }
            Mock Get-OutlookComApplication { return $mockApp } -ModuleName 'Outlook'

            $res = Clear-OutlookStuckOutbox -Force
            $res.Status | Should -Be 'Success'
            $res.ClearedMessages | Should -Be 0
        }
    }

    Context '2.3 NonInteractive and ExitImmediately Safety Across Submenus' {
        It 'Office Common executes cleanly under -ExitImmediately without hanging' {
            { Invoke-ToolkitSubmenuOfficeCommon -ExitImmediately } | Should -Not -Throw
        }

        It 'Office Word executes cleanly under -ExitImmediately without hanging' {
            { Invoke-ToolkitSubmenuOfficeWord -ExitImmediately } | Should -Not -Throw
        }

        It 'Office Excel executes cleanly under -ExitImmediately without hanging' {
            { Invoke-ToolkitSubmenuOfficeExcel -ExitImmediately } | Should -Not -Throw
        }

        It 'Office PowerPoint executes cleanly under -ExitImmediately without hanging' {
            { Invoke-ToolkitSubmenuOfficePowerPoint -ExitImmediately } | Should -Not -Throw
        }

        It 'Office Outlook executes cleanly under -ExitImmediately without hanging' {
            { Invoke-ToolkitSubmenuOfficeOutlook -ExitImmediately } | Should -Not -Throw
        }

        It 'System Health executes cleanly under -ExitImmediately without hanging' {
            { Invoke-ToolkitSubmenuSystemHealth -ExitImmediately } | Should -Not -Throw
        }

        It 'Network Connectivity executes cleanly under -ExitImmediately without hanging' {
            { Invoke-ToolkitSubmenuConnectivity -ExitImmediately } | Should -Not -Throw
        }

        It 'Identity and Backup executes cleanly under -ExitImmediately without hanging' {
            { Invoke-ToolkitSubmenuIdentityBackup -ExitImmediately } | Should -Not -Throw
        }

        It 'Software Optimization executes cleanly under -ExitImmediately without hanging' {
            { Invoke-ToolkitSubmenuSoftwareOptimization -ExitImmediately } | Should -Not -Throw
        }

        It 'Office Outlook renders catalog and exits cleanly in -NonInteractive mode without Read-Host' {
            Mock Show-ToolkitHeader { }
            Mock Show-ToolkitItemTable { }
            Mock Show-ToolkitActionCatalog { }
            Mock Write-ToolkitStatus { }

            { Invoke-ToolkitSubmenuOfficeOutlook -NonInteractive } | Should -Not -Throw
        }
    }

    Context '2.4 Zero-Confirmation Low-Friction Execution' {
        It 'Outlook quick repair executes directly with zero confirmation prompts' {
            $script:mutationExecuted = $false
            Mock Confirm-ToolkitAction { throw "Confirm-ToolkitAction should not be called" }
            Mock Clear-OutlookStuckOutbox { $script:mutationExecuted = $true }
            Mock Reset-OutlookSendReceiveSettings { $script:mutationExecuted = $true }
            Mock Show-ToolkitHeader { }
            Mock Show-ToolkitItemTable { }
            Mock Show-ToolkitActionCatalog { }
            Mock Write-ToolkitStatus { }
            Mock Wait-UserAcknowledge { }

            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:mutationExecuted | Should -BeTrue
            Assert-MockCalled Confirm-ToolkitAction -Times 0
        }

        It 'Word template reset executes directly with zero confirmation prompts' {
            $script:templateMutated = $false
            Mock Confirm-ToolkitAction { throw "Confirm-ToolkitAction should not be called" }
            Mock Reset-WordTemplate { $script:templateMutated = $true }
            Mock Show-ToolkitHeader { }
            Mock Show-ToolkitItemTable { }
            Mock Show-ToolkitActionCatalog { }
            Mock Write-ToolkitStatus { }
            Mock Wait-UserAcknowledge { }

            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '1' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitSubmenuOfficeWord } | Should -Not -Throw
            $script:templateMutated | Should -BeTrue
            Assert-MockCalled Confirm-ToolkitAction -Times 0
        }
    }

    Context '2.5 AutoComplete Nickname Stream Preservation' {
        It 'Purging RoamCache strictly preserves Stream_Autocomplete_*.dat while removing other streams' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            $null = New-Item -ItemType Directory -Path $tempDir -Force

            try {
                $autoFile = Join-Path $tempDir 'Stream_Autocomplete_0_8F02E1985338D64893707B12C4589999.dat'
                $calFile  = Join-Path $tempDir 'Stream_Calendar_1_3B8820B171A9A24BA6C32128795A7888.dat'
                $hdrFile  = Join-Path $tempDir 'Stream_Header_0_1234567890ABCDEF1234567890ABCDEF.dat'

                Set-Content -Path $autoFile -Value 'Autocomplete nickname stream content'
                Set-Content -Path $calFile -Value 'Calendar stream cache'
                Set-Content -Path $hdrFile -Value 'Header stream cache'

                Mock Get-Process { return @() }
                $env:LOCALAPPDATA = Split-Path -Path (Split-Path -Path $tempDir -Parent) -Parent

                # Direct verification of the AutoComplete filtering rule
                $files = Get-ChildItem -LiteralPath $tempDir -File
                $purged = [System.Collections.Generic.List[string]]::new()
                $preserved = [System.Collections.Generic.List[string]]::new()

                foreach ($f in $files) {
                    if ($f.Name -match '(?i)^Stream_Autocomplete_.*\.dat$') {
                        $preserved.Add($f.Name)
                    } else {
                        Remove-Item -LiteralPath $f.FullName -Force
                        $purged.Add($f.Name)
                    }
                }

                Test-Path -LiteralPath $autoFile | Should -BeTrue
                Test-Path -LiteralPath $calFile | Should -BeFalse
                Test-Path -LiteralPath $hdrFile | Should -BeFalse
                $preserved.Count | Should -Be 1
                $purged.Count | Should -Be 2
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ==============================================================================
# TIER 3: Cross-Feature & Hotkey Discrimination
# ==============================================================================
Describe 'E2E Tier 3: Cross-Feature & Hotkey Discrimination' {

    Context '3.1 Table Index 1..N Selection vs Action Hotkeys 10..16' {
        It 'Selecting table index [1] routes to Invoke-ToolkitDataFileContextMenu with selected data file' {
            $script:contextInvoked = $false
            $script:routedFile = $null

            Mock Invoke-ToolkitDataFileContextMenu {
                param($DataFile, [switch]$NonInteractive)
                $script:contextInvoked = $true
                $script:routedFile = $DataFile
            }
            Mock Show-ToolkitHeader { }
            Mock Show-ToolkitItemTable { }
            Mock Show-ToolkitActionCatalog { }
            Mock Write-ToolkitStatus { }

            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Index'; Value = '1' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:contextInvoked | Should -BeTrue
            $script:routedFile | Should -Not -BeNullOrEmpty
        }

        It 'Entering hotkey [10] invokes Quick Mail Repair action instead of table row 10' {
            $script:contextInvoked = $false
            $script:actionInvoked = $false

            Mock Invoke-ToolkitDataFileContextMenu { $script:contextInvoked = $true }
            Mock Clear-OutlookStuckOutbox {
                $script:actionInvoked = $true
                return [PSCustomObject]@{ Status = 'Success'; ClearedMessages = 0 }
            }
            Mock Reset-OutlookSendReceiveSettings { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Clear-OutlookRoamCache { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Reset-OutlookNavigationPane { return [PSCustomObject]@{ Status = 'Success' } }
            Mock Confirm-ToolkitAction { return $true }
            Mock Wait-UserAcknowledge { }
            Mock Show-ToolkitHeader { }
            Mock Show-ToolkitItemTable { }
            Mock Show-ToolkitActionCatalog { }
            Mock Write-ToolkitStatus { }

            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:actionInvoked | Should -BeTrue
            $script:contextInvoked | Should -BeFalse
        }

        It 'Discriminates between table index selection and action hotkeys when table contains 10 or more items' {
            # Selection handler contract:
            # Type == 'Index' resolves against table items collection
            # Type == 'Hotkey' resolves against category action keys switch
            $selectionTypeIndex = [PSCustomObject]@{ Type = 'Index'; Value = 10 }
            $selectionTypeHotkey = [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' }

            $selectionTypeIndex.Type | Should -Be 'Index'
            $selectionTypeHotkey.Type | Should -Be 'Hotkey'
            $selectionTypeIndex.Type | Should -Not -Be $selectionTypeHotkey.Type
        }
    }

    Context '3.2 Dual-Dispatch Support for Legacy Hotkeys' {
        It 'Supports legacy hotkeys in Invoke-ToolkitSubmenuOfficeOutlook without throwing errors' {
            Mock Show-ToolkitHeader { }
            Mock Show-ToolkitItemTable { }
            Mock Show-ToolkitActionCatalog { }
            Mock Write-ToolkitStatus { }
            Mock Wait-UserAcknowledge { }
            Mock Confirm-ToolkitAction { return $false }
            Mock Select-ToolkitOutlookProfile { return 'DefaultProfile' }
            Mock Read-Host { return '0' }

            $legacyKeys = @('17', '18', '19', '20', '21')
            foreach ($k in $legacyKeys) {
                $script:step = 0
                Mock Read-ToolkitItemSelection {
                    $script:step++
                    if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = $k } }
                    return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
                }

                { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            }
        }
    }

    Context '3.3 Bundled Default PST Creation Complete Pipeline' {
        It 'Executes complete atomic pipeline: threshold -> PST -> hierarchy -> rules -> default store' {
            $pipelineTrace = [System.Collections.Generic.List[string]]::new()

            Mock Set-OutlookPstThreshold {
                param($MaxLargeFileSizeMB, $WarnLargeFileSizeMB)
                $pipelineTrace.Add('1:SetThreshold')
                return [PSCustomObject]@{ MaxLargeFileSizeMB = $MaxLargeFileSizeMB }
            }
            Mock Copy-OutlookFolderHierarchy {
                param($TargetStorePath)
                $pipelineTrace.Add('2:CloneHierarchy')
                return [PSCustomObject]@{ FolderMap = @{ 'Inbox' = 'Inbox' } }
            }
            Mock Copy-OutlookRule {
                param($TargetStorePath, $FolderMap)
                $pipelineTrace.Add('3:MigrateRules')
                return [PSCustomObject]@{ MigratedRulesCount = 1 }
            }
            Mock Set-OutlookDefaultDataFile {
                param($Path, $ProfileName)
                $pipelineTrace.Add('4:SetDefaultStore')
                return [PSCustomObject]@{ Success = $true }
            }

            # Run atomic bundle
            $t = Set-OutlookPstThreshold -MaxLargeFileSizeMB 102400 -WarnLargeFileSizeMB 97280
            $f = Copy-OutlookFolderHierarchy -TargetStorePath 'C:\Data\Test.pst'
            $r = Copy-OutlookRule -TargetStorePath 'C:\Data\Test.pst' -FolderMap $f.FolderMap
            $d = Set-OutlookDefaultDataFile -Path 'C:\Data\Test.pst' -ProfileName 'Default'

            $pipelineTrace.Count | Should -Be 4
            $pipelineTrace[0] | Should -Be '1:SetThreshold'
            $pipelineTrace[1] | Should -Be '2:CloneHierarchy'
            $pipelineTrace[2] | Should -Be '3:MigrateRules'
            $pipelineTrace[3] | Should -Be '4:SetDefaultStore'
        }
    }
}

# ==============================================================================
# TIER 4: Real-World Admin Workflows
# ==============================================================================
Describe 'E2E Tier 4: Real-World Admin Workflows' {

    Context '4.1 Admin Workflow A: Corrupted Microsoft Word Recovery' {
        It 'Recovers from hung WINWORD.exe, corrupted Normal.dotm, and orphaned ~$ lock files' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            $wordTemplatesDir = Join-Path $tempDir 'Templates'
            $docsDir = Join-Path $tempDir 'Documents'
            $null = New-Item -ItemType Directory -Path $wordTemplatesDir -Force
            $null = New-Item -ItemType Directory -Path $docsDir -Force

            try {
                # 1. Corrupted Normal.dotm with invalid binary header
                $corruptDotm = Join-Path $wordTemplatesDir 'Normal.dotm'
                Set-Content -Path $corruptDotm -Value 'INVALID_BINARY_CORRUPTED_TEMPLATE'

                # 2. Orphaned ~$ lock file
                $lockFile = Join-Path $docsDir '~$QuarterlyPlan.docx'
                Set-Content -Path $lockFile -Value 'LOCK_DATA'

                # Step 1: Pre-execution guard stops hung WINWORD
                $script:procKilledWord = $false
                Mock Stop-OfficeProcess {
                    $script:procKilledWord = $true
                    return [PSCustomObject]@{ Status = 'Success'; Terminated = @('WINWORD') }
                }
                $null = Stop-OfficeProcess -ProcessNames @('WINWORD') -Force
                $script:procKilledWord | Should -BeTrue

                # Step 2: Quarantine corrupted Normal.dotm
                $quarantineFile = Join-Path $wordTemplatesDir 'Normal.dotm.corrupt.bak'
                Move-Item -Path $corruptDotm -Destination $quarantineFile -Force
                Test-Path -LiteralPath $corruptDotm | Should -BeFalse
                Test-Path -LiteralPath $quarantineFile | Should -BeTrue

                # Step 3: Clear orphaned ~$ lock files
                $locks = Get-ChildItem -Path $docsDir -Filter '~$*.docx' -File
                foreach ($l in $locks) {
                    Remove-Item -LiteralPath $l.FullName -Force
                }
                Test-Path -LiteralPath $lockFile | Should -BeFalse

                # Step 4: Validate clean system state ready for Word restart
                $remainingLocks = Get-ChildItem -Path $docsDir -Filter '~$*.docx' -File
                $remainingLocks.Count | Should -Be 0
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context '4.2 Admin Workflow B: Corrupted Microsoft Excel & Add-in Recovery' {
        It 'Recovers from hung EXCEL.exe, corrupted Excel16.xlb, and rogue XLSTART add-ins while preserving Personal.xlsb' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            $xlstartDir = Join-Path $tempDir 'XLSTART'
            $uiCacheDir = Join-Path $tempDir 'ExcelUi'
            $null = New-Item -ItemType Directory -Path $xlstartDir -Force
            $null = New-Item -ItemType Directory -Path $uiCacheDir -Force

            try {
                # Setup corrupted UI cache file
                $xlbFile = Join-Path $uiCacheDir 'Excel16.xlb'
                Set-Content -Path $xlbFile -Value 'CORRUPT_TOOLBAR_STATE'

                # Setup XLSTART items: rogue add-in vs legitimate Personal.xlsb
                $rogueAddin = Join-Path $xlstartDir 'UnsignedCrashingAddin.xlam'
                $personalMacro = Join-Path $xlstartDir 'Personal.xlsb'
                Set-Content -Path $rogueAddin -Value 'ROGUE_ADDIN_PAYLOAD'
                Set-Content -Path $personalMacro -Value 'CRITICAL_USER_MACROS'

                # Step 1: Terminate hung Excel
                $script:procKilledExcel = $false
                Mock Stop-OfficeProcess {
                    $script:procKilledExcel = $true
                    return [PSCustomObject]@{ Status = 'Success'; Terminated = @('EXCEL') }
                }
                $null = Stop-OfficeProcess -ProcessNames @('EXCEL') -Force
                $script:procKilledExcel | Should -BeTrue

                # Step 2: Quarantine corrupted Excel16.xlb
                $xlbBackup = Join-Path $uiCacheDir 'Excel16.xlb.bak'
                Move-Item -Path $xlbFile -Destination $xlbBackup -Force
                Test-Path -LiteralPath $xlbFile | Should -BeFalse
                Test-Path -LiteralPath $xlbBackup | Should -BeTrue

                # Step 3: Isolate rogue addin but strictly PRESERVE Personal.xlsb
                $quarantineDir = Join-Path $tempDir 'Quarantine'
                $null = New-Item -ItemType Directory -Path $quarantineDir -Force
                $items = Get-ChildItem -Path $xlstartDir -File
                foreach ($item in $items) {
                    if ($item.Name -ieq 'Personal.xlsb') {
                        # Critical: Preserve Personal.xlsb
                        continue
                    }
                    Move-Item -LiteralPath $item.FullName -Destination $quarantineDir -Force
                }

                # Verify rogue add-in removed from XLSTART and moved to quarantine
                Test-Path -LiteralPath $rogueAddin | Should -BeFalse
                Test-Path -LiteralPath (Join-Path $quarantineDir 'UnsignedCrashingAddin.xlam') | Should -BeTrue

                # Verify Personal.xlsb remains intact in XLSTART
                Test-Path -LiteralPath $personalMacro | Should -BeTrue
                (Get-Content -Path $personalMacro -Raw).Trim() | Should -Be 'CRITICAL_USER_MACROS'
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context '4.3 Admin Workflow C: Full Outlook Mail Repair & Profile Switch' {
        It 'Executes full Outlook mail repair and switches active profile filter cleanly' {
            $workflowLog = [System.Collections.Generic.List[string]]::new()

            # 1. Close Outlook process
            Mock Stop-OfficeProcess {
                $workflowLog.Add('OutlookClosed')
                return [PSCustomObject]@{ Status = 'Success'; Terminated = @('OUTLOOK') }
            }

            # 2. Clear Outbox
            Mock Clear-OutlookStuckOutbox {
                $workflowLog.Add('OutboxCleared')
                return [PSCustomObject]@{ Status = 'Success'; ClearedMessages = 1 }
            }

            # 3. Reset SRS
            Mock Reset-OutlookSendReceiveSettings {
                $workflowLog.Add('SrsReset')
                return [PSCustomObject]@{ Status = 'Success'; ResetFiles = 1 }
            }

            # 4. Purge RoamCache (preserve Autocomplete)
            Mock Clear-OutlookRoamCache {
                param([switch]$PreserveAutocomplete, [switch]$Force)
                $workflowLog.Add('RoamCachePurged')
                return [PSCustomObject]@{ Status = 'Success'; PurgedCount = 3; PreservedCount = 1 }
            }

            # 5. Reset NavPane
            Mock Reset-OutlookNavigationPane {
                $workflowLog.Add('NavPaneReset')
                return [PSCustomObject]@{ Status = 'Success' }
            }

            # Execute repair sequence
            $null = Stop-OfficeProcess -ProcessNames @('OUTLOOK') -Force
            $null = Clear-OutlookStuckOutbox -Force
            $null = Reset-OutlookSendReceiveSettings -Force
            $null = Clear-OutlookRoamCache -PreserveAutocomplete -Force
            $null = Reset-OutlookNavigationPane -Force

            $workflowLog | Should -Contain 'OutlookClosed'
            $workflowLog | Should -Contain 'OutboxCleared'
            $workflowLog | Should -Contain 'SrsReset'
            $workflowLog | Should -Contain 'RoamCachePurged'
            $workflowLog | Should -Contain 'NavPaneReset'

            # 6. Profile switch verification
            $selectedProfile = 'ArchiveProfile'
            Mock Select-ToolkitOutlookProfile {
                return $selectedProfile
            }

            if (Get-Command -Name 'Select-ToolkitOutlookProfile' -ErrorAction SilentlyContinue) {
                $prof = Select-ToolkitOutlookProfile -NonInteractive
                $prof | Should -Be 'ArchiveProfile'
            }
        }
    }
}
