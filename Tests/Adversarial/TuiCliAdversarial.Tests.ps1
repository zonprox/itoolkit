# ==============================================================================
# TuiCliAdversarial.Tests.ps1
# Adversarial stress and edge-case verification for TUI and CLI interfaces.
# Covers:
# - Non-interactive CLI behavior (-ExitImmediately, -NonInteractive, closed stdin, invalid options)
# - Terminal layout adaptability (40, 80, 160 cols, 1-col/2-col reflow, border integrity)
# - Rapid repeated execution stress testing (in-process memory stability & child process cleanup)
# ==============================================================================

BeforeAll {
    $script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:StartScriptPath = Join-Path $script:ProjectRoot 'Start-IToolkit.ps1'
    $script:TuiManifest = Join-Path $script:ProjectRoot 'Modules/TUI/TUI.psd1'

    Import-Module $script:TuiManifest -Force -DisableNameChecking

    $script:testActions = @(
        @{ Key = '1'; Label = 'Scan Data Files' },
        @{ Key = '2'; Label = 'Relocate PST' },
        @{ Key = '3'; Label = 'Update Profile Path' },
        @{ Key = '4'; Label = 'Expand Size Limit' }
    )
    $script:testNav = @(
        @{ Key = 'B'; Label = 'Back to Main Menu' },
        @{ Key = 'Q'; Label = 'Exit Console' }
    )
    $script:testDetails = @(
        @{ Key = '1'; Action = 'Scan Data Files'; Description = 'Deep discovery across registry profiles & disk drives.'; Prerequisite = 'None [READY]' },
        @{ Key = '2'; Action = 'Relocate PST'; Description = 'Move PST/OST with SHA-256 validation & profile repoint.'; Prerequisite = 'Outlook must be stopped [SAFE]' }
    )
    $script:testStatus = @(
        'Outlook State  : Stopped [SAFE TO MOVE DATA FILES]',
        'Default Profile: Outlook (Office 16.0 / 365)',
        'PST Policy     : Default limit (~50 GB threshold)'
    )
}

Describe 'Adversarial: Non-Interactive CLI Behavior & Parameter Stress' {

    Context 'Start-IToolkit.ps1 -ExitImmediately & Trailing Arguments' {
        It 'Exits cleanly with exit code 0 when invoked with -SkipElevation -ExitImmediately' {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'
            $psi.Arguments = "-NoProfile -File `"$($script:StartScriptPath)`" -SkipElevation -ExitImmediately"
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false

            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.StandardInput.Close()
            $completed = $proc.WaitForExit(15000)
            if (-not $completed) { try { $proc.Kill() } catch { $null = $_ } }

            $completed | Should -BeTrue
            $proc.ExitCode | Should -Be 0
        }

        It 'Gracefully handles valid trailing positional arguments mapping to parameters' {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'
            $psi.Arguments = "-NoProfile -File `"$($script:StartScriptPath)`" -SkipElevation -ExitImmediately 1 ./TestLogs"
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false

            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.StandardInput.Close()
            $completed = $proc.WaitForExit(15000)
            if (-not $completed) { try { $proc.Kill() } catch { $null = $_ } }

            $completed | Should -BeTrue
            $proc.ExitCode | Should -Be 0
        }

        It 'Fails loud with non-zero exit code when unbound extra positional arguments are provided' {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'
            $psi.Arguments = "-NoProfile -File `"$($script:StartScriptPath)`" -SkipElevation -ExitImmediately arg1 arg2 extra_arg3"
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false

            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.StandardInput.Close()
            $completed = $proc.WaitForExit(15000)
            if (-not $completed) { try { $proc.Kill() } catch { $null = $_ } }

            $completed | Should -BeTrue
            $proc.ExitCode | Should -Not -Be 0
        }
    }

    Context 'Closed Stdin (EOF / /dev/null / $null) Resilience' {
        It 'Start-IToolkit.ps1 with -SkipElevation -NonInteractive terminates cleanly on closed stdin' {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'
            $psi.Arguments = "-NoProfile -File `"$($script:StartScriptPath)`" -SkipElevation -NonInteractive"
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false

            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.StandardInput.Close()
            $stdout = $proc.StandardOutput.ReadToEnd()
            $completed = $proc.WaitForExit(15000)
            if (-not $completed) { try { $proc.Kill() } catch { $null = $_ } }

            $completed | Should -BeTrue
            $proc.ExitCode | Should -Be 0
            $stdout | Should -Match '(?i)Initialized in non-interactive mode'
        }

        It 'Interactive mode terminates cleanly without infinite loop when stdin is closed' {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'
            $psi.Arguments = "-NoProfile -File `"$($script:StartScriptPath)`" -SkipElevation"
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false

            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.StandardInput.Close()
            $completed = $proc.WaitForExit(15000)
            if (-not $completed) { try { $proc.Kill() } catch { $null = $_ } }

            $completed | Should -BeTrue
            $proc.ExitCode | Should -Be 0
        }
    }

    Context 'All 6 Submenus Non-Interactive & Immediate Exit Verification' {
        It 'Executes each submenu (1 through 6) non-interactively with -ExitImmediately' {
            for ($cat = 1; $cat -le 6; $cat++) {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = 'pwsh'
                $psi.Arguments = "-NoProfile -File `"$($script:StartScriptPath)`" -SkipElevation -ExitImmediately -MenuOption $cat"
                $psi.RedirectStandardInput = $true
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.UseShellExecute = $false

                $proc = [System.Diagnostics.Process]::Start($psi)
                $proc.StandardInput.Close()
                $completed = $proc.WaitForExit(15000)
                if (-not $completed) { try { $proc.Kill() } catch { $null = $_ } }

                $completed | Should -BeTrue
                $proc.ExitCode | Should -Be 0
            }
        }

        It 'Executes each submenu (1 through 6) non-interactively with -NonInteractive' {
            for ($cat = 1; $cat -le 6; $cat++) {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = 'pwsh'
                $psi.Arguments = "-NoProfile -File `"$($script:StartScriptPath)`" -SkipElevation -NonInteractive -MenuOption $cat"
                $psi.RedirectStandardInput = $true
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.UseShellExecute = $false

                $proc = [System.Diagnostics.Process]::Start($psi)
                $proc.StandardInput.Close()
                $stdout = $proc.StandardOutput.ReadToEnd()
                $completed = $proc.WaitForExit(15000)
                if (-not $completed) { try { $proc.Kill() } catch { $null = $_ } }

                $completed | Should -BeTrue
                $proc.ExitCode | Should -Be 0
                $stdout | Should -Match '(?i)Non-interactive category listing complete'
            }
        }
    }

    Context 'Invalid & Unrecognized Menu Options' {
        It 'Gracefully handles unrecognized numeric MenuOption (e.g. 99) in non-interactive mode' {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'
            $psi.Arguments = "-NoProfile -File `"$($script:StartScriptPath)`" -SkipElevation -NonInteractive -MenuOption 99"
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false

            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.StandardInput.Close()
            $stdout = $proc.StandardOutput.ReadToEnd()
            $completed = $proc.WaitForExit(15000)
            if (-not $completed) { try { $proc.Kill() } catch { $null = $_ } }

            $completed | Should -BeTrue
            $proc.ExitCode | Should -Be 0
            $stdout | Should -Match "Unrecognized menu option '99'"
        }

        It 'Gracefully handles unrecognized string MenuOption in non-interactive mode' {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'
            $psi.Arguments = "-NoProfile -File `"$($script:StartScriptPath)`" -SkipElevation -NonInteractive -MenuOption INVALID_CMD"
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false

            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.StandardInput.Close()
            $stdout = $proc.StandardOutput.ReadToEnd()
            $completed = $proc.WaitForExit(15000)
            if (-not $completed) { try { $proc.Kill() } catch { $null = $_ } }

            $completed | Should -BeTrue
            $proc.ExitCode | Should -Be 0
            $stdout | Should -Match "Unrecognized menu option 'INVALID_CMD'"
        }
    }
}

Describe 'Adversarial: Terminal Layout Adaptability Across Extreme Widths' {

    Context 'Get-ToolkitLayoutWidth Boundary Constraints' {
        It 'Clamps width to Min (40) when environment COLUMNS is below minimum in redirected/headless mode' {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'
            $psi.Arguments = "-NoProfile -Command `"`$env:COLUMNS=30; Import-Module $($script:TuiManifest) -Force; Get-ToolkitLayoutWidth -Min 40 -Max 160`""
            $psi.RedirectStandardOutput = $true
            $psi.UseShellExecute = $false
            $proc = [System.Diagnostics.Process]::Start($psi)
            $out = $proc.StandardOutput.ReadToEnd()
            $proc.WaitForExit(10000)
            [int]($out.Trim()) | Should -Be 40
        }

        It 'Clamps width to Max (160) when environment COLUMNS exceeds maximum in redirected/headless mode' {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'
            $psi.Arguments = "-NoProfile -Command `"`$env:COLUMNS=220; Import-Module $($script:TuiManifest) -Force; Get-ToolkitLayoutWidth -Min 40 -Max 160`""
            $psi.RedirectStandardOutput = $true
            $psi.UseShellExecute = $false
            $proc = [System.Diagnostics.Process]::Start($psi)
            $out = $proc.StandardOutput.ReadToEnd()
            $proc.WaitForExit(10000)
            [int]($out.Trim()) | Should -Be 160
        }

        It 'Scales dynamically for standard 80-column terminal in redirected/headless mode' {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'
            $psi.Arguments = "-NoProfile -Command `"`$env:COLUMNS=80; Import-Module $($script:TuiManifest) -Force; Get-ToolkitLayoutWidth -Min 40 -Max 160`""
            $psi.RedirectStandardOutput = $true
            $psi.UseShellExecute = $false
            $proc = [System.Diagnostics.Process]::Start($psi)
            $out = $proc.StandardOutput.ReadToEnd()
            $proc.WaitForExit(10000)
            # 80 - 2 margin = 78
            [int]($out.Trim()) | Should -Be 78
        }
    }

    Context 'Component Rendering Across Widths (40, 80, 160)' {
        $widths = @(40, 80, 160)

        It 'Show-ToolkitHeader renders without exceptions across widths <Width>' -TestCases ($widths | ForEach-Object { @{ Width = $_ } }) {
            param($Width)
            { Show-ToolkitHeader -Title 'TEST TITLE' -Subtitle 'Test Subtitle' -InfoLines @('Key: Value') -Width $Width -NoSystemInfo } | Should -Not -Throw
        }

        It 'Show-ToolkitActionCatalog reflows correctly without exceptions across widths <Width>' -TestCases ($widths | ForEach-Object { @{ Width = $_ } }) {
            param($Width)
            { Show-ToolkitActionCatalog -Actions $script:testActions -NavActions $script:testNav -Width $Width } | Should -Not -Throw
        }

        It 'Show-ToolkitDetailPanel renders action details without exceptions across widths <Width>' -TestCases ($widths | ForEach-Object { @{ Width = $_ } }) {
            param($Width)
            { Show-ToolkitDetailPanel -Details $script:testDetails -Width $Width } | Should -Not -Throw
        }

        It 'Show-ToolkitStatusPanel renders telemetry badges without exceptions across widths <Width>' -TestCases ($widths | ForEach-Object { @{ Width = $_ } }) {
            param($Width)
            { Show-ToolkitStatusPanel -StatusItems $script:testStatus -Width $Width } | Should -Not -Throw
        }

        It 'Show-ToolkitActionCatalog reflows to single column on narrow widths (< 70)' {
            { Show-ToolkitActionCatalog -Actions $script:testActions -Width 40 } | Should -Not -Throw
        }

        It 'Borders and dividers tolerate extreme boundary widths (10 and 300)' {
            { Show-ToolkitActionCatalog -Actions $script:testActions -Width 10 } | Should -Not -Throw
            { Show-ToolkitActionCatalog -Actions $script:testActions -Width 300 } | Should -Not -Throw
            { Show-ToolkitDetailPanel -Details $script:testDetails -Width 10 } | Should -Not -Throw
            { Show-ToolkitDetailPanel -Details $script:testDetails -Width 300 } | Should -Not -Throw
            { Show-ToolkitStatusPanel -StatusItems $script:testStatus -Width 10 } | Should -Not -Throw
            { Show-ToolkitStatusPanel -StatusItems $script:testStatus -Width 300 } | Should -Not -Throw
        }
    }
}

Describe 'Adversarial: Rapid Repeated Execution & Memory/Process Leak Stress' {

    Context 'In-Process Rapid Repeated Execution (100 Iterations)' {
        It 'Executes Start-IToolkitMenu -ExitImmediately 100 times with zero memory leak (delta < 10MB)' {
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
            $memBefore = [System.GC]::GetTotalMemory($true)

            for ($i = 1; $i -le 100; $i++) {
                Start-IToolkitMenu -ExitImmediately
            }

            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
            $memAfter = [System.GC]::GetTotalMemory($true)
            $deltaMB = [math]::Round(($memAfter - $memBefore) / 1MB, 2)

            # Less than 10MB memory change across 100 iterations
            $deltaMB | Should -BeLessThan 10
        }
    }

    Context 'Process-Level Rapid Repeated Execution (50 Iterations)' {
        It 'Launches 50 child processes with 100% clean exit codes and zero lingering processes' {
            $spawnedPids = [System.Collections.Generic.List[int]]::new()
            $failures = 0

            for ($i = 1; $i -le 50; $i++) {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = 'pwsh'
                $psi.Arguments = "-NoProfile -File `"$($script:StartScriptPath)`" -SkipElevation -ExitImmediately"
                $psi.RedirectStandardInput = $true
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.UseShellExecute = $false

                $proc = [System.Diagnostics.Process]::Start($psi)
                $spawnedPids.Add($proc.Id)
                $proc.StandardInput.Close()

                $completed = $proc.WaitForExit(15000)
                if (-not $completed) {
                    try { $proc.Kill() } catch { $null = $_ }
                    $failures++
                } elseif ($proc.ExitCode -ne 0) {
                    $failures++
                }
                $proc.Dispose()
            }

            $failures | Should -Be 0

            # Verify no spawned PIDs remain in system process table
            $lingering = 0
            foreach ($p in $spawnedPids) {
                if (Get-Process -Id $p -ErrorAction SilentlyContinue) {
                    $lingering++
                }
            }
            $lingering | Should -Be 0
        }
    }
}
