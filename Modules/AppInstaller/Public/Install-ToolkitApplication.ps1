function Install-ToolkitApplication {
<#
.SYNOPSIS
    Installs standard enterprise applications with automated desktop shortcut and default association configuration.
.DESCRIPTION
    Automates silent installation of UniKey, UltraVNC, K-Lite Codec Pack, Google Chrome,
    Visual C++ Redistributables All-In-One (vcredist AIO), and Foxit PDF Reader.
    Utilizes Windows Package Manager (winget) when available with graceful fallback to official silent installers.
    Automatically creates desktop shortcuts for the current user and assigns default applications for Chrome and Foxit.
.PARAMETER AppName
    Application to install. Valid values: 'UniKey', 'UltraVNC', 'KLiteCodec', 'Chrome', 'VCRedistAIO', 'FoxitReader', 'All'. Default is 'All'.
.PARAMETER CreateShortcut
    Creates a desktop shortcut (.lnk) on the current user's desktop upon installation. Default is true.
.PARAMETER SetDefault
    Configures the application as default handler (Chrome for web, Foxit for PDF). Default is true.
.PARAMETER Force
    Re-runs installation even if the application is already detected.
.OUTPUTS
    [PSCustomObject[]] containing AppName, Installed, ShortcutCreated, DefaultConfigured, ExecutablePath, Status.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('UniKey', 'UltraVNC', 'KLiteCodec', 'Chrome', 'VCRedistAIO', 'FoxitReader', 'All')]
        [string]$AppName = 'All',

        [Parameter(Mandatory = $false)]
        [switch]$CreateShortcut = $true,

        [Parameter(Mandatory = $false)]
        [switch]$SetDefault = $true,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        # 1. Pre-Flight Internet Connectivity Check
        $online = $true
        if (Get-Command -Name 'Test-InternetConnectivity' -ErrorAction SilentlyContinue) {
            $online = Test-InternetConnectivity
        }
        if (-not $online) {
            throw "Pre-flight check failed: Internet connectivity is required to download application packages."
        }

        # 2. Application Definition Catalog
        $catalog = @{
            'UniKey' = @{
                DisplayName     = 'UniKey Vietnamese Input Method'
                WingetId        = 'PhamKimLong.UniKey'
                FallbackUrl     = 'https://www.unikey.org/'
                SilentArgs      = '/VERYSILENT /NORESTART'
                ShortcutName    = 'UniKey.lnk'
                CanSetDefault   = $false
            }
            'UltraVNC' = @{
                DisplayName     = 'UltraVNC Remote Support'
                WingetId        = 'uvnc.UltraVNC'
                FallbackUrl     = 'https://uvnc.com/'
                SilentArgs      = '/VERYSILENT /NORESTART'
                ShortcutName    = 'UltraVNC Viewer.lnk'
                CanSetDefault   = $false
            }
            'KLiteCodec' = @{
                DisplayName     = 'K-Lite Codec Pack'
                WingetId        = 'CodecGuide.K-LiteCodecPack.Standard'
                FallbackUrl     = 'https://codecguide.com/'
                SilentArgs      = '/verysilent /norestart'
                ShortcutName    = 'Media Player Classic.lnk'
                CanSetDefault   = $false
            }
            'Chrome' = @{
                DisplayName     = 'Google Chrome'
                WingetId        = 'Google.Chrome'
                FallbackUrl     = 'https://dl.google.com/chrome/install/latest/chrome_installer.exe'
                SilentArgs      = '/silent /install'
                ShortcutName    = 'Google Chrome.lnk'
                CanSetDefault   = $true
            }
            'VCRedistAIO' = @{
                DisplayName     = 'Visual C++ Redistributable AIO'
                WingetId        = 'abbodi1406.vcredist'
                FallbackUrl     = 'https://github.com/abbodi1406/vcredist/releases/latest/download/VisualCppRedist_AIO_x86_x64.exe'
                SilentArgs      = '/ai /y'
                ShortcutName    = $null # Runtime libraries, no desktop shortcut needed
                CanSetDefault   = $false
            }
            'FoxitReader' = @{
                DisplayName     = 'Foxit PDF Reader'
                WingetId        = 'Foxit.FoxitReader'
                FallbackUrl     = 'https://cdn01.foxitsoftware.com/product/reader/desktop/win/latest/FoxitPDFReader_Setup.exe'
                SilentArgs      = '/quiet /norestart'
                ShortcutName    = 'Foxit PDF Reader.lnk'
                CanSetDefault   = $true
            }
        }

        $targets = if ($AppName -eq 'All') {
            @('UniKey', 'UltraVNC', 'KLiteCodec', 'Chrome', 'VCRedistAIO', 'FoxitReader')
        } else {
            @($AppName)
        }

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        $hasWinget = [bool](Get-Command -Name 'winget' -ErrorAction SilentlyContinue)

        foreach ($target in $targets) {
            $meta = $catalog[$target]
            if (-not $meta) { continue }

            if (-not $PSCmdlet.ShouldProcess("$($meta.DisplayName) ($target)", "Install application, create shortcut, and configure default handlers")) {
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

            # Check if already installed
            $currentStatus = Get-ToolkitInstalledApplication -AppName $target
            $installed = $currentStatus.Installed
            $exePath = $currentStatus.ExecutablePath

            if (-not $installed -or $Force) {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Installing $($meta.DisplayName)..." -Level 'INFO' -Component 'Install-ToolkitApplication'
                }

                $installedSuccess = $false

                # Method A: Try winget if available
                if ($hasWinget -and -not [string]::IsNullOrWhiteSpace($meta.WingetId)) {
                    try {
                        $wingetArgs = "install --id $($meta.WingetId) -e --silent --accept-package-agreements --accept-source-agreements --force"
                        $proc = Start-Process -FilePath "winget" -ArgumentList $wingetArgs -Wait -PassThru -ErrorAction Stop
                        if ($proc.ExitCode -eq 0) {
                            $installedSuccess = $true
                        }
                    } catch {
                        $null = $_
                    }
                }

                # Method B: Direct URL download and execute if winget was unsuccessful
                if (-not $installedSuccess -and -not [string]::IsNullOrWhiteSpace($meta.FallbackUrl) -and $meta.FallbackUrl.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
                    try {
                        $tempInstaller = Join-Path $env:TEMP "$target-installer.exe"
                        Invoke-WebRequest -Uri $meta.FallbackUrl -OutFile $tempInstaller -UseBasicParsing -ErrorAction Stop
                        $proc = Start-Process -FilePath $tempInstaller -ArgumentList $meta.SilentArgs -Wait -PassThru -ErrorAction Stop
                        if ($proc.ExitCode -eq 0 -or $null -eq $proc.ExitCode) {
                            $installedSuccess = $true
                        }
                        Remove-Item -LiteralPath $tempInstaller -Force -ErrorAction SilentlyContinue
                    } catch {
                        $null = $_
                    }
                }

                # Re-check installation state
                $postCheck = Get-ToolkitInstalledApplication -AppName $target
                $installed = $postCheck.Installed
                $exePath = $postCheck.ExecutablePath
            }

            # Shortcut creation for current user account
            $shortcutCreated = $false
            if ($CreateShortcut -and -not [string]::IsNullOrWhiteSpace($meta.ShortcutName) -and -not [string]::IsNullOrWhiteSpace($exePath)) {
                try {
                    $shortcutResult = New-ToolkitDesktopShortcut -TargetExecutable $exePath -ShortcutName $meta.ShortcutName
                    $shortcutCreated = [bool]($shortcutResult.Created -or $shortcutResult.AlreadyExists)
                } catch {
                    $null = $_
                }
            }

            # Set default handler for Chrome and Foxit
            $defaultConfigured = $false
            if ($SetDefault -and $meta.CanSetDefault) {
                try {
                    $defResult = Set-ToolkitDefaultApplication -Application $target -ExecutablePath $exePath
                    $defaultConfigured = [bool]($defResult | Where-Object { $_.DefaultSet -eq $true })
                } catch {
                    $null = $_
                }
            }

            $results.Add([PSCustomObject]@{
                AppName           = $target
                DisplayName       = $meta.DisplayName
                Installed         = $installed
                ShortcutCreated   = $shortcutCreated
                DefaultConfigured = $defaultConfigured
                ExecutablePath    = $exePath
                Status            = if ($installed) { 'OK' } else { 'WARN' }
            })
        }

        return $results.ToArray()
    }
}
