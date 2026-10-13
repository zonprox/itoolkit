# ==============================================================================
# TUI.Tests.ps1
# Unit test suite for Modules/TUI
# Covers: Show-ToolkitHeader, Show-ToolkitMenuOption, Read-ToolkitMenuChoice,
# Write-ToolkitStatus, Start-IToolkitMenu, and the 5 Enterprise Core Pillars.
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
    if (-not (Get-Command -Name 'Get-CimInstance' -CommandType Cmdlet -ErrorAction SilentlyContinue)) {
        function global:Get-CimInstance { param($ClassName) }
    }
    $tuiMod = Get-Module -Name 'TUI'
    if ($tuiMod) {
        & $tuiMod {
            if (-not (Get-Command -Name 'Get-CimInstance' -CommandType Cmdlet -ErrorAction SilentlyContinue)) {
                function script:Get-CimInstance { param($ClassName) }
            }
        }
    }
}

Describe 'Unit: Interactive Console TUI Menu Module' {

    Context 'Header & Banner Rendering' {
        It 'Show-ToolkitHeader renders banner title and subtitle' -Skip:(-not $isTUIAvailable) {
            { Show-ToolkitHeader -Title 'IToolkit Main Menu' -Subtitle 'Enterprise IT Support' } | Should -Not -Throw
        }
    }

    Context 'Menu Options & Choice Reading' {
        It 'Show-ToolkitMenuOption displays menu key and label' -Skip:(-not $isTUIAvailable) {
            { Show-ToolkitMenuOption -Key '1' -Label 'System Health & Maintenance' -Status 'OK' } | Should -Not -Throw
        }

        It 'Read-ToolkitMenuChoice accepts valid key choice' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '1' }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', '0')
            $choice | Should -Be '1'
        }

        It 'Read-ToolkitMenuChoice rejects letter exit keys and requires numeric 0' -Skip:(-not $isTUIAvailable) {
            $script:attemptCount = 0
            Mock Read-Host {
                $script:attemptCount++
                if ($script:attemptCount -eq 1) { return 'q' }
                return '0'
            }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', '0')
            $choice | Should -Be '0'
            $script:attemptCount | Should -Be 2
        }

        It 'Read-ToolkitMenuChoice returns Default value when input is empty string' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '' }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', '0') -Default '0'
            $choice | Should -Be '0'
        }

        It 'Read-ToolkitMenuChoice returns normalized Default value when Default is bracketed [1]' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '' }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', '0') -Default '[1]'
            $choice | Should -Be '1'
        }

        It 'Read-ToolkitMenuChoice safely handles null/EOF without throwing' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return $null }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', '0')
            $choice | Should -Be ''
        }

        It 'Read-ToolkitMenuChoice terminates after max attempts on repeated empty input' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '' }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', '0')
            $choice | Should -Be ''
        }

        It 'Read-ToolkitMenuChoice retries after invalid input and returns subsequent valid choice' -Skip:(-not $isTUIAvailable) {
            $script:attemptCount = 0
            Mock Read-Host {
                $script:attemptCount++
                if ($script:attemptCount -eq 1) { return 'invalid_choice' }
                return '2'
            }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', '0')
            $choice | Should -Be '2'
        }

        It 'Read-ToolkitMenuChoice with default valid keys rejects letter inputs and accepts numeric 0' -Skip:(-not $isTUIAvailable) {
            $script:attemptCount = 0
            Mock Read-Host {
                $script:attemptCount++
                if ($script:attemptCount -eq 1) { return 'Q' }
                return '0'
            }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option'
            $choice | Should -Be '0'
            $script:attemptCount | Should -Be 2
        }

        It 'Read-ToolkitMenuChoice accepts bracketed numeric input and returns canonical key' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '[1]' }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', '0')
            $choice | Should -Be '1'
        }

        It 'Read-ToolkitMenuChoice accepts bracketed exit [0] and returns 0' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '[0]' }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', '0')
            $choice | Should -Be '0'
        }
    }

    Context 'Start-IToolkitMenu Execution Modes & Non-Interactive Contract' {
        It 'Start-IToolkitMenu returns immediately when -ExitImmediately is specified' -Skip:(-not $isTUIAvailable) {
            { Start-IToolkitMenu -ExitImmediately } | Should -Not -Throw
        }

        It 'Start-IToolkitMenu handles -NonInteractive without MenuOption cleanly' -Skip:(-not $isTUIAvailable) {
            { Start-IToolkitMenu -NonInteractive } | Should -Not -Throw
        }

        It 'Start-IToolkitMenu handles -NonInteractive with Exit options (0, Q, and X)' -Skip:(-not $isTUIAvailable) {
            { Start-IToolkitMenu -MenuOption '0' -NonInteractive } | Should -Not -Throw
            { Start-IToolkitMenu -MenuOption 'Q' -NonInteractive } | Should -Not -Throw
            { Start-IToolkitMenu -MenuOption 'X' -NonInteractive } | Should -Not -Throw
        }

        It 'Start-IToolkitMenu accepts bracketed menu options (e.g. [1], [0]) and routes cleanly' -Skip:(-not $isTUIAvailable) {
            $script:healthCalled = $false
            Mock Invoke-ToolkitSubmenuSystemHealth { $script:healthCalled = $true }
            { Start-IToolkitMenu -MenuOption '[1]' -NonInteractive } | Should -Not -Throw
            $script:healthCalled | Should -BeTrue
            { Start-IToolkitMenu -MenuOption '[0]' -NonInteractive } | Should -Not -Throw
        }

        It 'Start-IToolkitMenu lists category options without prompting when -NonInteractive is specified' -Skip:(-not $isTUIAvailable) {
            $categories = @('1', '2', '3', '4', '5', '6', '7', '8', '9', 'N')
            foreach ($cat in $categories) {
                { Start-IToolkitMenu -MenuOption $cat -NonInteractive } | Should -Not -Throw
            }
        }

        It 'Submenus terminate immediately on EOF ($null) without infinite looping' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return $null }
            $categories = @('1', '2', '3', '4', '5')
            foreach ($cat in $categories) {
                { Start-IToolkitMenu -MenuOption $cat } | Should -Not -Throw
            }
        }

        It 'Submenus terminate immediately on empty string input fallback without looping' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '' }
            $categories = @('1', '2', '3', '4', '5')
            foreach ($cat in $categories) {
                { Start-IToolkitMenu -MenuOption $cat } | Should -Not -Throw
            }
        }

        It 'Submenus exit back to caller when Back key (0) is selected' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '0' }
            $categories = @('1', '2', '3', '4', '5')
            foreach ($cat in $categories) {
                { Start-IToolkitMenu -MenuOption $cat } | Should -Not -Throw
            }
        }
    }

    Context 'Submenu Invocations: Non-Interactive & Immediate Exit Contract' {
        $submenus = @(
            @{ Name = 'SystemHealth';         Command = 'Invoke-ToolkitSubmenuSystemHealth' },
            @{ Name = 'OfficeSuite';          Command = 'Invoke-ToolkitSubmenuOfficeSuite' },
            @{ Name = 'Connectivity';         Command = 'Invoke-ToolkitSubmenuConnectivity' },
            @{ Name = 'IdentityBackup';       Command = 'Invoke-ToolkitSubmenuIdentityBackup' },
            @{ Name = 'SoftwareOptimization'; Command = 'Invoke-ToolkitSubmenuSoftwareOptimization' }
        )

        It '<Name> renders and terminates cleanly with -NonInteractive' -TestCases $submenus -Skip:(-not $isTUIAvailable) {
            param($Name, $Command)
            { & $Command -NonInteractive } | Should -Not -Throw
        }

        It '<Name> returns immediately when -ExitImmediately is specified' -TestCases $submenus -Skip:(-not $isTUIAvailable) {
            param($Name, $Command)
            { & $Command -ExitImmediately } | Should -Not -Throw
        }
    }

    Context 'Headless Menu Invocation & Telemetry Extraction' {
        It 'Start-IToolkitMenu extracts system telemetry without prompting for user interaction' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { throw "Read-Host should never be invoked in non-interactive headless mode" }
            { Start-IToolkitMenu -NonInteractive } | Should -Not -Throw
        }

        It 'Start-IToolkitMenu extracts category telemetry across all submenus in headless mode' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { throw "Read-Host should never be invoked in non-interactive headless mode" }
            $categories = @('1', '2', '3', '4', '5')
            foreach ($cat in $categories) {
                { Start-IToolkitMenu -MenuOption $cat -NonInteractive } | Should -Not -Throw
            }
        }
    }

    Context 'Status Indicators' {
        It 'Write-ToolkitStatus prints OK, WARN, and FAIL indicators' -Skip:(-not $isTUIAvailable) {
            { Write-ToolkitStatus -Message 'Operation succeeded' -Type 'OK' } | Should -Not -Throw
            { Write-ToolkitStatus -Message 'Drive space low' -Type 'WARN' } | Should -Not -Throw
            { Write-ToolkitStatus -Message 'Spooler crashed' -Type 'FAIL' } | Should -Not -Throw
        }
    }

    Context 'Deep Hardware & System Telemetry Collection & UI/UX' {
        BeforeEach {
            if (Get-Command -Name 'Clear-ToolkitTelemetryCache' -ErrorAction SilentlyContinue) {
                Clear-ToolkitTelemetryCache
            }
        }

        It 'Get-MainSystemInfoLines returns formatted array containing all required telemetry sections' -Skip:(-not $isTUIAvailable) {
            $lines = Get-MainSystemInfoLines
            $lines.Count | Should -BeGreaterOrEqual 8
            $lines[0] | Should -Match '^OS & Build\s*:'
            $lines[1] | Should -Match '^Hardware Model\s*:'
            $lines[2] | Should -Match '^Processor & RAM\s*:'
            $lines[3] | Should -Match '^Storage Space\s*:'
        }
    }

    Context 'Show-ToolkitItemTable Tabular Display Engine' {
        It 'Show-ToolkitItemTable renders tabular format without error' -Skip:(-not $isTUIAvailable) {
            $items = @(
                [PSCustomObject]@{ Name = 'TestItem1'; Status = 'OK'; Details = 'Detail 1' },
                [PSCustomObject]@{ Name = 'TestItem2'; Status = 'WARN'; Details = 'Detail 2' }
            )
            { Show-ToolkitItemTable -Items $items -Columns @('Name', 'Status', 'Details') -Title 'Test Table' } | Should -Not -Throw
        }

        It 'Show-ToolkitItemTable suppresses row index prefixes [1], [2] when -NoIndex is supplied' -Skip:(-not $isTUIAvailable) {
            $capturedLines = [System.Collections.Generic.List[string]]::new()
            Mock Write-Host {
                param($Object)
                if ($null -ne $Object) {
                    $capturedLines.Add("$Object")
                }
            }
            $items = @(
                [PSCustomObject]@{ Name = 'TestItem1'; Status = 'OK'; Details = 'Detail 1' },
                [PSCustomObject]@{ Name = 'TestItem2'; Status = 'WARN'; Details = 'Detail 2' }
            )
            Show-ToolkitItemTable -Items $items -Columns @('Name', 'Status', 'Details') -Title 'Test Table' -NoIndex

            $allOutput = $capturedLines -join "`n"
            $allOutput | Should -Not -Match '\[1\]'
            $allOutput | Should -Not -Match '\[2\]'
        }

        It 'Show-ToolkitItemTable renders row index prefixes [1], [2] when -NoIndex is omitted' -Skip:(-not $isTUIAvailable) {
            $capturedLines = [System.Collections.Generic.List[string]]::new()
            Mock Write-Host {
                param($Object)
                if ($null -ne $Object) {
                    $capturedLines.Add("$Object")
                }
            }
            $items = @(
                [PSCustomObject]@{ Name = 'TestItem1'; Status = 'OK'; Details = 'Detail 1' },
                [PSCustomObject]@{ Name = 'TestItem2'; Status = 'WARN'; Details = 'Detail 2' }
            )
            Show-ToolkitItemTable -Items $items -Columns @('Name', 'Status', 'Details') -Title 'Test Table'

            $allOutput = $capturedLines -join "`n"
            $allOutput | Should -Match '\[1\]'
            $allOutput | Should -Match '\[2\]'
        }
    }

    Context 'Read-ToolkitItemSelection Input Parsing & Safeguards' {
        It 'Read-ToolkitItemSelection parses hotkey input cleanly' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '9' }
            $res = Read-ToolkitItemSelection -MaxIndex 5 -ValidHotkeys @('9', '10') -Prompt 'Select'
            $res.Type | Should -Be 'Hotkey'
            $res.Value | Should -Be '9'
        }

        It 'Read-ToolkitItemSelection parses index input cleanly' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '3' }
            $res = Read-ToolkitItemSelection -MaxIndex 5 -ValidHotkeys @('0') -Prompt 'Select'
            $res.Type | Should -Be 'Index'
            $res.Value | Should -Be 3
        }

        It 'Read-ToolkitItemSelection handles exit keys cleanly' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '0' }
            $res = Read-ToolkitItemSelection -MaxIndex 5 -ValidHotkeys @('1', '2') -Prompt 'Select'
            $res.Type | Should -Be 'Exit'
            $res.Value | Should -Be '0'
        }

        It 'Read-ToolkitItemSelection rejects letter exit keys and requires numeric 0' -Skip:(-not $isTUIAvailable) {
            $script:attemptCount = 0
            Mock Read-Host {
                $script:attemptCount++
                if ($script:attemptCount -eq 1) { return 'Q' }
                return '0'
            }
            $res = Read-ToolkitItemSelection -MaxIndex 5 -ValidHotkeys @('1', '2') -Prompt 'Select'
            $res.Type | Should -Be 'Exit'
            $res.Value | Should -Be '0'
            $script:attemptCount | Should -Be 2
        }

        It 'Read-ToolkitItemSelection accepts bracketed numeric exit [0] immediately without retry warnings' -Skip:(-not $isTUIAvailable) {
            $script:attemptCount = 0
            Mock Read-Host {
                $script:attemptCount++
                return '[0]'
            }
            $res = Read-ToolkitItemSelection -MaxIndex 5 -ValidHotkeys @('1', '2') -Prompt 'Select'
            $res.Type | Should -Be 'Exit'
            $res.Value | Should -Be '0'
            $script:attemptCount | Should -Be 1
        }
    }

    Context 'Item-Centric Submenu Matrix Non-Interactive & Immediate Exit Verification' {
        $submenus = @(
            @{ Name = 'SystemHealth';         Command = 'Invoke-ToolkitSubmenuSystemHealth' },
            @{ Name = 'OfficeSuite';          Command = 'Invoke-ToolkitSubmenuOfficeSuite' },
            @{ Name = 'Connectivity';         Command = 'Invoke-ToolkitSubmenuConnectivity' },
            @{ Name = 'IdentityBackup';       Command = 'Invoke-ToolkitSubmenuIdentityBackup' },
            @{ Name = 'SoftwareOptimization'; Command = 'Invoke-ToolkitSubmenuSoftwareOptimization' }
        )

        It '<Name>: Terminates immediately without processing when -ExitImmediately is passed' -TestCases $submenus -Skip:(-not $isTUIAvailable) {
            param($Name, $Command)
            { & $Command -ExitImmediately } | Should -Not -Throw
        }

        It '<Name>: Renders non-interactively and NEVER calls Read-Host' -TestCases $submenus -Skip:(-not $isTUIAvailable) {
            param($Name, $Command)
            Mock Read-Host { throw "CRITICAL: Read-Host must not be called in non-interactive mode for $Name!" }
            Mock Read-ToolkitMenuChoice { throw "CRITICAL: Read-ToolkitMenuChoice must not be called in non-interactive mode for $Name!" }
            Mock Read-ToolkitItemSelection { throw "CRITICAL: Read-ToolkitItemSelection must not be called in non-interactive mode for $Name!" }

            { & $Command -NonInteractive } | Should -Not -Throw
        }

        It 'SystemHealth: Invokes Show-ToolkitItemTable with -NoIndex to prevent row index collisions' -Skip:(-not $isTUIAvailable) {
            $script:passedNoIndex = $false
            Mock Show-ToolkitItemTable {
                param($Items, $Columns, $Headers, $Title, [switch]$NoIndex)
                $script:passedNoIndex = [bool]$NoIndex
            }
            { Invoke-ToolkitSubmenuSystemHealth -NonInteractive } | Should -Not -Throw
            $script:passedNoIndex | Should -BeTrue
        }

        $entitySubmenus = @(
            @{ Name = 'OfficeSuite';          Command = 'Invoke-ToolkitSubmenuOfficeSuite' },
            @{ Name = 'Connectivity';         Command = 'Invoke-ToolkitSubmenuConnectivity' },
            @{ Name = 'IdentityBackup';       Command = 'Invoke-ToolkitSubmenuIdentityBackup' },
            @{ Name = 'SoftwareOptimization'; Command = 'Invoke-ToolkitSubmenuSoftwareOptimization' }
        )

        It '<Name>: Invokes Show-ToolkitItemTable without -NoIndex to render selectable row numbers [1..N]' -TestCases $entitySubmenus -Skip:(-not $isTUIAvailable) {
            param($Name, $Command)
            $script:passedNoIndex = $true
            Mock Show-ToolkitItemTable {
                param($Items, $Columns, $Headers, $Title, [switch]$NoIndex)
                $script:passedNoIndex = [bool]$NoIndex
            }
            { & $Command -NonInteractive } | Should -Not -Throw
            $script:passedNoIndex | Should -BeFalse
        }
    }

    Context '5 Enterprise Core Pillars Main Menu Architecture & Router Verification' {
        It 'Start-IToolkitMenu details panel exposes exactly 5 Core Pillars' -Skip:(-not $isTUIAvailable) {
            $script:capturedMainDetails = $null
            Mock Show-ToolkitDetailPanel {
                param($Details, $NavActions, $Title)
                $script:capturedMainDetails = $Details
            }
            { Start-IToolkitMenu -NonInteractive } | Should -Not -Throw
            $script:capturedMainDetails | Should -Not -BeNullOrEmpty
            $script:capturedMainDetails.Count | Should -Be 5

            $p1 = $script:capturedMainDetails | Where-Object { $_.Key -eq '1' }
            $p1.Action | Should -Be 'System Health & Maintenance'

            $p2 = $script:capturedMainDetails | Where-Object { $_.Key -eq '2' }
            $p2.Action | Should -Be 'Office & Productivity Suite'

            $p3 = $script:capturedMainDetails | Where-Object { $_.Key -eq '3' }
            $p3.Action | Should -Be 'Network & Connectivity'

            $p4 = $script:capturedMainDetails | Where-Object { $_.Key -eq '4' }
            $p4.Action | Should -Be 'Accounts, Identity & Backup'

            $p5 = $script:capturedMainDetails | Where-Object { $_.Key -eq '5' }
            $p5.Action | Should -Be 'Software & System Optimization'
        }

        It 'Start-IToolkitMenu interactive loop includes valid keys 1-5, 9, 0' -Skip:(-not $isTUIAvailable) {
            $script:capturedValidKeys = $null
            Mock Read-ToolkitMenuChoice {
                param($Prompt, $ValidKeys, $Default)
                $script:capturedValidKeys = $ValidKeys
                return '0'
            }
            { Start-IToolkitMenu } | Should -Not -Throw
            $script:capturedValidKeys | Should -Not -BeNullOrEmpty
            $script:capturedValidKeys | Should -Contain '1'
            $script:capturedValidKeys | Should -Contain '2'
            $script:capturedValidKeys | Should -Contain '3'
            $script:capturedValidKeys | Should -Contain '4'
            $script:capturedValidKeys | Should -Contain '5'
            $script:capturedValidKeys | Should -Contain '9'
            $script:capturedValidKeys | Should -Contain '0'
            $script:capturedValidKeys | Should -Not -Contain 'R'
            $script:capturedValidKeys | Should -Not -Contain 'Q'
            $script:capturedValidKeys | Should -Not -Contain 'X'
        }

        It 'Start-IToolkitMenu routes Option 1 to Invoke-ToolkitSubmenuSystemHealth' -Skip:(-not $isTUIAvailable) {
            $script:healthCalled = $false
            Mock Invoke-ToolkitSubmenuSystemHealth { $script:healthCalled = $true }
            { Start-IToolkitMenu -MenuOption '1' -NonInteractive } | Should -Not -Throw
            $script:healthCalled | Should -BeTrue
        }

        It 'Start-IToolkitMenu routes Option 2 to Invoke-ToolkitSubmenuOfficeSuite' -Skip:(-not $isTUIAvailable) {
            $script:officeCalled = $false
            Mock Invoke-ToolkitSubmenuOfficeSuite { $script:officeCalled = $true }
            { Start-IToolkitMenu -MenuOption '2' -NonInteractive } | Should -Not -Throw
            $script:officeCalled | Should -BeTrue
        }

        It 'Start-IToolkitMenu routes Option 3 to Invoke-ToolkitSubmenuConnectivity' -Skip:(-not $isTUIAvailable) {
            $script:connCalled = $false
            Mock Invoke-ToolkitSubmenuConnectivity { $script:connCalled = $true }
            { Start-IToolkitMenu -MenuOption '3' -NonInteractive } | Should -Not -Throw
            $script:connCalled | Should -BeTrue
        }

        It 'Start-IToolkitMenu routes Option 4 to Invoke-ToolkitSubmenuIdentityBackup' -Skip:(-not $isTUIAvailable) {
            $script:idCalled = $false
            Mock Invoke-ToolkitSubmenuIdentityBackup { $script:idCalled = $true }
            { Start-IToolkitMenu -MenuOption '4' -NonInteractive } | Should -Not -Throw
            $script:idCalled | Should -BeTrue
        }

        It 'Start-IToolkitMenu routes Option 5 to Invoke-ToolkitSubmenuSoftwareOptimization' -Skip:(-not $isTUIAvailable) {
            $script:softCalled = $false
            Mock Invoke-ToolkitSubmenuSoftwareOptimization { $script:softCalled = $true }
            { Start-IToolkitMenu -MenuOption '5' -NonInteractive } | Should -Not -Throw
            $script:softCalled | Should -BeTrue
        }

        It 'Start-IToolkitMenu gracefully maps legacy options (6, 7, 8, N) to corresponding Core Pillars' -Skip:(-not $isTUIAvailable) {
            $script:calls = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-ToolkitSubmenuSystemHealth { $script:calls.Add('Health') }
            Mock Invoke-ToolkitSubmenuConnectivity { $script:calls.Add('Conn') }
            Mock Invoke-ToolkitSubmenuSoftwareOptimization { $script:calls.Add('Soft') }

            Start-IToolkitMenu -MenuOption '6' -NonInteractive
            Start-IToolkitMenu -MenuOption '7' -NonInteractive
            Start-IToolkitMenu -MenuOption '8' -NonInteractive
            Start-IToolkitMenu -MenuOption 'N' -NonInteractive
            Start-IToolkitMenu -MenuOption 'NETWORK' -NonInteractive

            $script:calls | Should -Contain 'Soft'
            $script:calls | Should -Contain 'Health'
            $script:calls | Should -Contain 'Conn'
        }

        It 'Start-IToolkitMenu routes Option 9 to Clear-ToolkitTelemetryCache instead of Invoke-ToolkitSubmenuSystemHealth' -Skip:(-not $isTUIAvailable) {
            $script:cacheCleared = $false
            $script:healthCalled = $false
            Mock Clear-ToolkitTelemetryCache { $script:cacheCleared = $true }
            Mock Invoke-ToolkitSubmenuSystemHealth { $script:healthCalled = $true }

            Start-IToolkitMenu -MenuOption '9' -NonInteractive

            $script:cacheCleared | Should -BeTrue
            $script:healthCalled | Should -BeFalse
        }

        It 'Start-IToolkitMenu routes bracketed Option [9] to Clear-ToolkitTelemetryCache' -Skip:(-not $isTUIAvailable) {
            $script:cacheCleared = $false
            Mock Clear-ToolkitTelemetryCache { $script:cacheCleared = $true }

            Start-IToolkitMenu -MenuOption '[9]' -NonInteractive

            $script:cacheCleared | Should -BeTrue
        }

        It 'Start-IToolkitMenu interactive choices 1-5 dispatch to corresponding Core Pillars' -Skip:(-not $isTUIAvailable) {
            $dispatches = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-ToolkitSubmenuSystemHealth { $dispatches.Add('P1') }
            Mock Invoke-ToolkitSubmenuOfficeSuite { $dispatches.Add('P2') }
            Mock Invoke-ToolkitSubmenuConnectivity { $dispatches.Add('P3') }
            Mock Invoke-ToolkitSubmenuIdentityBackup { $dispatches.Add('P4') }
            Mock Invoke-ToolkitSubmenuSoftwareOptimization { $dispatches.Add('P5') }

            for ($i = 1; $i -le 5; $i++) {
                $currentChoice = [string]$i
                $script:count = 0
                Mock Read-ToolkitMenuChoice {
                    $script:count++
                    if ($script:count -eq 1) { return $currentChoice }
                    return '0'
                }
                { Start-IToolkitMenu } | Should -Not -Throw
            }

            $dispatches | Should -Contain 'P1'
            $dispatches | Should -Contain 'P2'
            $dispatches | Should -Contain 'P3'
            $dispatches | Should -Contain 'P4'
            $dispatches | Should -Contain 'P5'
        }
    }

    Context 'Pillar 1: System Health & Maintenance Submenu Workflow' {
        It 'Invoke-ToolkitSubmenuSystemHealth renders action catalog exposing numeric keys 1-9' -Skip:(-not $isTUIAvailable) {
            $script:healthActions = $null
            Mock Show-ToolkitActionCatalog {
                param($Actions, $NavActions, $Title)
                $script:healthActions = $Actions
            }
            { Invoke-ToolkitSubmenuSystemHealth -NonInteractive } | Should -Not -Throw
            $script:healthActions | Should -Not -BeNullOrEmpty
            $keys = $script:healthActions | ForEach-Object { $_.Key }
            for ($k = 1; $k -le 9; $k++) {
                $keys | Should -Contain ([string]$k)
            }
            $keys | Should -Not -Contain 'A'
            $keys | Should -Not -Contain 'S'
            $keys | Should -Not -Contain 'D'
            $keys | Should -Not -Contain 'W'
        }

        It 'Invoke-ToolkitSubmenuSystemHealth displays elevation warning when Test-IsAdmin returns false' -Skip:(-not $isTUIAvailable) {
            Mock Test-IsAdmin { return $false }
            $script:statusMessages = [System.Collections.Generic.List[string]]::new()
            Mock Write-ToolkitStatus {
                param($Message, $Type)
                $script:statusMessages.Add($Message)
            }
            { Invoke-ToolkitSubmenuSystemHealth -NonInteractive } | Should -Not -Throw
            $warningBanner = $script:statusMessages | Where-Object { $_ -match 'ELEVATION WARNING' }
            $warningBanner | Should -Not -BeNullOrEmpty
        }

        It 'Invoke-ToolkitSubmenuSystemHealth dispatches auto repair and individual actions' -Skip:(-not $isTUIAvailable) {
            $script:sfcRan = $false
            $script:dismRan = $false
            $script:wuRan = $false
            $script:ccRan = $false

            Mock Invoke-WindowsSfcScan { $script:sfcRan = $true; return [PSCustomObject]@{ Success = $true; Status = 'OK' } }
            Mock Invoke-WindowsDismRepair { param($Mode) $script:dismRan = $true; return [PSCustomObject]@{ Success = $true; Status = 'OK' } }
            Mock Reset-WindowsUpdateComponents { $script:wuRan = $true; return [PSCustomObject]@{ Success = $true } }
            Mock Invoke-WindowsComponentCleanup { $script:ccRan = $true; return [PSCustomObject]@{ Success = $true; Status = 'OK' } }
            Mock Wait-UserAcknowledge { }

            # Test 1 (Auto repair)
            Mock Read-ToolkitItemSelection {
                return [PSCustomObject]@{ Type = 'Hotkey'; Value = '1' }
            }
            Mock Wait-UserAcknowledge {
                Mock Read-ToolkitItemSelection { return [PSCustomObject]@{ Type = 'Exit'; Value = '0' } }
            }
            { Invoke-ToolkitSubmenuSystemHealth } | Should -Not -Throw
            $script:sfcRan | Should -BeTrue
            $script:dismRan | Should -BeTrue
        }
    }

    Context 'Pillar 2: Office & Productivity Suite Submenu Workflow' {
        It 'Invoke-ToolkitSubmenuOfficeSuite renders action catalog exposing numeric keys 10-16' -Skip:(-not $isTUIAvailable) {
            $script:officeActions = $null
            Mock Show-ToolkitActionCatalog {
                param($Actions, $NavActions, $Title)
                $script:officeActions = $Actions
            }
            { Invoke-ToolkitSubmenuOfficeSuite -NonInteractive } | Should -Not -Throw
            $script:officeActions | Should -Not -BeNullOrEmpty
            $keys = $script:officeActions | ForEach-Object { $_.Key }
            for ($k = 10; $k -le 16; $k++) {
                $keys | Should -Contain ([string]$k)
            }
            $keys | Should -Not -Contain 'N'
            $keys | Should -Not -Contain 'E'
            $keys | Should -Not -Contain 'C'
            $keys | Should -Not -Contain 'H'
        }

        It 'Invoke-ToolkitSubmenuOfficeSuite dispatches Toggle Graphics Acceleration on key 12' -Skip:(-not $isTUIAvailable) {
            $script:accelCalled = $false
            Mock Set-ExcelHardwareAcceleration { $script:accelCalled = $true }
            Mock Wait-UserAcknowledge { }

            Mock Read-ToolkitItemSelection {
                return [PSCustomObject]@{ Type = 'Hotkey'; Value = '12' }
            }
            Mock Wait-UserAcknowledge {
                Mock Read-ToolkitItemSelection { return [PSCustomObject]@{ Type = 'Exit'; Value = '0' } }
            }
            { Invoke-ToolkitSubmenuOfficeSuite } | Should -Not -Throw
            $script:accelCalled | Should -BeTrue
        }

        It 'Invoke-ToolkitSubmenuOfficeSuite dispatches Clear Temp Cache on key 13' -Skip:(-not $isTUIAvailable) {
            $script:cacheCalled = $false
            Mock Clear-OfficeTempCache { $script:cacheCalled = $true }
            Mock Reset-ExcelUiCache { }
            Mock Wait-UserAcknowledge { }

            Mock Read-ToolkitItemSelection {
                return [PSCustomObject]@{ Type = 'Hotkey'; Value = '13' }
            }
            Mock Wait-UserAcknowledge {
                Mock Read-ToolkitItemSelection { return [PSCustomObject]@{ Type = 'Exit'; Value = '0' } }
            }
            { Invoke-ToolkitSubmenuOfficeSuite } | Should -Not -Throw
            $script:cacheCalled | Should -BeTrue
        }
    }

    Context 'Pillar 3: Network & Connectivity Submenu Workflow' {
        It 'Invoke-ToolkitSubmenuConnectivity renders action catalog exposing numeric keys 10-18' -Skip:(-not $isTUIAvailable) {
            $script:connActions = $null
            Mock Show-ToolkitActionCatalog {
                param($Actions, $NavActions, $Title)
                $script:connActions = $Actions
            }
            { Invoke-ToolkitSubmenuConnectivity -NonInteractive } | Should -Not -Throw
            $script:connActions | Should -Not -BeNullOrEmpty
            $keys = $script:connActions | ForEach-Object { $_.Key }
            for ($k = 10; $k -le 18; $k++) {
                $keys | Should -Contain ([string]$k)
            }
            $keys | Should -Not -Contain 'A'
            $keys | Should -Not -Contain 'S'
            $keys | Should -Not -Contain 'P'
        }

        It 'Invoke-ToolkitSubmenuConnectivity dispatches Spooler Restart on key 12' -Skip:(-not $isTUIAvailable) {
            $script:spoolerCalled = $false
            Mock Reset-PrintSpoolerQueue { $script:spoolerCalled = $true }
            Mock Wait-UserAcknowledge { }

            Mock Read-ToolkitItemSelection {
                return [PSCustomObject]@{ Type = 'Hotkey'; Value = '12' }
            }
            Mock Wait-UserAcknowledge {
                Mock Read-ToolkitItemSelection { return [PSCustomObject]@{ Type = 'Exit'; Value = '0' } }
            }
            { Invoke-ToolkitSubmenuConnectivity } | Should -Not -Throw
            $script:spoolerCalled | Should -BeTrue
        }

        It 'Invoke-ToolkitSubmenuConnectivity dispatches Apply All Fixes on key 10' -Skip:(-not $isTUIAvailable) {
            $script:netRemCalled = $false
            Mock Set-NetworkRemediation {
                param([switch]$All)
                $script:netRemCalled = [bool]$All
                return [PSCustomObject]@{ Success = $true; FixesApplied = @('DnsResolution', 'TcpIpStack') }
            }
            Mock Wait-UserAcknowledge { }

            Mock Read-ToolkitItemSelection {
                return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' }
            }
            Mock Wait-UserAcknowledge {
                Mock Read-ToolkitItemSelection { return [PSCustomObject]@{ Type = 'Exit'; Value = '0' } }
            }
            { Invoke-ToolkitSubmenuConnectivity } | Should -Not -Throw
            $script:netRemCalled | Should -BeTrue
        }
    }

    Context 'Pillar 4: Accounts, Identity & Backup Submenu Workflow' {
        It 'Invoke-ToolkitSubmenuIdentityBackup renders action catalog exposing numeric keys 10-18' -Skip:(-not $isTUIAvailable) {
            $script:idActions = $null
            Mock Show-ToolkitActionCatalog {
                param($Actions, $NavActions, $Title)
                $script:idActions = $Actions
            }
            { Invoke-ToolkitSubmenuIdentityBackup -NonInteractive } | Should -Not -Throw
            $script:idActions | Should -Not -BeNullOrEmpty
            $keys = $script:idActions | ForEach-Object { $_.Key }
            for ($k = 10; $k -le 18; $k++) {
                $keys | Should -Contain ([string]$k)
            }
            $keys | Should -Not -Contain 'A'
            $keys | Should -Not -Contain 'S'
            $keys | Should -Not -Contain 'P'
        }

        It 'Invoke-ToolkitSubmenuIdentityBackup dispatches Enable Administrator SID-500 on key 11' -Skip:(-not $isTUIAvailable) {
            $script:adminEnabled = $false
            Mock Enable-BuiltInAdministrator { $script:adminEnabled = $true }
            Mock Wait-UserAcknowledge { }

            Mock Read-ToolkitItemSelection {
                return [PSCustomObject]@{ Type = 'Hotkey'; Value = '11' }
            }
            Mock Wait-UserAcknowledge {
                Mock Read-ToolkitItemSelection { return [PSCustomObject]@{ Type = 'Exit'; Value = '0' } }
            }
            { Invoke-ToolkitSubmenuIdentityBackup } | Should -Not -Throw
            $script:adminEnabled | Should -BeTrue
        }

        It 'Invoke-ToolkitSubmenuIdentityBackup dispatches Export Bookmarks on key 17' -Skip:(-not $isTUIAvailable) {
            $script:bmCalled = $false
            Mock Export-BrowserBookmarks { $script:bmCalled = $true }
            Mock Read-Host { return 'C:\Backups\Bookmarks' }
            Mock Wait-UserAcknowledge { }

            Mock Read-ToolkitItemSelection {
                return [PSCustomObject]@{ Type = 'Hotkey'; Value = '17' }
            }
            Mock Wait-UserAcknowledge {
                Mock Read-ToolkitItemSelection { return [PSCustomObject]@{ Type = 'Exit'; Value = '0' } }
            }
            { Invoke-ToolkitSubmenuIdentityBackup } | Should -Not -Throw
            $script:bmCalled | Should -BeTrue
        }
    }

    Context 'Pillar 5: Software & System Optimization Submenu Workflow' {
        It 'Invoke-ToolkitSubmenuSoftwareOptimization renders action catalog exposing numeric keys 1-12' -Skip:(-not $isTUIAvailable) {
            $script:softActions = $null
            Mock Show-ToolkitActionCatalog {
                param($Actions, $NavActions, $Title)
                $script:softActions = $Actions
            }
            { Invoke-ToolkitSubmenuSoftwareOptimization -NonInteractive } | Should -Not -Throw
            $script:softActions | Should -Not -BeNullOrEmpty
            $keys = $script:softActions | ForEach-Object { $_.Key }
            for ($k = 1; $k -le 12; $k++) {
                $keys | Should -Contain ([string]$k)
            }
            $keys | Should -Not -Contain 'A'
            $keys | Should -Not -Contain 'U'
            $keys | Should -Not -Contain 'D'
            $keys | Should -Not -Contain 'T'
            $keys | Should -Not -Contain 'O'
            $keys | Should -Not -Contain 'C'
            $keys | Should -Not -Contain 'W'
            $keys | Should -Not -Contain 'B'

            # Verify action labels format (no 'Install' prefix, no parenthetical clauses)
            $labels = $script:softActions | ForEach-Object { $_.Label }
            foreach ($label in $labels) {
                $label | Should -Not -Match '^Install\s'
                $label | Should -Not -Match '\(.*\)'
            }
            # Assert applications are indexed 1..8 and category actions use keys 9..12
            ($script:softActions | Where-Object { $_.Key -eq '1' }).Label | Should -Be 'Google Chrome'
            ($script:softActions | Where-Object { $_.Key -eq '8' }).Label | Should -Be 'WinRAR'
            ($script:softActions | Where-Object { $_.Key -eq '9' }).Label | Should -Be 'Update All Winget Apps'
            ($script:softActions | Where-Object { $_.Key -eq '10' }).Label | Should -Be 'Win11Debloat'
            ($script:softActions | Where-Object { $_.Key -eq '11' }).Label | Should -Be 'Browser Debloat'
            ($script:softActions | Where-Object { $_.Key -eq '12' }).Label | Should -Be 'Office Tool Plus'
        }

        It 'Invoke-ToolkitSubmenuSoftwareOptimization dispatches WinRAR through contextual workflow on key 8' -Skip:(-not $isTUIAvailable) {
            $script:winrarInstalled = $false
            $script:winrarShortcut = $false
            Mock Install-ToolkitApplication {
                param($AppName, $CreateShortcut)
                if ($AppName -eq 'WinRAR') {
                    $script:winrarInstalled = $true
                    $script:winrarShortcut = [bool]$CreateShortcut
                }
                return [PSCustomObject]@{ AppName = $AppName; Installed = $true }
            }
            Mock Wait-UserAcknowledge { }
            $script:selectionStep = 0
            Mock Read-ToolkitItemSelection {
                $script:selectionStep++
                switch ($script:selectionStep) {
                    1 { return [PSCustomObject]@{ Type = 'Index'; Value = 8 } }
                    2 { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '1' } }
                    3 { return [PSCustomObject]@{ Type = 'Exit'; Value = '0' } }
                    default { return [PSCustomObject]@{ Type = 'Exit'; Value = '0' } }
                }
            }
            { Invoke-ToolkitSubmenuSoftwareOptimization } | Should -Not -Throw
            $script:winrarInstalled | Should -BeTrue
            $script:winrarShortcut | Should -BeTrue
        }

        It 'Invoke-ToolkitSubmenuSoftwareOptimization dispatches Winget Update on key 9' -Skip:(-not $isTUIAvailable) {
            $script:upgradeAllCalled = $false
            Mock Update-WingetPackage {
                param([switch]$All)
                $script:upgradeAllCalled = [bool]$All
                return [PSCustomObject]@{ Success = $true; TotalUpgraded = 2 }
            }
            Mock Wait-UserAcknowledge { }
            $script:sCount = 0
            Mock Read-ToolkitItemSelection {
                $script:sCount++
                if ($script:sCount -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '9' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuSoftwareOptimization } | Should -Not -Throw
            $script:upgradeAllCalled | Should -BeTrue
        }

        It 'Invoke-ToolkitSubmenuSoftwareOptimization dispatches Win11Debloat on key 10' -Skip:(-not $isTUIAvailable) {
            $script:debloatCalled = $false
            Mock Invoke-Win11Debloat {
                $script:debloatCalled = $true
                return [PSCustomObject]@{ Success = $true }
            }
            Mock Wait-UserAcknowledge { }
            $script:sCount = 0
            Mock Read-ToolkitItemSelection {
                $script:sCount++
                if ($script:sCount -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuSoftwareOptimization } | Should -Not -Throw
            $script:debloatCalled | Should -BeTrue
        }
    }

    Context 'Contextual Submenu: Local Account Administration' {
        BeforeAll {
            $script:testAccount = [PSCustomObject]@{
                Name     = 'TestAdmin'
                Status   = '[ENABLED]'
                Enabled  = $true
                Locked   = $false
                SID      = 'S-1-5-21-1234567890-500'
                Details  = 'Security Identifier SID -500'
            }
        }

        It 'Invoke-ToolkitSubmenuIdentityBackup routes item index 1 to Invoke-ToolkitAccountContextMenu' -Skip:(-not $isTUIAvailable) {
            $script:routedAccount = $null
            Mock Invoke-ToolkitAccountContextMenu {
                param($Account)
                $script:routedAccount = $Account
            }
            $script:idStep = 0
            Mock Read-ToolkitItemSelection {
                $script:idStep++
                if ($script:idStep -eq 1) { return [PSCustomObject]@{ Type = 'Index'; Value = 1 } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuIdentityBackup } | Should -Not -Throw
            $script:routedAccount | Should -Not -BeNullOrEmpty
        }

        It 'Invoke-ToolkitAccountContextMenu renders action catalog exposing numeric keys 1-4 and 0 back' -Skip:(-not $isTUIAvailable) {
            $script:capturedAccActions = $null
            $script:capturedAccNav = $null
            Mock Show-ToolkitActionCatalog {
                param($Actions, $NavActions, $Title)
                $script:capturedAccActions = $Actions
                $script:capturedAccNav = $NavActions
            }
            { Invoke-ToolkitAccountContextMenu -Account $script:testAccount -NonInteractive } | Should -Not -Throw
            $keys = $script:capturedAccActions | ForEach-Object { $_.Key }
            for ($k = 1; $k -le 4; $k++) {
                $keys | Should -Contain ([string]$k)
            }
            ($script:capturedAccNav | ForEach-Object { $_.Key }) | Should -Contain '0'
        }

        It 'Invoke-ToolkitAccountContextMenu executes Toggle State (key 1) with targeted username' -Skip:(-not $isTUIAvailable) {
            $script:toggledUser = $null
            $script:toggledState = $null
            Mock Set-LocalAccountState {
                param($Username, $Enabled)
                $script:toggledUser = $Username
                $script:toggledState = $Enabled
            }
            Mock Wait-UserAcknowledge { }
            $script:cStep = 0
            Mock Read-ToolkitItemSelection {
                $script:cStep++
                if ($script:cStep -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '1' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitAccountContextMenu -Account $script:testAccount } | Should -Not -Throw
            $script:toggledUser | Should -Be 'TestAdmin'
            $script:toggledState | Should -Be $false
        }

        It 'Invoke-ToolkitAccountContextMenu executes Unlock Account (key 2) with targeted username' -Skip:(-not $isTUIAvailable) {
            $script:unlockedUser = $null
            Mock Unlock-LocalAccountItem {
                param($Username)
                $script:unlockedUser = $Username
            }
            Mock Wait-UserAcknowledge { }
            $script:cStep = 0
            Mock Read-ToolkitItemSelection {
                $script:cStep++
                if ($script:cStep -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '2' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitAccountContextMenu -Account $script:testAccount } | Should -Not -Throw
            $script:unlockedUser | Should -Be 'TestAdmin'
        }

        It 'Invoke-ToolkitAccountContextMenu executes Reset Password (key 3) for SID-500 Administrator' -Skip:(-not $isTUIAvailable) {
            $script:pwdResetCalled = $false
            Mock Read-Host { return ('Pass123' | ConvertTo-SecureString -AsPlainText -Force) }
            Mock Reset-BuiltInAdministratorPassword {
                param($Password)
                $script:pwdResetCalled = $true
            }
            Mock Wait-UserAcknowledge { }
            $script:cStep = 0
            Mock Read-ToolkitItemSelection {
                $script:cStep++
                if ($script:cStep -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '3' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitAccountContextMenu -Account $script:testAccount } | Should -Not -Throw
            $script:pwdResetCalled | Should -BeTrue
        }

        It 'Invoke-ToolkitAccountContextMenu cleanly returns on key 0 without action dispatch' -Skip:(-not $isTUIAvailable) {
            Mock Read-ToolkitItemSelection { return [PSCustomObject]@{ Type = 'Exit'; Value = '0' } }
            { Invoke-ToolkitAccountContextMenu -Account $script:testAccount } | Should -Not -Throw
        }
    }

    Context 'Contextual Submenu: Outlook Data File Administration' {
        BeforeAll {
            $script:testDataFile = [PSCustomObject]@{
                Item    = 'archive.pst'
                Path    = 'C:\Data\archive.pst'
                Type    = 'PST'
                Profile = 'MainProfile'
                SizeGB  = 12.5
                Details = 'C:\Data\archive.pst'
            }
        }

        It 'Invoke-ToolkitSubmenuOfficeSuite routes item index 1 to Invoke-ToolkitDataFileContextMenu' -Skip:(-not $isTUIAvailable) {
            $script:routedFile = $null
            Mock Invoke-ToolkitDataFileContextMenu {
                param($DataFile)
                $script:routedFile = $DataFile
            }
            $script:ofStep = 0
            Mock Read-ToolkitItemSelection {
                $script:ofStep++
                if ($script:ofStep -eq 1) { return [PSCustomObject]@{ Type = 'Index'; Value = 1 } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeSuite } | Should -Not -Throw
            $script:routedFile | Should -Not -BeNullOrEmpty
        }

        It 'Invoke-ToolkitDataFileContextMenu renders action catalog exposing numeric keys 1-5 and 0 back' -Skip:(-not $isTUIAvailable) {
            $script:capturedFileActions = $null
            $script:capturedFileNav = $null
            Mock Show-ToolkitActionCatalog {
                param($Actions, $NavActions, $Title)
                $script:capturedFileActions = $Actions
                $script:capturedFileNav = $NavActions
            }
            { Invoke-ToolkitDataFileContextMenu -DataFile $script:testDataFile -NonInteractive } | Should -Not -Throw
            $keys = $script:capturedFileActions | ForEach-Object { $_.Key }
            for ($k = 1; $k -le 5; $k++) {
                $keys | Should -Contain ([string]$k)
            }
            ($script:capturedFileNav | ForEach-Object { $_.Key }) | Should -Contain '0'
        }

        It 'Invoke-ToolkitDataFileContextMenu executes Compaction (key 1) with targeted file path' -Skip:(-not $isTUIAvailable) {
            $script:compactedPath = $null
            Mock Invoke-OutlookCompaction {
                param($FilePath)
                $script:compactedPath = $FilePath
            }
            Mock Wait-UserAcknowledge { }
            $script:fStep = 0
            Mock Read-ToolkitItemSelection {
                $script:fStep++
                if ($script:fStep -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '1' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitDataFileContextMenu -DataFile $script:testDataFile } | Should -Not -Throw
            $script:compactedPath | Should -Be 'C:\Data\archive.pst'
        }

        It 'Invoke-ToolkitDataFileContextMenu executes Expand Limit (key 2) with 100GB limit' -Skip:(-not $isTUIAvailable) {
            $script:limitSet = $false
            Mock Set-OutlookPstThreshold {
                param($MaxLargeFileSizeMB, $WarnLargeFileSizeMB)
                if ($MaxLargeFileSizeMB -eq 102400) { $script:limitSet = $true }
            }
            Mock Wait-UserAcknowledge { }
            $script:fStep = 0
            Mock Read-ToolkitItemSelection {
                $script:fStep++
                if ($script:fStep -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '2' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitDataFileContextMenu -DataFile $script:testDataFile } | Should -Not -Throw
            $script:limitSet | Should -BeTrue
        }

        It 'Invoke-ToolkitDataFileContextMenu executes Backup (key 3) with targeted file path' -Skip:(-not $isTUIAvailable) {
            $script:backupSource = $null
            Mock Read-Host { return 'C:\Backups\Outlook' }
            Mock Backup-OutlookPst {
                param($SourcePath, $BackupDirectory)
                $script:backupSource = $SourcePath
                return @{ Success = $true; BackupPath = "$BackupDirectory\archive.pst" }
            }
            Mock Wait-UserAcknowledge { }
            $script:fStep = 0
            Mock Read-ToolkitItemSelection {
                $script:fStep++
                if ($script:fStep -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '3' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitDataFileContextMenu -DataFile $script:testDataFile } | Should -Not -Throw
            $script:backupSource | Should -Be 'C:\Data\archive.pst'
        }

        It 'Invoke-ToolkitDataFileContextMenu executes Set Default (key 5) with targeted path and profile' -Skip:(-not $isTUIAvailable) {
            $script:defaultPath = $null
            $script:defaultProf = $null
            Mock Set-OutlookDefaultDataFile {
                param($Path, $ProfileName)
                $script:defaultPath = $Path
                $script:defaultProf = $ProfileName
                return @{ Success = $true }
            }
            Mock Wait-UserAcknowledge { }
            $script:fStep = 0
            Mock Read-ToolkitItemSelection {
                $script:fStep++
                if ($script:fStep -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '5' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitDataFileContextMenu -DataFile $script:testDataFile } | Should -Not -Throw
            $script:defaultPath | Should -Be 'C:\Data\archive.pst'
            $script:defaultProf | Should -Be 'MainProfile'
        }

        It 'Invoke-ToolkitDataFileContextMenu cleanly returns on key 0 without action dispatch' -Skip:(-not $isTUIAvailable) {
            Mock Read-ToolkitItemSelection { return [PSCustomObject]@{ Type = 'Exit'; Value = '0' } }
            { Invoke-ToolkitDataFileContextMenu -DataFile $script:testDataFile } | Should -Not -Throw
        }
    }

    Context 'Contextual Submenu: Network Device & Printer Administration' {
        BeforeAll {
            $script:testDevice = [PSCustomObject]@{
                Device  = 'Ethernet0'
                Status  = '[READY]'
                Type    = 'Adapter'
                Details = '192.168.1.100'
                Gateway = '192.168.1.1'
            }
        }

        It 'Invoke-ToolkitSubmenuConnectivity routes item index 1 to Invoke-ToolkitNetworkDeviceContextMenu' -Skip:(-not $isTUIAvailable) {
            $script:routedDev = $null
            Mock Invoke-ToolkitNetworkDeviceContextMenu {
                param($Device)
                $script:routedDev = $Device
            }
            $script:cnStep = 0
            Mock Read-ToolkitItemSelection {
                $script:cnStep++
                if ($script:cnStep -eq 1) { return [PSCustomObject]@{ Type = 'Index'; Value = 1 } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuConnectivity } | Should -Not -Throw
            $script:routedDev | Should -Not -BeNullOrEmpty
        }

        It 'Invoke-ToolkitNetworkDeviceContextMenu renders action catalog exposing numeric keys 1-4 and 0 back' -Skip:(-not $isTUIAvailable) {
            $script:capturedDevActions = $null
            $script:capturedDevNav = $null
            Mock Show-ToolkitActionCatalog {
                param($Actions, $NavActions, $Title)
                $script:capturedDevActions = $Actions
                $script:capturedDevNav = $NavActions
            }
            { Invoke-ToolkitNetworkDeviceContextMenu -Device $script:testDevice -NonInteractive } | Should -Not -Throw
            $keys = $script:capturedDevActions | ForEach-Object { $_.Key }
            for ($k = 1; $k -le 4; $k++) {
                $keys | Should -Contain ([string]$k)
            }
            ($script:capturedDevNav | ForEach-Object { $_.Key }) | Should -Contain '0'
        }

        It 'Invoke-ToolkitNetworkDeviceContextMenu executes Restart Adapter (key 1) with targeted device' -Skip:(-not $isTUIAvailable) {
            $script:restartedDev = $null
            Mock Restart-ToolkitNetworkAdapter {
                param($Name)
                $script:restartedDev = $Name
                return @{ Success = $true }
            }
            Mock Wait-UserAcknowledge { }
            $script:dStep = 0
            Mock Read-ToolkitItemSelection {
                $script:dStep++
                if ($script:dStep -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '1' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitNetworkDeviceContextMenu -Device $script:testDevice } | Should -Not -Throw
            $script:restartedDev | Should -Be 'Ethernet0'
        }

        It 'Invoke-ToolkitNetworkDeviceContextMenu executes Flush DNS & Renew DHCP (key 2)' -Skip:(-not $isTUIAvailable) {
            $script:dnsReset = $false
            $script:dhcpReset = $false
            Mock Reset-NetworkDns { $script:dnsReset = $true }
            Mock Reset-NetworkDhcp { $script:dhcpReset = $true }
            Mock Wait-UserAcknowledge { }
            $script:dStep = 0
            Mock Read-ToolkitItemSelection {
                $script:dStep++
                if ($script:dStep -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '2' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitNetworkDeviceContextMenu -Device $script:testDevice } | Should -Not -Throw
            $script:dnsReset | Should -BeTrue
            $script:dhcpReset | Should -BeTrue
        }

        It 'Invoke-ToolkitNetworkDeviceContextMenu executes Purge Spooler Queue (key 4)' -Skip:(-not $isTUIAvailable) {
            $script:spoolerReset = $false
            Mock Reset-PrintSpoolerQueue {
                param([switch]$Force)
                $script:spoolerReset = [bool]$Force
            }
            Mock Wait-UserAcknowledge { }
            $script:dStep = 0
            Mock Read-ToolkitItemSelection {
                $script:dStep++
                if ($script:dStep -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '4' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitNetworkDeviceContextMenu -Device $script:testDevice } | Should -Not -Throw
            $script:spoolerReset | Should -BeTrue
        }

        It 'Invoke-ToolkitNetworkDeviceContextMenu cleanly returns on key 0 without action dispatch' -Skip:(-not $isTUIAvailable) {
            Mock Read-ToolkitItemSelection { return [PSCustomObject]@{ Type = 'Exit'; Value = '0' } }
            { Invoke-ToolkitNetworkDeviceContextMenu -Device $script:testDevice } | Should -Not -Throw
        }
    }

    Context 'Contextual Submenu: Application Deployment & Management' {
        BeforeAll {
            $script:testApplication = [PSCustomObject]@{
                AppName        = 'WinRAR'
                DisplayName    = 'WinRAR Archiver'
                Application    = 'WinRAR Archiver'
                Status         = '[MISSING]'
                Executable     = 'WinRAR.exe'
                ExecutablePath = ''
                Version        = 'N/A'
                Installed      = $false
            }
        }

        It 'Invoke-ToolkitSubmenuSoftwareOptimization routes item index 8 to Invoke-ToolkitApplicationContextMenu' -Skip:(-not $isTUIAvailable) {
            $script:routedApp = $null
            Mock Invoke-ToolkitApplicationContextMenu {
                param($SelectedApp)
                $script:routedApp = $SelectedApp
            }
            $script:soStep = 0
            Mock Read-ToolkitItemSelection {
                $script:soStep++
                if ($script:soStep -eq 1) { return [PSCustomObject]@{ Type = 'Index'; Value = 8 } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuSoftwareOptimization } | Should -Not -Throw
            $script:routedApp | Should -Not -BeNullOrEmpty
            $script:routedApp.AppName | Should -Be 'WinRAR'
        }

        It 'Invoke-ToolkitApplicationContextMenu renders action catalog exposing numeric keys 1-4 and 0 back' -Skip:(-not $isTUIAvailable) {
            $script:capturedAppActions = $null
            $script:capturedAppNav = $null
            Mock Show-ToolkitActionCatalog {
                param($Actions, $NavActions, $Title)
                $script:capturedAppActions = $Actions
                $script:capturedAppNav = $NavActions
            }
            { Invoke-ToolkitApplicationContextMenu -SelectedApp $script:testApplication -NonInteractive } | Should -Not -Throw
            $keys = $script:capturedAppActions | ForEach-Object { $_.Key }
            for ($k = 1; $k -le 4; $k++) {
                $keys | Should -Contain ([string]$k)
            }
            ($script:capturedAppNav | ForEach-Object { $_.Key }) | Should -Contain '0'
        }

        It 'Invoke-ToolkitApplicationContextMenu executes Silent Install (key 1) for targeted application' -Skip:(-not $isTUIAvailable) {
            $script:instTarget = $null
            $script:instShortcut = $false
            Mock Install-ToolkitApplication {
                param($AppName, $CreateShortcut)
                $script:instTarget = $AppName
                $script:instShortcut = [bool]$CreateShortcut
                return [PSCustomObject]@{ AppName = $AppName; Installed = $true }
            }
            Mock Wait-UserAcknowledge { }
            $script:aStep = 0
            Mock Read-ToolkitItemSelection {
                $script:aStep++
                if ($script:aStep -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '1' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitApplicationContextMenu -SelectedApp $script:testApplication } | Should -Not -Throw
            $script:instTarget | Should -Be 'WinRAR'
            $script:instShortcut | Should -BeTrue
        }

        It 'Invoke-ToolkitApplicationContextMenu executes Force Reinstall (key 2) with Force flag' -Skip:(-not $isTUIAvailable) {
            $script:forceTarget = $null
            $script:forceFlag = $false
            Mock Install-ToolkitApplication {
                param($AppName, [switch]$Force, $CreateShortcut)
                $script:forceTarget = $AppName
                $script:forceFlag = [bool]$Force
                return [PSCustomObject]@{ AppName = $AppName; Installed = $true }
            }
            Mock Wait-UserAcknowledge { }
            $script:aStep = 0
            Mock Read-ToolkitItemSelection {
                $script:aStep++
                if ($script:aStep -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '2' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitApplicationContextMenu -SelectedApp $script:testApplication } | Should -Not -Throw
            $script:forceTarget | Should -Be 'WinRAR'
            $script:forceFlag | Should -BeTrue
        }

        It 'Invoke-ToolkitApplicationContextMenu executes Verify Status (key 3)' -Skip:(-not $isTUIAvailable) {
            $script:statusTarget = $null
            Mock Get-ToolkitInstalledApplication {
                param($AppName)
                $script:statusTarget = $AppName
                return [PSCustomObject]@{ AppName = $AppName; Installed = $true; Version = '7.01' }
            }
            Mock Wait-UserAcknowledge { }
            $script:aStep = 0
            Mock Read-ToolkitItemSelection {
                $script:aStep++
                if ($script:aStep -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '3' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitApplicationContextMenu -SelectedApp $script:testApplication } | Should -Not -Throw
            $script:statusTarget | Should -Be 'WinRAR'
        }

        It 'Invoke-ToolkitApplicationContextMenu executes Create Desktop Shortcut (key 4)' -Skip:(-not $isTUIAvailable) {
            $script:shortcutTarget = $null
            $script:shortcutName = $null
            Mock Get-ToolkitInstalledApplication {
                param($AppName)
                return [PSCustomObject]@{ AppName = $AppName; ExecutablePath = 'C:\Program Files\WinRAR\WinRAR.exe'; Installed = $true }
            }
            Mock New-ToolkitDesktopShortcut {
                param($TargetExecutable, $ShortcutName, [switch]$Force)
                $script:shortcutTarget = $TargetExecutable
                $script:shortcutName = $ShortcutName
                return [PSCustomObject]@{ Success = $true; ShortcutPath = "C:\Users\User\Desktop\$ShortcutName.lnk"; Created = $true }
            }
            Mock Wait-UserAcknowledge { }
            $script:aStep = 0
            Mock Read-ToolkitItemSelection {
                $script:aStep++
                if ($script:aStep -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '4' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitApplicationContextMenu -SelectedApp $script:testApplication } | Should -Not -Throw
            $script:shortcutTarget | Should -Be 'C:\Program Files\WinRAR\WinRAR.exe'
            $script:shortcutName | Should -Be 'WinRAR Archiver'
        }

        It 'Invoke-ToolkitApplicationContextMenu cleanly returns on key 0 without action dispatch' -Skip:(-not $isTUIAvailable) {
            Mock Read-ToolkitItemSelection { return [PSCustomObject]@{ Type = 'Exit'; Value = '0' } }
            { Invoke-ToolkitApplicationContextMenu -SelectedApp $script:testApplication } | Should -Not -Throw
        }
    }

    Context 'Two-Level Navigation Backtrack Verification' {
        It 'SoftwareOptimization: entering 0 in contextual menu returns to parent, then 0 returns to main menu' -Skip:(-not $isTUIAvailable) {
            Mock Wait-UserAcknowledge { }
            $script:navStep = 0
            Mock Read-ToolkitItemSelection {
                $script:navStep++
                switch ($script:navStep) {
                    1 { return [PSCustomObject]@{ Type = 'Index'; Value = 8 } }
                    2 { return [PSCustomObject]@{ Type = 'Exit'; Value = '0' } }
                    3 { return [PSCustomObject]@{ Type = 'Exit'; Value = '0' } }
                    default { return [PSCustomObject]@{ Type = 'Exit'; Value = '0' } }
                }
            }
            { Invoke-ToolkitSubmenuSoftwareOptimization } | Should -Not -Throw
            $script:navStep | Should -Be 3
        }
    }
}
