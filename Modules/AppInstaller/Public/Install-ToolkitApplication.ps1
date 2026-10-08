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
        [Parameter(Mandatory = $false, Position = 0, ValueFromPipeline = $true)]
        [ValidateSet('UniKey', 'UltraVNC', 'KLiteCodec', 'Chrome', 'VCRedistAIO', 'FoxitReader', 'Zalo', 'All')]
        [string[]]$AppName = @('All'),

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
        if (-not (Get-Command -Name 'Resolve-ToolkitApplicationDownloadUrl' -ErrorAction SilentlyContinue)) {
            $pubResolve = Join-Path $PSScriptRoot 'Resolve-ToolkitApplicationDownloadUrl.ps1'
            if (Test-Path -LiteralPath $pubResolve) { . $pubResolve }
        }

        if (-not (Get-PSDrive -Name 'C' -Scope Global -ErrorAction SilentlyContinue)) {
            New-PSDrive -Name 'C' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -Scope Global -ErrorAction SilentlyContinue -WhatIf:$false | Out-Null
        }
        $progFiles = if ($env:ProgramFiles) { $env:ProgramFiles } else { 'C:\Program Files' }
        $userProf = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { [System.IO.Path]::GetTempPath() }
        $localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $userProf 'AppData\Local' }

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
                DisplayName          = 'UniKey Vietnamese Input Method'
                WingetId             = 'PhamKimLong.UniKey'
                FallbackUrl          = 'https://www.unikey.org/assets/release/unikey46RC2-230919-win64.zip'
                AlternateFallbackUrl = 'https://www.unikey.org/assets/release/unikey46RC2-230919-win32.zip'
                Arm64FallbackUrl     = 'https://www.unikey.org/assets/release/unikey46RC2-250531-arm64.zip'
                InstallType          = 'Archive'
                TargetDir            = 'UniKey'
                TargetExe            = 'UniKeyNT.exe'
                SilentArgs           = '/VERYSILENT /NORESTART'
                ShortcutName         = 'UniKey.lnk'
                CanSetDefault        = $false
                ProcessNames         = @('UniKeyNT', 'UniKey')
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
                DisplayName          = 'Zalo'
                WingetId             = 'VNG.Zalo'
                AlternateWingetId    = 'VNGCorp.Zalo'
                FallbackUrl          = 'https://res-download-pc.zadn.vn/win/ZaloSetup-26.10.10.exe'
                AlternateFallbackUrl = 'https://res-zaloapp-aka-jpt.zdn.vn/win/ZaloSetup-26.10.10.exe'
                GenericFallbackUrl   = 'https://zalo.me/download/zalo-pc'
                SilentArgs           = '/VERYSILENT /NORESTART /S'
                ShortcutName         = 'Zalo.lnk'
                CanSetDefault        = $false
                ProcessNames         = @('Zalo')
            }
        }

        # 3. Dependency Sequencing & Target Resolution
        $targets = if ($AppName -contains 'All') {
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
                            try {
                                Stop-Process -Name $procName -Force -ErrorAction Stop
                                Write-AppInstallerLog -Message "Successfully terminated conflicting process '$procName'." -Level 'INFO' -Component 'Install-ToolkitApplication'
                            } catch {
                                Write-AppInstallerLog -Message "Could not terminate conflicting process '$procName': $($_.Exception.Message)" -Level 'WARN' -Component 'Install-ToolkitApplication'
                            }
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
                $candidateWingetIds = @($meta.WingetId)
                if (-not [string]::IsNullOrWhiteSpace($meta.AlternateWingetId)) {
                    $candidateWingetIds += $meta.AlternateWingetId
                }
                foreach ($wId in $candidateWingetIds) {
                    try {
                        $wingetArgs = "install --id $wId -e --silent --accept-package-agreements --accept-source-agreements $(if ($Force) { '--force' } else { '' })".Trim()
                        Write-AppInstallerLog -Message "Invoking winget: winget $wingetArgs" -Level 'DEBUG' -Component 'Install-ToolkitApplication'
                        $proc = Start-Process -FilePath "winget" -ArgumentList $wingetArgs -Wait -PassThru -ErrorAction Stop
                        $exitCode = if ($null -ne $proc.ExitCode) { $proc.ExitCode } else { 0 }
                        Write-AppInstallerLog -Message "winget process exited with code $exitCode." -Level $(if ($exitCode -eq 0) { 'DEBUG' } else { 'WARN' }) -Component 'Install-ToolkitApplication'
                        if ($exitCode -eq 0) {
                            $installedSuccess = $true
                            break
                        } else {
                            Write-AppInstallerLog -Message "winget installation for $($meta.DisplayName) (id: $wId) returned non-zero code $exitCode." -Level 'WARN' -Component 'Install-ToolkitApplication'
                        }
                    } catch {
                        Write-AppInstallerLog -Message "winget execution error for $($meta.DisplayName) (id: $wId): $($_.Exception.Message)." -Level 'WARN' -Component 'Install-ToolkitApplication'
                    }
                }
                if (-not $installedSuccess) {
                    Write-AppInstallerLog -Message "winget installation unsuccessful for $($meta.DisplayName). Falling back to direct URL resolution..." -Level 'WARN' -Component 'Install-ToolkitApplication'
                }
            }

            # Method B: Direct URL download and execute/extract if winget was unavailable or unsuccessful
            $fallbackUrls = [System.Collections.Generic.List[string]]::new()

            if (Get-Command -Name 'Resolve-ToolkitApplicationDownloadUrl' -ErrorAction SilentlyContinue) {
                try {
                    $dynInfo = Resolve-ToolkitApplicationDownloadUrl -AppName $target -ErrorAction SilentlyContinue
                    if ($dynInfo -and -not [string]::IsNullOrWhiteSpace($dynInfo.PrimaryUrl)) {
                        if ($dynInfo.PrimaryUrl -match '\.(exe|zip|msi)(\?.*)?$') {
                            $fallbackUrls.Add($dynInfo.PrimaryUrl)
                        }
                        if ($dynInfo.ResolvedDynamically) {
                            Write-AppInstallerLog -Message "Dynamically resolved latest download endpoint for $($meta.DisplayName): $($dynInfo.PrimaryUrl)" -Level 'DEBUG' -Component 'Install-ToolkitApplication'
                        }
                    }
                    if ($dynInfo -and $dynInfo.FallbackUrls) {
                        foreach ($fb in $dynInfo.FallbackUrls) {
                            if ($fb -match '\.(exe|zip|msi)(\?.*)?$' -and -not $fallbackUrls.Contains($fb)) {
                                $fallbackUrls.Add($fb)
                            }
                        }
                    }
                } catch {
                    $null = $_
                }
            }

            foreach ($uKey in @('FallbackUrl', 'AlternateFallbackUrl', 'Arm64FallbackUrl')) {
                if ($meta.ContainsKey($uKey)) {
                    $uVal = $meta[$uKey]
                    if (-not [string]::IsNullOrWhiteSpace($uVal) -and ($uVal -match '\.(exe|zip|msi)(\?.*)?$') -and -not $fallbackUrls.Contains($uVal)) {
                        $fallbackUrls.Add($uVal)
                    }
                }
            }

            if (-not $installedSuccess -and $fallbackUrls.Count -gt 0) {
                $tempDir = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { [System.IO.Path]::GetTempPath() }
                $downloadSuccess = $false
                $maxRetries = 2
                $downloadedFile = $null
                $isArchive = $false

                foreach ($currentUrl in $fallbackUrls) {
                    Write-AppInstallerLog -Message "Attempting direct download fallback for $($meta.DisplayName) from $currentUrl..." -Level 'INFO' -Component 'Install-ToolkitApplication'
                    $isArchive = ($currentUrl.EndsWith('.zip', [System.StringComparison]::OrdinalIgnoreCase) -or ($meta.InstallType -eq 'Archive'))
                    $tempExt = if ($isArchive) { '.zip' } else { '.exe' }
                    $tempInstaller = Join-Path $tempDir "$target-installer$tempExt"

                    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
                        try {
                            Write-AppInstallerLog -Message "Downloading $($meta.DisplayName) package (attempt $attempt of $maxRetries)..." -Level 'DEBUG' -Component 'Install-ToolkitApplication'
                            Invoke-WebRequest -Uri $currentUrl -OutFile $tempInstaller -UseBasicParsing -ErrorAction Stop
                            if (Test-Path -LiteralPath $tempInstaller) {
                                $downloadSuccess = $true
                                $downloadedFile = $tempInstaller
                                Write-AppInstallerLog -Message "Successfully downloaded $($meta.DisplayName) package." -Level 'DEBUG' -Component 'Install-ToolkitApplication'
                                break
                            }
                        } catch {
                            Write-AppInstallerLog -Message "Download attempt $attempt failed for $($meta.DisplayName): $($_.Exception.Message)" -Level 'WARN' -Component 'Install-ToolkitApplication'
                            if ($attempt -lt $maxRetries) {
                                Start-Sleep -Milliseconds 500
                            }
                        }
                    }

                    if ($downloadSuccess) { break }
                }

                if ($downloadSuccess -and $downloadedFile) {
                    if ($isArchive) {
                        try {
                            Write-AppInstallerLog -Message "Extracting archive package for $($meta.DisplayName)..." -Level 'DEBUG' -Component 'Install-ToolkitApplication'
                            $subDir = if ($meta.TargetDir) { $meta.TargetDir } else { $target }
                            $candidateDirs = [System.Collections.Generic.List[string]]::new()
                            $candidateDirs.Add((Join-Path $progFiles $subDir))
                            $candidateDirs.Add((Join-Path $localAppData "Programs\$subDir"))

                            $extracted = $false
                            foreach ($candDir in $candidateDirs) {
                                try {
                                    $destDir = $candDir
                                    if ($candDir -match '^[a-zA-Z]:[/\\]') {
                                        $dName = $candDir.Substring(0, 1)
                                        $psd = Get-PSDrive -Name $dName -ErrorAction SilentlyContinue
                                        if ($psd -and $psd.Root -and $psd.Root -ne "$dName`:\") {
                                            $rel = $candDir.Substring(3).TrimStart('\', '/')
                                            $destDir = Join-Path $psd.Root $rel
                                        }
                                    }

                                    if (-not (Test-Path -LiteralPath $destDir)) {
                                        New-Item -ItemType Directory -Path $destDir -Force -ErrorAction Stop | Out-Null
                                    }

                                    Expand-Archive -LiteralPath $downloadedFile -DestinationPath $destDir -Force -ErrorAction Stop
                                    $expectedExe = if ($meta.TargetExe) { Join-Path $destDir $meta.TargetExe } else { $null }
                                    if (-not $expectedExe -or (Test-Path -LiteralPath $expectedExe -ErrorAction SilentlyContinue)) {
                                        $installedSuccess = $true
                                        $extracted = $true
                                        Write-AppInstallerLog -Message "Successfully extracted $($meta.DisplayName) archive to '$destDir'." -Level 'INFO' -Component 'Install-ToolkitApplication'
                                        break
                                    }
                                } catch {
                                    Write-AppInstallerLog -Message "Archive extraction to '$candDir' unsuccessful: $($_.Exception.Message)" -Level 'DEBUG' -Component 'Install-ToolkitApplication'
                                }
                            }

                            if (-not $extracted) {
                                Write-AppInstallerLog -Message "Archive extraction failed for $($meta.DisplayName) across all target locations." -Level 'ERROR' -Component 'Install-ToolkitApplication'
                            }
                        } catch {
                            Write-AppInstallerLog -Message "Archive extraction exception for $($meta.DisplayName): $($_.Exception.Message)" -Level 'ERROR' -Component 'Install-ToolkitApplication'
                        } finally {
                            Remove-Item -LiteralPath $downloadedFile -Force -ErrorAction SilentlyContinue
                        }
                    } else {
                        try {
                            Write-AppInstallerLog -Message "Launching silent installer: $downloadedFile $($meta.SilentArgs)" -Level 'DEBUG' -Component 'Install-ToolkitApplication'
                            $proc = Start-Process -FilePath $downloadedFile -ArgumentList $meta.SilentArgs -Wait -PassThru -ErrorAction Stop
                            $exitCode = if ($null -ne $proc -and $null -ne $proc.ExitCode) { $proc.ExitCode } else { 0 }
                            Write-AppInstallerLog -Message "Silent installer exited with code $exitCode." -Level $(if ($exitCode -eq 0) { 'DEBUG' } else { 'WARN' }) -Component 'Install-ToolkitApplication'
                            if ($exitCode -eq 0) {
                                $installedSuccess = $true
                            }
                        } catch {
                            Write-AppInstallerLog -Message "Silent installer execution failed for $($meta.DisplayName): $($_.Exception.Message)" -Level 'ERROR' -Component 'Install-ToolkitApplication'
                        } finally {
                            Remove-Item -LiteralPath $downloadedFile -Force -ErrorAction SilentlyContinue
                        }
                    }
                } else {
                    Write-AppInstallerLog -Message "Direct download failed for $($meta.DisplayName) after $maxRetries attempts across available endpoints." -Level 'ERROR' -Component 'Install-ToolkitApplication'
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
                    $ignoredProps = @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')
                    foreach ($rk in $runKeys) {
                        if (Test-Path -LiteralPath $rk -ErrorAction SilentlyContinue) {
                            $props = Get-ItemProperty -Path $rk -ErrorAction SilentlyContinue
                            if ($props) {
                                foreach ($prop in $props.PSObject.Properties) {
                                    if ($prop.Name -in $ignoredProps) { continue }
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
