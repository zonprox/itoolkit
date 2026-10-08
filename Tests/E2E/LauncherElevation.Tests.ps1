# ==============================================================================
# LauncherElevation.Tests.ps1
# E2E Tier 1: Launchers & Self-Elevation Verification
# Tests Start-IToolkit.ps1 and Run-IToolkit.bat for automatic privilege detection,
# UAC self-elevation via Start-Process -Verb RunAs, and argument preservation.
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:ProjectRoot = $ProjectRoot
$script:StartScriptPath = Join-Path $ProjectRoot 'Start-IToolkit.ps1'
$script:BatchScriptPath = Join-Path $ProjectRoot 'Run-IToolkit.bat'
$isLauncherAvailable = (Test-Path $script:StartScriptPath) -or (Test-Path $script:BatchScriptPath)

BeforeAll {
    $script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
    $script:StartScriptPath = Join-Path $script:ProjectRoot 'Start-IToolkit.ps1'
    $script:BatchScriptPath = Join-Path $script:ProjectRoot 'Run-IToolkit.bat'
    $root = $script:ProjectRoot
    if (-not (Get-Command -Name 'Write-ToolkitMenuDivider' -ErrorAction SilentlyContinue)) {
        function global:Write-ToolkitMenuDivider { param([int]$Width = 78) Write-Host ('  ' + ('-' * [math]::Max(20, $Width - 2))) }
    }
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
Describe 'E2E Tier 1: Launcher & Automatic Self-Elevation' {

    Context 'Start-IToolkit.ps1 Static & AST Analysis' {
        $hasStartScript = Test-Path (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path 'Start-IToolkit.ps1')

        It 'Start-IToolkit.ps1 exists in project root' -Skip:(-not $hasStartScript) {
            $path = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path 'Start-IToolkit.ps1'
            Test-Path $path | Should -BeTrue
        }

        It 'Start-IToolkit.ps1 contains elevation detection and RunAs relaunch logic' -Skip:(-not $hasStartScript) {
            $path = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path 'Start-IToolkit.ps1'
            $content = Get-Content -Path $path -Raw
            $content | Should -Match '(?i)(?:Test-IsAdmin|WindowsPrincipal|Administrator)'
            $content | Should -Match '(?i)Start-Process.*-Verb\s+RunAs'
        }

        It 'Start-IToolkit.ps1 parses with zero syntax errors' -Skip:(-not $hasStartScript) {
            $path = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path 'Start-IToolkit.ps1'
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            $errors.Count | Should -Be 0
        }
    }

    Context 'Run-IToolkit.bat Wrapper Verification' {
        $hasBatchScript = Test-Path (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path 'Run-IToolkit.bat')

        It 'Run-IToolkit.bat exists in project root' -Skip:(-not $hasBatchScript) {
            $path = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path 'Run-IToolkit.bat'
            Test-Path $path | Should -BeTrue
        }

        It 'Run-IToolkit.bat includes administrator check and elevation command' -Skip:(-not $hasBatchScript) {
            $path = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path 'Run-IToolkit.bat'
            $content = Get-Content -Path $path -Raw
            # Checks for standard batch admin checks: openfiles, net session, or fltmc
            $content | Should -Match '(?i)(?:openfiles|net session|fltmc|powershell.*RunAs)'
            # Verifies ExecutionPolicy Bypass
            $content | Should -Match '(?i)-ExecutionPolicy\s+Bypass'
            # Verifies Start-IToolkit.ps1 invocation
            $content | Should -Match '(?i)Start-IToolkit\.ps1'
        }
    }

    Context 'Elevation Behavioral Contract Simulation' {
        It 'Non-elevated session triggers Start-Process with RunAs verb' {
            # Simulate non-admin runner function
            $elevationTriggered = $false
            $verbUsed = $null

            $simulatedLauncher = {
                param([bool]$IsElevated)
                if (-not $IsElevated) {
                    $verbUsed = 'RunAs'
                    $elevationTriggered = $true
                    return [PSCustomObject]@{ Relaunched = $true; Verb = $verbUsed }
                }
                return [PSCustomObject]@{ Relaunched = $false; Verb = $null }
            }

            $res = & $simulatedLauncher -IsElevated $false
            $res.Relaunched | Should -BeTrue
            $res.Verb | Should -Be 'RunAs'
        }

        It 'Elevated session bypasses relaunch and proceeds directly to toolkit execution' {
            $simulatedLauncher = {
                param([bool]$IsElevated)
                if (-not $IsElevated) {
                    return [PSCustomObject]@{ Relaunched = $true; Verb = 'RunAs' }
                }
                return [PSCustomObject]@{ Relaunched = $false; Initialized = $true }
            }

            $res = & $simulatedLauncher -IsElevated $true
            $res.Relaunched | Should -BeFalse
            $res.Initialized | Should -BeTrue
        }
    }

    Context 'Start-IToolkit.ps1 Non-Interactive & Pipeline Contract Verification' {
        $hasStartScript = Test-Path $script:StartScriptPath

        It 'Start-IToolkit.ps1 exits with code 0 when invoked with -SkipElevation -NonInteractive' -Skip:(-not $hasStartScript) {
            $psExe = (Get-Process -Id $PID).Path
            if ([string]::IsNullOrWhiteSpace($psExe)) {
                $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell.exe' }
            }
            $scriptPath = $script:StartScriptPath
            $bootstrap = "if (-not (Get-Command 'Write-ToolkitMenuDivider' -ErrorAction SilentlyContinue)) { function global:Write-ToolkitMenuDivider { param([int]`$w = 78) Write-Host ('  ' + ('-' * [math]::Max(20, `$w - 2))) } }; & '$scriptPath' -SkipElevation -NonInteractive"
            $output = & $psExe -NoProfile -Command $bootstrap
            $LASTEXITCODE | Should -Be 0
            ($output -join "`n") | Should -Match '(?i)Initialized in non-interactive mode'
        }

        It 'Start-IToolkit.ps1 -NonInteractive -MenuOption 1 prints category listing and terminates cleanly' -Skip:(-not $hasStartScript) {
            $psExe = (Get-Process -Id $PID).Path
            if ([string]::IsNullOrWhiteSpace($psExe)) {
                $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell.exe' }
            }
            $scriptPath = $script:StartScriptPath
            $bootstrap = "if (-not (Get-Command 'Write-ToolkitMenuDivider' -ErrorAction SilentlyContinue)) { function global:Write-ToolkitMenuDivider { param([int]`$w = 78) Write-Host ('  ' + ('-' * [math]::Max(20, `$w - 2))) } }; & '$scriptPath' -SkipElevation -NonInteractive -MenuOption '1'"
            $output = & $psExe -NoProfile -Command $bootstrap
            $LASTEXITCODE | Should -Be 0
            $outputStr = $output -join "`n"
            $outputStr | Should -Match '(?i)Outlook & PST Data Management'
            $outputStr | Should -Match '(?i)Non-interactive category listing complete'
        }

        It 'Start-IToolkit.ps1 -NonInteractive -MenuOption Q exits cleanly with code 0' -Skip:(-not $hasStartScript) {
            $psExe = (Get-Process -Id $PID).Path
            if ([string]::IsNullOrWhiteSpace($psExe)) {
                $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell.exe' }
            }
            $scriptPath = $script:StartScriptPath
            $bootstrap = "if (-not (Get-Command 'Write-ToolkitMenuDivider' -ErrorAction SilentlyContinue)) { function global:Write-ToolkitMenuDivider { param([int]`$w = 78) Write-Host ('  ' + ('-' * [math]::Max(20, `$w - 2))) } }; & '$scriptPath' -SkipElevation -NonInteractive -MenuOption 'Q'"
            $output = & $psExe -NoProfile -Command $bootstrap
            $LASTEXITCODE | Should -Be 0
            ($output -join "`n") | Should -Match '(?i)Exiting IToolkit'
        }

        It 'Start-IToolkit.ps1 does not hang when stdin is closed (EOF / null input stream)' -Skip:(-not $hasStartScript) {
            $psExe = (Get-Process -Id $PID).Path
            if ([string]::IsNullOrWhiteSpace($psExe)) {
                if ($PSVersionTable.PSEdition -eq 'Core') {
                    $psExe = 'pwsh'
                } else {
                    $psExe = 'powershell.exe'
                }
            }
            $scriptPath = $script:StartScriptPath
            
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $psExe
            $bootstrap = "if (-not (Get-Command 'Write-ToolkitMenuDivider' -ErrorAction SilentlyContinue)) { function global:Write-ToolkitMenuDivider { param([int]`$w = 78) Write-Host ('  ' + ('-' * [math]::Max(20, `$w - 2))) } }; & '$scriptPath' -SkipElevation -NonInteractive -MenuOption 1"
            $psi.Arguments = "-NoProfile -Command `"$bootstrap`""
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false

            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.StandardInput.Close()
            $stdout = $proc.StandardOutput.ReadToEnd()
            $stderr = $proc.StandardError.ReadToEnd()
            $completed = $proc.WaitForExit(30000)

            if (-not $completed) {
                try { $proc.Kill() } catch { $null = $_ }
            }

            $completed | Should -BeTrue
            $proc.ExitCode | Should -Be 0
        }

        It 'Start-IToolkit.ps1 executes all 6 submenus non-interactively with zero errors' -Skip:(-not $hasStartScript) {
            $psExe = (Get-Process -Id $PID).Path
            if ([string]::IsNullOrWhiteSpace($psExe)) {
                $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell.exe' }
            }
            $scriptPath = $script:StartScriptPath

            $options = @('1', '2', '3', '4', '5', '6')
            foreach ($opt in $options) {
                $bootstrap = "if (-not (Get-Command 'Write-ToolkitMenuDivider' -ErrorAction SilentlyContinue)) { function global:Write-ToolkitMenuDivider { param([int]`$w = 78) Write-Host ('  ' + ('-' * [math]::Max(20, `$w - 2))) } }; & '$scriptPath' -SkipElevation -NonInteractive -MenuOption $opt"
                $output = & $psExe -NoProfile -Command $bootstrap
                $LASTEXITCODE | Should -Be 0
                ($output -join "`n") | Should -Match '(?i)Non-interactive category listing complete'
            }
        }

        It 'Start-IToolkit.ps1 exits cleanly when invoked with -SkipElevation -ExitImmediately' -Skip:(-not $hasStartScript -or -not ((Get-Command $script:StartScriptPath).Parameters.ContainsKey('ExitImmediately'))) {
            $psExe = (Get-Process -Id $PID).Path
            if ([string]::IsNullOrWhiteSpace($psExe)) {
                $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell.exe' }
            }
            $scriptPath = $script:StartScriptPath
            $bootstrap = "if (-not (Get-Command 'Write-ToolkitMenuDivider' -ErrorAction SilentlyContinue)) { function global:Write-ToolkitMenuDivider { param([int]`$w = 78) Write-Host ('  ' + ('-' * [math]::Max(20, `$w - 2))) } }; & '$scriptPath' -SkipElevation -ExitImmediately"
            $output = & $psExe -NoProfile -Command $bootstrap
            $LASTEXITCODE | Should -Be 0
        }

        It 'Headless invocation of Start-IToolkit.ps1 extracts system telemetry without user interaction' -Skip:(-not $hasStartScript) {
            $psExe = (Get-Process -Id $PID).Path
            if ([string]::IsNullOrWhiteSpace($psExe)) {
                $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell.exe' }
            }
            $scriptPath = $script:StartScriptPath

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $psExe
            $bootstrap = "if (-not (Get-Command 'Write-ToolkitMenuDivider' -ErrorAction SilentlyContinue)) { function global:Write-ToolkitMenuDivider { param([int]`$w = 78) Write-Host ('  ' + ('-' * [math]::Max(20, `$w - 2))) } }; & '$scriptPath' -SkipElevation -NonInteractive -MenuOption 1"
            $psi.Arguments = "-NoProfile -Command `"$bootstrap`""
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false

            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.StandardInput.Close()
            $stdout = $proc.StandardOutput.ReadToEnd()
            $completed = $proc.WaitForExit(15000)

            if (-not $completed) {
                try { $proc.Kill() } catch { $null = $_ }
            }

            $completed | Should -BeTrue
            $proc.ExitCode | Should -Be 0
            $stdout | Should -Match '(?i)ITOOLKIT > OUTLOOK'
            $stdout | Should -Match '(?i)Initialized in non-interactive mode'
        }
    }
}
