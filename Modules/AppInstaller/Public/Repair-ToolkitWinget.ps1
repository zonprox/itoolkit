function Repair-ToolkitWinget {
<#
.SYNOPSIS
    Self-diagnosis and auto-repair engine for Windows Package Manager (winget).
.DESCRIPTION
    Diagnoses winget execution status, repairs disabled or missing App Execution Aliases,
    resets corrupted or unreachable source repository caches (winget source reset --force),
    re-registers Microsoft.DesktopAppInstaller AppX packages, and re-installs missing runtime dependencies.
    Supports -WhatIf / SupportsShouldProcess.
.PARAMETER Force
    Executes all repair stages unconditionally regardless of current health state.
.OUTPUTS
    [PSCustomObject] containing ActionsTaken, Success, Healthy, ErrorMessage.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        if (-not (Get-Command -Name 'Write-AppInstallerLog' -ErrorAction SilentlyContinue)) {
            $privLog = Join-Path (Split-Path -Parent $PSScriptRoot) 'Private/Write-AppInstallerLog.ps1'
            if (Test-Path -LiteralPath $privLog) { . $privLog }
        }

        if (-not $PSCmdlet.ShouldProcess("Windows Package Manager (winget)", "Diagnose and repair winget execution aliases, source repositories, AppX registration, and dependencies")) {
            Write-AppInstallerLog -Message "ShouldProcess: Skipping winget self-repair (WhatIf mode)." -Level 'DEBUG' -Component 'Repair-ToolkitWinget'
            return [PSCustomObject]@{
                ActionsTaken = @()
                Success      = $false
                Healthy      = $false
                ErrorMessage = 'Operation skipped by ShouldProcess (-WhatIf).'
            }
        }

        Write-AppInstallerLog -Message "Starting Windows Package Manager (winget) self-diagnosis and repair sequence..." -Level 'INFO' -Component 'Repair-ToolkitWinget'

        $actionsTaken = [System.Collections.Generic.List[string]]::new()
        $initialStatus = $null
        if (Get-Command -Name 'Get-ToolkitWingetStatus' -ErrorAction SilentlyContinue) {
            $initialStatus = Get-ToolkitWingetStatus
        }

        # 1. Detect & Repair App Execution Alias / PATH
        Write-AppInstallerLog -Message "Diagnosing App Execution Alias and PATH configuration for winget.exe..." -Level 'DEBUG' -Component 'Repair-ToolkitWinget'
        $aliasDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps' } else { $null }
        $aliasPath = if ($aliasDir) { Join-Path $aliasDir 'winget.exe' } else { $null }

        $needsAliasFix = $false
        if ($aliasDir -and -not (Test-Path -LiteralPath $aliasPath)) {
            $needsAliasFix = $true
        }
        if ($aliasDir -and ($env:PATH -notlike "*$aliasDir*")) {
            $needsAliasFix = $true
        }

        if ($needsAliasFix -or $Force -or ($initialStatus -and -not $initialStatus.Available)) {
            try {
                if ($aliasDir -and ($env:PATH -notlike "*$aliasDir*")) {
                    $env:PATH = "$aliasDir;$env:PATH"
                }
                if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT -and $aliasDir) {
                    try {
                        $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
                        if ($userPath -notlike "*$aliasDir*") {
                            [System.Environment]::SetEnvironmentVariable('Path', "$aliasDir;$userPath", 'User')
                        }
                    } catch { $null = $_ }
                }
                $actionsTaken.Add('Repaired App Execution Alias and PATH configuration')
                Write-AppInstallerLog -Message "App Execution Alias and PATH verified." -Level 'DEBUG' -Component 'Repair-ToolkitWinget'
            } catch {
                Write-AppInstallerLog -Message "Notice while repairing alias: $($_.Exception.Message)" -Level 'WARN' -Component 'Repair-ToolkitWinget'
            }
        }

        # 2. Reset corrupted or unreachable source repository cache (winget source reset --force)
        Write-AppInstallerLog -Message "Diagnosing winget repository source cache..." -Level 'DEBUG' -Component 'Repair-ToolkitWinget'
        $shouldResetSources = $Force
        if ($initialStatus -and (-not $initialStatus.SourcesHealthy -or -not $initialStatus.Healthy)) {
            $shouldResetSources = $true
        }

        if ($shouldResetSources) {
            Write-AppInstallerLog -Message "Resetting corrupted or unreachable winget package source cache..." -Level 'INFO' -Component 'Repair-ToolkitWinget'
            try {
                $proc = Start-Process -FilePath 'winget' -ArgumentList 'source reset --force' -Wait -PassThru -ErrorAction Stop
                $exitCode = if ($null -ne $proc.ExitCode) { $proc.ExitCode } else { 0 }
                if ($exitCode -eq 0) {
                    $actionsTaken.Add('Reset winget package source cache with --force')
                    Write-AppInstallerLog -Message "Source cache reset completed successfully." -Level 'INFO' -Component 'Repair-ToolkitWinget'
                } else {
                    $actionsTaken.Add("Reset winget package source cache with --force (exit code: $exitCode)")
                    Write-AppInstallerLog -Message "Source cache reset returned non-zero code $exitCode." -Level 'WARN' -Component 'Repair-ToolkitWinget'
                }
            } catch {
                Write-AppInstallerLog -Message "Could not execute 'winget source reset --force': $($_.Exception.Message)" -Level 'WARN' -Component 'Repair-ToolkitWinget'
            }
        }

        # 3. Re-register AppX package via Add-AppxPackage if registration is broken
        Write-AppInstallerLog -Message "Diagnosing Microsoft.DesktopAppInstaller AppX package registration..." -Level 'DEBUG' -Component 'Repair-ToolkitWinget'
        $midStatus = if (Get-Command -Name 'Get-ToolkitWingetStatus' -ErrorAction SilentlyContinue) { Get-ToolkitWingetStatus } else { $null }
        $shouldReRegister = $Force
        if ($midStatus -and (-not $midStatus.Available -or [string]::IsNullOrWhiteSpace($midStatus.Version))) {
            $shouldReRegister = $true
        }

        if ($shouldReRegister) {
            Write-AppInstallerLog -Message "Attempting AppX package registration remediation..." -Level 'INFO' -Component 'Repair-ToolkitWinget'
            $regSuccess = $false
            try {
                if (Get-Command -Name 'Get-AppxPackage' -ErrorAction SilentlyContinue) {
                    $pkg = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue
                    if ($pkg -and $pkg.InstallLocation) {
                        $manifest = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
                        if (Test-Path -LiteralPath $manifest) {
                            if (Get-Command -Name 'Add-AppxPackage' -ErrorAction SilentlyContinue) {
                                Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop
                                $regSuccess = $true
                            }
                        }
                    }
                }
                if (-not $regSuccess -and (Get-Command -Name 'Install-ToolkitWingetLatest' -ErrorAction SilentlyContinue)) {
                    $boot = Install-ToolkitWingetLatest -Force
                    if ($boot.Success) {
                        $regSuccess = $true
                    }
                }
                if ($regSuccess) {
                    $actionsTaken.Add('Re-registered Microsoft.DesktopAppInstaller AppX package')
                    Write-AppInstallerLog -Message "Re-registered DesktopAppInstaller AppX package." -Level 'INFO' -Component 'Repair-ToolkitWinget'
                }
            } catch {
                Write-AppInstallerLog -Message "Failed re-registering AppX package: $($_.Exception.Message)" -Level 'WARN' -Component 'Repair-ToolkitWinget'
            }
        }

        # 4. Re-install missing runtime dependencies if dependency mismatch detected
        Write-AppInstallerLog -Message "Diagnosing runtime dependencies..." -Level 'DEBUG' -Component 'Repair-ToolkitWinget'
        $postStatus = if (Get-Command -Name 'Get-ToolkitWingetStatus' -ErrorAction SilentlyContinue) { Get-ToolkitWingetStatus } else { $null }
        $shouldReinstallDeps = $Force
        if ($postStatus -and (-not $postStatus.Healthy)) {
            $shouldReinstallDeps = $true
        }

        if ($shouldReinstallDeps) {
            Write-AppInstallerLog -Message "Re-installing runtime dependencies (VCLibs / UI.Xaml)..." -Level 'INFO' -Component 'Repair-ToolkitWinget'
            try {
                if (Get-Command -Name 'Install-ToolkitWingetLatest' -ErrorAction SilentlyContinue) {
                    $depRes = Install-ToolkitWingetLatest -Force
                    if ($depRes.Success -or ($depRes.DependenciesInstalled -and $depRes.DependenciesInstalled.Count -gt 0)) {
                        $actionsTaken.Add('Re-installed runtime dependencies (VCLibs / UI.Xaml)')
                        Write-AppInstallerLog -Message "Runtime dependencies re-installed successfully." -Level 'INFO' -Component 'Repair-ToolkitWinget'
                    }
                }
            } catch {
                Write-AppInstallerLog -Message "Error re-installing runtime dependencies: $($_.Exception.Message)" -Level 'WARN' -Component 'Repair-ToolkitWinget'
            }
        }

        # 5. Final Evaluation
        $finalStatus = if (Get-Command -Name 'Get-ToolkitWingetStatus' -ErrorAction SilentlyContinue) {
            Get-ToolkitWingetStatus
        } else {
            $null
        }

        $isHealthy = if ($finalStatus) { [bool]$finalStatus.Healthy } else { [bool](Get-Command -Name 'winget' -ErrorAction SilentlyContinue) }
        $isSuccess = ($isHealthy -or $actionsTaken.Count -gt 0)

        Write-AppInstallerLog -Message "Repair-ToolkitWinget summary: Success=$isSuccess, Healthy=$isHealthy, ActionsCount=$($actionsTaken.Count)" -Level 'INFO' -Component 'Repair-ToolkitWinget'

        return [PSCustomObject]@{
            ActionsTaken = @($actionsTaken)
            Success      = $isSuccess
            Healthy      = $isHealthy
            ErrorMessage = if (-not $isHealthy -and $finalStatus) { $finalStatus.ErrorMessage } else { $null }
        }
    }
}
