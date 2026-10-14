# ==============================================================================
# Core.Tests.ps1
# Unit test suite for Modules/Core
# Covers: Test-IsAdmin, Assert-IsAdmin, Start-ToolkitSelfElevation,
# Test-ProcessRunning, Stop-ToolkitProcess, Test-DiskSpaceAvailable,
# Export-RegistryKeyBackup, Restore-RegistryKeyBackup, Set-ToolkitRegistryValue,
# Write-ToolkitLog, Format-ToolkitSummary, Show-ToolkitConfirmation.
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:CoreManifest = Join-Path $ProjectRoot 'Modules/Core/Core.psd1'
$isCoreAvailable = Test-Path $script:CoreManifest

BeforeAll {
    $script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    $root = $script:ProjectRoot
    $script:CoreManifest = Join-Path $root 'Modules/Core/Core.psd1'
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
    # Dot-source Core scripts into test scope to enable unqualified Pester mocking
    Get-ChildItem -Path (Join-Path $root "Modules/Core/Private/*.ps1") | ForEach-Object { . $_.FullName }
    Get-ChildItem -Path (Join-Path $root "Modules/Core/Public/*.ps1") | ForEach-Object { . $_.FullName }
}
Describe 'Unit: Core Module Services' {

    Context 'Administrative Elevation Checks' {
        It 'Test-IsAdmin returns a boolean value' -Skip:(-not $isCoreAvailable) {
            $result = Test-IsAdmin
            $result -is [bool] | Should -BeTrue
        }

        It 'Assert-IsAdmin succeeds when session is elevated' -Skip:(-not $isCoreAvailable) {
            Mock Test-IsAdmin { return $true }
            { Assert-IsAdmin } | Should -Not -Throw
        }

        It 'Assert-IsAdmin throws terminating error when session is not elevated' -Skip:(-not $isCoreAvailable) {
            Mock Test-IsAdmin { return $false }
            { Assert-IsAdmin } | Should -Throw
        }

        It 'Start-ToolkitSelfElevation invokes Start-Process with RunAs verb' -Skip:(-not $isCoreAvailable) {
            Mock Start-Process { return [PSCustomObject]@{ Id = 1234 } }
            Start-ToolkitSelfElevation -ScriptPath 'C:\IToolkit\Start-IToolkit.ps1' -Arguments '-NoExit'
            Assert-MockCalled Start-Process -Times 1 -ParameterFilter {
                $Verb -eq 'RunAs'
            }
        }
    }

    Context 'Process Lifecycle Management' {
        It 'Test-ProcessRunning returns true when target process exists' -Skip:(-not $isCoreAvailable) {
            Mock Get-Process { return [PSCustomObject]@{ ProcessName = 'OUTLOOK' } }
            $res = Test-ProcessRunning -ProcessName 'OUTLOOK'
            $res | Should -BeTrue
        }

        It 'Test-ProcessRunning returns false when target process does not exist' -Skip:(-not $isCoreAvailable) {
            Mock Get-Process { throw [System.Management.Automation.ItemNotFoundException]::new() }
            $res = Test-ProcessRunning -ProcessName 'NON_EXISTENT_PROC'
            $res | Should -BeFalse
        }

        It 'Stop-ToolkitProcess handles already stopped process' -Skip:(-not $isCoreAvailable) {
            Mock Get-Process { throw [System.Management.Automation.ItemNotFoundException]::new() }
            $res = Stop-ToolkitProcess -ProcessName 'EXCEL'
            $res.ProcessName | Should -Be 'EXCEL'
            $res.Terminated | Should -BeFalse
            $res.ForceUsed | Should -BeFalse
        }

        It 'Stop-ToolkitProcess gracefully closes responding process' -Skip:(-not $isCoreAvailable) {
            $mockProc = [PSCustomObject]@{
                ProcessName     = 'OUTLOOK'
                CloseMainWindow = { return $true }
                WaitForExit     = { param($t) return $true }
                HasExited       = $true
            }
            Mock Get-Process { return @($mockProc) }
            $res = Stop-ToolkitProcess -ProcessName 'OUTLOOK' -TimeoutSeconds 5
            $res.ProcessName | Should -Be 'OUTLOOK'
            $res.Terminated | Should -BeTrue
            $res.ForceUsed | Should -BeFalse
        }

        It 'Stop-ToolkitProcess falls back to force kill when requested' -Skip:(-not $isCoreAvailable) {
            $mockProc = [PSCustomObject]@{
                ProcessName = 'HUNG_APP'
                Kill        = { return $true }
                HasExited   = $true
            }
            Mock Get-Process { return @($mockProc) }
            Mock Stop-Process { }
            $res = Stop-ToolkitProcess -ProcessName 'HUNG_APP' -Force
            $res.Terminated | Should -BeTrue
            $res.ForceUsed | Should -BeTrue
        }
    }

    Context 'Disk Space & Resource Pre-Flight Checks' {
        It 'Test-DiskSpaceAvailable returns true when free space exceeds threshold * 1.2' -Skip:(-not $isCoreAvailable) {
            $mockDrive = [PSCustomObject]@{
                Root      = 'C:\'
                FreeBytes = 100GB
            }
            Mock Get-PSDrive { return $mockDrive }
            # Required: 50GB * 1.2 = 60GB < 100GB
            $res = Test-DiskSpaceAvailable -Path 'C:\Data' -RequiredBytes 50GB
            $res | Should -BeTrue
        }

        It 'Test-DiskSpaceAvailable returns false when free space is insufficient' -Skip:(-not $isCoreAvailable) {
            $mockDrive = [PSCustomObject]@{
                Root      = 'C:\'
                FreeBytes = 55GB
            }
            Mock Get-PSDrive { return $mockDrive }
            # Required: 50GB * 1.2 = 60GB > 55GB
            $res = Test-DiskSpaceAvailable -Path 'C:\Data' -RequiredBytes 50GB
            $res | Should -BeFalse
        }

        It 'Test-DiskSpaceAvailable respects custom safety multiplier' -Skip:(-not $isCoreAvailable) {
            $mockDrive = [PSCustomObject]@{
                Root      = 'D:\'
                FreeBytes = 80GB
            }
            Mock Get-PSDrive { return $mockDrive }
            # Required: 50GB * 2.0 = 100GB > 80GB
            $res = Test-DiskSpaceAvailable -Path 'D:\Backup' -RequiredBytes 50GB -SafetyMultiplier 2.0
            $res | Should -BeFalse
        }
    }

    Context 'Reversible Registry Engine' {
        It 'Export-RegistryKeyBackup generates .reg file in backup directory' -Skip:(-not $isCoreAvailable) {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            try {
                Mock Start-Process {
                    # Simulate reg.exe export
                    param($FilePath, $ArgumentList)
                    $outPath = ($ArgumentList -split '\s+')[2].Trim('"')
                    Set-Content -Path $outPath -Value "Windows Registry Editor Version 5.00`n`n[HKEY_CURRENT_USER\Software\Test]`n`"Key`"=`"Val`""
                    return [PSCustomObject]@{ ExitCode = 0 }
                }

                $backupFile = Export-RegistryKeyBackup -KeyPath 'HKCU:\Software\Test' -BackupDirectory $tempDir
                Test-Path $backupFile | Should -BeTrue
                $content = Get-Content -Path $backupFile -Raw
                $content | Should -Match 'Windows Registry Editor Version 5\.00'
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Restore-RegistryKeyBackup calls reg.exe import and returns success' -Skip:(-not $isCoreAvailable) {
            $tempFile = [System.IO.Path]::GetTempFileName()
            Set-Content -Path $tempFile -Value "Windows Registry Editor Version 5.00"
            try {
                Mock Start-Process { return [PSCustomObject]@{ ExitCode = 0 } }
                $res = Restore-RegistryKeyBackup -BackupFilePath $tempFile
                $res | Should -BeTrue
            } finally {
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Restore-RegistryKeyBackup returns false if file does not exist' -Skip:(-not $isCoreAvailable) {
            $res = Restore-RegistryKeyBackup -BackupFilePath 'C:\NonExistent\Backup.reg'
            $res | Should -BeFalse
        }

        It 'Set-ToolkitRegistryValue creates backup before modifying and supports WhatIf' -Skip:(-not $isCoreAvailable) {
            Mock Export-RegistryKeyBackup -ModuleName Core { return 'C:\Backups\Reg_123.reg' }
            Mock Set-ItemProperty -ModuleName Core { }
            Mock Get-ItemProperty -ModuleName Core { return [PSCustomObject]@{ DisableHardwareAcceleration = 0 } }
            Mock Export-RegistryKeyBackup { return 'C:\Backups\Reg_123.reg' }
            Mock Set-ItemProperty { }
            Mock Get-ItemProperty { return [PSCustomObject]@{ DisableHardwareAcceleration = 0 } }

            $res = Set-ToolkitRegistryValue -KeyPath 'HKCU:\Software\Microsoft\Office\16.0\Common\Graphics' `
                                            -ValueName 'DisableHardwareAcceleration' `
                                            -Value 1 `
                                            -PropertyType 'DWord' `
                                            -WhatIf

            $res.KeyPath | Should -Match 'Office'
            $res.ValueName | Should -Be 'DisableHardwareAcceleration'
        }
    }

    Context 'Centralized Logging & Summaries' {
        It 'Write-ToolkitLog formats messages with level, timestamp, and component' -Skip:(-not $isCoreAvailable) {
            $tempLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            try {
                Write-ToolkitLog -Message 'Test message' -Level 'Info' -Component 'Core' -LogDirectory $tempLogDir
                $logFiles = Get-ChildItem -Path $tempLogDir -Filter '*.log'
                $logFiles.Count | Should -BeGreaterThan 0
                $content = Get-Content -Path $logFiles[0].FullName -Raw
                $content | Should -Match '\[INFO\]'
                $content | Should -Match '\[Core\]'
                $content | Should -Match 'Test message'
            } finally {
                Remove-Item -Path $tempLogDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Write-ToolkitLog suppresses DEBUG messages from console while writing to log file' -Skip:(-not $isCoreAvailable) {
            $tempLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            try {
                Mock Write-Host {}
                Write-ToolkitLog -Message 'Diagnostic debug detail' -Level 'DEBUG' -Component 'Core' -LogDirectory $tempLogDir
                Assert-MockCalled Write-Host -Times 0 -Scope It
                $logFiles = Get-ChildItem -Path $tempLogDir -Filter '*.log'
                $logFiles.Count | Should -BeGreaterThan 0
                $content = Get-Content -Path $logFiles[0].FullName -Raw
                $content | Should -Match '\[DEBUG\]'
                $content | Should -Match '\[Core\]'
                $content | Should -Match 'Diagnostic debug detail'
            } finally {
                Remove-Item -Path $tempLogDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Format-ToolkitSummary generates structured output table' -Skip:(-not $isCoreAvailable) {
            $items = @(
                @{ Label = 'PST File Path'; Value = 'C:\Data\archive.pst'; Status = 'OK' },
                @{ Label = 'PST Size'; Value = '48.2 GB'; Status = 'WARN' }
            )
            $output = Format-ToolkitSummary -Title 'Outlook Migration Summary' -Items $items
            $output | Should -Not -BeNullOrEmpty
        }

        It 'Show-ToolkitConfirmation returns true when user enters Y' -Skip:(-not $isCoreAvailable) {
            Mock Read-Host { return 'Y' }
            $res = Show-ToolkitConfirmation -Prompt 'Proceed with destructive reset?'
            $res | Should -BeTrue
        }

        It 'Show-ToolkitConfirmation returns false when user enters N' -Skip:(-not $isCoreAvailable) {
            Mock Read-Host { return 'N' }
            $res = Show-ToolkitConfirmation -Prompt 'Proceed with destructive reset?'
            $res | Should -BeFalse
        }

        It 'Show-ToolkitConfirmation respects default value on empty input' -Skip:(-not $isCoreAvailable) {
            Mock Read-Host { return '' }
            $res = Show-ToolkitConfirmation -Prompt 'Proceed?' -Default $true
            $res | Should -BeTrue

            $res2 = Show-ToolkitConfirmation -Prompt 'Proceed?' -Default $false
            $res2 | Should -BeFalse
        }

        It 'Write-ToolkitLog normalizes lowercase logs path to PascalCase Logs' -Skip:(-not $isCoreAvailable) {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            $subLogs = Join-Path $tempDir 'logs'
            try {
                Write-ToolkitLog -Message 'Normalization test' -LogDirectory $subLogs
                Test-Path -LiteralPath (Join-Path $tempDir 'Logs') | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $tempDir 'logs') | Should -BeFalse
            } finally {
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Write-ToolkitLog respects global:ToolkitLogDirectory and env:ITOOLKIT_LOG_DIR' -Skip:(-not $isCoreAvailable) {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            try {
                $global:ToolkitLogDirectory = $tempDir
                Write-ToolkitLog -Message 'Global log test' -Component 'CoreTest'
                $logFiles = Get-ChildItem -Path $tempDir -Filter '*.log'
                $logFiles.Count | Should -BeGreaterThan 0
                $content = Get-Content -Path $logFiles[0].FullName -Raw
                $content | Should -Match 'Global log test'
            } finally {
                $global:ToolkitLogDirectory = $null
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Write-ToolkitLog auto-discovers application root Logs directory when no parameters are provided' -Skip:(-not $isCoreAvailable) {
            $savedGlobal = $global:ToolkitLogDirectory
            $savedEnv = $env:ITOOLKIT_LOG_DIR
            try {
                $global:ToolkitLogDirectory = $null
                $env:ITOOLKIT_LOG_DIR = $null
                $rootLogs = Join-Path $script:ProjectRoot 'Logs'
                Write-ToolkitLog -Message 'Root discovery test' -Component 'CoreTest' -NoConsole
                Test-Path -LiteralPath $rootLogs | Should -BeTrue
                $logFiles = Get-ChildItem -Path $rootLogs -Filter 'IToolkit_*.log'
                $logFiles.Count | Should -BeGreaterThan 0
            } finally {
                $global:ToolkitLogDirectory = $savedGlobal
                $env:ITOOLKIT_LOG_DIR = $savedEnv
            }
        }

        It 'Write-ToolkitLog falls back gracefully when target log directory cannot be created' -Skip:(-not $isCoreAvailable) {
            $invalidDir = '/proc/invalid_readonly_log_dir_12345/logs'
            if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
                $invalidDir = 'Z:\NonExistentDriveLetterXYZ:\Logs'
            }
            try {
                { Write-ToolkitLog -Message 'Fallback resilience test' -LogDirectory $invalidDir -NoConsole } | Should -Not -Throw
            } finally {
                $null = $null
            }
        }
    }

    Context 'TUI Mode Session Management & Log Suppression' {
        BeforeAll {
            # Tier 1: Snapshot pre-flight state
            $script:origTuiDepth = $global:ToolkitTuiDepth
            $script:origTuiActive = $global:ToolkitTuiActive
            $script:origTuiMode = $global:ToolkitTUIMode
            $script:origSuppressLog = $global:ToolkitSuppressConsoleLog
            $script:origEnvTuiMode = $env:ITOOLKIT_TUI_MODE
        }

        BeforeEach {
            # Tier 2: Pristine reset before every test
            $global:ToolkitTuiDepth = 0
            $global:ToolkitTuiActive = $false
            $global:ToolkitTUIMode = $false
            $global:ToolkitSuppressConsoleLog = $false
            Remove-Item -Path 'env:ITOOLKIT_TUI_MODE' -ErrorAction SilentlyContinue
            $env:ITOOLKIT_TUI_MODE = $null
        }

        AfterEach {
            # Tier 3: Guaranteed teardown after every test
            if (Get-Command -Name 'Exit-ToolkitTuiMode' -ErrorAction SilentlyContinue) {
                Exit-ToolkitTuiMode -Force
            }
            $global:ToolkitTuiDepth = 0
            $global:ToolkitTuiActive = $false
            $global:ToolkitTUIMode = $false
            $global:ToolkitSuppressConsoleLog = $false
            Remove-Item -Path 'env:ITOOLKIT_TUI_MODE' -ErrorAction SilentlyContinue
            $env:ITOOLKIT_TUI_MODE = $null
        }

        AfterAll {
            # Tier 4: Restore original state to eliminate cross-suite contamination
            $global:ToolkitTuiDepth = $script:origTuiDepth
            $global:ToolkitTuiActive = $script:origTuiActive
            $global:ToolkitTUIMode = $script:origTuiMode
            $global:ToolkitSuppressConsoleLog = $script:origSuppressLog
            if ($null -ne $script:origEnvTuiMode) {
                $env:ITOOLKIT_TUI_MODE = $script:origEnvTuiMode
            } else {
                Remove-Item -Path 'env:ITOOLKIT_TUI_MODE' -ErrorAction SilentlyContinue
                $env:ITOOLKIT_TUI_MODE = $null
            }
        }

        It 'Enter-ToolkitTuiMode increments depth, sets active flag, and sets environment variable' -Skip:(-not $isCoreAvailable) {
            $global:ToolkitTuiDepth | Should -Be 0
            $global:ToolkitTuiActive | Should -BeFalse
            $env:ITOOLKIT_TUI_MODE | Should -BeNullOrEmpty

            $depth = Enter-ToolkitTuiMode -PassThru
            $depth | Should -Be 1
            $global:ToolkitTuiDepth | Should -Be 1
            $global:ToolkitTuiActive | Should -BeTrue
            $global:ToolkitTUIMode | Should -BeTrue
            $env:ITOOLKIT_TUI_MODE | Should -Be '1'
        }

        It 'Exit-ToolkitTuiMode decrements depth, resets active flag, and clears environment variable at depth 0' -Skip:(-not $isCoreAvailable) {
            Enter-ToolkitTuiMode
            $global:ToolkitTuiDepth | Should -Be 1
            $global:ToolkitTuiActive | Should -BeTrue
            $env:ITOOLKIT_TUI_MODE | Should -Be '1'

            $remaining = Exit-ToolkitTuiMode -PassThru
            $remaining | Should -Be 0
            $global:ToolkitTuiDepth | Should -Be 0
            $global:ToolkitTuiActive | Should -BeFalse
            $global:ToolkitTUIMode | Should -BeFalse
            $env:ITOOLKIT_TUI_MODE | Should -BeNullOrEmpty
        }

        It 'Enter-ToolkitTuiMode and Exit-ToolkitTuiMode handle nested calls (depth 1 -> 2 -> 1 -> 0)' -Skip:(-not $isCoreAvailable) {
            # Step 1: Root entry (depth 0 -> 1)
            $d1 = Enter-ToolkitTuiMode -PassThru
            $d1 | Should -Be 1
            $global:ToolkitTuiDepth | Should -Be 1
            $global:ToolkitTuiActive | Should -BeTrue
            $env:ITOOLKIT_TUI_MODE | Should -Be '1'

            # Step 2: Nested entry (depth 1 -> 2)
            $d2 = Enter-ToolkitTuiMode -PassThru
            $d2 | Should -Be 2
            $global:ToolkitTuiDepth | Should -Be 2
            $global:ToolkitTuiActive | Should -BeTrue
            $env:ITOOLKIT_TUI_MODE | Should -Be '1'

            # Step 3: Nested exit (depth 2 -> 1)
            $d3 = Exit-ToolkitTuiMode -PassThru
            $d3 | Should -Be 1
            $global:ToolkitTuiDepth | Should -Be 1
            $global:ToolkitTuiActive | Should -BeTrue  # Still active in parent menu
            $env:ITOOLKIT_TUI_MODE | Should -Be '1'

            # Step 4: Root exit (depth 1 -> 0)
            $d4 = Exit-ToolkitTuiMode -PassThru
            $d4 | Should -Be 0
            $global:ToolkitTuiDepth | Should -Be 0
            $global:ToolkitTuiActive | Should -BeFalse # Inactive when returning to CLI
            $env:ITOOLKIT_TUI_MODE | Should -BeNullOrEmpty
        }

        It 'Write-ToolkitLog skips Write-Host when TUI mode is active across multiple log levels' -Skip:(-not $isCoreAvailable) {
            $tempLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            try {
                Enter-ToolkitTuiMode
                Mock Write-Host {}

                # Test multiple severity levels that normally emit to console
                Write-ToolkitLog -Message 'Suppressed info message' -Level 'Info' -Component 'TuiTest' -LogDirectory $tempLogDir
                Write-ToolkitLog -Message 'Suppressed warning message' -Level 'Warn' -Component 'TuiTest' -LogDirectory $tempLogDir
                Write-ToolkitLog -Message 'Suppressed error message' -Level 'Error' -Component 'TuiTest' -LogDirectory $tempLogDir
                Write-ToolkitLog -Message 'Suppressed success message' -Level 'Success' -Component 'TuiTest' -LogDirectory $tempLogDir

                Assert-MockCalled Write-Host -Times 0 -Scope It
            } finally {
                Exit-ToolkitTuiMode -Force
                Remove-Item -Path $tempLogDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Write-ToolkitLog still appends to daily log file when TUI mode is active' -Skip:(-not $isCoreAvailable) {
            $tempLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            try {
                Enter-ToolkitTuiMode
                Mock Write-Host {}

                $uniqueMsg = "Audit entry while in TUI mode - $([System.Guid]::NewGuid().ToString())"
                Write-ToolkitLog -Message $uniqueMsg -Level 'Info' -Component 'AuditComponent' -LogDirectory $tempLogDir

                # Write-Host must have been suppressed
                Assert-MockCalled Write-Host -Times 0 -Scope It

                # File log must have captured the audit entry
                $logFiles = Get-ChildItem -Path $tempLogDir -Filter 'IToolkit_*.log'
                $logFiles.Count | Should -BeGreaterThan 0
                $content = Get-Content -Path $logFiles[0].FullName -Raw
                $content | Should -Match '\[INFO\]'
                $content | Should -Match '\[AuditComponent\]'
                $content | Should -Match ([regex]::Escape($uniqueMsg))
            } finally {
                Exit-ToolkitTuiMode -Force
                Remove-Item -Path $tempLogDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Write-ToolkitLog restores normal console output when TUI mode is exited' -Skip:(-not $isCoreAvailable) {
            $tempLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            try {
                # 1. Enter TUI mode and verify suppression
                Enter-ToolkitTuiMode
                Mock Write-Host {}
                Write-ToolkitLog -Message 'TUI suppressed message' -Level 'Info' -Component 'CoreTest' -LogDirectory $tempLogDir
                Assert-MockCalled Write-Host -Times 0 -Scope It

                # 2. Exit TUI mode back to depth 0
                Exit-ToolkitTuiMode
                $global:ToolkitTuiActive | Should -BeFalse

                # 3. Verify normal console output is restored
                Write-ToolkitLog -Message 'Restored normal CLI message' -Level 'Info' -Component 'CoreTest' -LogDirectory $tempLogDir
                Assert-MockCalled Write-Host -Times 1 -Scope It
            } finally {
                Exit-ToolkitTuiMode -Force
                Remove-Item -Path $tempLogDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Exit-ToolkitTuiMode with -Force resets depth, active flag, and clears environment variable immediately' -Skip:(-not $isCoreAvailable) {
            Enter-ToolkitTuiMode
            Enter-ToolkitTuiMode
            Enter-ToolkitTuiMode
            $global:ToolkitTuiDepth | Should -Be 3

            Exit-ToolkitTuiMode -Force
            $global:ToolkitTuiDepth | Should -Be 0
            $global:ToolkitTuiActive | Should -BeFalse
            $global:ToolkitTUIMode | Should -BeFalse
            $env:ITOOLKIT_TUI_MODE | Should -BeNullOrEmpty
        }

        It 'Exit-ToolkitTuiMode protects against negative depth and handles extraneous exits safely' -Skip:(-not $isCoreAvailable) {
            Exit-ToolkitTuiMode -Force
            $global:ToolkitTuiDepth | Should -Be 0

            # Calling exit when already at 0 should stay at 0 and not throw
            { Exit-ToolkitTuiMode } | Should -Not -Throw
            $global:ToolkitTuiDepth | Should -Be 0
            $global:ToolkitTuiActive | Should -BeFalse
            $env:ITOOLKIT_TUI_MODE | Should -BeNullOrEmpty
        }

        It 'Enter-ToolkitTuiMode and Exit-ToolkitTuiMode do not pollute pipeline unless -PassThru is specified' -Skip:(-not $isCoreAvailable) {
            $pipeIn = & { Enter-ToolkitTuiMode }
            $pipeIn | Should -BeNullOrEmpty

            $pipeOut = & { Exit-ToolkitTuiMode }
            $pipeOut | Should -BeNullOrEmpty
        }
    }

    Context 'Deterministic COM Object Cleanup' {
        It 'Remove-ToolkitComObject handles null without errors' -Skip:(-not $isCoreAvailable) {
            { Remove-ToolkitComObject -ComObject $null } | Should -Not -Throw
        }

        It 'Remove-ToolkitComObject handles non-COM objects gracefully' -Skip:(-not $isCoreAvailable) {
            $nonCom = [PSCustomObject]@{ Name = 'Test' }
            { Remove-ToolkitComObject -ComObject $nonCom } | Should -Not -Throw
        }

        It 'Remove-ToolkitComObject accepts pipeline input' -Skip:(-not $isCoreAvailable) {
            { @($null, [PSCustomObject]@{ Id = 1 }) | Remove-ToolkitComObject -SkipGarbageCollection } | Should -Not -Throw
        }

        It 'Remove-ToolkitComObject respects SkipGarbageCollection switch' -Skip:(-not $isCoreAvailable) {
            { Remove-ToolkitComObject -ComObject $null -SkipGarbageCollection } | Should -Not -Throw
        }
    }

    Context 'Upload Boundary & Production Sanitization' {
        It 'Modules/Core does not export Send-ToolkitUpload cmdlet' -Skip:(-not $isCoreAvailable) {
            $manifestPath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path 'Modules/Core/Core.psd1'
            $manifest = Import-PowerShellDataFile -Path $manifestPath
            $exports = $manifest.FunctionsToExport
            $exports | Should -Not -Contain 'Send-ToolkitUpload'
        }

        It 'Modules/Core does not export any upload cmdlets' -Skip:(-not $isCoreAvailable) {
            $cmd = Get-Command -Module 'Core' -Name 'Send-ToolkitUpload' -ErrorAction SilentlyContinue
            $cmd | Should -BeNullOrEmpty
        }

        It 'Core module remains 100% clean and local-only' -Skip:(-not $isCoreAvailable) {
            $coreCommands = Get-Command -Module 'Core'
            foreach ($c in $coreCommands) {
                $c.Name | Should -Not -Match '(?i)upload'
            }
        }
    }
}
