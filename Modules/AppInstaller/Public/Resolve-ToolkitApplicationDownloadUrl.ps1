function Resolve-ToolkitApplicationDownloadUrl {
<#
.SYNOPSIS
    Dynamically resolves the latest official download URLs for catalog applications.
.DESCRIPTION
    Dynamically queries official endpoints (unikey.org, zalo.me redirect) with short
    timeouts (4s) and architecture detection, falling back gracefully to known stable URLs.
.PARAMETER AppName
    Target application name ('UniKey', 'Zalo', 'Chrome', 'FoxitReader', 'VCRedistAIO', 'UltraVNC', 'KLiteCodec').
.PARAMETER Architecture
    Optional architecture override ('win64', 'win32', 'arm64').
.OUTPUTS
    [PSCustomObject] containing AppName, PrimaryUrl, FallbackUrls, ResolvedDynamically, DetectedArchitecture.
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateSet('UniKey', 'Zalo', 'Chrome', 'FoxitReader', 'VCRedistAIO', 'UltraVNC', 'KLiteCodec')]
        [string]$AppName,

        [Parameter(Mandatory = $false)]
        [string]$Architecture
    )

    process {
        # Detect host architecture
        $arch = $Architecture
        if ([string]::IsNullOrWhiteSpace($arch)) {
            $rawArch = if ($env:PROCESSOR_ARCHITEW6432) {
                $env:PROCESSOR_ARCHITEW6432.ToLowerInvariant()
            } elseif ($env:PROCESSOR_ARCHITECTURE) {
                $env:PROCESSOR_ARCHITECTURE.ToLowerInvariant()
            } else {
                [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
            }
            $arch = switch -Wildcard ($rawArch) {
                '*arm64*' { 'arm64' }
                '*x86*'   { 'win32' }
                default   { 'win64' }
            }
        }

        $resolvedDynamically = $false
        $primaryUrl = $null
        $fallbacks = [System.Collections.Generic.List[string]]::new()

        switch ($AppName) {
            'UniKey' {
                # Known stable fallbacks (UniKey 4.6 RC2)
                $stableUrls = @{
                    'win64' = 'https://www.unikey.org/assets/release/unikey46RC2-230919-win64.zip'
                    'win32' = 'https://www.unikey.org/assets/release/unikey46RC2-230919-win32.zip'
                    'arm64' = 'https://www.unikey.org/assets/release/unikey46RC2-250531-arm64.zip'
                }

                # Attempt dynamic discovery from unikey.org/assets/release/ directory listing
                $handler = $null
                $client = $null
                try {
                    $handler = [System.Net.Http.HttpClientHandler]::new()
                    $client = [System.Net.Http.HttpClient]::new($handler)
                    $client.Timeout = [System.TimeSpan]::FromSeconds(4)
                    $client.DefaultRequestHeaders.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)')
                    $html = $client.GetStringAsync('https://www.unikey.org/assets/release/').GetAwaiter().GetResult()
                    $regex = '(?i)(unikey[0-9A-Za-z_-]+-(?:win64|win32|arm64)\.zip)'
                    $matches = [regex]::Matches($html, $regex)
                    $archMatches = [System.Collections.Generic.List[string]]::new()
                    foreach ($m in $matches) {
                        $fName = $m.Value
                        if ($fName -like "*-$arch.zip" -and -not $archMatches.Contains($fName)) {
                            $archMatches.Add($fName)
                        }
                    }
                    if ($archMatches.Count -gt 0) {
                        $archMatches.Sort()
                        $latest = $archMatches[$archMatches.Count - 1]
                        $primaryUrl = "https://www.unikey.org/assets/release/$latest"
                        $resolvedDynamically = $true
                    }
                } catch {
                    # Offline / restricted / timeout - fall back gracefully
                    $resolvedDynamically = $false
                } finally {
                    if ($null -ne $client) { $client.Dispose() }
                    if ($null -ne $handler) { $handler.Dispose() }
                }

                if (-not $primaryUrl) {
                    $primaryUrl = $stableUrls[$arch]
                    if (-not $primaryUrl) {
                        $primaryUrl = $stableUrls['win64']
                    }
                }

                # Add alternate architecture stable URLs as fallbacks
                foreach ($k in @('win64', 'win32', 'arm64')) {
                    $u = $stableUrls[$k]
                    if ($u -ne $primaryUrl -and -not $fallbacks.Contains($u)) {
                        $fallbacks.Add($u)
                    }
                }
            }

            'Zalo' {
                $knownStable = @(
                    'https://res-download-pc.zadn.vn/win/ZaloSetup-26.10.10.exe',
                    'https://res-zaloapp-aka-jpt.zdn.vn/win/ZaloSetup-26.10.10.exe'
                )

                # Attempt dynamic discovery by inspecting official redirect endpoint
                $handler = $null
                $client = $null
                $resp = $null
                try {
                    $handler = [System.Net.Http.HttpClientHandler]::new()
                    $handler.AllowAutoRedirect = $false
                    $client = [System.Net.Http.HttpClient]::new($handler)
                    $client.Timeout = [System.TimeSpan]::FromSeconds(4)
                    $client.DefaultRequestHeaders.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)')
                    $resp = $client.GetAsync('https://zalo.me/download/zalo-pc').GetAwaiter().GetResult()
                    if ($resp -and $resp.Headers.Location) {
                        $targetUri = if ($resp.Headers.Location.IsAbsoluteUri) {
                            $resp.Headers.Location
                        } else {
                            [System.Uri]::new([System.Uri]::new('https://zalo.me/'), $resp.Headers.Location)
                        }
                        $loc = $targetUri.AbsoluteUri
                        if ($loc -and $loc.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
                            $primaryUrl = $loc
                            $resolvedDynamically = $true
                        }
                    }
                } catch {
                    $resolvedDynamically = $false
                } finally {
                    if ($null -ne $resp) { $resp.Dispose() }
                    if ($null -ne $client) { $client.Dispose() }
                    if ($null -ne $handler) { $handler.Dispose() }
                }

                if (-not $primaryUrl) {
                    $primaryUrl = $knownStable[0]
                }

                foreach ($u in $knownStable) {
                    if ($u -ne $primaryUrl -and -not $fallbacks.Contains($u)) {
                        $fallbacks.Add($u)
                    }
                }
            }

            'Chrome' {
                $primaryUrl = 'https://dl.google.com/chrome/install/latest/chrome_installer.exe'
                $resolvedDynamically = $true
            }

            'VCRedistAIO' {
                $primaryUrl = 'https://github.com/abbodi1406/vcredist/releases/latest/download/VisualCppRedist_AIO_x86_x64.exe'
                $resolvedDynamically = $true
            }

            'FoxitReader' {
                $primaryUrl = 'https://cdn01.foxitsoftware.com/product/reader/desktop/win/latest/FoxitPDFReader_Setup.exe'
                $resolvedDynamically = $true
            }

            'UltraVNC' {
                $primaryUrl = $null
                $resolvedDynamically = $false
            }

            'KLiteCodec' {
                $primaryUrl = $null
                $resolvedDynamically = $false
            }
        }

        return [PSCustomObject]@{
            AppName              = $AppName
            PrimaryUrl           = $primaryUrl
            FallbackUrls         = $fallbacks.ToArray()
            ResolvedDynamically  = $resolvedDynamically
            DetectedArchitecture = $arch
        }
    }
}

if (Get-Command -Name 'Resolve-ToolkitApplicationDownloadUrl' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Resolve-ToolkitApplicationDownloadUrl' -Value (Get-Command -Name 'Resolve-ToolkitApplicationDownloadUrl').ScriptBlock
}
