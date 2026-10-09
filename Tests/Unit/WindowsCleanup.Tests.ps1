# ==============================================================================
# WindowsCleanup.Tests.ps1
# Unit test suite for Modules/WindowsCleanup
# Covers: Invoke-WindowsComponentCleanup, Clear-WindowsUpdateCache,
# Clear-WindowsDeliveryOptimizationCache, Clear-WindowsSystemLogs,
# Clear-WindowsTempCache, Invoke-WindowsCleanup.
# ==============================================================================

BeforeAll {
    $script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    $script:CleanupManifest = Join-Path $script:ProjectRoot 'Modules/WindowsCleanup/WindowsCleanup.psd1'

    # Stubs for native Windows commands & services if running on non-Windows
    $compatCmds = @('DISM', 'Stop-Service', 'Start-Service', 'Get-Service', 'Delete-DeliveryOptimizationCache')
    foreach ($cmd in $compatCmds) {
        $existing = Get-Command -Name $cmd -ErrorAction SilentlyContinue
        if (-not $existing -or -not ($existing.Parameters -and $existing.Parameters.ContainsKey('Name'))) {
            Set-Item -Path "function:global:$cmd" -Value {
                [CmdletBinding()]
                param(
                    [Parameter(Position = 0)]
                    [string]$Name,
                    [switch]$Force,
                    [Parameter(ValueFromRemainingArguments = $true)]
                    $RemainingArgs
                )
            }
        }
    }

    if (-not (Get-PSDrive -Name 'C' -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name 'C' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not (Get-PSDrive -Name 'D' -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name 'D' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -ErrorAction SilentlyContinue | Out-Null
    }

    # Import Core if present for shared utilities
    $coreManifest = Join-Path $script:ProjectRoot 'Modules/Core/Core.psd1'
    if (Test-Path -LiteralPath $coreManifest) {
        Import-Module $coreManifest -Force -ErrorAction SilentlyContinue
    }

    # Import WindowsCleanup module under test
    Import-Module $script:CleanupManifest -Force -ErrorAction Stop
}

Describe 'Unit: Windows Cleanup Module' {

    Context 'Module Manifest & Export Integrity' {
        It 'WindowsCleanup manifest exists and is valid' {
            Test-Path -LiteralPath $script:CleanupManifest | Should -BeTrue
            $manifest = Import-PowerShellDataFile -Path $script:CleanupManifest
            $manifest.PowerShellVersion | Should -Be '5.1'
            $manifest.FunctionsToExport | Should -Contain 'Invoke-WindowsComponentCleanup'
            $manifest.FunctionsToExport | Should -Contain 'Clear-WindowsUpdateCache'
            $manifest.FunctionsToExport | Should -Contain 'Clear-WindowsDeliveryOptimizationCache'
            $manifest.FunctionsToExport | Should -Contain 'Clear-WindowsSystemLogs'
            $manifest.FunctionsToExport | Should -Contain 'Clear-WindowsTempCache'
            $manifest.FunctionsToExport | Should -Contain 'Invoke-WindowsCleanup'
        }

        It 'All 6 public cmdlets are callable commands in session' {
            Get-Command -Name 'Invoke-WindowsComponentCleanup' -CommandType Function | Should -Not -BeNullOrEmpty
            Get-Command -Name 'Clear-WindowsUpdateCache' -CommandType Function | Should -Not -BeNullOrEmpty
            Get-Command -Name 'Clear-WindowsDeliveryOptimizationCache' -CommandType Function | Should -Not -BeNullOrEmpty
            Get-Command -Name 'Clear-WindowsSystemLogs' -CommandType Function | Should -Not -BeNullOrEmpty
            Get-Command -Name 'Clear-WindowsTempCache' -CommandType Function | Should -Not -BeNullOrEmpty
            Get-Command -Name 'Invoke-WindowsCleanup' -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Invoke-WindowsComponentCleanup' {
        It 'Executes default /StartComponentCleanup and returns success on exit code 0' {
            Mock Test-IsAdmin { return $true }
            $script:capturedDismArgs = $null
            Mock Start-Process {
                $script:capturedDismArgs = $ArgumentList
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $result = Invoke-WindowsComponentCleanup
            $result.Target | Should -Be 'ComponentStore'
            $result.ExitCode | Should -Be 0
            $result.Success | Should -BeTrue
            $result.Status | Should -Be 'Operation completed successfully'
            $result.ResetBaseUsed | Should -BeFalse

            $script:capturedDismArgs | Should -Contain '/Online'
            $script:capturedDismArgs | Should -Contain '/Cleanup-Image'
            $script:capturedDismArgs | Should -Contain '/StartComponentCleanup'
            $script:capturedDismArgs | Should -Not -Contain '/ResetBase'
        }

        It 'Appends /ResetBase when specified and sets ResetBaseUsed to true' {
            Mock Test-IsAdmin { return $true }
            $script:capturedDismArgs = $null
            Mock Start-Process {
                $script:capturedDismArgs = $ArgumentList
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $warns = $null
            $result = Invoke-WindowsComponentCleanup -ResetBase -WarningVariable warns -WarningAction SilentlyContinue
            $result.Success | Should -BeTrue
            $result.ResetBaseUsed | Should -BeTrue
            $script:capturedDismArgs | Should -Contain '/ResetBase'
            $warns.Count | Should -BeGreaterThan 0
            $warns[0].ToString() | Should -Match 'ResetBase'
        }

        It 'Executes /AnalyzeComponentStore when AnalyzeOnly switch is specified' {
            Mock Test-IsAdmin { return $true }
            $script:capturedDismArgs = $null
            Mock Start-Process {
                $script:capturedDismArgs = $ArgumentList
                return [PSCustomObject]@{ ExitCode = 0 }
            }

            $result = Invoke-WindowsComponentCleanup -AnalyzeOnly
            $result.Success | Should -BeTrue
            $script:capturedDismArgs | Should -Contain '/AnalyzeComponentStore'
            $script:capturedDismArgs | Should -Not -Contain '/StartComponentCleanup'
        }

        It 'Treats exit code 3010 as success with reboot required notice' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 3010 } }

            $result = Invoke-WindowsComponentCleanup
            $result.ExitCode | Should -Be 3010
            $result.Success | Should -BeTrue
            $result.Status | Should -Match 'restart is required'
        }

        It 'Evaluates non-zero exit code as failure' {
            Mock Test-IsAdmin { return $true }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 87 } }

            $result = Invoke-WindowsComponentCleanup
            $result.ExitCode | Should -Be 87
            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -Match '87'
        }

        It 'Supports -WhatIf simulation without running Start-Process' {
            Mock Start-Process { throw 'Start-Process must not be called during WhatIf' }

            $result = Invoke-WindowsComponentCleanup -WhatIf
            $result.Target | Should -Be 'ComponentStore'
            $result.Status | Should -Match 'WhatIf'
            $result.Success | Should -BeTrue
        }

        It 'Warns when administrative elevation is missing' {
            Mock Test-IsAdmin { return $false }
            Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }

            $warns = $null
            Invoke-WindowsComponentCleanup -WarningVariable warns -WarningAction SilentlyContinue | Out-Null
            $warns.Count | Should -BeGreaterThan 0
            $warns[0].ToString() | Should -Match 'Administrative privileges'
        }
    }

    Context 'Clear-WindowsUpdateCache' {
        It 'Stops services, purges download files, and restarts services in finally block' {
            Mock Test-IsAdmin { return $true }
            $testFolder = Join-Path ([System.IO.Path]::GetTempPath()) ("itoolkit_wu_test_" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -Path $testFolder -ItemType Directory -Force | Out-Null

            $file1 = Join-Path $testFolder 'update1.cab'
            $file2 = Join-Path $testFolder 'update2.msu'
            [System.IO.File]::WriteAllBytes($file1, [byte[]]@(1, 2, 3, 4))
            [System.IO.File]::WriteAllBytes($file2, [byte[]]@(5, 6, 7, 8, 9, 10))

            $stopped = [System.Collections.Generic.List[string]]::new()
            $started = [System.Collections.Generic.List[string]]::new()

            Mock Stop-Service {
                param($Name)
                $svcVal = if ($Name) { $Name } elseif ($args.Count -gt 0) { $args[0] } else { $null }
                $stopped.Add($svcVal)
            }
            Mock Start-Service {
                param($Name)
                $svcVal = if ($Name) { $Name } elseif ($args.Count -gt 0) { $args[0] } else { $null }
                $started.Add($svcVal)
            }

            try {
                $result = Clear-WindowsUpdateCache -Path $testFolder
                $result.Target | Should -Be 'WindowsUpdateCache'
                $result.Success | Should -BeTrue
                $result.ItemCount | Should -Be 2
                $result.ReclaimedBytes | Should -Be 10
                $result.ServicesRestarted | Should -Contain 'wuauserv'
                $result.ServicesRestarted | Should -Contain 'bits'

                $stopped | Should -Contain 'wuauserv'
                $stopped | Should -Contain 'bits'
                $started | Should -Contain 'wuauserv'
                $started | Should -Contain 'bits'

                Test-Path -LiteralPath $file1 | Should -BeFalse
                Test-Path -LiteralPath $file2 | Should -BeFalse
            }
            finally {
                Remove-Item -LiteralPath $testFolder -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Supports -WhatIf space analysis without stopping services or deleting files' {
            $testFolder = Join-Path ([System.IO.Path]::GetTempPath()) ("itoolkit_wu_whatif_" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -Path $testFolder -ItemType Directory -Force | Out-Null

            $file1 = Join-Path $testFolder 'payload.bin'
            [System.IO.File]::WriteAllBytes($file1, [byte[]]@(1, 2, 3, 4, 5))

            Mock Stop-Service { throw 'Stop-Service must not be called during WhatIf' }
            Mock Start-Service { throw 'Start-Service must not be called during WhatIf' }

            try {
                $result = Clear-WindowsUpdateCache -Path $testFolder -WhatIf
                $result.Status | Should -Match 'WhatIf'
                $result.Success | Should -BeTrue
                $result.ReclaimedBytes | Should -Be 5
                $result.ItemCount | Should -Be 1
                Test-Path -LiteralPath $file1 | Should -BeTrue
            }
            finally {
                Remove-Item -LiteralPath $testFolder -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Clear-WindowsDeliveryOptimizationCache' {
        It 'Purges delivery optimization cache directory' {
            Mock Test-IsAdmin { return $true }
            $testFolder = Join-Path ([System.IO.Path]::GetTempPath()) ("itoolkit_do_test_" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -Path $testFolder -ItemType Directory -Force | Out-Null

            $f1 = Join-Path $testFolder 'chunk1.dat'
            [System.IO.File]::WriteAllBytes($f1, [byte[]]@(1, 2, 3))

            try {
                $result = Clear-WindowsDeliveryOptimizationCache -Path $testFolder
                $result.Target | Should -Be 'DeliveryOptimization'
                $result.Success | Should -BeTrue
                $result.ItemCount | Should -Be 1
                $result.ReclaimedBytes | Should -Be 3
                Test-Path -LiteralPath $f1 | Should -BeFalse
            }
            finally {
                Remove-Item -LiteralPath $testFolder -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Supports -WhatIf without deleting delivery optimization files' {
            $testFolder = Join-Path ([System.IO.Path]::GetTempPath()) ("itoolkit_do_whatif_" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -Path $testFolder -ItemType Directory -Force | Out-Null

            $f1 = Join-Path $testFolder 'chunk.dat'
            [System.IO.File]::WriteAllBytes($f1, [byte[]]@(1, 2, 3, 4))

            try {
                $result = Clear-WindowsDeliveryOptimizationCache -Path $testFolder -WhatIf
                $result.Status | Should -Match 'WhatIf'
                $result.Success | Should -BeTrue
                $result.ReclaimedBytes | Should -Be 4
                $result.ItemCount | Should -Be 1
                Test-Path -LiteralPath $f1 | Should -BeTrue
            }
            finally {
                Remove-Item -LiteralPath $testFolder -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Clear-WindowsSystemLogs' {
        It 'Purges archived CBS logs and crash dumps while preserving active CBS.log' {
            Mock Test-IsAdmin { return $true }
            $baseDir = Join-Path ([System.IO.Path]::GetTempPath()) ("itoolkit_logs_test_" + [System.Guid]::NewGuid().ToString('N'))
            $cbsDir = Join-Path $baseDir 'Logs\CBS'
            New-Item -Path $cbsDir -ItemType Directory -Force | Out-Null

            # Active CBS.log (MUST BE PRESERVED)
            $activeCbs = Join-Path $cbsDir 'CBS.log'
            [System.IO.File]::WriteAllText($activeCbs, 'active log data')

            # Archived CBS logs (MUST BE DELETED)
            $archive1 = Join-Path $cbsDir 'CbsPersist_20261001.log'
            $archive2 = Join-Path $cbsDir 'CbsPersist_20261002.cab'
            [System.IO.File]::WriteAllBytes($archive1, [byte[]]@(1, 2, 3, 4))
            [System.IO.File]::WriteAllBytes($archive2, [byte[]]@(5, 6, 7, 8, 9, 10))

            # Temporarily redirect SystemRoot to test folder
            $origSysRoot = $env:SystemRoot
            $env:SystemRoot = $baseDir

            try {
                $result = Clear-WindowsSystemLogs -IncludeComponentLogs
                $result.Target | Should -Be 'SystemLogs'
                $result.Success | Should -BeTrue
                $result.ItemCount | Should -Be 2
                $result.ReclaimedBytes | Should -Be 10

                # Verify active CBS.log was preserved
                Test-Path -LiteralPath $activeCbs | Should -BeTrue
                Test-Path -LiteralPath $archive1 | Should -BeFalse
                Test-Path -LiteralPath $archive2 | Should -BeFalse
            }
            finally {
                $env:SystemRoot = $origSysRoot
                Remove-Item -LiteralPath $baseDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Supports -WhatIf space projection for system logs' {
            $baseDir = Join-Path ([System.IO.Path]::GetTempPath()) ("itoolkit_logs_whatif_" + [System.Guid]::NewGuid().ToString('N'))
            $miniDir = Join-Path $baseDir 'Minidump'
            New-Item -Path $miniDir -ItemType Directory -Force | Out-Null

            $dump1 = Join-Path $miniDir 'mini1.dmp'
            [System.IO.File]::WriteAllBytes($dump1, [byte[]]@(1, 2, 3, 4, 5))

            $origSysRoot = $env:SystemRoot
            $env:SystemRoot = $baseDir

            try {
                $result = Clear-WindowsSystemLogs -IncludeMemoryDumps -WhatIf
                $result.Status | Should -Match 'WhatIf'
                $result.Success | Should -BeTrue
                $result.ReclaimedBytes | Should -Be 5
                $result.ItemCount | Should -Be 1
                Test-Path -LiteralPath $dump1 | Should -BeTrue
            }
            finally {
                $env:SystemRoot = $origSysRoot
                Remove-Item -LiteralPath $baseDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Clear-WindowsTempCache' {
        It 'Purges files older than 24h and preserves active files younger than 24h' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("itoolkit_temp_test_" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

            $oldFile = Join-Path $tempDir 'old_installer.tmp'
            $youngFile = Join-Path $tempDir 'active_session.tmp'

            [System.IO.File]::WriteAllBytes($oldFile, [byte[]]@(1, 2, 3, 4, 5, 6, 7, 8))
            [System.IO.File]::WriteAllBytes($youngFile, [byte[]]@(9, 10, 11))

            # Set old file timestamp to 48 hours ago
            $past = (Get-Date).AddHours(-48)
            [System.IO.File]::SetLastWriteTime($oldFile, $past)
            [System.IO.File]::SetCreationTime($oldFile, $past)

            # Set young file timestamp to 2 hours ago
            $recent = (Get-Date).AddHours(-2)
            [System.IO.File]::SetLastWriteTime($youngFile, $recent)
            [System.IO.File]::SetCreationTime($youngFile, $recent)

            $origTemp = $env:TEMP
            $origTmp = $env:TMP
            $env:TEMP = $tempDir
            $env:TMP = $tempDir

            try {
                $result = Clear-WindowsTempCache -AgeHours 24 -IncludeUserTemp
                $result.Target | Should -Be 'TemporaryFiles'
                $result.Success | Should -BeTrue
                $result.ItemCount | Should -Be 1
                $result.ReclaimedBytes | Should -Be 8
                $result.SkippedCount | Should -Be 1

                # Old file deleted, young file preserved
                Test-Path -LiteralPath $oldFile | Should -BeFalse
                Test-Path -LiteralPath $youngFile | Should -BeTrue
            }
            finally {
                $env:TEMP = $origTemp
                $env:TMP = $origTmp
                Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Safely skips open/locked files without throwing terminating errors' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("itoolkit_temp_locked_" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

            $lockedFile = Join-Path $tempDir 'locked_app.tmp'
            $freeFile = Join-Path $tempDir 'free_data.tmp'

            [System.IO.File]::WriteAllBytes($lockedFile, [byte[]]@(1, 2, 3))
            [System.IO.File]::WriteAllBytes($freeFile, [byte[]]@(4, 5, 6, 7))

            # Backdate both files to qualify for deletion (>24h)
            $past = (Get-Date).AddHours(-72)
            [System.IO.File]::SetLastWriteTime($lockedFile, $past)
            [System.IO.File]::SetCreationTime($lockedFile, $past)
            [System.IO.File]::SetLastWriteTime($freeFile, $past)
            [System.IO.File]::SetCreationTime($freeFile, $past)

            # Mock Remove-Item to throw IOException for the locked file (cross-platform simulation)
            Mock Remove-Item {
                if ($LiteralPath -like "*locked_app*") {
                    throw [System.IO.IOException]::new("The process cannot access the file '$LiteralPath' because it is being used by another process.")
                }
                if (Test-Path -LiteralPath $LiteralPath -PathType Container) {
                    [System.IO.Directory]::Delete($LiteralPath, $true)
                }
                elseif (Test-Path -LiteralPath $LiteralPath) {
                    [System.IO.File]::Delete($LiteralPath)
                }
            }

            $origTemp = $env:TEMP
            $origTmp = $env:TMP
            $env:TEMP = $tempDir
            $env:TMP = $tempDir

            try {
                $result = Clear-WindowsTempCache -AgeHours 24 -IncludeUserTemp
                $result.Success | Should -BeTrue
                $result.ItemCount | Should -Be 1
                $result.ReclaimedBytes | Should -Be 4
                $result.SkippedCount | Should -Be 1

                # Locked file was skipped and kept; free file was deleted
                Test-Path -LiteralPath $lockedFile | Should -BeTrue
                Test-Path -LiteralPath $freeFile | Should -BeFalse
            }
            finally {
                $env:TEMP = $origTemp
                $env:TMP = $origTmp
                Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Supports -WhatIf space analysis without deleting files' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("itoolkit_temp_whatif_" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

            $oldFile = Join-Path $tempDir 'qualifying.tmp'
            [System.IO.File]::WriteAllBytes($oldFile, [byte[]]@(1, 2, 3, 4, 5))
            $past = (Get-Date).AddHours(-48)
            [System.IO.File]::SetLastWriteTime($oldFile, $past)
            [System.IO.File]::SetCreationTime($oldFile, $past)

            $origTemp = $env:TEMP
            $origTmp = $env:TMP
            $env:TEMP = $tempDir
            $env:TMP = $tempDir

            try {
                $result = Clear-WindowsTempCache -AgeHours 24 -IncludeUserTemp -WhatIf
                $result.Status | Should -Match 'WhatIf'
                $result.Success | Should -BeTrue
                $result.ReclaimedBytes | Should -Be 5
                $result.ItemCount | Should -Be 1
                Test-Path -LiteralPath $oldFile | Should -BeTrue
            }
            finally {
                $env:TEMP = $origTemp
                $env:TMP = $origTmp
                Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Invoke-WindowsCleanup Master Orchestrator' {
        It 'Orchestrates all categories when -All is specified and aggregates metrics' {
            Mock Clear-WindowsTempCache {
                return [PSCustomObject]@{ Target = 'TemporaryFiles'; ReclaimedBytes = [int64]100; ItemCount = 10; SkippedCount = 2; Success = $true }
            }
            Mock Clear-WindowsSystemLogs {
                return [PSCustomObject]@{ Target = 'SystemLogs'; ReclaimedBytes = [int64]200; ItemCount = 5; SkippedCount = 0; Success = $true }
            }
            Mock Clear-WindowsDeliveryOptimizationCache {
                return [PSCustomObject]@{ Target = 'DeliveryOptimization'; ReclaimedBytes = [int64]300; ItemCount = 3; SkippedCount = 1; Success = $true }
            }
            Mock Clear-WindowsUpdateCache {
                return [PSCustomObject]@{ Target = 'WindowsUpdateCache'; ReclaimedBytes = [int64]400; ItemCount = 4; SkippedCount = 0; Success = $true }
            }
            Mock Invoke-WindowsComponentCleanup {
                return [PSCustomObject]@{ Target = 'ComponentStore'; ReclaimedBytes = [int64]0; ItemCount = 0; SkippedCount = 0; Success = $true }
            }

            $masterResult = Invoke-WindowsCleanup -All
            $masterResult.Target | Should -Be 'MasterCleanup'
            $masterResult.Success | Should -BeTrue
            $masterResult.ReclaimedBytes | Should -Be 1000
            $masterResult.TotalReclaimedBytes | Should -Be 1000
            $masterResult.ItemCount | Should -Be 22
            $masterResult.TotalItemsCleaned | Should -Be 22
            $masterResult.SkippedCount | Should -Be 3
            $masterResult.TotalSkipped | Should -Be 3
            $masterResult.Results.Count | Should -Be 5
        }

        It 'Does NOT enable ResetBase when -All is invoked without explicit -ResetBase' {
            $script:passedResetBase = $null
            Mock Clear-WindowsTempCache { return [PSCustomObject]@{ Target = 'TemporaryFiles'; ReclaimedBytes = [int64]0; ItemCount = 0; SkippedCount = 0; Success = $true } }
            Mock Clear-WindowsSystemLogs { return [PSCustomObject]@{ Target = 'SystemLogs'; ReclaimedBytes = [int64]0; ItemCount = 0; SkippedCount = 0; Success = $true } }
            Mock Clear-WindowsDeliveryOptimizationCache { return [PSCustomObject]@{ Target = 'DeliveryOptimization'; ReclaimedBytes = [int64]0; ItemCount = 0; SkippedCount = 0; Success = $true } }
            Mock Clear-WindowsUpdateCache { return [PSCustomObject]@{ Target = 'WindowsUpdateCache'; ReclaimedBytes = [int64]0; ItemCount = 0; SkippedCount = 0; Success = $true } }
            Mock Invoke-WindowsComponentCleanup {
                param([switch]$ResetBase)
                $script:passedResetBase = [bool]$ResetBase
                return [PSCustomObject]@{ Target = 'ComponentStore'; ReclaimedBytes = [int64]0; ItemCount = 0; SkippedCount = 0; Success = $true }
            }

            $masterResult = Invoke-WindowsCleanup -All
            $script:passedResetBase | Should -BeFalse
        }

        It 'Passes ResetBase only when explicitly requested' {
            $script:passedResetBase = $null
            Mock Clear-WindowsTempCache { return [PSCustomObject]@{ Target = 'TemporaryFiles'; ReclaimedBytes = [int64]0; ItemCount = 0; SkippedCount = 0; Success = $true } }
            Mock Clear-WindowsSystemLogs { return [PSCustomObject]@{ Target = 'SystemLogs'; ReclaimedBytes = [int64]0; ItemCount = 0; SkippedCount = 0; Success = $true } }
            Mock Clear-WindowsDeliveryOptimizationCache { return [PSCustomObject]@{ Target = 'DeliveryOptimization'; ReclaimedBytes = [int64]0; ItemCount = 0; SkippedCount = 0; Success = $true } }
            Mock Clear-WindowsUpdateCache { return [PSCustomObject]@{ Target = 'WindowsUpdateCache'; ReclaimedBytes = [int64]0; ItemCount = 0; SkippedCount = 0; Success = $true } }
            Mock Invoke-WindowsComponentCleanup {
                param([switch]$ResetBase)
                $script:passedResetBase = [bool]$ResetBase
                return [PSCustomObject]@{ Target = 'ComponentStore'; ReclaimedBytes = [int64]0; ItemCount = 0; SkippedCount = 0; Success = $true }
            }

            $masterResult = Invoke-WindowsCleanup -All -ResetBase
            $script:passedResetBase | Should -BeTrue
        }

        It 'Runs only selected categories when specified by Category filter' {
            $calledCategories = [System.Collections.Generic.List[string]]::new()
            Mock Clear-WindowsTempCache {
                $calledCategories.Add('TempCache')
                return [PSCustomObject]@{ Target = 'TemporaryFiles'; ReclaimedBytes = [int64]50; ItemCount = 1; SkippedCount = 0; Success = $true }
            }
            Mock Clear-WindowsSystemLogs {
                $calledCategories.Add('SystemLogs')
                return [PSCustomObject]@{ Target = 'SystemLogs'; ReclaimedBytes = [int64]0; ItemCount = 0; SkippedCount = 0; Success = $true }
            }
            Mock Clear-WindowsDeliveryOptimizationCache {
                $calledCategories.Add('DeliveryOptimization')
                return [PSCustomObject]@{ Target = 'DeliveryOptimization'; ReclaimedBytes = [int64]0; ItemCount = 0; SkippedCount = 0; Success = $true }
            }
            Mock Clear-WindowsUpdateCache {
                $calledCategories.Add('UpdateCache')
                return [PSCustomObject]@{ Target = 'WindowsUpdateCache'; ReclaimedBytes = [int64]0; ItemCount = 0; SkippedCount = 0; Success = $true }
            }
            Mock Invoke-WindowsComponentCleanup {
                $calledCategories.Add('ComponentStore')
                return [PSCustomObject]@{ Target = 'ComponentStore'; ReclaimedBytes = [int64]0; ItemCount = 0; SkippedCount = 0; Success = $true }
            }

            $masterResult = Invoke-WindowsCleanup -Category 'TempCache'
            $masterResult.Success | Should -BeTrue
            $calledCategories | Should -Contain 'TempCache'
            $calledCategories | Should -Not -Contain 'UpdateCache'
            $calledCategories | Should -Not -Contain 'ComponentStore'
        }

        It 'Supports master -WhatIf simulation across all subsystems' {
            Mock Clear-WindowsTempCache {
                return [PSCustomObject]@{ Target = 'TemporaryFiles'; ReclaimedBytes = [int64]100; ItemCount = 2; SkippedCount = 1; Success = $true; Status = 'Simulated - WhatIf' }
            }
            Mock Clear-WindowsSystemLogs {
                return [PSCustomObject]@{ Target = 'SystemLogs'; ReclaimedBytes = [int64]200; ItemCount = 1; SkippedCount = 0; Success = $true; Status = 'Simulated - WhatIf' }
            }
            Mock Clear-WindowsDeliveryOptimizationCache {
                return [PSCustomObject]@{ Target = 'DeliveryOptimization'; ReclaimedBytes = [int64]300; ItemCount = 1; SkippedCount = 0; Success = $true; Status = 'Simulated - WhatIf' }
            }
            Mock Clear-WindowsUpdateCache {
                return [PSCustomObject]@{ Target = 'WindowsUpdateCache'; ReclaimedBytes = [int64]400; ItemCount = 1; SkippedCount = 0; Success = $true; Status = 'Simulated - WhatIf' }
            }
            Mock Invoke-WindowsComponentCleanup {
                return [PSCustomObject]@{ Target = 'ComponentStore'; ReclaimedBytes = [int64]0; ItemCount = 0; SkippedCount = 0; Success = $true; Status = 'Simulated - WhatIf' }
            }

            $masterResult = Invoke-WindowsCleanup -All -WhatIf
            $masterResult.Status | Should -Match 'WhatIf'
            $masterResult.Success | Should -BeTrue
            $masterResult.TotalReclaimedBytes | Should -Be 1000
        }
    }

    Context 'Safety Invariants (Strict Negative Verification)' {
        It 'Modules/WindowsCleanup contains ZERO registry cleaner code' {
            $cleanupDir = Join-Path $script:ProjectRoot 'Modules/WindowsCleanup'
            $files = Get-ChildItem -Path $cleanupDir -Filter '*.ps*' -Recurse -File
            foreach ($file in $files) {
                $content = Get-Content -LiteralPath $file.FullName -Raw
                # Prohibit registry manipulation / deletion
                $content | Should -Not -Match 'Remove-Item.*(?:HKLM|HKCU|Registry::)'
                $content | Should -Not -Match 'Remove-ItemProperty.*(?:HKLM|HKCU|Registry::)'
            }
        }

        It 'Modules/WindowsCleanup contains ZERO raw deletion of WinSxS or DriverStore' {
            $cleanupDir = Join-Path $script:ProjectRoot 'Modules/WindowsCleanup'
            $files = Get-ChildItem -Path $cleanupDir -Filter '*.ps*' -Recurse -File
            foreach ($file in $files) {
                $content = Get-Content -LiteralPath $file.FullName -Raw
                # Raw deletion of WinSxS or DriverStore is strictly prohibited
                $content | Should -Not -Match 'Remove-Item.*(?:WinSxS|DriverStore)'
            }
        }

        It 'Modules/WindowsCleanup contains ZERO tampering with System Restore or VSS shadows' {
            $cleanupDir = Join-Path $script:ProjectRoot 'Modules/WindowsCleanup'
            $files = Get-ChildItem -Path $cleanupDir -Filter '*.ps*' -Recurse -File
            foreach ($file in $files) {
                $content = Get-Content -LiteralPath $file.FullName -Raw
                $content | Should -Not -Match 'vssadmin'
                $content | Should -Not -Match 'Disable-ComputerRestore'
                $content | Should -Not -Match 'Checkpoint-Computer'
                $content | Should -Not -Match 'Delete-ShadowCopy'
            }
        }

        It 'Format-ByteSize private helper formats byte sizes accurately' {
            Format-ByteSize -Bytes 0 | Should -Be '0 B'
            Format-ByteSize -Bytes 1024 | Should -Be '1.00 KB'
            Format-ByteSize -Bytes 1048576 | Should -Be '1.00 MB'
            Format-ByteSize -Bytes 1073741824 | Should -Be '1.00 GB'
        }
    }
}
