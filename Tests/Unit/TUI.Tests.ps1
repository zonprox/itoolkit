# ==============================================================================
# TUI.Tests.ps1
# Unit test suite for Modules/TUI
# Covers: Show-ToolkitHeader, Show-ToolkitMenuOption, Read-ToolkitMenuChoice,
# Write-ToolkitStatus, Start-IToolkitMenu.
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:TUIManifest = Join-Path $ProjectRoot 'Modules/TUI/TUI.psd1'
$isTUIAvailable = Test-Path $script:TUIManifest

BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
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
Describe 'Unit: Interactive Console TUI Menu Module' {

    Context 'Header & Banner Rendering' {
        It 'Show-ToolkitHeader renders banner title and subtitle' -Skip:(-not $isTUIAvailable) {
            { Show-ToolkitHeader -Title 'IToolkit Main Menu' -Subtitle 'Enterprise IT Support' } | Should -Not -Throw
        }
    }

    Context 'Menu Options & Choice Reading' {
        It 'Show-ToolkitMenuOption displays menu key and label' -Skip:(-not $isTUIAvailable) {
            { Show-ToolkitMenuOption -Key '1' -Label 'Outlook & PST Management' -Status 'OK' } | Should -Not -Throw
        }

        It 'Read-ToolkitMenuChoice accepts valid key choice' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '1' }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', 'Q')
            $choice | Should -Be '1'
        }

        It 'Read-ToolkitMenuChoice is case-insensitive for exit keys' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return 'q' }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', 'Q')
            $choice.ToUpper() | Should -Be 'Q'
        }

        It 'Read-ToolkitMenuChoice returns Default value when input is empty string' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '' }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', 'Q') -Default 'Q'
            $choice | Should -Be 'Q'
        }

        It 'Read-ToolkitMenuChoice safely handles null/EOF without throwing' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return $null }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', 'Q')
            $choice | Should -Be ''
        }

        It 'Read-ToolkitMenuChoice terminates after max attempts on repeated empty input' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '' }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', 'Q')
            $choice | Should -Be ''
        }

        It 'Read-ToolkitMenuChoice retries after invalid input and returns subsequent valid choice' -Skip:(-not $isTUIAvailable) {
            $script:attemptCount = 0
            Mock Read-Host {
                $script:attemptCount++
                if ($script:attemptCount -eq 1) { return 'invalid_choice' }
                return '2'
            }
            $choice = Read-ToolkitMenuChoice -Prompt 'Select Option' -ValidKeys @('1', '2', 'Q')
            $choice | Should -Be '2'
        }
    }

    Context 'Start-IToolkitMenu Execution Modes & Non-Interactive Contract' {
        It 'Start-IToolkitMenu returns immediately when -ExitImmediately is specified' -Skip:(-not $isTUIAvailable) {
            { Start-IToolkitMenu -ExitImmediately } | Should -Not -Throw
        }

        It 'Start-IToolkitMenu handles -NonInteractive without MenuOption cleanly' -Skip:(-not $isTUIAvailable) {
            { Start-IToolkitMenu -NonInteractive } | Should -Not -Throw
        }

        It 'Start-IToolkitMenu handles -NonInteractive with Exit options (Q and X)' -Skip:(-not $isTUIAvailable) {
            { Start-IToolkitMenu -MenuOption 'Q' -NonInteractive } | Should -Not -Throw
            { Start-IToolkitMenu -MenuOption 'X' -NonInteractive } | Should -Not -Throw
        }

        It 'Start-IToolkitMenu lists category options without prompting when -NonInteractive is specified' -Skip:(-not $isTUIAvailable) {
            $categories = @('1', '2', '3', '4', '5', '6')
            foreach ($cat in $categories) {
                { Start-IToolkitMenu -MenuOption $cat -NonInteractive } | Should -Not -Throw
            }
        }

        It 'Submenus terminate immediately on EOF ($null) without infinite looping' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return $null }
            $categories = @('1', '2', '3', '4', '5', '6')
            foreach ($cat in $categories) {
                { Start-IToolkitMenu -MenuOption $cat } | Should -Not -Throw
            }
        }

        It 'Submenus terminate immediately on empty string input fallback without looping' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return '' }
            $categories = @('1', '2', '3', '4', '5', '6')
            foreach ($cat in $categories) {
                { Start-IToolkitMenu -MenuOption $cat } | Should -Not -Throw
            }
        }

        It 'Submenus exit back to caller when Back key (B) is selected' -Skip:(-not $isTUIAvailable) {
            Mock Read-Host { return 'B' }
            $categories = @('1', '2', '3', '4', '5', '6')
            foreach ($cat in $categories) {
                { Start-IToolkitMenu -MenuOption $cat } | Should -Not -Throw
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
}
