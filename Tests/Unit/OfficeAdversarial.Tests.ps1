# ==============================================================================
# OfficeAdversarial.Tests.ps1
# Adversarial stress test suite for Modules/Office
# Challenger M2.2 - Empirical Verification & Stress Testing
# Covers: Legacy Office rejection (14.0/15.0), missing Excel16.xlb, non-existent
# cache paths, negative/boundary thresholds, duplicate COM add-in registrations across
# hives, full WhatIf dry-run guarantees, ClickToRun repair argument formulation,
# and process termination scoping.
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:OfficeManifest = Join-Path $ProjectRoot 'Modules/Office/Office.psd1'
$isOfficeAvailable = Test-Path $script:OfficeManifest

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
    # Dot-source Office private helpers into test scope to enable unit testing of private functions
    Get-ChildItem -Path (Join-Path $root "Modules/Office/Private/*.ps1") | ForEach-Object { . $_.FullName }
}

Describe 'Adversarial: Office Module Edge Cases & Robustness' {

    Context '1. Legacy Office Version Rejection (14.0/15.0) & Hive Validation' {
        It 'Rejects Office 2010 (14.0) with expected exception message' -Skip:(-not $isOfficeAvailable) {
            { Assert-SupportedOfficeVersion -OfficeVersion '14.0' } |
                Should -Throw -ExpectedMessage '*Unsupported legacy Office version: 14.0. Only Office 16.0 (2016/2021/2024/C2R) is supported.*'
        }

        It 'Rejects Office 2013 (15.0) with expected exception message' -Skip:(-not $isOfficeAvailable) {
            { Assert-SupportedOfficeVersion -OfficeVersion '15.0' } |
                Should -Throw -ExpectedMessage '*Unsupported legacy Office version: 15.0. Only Office 16.0 (2016/2021/2024/C2R) is supported.*'
        }

        It 'Rejects point releases of legacy versions (14.0.7268 and 15.0.5589)' -Skip:(-not $isOfficeAvailable) {
            { Assert-SupportedOfficeVersion -OfficeVersion '14.0.7268.5000' } | Should -Throw -ExpectedMessage '*Unsupported legacy Office version*'
            { Assert-SupportedOfficeVersion -OfficeVersion '15.0.5589.1000' } | Should -Throw -ExpectedMessage '*Unsupported legacy Office version*'
        }

        It 'Accepts Office 16.0 (2016/2019/2021/2024/C2R)' -Skip:(-not $isOfficeAvailable) {
            Assert-SupportedOfficeVersion -OfficeVersion '16.0' | Should -BeTrue
            Assert-SupportedOfficeVersion -OfficeVersion '16.0.17928.20156' | Should -BeTrue
            Assert-SupportedOfficeVersion | Should -BeTrue
        }

        It 'Ensures zero hardcoded 14.0 or 15.0 registry paths exist in Modules/Office scripts' {
            $root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
            $officeFiles = Get-ChildItem -Path (Join-Path $root 'Modules/Office') -Filter '*.ps1' -Recurse
            foreach ($file in $officeFiles) {
                $content = Get-Content -Path $file.FullName -Raw
                # Should not target Office\14.0 or Office\15.0 registry keys
                $content | Should -Not -Match 'Office\\(?:14|15)\.0'
            }
        }
    }

    Context '2. Missing Excel16.xlb and Missing Directory Resilience' {
        It 'Reset-ExcelUiCache handles completely missing Excel16.xlb gracefully' -Skip:(-not $isOfficeAvailable) {
            Mock Test-Path { return $false }
            Mock Rename-Item { throw "Should not be called when file is missing" }

            $res = Reset-ExcelUiCache -CleanXlStart $false
            $res | Should -Not -BeNullOrEmpty
            $res.QuarantinedFiles.Count | Should -Be 0
            $res.RestoredBackup | Should -BeNullOrEmpty
        }

        It 'Reset-ExcelUiCache handles missing XLSTART directory gracefully when CleanXlStart is true' -Skip:(-not $isOfficeAvailable) {
            Mock Test-Path { return $false }
            Mock Rename-Item { throw "Should not be called when directory is missing" }

            $res = Reset-ExcelUiCache -CleanXlStart $true
            $res | Should -Not -BeNullOrEmpty
            $res.QuarantinedFiles.Count | Should -Be 0
            $res.RestoredBackup | Should -BeNullOrEmpty
        }

        It 'Reset-ExcelUiCache survives Rename-Item failure without throwing to caller' -Skip:(-not $isOfficeAvailable) {
            Mock Test-Path { return $true }
            Mock Rename-Item { throw [System.IO.IOException]::new("The process cannot access the file because it is being used by another process.") }

            { $res = Reset-ExcelUiCache -CleanXlStart $false } | Should -Not -Throw
        }

        It 'Reset-ExcelUiCache does not mark file as quarantined when Rename-Item throws' -Skip:(-not $isOfficeAvailable) {
            Mock Test-Path { return $true }
            Mock Rename-Item { throw [System.IO.IOException]::new("File locked") }

            $res = Reset-ExcelUiCache -CleanXlStart $false
            $res.QuarantinedFiles.Count | Should -Be 0
            $res.RestoredBackup | Should -BeNullOrEmpty
        }
    }

    Context '3. Non-Existent and Corrupt Cache Path Handling' {
        It 'Clear-OfficeTempCache handles non-existent cache directories gracefully' -Skip:(-not $isOfficeAvailable) {
            Mock Get-ChildItem { return @() }
            Mock Remove-Item { throw "Should not be called for non-existent files" }

            $res = Clear-OfficeTempCache -IncludeDocumentCache $true -IncludeWefCache $true
            $res.CleanedFilesCount | Should -Be 0
            $res.BytesFreed | Should -Be 0
        }

        It 'Clear-OfficeTempCache handles all flags set to false without operations' -Skip:(-not $isOfficeAvailable) {
            Mock Get-ChildItem { throw "Should not be called when all caches excluded" }

            $res = Clear-OfficeTempCache -IncludeDocumentCache $false -IncludeWefCache $false
            $res.CleanedFilesCount | Should -Be 0
            $res.BytesFreed | Should -Be 0
        }

        It 'Clear-OfficeTempCache catches filesystem errors without aborting' -Skip:(-not $isOfficeAvailable) {
            Mock Get-ChildItem { throw [System.UnauthorizedAccessException]::new("Access denied to cache directory") }

            { $res = Clear-OfficeTempCache } | Should -Not -Throw
        }

        It 'Clear-OfficeTempCache does not increment count or bytes when Remove-Item throws' -Skip:(-not $isOfficeAvailable) {
            Mock Get-ChildItem { return @([PSCustomObject]@{ FullName = 'C:\Temp\Locked.tmp'; Length = 1048576 }) }
            Mock Remove-Item { throw [System.IO.IOException]::new("File is locked by EXCEL.EXE") }

            $res = Clear-OfficeTempCache
            $res.CleanedFilesCount | Should -Be 0
            $res.BytesFreed | Should -Be 0
        }
    }

    Context '4. Negative and Boundary Thresholds in GDI Leak Detection' {
        It 'Get-ExcelGdiHandleUsage executes when given negative threshold' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process {
                return @(
                    [PSCustomObject]@{ Id = 2001; ProcessName = 'EXCEL'; HandleCount = 150; WorkingSet64 = 10485760 }
                )
            }
            # Negative threshold marks processes with >= 0 handles as leaking
            $usage = Get-ExcelGdiHandleUsage -WarningThreshold -100
            $usage.Count | Should -Be 1
            $usage[0].IsLeaking | Should -BeTrue
        }

        It 'Get-ExcelGdiHandleUsage handles 0 threshold properly' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process {
                return @(
                    [PSCustomObject]@{ Id = 2002; ProcessName = 'EXCEL'; HandleCount = 0; WorkingSet64 = 10485760 }
                )
            }
            $usage = Get-ExcelGdiHandleUsage -WarningThreshold 0
            $usage.Count | Should -Be 1
            $usage[0].IsLeaking | Should -BeTrue
        }

        It 'Get-ExcelGdiHandleUsage returns false when handle count is below high threshold' -Skip:(-not $isOfficeAvailable) {
            Mock Get-Process {
                return @(
                    [PSCustomObject]@{ Id = 2003; ProcessName = 'EXCEL'; HandleCount = 4500; WorkingSet64 = 52428800 }
                )
            }
            $usage = Get-ExcelGdiHandleUsage -WarningThreshold 5000
            $usage.Count | Should -Be 1
            $usage[0].IsLeaking | Should -BeFalse
        }

        It 'Stop-ExcelGdiLeakers executes with negative threshold' -Skip:(-not $isOfficeAvailable) {
            Mock Get-ExcelGdiHandleUsage {
                return @([PSCustomObject]@{ PID = 2004; ProcessName = 'EXCEL'; GdiHandles = 200; IsLeaking = $true })
            }
            Mock Stop-ToolkitProcess { [PSCustomObject]@{ Terminated = $true } }
            Mock Stop-Process { }

            $res = Stop-ExcelGdiLeakers -Threshold -100 -Force
            $res.Count | Should -Be 1
            $res.TerminatedPIDs | Should -Contain 2004
        }

        It 'Stop-ExcelGdiLeakers targets specific leaking PID without killing all instances' -Skip:(-not $isOfficeAvailable) {
            Mock Get-ExcelGdiHandleUsage {
                return @(
                    [PSCustomObject]@{ PID = 2004; ProcessName = 'EXCEL'; GdiHandles = 12000; IsLeaking = $true }
                )
            }
            $script:stopToolkitTarget = $null
            $script:stopToolkitId = $null
            Mock Stop-ToolkitProcess {
                param($ProcessName, $Id)
                $script:stopToolkitTarget = $ProcessName
                $script:stopToolkitId = $Id
                return [PSCustomObject]@{ Terminated = $true }
            }
            Mock Stop-Process { }

            $res = Stop-ExcelGdiLeakers -Threshold 8000 -Force
            $script:stopToolkitTarget | Should -Be 'EXCEL'
            $script:stopToolkitId | Should -Be 2004
            $res.Count | Should -Be 1
            $res.TerminatedPIDs | Should -Contain 2004
        }
    }

    Context '5. Duplicate COM Add-in Registrations Across Registry Hives' {
        It 'Get-ExcelComAddin deduplicates identical ProgId across HKCU and HKLM hives' -Skip:(-not $isOfficeAvailable) {
            Mock Get-ChildItem {
                param($Path)
                if ($Path -match '^HKCU') {
                    return @(
                        [PSCustomObject]@{
                            PSChildName = 'SharedAddin.ProgId'
                            GetValue    = { param($k) if ($k -eq 'LoadBehavior') { return 2 } else { return 'HKCU Friendly Name' } }
                        }
                    )
                }
                elseif ($Path -match '^HKLM') {
                    return @(
                        [PSCustomObject]@{
                            PSChildName = 'SharedAddin.ProgId'
                            GetValue    = { param($k) if ($k -eq 'LoadBehavior') { return 3 } else { return 'HKLM Friendly Name' } }
                        }
                    )
                }
                return @()
            }

            $addins = Get-ExcelComAddin
            # Must be deduplicated to exactly 1 entry
            $addins.Count | Should -Be 1
            $addins[0].ProgId | Should -Be 'SharedAddin.ProgId'
            # HKCU takes precedence
            $addins[0].Location | Should -Be 'HKCU'
            $addins[0].LoadBehavior | Should -Be 2
        }

        It 'Get-ExcelComAddin performs case-insensitive deduplication of ProgIds' -Skip:(-not $isOfficeAvailable) {
            Mock Get-ChildItem {
                param($Path)
                if ($Path -match '^HKCU') {
                    return @(
                        [PSCustomObject]@{
                            PSChildName = 'CaseTest.Plugin'
                            GetValue    = { param($k) if ($k -eq 'LoadBehavior') { return 3 } else { return 'Case Test' } }
                        }
                    )
                }
                elseif ($Path -match '^HKLM') {
                    return @(
                        [PSCustomObject]@{
                            PSChildName = 'casetest.plugin'
                            GetValue    = { param($k) if ($k -eq 'LoadBehavior') { return 1 } else { return 'Lower Case Test' } }
                        }
                    )
                }
                return @()
            }

            $addins = Get-ExcelComAddin
            $addins.Count | Should -Be 1
            $addins[0].ProgId | Should -Be 'CaseTest.Plugin'
        }

        It 'Get-ExcelComAddin preserves distinct add-ins across different hives' -Skip:(-not $isOfficeAvailable) {
            Mock Get-ChildItem {
                param($Path)
                if ($Path -match '^HKCU') {
                    return @([PSCustomObject]@{ PSChildName = 'UserAddin'; GetValue = { param($k) return 3 } })
                }
                elseif ($Path -match 'WOW6432Node') {
                    return @([PSCustomObject]@{ PSChildName = 'WowAddin'; GetValue = { param($k) return 3 } })
                }
                elseif ($Path -match '^HKLM') {
                    return @([PSCustomObject]@{ PSChildName = 'SystemAddin'; GetValue = { param($k) return 3 } })
                }
                return @()
            }

            $addins = Get-ExcelComAddin
            $addins.Count | Should -Be 3
            $addins.ProgId | Should -Contain 'UserAddin'
            $addins.ProgId | Should -Contain 'SystemAddin'
            $addins.ProgId | Should -Contain 'WowAddin'
        }
    }

    Context '6. Comprehensive WhatIf / Dry-Run Invariance Across Mutating Cmdlets' {
        It 'Set-ExcelHardwareAcceleration does not invoke Set-ToolkitRegistryValue under WhatIf' -Skip:(-not $isOfficeAvailable) {
            Mock Set-ToolkitRegistryValue { throw "Set-ToolkitRegistryValue must not be called during WhatIf" }

            $res = Set-ExcelHardwareAcceleration -Disable $true -WhatIf
            $res.Disabled | Should -BeTrue
            $res.RegBackupFile | Should -Match 'WhatIf'
        }

        It 'Reset-ExcelUiCache does not invoke Rename-Item or Stop-ToolkitProcess under WhatIf' -Skip:(-not $isOfficeAvailable) {
            Mock Rename-Item { throw "Rename-Item must not be called during WhatIf" }
            Mock Stop-ToolkitProcess { throw "Stop-ToolkitProcess must not be called during WhatIf" }

            $res = Reset-ExcelUiCache -CleanXlStart $true -WhatIf
            $res.QuarantinedFiles | Should -Contain '[Simulated - WhatIf]'
            $res.RestoredBackup | Should -BeNullOrEmpty
        }

        It 'Clear-OfficeTempCache does not invoke Remove-Item under WhatIf' -Skip:(-not $isOfficeAvailable) {
            Mock Remove-Item { throw "Remove-Item must not be called during WhatIf" }

            $res = Clear-OfficeTempCache -WhatIf
            $res.CleanedFilesCount | Should -Be 0
            $res.BytesFreed | Should -Be 0
        }

        It 'Set-ExcelComAddinState does not invoke Set-ToolkitRegistryValue under WhatIf' -Skip:(-not $isOfficeAvailable) {
            Mock Set-ToolkitRegistryValue { throw "Set-ToolkitRegistryValue must not be called during WhatIf" }

            $res = Set-ExcelComAddinState -ProgId 'MyAddin' -LoadBehavior 0 -WhatIf
            $res.ProgId | Should -Be 'MyAddin'
            $res.NewBehavior | Should -Be 0
            $res.PreviousBehavior | Should -BeNullOrEmpty
        }

        It 'Reset-ExcelResiliency does not invoke Remove-ItemProperty under WhatIf' -Skip:(-not $isOfficeAvailable) {
            Mock Remove-ItemProperty { throw "Remove-ItemProperty must not be called during WhatIf" }
            Mock Export-RegistryKeyBackup { throw "Export-RegistryKeyBackup must not be called during WhatIf" }

            $res = Reset-ExcelResiliency -WhatIf
            $res.ClearedItemsCount | Should -Be 0
            $res.RegBackupFile | Should -Match 'WhatIf'
        }

        It 'Stop-ExcelGdiLeakers does not terminate processes under WhatIf' -Skip:(-not $isOfficeAvailable) {
            Mock Stop-Process { throw "Stop-Process must not be called during WhatIf" }
            Mock Stop-ToolkitProcess { throw "Stop-ToolkitProcess must not be called during WhatIf" }

            $res = Stop-ExcelGdiLeakers -Threshold 5000 -WhatIf
            $res.Count | Should -Be 0
            $res.TerminatedPIDs.Count | Should -Be 0
        }

        It 'Start-OfficeClickToRunRepair does not invoke Start-Process under WhatIf' -Skip:(-not $isOfficeAvailable) {
            Mock Start-Process { throw "Start-Process must not be called during WhatIf" }

            $res = Start-OfficeClickToRunRepair -RepairType 'Quick' -WhatIf
            $res.Launched | Should -BeFalse
            $res.ExitCode | Should -Be 0
        }
    }

    Context '7. ClickToRun Repair Scenario & Argument Formulation' {
        It 'Start-OfficeClickToRunRepair formats arguments for Quick repair' -Skip:(-not $isOfficeAvailable) {
            $capturedArgs = $null
            Mock Start-Process {
                $script:capturedArgs = $ArgumentList
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $res = Start-OfficeClickToRunRepair -RepairType 'Quick'
            $res.Launched | Should -BeTrue
            $script:capturedArgs | Should -Contain 'scenario=Repair'
            $script:capturedArgs | Should -Contain 'RepairType=QuickRepair'
            $script:capturedArgs | Should -Contain 'DisplayLevel=True'
            $script:capturedArgs | Should -Contain 'forceappshutdown=True'
        }

        It 'Start-OfficeClickToRunRepair formats arguments for Online repair' -Skip:(-not $isOfficeAvailable) {
            $capturedArgs = $null
            Mock Start-Process {
                $script:capturedArgs = $ArgumentList
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $res = Start-OfficeClickToRunRepair -RepairType 'Online'
            $res.Launched | Should -BeTrue
            $script:capturedArgs | Should -Contain 'scenario=Repair'
            $script:capturedArgs | Should -Contain 'RepairType=FullRepair'
            $script:capturedArgs | Should -Contain 'DisplayLevel=True'
        }

        It 'Start-OfficeClickToRunRepair handles QuickRepair and FullRepair synonyms' -Skip:(-not $isOfficeAvailable) {
            $capturedArgs = $null
            Mock Start-Process {
                $script:capturedArgs = $ArgumentList
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $null = Start-OfficeClickToRunRepair -RepairType 'QuickRepair'
            $script:capturedArgs | Should -Contain 'RepairType=QuickRepair'

            $null = Start-OfficeClickToRunRepair -RepairType 'FullRepair'
            $script:capturedArgs | Should -Contain 'RepairType=FullRepair'
        }

        It 'Start-OfficeClickToRunRepair formats DisplayLevel=False when DisplayMode is Silent' -Skip:(-not $isOfficeAvailable) {
            $capturedArgs = $null
            Mock Start-Process {
                $script:capturedArgs = $ArgumentList
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $res = Start-OfficeClickToRunRepair -RepairType 'Quick' -DisplayMode 'Silent'
            $script:capturedArgs | Should -Contain 'DisplayLevel=False'
        }

        It 'Start-OfficeClickToRunRepair validates RepairType against ValidateSet' -Skip:(-not $isOfficeAvailable) {
            { Start-OfficeClickToRunRepair -RepairType 'InvalidType' } | Should -Throw
        }

        It 'Start-OfficeClickToRunRepair validates DisplayMode against ValidateSet' -Skip:(-not $isOfficeAvailable) {
            { Start-OfficeClickToRunRepair -RepairType 'Quick' -DisplayMode 'InvalidMode' } | Should -Throw
        }
    }
}
