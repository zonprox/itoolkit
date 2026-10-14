# ==============================================================================
# OfficeTuiAdversarial.Tests.ps1
# Adversarial Stress Testing for Pillar 2: Office & Productivity Suite TUI
# 
# Verifies:
# 1. Pure numeric keypad enforcement: letter aliases ('Q', 'B', 'q', 'b', 'x')
#    are strictly rejected with warnings and NEVER act as Back/Quit.
# 2. Out-of-range numbers ('99', '100', '-1') are cleanly rejected without exceptions.
# 3. Numeric '0' and bracketed '[0]' cleanly and safely exit each submenu.
# 4. Headless automation compatibility (-NonInteractive, -ExitImmediately, Closed Stdin)
#    executes cleanly without blocking across all 6 submenus.
# ==============================================================================

$OfficeSubmenus = @(
    @{ Name = 'OfficeSuite Hub';         Command = 'Invoke-ToolkitSubmenuOfficeSuite' },
    @{ Name = 'OfficeCommon Repairs';     Command = 'Invoke-ToolkitSubmenuOfficeCommon' },
    @{ Name = 'OfficeWord Repairs';       Command = 'Invoke-ToolkitSubmenuOfficeWord' },
    @{ Name = 'OfficeExcel Repairs';      Command = 'Invoke-ToolkitSubmenuOfficeExcel' },
    @{ Name = 'OfficePowerPoint Repairs'; Command = 'Invoke-ToolkitSubmenuOfficePowerPoint' },
    @{ Name = 'OfficeOutlook Repairs';    Command = 'Invoke-ToolkitSubmenuOfficeOutlook' }
)

BeforeAll {
    $script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:TuiManifest = Join-Path $script:ProjectRoot 'Modules/TUI/TUI.psd1'
    $script:OfficeManifest = Join-Path $script:ProjectRoot 'Modules/Office/Office.psd1'
    $script:OutlookManifest = Join-Path $script:ProjectRoot 'Modules/Outlook/Outlook.psd1'

    if (Test-Path -LiteralPath $script:OfficeManifest) {
        Import-Module $script:OfficeManifest -Force -DisableNameChecking
    }
    if (Test-Path -LiteralPath $script:OutlookManifest) {
        Import-Module $script:OutlookManifest -Force -DisableNameChecking
    }
    if (Test-Path -LiteralPath $script:TuiManifest) {
        Import-Module $script:TuiManifest -Force -DisableNameChecking
    }
}

Describe 'Adversarial: Office TUI Numeric Keypad & Input Validation Stress' {

    # --------------------------------------------------------------------------
    # 1. Letter Aliases Strictly Rejected (Never Act as Back/Quit)
    # --------------------------------------------------------------------------
    Context 'Letter Aliases Rejection: <_.Name>' -ForEach $OfficeSubmenus {
        BeforeEach {
            Mock Wait-UserAcknowledge { }
            Mock Clear-Host { }
        }

        It 'Strictly rejects letter alias "<Letter>" and requires numeric "0" to exit' -TestCases @(
            @{ Letter = 'Q' },
            @{ Letter = 'B' },
            @{ Letter = 'q' },
            @{ Letter = 'b' },
            @{ Letter = 'x' }
        ) {
            param($Letter)

            $script:attemptCount = 0
            Mock Read-Host {
                $script:attemptCount++
                if ($script:attemptCount -eq 1) { return $Letter }
                return '0'
            }

            # Invoke submenu: on attempt 1, letter must be rejected; on attempt 2, '0' exits
            { & $Command } | Should -Not -Throw

            # If letter had acted as Back/Quit, attemptCount would be 1.
            # Pure numeric validation requires retry, thus attemptCount must be 2.
            $script:attemptCount | Should -Be 2 -Because "Letter '$Letter' must be rejected and never act as Back/Quit"
        }
    }

    # --------------------------------------------------------------------------
    # 2. Out-of-Range Numeric Rejection
    # --------------------------------------------------------------------------
    Context 'Out-of-Range Numeric Rejection: <_.Name>' -ForEach $OfficeSubmenus {
        BeforeEach {
            Mock Wait-UserAcknowledge { }
            Mock Clear-Host { }
        }

        It 'Cleanly rejects out-of-range input "<InputVal>" without throwing exceptions' -TestCases @(
            @{ InputVal = '99' },
            @{ InputVal = '100' },
            @{ InputVal = '-1' }
        ) {
            param($InputVal)

            $script:attemptCount = 0
            Mock Read-Host {
                $script:attemptCount++
                if ($script:attemptCount -eq 1) { return $InputVal }
                return '0'
            }

            { & $Command } | Should -Not -Throw

            # Must reject out-of-range value on attempt 1 and exit cleanly on attempt 2 ('0')
            $script:attemptCount | Should -Be 2 -Because "Out-of-range input '$InputVal' must be rejected without exceptions"
        }
    }

    # --------------------------------------------------------------------------
    # 3. Clean and Safe Exit via '0' and '[0]'
    # --------------------------------------------------------------------------
    Context 'Numeric Exit Safety: <_.Name>' -ForEach $OfficeSubmenus {
        BeforeEach {
            Mock Wait-UserAcknowledge { }
            Mock Clear-Host { }
        }

        It 'Cleanly and immediately exits on primary numeric key "0"' {
            $script:attemptCount = 0
            Mock Read-Host {
                $script:attemptCount++
                return '0'
            }

            { & $Command } | Should -Not -Throw
            $script:attemptCount | Should -Be 1 -Because "'0' must immediately exit the submenu on first attempt"
        }

        It 'Cleanly and immediately exits on bracketed numeric key "[0]"' {
            $script:attemptCount = 0
            Mock Read-Host {
                $script:attemptCount++
                return '[0]'
            }

            { & $Command } | Should -Not -Throw
            $script:attemptCount | Should -Be 1 -Because "'[0]' must immediately exit the submenu on first attempt"
        }
    }

    # --------------------------------------------------------------------------
    # 4. Headless Automation Resiliency
    # --------------------------------------------------------------------------
    Context 'Headless Automation Resiliency: <_.Name>' -ForEach $OfficeSubmenus {
        It 'Executes cleanly without blocking or throwing with -ExitImmediately' {
            { & $Command -ExitImmediately } | Should -Not -Throw
        }

        It 'Executes cleanly without blocking or prompting with -NonInteractive' {
            # Ensure Read-Host is never called when -NonInteractive is active
            Mock Read-Host { throw "Read-Host was unexpectedly invoked during -NonInteractive execution!" }
            { & $Command -NonInteractive } | Should -Not -Throw
        }

        It 'Terminates cleanly without hanging when standard input is closed ($null / EOF)' {
            Mock Read-Host { return $null }
            { & $Command } | Should -Not -Throw
        }
    }
}
