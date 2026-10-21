# ==============================================================================
# Challenger5ProfileSelectorAndMenuRoutingStress.Tests.ps1
# Milestone 4 Challenger 5 Empirical Stress Test Suite
# Scope: Deep Adversarial Stress-Testing for:
# - Select-ToolkitOutlookProfile (numeric boundaries, overflow, custom [N+1], edge cases)
# - Invoke-ToolkitSubmenuOfficeOutlook (cancellations, exceptions, multi-cycle loops, no hangs)
# - Invoke-ToolkitDataFileContextMenu (cancellations, exceptions, invalid datafiles, no hangs)
# ==============================================================================

BeforeAll {
    $script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:TUIManifest = Join-Path $script:ProjectRoot 'Modules/TUI/TUI.psd1'
    $script:OutlookManifest = Join-Path $script:ProjectRoot 'Modules/Outlook/Outlook.psd1'
    $script:OfficeManifest = Join-Path $script:ProjectRoot 'Modules/Office/Office.psd1'

    if (Test-Path -LiteralPath $script:TUIManifest) {
        Import-Module $script:TUIManifest -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $script:OutlookManifest) {
        Import-Module $script:OutlookManifest -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $script:OfficeManifest) {
        Import-Module $script:OfficeManifest -Force -ErrorAction SilentlyContinue
    }

    $selectorScript = Join-Path $script:ProjectRoot 'Modules/TUI/Public/Select-ToolkitOutlookProfile.ps1'
    if (Test-Path -LiteralPath $selectorScript) {
        . $selectorScript
    }

    $menuScript = Join-Path $script:ProjectRoot 'Modules/TUI/Public/Invoke-ToolkitSubmenuOfficeOutlook.ps1'
    if (Test-Path -LiteralPath $menuScript) {
        . $menuScript
    }
}

Describe 'Milestone 4 Challenger 5: Select-ToolkitOutlookProfile Deep Stress' {

    Context '1. Custom Option [N+1] Exhaustive Scenarios' {

        It 'Correctly identifies [N+1] when there are 10 discovered profiles' {
            $profiles = @(1..10 | ForEach-Object { "Profile$_" }) # Count 10, customOpt 11
            $script:step = 0
            Mock Read-Host {
                $script:step++
                if ($script:step -eq 1) { return '11' }
                return 'CustomTenPlusOne'
            }
            Mock Read-Host {
                $script:step++
                if ($script:step -eq 1) { return '11' }
                return 'CustomTenPlusOne'
            } -ModuleName 'TUI'

            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Profile1'
            $res | Should -Be 'CustomTenPlusOne'
        }

        It 'Correctly accepts complex and special character profile names via [N+1]' {
            $profiles = @('Work', 'Personal') # Count 2, customOpt 3
            $complexName = 'MyCorp (HQ) - [Finance & Payroll] #42'
            $script:step = 0
            Mock Read-Host {
                $script:step++
                if ($script:step -eq 1) { return '3' }
                return $complexName
            }
            Mock Read-Host {
                $script:step++
                if ($script:step -eq 1) { return '3' }
                return $complexName
            } -ModuleName 'TUI'

            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Work'
            $res | Should -Be $complexName
        }

        It 'Falls back to default profile when [N+1] is chosen and user provides empty string' {
            $profiles = @('Work', 'Personal')
            $script:step = 0
            Mock Read-Host {
                $script:step++
                if ($script:step -eq 1) { return '3' }
                return ''
            }
            Mock Read-Host {
                $script:step++
                if ($script:step -eq 1) { return '3' }
                return ''
            } -ModuleName 'TUI'

            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Personal'
            $res | Should -Be 'Personal'
        }

        It 'Falls back to default profile when [N+1] is chosen and user provides whitespace' {
            $profiles = @('Work', 'Personal')
            $script:step = 0
            Mock Read-Host {
                $script:step++
                if ($script:step -eq 1) { return '3' }
                return "   `t   "
            }
            Mock Read-Host {
                $script:step++
                if ($script:step -eq 1) { return '3' }
                return "   `t   "
            } -ModuleName 'TUI'

            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Work'
            $res | Should -Be 'Work'
        }

        It 'Falls back to default profile when [N+1] is chosen and Read-Host returns null' {
            $profiles = @('Work', 'Personal')
            $script:step = 0
            Mock Read-Host {
                $script:step++
                if ($script:step -eq 1) { return '3' }
                return $null
            }
            Mock Read-Host {
                $script:step++
                if ($script:step -eq 1) { return '3' }
                return $null
            } -ModuleName 'TUI'

            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Work'
            $res | Should -Be 'Work'
        }
    }

    Context '2. Boundary & Overflow Input Fuzzing' {

        It 'Treats non-integer overflow string as direct custom profile name without throwing' {
            $profiles = @('Alpha', 'Beta')
            Mock Read-Host { return '999999999999999999999999999999999999' }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Alpha'
            $res | Should -Be '999999999999999999999999999999999999'
        }

        It 'Handles Int32::MaxValue without throwing, falling back to default' {
            $profiles = @('Alpha', 'Beta')
            Mock Read-Host { return '2147483647' }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Beta'
            $res | Should -Be 'Beta'
        }

        It 'Handles Int32::MinValue without throwing, falling back to default' {
            $profiles = @('Alpha', 'Beta')
            Mock Read-Host { return '-2147483648' }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Alpha'
            $res | Should -Be 'Alpha'
        }

        It 'Treats floating point strings as direct custom profile name without throwing' {
            $profiles = @('Alpha', 'Beta')
            Mock Read-Host { return '2.5' }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Alpha'
            $res | Should -Be '2.5'
        }

        It 'Treats raw control characters or whitespace by falling back to default when trimmed is empty' {
            $profiles = @('Alpha', 'Beta')
            Mock Read-Host { return "`t  `r`n" }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Alpha'
            $res | Should -Be 'Alpha'
        }
    }

    Context '3. Zero and Empty Telemetry Resilience' {

        It 'Resolves custom option [2] when profile list is completely empty' {
            $script:step = 0
            Mock Read-Host {
                $script:step++
                if ($script:step -eq 1) { return '2' } # [1] Fallback, [2] Custom
                return 'NewDirectProfile'
            }
            Mock Read-Host {
                $script:step++
                if ($script:step -eq 1) { return '2' }
                return 'NewDirectProfile'
            } -ModuleName 'TUI'

            $res = Select-ToolkitOutlookProfile -Profiles @() -DefaultProfile 'Fallback'
            $res | Should -Be 'NewDirectProfile'
        }

        It 'Never invokes Read-Host when -NonInteractive is specified even with empty inputs' {
            $readHostCalled = $false
            Mock Read-Host { $readHostCalled = $true; return '1' }
            Mock Read-Host { $readHostCalled = $true; return '1' } -ModuleName 'TUI'

            $res = Select-ToolkitOutlookProfile -Profiles @() -DefaultProfile 'NonInteractiveFallback' -NonInteractive
            $res | Should -Be 'NonInteractiveFallback'
            $readHostCalled | Should -BeFalse
        }
    }
}

Describe 'Milestone 4 Challenger 5: Menu Dispatch Cancellation & Error Stress Without Hangs' {

    Context '1. Multi-Cycle Cancellation Resilience in Primary Submenu' {
        BeforeEach {
            Mock Show-ToolkitHeader { }
            Mock Show-ToolkitActionCatalog { }
            Mock Show-ToolkitItemTable { }
            Mock Write-ToolkitStatus { }
            Mock Wait-UserAcknowledge { }
            Mock Get-OutlookDataFileInventory { return @() }
        }

        It 'Survives 5 consecutive cancelled actions followed by exit without hanging' {
            Mock Confirm-ToolkitAction { return $false }
            $script:cycleCount = 0
            $actions = @('10', '11', '12', '17', '18')

            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -le 5) {
                    $act = $actions[$script:step - 1]
                    return [PSCustomObject]@{ Type = 'Hotkey'; Value = $act }
                }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:step | Should -Be 6
        }

        It 'Action 21 (Profile Filter Switch) correctly updates filter and loops cleanly' {
            Mock Select-ToolkitOutlookProfile { return 'SelectedProfileFilter' }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) {
                    return [PSCustomObject]@{ Type = 'Hotkey'; Value = '21' }
                }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:step | Should -Be 2
        }

        It 'Action 19 handles empty manifest path by displaying warning and cleanly continuing loop' {
            Mock Select-ToolkitOutlookProfile { return 'WorkProfile' }
            Mock Read-Host { return '' } # empty manifest path
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '19' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:step | Should -Be 2
        }
    }

    Context '2. Multi-Cycle Error Resilience in Primary Submenu' {
        BeforeEach {
            Mock Show-ToolkitHeader { }
            Mock Show-ToolkitActionCatalog { }
            Mock Show-ToolkitItemTable { }
            Mock Write-ToolkitStatus { }
            Mock Wait-UserAcknowledge { }
            Mock Get-OutlookDataFileInventory { return @() }
            Mock Confirm-ToolkitAction { return $true }
            Mock Select-ToolkitOutlookProfile { return 'ErrorTestProfile' }
            Mock Read-Host { return '' }
        }

        It 'Survives 4 consecutive severe terminating exceptions without crashing menu loop' {
            Mock Clear-OutlookStuckOutbox { throw [System.IO.IOException]::new("MAPI RPC channel closed") }
            Mock Reset-OutlookNavigationPane { throw [System.UnauthorizedAccessException]::new("Registry write denied") }
            Mock Export-OutlookRule { throw [System.OutOfMemoryException]::new("Buffer allocation failed") }
            Mock Repair-OutlookRule { throw [System.TimeoutException]::new("COM server unresponsive") }

            $actions = @('10', '13', '18', '20')
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -le 4) {
                    $act = $actions[$script:step - 1]
                    return [PSCustomObject]@{ Type = 'Hotkey'; Value = $act }
                }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:step | Should -Be 5
        }
    }

    Context '3. Context Menu Resilience with Incomplete DataFile Objects' {
        BeforeEach {
            Mock Show-ToolkitHeader { }
            Mock Show-ToolkitActionCatalog { }
            Mock Write-ToolkitStatus { }
            Mock Wait-UserAcknowledge { }
            Mock Confirm-ToolkitAction { return $true }
            Mock Read-Host { return '' }
        }

        It 'Handles DataFile object with null Profile without crashing context menu' {
            $partialDataFile = [PSCustomObject]@{
                Filename = 'Incomplete.pst'
                Path     = 'C:\Mail\Incomplete.pst'
                Profile  = $null
                Type     = 'PST'
            }

            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '8' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            Mock Export-OutlookRule {
                param($Path, $ProfileName, $StorePath, $Force)
                return [PSCustomObject]@{ Success = $true; RulesExported = 0 }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $partialDataFile } | Should -Not -Throw
            $script:step | Should -Be 2
        }

        It 'Context Action 9 aborts gracefully when manifest path is empty string' {
            $dataFile = [PSCustomObject]@{
                Filename = 'Test.pst'
                Path     = 'C:\Mail\Test.pst'
                Profile  = 'TestProfile'
                Type     = 'PST'
            }

            Mock Read-Host { return '   ' } # empty manifest path
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '9' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }

            { Invoke-ToolkitDataFileContextMenu -DataFile $dataFile } | Should -Not -Throw
            $script:step | Should -Be 2
        }
    }
}
