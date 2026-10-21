# ==============================================================================
# ChallengerOutlookProfileAndMenuRouting.Tests.ps1
# Adversarial Challenger Stress Harness for:
# - Select-ToolkitOutlookProfile (numeric selection, custom option, bypass, out-of-bounds, edge cases)
# - Invoke-ToolkitSubmenuOfficeOutlook & Invoke-ToolkitDataFileContextMenu (cancellation and error routing)
# ==============================================================================

BeforeAll {
    $script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:TUIManifest = Join-Path $script:ProjectRoot 'Modules/TUI/TUI.psd1'
    $script:OutlookManifest = Join-Path $script:ProjectRoot 'Modules/Outlook/Outlook.psd1'

    if (Test-Path -LiteralPath $script:TUIManifest) {
        Import-Module $script:TUIManifest -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $script:OutlookManifest) {
        Import-Module $script:OutlookManifest -Force -ErrorAction SilentlyContinue
    }

    $script:OfficeManifest = Join-Path $script:ProjectRoot 'Modules/Office/Office.psd1'
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

Describe 'Challenger Stress Tests: Select-ToolkitOutlookProfile' {

    Context '1. Numeric Selection Verification' {
        It 'Selects profile [1] from multiple discovered profiles' {
            $profiles = @('Work', 'Personal', 'Archive')
            Mock Read-Host { return '1' }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Work'
            $res | Should -Be 'Work'
        }

        It 'Selects profile [2] from multiple discovered profiles' {
            $profiles = @('Work', 'Personal', 'Archive')
            Mock Read-Host { return '2' }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Work'
            $res | Should -Be 'Personal'
        }

        It 'Selects profile [N] (last profile) correctly' {
            $profiles = @('Work', 'Personal', 'Archive')
            Mock Read-Host { return '3' }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Work'
            $res | Should -Be 'Archive'
        }

        It 'Handles numeric selection with leading zero (e.g. 02 -> Personal)' {
            $profiles = @('Work', 'Personal', 'Archive')
            Mock Read-Host { return '02' }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Work'
            $res | Should -Be 'Personal'
        }

        It 'Handles numeric selection with padded whitespace (e.g. "  2  " -> Personal)' {
            $profiles = @('Work', 'Personal', 'Archive')
            Mock Read-Host { return '  2  ' }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Work'
            $res | Should -Be 'Personal'
        }

        It 'Defaults to effective default when user presses Enter (empty string)' {
            $profiles = @('Work', 'Personal', 'Archive')
            Mock Read-Host { return '' }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Personal'
            $res | Should -Be 'Personal'
        }

        It 'Defaults to effective default when Read-Host returns null' {
            $profiles = @('Work', 'Personal', 'Archive')
            Mock Read-Host { return $null }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Personal'
            $res | Should -Be 'Personal'
        }

        It 'Defaults to effective default when user inputs whitespace only' {
            $profiles = @('Work', 'Personal', 'Archive')
            Mock Read-Host { return '    ' }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Personal'
            $res | Should -Be 'Personal'
        }
    }

    Context '2. Custom Option [N+1] Handling' {
        It 'Prompts and returns custom profile name when [N+1] selected' {
            $profiles = @('Work', 'Personal') # Count is 2, customOpt is 3
            $script:step = 0
            Mock Read-Host {
                $script:step++
                if ($script:step -eq 1) { return '3' }
                return 'CustomEnterpriseProfile'
            }
            Mock Read-Host {
                $script:step++
                if ($script:step -eq 1) { return '3' }
                return 'CustomEnterpriseProfile'
            } -ModuleName 'TUI'
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Work'
            $res | Should -Be 'CustomEnterpriseProfile'
        }

        It 'Trims whitespace from custom profile input' {
            $profiles = @('Work', 'Personal')
            $script:step = 0
            Mock Read-Host {
                $script:step++
                if ($script:step -eq 1) { return '3' }
                return '   TrimmedCustomProfile   '
            }
            Mock Read-Host {
                $script:step++
                if ($script:step -eq 1) { return '3' }
                return '   TrimmedCustomProfile   '
            } -ModuleName 'TUI'
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Work'
            $res | Should -Be 'TrimmedCustomProfile'
        }

        It 'Falls back to default profile when custom input is empty string' {
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
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Work'
            $res | Should -Be 'Work'
        }

        It 'Falls back to default profile when custom input is whitespace only' {
            $profiles = @('Work', 'Personal')
            $script:step = 0
            Mock Read-Host {
                $script:step++
                if ($script:step -eq 1) { return '3' }
                return '      '
            }
            Mock Read-Host {
                $script:step++
                if ($script:step -eq 1) { return '3' }
                return '      '
            } -ModuleName 'TUI'
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Work'
            $res | Should -Be 'Work'
        }

        It 'Falls back to default profile when custom input is null' {
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

    Context '3. Direct String Input & Matching' {
        It 'Matches profile name directly by string case-insensitively' {
            $profiles = @('CorporateWork', 'PersonalMail')
            Mock Read-Host { return 'corporatework' }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'PersonalMail'
            $res | Should -Be 'CorporateWork'
        }

        It 'Accepts a direct custom profile name typed at the first prompt' {
            $profiles = @('CorporateWork', 'PersonalMail')
            Mock Read-Host { return 'ArbitraryDirectProfile' }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'CorporateWork'
            $res | Should -Be 'ArbitraryDirectProfile'
        }
    }

    Context '4. Non-Interactive Bypass Safeguard' {
        It 'Returns default profile immediately when -NonInteractive is passed without prompting' {
            $readHostCalled = $false
            Mock Read-Host { $readHostCalled = $true; return '2' }
            $res = Select-ToolkitOutlookProfile -Profiles @('Alpha', 'Beta') -DefaultProfile 'Beta' -NonInteractive
            $res | Should -Be 'Beta'
            $readHostCalled | Should -BeFalse
        }

        It 'Returns default profile immediately when $env:ITOOLKIT_NONINTERACTIVE is 1' {
            $readHostCalled = $false
            Mock Read-Host { $readHostCalled = $true; return '2' }
            $prevEnv = $env:ITOOLKIT_NONINTERACTIVE
            try {
                $env:ITOOLKIT_NONINTERACTIVE = '1'
                $res = Select-ToolkitOutlookProfile -Profiles @('Alpha', 'Beta') -DefaultProfile 'Beta'
                $res | Should -Be 'Beta'
                $readHostCalled | Should -BeFalse
            } finally {
                $env:ITOOLKIT_NONINTERACTIVE = $prevEnv
            }
        }
    }

    Context '5. Out-of-Bounds & Adversarial Input Handling' {
        It 'Falls back to default profile on negative numeric choice (-1)' {
            $profiles = @('Alpha', 'Beta')
            Mock Read-Host { return '-1' }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Alpha'
            $res | Should -Be 'Alpha'
        }

        It 'Falls back to default profile on choice 0 when 0 is not a profile name' {
            $profiles = @('Alpha', 'Beta')
            Mock Read-Host { return '0' }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Alpha'
            $res | Should -Be 'Alpha'
        }

        It 'Falls back to default profile on choice higher than custom option (e.g. 99)' {
            $profiles = @('Alpha', 'Beta') # Count 2, customOpt 3
            Mock Read-Host { return '99' }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Alpha'
            $res | Should -Be 'Alpha'
        }

        It 'Falls back to default profile on choice N+2 (e.g. 4 when N=2)' {
            $profiles = @('Alpha', 'Beta')
            Mock Read-Host { return '4' }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Beta'
            $res | Should -Be 'Beta'
        }

        It 'Correctly selects profile if a profile is literally named with a number' {
            $profiles = @('Profile1', '99')
            Mock Read-Host { return '99' }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Profile1'
            $res | Should -Be '99'
        }
    }

    Context '6. Edge Cases in Profile Discovery & Arguments' {
        It 'Handles empty profile array gracefully falling back to DefaultProfile' {
            Mock Read-Host { return '' }
            $res = Select-ToolkitOutlookProfile -Profiles @() -DefaultProfile 'FallbackProf'
            $res | Should -Be 'FallbackProf'
        }

        It 'Handles null Profiles argument falling back to DefaultProfile or Outlook' {
            Mock Read-Host { return '' }
            $res = Select-ToolkitOutlookProfile -DefaultProfile 'FallbackProf'
            $res | Should -Be 'FallbackProf'
        }

        It 'Handles null Profiles and null DefaultProfile falling back to Outlook' {
            Mock Read-Host { return '' }
            Mock Get-OutlookSystemContext { return $null }
            $res = Select-ToolkitOutlookProfile
            $res | Should -Be 'Outlook'
        }

        It 'Filters out duplicate and empty/whitespace profile entries' {
            $profiles = @('Alpha', '   ', '', 'Beta', 'Alpha', 'Beta')
            Mock Read-Host { return '2' }
            $res = Select-ToolkitOutlookProfile -Profiles $profiles -DefaultProfile 'Alpha'
            $res | Should -Be 'Beta'
        }

        It 'Survives Get-OutlookSystemContext throwing an unexpected exception' {
            Mock Get-OutlookSystemContext { throw "Registry Access Denied" }
            Mock Read-Host { return '1' }
            $res = Select-ToolkitOutlookProfile -Profiles @('SurvivingProfile') -DefaultProfile 'SurvivingProfile'
            $res | Should -Be 'SurvivingProfile'
        }
    }
}

Describe 'Challenger Stress Tests: Menu Action Routing Under Cancellation' {

    Context '1. Main Submenu (Invoke-ToolkitSubmenuOfficeOutlook) Cancellation Scenarios' {
        BeforeEach {
            Mock Show-ToolkitHeader { }
            Mock Show-ToolkitActionCatalog { }
            Mock Show-ToolkitItemTable { }
            Mock Write-ToolkitStatus { }
            Mock Wait-UserAcknowledge { }
            Mock Get-OutlookDataFileInventory { return @() }
        }

        It 'Action 10 (Clear Outbox) cancels safely when user declines confirmation' {
            $cleared = $false
            Mock Clear-OutlookStuckOutbox { $cleared = $true }
            Mock Confirm-ToolkitAction { return $false }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $cleared | Should -BeFalse
        }

        It 'Action 11 (Reset SRS) cancels safely when user declines confirmation' {
            $reset = $false
            Mock Reset-OutlookSendReceiveSettings { $reset = $true }
            Mock Confirm-ToolkitAction { return $false }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '11' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $reset | Should -BeFalse
        }

        It 'Action 12 (Clear RoamCache) cancels safely when user declines confirmation' {
            $cleared = $false
            Mock Clear-OutlookRoamCache { $cleared = $true }
            Mock Confirm-ToolkitAction { return $false }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '12' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $cleared | Should -BeFalse
        }

        It 'Action 13 (Reset NavPane) cancels safely when user declines confirmation' {
            $reset = $false
            Mock Reset-OutlookNavigationPane { $reset = $true }
            Mock Confirm-ToolkitAction { return $false }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '13' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $reset | Should -BeFalse
        }

        It 'Action 16 (Terminate Outlook) cancels safely when user declines confirmation' {
            $stopped = $false
            Mock Stop-OfficeProcess { $stopped = $true }
            Mock Confirm-ToolkitAction { return $false }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '16' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $stopped | Should -BeFalse
        }

        It 'Action 17 (New Default PST) cancels safely when user declines confirmation' {
            $newPstCalled = $false
            Mock New-OutlookDataFile { $newPstCalled = $true }
            Mock Confirm-ToolkitAction { return $false }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '17' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $newPstCalled | Should -BeFalse
        }

        It 'Action 18 (Export Rules) cancels safely when user declines confirmation' {
            $exported = $false
            Mock Export-OutlookRule { $exported = $true }
            Mock Select-ToolkitOutlookProfile { return 'WorkProfile' }
            Mock Read-Host { return '' }
            Mock Confirm-ToolkitAction { return $false }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '18' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $exported | Should -BeFalse
        }

        It 'Action 19 (Import Rules) cancels safely when user declines confirmation' {
            $imported = $false
            $tmpFile = [System.IO.Path]::GetTempFileName()
            try {
                Set-Content -Path $tmpFile -Value '{"Rules":[]}' -Encoding UTF8
                Mock Select-ToolkitOutlookProfile { return 'WorkProfile' }
                Mock Read-Host { return $tmpFile }
                Mock Confirm-ToolkitAction { return $false }
                Mock Import-OutlookRule { $imported = $true }
                $script:step = 0
                Mock Read-ToolkitItemSelection {
                    $script:step++
                    if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '19' } }
                    return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
                }
                { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
                $imported | Should -BeFalse
            } finally {
                if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'Action 19 (Import Rules) aborts when user specifies non-existent manifest file' {
            $imported = $false
            Mock Select-ToolkitOutlookProfile { return 'WorkProfile' }
            Mock Read-Host { return 'C:\NonExistent\GhostRules.json' }
            Mock Import-OutlookRule { $imported = $true }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '19' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $imported | Should -BeFalse
        }

        It 'Action 20 (Diagnostics & Auto-Repair) cancels safely when user declines confirmation' {
            $repaired = $false
            Mock Select-ToolkitOutlookProfile { return 'WorkProfile' }
            Mock Read-Host { return 'y' }
            Mock Confirm-ToolkitAction { return $false }
            Mock Repair-OutlookRule { $repaired = $true }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '20' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $repaired | Should -BeFalse
        }

        It 'Navigation Option 0 exits submenu immediately without errors' {
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                return [PSCustomObject]@{ Type = 'Hotkey'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:step | Should -Be 1
        }
    }

    Context '2. Context Menu (Invoke-ToolkitDataFileContextMenu) Cancellation Scenarios' {
        BeforeEach {
            Mock Show-ToolkitHeader { }
            Mock Show-ToolkitActionCatalog { }
            Mock Write-ToolkitStatus { }
            Mock Wait-UserAcknowledge { }
            $script:dummyFile = [PSCustomObject]@{
                Filename = 'Archive.pst'
                Path     = 'C:\Mail\Archive.pst'
                Profile  = 'WorkProfile'
                Type     = 'PST'
            }
        }

        It 'Context Action 7 (New Default PST) cancels safely when user declines confirmation' {
            $newPstCalled = $false
            Mock New-OutlookDataFile { $newPstCalled = $true }
            Mock Confirm-ToolkitAction { return $false }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '7' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitDataFileContextMenu -DataFile $script:dummyFile } | Should -Not -Throw
            $newPstCalled | Should -BeFalse
        }

        It 'Context Action 8 (Export Store Rules) cancels safely when user declines confirmation' {
            $exported = $false
            Mock Export-OutlookRule { $exported = $true }
            Mock Confirm-ToolkitAction { return $false }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '8' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitDataFileContextMenu -DataFile $script:dummyFile } | Should -Not -Throw
            $exported | Should -BeFalse
        }

        It 'Context Action 9 (Import Store Rules) cancels safely when user declines confirmation' {
            $imported = $false
            $tmpFile = [System.IO.Path]::GetTempFileName()
            try {
                Set-Content -Path $tmpFile -Value '{"Rules":[]}' -Encoding UTF8
                Mock Read-Host { return $tmpFile }
                Mock Confirm-ToolkitAction { return $false }
                Mock Import-OutlookRule { $imported = $true }
                $script:step = 0
                Mock Read-ToolkitItemSelection {
                    $script:step++
                    if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '9' } }
                    return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
                }
                { Invoke-ToolkitDataFileContextMenu -DataFile $script:dummyFile } | Should -Not -Throw
                $imported | Should -BeFalse
            } finally {
                if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'Context Action 10 (Diagnostics & Auto-Repair) cancels safely when user declines confirmation' {
            $repaired = $false
            Mock Read-Host { return 'y' }
            Mock Confirm-ToolkitAction { return $false }
            Mock Repair-OutlookRule { $repaired = $true }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitDataFileContextMenu -DataFile $script:dummyFile } | Should -Not -Throw
            $repaired | Should -BeFalse
        }
    }
}

Describe 'Challenger Stress Tests: Menu Action Routing Under Error Scenarios' {

    Context '1. Primary Submenu Resilient Exception Handling' {
        BeforeEach {
            Mock Show-ToolkitHeader { }
            Mock Show-ToolkitActionCatalog { }
            Mock Show-ToolkitItemTable { }
            Mock Write-ToolkitStatus { }
            Mock Wait-UserAcknowledge { }
            Mock Get-OutlookDataFileInventory { return @() }
            Mock Confirm-ToolkitAction { return $true }
            Mock Select-ToolkitOutlookProfile { return 'TestProfile' }
            Mock Read-Host { return '' }
        }

        It 'Action 10 catches terminating exceptions without crashing menu loop' {
            Mock Clear-OutlookStuckOutbox { throw "MAPI Outbox connection fault" }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:step | Should -Be 2
        }

        It 'Action 11 catches terminating exceptions without crashing menu loop' {
            Mock Reset-OutlookSendReceiveSettings { throw "Access to SRS file denied" }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '11' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:step | Should -Be 2
        }

        It 'Action 12 catches terminating exceptions without crashing menu loop' {
            Mock Clear-OutlookRoamCache { throw "Directory locked by antivirus" }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '12' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:step | Should -Be 2
        }

        It 'Action 13 catches terminating exceptions without crashing menu loop' {
            Mock Reset-OutlookNavigationPane { throw "Registry key corruption" }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '13' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:step | Should -Be 2
        }

        It 'Action 14 catches compaction terminating exceptions without crashing menu loop' {
            Mock Invoke-OutlookPstCompaction { throw "Disk I/O failure during compaction" }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '14' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:step | Should -Be 2
        }

        It 'Action 15 catches threshold evaluation terminating exceptions without crashing menu loop' {
            Mock Test-OutlookDataFileSize { throw "WMI RPC Server Unavailable" }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '15' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:step | Should -Be 2
        }

        It 'Action 16 catches process termination exceptions without crashing menu loop' {
            Mock Stop-OfficeProcess { throw "Privilege not held: SeDebugPrivilege" }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '16' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:step | Should -Be 2
        }

        It 'Action 17 catches New-OutlookDataFile exceptions without crashing menu loop' {
            Mock New-OutlookDataFile { throw "Failed to create MAPI store: 0x8004010F" }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '17' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:step | Should -Be 2
        }

        It 'Action 18 catches Export-OutlookRule exceptions without crashing menu loop' {
            Mock Export-OutlookRule { throw "Catastrophic failure in Rule.Export (E_FAIL)" }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '18' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:step | Should -Be 2
        }

        It 'Action 19 catches Import-OutlookRule exceptions without crashing menu loop' {
            $tmpFile = [System.IO.Path]::GetTempFileName()
            try {
                Set-Content -Path $tmpFile -Value '{"Rules":[]}' -Encoding UTF8
                Mock Read-Host { return $tmpFile }
                Mock Import-OutlookRule { throw "Target folder creation rejected: ACCESS_DENIED" }
                $script:step = 0
                Mock Read-ToolkitItemSelection {
                    $script:step++
                    if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '19' } }
                    return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
                }
                { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
                $script:step | Should -Be 2
            } finally {
                if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'Action 20 catches Repair-OutlookRule exceptions without crashing menu loop' {
            Mock Repair-OutlookRule { throw "Out of memory during rule AST parsing" }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '20' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitSubmenuOfficeOutlook } | Should -Not -Throw
            $script:step | Should -Be 2
        }
    }

    Context '2. Context Menu Resilient Exception Handling' {
        BeforeEach {
            Mock Show-ToolkitHeader { }
            Mock Show-ToolkitActionCatalog { }
            Mock Write-ToolkitStatus { }
            Mock Wait-UserAcknowledge { }
            Mock Confirm-ToolkitAction { return $true }
            Mock Read-Host { return '' }
            Mock Read-Host { return '' } -ModuleName 'TUI'
            $script:dummyFile = [PSCustomObject]@{
                Filename = 'Archive.pst'
                Path     = 'C:\Mail\Archive.pst'
                Profile  = 'WorkProfile'
                Type     = 'PST'
            }
        }

        It 'Context Action 8 catches Export-OutlookRule exceptions without crashing' {
            Mock Export-OutlookRule { throw "Store locked exclusively by another thread" }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '8' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitDataFileContextMenu -DataFile $script:dummyFile } | Should -Not -Throw
            $script:step | Should -Be 2
        }

        It 'Context Action 9 catches Import-OutlookRule exceptions without crashing' {
            $tmpFile = [System.IO.Path]::GetTempFileName()
            try {
                Set-Content -Path $tmpFile -Value '{"Rules":[]}' -Encoding UTF8
                Mock Read-Host { return $tmpFile }
                Mock Import-OutlookRule { throw "Invalid manifest schema version: null" }
                $script:step = 0
                Mock Read-ToolkitItemSelection {
                    $script:step++
                    if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '9' } }
                    return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
                }
                { Invoke-ToolkitDataFileContextMenu -DataFile $script:dummyFile } | Should -Not -Throw
                $script:step | Should -Be 2
            } finally {
                if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'Context Action 10 catches Repair-OutlookRule exceptions without crashing' {
            Mock Repair-OutlookRule { throw "MAPI RPC buffer overrun" }
            $script:step = 0
            Mock Read-ToolkitItemSelection {
                $script:step++
                if ($script:step -eq 1) { return [PSCustomObject]@{ Type = 'Hotkey'; Value = '10' } }
                return [PSCustomObject]@{ Type = 'Exit'; Value = '0' }
            }
            { Invoke-ToolkitDataFileContextMenu -DataFile $script:dummyFile } | Should -Not -Throw
            $script:step | Should -Be 2
        }
    }
}
