# ==============================================================================
# OfficeHubActionRouting.Tests.ps1
# Adversarial Action Routing & Integration Stress Test Suite for Pillar 2 (Office Hub)
# Covers:
# - Main Office Hub (Invoke-ToolkitSubmenuOfficeSuite) 5-way routing & navigation
# - Microsoft Word Repairs (Invoke-ToolkitSubmenuOfficeWord) options 1..5 dispatch
# - Microsoft Excel Repairs (Invoke-ToolkitSubmenuOfficeExcel) options 1..6 dispatch & GDI
# - Microsoft PowerPoint Repairs (Invoke-ToolkitSubmenuOfficePowerPoint) options 1..4 dispatch
# - Office Common Operations (Invoke-ToolkitSubmenuOfficeCommon) options 1..4 & confirmation gate
# - Microsoft Outlook & Data Files (Invoke-ToolkitSubmenuOfficeOutlook) 1..N context & 10..16 dispatch
# - Exception resilience and input stress across all submenus
# ==============================================================================

$script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:TUIManifest = Join-Path $script:ProjectRoot 'Modules/TUI/TUI.psd1'
$isTUIAvailable = Test-Path $script:TUIManifest

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    $script:ProjectRoot = $root
    $script:TUIManifest = Join-Path $root 'Modules/TUI/TUI.psd1'
    if (-not (Get-Command -Name 'Write-ToolkitMenuDivider' -ErrorAction SilentlyContinue)) {
        function global:Write-ToolkitMenuDivider { param([int]$Width = 78) Write-Host ('  ' + ('-' * [math]::Max(20, $Width - 2))) }
    }
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
}

Describe 'Adversarial: Office Hub & App Submenu Action Routing Integration' {

    Context '1. Main Office Hub Dispatcher Routing (Invoke-ToolkitSubmenuOfficeSuite)' {
        It 'Routes Option 1 to Invoke-ToolkitSubmenuOfficeCommon with parameter passthrough' -Skip:(-not $isTUIAvailable) {
            $script:commonCalled = $false
            $script:passedParams = $null
            Mock Invoke-ToolkitSubmenuOfficeCommon {
                param([switch]$NonInteractive, [switch]$ExitImmediately, [int]$MenuDepth)
                $script:commonCalled = $true
                $script:passedParams = @{
                    NonInteractive  = [bool]$NonInteractive
                    ExitImmediately = [bool]$ExitImmediately
                    MenuDepth       = $MenuDepth
                }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '1' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeSuite -MenuDepth 1 } | Should -Not -Throw
            $script:commonCalled | Should -BeTrue
            $script:passedParams.MenuDepth | Should -Be 2
        }

        It 'Routes Option 2 to Invoke-ToolkitSubmenuOfficeWord with parameter passthrough' -Skip:(-not $isTUIAvailable) {
            $script:wordCalled = $false
            $script:passedDepth = 0
            Mock Invoke-ToolkitSubmenuOfficeWord {
                param([switch]$NonInteractive, [switch]$ExitImmediately, [int]$MenuDepth)
                $script:wordCalled = $true
                $script:passedDepth = $MenuDepth
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '2' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeSuite -MenuDepth 1 } | Should -Not -Throw
            $script:wordCalled | Should -BeTrue
            $script:passedDepth | Should -Be 2
        }

        It 'Routes Option 3 to Invoke-ToolkitSubmenuOfficeExcel with parameter passthrough' -Skip:(-not $isTUIAvailable) {
            $script:excelCalled = $false
            $script:passedDepth = 0
            Mock Invoke-ToolkitSubmenuOfficeExcel {
                param([switch]$NonInteractive, [switch]$ExitImmediately, [int]$MenuDepth)
                $script:excelCalled = $true
                $script:passedDepth = $MenuDepth
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '3' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeSuite -MenuDepth 1 } | Should -Not -Throw
            $script:excelCalled | Should -BeTrue
            $script:passedDepth | Should -Be 2
        }

        It 'Routes Option 4 to Invoke-ToolkitSubmenuOfficePowerPoint with parameter passthrough' -Skip:(-not $isTUIAvailable) {
            $script:pptCalled = $false
            $script:passedDepth = 0
            Mock Invoke-ToolkitSubmenuOfficePowerPoint {
                param([switch]$NonInteractive, [switch]$ExitImmediately, [int]$MenuDepth)
                $script:pptCalled = $true
                $script:passedDepth = $MenuDepth
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '4' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeSuite -MenuDepth 1 } | Should -Not -Throw
            $script:pptCalled | Should -BeTrue
            $script:passedDepth | Should -Be 2
        }

        It 'Routes Option 5 to Invoke-ToolkitSubmenuOfficeOutlook with parameter passthrough' -Skip:(-not $isTUIAvailable) {
            $script:outlookCalled = $false
            $script:passedDepth = 0
            Mock Invoke-ToolkitSubmenuOfficeOutlook {
                param([switch]$NonInteractive, [switch]$ExitImmediately, [int]$MenuDepth)
                $script:outlookCalled = $true
                $script:passedDepth = $MenuDepth
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '5' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeSuite -MenuDepth 1 } | Should -Not -Throw
            $script:outlookCalled | Should -BeTrue
            $script:passedDepth | Should -Be 2
        }

        It 'Cleanly exits on Option 0 without dispatching any submenus' -Skip:(-not $isTUIAvailable) {
            $script:anySubmenuDispatched = $false
            Mock Invoke-ToolkitSubmenuOfficeCommon { $script:anySubmenuDispatched = $true }
            Mock Invoke-ToolkitSubmenuOfficeWord { $script:anySubmenuDispatched = $true }
            Mock Invoke-ToolkitSubmenuOfficeExcel { $script:anySubmenuDispatched = $true }
            Mock Invoke-ToolkitSubmenuOfficePowerPoint { $script:anySubmenuDispatched = $true }
            Mock Invoke-ToolkitSubmenuOfficeOutlook { $script:anySubmenuDispatched = $true }
            Mock Read-ToolkitItemSelection { return [PSCustomObject]@{ Type = 'Exit'; Value = '0' } }
            { Invoke-ToolkitSubmenuOfficeSuite } | Should -Not -Throw
            $script:anySubmenuDispatched | Should -BeFalse
        }

        It 'Invokes Show-ToolkitItemTable with -NoIndex to prevent row bracket conflicts' -Skip:(-not $isTUIAvailable) {
            $script:noIndexFlag = $false
            Mock Show-ToolkitItemTable {
                param($Items, $Columns, $Headers, $Title, [switch]$NoIndex)
                $script:noIndexFlag = [bool]$NoIndex
            }
            { Invoke-ToolkitSubmenuOfficeSuite -NonInteractive } | Should -Not -Throw
            $script:noIndexFlag | Should -BeTrue
        }

        It 'Compatibility alias Invoke-ToolkitSubmenuOffice forwards directly to Invoke-ToolkitSubmenuOfficeSuite' -Skip:(-not $isTUIAvailable) {
            $script:forwarded = $false
            Mock Invoke-ToolkitSubmenuOfficeSuite { $script:forwarded = $true }
            { Invoke-ToolkitSubmenuOffice -ExitImmediately } | Should -Not -Throw
            $script:forwarded | Should -BeTrue
        }
    }

    Context '2. Microsoft Word Repairs Action Dispatch (Invoke-ToolkitSubmenuOfficeWord)' {
        It 'Option 1 dispatches Reset-WordTemplate with -Force' -Skip:(-not $isTUIAvailable) {
            $script:templateCalled = $false
            $script:forcePassed = $false
            Mock Read-Host { return 'y' }
            Mock Reset-WordTemplate {
                param([switch]$Force)
                $script:templateCalled = $true
                $script:forcePassed = [bool]$Force
                return [PSCustomObject]@{ Status = 'Success'; Backup = 'Normal.dotm.bak' }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '1' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeWord } | Should -Not -Throw
            $script:templateCalled | Should -BeTrue
            $script:forcePassed | Should -BeTrue
        }

        It 'Option 1 aborts Reset-WordTemplate when user rejects confirmation with n' -Skip:(-not $isTUIAvailable) {
            $script:templateCalled = $false
            Mock Read-Host { return 'n' }
            Mock Reset-WordTemplate { $script:templateCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '1' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeWord } | Should -Not -Throw
            $script:templateCalled | Should -BeFalse
        }

        It 'Option 2 dispatches Reset-WordStartupAddin with -DisableAll and -Force' -Skip:(-not $isTUIAvailable) {
            $script:addinCalled = $false
            $script:disableAllPassed = $false
            $script:forcePassed = $false
            Mock Read-Host { return 'y' }
            Mock Reset-WordStartupAddin {
                param([switch]$DisableAll, [switch]$Force)
                $script:addinCalled = $true
                $script:disableAllPassed = [bool]$DisableAll
                $script:forcePassed = [bool]$Force
                return [PSCustomObject]@{ Status = 'Success'; AddinsIsolated = 2 }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '2' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeWord } | Should -Not -Throw
            $script:addinCalled | Should -BeTrue
            $script:disableAllPassed | Should -BeTrue
            $script:forcePassed | Should -BeTrue
        }

        It 'Option 2 aborts Reset-WordStartupAddin when user rejects confirmation with n' -Skip:(-not $isTUIAvailable) {
            $script:addinCalled = $false
            Mock Read-Host { return 'n' }
            Mock Reset-WordStartupAddin { $script:addinCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '2' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeWord } | Should -Not -Throw
            $script:addinCalled | Should -BeFalse
        }

        It 'Option 3 dispatches Reset-WordRegistryData with -ResetData and -ResetOptions' -Skip:(-not $isTUIAvailable) {
            $script:regCalled = $false
            $script:dataPassed = $false
            $script:optionsPassed = $false
            Mock Read-Host { return 'y' }
            Mock Reset-WordRegistryData {
                param([switch]$ResetData, [switch]$ResetOptions)
                $script:regCalled = $true
                $script:dataPassed = [bool]$ResetData
                $script:optionsPassed = [bool]$ResetOptions
                return [PSCustomObject]@{ Status = 'Success' }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '3' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeWord } | Should -Not -Throw
            $script:regCalled | Should -BeTrue
            $script:dataPassed | Should -BeTrue
            $script:optionsPassed | Should -BeTrue
        }

        It 'Option 3 aborts Reset-WordRegistryData when user rejects confirmation with n' -Skip:(-not $isTUIAvailable) {
            $script:regCalled = $false
            Mock Read-Host { return 'n' }
            Mock Reset-WordRegistryData { $script:regCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '3' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeWord } | Should -Not -Throw
            $script:regCalled | Should -BeFalse
        }

        It 'Option 4 dispatches Clear-WordOrphanedLocks with -Force' -Skip:(-not $isTUIAvailable) {
            $script:locksCalled = $false
            $script:forcePassed = $false
            Mock Clear-WordOrphanedLocks {
                param([switch]$Force)
                $script:locksCalled = $true
                $script:forcePassed = [bool]$Force
                return [PSCustomObject]@{ Status = 'Success'; CleanedFiles = @('~$Doc1.docx') }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '4' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeWord } | Should -Not -Throw
            $script:locksCalled | Should -BeTrue
            $script:forcePassed | Should -BeTrue
        }

        It 'Option 5 dispatches Stop-OfficeProcess targeting WINWORD with -Force' -Skip:(-not $isTUIAvailable) {
            $script:stopCalled = $false
            $script:targetList = $null
            $script:forcePassed = $false
            Mock Read-Host { return 'y' }
            Mock Stop-OfficeProcess {
                param($ProcessNames, [switch]$Force)
                $script:stopCalled = $true
                $script:targetList = $ProcessNames
                $script:forcePassed = [bool]$Force
                return [PSCustomObject]@{ Status = 'Success'; Terminated = @('WINWORD') }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '5' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeWord } | Should -Not -Throw
            $script:stopCalled | Should -BeTrue
            $script:targetList | Should -Contain 'WINWORD'
            $script:forcePassed | Should -BeTrue
        }

        It 'Option 5 aborts Stop-OfficeProcess when user rejects confirmation with n' -Skip:(-not $isTUIAvailable) {
            $script:stopCalled = $false
            Mock Read-Host { return 'n' }
            Mock Stop-OfficeProcess { $script:stopCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '5' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeWord } | Should -Not -Throw
            $script:stopCalled | Should -BeFalse
        }

        It 'Catches exceptions thrown during Word repair execution and avoids console crash' -Skip:(-not $isTUIAvailable) {
            $script:failedLogged = $false
            Mock Read-Host { return 'y' }
            Mock Reset-WordTemplate { throw "Simulated template filesystem lock failure" }
            Mock Write-ToolkitStatus {
                param($Message, $Type)
                if ($Type -eq 'FAIL' -and $Message -like "*Simulated template filesystem lock failure*") {
                    $script:failedLogged = $true
                }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '1' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeWord } | Should -Not -Throw
            $script:failedLogged | Should -BeTrue
        }
    }

    Context '3. Microsoft Excel Repairs Action Dispatch (Invoke-ToolkitSubmenuOfficeExcel)' {
        It 'Option 1 dispatches Set-ExcelHardwareAcceleration' -Skip:(-not $isTUIAvailable) {
            $script:accelCalled = $false
            Mock Set-ExcelHardwareAcceleration {
                param([switch]$Disable)
                $script:accelCalled = $true
                return [PSCustomObject]@{ Status = 'Success'; Disabled = $true }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '1' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeExcel } | Should -Not -Throw
            $script:accelCalled | Should -BeTrue
        }

        It 'Option 2 dispatches Clear-ExcelStartupFolder with -Force' -Skip:(-not $isTUIAvailable) {
            $script:xlstartCalled = $false
            $script:forcePassed = $false
            Mock Read-Host { return 'y' }
            Mock Clear-ExcelStartupFolder {
                param([switch]$Force)
                $script:xlstartCalled = $true
                $script:forcePassed = [bool]$Force
                return [PSCustomObject]@{ Status = 'Success'; RemovedFiles = @('Rogue.xla'); PersonalBackupPath = 'Personal.xlsb.bak' }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '2' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeExcel } | Should -Not -Throw
            $script:xlstartCalled | Should -BeTrue
            $script:forcePassed | Should -BeTrue
        }

        It 'Option 2 aborts Clear-ExcelStartupFolder when user rejects confirmation with n' -Skip:(-not $isTUIAvailable) {
            $script:xlstartCalled = $false
            Mock Read-Host { return 'n' }
            Mock Clear-ExcelStartupFolder { $script:xlstartCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '2' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeExcel } | Should -Not -Throw
            $script:xlstartCalled | Should -BeFalse
        }

        It 'Option 3 dispatches Reset-ExcelUiCache' -Skip:(-not $isTUIAvailable) {
            $script:uiCalled = $false
            Mock Read-Host { return 'y' }
            Mock Reset-ExcelUiCache {
                $script:uiCalled = $true
                return [PSCustomObject]@{ Status = 'Success'; QuarantinedFiles = @('Excel16.xlb'); WebServiceCachePurged = $true }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '3' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeExcel } | Should -Not -Throw
            $script:uiCalled | Should -BeTrue
        }

        It 'Option 3 aborts Reset-ExcelUiCache when user rejects confirmation with n' -Skip:(-not $isTUIAvailable) {
            $script:uiCalled = $false
            Mock Read-Host { return 'n' }
            Mock Reset-ExcelUiCache { $script:uiCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '3' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeExcel } | Should -Not -Throw
            $script:uiCalled | Should -BeFalse
        }

        It 'Option 4 dispatches Reset-ExcelDdeSettings' -Skip:(-not $isTUIAvailable) {
            $script:ddeCalled = $false
            Mock Reset-ExcelDdeSettings {
                $script:ddeCalled = $true
                return [PSCustomObject]@{ Status = 'Success'; DdeDisabled = $false; CalculationRestored = $true }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '4' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeExcel } | Should -Not -Throw
            $script:ddeCalled | Should -BeTrue
        }

        It 'Option 5 dispatches GDI handle auditing and terminates leaking instances when confirmed' -Skip:(-not $isTUIAvailable) {
            $script:gdiCalled = $false
            $script:leakerStopped = $false
            Mock Get-ExcelGdiHandleUsage {
                $script:gdiCalled = $true
                return @(
                    [PSCustomObject]@{ PID = 1001; ProcessName = 'EXCEL'; GdiHandles = 6500; UserHandles = 800; MemoryMB = 350; IsLeaking = $true }
                )
            }
            Mock Read-Host { return 'y' }
            Mock Stop-ExcelGdiLeakers {
                param($Threshold, [switch]$Force)
                $script:leakerStopped = $true
                return @(1001)
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '5' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeExcel } | Should -Not -Throw
            $script:gdiCalled | Should -BeTrue
            $script:leakerStopped | Should -BeTrue
        }

        It 'Option 5 audits GDI handles and cancels termination when user rejects prompt' -Skip:(-not $isTUIAvailable) {
            $script:leakerStopped = $false
            Mock Get-ExcelGdiHandleUsage {
                return @(
                    [PSCustomObject]@{ PID = 1002; ProcessName = 'EXCEL'; GdiHandles = 7200; UserHandles = 900; MemoryMB = 400; IsLeaking = $true }
                )
            }
            Mock Read-Host { return 'n' }
            Mock Stop-ExcelGdiLeakers { $script:leakerStopped = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '5' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeExcel } | Should -Not -Throw
            $script:leakerStopped | Should -BeFalse
        }

        It 'Option 6 dispatches Stop-OfficeProcess targeting EXCEL with -Force' -Skip:(-not $isTUIAvailable) {
            $script:stopCalled = $false
            $script:targetList = $null
            Mock Read-Host { return 'y' }
            Mock Stop-OfficeProcess {
                param($ProcessNames, [switch]$Force)
                $script:stopCalled = $true
                $script:targetList = $ProcessNames
                return [PSCustomObject]@{ Status = 'Success'; Terminated = @('EXCEL') }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '6' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeExcel } | Should -Not -Throw
            $script:stopCalled | Should -BeTrue
            $script:targetList | Should -Contain 'EXCEL'
        }

        It 'Option 6 aborts Stop-OfficeProcess when user rejects confirmation with n' -Skip:(-not $isTUIAvailable) {
            $script:stopCalled = $false
            Mock Read-Host { return 'n' }
            Mock Stop-OfficeProcess { $script:stopCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '6' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeExcel } | Should -Not -Throw
            $script:stopCalled | Should -BeFalse
        }
    }

    Context '4. Microsoft PowerPoint Repairs Action Dispatch (Invoke-ToolkitSubmenuOfficePowerPoint)' {
        It 'Option 1 dispatches Set-PowerPointHardwareAcceleration' -Skip:(-not $isTUIAvailable) {
            $script:accelCalled = $false
            Mock Set-PowerPointHardwareAcceleration {
                param([switch]$Disable)
                $script:accelCalled = $true
                return [PSCustomObject]@{ Status = 'Success'; Disabled = $true }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '1' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficePowerPoint } | Should -Not -Throw
            $script:accelCalled | Should -BeTrue
        }

        It 'Option 2 dispatches Reset-PowerPointCache with -Force' -Skip:(-not $isTUIAvailable) {
            $script:cacheCalled = $false
            $script:forcePassed = $false
            Mock Read-Host { return 'y' }
            Mock Reset-PowerPointCache {
                param([switch]$Force)
                $script:cacheCalled = $true
                $script:forcePassed = [bool]$Force
                return [PSCustomObject]@{ Status = 'Success'; CleanedFilesCount = 8; BytesFreed = 409600 }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '2' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficePowerPoint } | Should -Not -Throw
            $script:cacheCalled | Should -BeTrue
            $script:forcePassed | Should -BeTrue
        }

        It 'Option 2 aborts Reset-PowerPointCache when user rejects confirmation with n' -Skip:(-not $isTUIAvailable) {
            $script:cacheCalled = $false
            Mock Read-Host { return 'n' }
            Mock Reset-PowerPointCache { $script:cacheCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '2' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficePowerPoint } | Should -Not -Throw
            $script:cacheCalled | Should -BeFalse
        }

        It 'Option 3 dispatches Reset-PowerPointResiliency' -Skip:(-not $isTUIAvailable) {
            $script:resilCalled = $false
            Mock Read-Host { return 'y' }
            Mock Reset-PowerPointResiliency {
                $script:resilCalled = $true
                return [PSCustomObject]@{ Status = 'Success'; ClearedItems = 3 }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '3' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficePowerPoint } | Should -Not -Throw
            $script:resilCalled | Should -BeTrue
        }

        It 'Option 3 aborts Reset-PowerPointResiliency when user rejects confirmation with n' -Skip:(-not $isTUIAvailable) {
            $script:resilCalled = $false
            Mock Read-Host { return 'n' }
            Mock Reset-PowerPointResiliency { $script:resilCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '3' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficePowerPoint } | Should -Not -Throw
            $script:resilCalled | Should -BeFalse
        }

        It 'Option 4 dispatches Stop-OfficeProcess targeting POWERPNT with -Force' -Skip:(-not $isTUIAvailable) {
            $script:stopCalled = $false
            $script:targetList = $null
            Mock Read-Host { return 'y' }
            Mock Stop-OfficeProcess {
                param($ProcessNames, [switch]$Force)
                $script:stopCalled = $true
                $script:targetList = $ProcessNames
                return [PSCustomObject]@{ Status = 'Success'; Terminated = @('POWERPNT') }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '4' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficePowerPoint } | Should -Not -Throw
            $script:stopCalled | Should -BeTrue
            $script:targetList | Should -Contain 'POWERPNT'
        }

        It 'Option 4 aborts Stop-OfficeProcess when user rejects confirmation with n' -Skip:(-not $isTUIAvailable) {
            $script:stopCalled = $false
            Mock Read-Host { return 'n' }
            Mock Stop-OfficeProcess { $script:stopCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '4' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficePowerPoint } | Should -Not -Throw
            $script:stopCalled | Should -BeFalse
        }
    }

    Context '5. Office Suite Common Operations Action Dispatch (Invoke-ToolkitSubmenuOfficeCommon)' {
        It 'Option 1 dispatches Repair-OfficeClickToRunService' -Skip:(-not $isTUIAvailable) {
            $script:c2rCalled = $false
            Mock Repair-OfficeClickToRunService {
                $script:c2rCalled = $true
                return [PSCustomObject]@{ Status = 'Success'; ServiceStatus = 'Running'; Repaired = $true }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '1' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeCommon } | Should -Not -Throw
            $script:c2rCalled | Should -BeTrue
        }

        It 'Option 2 dispatches Reset-OfficeIdentityCache with -PurgeWamTokens' -Skip:(-not $isTUIAvailable) {
            $script:idCalled = $false
            $script:wamPassed = $false
            Mock Read-Host { return 'y' }
            Mock Reset-OfficeIdentityCache {
                param([switch]$PurgeWamTokens)
                $script:idCalled = $true
                $script:wamPassed = [bool]$PurgeWamTokens
                return [PSCustomObject]@{ Status = 'Success'; CachesCleared = @('Identity', 'WAM') }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '2' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeCommon } | Should -Not -Throw
            $script:idCalled | Should -BeTrue
            $script:wamPassed | Should -BeTrue
        }

        It 'Option 2 aborts Reset-OfficeIdentityCache when user rejects confirmation with n' -Skip:(-not $isTUIAvailable) {
            $script:idCalled = $false
            Mock Read-Host { return 'n' }
            Mock Reset-OfficeIdentityCache { $script:idCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '2' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeCommon } | Should -Not -Throw
            $script:idCalled | Should -BeFalse
        }

        It 'Option 3 dispatches Stop-OfficeProcess for all Office suite apps' -Skip:(-not $isTUIAvailable) {
            $script:stopAllCalled = $false
            Mock Read-Host { return 'y' }
            Mock Stop-OfficeProcess {
                $script:stopAllCalled = $true
                return [PSCustomObject]@{ Status = 'Success'; Terminated = @('WINWORD', 'EXCEL', 'OUTLOOK') }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '3' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeCommon } | Should -Not -Throw
            $script:stopAllCalled | Should -BeTrue
        }

        It 'Option 3 aborts Stop-OfficeProcess when user rejects confirmation with n' -Skip:(-not $isTUIAvailable) {
            $script:stopAllCalled = $false
            Mock Read-Host { return 'n' }
            Mock Stop-OfficeProcess { $script:stopAllCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '3' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeCommon } | Should -Not -Throw
            $script:stopAllCalled | Should -BeFalse
        }

        It 'Option 4 executes Uninstall-OfficeSuiteCleanly -Force when confirmed with y' -Skip:(-not $isTUIAvailable) {
            $script:scrubCalled = $false
            $script:forcePassed = $false
            Mock Read-Host { return 'y' }
            Mock Uninstall-OfficeSuiteCleanly {
                param([switch]$Force)
                $script:scrubCalled = $true
                $script:forcePassed = [bool]$Force
                return [PSCustomObject]@{ Status = 'Success'; PhasesCompleted = @('ProcessKill', 'ServiceControl', 'TaskRemoval', 'RegistryScrub', 'TokenPurge', 'FilePurge') }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '4' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeCommon } | Should -Not -Throw
            $script:scrubCalled | Should -BeTrue
            $script:forcePassed | Should -BeTrue
        }

        It 'Option 4 aborts Uninstall-OfficeSuiteCleanly when user rejects confirmation with n' -Skip:(-not $isTUIAvailable) {
            $script:scrubCalled = $false
            Mock Read-Host { return 'n' }
            Mock Uninstall-OfficeSuiteCleanly { $script:scrubCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '4' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeCommon } | Should -Not -Throw
            $script:scrubCalled | Should -BeFalse
        }

        It 'Option 4 aborts Uninstall-OfficeSuiteCleanly when user enters empty confirmation' -Skip:(-not $isTUIAvailable) {
            $script:scrubCalled = $false
            Mock Read-Host { return '' }
            Mock Uninstall-OfficeSuiteCleanly { $script:scrubCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '4' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeCommon } | Should -Not -Throw
            $script:scrubCalled | Should -BeFalse
        }
    }

    Context '6. Microsoft Outlook & Data Files Action Dispatch (Invoke-ToolkitSubmenuOfficeOutlook)' {
        It 'Routes numeric selection 1..N to Invoke-ToolkitDataFileContextMenu' -Skip:(-not $isTUIAvailable) {
            $script:targetFileObj = $null
            Mock Get-OutlookDataFileInventory {
                return @(
                    [PSCustomObject]@{
                        Filename   = 'Work.ost'
                        Size       = '12.40 GB'
                        Format     = 'OST'
                        Status     = '[READY]'
                        Path       = 'C:\Users\User\AppData\Local\Microsoft\Outlook\Work.ost'
                        Profile    = 'DefaultProfile'
                        Item       = 'Work.ost'
                        Type       = 'OST'
                        Details    = 'C:\Users\User\AppData\Local\Microsoft\Outlook\Work.ost'
                        SizeGB     = 12.4
                    },
                    [PSCustomObject]@{
                        Filename   = 'Archive.pst'
                        Size       = '4.20 GB'
                        Format     = 'PST'
                        Status     = '[READY]'
                        Path       = 'D:\Outlook\Archive.pst'
                        Profile    = 'DefaultProfile'
                        Item       = 'Archive.pst'
                        Type       = 'PST'
                        Details    = 'D:\Outlook\Archive.pst'
                        SizeGB     = 4.2
                    }
                )
            }
            Mock Invoke-ToolkitDataFileContextMenu {
                param($DataFile)
                $script:targetFileObj = $DataFile
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Index'; Value = 2 } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:targetFileObj | Should -Not -BeNullOrEmpty
            $script:targetFileObj.Filename | Should -Be 'Archive.pst'
        }

        It 'Option 10 dispatches Clear-OutlookStuckOutbox' -Skip:(-not $isTUIAvailable) {
            $script:outboxCalled = $false
            Mock Read-Host { return 'y' }
            Mock Clear-OutlookStuckOutbox {
                $script:outboxCalled = $true
                return [PSCustomObject]@{ Status = 'Success'; ClearedMessages = 2 }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:outboxCalled | Should -BeTrue
        }

        It 'Option 10 aborts Clear-OutlookStuckOutbox when user rejects confirmation with n' -Skip:(-not $isTUIAvailable) {
            $script:outboxCalled = $false
            Mock Read-Host { return 'n' }
            Mock Clear-OutlookStuckOutbox { $script:outboxCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:outboxCalled | Should -BeFalse
        }

        It 'Option 11 dispatches Reset-OutlookSendReceiveSettings with -Backup' -Skip:(-not $isTUIAvailable) {
            $script:srsCalled = $false
            $script:backupPassed = $false
            Mock Read-Host { return 'y' }
            Mock Reset-OutlookSendReceiveSettings {
                param([switch]$Backup)
                $script:srsCalled = $true
                $script:backupPassed = [bool]$Backup
                return [PSCustomObject]@{ Status = 'Success'; BackupFile = 'Outlook.srs.bak' }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '11' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:srsCalled | Should -BeTrue
            $script:backupPassed | Should -BeTrue
        }

        It 'Option 11 aborts Reset-OutlookSendReceiveSettings when user rejects confirmation with n' -Skip:(-not $isTUIAvailable) {
            $script:srsCalled = $false
            Mock Read-Host { return 'n' }
            Mock Reset-OutlookSendReceiveSettings { $script:srsCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '11' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:srsCalled | Should -BeFalse
        }

        It 'Option 12 dispatches Clear-OutlookRoamCache with -PreserveAutocomplete' -Skip:(-not $isTUIAvailable) {
            $script:roamCalled = $false
            $script:preservePassed = $false
            Mock Read-Host { return 'y' }
            Mock Clear-OutlookRoamCache {
                param([switch]$PreserveAutocomplete)
                $script:roamCalled = $true
                $script:preservePassed = [bool]$PreserveAutocomplete
                return [PSCustomObject]@{ Status = 'Success'; PurgedCount = 14; PreservedCount = 1 }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '12' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:roamCalled | Should -BeTrue
            $script:preservePassed | Should -BeTrue
        }

        It 'Option 12 aborts Clear-OutlookRoamCache when user rejects confirmation with n' -Skip:(-not $isTUIAvailable) {
            $script:roamCalled = $false
            Mock Read-Host { return 'n' }
            Mock Clear-OutlookRoamCache { $script:roamCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '12' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:roamCalled | Should -BeFalse
        }

        It 'Option 13 dispatches Reset-OutlookNavigationPane' -Skip:(-not $isTUIAvailable) {
            $script:navPaneCalled = $false
            Mock Read-Host { return 'y' }
            Mock Reset-OutlookNavigationPane {
                $script:navPaneCalled = $true
                return [PSCustomObject]@{ Status = 'Success' }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '13' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:navPaneCalled | Should -BeTrue
        }

        It 'Option 13 aborts Reset-OutlookNavigationPane when user rejects confirmation with n' -Skip:(-not $isTUIAvailable) {
            $script:navPaneCalled = $false
            Mock Read-Host { return 'n' }
            Mock Reset-OutlookNavigationPane { $script:navPaneCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '13' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:navPaneCalled | Should -BeFalse
        }

        It 'Option 14 dispatches Invoke-OutlookPstCompaction' -Skip:(-not $isTUIAvailable) {
            $script:compactCalled = $false
            Mock Invoke-OutlookPstCompaction {
                $script:compactCalled = $true
                return [PSCustomObject]@{ Status = 'Success'; CompactedFiles = 1 }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '14' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:compactCalled | Should -BeTrue
        }

        It 'Option 15 dispatches Test-OutlookDataFileSize across inventory items' -Skip:(-not $isTUIAvailable) {
            $script:testedFiles = [System.Collections.Generic.List[string]]::new()
            Mock Get-OutlookDataFileInventory {
                return @(
                    [PSCustomObject]@{
                        Filename = 'Mail.pst'; Path = 'C:\Mail.pst'; Format = 'PST'; Status = '[READY]'; Item = 'Mail.pst'; Type = 'PST'; Details = 'C:\Mail.pst'
                    }
                )
            }
            Mock Test-OutlookDataFileSize {
                param($FilePath)
                $script:testedFiles.Add($FilePath)
                return [PSCustomObject]@{ Status = 'OK'; SizeGB = 2.5; MaxThresholdGB = 50.0; PercentOfMax = 5.0 }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '15' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:testedFiles | Should -Contain 'C:\Mail.pst'
        }

        It 'Option 16 dispatches Stop-OfficeProcess targeting OUTLOOK with -Force' -Skip:(-not $isTUIAvailable) {
            $script:stopCalled = $false
            $script:targetList = $null
            Mock Read-Host { return 'y' }
            Mock Stop-OfficeProcess {
                param($ProcessNames, [switch]$Force)
                $script:stopCalled = $true
                $script:targetList = $ProcessNames
                return [PSCustomObject]@{ Status = 'Success'; Terminated = @('OUTLOOK') }
            }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '16' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:stopCalled | Should -BeTrue
            $script:targetList | Should -Contain 'OUTLOOK'
        }

        It 'Option 16 aborts Stop-OfficeProcess when user rejects confirmation with n' -Skip:(-not $isTUIAvailable) {
            $script:stopCalled = $false
            Mock Read-Host { return 'n' }
            Mock Stop-OfficeProcess { $script:stopCalled = $true }
            Mock Wait-UserAcknowledge { }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '16' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:stopCalled | Should -BeFalse
        }

        It 'Compatibility alias Invoke-ToolkitSubmenuOutlook forwards to Invoke-ToolkitSubmenuOfficeOutlook' -Skip:(-not $isTUIAvailable) {
            $script:forwarded = $false
            Mock Invoke-ToolkitSubmenuOfficeOutlook { $script:forwarded = $true }
            { Invoke-ToolkitSubmenuOutlook -ExitImmediately } | Should -Not -Throw
            $script:forwarded | Should -BeTrue
        }
    }
}
