# ==============================================================================
# TuiModeReentrancyStress.Tests.ps1
# Empirical Adversarial Stress Test Suite for Milestone 1:
# Core Logging Suppression & Re-entrant Mode Management
# ==============================================================================

BeforeAll {
    $script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    Import-Module (Join-Path $script:ProjectRoot 'IToolkit.psd1') -Force
    Import-Module (Join-Path $script:ProjectRoot 'Modules/Core/Core.psd1') -Force

    # Dot-source Core scripts into test scope to enable unqualified Pester mocking
    Get-ChildItem -Path (Join-Path $script:ProjectRoot 'Modules/Core/Private/*.ps1') | ForEach-Object { . $_.FullName }
    Get-ChildItem -Path (Join-Path $script:ProjectRoot 'Modules/Core/Public/*.ps1') | ForEach-Object { . $_.FullName }

    $script:appInstallerManifest = Join-Path $script:ProjectRoot 'Modules/AppInstaller/AppInstaller.psd1'
    if (Test-Path -LiteralPath $script:appInstallerManifest) {
        Import-Module $script:appInstallerManifest -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Milestone 1 Empirical Stress Tests: Re-entrancy & Suppression' {

    BeforeEach {
        $global:ToolkitTuiDepth = 0
        $global:ToolkitTuiActive = $false
        $global:ToolkitTUIMode = $false
        $global:ToolkitSuppressConsoleLog = $false
        Remove-Item -Path 'env:ITOOLKIT_TUI_MODE' -ErrorAction SilentlyContinue
        $env:ITOOLKIT_TUI_MODE = $null
    }

    AfterEach {
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

    # --------------------------------------------------------------------------
    # 1. Re-entrant Nesting and Deep Recursion (Depth 10, 50, 100, 500)
    # --------------------------------------------------------------------------
    Context 'Deep Re-entrancy Nesting & Recursion' {
        It 'Maintains accurate depth tracking across 10 nested levels' {
            for ($i = 1; $i -le 10; $i++) {
                $d = Enter-ToolkitTuiMode -PassThru
                $d | Should -Be $i
                $global:ToolkitTuiDepth | Should -Be $i
                $global:ToolkitTuiActive | Should -BeTrue
                $global:ToolkitSuppressConsoleLog | Should -BeTrue
                $env:ITOOLKIT_TUI_MODE | Should -Be '1'
            }

            for ($i = 9; $i -ge 1; $i--) {
                $d = Exit-ToolkitTuiMode -PassThru
                $d | Should -Be $i
                $global:ToolkitTuiDepth | Should -Be $i
                $global:ToolkitTuiActive | Should -BeTrue
                $global:ToolkitSuppressConsoleLog | Should -BeTrue
                $env:ITOOLKIT_TUI_MODE | Should -Be '1'
            }

            $finalDepth = Exit-ToolkitTuiMode -PassThru
            $finalDepth | Should -Be 0
            $global:ToolkitTuiDepth | Should -Be 0
            $global:ToolkitTuiActive | Should -BeFalse
            $global:ToolkitSuppressConsoleLog | Should -BeFalse
            $env:ITOOLKIT_TUI_MODE | Should -BeNullOrEmpty
        }

        It 'Maintains accurate depth tracking across 50 nested levels' {
            for ($i = 1; $i -le 50; $i++) {
                $d = Enter-ToolkitTuiMode -PassThru
                $d | Should -Be $i
            }
            $global:ToolkitTuiDepth | Should -Be 50
            $global:ToolkitTuiActive | Should -BeTrue

            for ($i = 49; $i -ge 0; $i--) {
                $d = Exit-ToolkitTuiMode -PassThru
                $d | Should -Be $i
            }
            $global:ToolkitTuiDepth | Should -Be 0
            $global:ToolkitTuiActive | Should -BeFalse
        }

        It 'Maintains accurate depth tracking across 100 nested levels' {
            for ($i = 1; $i -le 100; $i++) {
                $d = Enter-ToolkitTuiMode -PassThru
                $d | Should -Be $i
            }
            $global:ToolkitTuiDepth | Should -Be 100
            $global:ToolkitTuiActive | Should -BeTrue

            for ($i = 99; $i -ge 0; $i--) {
                $d = Exit-ToolkitTuiMode -PassThru
                $d | Should -Be $i
            }
            $global:ToolkitTuiDepth | Should -Be 0
            $global:ToolkitTuiActive | Should -BeFalse
        }

        It 'Handles deep recursion up to 500 nested levels without degradation' {
            for ($i = 1; $i -le 500; $i++) {
                Enter-ToolkitTuiMode
            }
            $global:ToolkitTuiDepth | Should -Be 500
            $global:ToolkitTuiActive | Should -BeTrue

            for ($i = 1; $i -le 500; $i++) {
                Exit-ToolkitTuiMode
            }
            $global:ToolkitTuiDepth | Should -Be 0
            $global:ToolkitTuiActive | Should -BeFalse
        }

        It 'Unwinds cleanly via try/finally recursion even when exceptions occur at arbitrary depths' {
            function Invoke-NestedTuiWorker {
                param([int]$CurrentLevel, [int]$FailAtLevel)
                try {
                    Enter-ToolkitTuiMode
                    if ($CurrentLevel -eq $FailAtLevel) {
                        throw "Simulated crash at recursion level $FailAtLevel"
                    }
                    if ($CurrentLevel -lt 25) {
                        Invoke-NestedTuiWorker -CurrentLevel ($CurrentLevel + 1) -FailAtLevel $FailAtLevel
                    }
                }
                finally {
                    Exit-ToolkitTuiMode
                }
            }

            { Invoke-NestedTuiWorker -CurrentLevel 1 -FailAtLevel 17 } | Should -Throw
            $global:ToolkitTuiDepth | Should -Be 0
            $global:ToolkitTuiActive | Should -BeFalse
            $env:ITOOLKIT_TUI_MODE | Should -BeNullOrEmpty
        }
    }

    # --------------------------------------------------------------------------
    # 2. Mismatched Exits, Negative Depth & Type Corruption Protection
    # --------------------------------------------------------------------------
    Context 'Mismatched Exits & Underflow / Corruption Protection' {
        It 'Handles 50 consecutive extraneous exits from depth 0 without error or negative drift' {
            for ($i = 1; $i -le 50; $i++) {
                $res = Exit-ToolkitTuiMode -PassThru
                $res | Should -Be 0
                $global:ToolkitTuiDepth | Should -Be 0
                $global:ToolkitTuiActive | Should -BeFalse
                $env:ITOOLKIT_TUI_MODE | Should -BeNullOrEmpty
            }
        }

        It 'Safely handles externally injected negative depth on Exit-ToolkitTuiMode' {
            $global:ToolkitTuiDepth = -42
            $res = Exit-ToolkitTuiMode -PassThru
            $res | Should -Be 0
            $global:ToolkitTuiDepth | Should -Be 0
            $global:ToolkitTuiActive | Should -BeFalse
            $env:ITOOLKIT_TUI_MODE | Should -BeNullOrEmpty
        }

        It 'Safely recovers to depth 1 when Enter-ToolkitTuiMode is called on negative depth' {
            $global:ToolkitTuiDepth = -15
            $res = Enter-ToolkitTuiMode -PassThru
            $res | Should -Be 1
            $global:ToolkitTuiDepth | Should -Be 1
            $global:ToolkitTuiActive | Should -BeTrue
            $env:ITOOLKIT_TUI_MODE | Should -Be '1'
        }

        It 'Recovers gracefully when global:ToolkitTuiDepth is non-integer string' {
            $global:ToolkitTuiDepth = 'corrupted_state_string'
            $res = Enter-ToolkitTuiMode -PassThru
            $res | Should -Be 1
            $global:ToolkitTuiDepth | Should -Be 1
            $global:ToolkitTuiActive | Should -BeTrue

            $global:ToolkitTuiDepth = 'malformed_depth'
            $resExit = Exit-ToolkitTuiMode -PassThru
            $resExit | Should -Be 0
            $global:ToolkitTuiDepth | Should -Be 0
        }

        It 'Handles global:ToolkitTuiDepth set to null or boolean safely' {
            $global:ToolkitTuiDepth = $null
            { Enter-ToolkitTuiMode } | Should -Not -Throw
            $global:ToolkitTuiDepth | Should -Be 1

            $global:ToolkitTuiDepth = $true
            { Exit-ToolkitTuiMode } | Should -Not -Throw
            $global:ToolkitTuiDepth | Should -Be 0
        }
    }

    # --------------------------------------------------------------------------
    # 3. Force Reset Behavior (-Force)
    # --------------------------------------------------------------------------
    Context 'Force Reset Behavior (-Force)' {
        It 'Instantly resets depth and state from depth 10' {
            for ($i = 1; $i -le 10; $i++) { Enter-ToolkitTuiMode }
            $global:ToolkitTuiDepth | Should -Be 10

            $res = Exit-ToolkitTuiMode -Force -PassThru
            $res | Should -Be 0
            $global:ToolkitTuiDepth | Should -Be 0
            $global:ToolkitTuiActive | Should -BeFalse
            $global:ToolkitTUIMode | Should -BeFalse
            $env:ITOOLKIT_TUI_MODE | Should -BeNullOrEmpty
        }

        It 'Instantly resets depth and state from depth 100' {
            for ($i = 1; $i -le 100; $i++) { Enter-ToolkitTuiMode }
            $global:ToolkitTuiDepth | Should -Be 100

            Exit-ToolkitTuiMode -Force
            $global:ToolkitTuiDepth | Should -Be 0
            $global:ToolkitTuiActive | Should -BeFalse
            $env:ITOOLKIT_TUI_MODE | Should -BeNullOrEmpty
        }

        It 'Calling Exit-ToolkitTuiMode -Force when already at depth 0 is safe and idempotent' {
            Exit-ToolkitTuiMode -Force
            Exit-ToolkitTuiMode -Force
            Exit-ToolkitTuiMode -Force
            $global:ToolkitTuiDepth | Should -Be 0
            $global:ToolkitTuiActive | Should -BeFalse
            $env:ITOOLKIT_TUI_MODE | Should -BeNullOrEmpty
        }
    }

    # --------------------------------------------------------------------------
    # 4. Console Output Suppression Across All Depths > 0
    # --------------------------------------------------------------------------
    Context 'Console Output Suppression at Every Depth > 0' {
        It 'Suppresses Write-Host across all log levels at depths 1, 2, 5, 10, 50, 100' {
            $testDepths = @(1, 2, 5, 10, 50, 100)
            $tempLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())

            try {
                Mock Write-Host { }

                foreach ($targetDepth in $testDepths) {
                    Exit-ToolkitTuiMode -Force
                    for ($i = 1; $i -le $targetDepth; $i++) { Enter-ToolkitTuiMode }

                    $global:ToolkitTuiDepth | Should -Be $targetDepth

                    # Direct stream capture check: 0 items emitted to Information stream 6
                    $capturedStream = & {
                        Write-ToolkitLog -Message "Depth $targetDepth INFO" -Level 'Info' -Component 'StressTest' -LogDirectory $tempLogDir
                        Write-ToolkitLog -Message "Depth $targetDepth WARN" -Level 'Warn' -Component 'StressTest' -LogDirectory $tempLogDir
                        Write-ToolkitLog -Message "Depth $targetDepth ERROR" -Level 'Error' -Component 'StressTest' -LogDirectory $tempLogDir
                        Write-ToolkitLog -Message "Depth $targetDepth SUCCESS" -Level 'Success' -Component 'StressTest' -LogDirectory $tempLogDir
                        Write-ToolkitLog -Message "Depth $targetDepth DEBUG" -Level 'Debug' -Component 'StressTest' -LogDirectory $tempLogDir
                    } 6>&1

                    $capturedStream.Count | Should -Be 0

                    # AppInstaller wrapper if available
                    if (Get-Command -Name 'Write-AppInstallerLog' -ErrorAction SilentlyContinue) {
                        $capturedAppStream = & {
                            Write-AppInstallerLog -Message "Depth $targetDepth AppInstaller INFO" -Level 'INFO' -Component 'StressTest'
                            Write-AppInstallerLog -Message "Depth $targetDepth AppInstaller WARN" -Level 'WARN' -Component 'StressTest'
                            Write-AppInstallerLog -Message "Depth $targetDepth AppInstaller ERROR" -Level 'ERROR' -Component 'StressTest'
                            Write-AppInstallerLog -Message "Depth $targetDepth AppInstaller SUCCESS" -Level 'SUCCESS' -Component 'StressTest'
                        } 6>&1
                        $capturedAppStream.Count | Should -Be 0
                    }
                }

                # Under all these calls across all depths, Write-Host mock was also called 0 times
                Assert-MockCalled Write-Host -Times 0 -Scope It
            }
            finally {
                Exit-ToolkitTuiMode -Force
                Remove-Item -Path $tempLogDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # --------------------------------------------------------------------------
    # 5. File Log Retention Under Heavy Suppression (1,000 Records)
    # --------------------------------------------------------------------------
    Context 'File Log Retention Under Heavy Suppression' {
        It 'Retains 100% of 1,000 log records in daily log file without dropping under heavy TUI suppression' {
            $tempLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            try {
                # Enter TUI mode at depth 5
                for ($i = 1; $i -le 5; $i++) { Enter-ToolkitTuiMode }
                Mock Write-Host { }

                $recordCount = 1000
                $levels = @('Info', 'Warn', 'Error', 'Success')

                for ($i = 1; $i -le $recordCount; $i++) {
                    $lvl = $levels[$i % $levels.Length]
                    Write-ToolkitLog -Message "High volume suppression record #$i" -Level $lvl -Component 'StressRetain' -LogDirectory $tempLogDir
                }

                # Ensure Write-Host was completely silenced
                Assert-MockCalled Write-Host -Times 0 -Scope It

                # Read daily log file and verify retention
                $logFiles = Get-ChildItem -Path $tempLogDir -Filter 'IToolkit_*.log'
                $logFiles.Count | Should -BeGreaterThan 0

                $lines = Get-Content -Path $logFiles[0].FullName
                $lines.Count | Should -Be $recordCount

                # Verify first, middle, and last record structure
                $lines[0] | Should -Match '\[StressRetain\] High volume suppression record #1'
                $lines[499] | Should -Match '\[StressRetain\] High volume suppression record #500'
                $lines[999] | Should -Match '\[StressRetain\] High volume suppression record #1000'
            }
            finally {
                Exit-ToolkitTuiMode -Force
                Remove-Item -Path $tempLogDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # --------------------------------------------------------------------------
    # 6. Immediate Console Output Restoration at Depth 0
    # --------------------------------------------------------------------------
    Context 'Immediate Console Restoration at Depth 0' {
        It 'Immediately restores console logging across all active levels upon reaching depth 0' {
            $tempLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            try {
                # 1. Enter to depth 10
                for ($i = 1; $i -le 10; $i++) { Enter-ToolkitTuiMode }

                $suppressed10 = & {
                    Write-ToolkitLog -Message 'Suppressed at depth 10' -Level 'Info' -Component 'RestoreTest' -LogDirectory $tempLogDir
                } 6>&1
                $suppressed10.Count | Should -Be 0

                # 2. Exit 9 times down to depth 1
                for ($i = 1; $i -le 9; $i++) { Exit-ToolkitTuiMode }
                $global:ToolkitTuiDepth | Should -Be 1
                $global:ToolkitTuiActive | Should -BeTrue

                $suppressed1 = & {
                    Write-ToolkitLog -Message 'Suppressed at depth 1' -Level 'Info' -Component 'RestoreTest' -LogDirectory $tempLogDir
                } 6>&1
                $suppressed1.Count | Should -Be 0

                # 3. Final exit down to depth 0
                Exit-ToolkitTuiMode
                $global:ToolkitTuiDepth | Should -Be 0
                $global:ToolkitTuiActive | Should -BeFalse

                # 4. Normal console logging must immediately resume via Information stream 6
                $restoredInfo = & {
                    Write-ToolkitLog -Message 'Restored INFO' -Level 'Info' -Component 'RestoreTest' -LogDirectory $tempLogDir
                } 6>&1
                $restoredInfo | Should -Match '\[INFO\]\s+Restored INFO'

                $restoredWarn = & {
                    Write-ToolkitLog -Message 'Restored WARN' -Level 'Warn' -Component 'RestoreTest' -LogDirectory $tempLogDir
                } 6>&1
                $restoredWarn | Should -Match '\[WARN\]\s+Restored WARN'

                $restoredError = & {
                    Write-ToolkitLog -Message 'Restored ERROR' -Level 'Error' -Component 'RestoreTest' -LogDirectory $tempLogDir
                } 6>&1
                $restoredError | Should -Match '\[FAIL\]\s+Restored ERROR'

                $restoredSuccess = & {
                    Write-ToolkitLog -Message 'Restored SUCCESS' -Level 'Success' -Component 'RestoreTest' -LogDirectory $tempLogDir
                } 6>&1
                $restoredSuccess | Should -Match '\[OK\]\s+Restored SUCCESS'

                # DEBUG is always suppressed from console
                $suppressedDebug = & {
                    Write-ToolkitLog -Message 'Suppressed DEBUG' -Level 'Debug' -Component 'RestoreTest' -LogDirectory $tempLogDir
                } 6>&1
                $suppressedDebug.Count | Should -Be 0
            }
            finally {
                Exit-ToolkitTuiMode -Force
                Remove-Item -Path $tempLogDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # --------------------------------------------------------------------------
    # 7. Subprocess / Cross-Process Environment Variable Inheritance
    # --------------------------------------------------------------------------
    Context 'Cross-Process Environment Variable Inheritance' {
        It 'Propagates suppression to child PowerShell process via env:ITOOLKIT_TUI_MODE' {
            Enter-ToolkitTuiMode
            $env:ITOOLKIT_TUI_MODE | Should -Be '1'

            # Run a child PowerShell process while env var is active
            $childScript = "
                Import-Module '$($script:ProjectRoot)/IToolkit.psd1' -Force
                Write-ToolkitLog -Message 'Child message during TUI' -Level 'Info' -Component 'ChildProc'
            "
            $capturedOutput = & pwsh -NoProfile -Command $childScript 2>&1
            $capturedOutput | Should -BeNullOrEmpty

            # Exit TUI mode in parent
            Exit-ToolkitTuiMode
            $env:ITOOLKIT_TUI_MODE | Should -BeNullOrEmpty

            # Run child process after exit
            $childScriptRestored = "
                Import-Module '$($script:ProjectRoot)/IToolkit.psd1' -Force
                Write-ToolkitLog -Message 'Child message after exit' -Level 'Info' -Component 'ChildProc'
            "
            $capturedRestored = & pwsh -NoProfile -Command $childScriptRestored 2>&1
            $capturedRestored | Should -Match '\[INFO\]\s+Child message after exit'
        }
    }

    # --------------------------------------------------------------------------
    # 8. Pipeline Cleanliness
    # --------------------------------------------------------------------------
    Context 'Pipeline Cleanliness' {
        It 'Does not pollute pipeline when PassThru is omitted' {
            $resEnter = @(& { Enter-ToolkitTuiMode })
            $resEnter.Count | Should -Be 0

            $resExit = @(& { Exit-ToolkitTuiMode })
            $resExit.Count | Should -Be 0

            $resForce = @(& { Exit-ToolkitTuiMode -Force })
            $resForce.Count | Should -Be 0
        }

        It 'Returns exact integer depth when PassThru is specified' {
            $d1 = Enter-ToolkitTuiMode -PassThru
            $d1 | Should -BeOfType [int]
            $d1 | Should -Be 1

            $d2 = Enter-ToolkitTuiMode -PassThru
            $d2 | Should -Be 2

            $d3 = Exit-ToolkitTuiMode -PassThru
            $d3 | Should -Be 1

            $d4 = Exit-ToolkitTuiMode -Force -PassThru
            $d4 | Should -Be 0
        }
    }
}
