function Install-ToolkitApplication {
<#
.SYNOPSIS
    Installs standard enterprise applications with automated desktop shortcut and default association configuration.
.DESCRIPTION
    Automates silent installation of UniKey, UltraVNC, K-Lite Codec Pack, Google Chrome,
    Visual C++ Redistributables All-In-One (vcredist AIO), Foxit PDF Reader, and Zalo PC.
    Sequences runtime dependencies (VCRedistAIO) first, guards against conflicting active processes,
    utilizes Windows Package Manager (winget) with resilient direct URL fallback, automatically creates
    desktop shortcuts, assigns default browser/PDF handlers, and deploys Chrome enterprise policies.
.PARAMETER AppName
    Application to install. Valid values: 'UniKey', 'UltraVNC', 'KLiteCodec', 'Chrome', 'VCRedistAIO', 'FoxitReader', 'Zalo', 'All'. Default is 'All'.
.PARAMETER CreateShortcut
    Creates a desktop shortcut (.lnk) on the current user's desktop upon installation. Default is true.
.PARAMETER SetDefault
    Configures the application as default handler (Chrome for web, Foxit for PDF). Default is true.
.PARAMETER ConfigureChromeExtensions
    Configures Chrome enterprise policy (ExtensionInstallForcelist) to force-install uBlock Origin Lite. Default is true.
.PARAMETER OptimizePostInstall
    Performs post-installation tuning (shortcut validation and disabling unwanted startup launch entries).
.PARAMETER Force
    Re-runs installation and overwrites even if the application is already detected.
.OUTPUTS
    [PSCustomObject[]] containing AppName, Installed, ShortcutCreated, DefaultConfigured, ExecutablePath, Status.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('UniKey', 'UltraVNC', 'KLiteCodec', 'Chrome', 'VCRedistAIO', 'FoxitReader', 'Zalo', 'All')]
        [string]$AppName = 'All',

        [Parameter(Mandatory = $false)]
        [switch]$CreateShortcut = $true,

        [Parameter(Mandatory = $false)]
        [switch]$SetDefault = $true,

        [Parameter(Mandatory = $false)]
        [switch]$ConfigureChromeExtensions = $true,

        [Parameter(Mandatory = $false)]
        [switch]$OptimizePostInstall,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        if (-not (Get-Command -Name 'Write-AppInstallerLog' -ErrorAction SilentlyContinue)) {
            $privLog = Join-Path (Split-Path -Parent $PSScriptRoot) 'Private/Write-AppInstallerLog.ps1'
            if (Test-Path -LiteralPath $privLog) { . $privLog }
        }

        # 1. Pre-Flight Internet Connectivity Check
        Write-AppInstallerLog -Message "Validating pre-flight network connectivity..." -Level 'DEBUG' -Component 'Install-ToolkitApplication'
        $online = $true
        if (Get-Command -Name 'Test-InternetConnectivity' -ErrorAction SilentlyContinue) {
            $online = Test-InternetConnectivity
        }
        if (-not $online) {
            Write-AppInstallerLog -Message "Pre-flight check failed: Internet connectivity is required to download application packages." -Level 'ERROR' -Component 'Install-ToolkitApplication'
            throw "Pre-flight check failed: Internet connectivity is required to download application packages."
        }
        Write-AppInstallerLog -Message "Pre-flight connectivity check passed." -Level 'DEBUG' -Component 'Install-ToolkitApplication'

        # 2. Application Definition Catalog
        $catalog = @{
            'VCRedistAIO' = @{
                DisplayName     = 'Visual C++ Redistributable AIO'
                WingetId        = 'abbodi1406.vcredist'
                FallbackUrl     = 'https://github.com/abbodi1406/vcredist/releases/latest/download/VisualCppRedist_AIO_x86_x64.exe'
                SilentArgs      = '/ai /y'
                ShortcutName    = $null # Runtime libraries, no desktop shortcut needed
                CanSetDefault   = $false
                ProcessNames    = @()
            }
            'UniKey' = @{
                DisplayName     = 'UniKey Vietnamese Input Method'
                WingetId        = 'PhamKimLong.UniKey'
                FallbackUrl     = 'https://www.unikey.org/'
                SilentArgs      = '/VERYSILENT /NORESTART'
                ShortcutName    = 'UniKey.lnk'
                CanSetDefault   = $false
                ProcessNames    = @('UniKeyNT', 'UniKey')
            }
            'UltraVNC' = @{
                DisplayName     = 'UltraVNC Remote Support'
                WingetId        = 'uvnc.UltraVNC'
                FallbackUrl     = 'https://uvnc.com/'
                SilentArgs      = '/VERYSILENT /NORESTART'
                ShortcutName    = 'UltraVNC Viewer.lnk'
                CanSetDefault   = $false
                ProcessNames    = @('vncviewer', 'winvnc')
            }
            'KLiteCodec' = @{
                DisplayName     = 'K-Lite Codec Pack'
                WingetId        = 'CodecGuide.K-LiteCodecPack.Standard'
                FallbackUrl     = 'https://codecguide.com/'
                SilentArgs      = '/verysilent /norestart'
                ShortcutName    = 'Media Player Classic.lnk'
                CanSetDefault   = $false
                ProcessNames    = @('mpc-hc64', 'mpc-hc', 'mpc-be64', 'mpc-be')
            }
            'Chrome' = @{
                DisplayName     = 'Google Chrome'
                WingetId        = 'Google.Chrome'
                FallbackUrl     = 'https://dl.google.com/chrome/install/latest/chrome_installer.exe'
                SilentArgs      = '/silent /install'
                ShortcutName    = 'Google Chrome.lnk'
                CanSetDefault   = $true
                ProcessNames    = @('chrome')
            }
            'FoxitReader' = @{
                DisplayName     = 'Foxit PDF Reader'
                WingetId        = 'Foxit.FoxitReader'
                FallbackUrl     = 'https://cdn01.foxitsoftware.com/product/reader/desktop/win/latest/FoxitPDFReader_Setup.exe'
                SilentArgs      = '/quiet /norestart'
                ShortcutName    = 'Foxit PDF Reader.lnk'
                CanSetDefault   = $true
                ProcessNames    = @('FoxitPDFReader', 'FoxitReader')
            }
            'Zalo' = @{
                DisplayName     = 'Zalo'
                WingetId        = 'VNG.Zalo'
                FallbackUrl     = 'https://res-download-pc-te-vnso-zn-31.zadn.vn/win/ZaloSetup.exe'
                SilentArgs      = '/VERYSILENT /NORESTART /S'
                ShortcutName    = 'Zalo.lnk'
                CanSetDefault   = $false
                ProcessNames    = @('Zalo')
            }
        }

        # 3. Dependency Sequencing & Target Resolution
        $targets = if ($AppName -eq 'All') {
            @('VCRedistAIO', 'UniKey', 'UltraVNC', 'KLiteCodec', 'Chrome', 'FoxitReader', 'Zalo')
        } else {
            @($AppName)
        }

        # Automatically sequence runtime dependencies (VCRedistAIO) to be installed first
        if ($targets -contains 'VCRedistAIO' -and $targets[0] -ne 'VCRedistAIO') {
            $targets = @('VCRedistAIO') + ($targets | Where-Object { $_ -ne 'VCRedistAIO' })
            Write-AppInstallerLog -Message "Dependency sequencing: Reordered VCRedistAIO to first position ahead of dependent applications." -Level 'DEBUG' -Component 'Install-ToolkitApplication'
        }

        Write-AppInstallerLog -Message "Resolved deployment targets: $($targets -join ', ')" -Level 'INFO' -Component 'Install-ToolkitApplication'

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        $hasWinget = [bool](Get-Command -Name 'winget' -ErrorAction SilentlyContinue)

        foreach ($target in $targets) {
            $meta = $catalog[$target]
            if (-not $meta) { continue }

            if (-not $PSCmdlet.ShouldProcess("$($meta.DisplayName) ($target)", "Install application, create shortcut, and configure default handlers")) {
                Write-AppInstallerLog -Message "ShouldProcess: Skipping installation for $($meta.DisplayName) (WhatIf mode)." -Level 'DEBUG' -Component 'Install-ToolkitApplication'
                $results.Add([PSCustomObject]@{
                    AppName           = $target
                    DisplayName       = $meta.DisplayName
                    Installed         = $false
                    ShortcutCreated   = $false
                    DefaultConfigured = $false
                    ExecutablePath    = $null
                    Status            = 'WhatIf'
                })
                continue
            }

            # 4. Check If Application Is Already Installed
            Write-AppInstallerLog -Message "Checking if $($meta.DisplayName) is already installed..." -Level 'DEBUG' -Component 'Install-ToolkitApplication'
            $currentStatus = Get-ToolkitInstalledApplication -AppName $target
            $installed = $currentStatus.Installed
            $exePath = $currentStatus.ExecutablePath

            if ($installed -and -not $Force) {
                Write-AppInstallerLog -Message "$($meta.DisplayName) is already installed at '$exePath'. Skipping reinstallation (use -Force to override)." -Level 'INFO' -Component 'Install-ToolkitApplication'
                $results.Add([PSCustomObject]@{
                    AppName           = $target
                    DisplayName       = $meta.DisplayName
                    Installed         = $true
                    ShortcutCreated   = $false
                    DefaultConfigured = $false
                    ExecutablePath    = $exePath
                    Status            = 'OK'
                })
                continue
            }

            # 5. Intelligent Process Conflict & Pre-Flight Management
            if ($meta.ProcessNames -and $meta.ProcessNames.Count -gt 0) {
                foreach ($procName in $meta.ProcessNames) {
                    try {
                        $runningList = Get-Process -Name $procName -ErrorAction SilentlyContinue
                        if ($runningList) {
                            $procCount = if ($runningList -is [System.Array]) { $runningList.Count } else { 1 }
                            Write-AppInstallerLog -Message "Conflicting process '$procName' detected ($procCount active instance(s)) for $($meta.DisplayName). Terminating process to prevent installer locks..." -Level 'WARN' -Component 'Install-ToolkitApplication'
                            Stop-Process -Name $procName -Force -ErrorAction SilentlyContinue
                            Write-AppInstallerLog -Message "Successfully terminated conflicting process '$procName'." -Level 'INFO' -Component 'Install-ToolkitApplication'
                            Start-Sleep -Milliseconds 250
                        }
                    } catch {
                        Write-AppInstallerLog -Message "Could not inspect conflicting processes for '$procName': $($_.Exception.Message)" -Level 'WARN' -Component 'Install-ToolkitApplication'
                    }
                }
            }

            # 6. Multi-Tier Silent Installation Execution
            Write-AppInstallerLog -Message "Initiating installation for $($meta.DisplayName)..." -Level 'INFO' -Component 'Install-ToolkitApplication'
            $installedSuccess = $false

            # Method A: Try Windows Package Manager (winget) first
            if ($hasWinget -and -not [string]::IsNullOrWhiteSpace($meta.WingetId)) {
                try {
                    $wingetArgs = "install --id $($meta.WingetId) -e --silent --accept-package-agreements --accept-source-agreements $(if ($Force) { '--force' } else { '' })".Trim()
                    Write-AppInstallerLog -Message "Invoking winget: winget $wingetArgs" -Level 'DEBUG' -Component 'Install-ToolkitApplication'
                    $proc = Start-Process -FilePath "winget" -ArgumentList $wingetArgs -Wait -PassThru -ErrorAction Stop
                    $exitCode = if ($null -ne $proc.ExitCode) { $proc.ExitCode } else { 0 }
                    Write-AppInstallerLog -Message "winget process exited with code $exitCode." -Level $(if ($exitCode -eq 0) { 'DEBUG' } else { 'WARN' }) -Component 'Install-ToolkitApplication'
                    if ($exitCode -eq 0) {
                        $installedSuccess = $true
                    } else {
                        Write-AppInstallerLog -Message "winget installation for $($meta.DisplayName) returned non-zero code $exitCode. Falling back to direct URL resolution..." -Level 'WARN' -Component 'Install-ToolkitApplication'
                    }
                } catch {
                    Write-AppInstallerLog -Message "winget execution error for $($meta.DisplayName): $($_.Exception.Message). Falling back to direct URL resolution..." -Level 'WARN' -Component 'Install-ToolkitApplication'
                }
            }

            # Method B: Direct URL download and execute if winget was unavailable or unsuccessful
            if (-not $installedSuccess -and -not [string]::IsNullOrWhiteSpace($meta.FallbackUrl) -and $meta.FallbackUrl.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-AppInstallerLog -Message "Attempting direct download fallback for $($meta.DisplayName) from $($meta.FallbackUrl)..." -Level 'INFO' -Component 'Install-ToolkitApplication'
                $tempDir = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { [System.IO.Path]::GetTempPath() }
                $tempInstaller = Join-Path $tempDir "$target-installer.exe"
                $downloadSuccess = $false
                $maxRetries = 2

                for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
                    try {
                        Write-AppInstallerLog -Message "Downloading $($meta.DisplayName) installer (attempt $attempt of $maxRetries)..." -Level 'DEBUG' -Component 'Install-ToolkitApplication'
                        Invoke-WebRequest -Uri $meta.FallbackUrl -OutFile $tempInstaller -UseBasicParsing -ErrorAction Stop
                        $downloadSuccess = $true
                        Write-AppInstallerLog -Message "Successfully downloaded $($meta.DisplayName) installer." -Level 'DEBUG' -Component 'Install-ToolkitApplication'
                        break
                    } catch {
                        Write-AppInstallerLog -Message "Download attempt $attempt failed for $($meta.DisplayName): $($_.Exception.Message)" -Level 'WARN' -Component 'Install-ToolkitApplication'
                        if ($attempt -lt $maxRetries) {
                            Start-Sleep -Milliseconds 500
                        }
                    }
                }

                if ($downloadSuccess) {
                    try {
                        Write-AppInstallerLog -Message "Launching silent installer: $tempInstaller $($meta.SilentArgs)" -Level 'DEBUG' -Component 'Install-ToolkitApplication'
                        $proc = Start-Process -FilePath $tempInstaller -ArgumentList $meta.SilentArgs -Wait -PassThru -ErrorAction Stop
                        $exitCode = if ($null -ne $proc.ExitCode) { $proc.ExitCode } else { 0 }
                        Write-AppInstallerLog -Message "Silent installer exited with code $exitCode." -Level $(if ($exitCode -eq 0) { 'DEBUG' } else { 'WARN' }) -Component 'Install-ToolkitApplication'
                        if ($exitCode -eq 0) {
                            $installedSuccess = $true
                        }
                    } catch {
                        Write-AppInstallerLog -Message "Silent installer execution failed for $($meta.DisplayName): $($_.Exception.Message)" -Level 'ERROR' -Component 'Install-ToolkitApplication'
                    } finally {
                        Remove-Item -LiteralPath $tempInstaller -Force -ErrorAction SilentlyContinue
                    }
                } else {
                    Write-AppInstallerLog -Message "Direct download failed for $($meta.DisplayName) after $maxRetries attempts." -Level 'ERROR' -Component 'Install-ToolkitApplication'
                }
            }

            # 7. Post-Installation Verification
            $postCheck = Get-ToolkitInstalledApplication -AppName $target
            $installed = $postCheck.Installed
            $exePath = $postCheck.ExecutablePath
            if ($installed) {
                Write-AppInstallerLog -Message "Installation successfully verified for $($meta.DisplayName)." -Level 'SUCCESS' -Component 'Install-ToolkitApplication'
            } else {
                Write-AppInstallerLog -Message "Installation could not be verified for $($meta.DisplayName)." -Level 'WARN' -Component 'Install-ToolkitApplication'
            }

            # 8. Desktop Shortcut Creation
            $shortcutCreated = $false
            if ($CreateShortcut -and -not [string]::IsNullOrWhiteSpace($meta.ShortcutName) -and -not [string]::IsNullOrWhiteSpace($exePath)) {
                try {
                    Write-AppInstallerLog -Message "Creating desktop shortcut '$($meta.ShortcutName)' for $($meta.DisplayName)..." -Level 'DEBUG' -Component 'Install-ToolkitApplication'
                    $shortcutResult = New-ToolkitDesktopShortcut -TargetExecutable $exePath -ShortcutName $meta.ShortcutName -Force:$Force
                    $shortcutCreated = [bool]($shortcutResult.Created -or $shortcutResult.AlreadyExists)
                    Write-AppInstallerLog -Message "Desktop shortcut configured: $($meta.ShortcutName)" -Level 'DEBUG' -Component 'Install-ToolkitApplication'
                } catch {
                    Write-AppInstallerLog -Message "Failed to create desktop shortcut for $($meta.DisplayName): $($_.Exception.Message)" -Level 'WARN' -Component 'Install-ToolkitApplication'
                }
            }

            # 9. Default Application Association (Strictly isolated to Chrome and Foxit)
            $defaultConfigured = $false
            if ($SetDefault -and $meta.CanSetDefault -and ($target -eq 'Chrome' -or $target -eq 'FoxitReader')) {
                try {
                    Write-AppInstallerLog -Message "Configuring default application association for $($meta.DisplayName)..." -Level 'DEBUG' -Component 'Install-ToolkitApplication'
                    $defResult = Set-ToolkitDefaultApplication -Application $target -ExecutablePath $exePath
                    $defaultConfigured = [bool]($defResult | Where-Object { $_.DefaultSet -eq $true })
                    Write-AppInstallerLog -Message "Default application association configured for $($meta.DisplayName)." -Level 'DEBUG' -Component 'Install-ToolkitApplication'
                } catch {
                    Write-AppInstallerLog -Message "Failed to configure default association for $($meta.DisplayName): $($_.Exception.Message)" -Level 'WARN' -Component 'Install-ToolkitApplication'
                }
            }

            # 10. Chrome Enterprise Extension Policy Deployment (Strictly isolated to Google Chrome)
            if ($target -eq 'Chrome' -and $ConfigureChromeExtensions) {
                try {
                    Write-AppInstallerLog -Message "Deploying Chrome enterprise policy for extension uBlock Origin Lite..." -Level 'INFO' -Component 'Install-ToolkitApplication'
                    if (Get-Command -Name 'Set-ToolkitChromeExtensionPolicy' -ErrorAction SilentlyContinue) {
                        Set-ToolkitChromeExtensionPolicy | Out-Null
                        Write-AppInstallerLog -Message "Chrome enterprise policy for uBlock Origin Lite configured successfully." -Level 'DEBUG' -Component 'Install-ToolkitApplication'
                    }
                } catch {
                    Write-AppInstallerLog -Message "Failed to deploy Chrome extension policy: $($_.Exception.Message)" -Level 'WARN' -Component 'Install-ToolkitApplication'
                }
            }

            # 11. Post-Installation Optimization
            if ($OptimizePostInstall) {
                Write-AppInstallerLog -Message "Performing post-installation tuning for $($meta.DisplayName)..." -Level 'DEBUG' -Component 'Install-ToolkitApplication'
                # Validate desktop shortcut
                if (-not [string]::IsNullOrWhiteSpace($meta.ShortcutName)) {
                    $desktopPath = [Environment]::GetFolderPath('Desktop')
                    if ([string]::IsNullOrWhiteSpace($desktopPath)) { $desktopPath = "$env:USERPROFILE\Desktop" }
                    $lnkFile = Join-Path $desktopPath $meta.ShortcutName
                    if (Test-Path -LiteralPath $lnkFile -ErrorAction SilentlyContinue) {
                        Write-AppInstallerLog -Message "Post-install validation: Desktop shortcut verified at '$lnkFile'." -Level 'DEBUG' -Component 'Install-ToolkitApplication'
                    }
                }

                # Disable unwanted startup launch entries in Run keys
                try {
                    $runKeys = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run')
                    foreach ($rk in $runKeys) {
                        if (Test-Path -LiteralPath $rk -ErrorAction SilentlyContinue) {
                            $props = Get-ItemProperty -Path $rk -ErrorAction SilentlyContinue
                            if ($props) {
                                foreach ($prop in $props.PSObject.Properties) {
                                    if ($prop.Name -like "*$target*" -or $prop.Name -like "*$($meta.DisplayName)*") {
                                        Remove-ItemProperty -Path $rk -Name $prop.Name -Force -ErrorAction SilentlyContinue | Out-Null
                                        Write-AppInstallerLog -Message "Post-install optimization: Disabled startup launch entry '$($prop.Name)' in $rk." -Level 'INFO' -Component 'Install-ToolkitApplication'
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    Write-AppInstallerLog -Message "Post-install tuning notice: $($_.Exception.Message)" -Level 'DEBUG' -Component 'Install-ToolkitApplication'
                }
            }

            $statusVal = if ($installed) { 'OK' } else { 'WARN' }
            Write-AppInstallerLog -Message "Completed deployment workflow for $($meta.DisplayName) with status: $statusVal." -Level $(if ($installed) { 'SUCCESS' } else { 'WARN' }) -Component 'Install-ToolkitApplication'

            $results.Add([PSCustomObject]@{
                AppName           = $target
                DisplayName       = $meta.DisplayName
                Installed         = $installed
                ShortcutCreated   = $shortcutCreated
                DefaultConfigured = $defaultConfigured
                ExecutablePath    = $exePath
                Status            = $statusVal
            })
        }

        return $results.ToArray()
    }
}
