# ==============================================================================
# WindowsCleanupAdversarial.Tests.ps1
# Adversarial verification and empirical stress-testing suite for Modules/WindowsCleanup
# Covers: WhatIf dry-run, locked file handling, age filtering, negative invariants,
# parameter validation, and boundary conditions.
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

    # Import WindowsCleanup module under test
    Import-Module $script:CleanupManifest -Force -ErrorAction Stop
}

Describe 'Adversarial Stress: Modules/WindowsCleanup' {

    # --------------------------------------------------------------------------
    # 1. WhatIf Mode Verification (Dry-Run Space Analysis & Zero Deletion Guarantee)
    # --------------------------------------------------------------------------
    Context '1. WhatIf Mode Verification (Zero Deletions & Accurate Projections)' {

        It 'Clear-WindowsTempCache -WhatIf accurately projects bytes and deletes zero files' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wc_stress_whatif_temp_" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -Path $testDir -ItemType Directory -Force | Out-Null

            $subDir = Join-Path $testDir 'subFolder'
            New-Item -Path $subDir -ItemType Directory -Force | Out-Null

            # Qualifying old files (>24h)
            $f1 = Join-Path $testDir 'old1.tmp'
            $f2 = Join-Path $testDir 'old2.tmp'
            $f3 = Join-Path $subDir  'sub_old1.tmp'
            [System.IO.File]::WriteAllBytes($f1, [byte[]]::new(100))
            [System.IO.File]::WriteAllBytes($f2, [byte[]]::new(250))
            [System.IO.File]::WriteAllBytes($f3, [byte[]]::new(150))

            # Non-qualifying young files (<24h)
            $fYoung1 = Join-Path $testDir 'young1.tmp'
            $fYoung2 = Join-Path $subDir  'sub_young.tmp'
            [System.IO.File]::WriteAllBytes($fYoung1, [byte[]]::new(50))
            [System.IO.File]::WriteAllBytes($fYoung2, [byte[]]::new(75))

            $past = (Get-Date).AddHours(-48)
            $recent = (Get-Date).AddHours(-2)

            foreach ($oldPath in @($f1, $f2, $f3)) {
                [System.IO.File]::SetLastWriteTime($oldPath, $past)
                [System.IO.File]::SetCreationTime($oldPath, $past)
            }
            foreach ($youngPath in @($fYoung1, $fYoung2)) {
                [System.IO.File]::SetLastWriteTime($youngPath, $recent)
                [System.IO.File]::SetCreationTime($youngPath, $recent)
            }

            $origTemp = $env:TEMP
            $origTmp = $env:TMP
            $env:TEMP = $testDir
            $env:TMP = $testDir

            try {
                $result = Clear-WindowsTempCache -AgeHours 24 -IncludeUserTemp -WhatIf

                $result.Status | Should -Match 'WhatIf'
                $result.Success | Should -BeTrue
                # Expected qualifying bytes: 100 + 250 + 150 = 500 bytes
                $result.ReclaimedBytes | Should -Be 500
                $result.ItemCount | Should -Be 3
                $result.SkippedCount | Should -Be 2

                # EMPIRICAL ZERO DELETION INVARIANT
                Test-Path -LiteralPath $f1 | Should -BeTrue
                Test-Path -LiteralPath $f2 | Should -BeTrue
                Test-Path -LiteralPath $f3 | Should -BeTrue
                Test-Path -LiteralPath $fYoung1 | Should -BeTrue
                Test-Path -LiteralPath $fYoung2 | Should -BeTrue
                Test-Path -LiteralPath $subDir | Should -BeTrue
            }
            finally {
                $env:TEMP = $origTemp
                $env:TMP = $origTmp
                Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Clear-WindowsUpdateCache -WhatIf projects size without deleting or stopping services' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wc_stress_whatif_wu_" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -Path $testDir -ItemType Directory -Force | Out-Null

            $f1 = Join-Path $testDir 'update_A.cab'
            $f2 = Join-Path $testDir 'update_B.msu'
            [System.IO.File]::WriteAllBytes($f1, [byte[]]::new(1024))
            [System.IO.File]::WriteAllBytes($f2, [byte[]]::new(2048))

            Mock Stop-Service { throw 'Stop-Service must not be called during WhatIf' }
            Mock Start-Service { throw 'Start-Service must not be called during WhatIf' }

            try {
                $result = Clear-WindowsUpdateCache -Path $testDir -WhatIf
                $result.Status | Should -Match 'WhatIf'
                $result.Success | Should -BeTrue
                $result.ReclaimedBytes | Should -Be 3072
                $result.ItemCount | Should -Be 2
                $result.ServicesRestarted.Count | Should -Be 0

                # EMPIRICAL ZERO DELETION
                Test-Path -LiteralPath $f1 | Should -BeTrue
                Test-Path -LiteralPath $f2 | Should -BeTrue
            }
            finally {
                Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Clear-WindowsDeliveryOptimizationCache -WhatIf projects space without deleting files' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wc_stress_whatif_do_" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -Path $testDir -ItemType Directory -Force | Out-Null

            $chunk1 = Join-Path $testDir 'payload1.dat'
            $chunk2 = Join-Path $testDir 'payload2.dat'
            [System.IO.File]::WriteAllBytes($chunk1, [byte[]]::new(512))
            [System.IO.File]::WriteAllBytes($chunk2, [byte[]]::new(512))

            try {
                $result = Clear-WindowsDeliveryOptimizationCache -Path $testDir -WhatIf
                $result.Status | Should -Match 'WhatIf'
                $result.Success | Should -BeTrue
                $result.ReclaimedBytes | Should -Be 1024
                $result.ItemCount | Should -Be 2

                Test-Path -LiteralPath $chunk1 | Should -BeTrue
                Test-Path -LiteralPath $chunk2 | Should -BeTrue
            }
            finally {
                Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Clear-WindowsSystemLogs -WhatIf projects logs and dumps without touching disk' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wc_stress_whatif_logs_" + [System.Guid]::NewGuid().ToString('N'))
            $cbsDir = Join-Path $testDir 'Logs\CBS'
            $miniDir = Join-Path $testDir 'Minidump'
            New-Item -Path $cbsDir -ItemType Directory -Force | Out-Null
            New-Item -Path $miniDir -ItemType Directory -Force | Out-Null

            $activeLog = Join-Path $cbsDir 'CBS.log'
            $persistLog = Join-Path $cbsDir 'CbsPersist_2026.log'
            $dumpFile = Join-Path $miniDir 'crash.dmp'

            [System.IO.File]::WriteAllBytes($activeLog, [byte[]]::new(100))
            [System.IO.File]::WriteAllBytes($persistLog, [byte[]]::new(400))
            [System.IO.File]::WriteAllBytes($dumpFile, [byte[]]::new(600))

            $origSysRoot = $env:SystemRoot
            $env:SystemRoot = $testDir

            try {
                $result = Clear-WindowsSystemLogs -IncludeMemoryDumps -IncludeComponentLogs -WhatIf
                $result.Status | Should -Match 'WhatIf'
                $result.Success | Should -BeTrue
                $result.ReclaimedBytes | Should -Be 1000
                $result.ItemCount | Should -Be 2

                # All files must remain
                Test-Path -LiteralPath $activeLog | Should -BeTrue
                Test-Path -LiteralPath $persistLog | Should -BeTrue
                Test-Path -LiteralPath $dumpFile | Should -BeTrue
            }
            finally {
                $env:SystemRoot = $origSysRoot
                Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Invoke-WindowsCleanup master -WhatIf aggregates all categories with zero side-effects' {
            $masterDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wc_stress_whatif_master_" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -Path $masterDir -ItemType Directory -Force | Out-Null

            $tempFile = Join-Path $masterDir 'temp_old.tmp'
            [System.IO.File]::WriteAllBytes($tempFile, [byte[]]::new(800))
            $past = (Get-Date).AddHours(-48)
            [System.IO.File]::SetLastWriteTime($tempFile, $past)
            [System.IO.File]::SetCreationTime($tempFile, $past)

            $origTemp = $env:TEMP
            $origTmp = $env:TMP
            $env:TEMP = $masterDir
            $env:TMP = $masterDir

            try {
                $result = Invoke-WindowsCleanup -Category 'TempCache' -WhatIf
                $result.Target | Should -Be 'MasterCleanup'
                $result.Status | Should -Match 'WhatIf'
                $result.Success | Should -BeTrue
                $result.TotalReclaimedBytes | Should -Be 800
                $result.TotalItemsCleaned | Should -Be 1

                # File remains intact
                Test-Path -LiteralPath $tempFile | Should -BeTrue
            }
            finally {
                $env:TEMP = $origTemp
                $env:TMP = $origTmp
                Remove-Item -LiteralPath $masterDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # --------------------------------------------------------------------------
    # 2. Locked File Handling & Resilience (System.IO.FileStream + Exceptions)
    # --------------------------------------------------------------------------
    Context '2. Locked File Handling & Graceful Degradation' {

        It 'Clear-WindowsTempCache safely bypasses locked file held open with FileStream and deletes free file' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wc_stress_lock_temp_" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -Path $testDir -ItemType Directory -Force | Out-Null

            $freeFile = Join-Path $testDir 'free_data.tmp'
            $lockedFile = Join-Path $testDir 'exclusive_locked.tmp'

            [System.IO.File]::WriteAllBytes($freeFile, [byte[]]::new(300))
            [System.IO.File]::WriteAllBytes($lockedFile, [byte[]]::new(500))

            $past = (Get-Date).AddHours(-48)
            [System.IO.File]::SetLastWriteTime($freeFile, $past)
            [System.IO.File]::SetCreationTime($freeFile, $past)
            [System.IO.File]::SetLastWriteTime($lockedFile, $past)
            [System.IO.File]::SetCreationTime($lockedFile, $past)

            # Hold exclusive lock using FileStream
            $fileStream = [System.IO.FileStream]::new(
                $lockedFile,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )

            # Mock Remove-Item to throw IOException for the locked file (cross-platform simulation)
            Mock Remove-Item {
                if ($LiteralPath -like "*exclusive_locked*") {
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
            $env:TEMP = $testDir
            $env:TMP = $testDir

            try {
                $result = Clear-WindowsTempCache -AgeHours 24 -IncludeUserTemp

                # Must not throw unhandled exception
                $result.Success | Should -BeTrue
                $result.ItemCount | Should -Be 1
                $result.ReclaimedBytes | Should -Be 300
                $result.SkippedCount | Should -Be 1
                $result.Status | Should -Match 'retained: locked'

                # Free file was deleted
                Test-Path -LiteralPath $freeFile | Should -BeFalse

                # Locked file was safely skipped and preserved
                Test-Path -LiteralPath $lockedFile | Should -BeTrue
            }
            finally {
                $fileStream.Close()
                $fileStream.Dispose()
                $env:TEMP = $origTemp
                $env:TMP = $origTmp
                Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Clear-WindowsTempCache preserves directory structure when subfolder contains a locked file' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wc_stress_lock_subdir_" + [System.Guid]::NewGuid().ToString('N'))
            $subDir = Join-Path $testDir 'app_cache'
            New-Item -Path $subDir -ItemType Directory -Force | Out-Null

            $freeFile = Join-Path $subDir 'sub_free.tmp'
            $lockedFile = Join-Path $subDir 'sub_locked.tmp'

            [System.IO.File]::WriteAllBytes($freeFile, [byte[]]::new(200))
            [System.IO.File]::WriteAllBytes($lockedFile, [byte[]]::new(400))

            $past = (Get-Date).AddHours(-72)
            [System.IO.File]::SetLastWriteTime($freeFile, $past)
            [System.IO.File]::SetCreationTime($freeFile, $past)
            [System.IO.File]::SetLastWriteTime($lockedFile, $past)
            [System.IO.File]::SetCreationTime($lockedFile, $past)
            [System.IO.File]::SetLastWriteTime($subDir, $past)
            [System.IO.File]::SetCreationTime($subDir, $past)

            $fs = [System.IO.FileStream]::new($lockedFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)

            Mock Remove-Item {
                if ($LiteralPath -like "*sub_locked*") {
                    throw [System.IO.IOException]::new("File in use: '$LiteralPath'")
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
            $env:TEMP = $testDir
            $env:TMP = $testDir

            try {
                $result = Clear-WindowsTempCache -AgeHours 24 -IncludeUserTemp

                $result.Success | Should -BeTrue
                $result.ItemCount | Should -Be 1
                $result.ReclaimedBytes | Should -Be 200
                $result.SkippedCount | Should -Be 1

                Test-Path -LiteralPath $freeFile | Should -BeFalse
                Test-Path -LiteralPath $lockedFile | Should -BeTrue
                # Crucial invariant: subfolder must NOT be deleted while containing locked file
                Test-Path -LiteralPath $subDir | Should -BeTrue
            }
            finally {
                $fs.Close()
                $fs.Dispose()
                $env:TEMP = $origTemp
                $env:TMP = $origTmp
                Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Clear-WindowsUpdateCache handles locked files and guarantees service restart in finally block' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wc_stress_lock_wu_" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -Path $testDir -ItemType Directory -Force | Out-Null

            $freePayload = Join-Path $testDir 'patch_free.cab'
            $lockedPayload = Join-Path $testDir 'patch_locked.cab'
            [System.IO.File]::WriteAllBytes($freePayload, [byte[]]::new(600))
            [System.IO.File]::WriteAllBytes($lockedPayload, [byte[]]::new(700))

            $stopped = [System.Collections.Generic.List[string]]::new()
            $started = [System.Collections.Generic.List[string]]::new()
            Mock Stop-Service { param($Name) $stopped.Add($Name) }
            Mock Start-Service { param($Name) $started.Add($Name) }

            $fs = [System.IO.FileStream]::new($lockedPayload, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)

            Mock Remove-Item {
                if ($LiteralPath -like "*patch_locked*") {
                    throw [System.IO.IOException]::new("Locked file in update cache")
                }
                if (Test-Path -LiteralPath $LiteralPath -PathType Container) {
                    [System.IO.Directory]::Delete($LiteralPath, $true)
                }
                elseif (Test-Path -LiteralPath $LiteralPath) {
                    [System.IO.File]::Delete($LiteralPath)
                }
            }

            try {
                $result = Clear-WindowsUpdateCache -Path $testDir

                $result.Success | Should -BeTrue
                $result.ItemCount | Should -Be 1
                $result.ReclaimedBytes | Should -Be 600
                $result.SkippedCount | Should -Be 1

                # Invariant: Services MUST be restarted even when locked files were encountered
                $started | Should -Contain 'wuauserv'
                $started | Should -Contain 'bits'

                Test-Path -LiteralPath $freePayload | Should -BeFalse
                Test-Path -LiteralPath $lockedPayload | Should -BeTrue
            }
            finally {
                $fs.Close()
                $fs.Dispose()
                Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Remove-SafeItem catches UnauthorizedAccessException and IOException cleanly' {
            $testFile = [System.IO.Path]::GetTempFileName()
            try {
                Mock Remove-Item {
                    throw [System.UnauthorizedAccessException]::new("Access to path '$LiteralPath' denied")
                }
                $res1 = Remove-SafeItem -Item $testFile
                $res1.Deleted | Should -BeFalse
                $res1.SkippedReason | Should -Be 'AccessDenied'

                Mock Remove-Item {
                    throw [System.IO.IOException]::new("Exclusive lock active on '$LiteralPath'")
                }
                $res2 = Remove-SafeItem -Item $testFile
                $res2.Deleted | Should -BeFalse
                $res2.SkippedReason | Should -Be 'LockedFile'
            }
            finally {
                if (Test-Path $testFile) { [System.IO.File]::Delete($testFile) }
            }
        }
    }

    # --------------------------------------------------------------------------
    # 3. Age Filtering Rigor (24h Window & Boundary Conditions)
    # --------------------------------------------------------------------------
    Context '3. Age Filtering Precision & Boundary Conditions' {

        It 'Purges only files >24h and strictly preserves files <24h' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wc_stress_age_filter_" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -Path $testDir -ItemType Directory -Force | Out-Null

            $fOld48  = Join-Path $testDir 'old_48h.tmp'
            $fOld25  = Join-Path $testDir 'old_25h.tmp'
            $fYoung2 = Join-Path $testDir 'young_2h.tmp'
            $fYoung23 = Join-Path $testDir 'young_23h.tmp'

            [System.IO.File]::WriteAllBytes($fOld48,   [byte[]]::new(10))
            [System.IO.File]::WriteAllBytes($fOld25,   [byte[]]::new(20))
            [System.IO.File]::WriteAllBytes($fYoung2,  [byte[]]::new(30))
            [System.IO.File]::WriteAllBytes($fYoung23, [byte[]]::new(40))

            $time48 = (Get-Date).AddHours(-48)
            $time25 = (Get-Date).AddHours(-25)
            $time2  = (Get-Date).AddHours(-2)
            $time23 = (Get-Date).AddHours(-23)

            [System.IO.File]::SetLastWriteTime($fOld48, $time48);   [System.IO.File]::SetCreationTime($fOld48, $time48)
            [System.IO.File]::SetLastWriteTime($fOld25, $time25);   [System.IO.File]::SetCreationTime($fOld25, $time25)
            [System.IO.File]::SetLastWriteTime($fYoung2, $time2);   [System.IO.File]::SetCreationTime($fYoung2, $time2)
            [System.IO.File]::SetLastWriteTime($fYoung23, $time23); [System.IO.File]::SetCreationTime($fYoung23, $time23)

            $origTemp = $env:TEMP
            $origTmp = $env:TMP
            $env:TEMP = $testDir
            $env:TMP = $testDir

            try {
                $result = Clear-WindowsTempCache -AgeHours 24 -IncludeUserTemp

                $result.Success | Should -BeTrue
                $result.ItemCount | Should -Be 2
                $result.ReclaimedBytes | Should -Be 30
                $result.SkippedCount | Should -Be 2

                # Verified: >24h files deleted
                Test-Path -LiteralPath $fOld48 | Should -BeFalse
                Test-Path -LiteralPath $fOld25 | Should -BeFalse

                # Verified: <24h files strictly preserved
                Test-Path -LiteralPath $fYoung2 | Should -BeTrue
                Test-Path -LiteralPath $fYoung23 | Should -BeTrue
            }
            finally {
                $env:TEMP = $origTemp
                $env:TMP = $origTmp
                Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Preserves files with old creation time but recent modification time (Active Write Protection)' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wc_stress_age_activewrite_" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -Path $testDir -ItemType Directory -Force | Out-Null

            $activeWriteFile = Join-Path $testDir 'active_download.tmp'
            [System.IO.File]::WriteAllBytes($activeWriteFile, [byte[]]::new(50))

            # Simulate through Mock Get-ChildItem to enforce exact asymmetric timestamps:
            # Created 72h ago, but written to 30 minutes ago
            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{
                        FullName      = $activeWriteFile
                        PSIsContainer = $false
                        Length        = 50
                        CreationTime  = (Get-Date).AddHours(-72)
                        LastWriteTime = (Get-Date).AddMinutes(-30)
                    }
                )
            }

            $origTemp = $env:TEMP
            $origTmp = $env:TMP
            $env:TEMP = $testDir
            $env:TMP = $testDir

            try {
                $result = Clear-WindowsTempCache -AgeHours 24 -IncludeUserTemp

                $result.Success | Should -BeTrue
                $result.ItemCount | Should -Be 0
                $result.SkippedCount | Should -Be 1

                # Must NOT delete active write file!
                Test-Path -LiteralPath $activeWriteFile | Should -BeTrue
            }
            finally {
                $env:TEMP = $origTemp
                $env:TMP = $origTmp
                Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Preserves files with recent creation time but old modification time (Extracted Archive Protection)' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wc_stress_age_archive_" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -Path $testDir -ItemType Directory -Force | Out-Null

            $extractedFile = Join-Path $testDir 'extracted_payload.tmp'
            [System.IO.File]::WriteAllBytes($extractedFile, [byte[]]::new(50))

            # Simulate through Mock Get-ChildItem to enforce exact asymmetric timestamps:
            # Created 1h ago on this machine, but source timestamp in archive was 100h ago
            Mock Get-ChildItem {
                return @(
                    [PSCustomObject]@{
                        FullName      = $extractedFile
                        PSIsContainer = $false
                        Length        = 50
                        CreationTime  = (Get-Date).AddHours(-1)
                        LastWriteTime = (Get-Date).AddHours(-100)
                    }
                )
            }

            $origTemp = $env:TEMP
            $origTmp = $env:TMP
            $env:TEMP = $testDir
            $env:TMP = $testDir

            try {
                $result = Clear-WindowsTempCache -AgeHours 24 -IncludeUserTemp

                $result.Success | Should -BeTrue
                $result.ItemCount | Should -Be 0
                $result.SkippedCount | Should -Be 1

                # Must NOT delete recently extracted file!
                Test-Path -LiteralPath $extractedFile | Should -BeTrue
            }
            finally {
                $env:TEMP = $origTemp
                $env:TMP = $origTmp
                Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Respects custom AgeHours parameter (e.g. AgeHours = 1 and AgeHours = 48)' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wc_stress_custom_age_" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -Path $testDir -ItemType Directory -Force | Out-Null

            $f3h = Join-Path $testDir 'file_3h.tmp'
            [System.IO.File]::WriteAllBytes($f3h, [byte[]]::new(100))
            [System.IO.File]::SetCreationTime($f3h, (Get-Date).AddHours(-3))
            [System.IO.File]::SetLastWriteTime($f3h, (Get-Date).AddHours(-3))

            $origTemp = $env:TEMP
            $origTmp = $env:TMP
            $env:TEMP = $testDir
            $env:TMP = $testDir

            try {
                # At 48h threshold: 3h file is preserved
                $res48 = Clear-WindowsTempCache -AgeHours 48 -IncludeUserTemp -WhatIf
                $res48.ItemCount | Should -Be 0
                $res48.SkippedCount | Should -Be 1

                # At 1h threshold: 3h file qualifies
                $res1 = Clear-WindowsTempCache -AgeHours 1 -IncludeUserTemp -WhatIf
                $res1.ItemCount | Should -Be 1
                $res1.SkippedCount | Should -Be 0
            }
            finally {
                $env:TEMP = $origTemp
                $env:TMP = $origTmp
                Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # --------------------------------------------------------------------------
    # 4. Negative Invariants (Strict Zero Tolerance Assertions)
    # --------------------------------------------------------------------------
    Context '4. Negative Invariants & Non-Destructive Invariant Audits' {

        It 'Modules/WindowsCleanup codebase contains zero registry deletion or cleaning logic' {
            $cleanupDir = Join-Path $script:ProjectRoot 'Modules/WindowsCleanup'
            $files = Get-ChildItem -Path $cleanupDir -Filter '*.ps*' -Recurse -File

            foreach ($file in $files) {
                $raw = Get-Content -LiteralPath $file.FullName -Raw
                # Assert zero registry removal
                $raw | Should -Not -Match 'Remove-ItemProperty'
                $raw | Should -Not -Match 'Clear-ItemProperty'
                $raw | Should -Not -Match 'Remove-Item.*(?:HKLM|HKCU|HKCR|HKU|Registry::)'
                $raw | Should -Not -Match 'Set-ItemProperty.*(?:HKLM|HKCU|Registry::)'
            }
        }

        It 'Modules/WindowsCleanup codebase contains zero raw deletion commands targeting WinSxS or DriverStore' {
            $cleanupDir = Join-Path $script:ProjectRoot 'Modules/WindowsCleanup'
            $files = Get-ChildItem -Path $cleanupDir -Filter '*.ps*' -Recurse -File

            foreach ($file in $files) {
                $raw = Get-Content -LiteralPath $file.FullName -Raw
                $raw | Should -Not -Match 'Remove-Item.*(?:WinSxS|DriverStore)'
                $raw | Should -Not -Match '\[System\.IO\.Directory\]::Delete.*(?:WinSxS|DriverStore)'
            }
        }

        It 'Modules/WindowsCleanup codebase contains zero shadow copy or system restore tampering' {
            $cleanupDir = Join-Path $script:ProjectRoot 'Modules/WindowsCleanup'
            $files = Get-ChildItem -Path $cleanupDir -Filter '*.ps*' -Recurse -File

            foreach ($file in $files) {
                $raw = Get-Content -LiteralPath $file.FullName -Raw
                $raw | Should -Not -Match 'vssadmin'
                $raw | Should -Not -Match 'shadowcopy'
                $raw | Should -Not -Match 'Disable-ComputerRestore'
                $raw | Should -Not -Match 'Delete-ShadowCopy'
            }
        }

        It 'Clear-WindowsSystemLogs strictly preserves active CBS.log and dism.log' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wc_stress_cbs_active_" + [System.Guid]::NewGuid().ToString('N'))
            $cbsDir = Join-Path $testDir 'Logs\CBS'
            $dismDir = Join-Path $testDir 'Logs\DISM'
            New-Item -Path $cbsDir -ItemType Directory -Force | Out-Null
            New-Item -Path $dismDir -ItemType Directory -Force | Out-Null

            $activeCbs = Join-Path $cbsDir 'CBS.log'
            $archiveCbs = Join-Path $cbsDir 'CbsPersist_20261005.cab'
            $activeDism = Join-Path $dismDir 'dism.log'
            $archiveDism = Join-Path $dismDir 'dism.log.bak'

            Set-Content -Path $activeCbs -Value 'Active CBS log content'
            Set-Content -Path $archiveCbs -Value 'Archived persist cab'
            Set-Content -Path $activeDism -Value 'Active DISM log content'
            Set-Content -Path $archiveDism -Value 'Archived dism backup'

            $origSysRoot = $env:SystemRoot
            $env:SystemRoot = $testDir

            try {
                $result = Clear-WindowsSystemLogs -IncludeComponentLogs

                $result.Success | Should -BeTrue
                $result.ItemCount | Should -Be 2

                # Invariant: Active logs MUST NOT be deleted
                Test-Path -LiteralPath $activeCbs | Should -BeTrue
                Test-Path -LiteralPath $activeDism | Should -BeTrue

                # Invariant: Archived logs were safely purged
                Test-Path -LiteralPath $archiveCbs | Should -BeFalse
                Test-Path -LiteralPath $archiveDism | Should -BeFalse
            }
            finally {
                $env:SystemRoot = $origSysRoot
                Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # --------------------------------------------------------------------------
    # 5. Parameter Validation & Boundary Edge Cases
    # --------------------------------------------------------------------------
    Context '5. Parameter Validation & Boundary Robustness' {

        It 'Clear-WindowsTempCache throws validation error on negative AgeHours' {
            { Clear-WindowsTempCache -AgeHours -1 } | Should -Throw -ExpectedMessage '*allowed range*'
        }

        It 'Clear-WindowsTempCache throws validation error on AgeHours exceeding 720' {
            { Clear-WindowsTempCache -AgeHours 721 } | Should -Throw -ExpectedMessage '*allowed range*'
        }

        It 'Invoke-WindowsCleanup throws validation error on invalid Category' {
            { Invoke-WindowsCleanup -Category 'NonExistentSubsystem' } | Should -Throw -ExpectedMessage '*ValidateSet*'
        }

        It 'Invoke-WindowsCleanup throws validation error on invalid Category in array' {
            { Invoke-WindowsCleanup -Category @('TempCache', 'RegistryHacker') } | Should -Throw -ExpectedMessage '*ValidateSet*'
        }

        It 'Invoke-WindowsCleanup throws validation error on invalid TempAgeHours' {
            { Invoke-WindowsCleanup -TempAgeHours -5 } | Should -Throw -ExpectedMessage '*allowed range*'
            { Invoke-WindowsCleanup -TempAgeHours 1000 } | Should -Throw -ExpectedMessage '*allowed range*'
        }

        It 'Clear-WindowsUpdateCache handles non-existent path gracefully' {
            $nonExistent = '/non/existent/path/for/wu/cache'
            $result = Clear-WindowsUpdateCache -Path $nonExistent
            $result.Success | Should -BeTrue
            $result.ReclaimedBytes | Should -Be 0
            $result.ItemCount | Should -Be 0
        }

        It 'Clear-WindowsDeliveryOptimizationCache handles non-existent path gracefully' {
            $nonExistent = '/non/existent/path/for/do/cache'
            $result = Clear-WindowsDeliveryOptimizationCache -Path $nonExistent
            $result.Success | Should -BeTrue
            $result.ReclaimedBytes | Should -Be 0
            $result.ItemCount | Should -Be 0
        }

        It 'Remove-SafeItem handles null, non-existent, and invalid item types without throwing' {
            $res1 = Remove-SafeItem -Item '/non/existent/path'
            $res1.Deleted | Should -BeFalse
            $res1.SkippedReason | Should -Be 'PathNotFound'

            $res2 = Remove-SafeItem -Item 12345
            $res2.Deleted | Should -BeFalse
            $res2.SkippedReason | Should -Be 'InvalidItemType'
        }
    }
}
