function Get-ToolkitInstalledApplication {
<#
.SYNOPSIS
    Discovers installation status, executable path, and version for standard enterprise applications.
.DESCRIPTION
    Checks standard 32-bit and 64-bit installation directories and registry uninstall keys
    for UniKey, UltraVNC, K-Lite Codec Pack, Google Chrome, Visual C++ Redistributable AIO, Foxit PDF Reader, Zalo, and WinRAR.
.PARAMETER AppName
    Target application name. Valid values: 'UniKey', 'UltraVNC', 'KLiteCodec', 'Chrome', 'VCRedistAIO', 'FoxitReader', 'Zalo', 'WinRAR', or 'All'. Default is 'All'.
.OUTPUTS
    [PSCustomObject[]] containing AppName, DisplayName, Installed, ExecutablePath, Version.
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0, ValueFromPipeline = $true)]
        [ValidateSet('UniKey', 'UltraVNC', 'KLiteCodec', 'Chrome', 'VCRedistAIO', 'FoxitReader', 'Zalo', 'WinRAR', 'All')]
        [string[]]$AppName = @('All')
    )

    process {
        if (-not (Get-Command -Name 'Write-AppInstallerLog' -ErrorAction SilentlyContinue)) {
            $privLog = Join-Path (Split-Path -Parent $PSScriptRoot) 'Private/Write-AppInstallerLog.ps1'
            if (Test-Path -LiteralPath $privLog) { . $privLog }
        }

        if (-not (Get-PSDrive -Name 'C' -Scope Global -ErrorAction SilentlyContinue)) {
            New-PSDrive -Name 'C' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -Scope Global -ErrorAction SilentlyContinue -WhatIf:$false | Out-Null
        }
        $progFiles = if ($env:ProgramFiles) { $env:ProgramFiles } else { 'C:\Program Files' }
        $progFilesX86 = if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)} } else { 'C:\Program Files (x86)' }
        $userProf = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { [System.IO.Path]::GetTempPath() }
        $localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $userProf 'AppData\Local' }

        $compareVersions = {
            param([string]$vA, [string]$vB)
            if ([string]::IsNullOrWhiteSpace($vA) -and [string]::IsNullOrWhiteSpace($vB)) { return 0 }
            if ([string]::IsNullOrWhiteSpace($vA)) { return -1 }
            if ([string]::IsNullOrWhiteSpace($vB)) { return 1 }
            $cleanA = ($vA -replace '^[^\d]*', '') -replace '[^\d.].*$', ''
            $cleanB = ($vB -replace '^[^\d]*', '') -replace '[^\d.].*$', ''
            $partsA = @($cleanA -split '\.' | ForEach-Object { if ($_ -match '^\d+$') { [long]$_ } else { 0 } })
            $partsB = @($cleanB -split '\.' | ForEach-Object { if ($_ -match '^\d+$') { [long]$_ } else { 0 } })
            $maxLen = [Math]::Max($partsA.Count, $partsB.Count)
            for ($i = 0; $i -lt $maxLen; $i++) {
                $segA = if ($i -lt $partsA.Count) { $partsA[$i] } else { 0 }
                $segB = if ($i -lt $partsB.Count) { $partsB[$i] } else { 0 }
                if ($segA -gt $segB) { return 1 }
                if ($segA -lt $segB) { return -1 }
            }
            return 0
        }

        $appCatalog = @{
            'UniKey' = @{
                DisplayName     = 'UniKey'
                ExeCandidates   = @(
                    (Join-Path $progFiles 'UniKey\UniKeyNT.exe'),
                    (Join-Path $progFilesX86 'UniKey\UniKeyNT.exe'),
                    (Join-Path $localAppData 'Programs\UniKey\UniKeyNT.exe'),
                    'C:\UniKey\UniKeyNT.exe'
                )
                RegistryPatterns = @('*UniKey*')
            }
            'UltraVNC' = @{
                DisplayName     = 'UltraVNC'
                ExeCandidates   = @(
                    (Join-Path $progFiles 'uvnc bvba\UltraVNC\vncviewer.exe'),
                    (Join-Path $progFilesX86 'uvnc bvba\UltraVNC\vncviewer.exe'),
                    (Join-Path $progFiles 'uvnc bvba\UltraVNC\winvnc.exe'),
                    (Join-Path $progFilesX86 'uvnc bvba\UltraVNC\winvnc.exe')
                )
                RegistryPatterns = @('*UltraVNC*')
            }
            'KLiteCodec' = @{
                DisplayName     = 'K-Lite Codec Pack'
                ExeCandidates   = @(
                    (Join-Path $progFilesX86 'K-Lite Codec Pack\MPC-HC64\mpc-hc64.exe'),
                    (Join-Path $progFiles 'K-Lite Codec Pack\MPC-HC64\mpc-hc64.exe'),
                    (Join-Path $progFilesX86 'K-Lite Codec Pack\MPC-HC\mpc-hc.exe'),
                    (Join-Path $progFilesX86 'K-Lite Codec Pack\Tools\CodecTweakTool.exe')
                )
                RegistryPatterns = @('*K-Lite Codec Pack*')
            }
            'Chrome' = @{
                DisplayName     = 'Google Chrome'
                ExeCandidates   = @(
                    (Join-Path $progFiles 'Google\Chrome\Application\chrome.exe'),
                    (Join-Path $progFilesX86 'Google\Chrome\Application\chrome.exe'),
                    (Join-Path $localAppData 'Google\Chrome\Application\chrome.exe')
                )
                RegistryPatterns = @('*Google Chrome*')
            }
            'VCRedistAIO' = @{
                DisplayName     = 'Visual C++ Redistributable AIO'
                ExeCandidates   = @() # System libraries, primarily detected via registry
                RegistryPatterns = @('*Microsoft Visual C++*')
            }
            'FoxitReader' = @{
                DisplayName     = 'Foxit PDF Reader'
                ExeCandidates   = @(
                    (Join-Path $progFiles 'Foxit Software\Foxit PDF Reader\FoxitPDFReader.exe'),
                    (Join-Path $progFilesX86 'Foxit Software\Foxit PDF Reader\FoxitPDFReader.exe'),
                    (Join-Path $progFiles 'Foxit Software\Foxit Reader\FoxitReader.exe'),
                    (Join-Path $progFilesX86 'Foxit Software\Foxit Reader\FoxitReader.exe')
                )
                RegistryPatterns = @('*Foxit*Reader*')
            }
            'Zalo' = @{
                DisplayName     = 'Zalo'
                ExeCandidates   = @(
                    (Join-Path $progFiles 'Zalo\Zalo.exe'),
                    (Join-Path $progFilesX86 'Zalo\Zalo.exe'),
                    (Join-Path $localAppData 'Programs\Zalo\Zalo.exe'),
                    (Join-Path $localAppData 'Zalo\Zalo.exe')
                )
                RegistryPatterns = @('*Zalo*')
            }
            'WinRAR' = @{
                DisplayName     = 'WinRAR'
                ExeCandidates   = @(
                    (Join-Path $progFiles 'WinRAR\WinRAR.exe'),
                    (Join-Path $progFilesX86 'WinRAR\WinRAR.exe')
                )
                RegistryPatterns = @('*WinRAR*')
            }
        }

        $targets = if ($AppName -contains 'All') {
            @('VCRedistAIO', 'UniKey', 'UltraVNC', 'KLiteCodec', 'Chrome', 'FoxitReader', 'Zalo', 'WinRAR')
        } else {
            @($AppName)
        }

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($target in $targets) {
            $def = $appCatalog[$target]
            $foundPath = $null
            $version = $null
            $installed = $false

            Write-AppInstallerLog -Message "Detecting installation status for $($def.DisplayName) ($target)..." -Level 'DEBUG' -Component 'Get-ToolkitInstalledApplication'

            # Check candidate executable paths
            foreach ($candidate in $def.ExeCandidates) {
                if (Test-Path -LiteralPath $candidate -ErrorAction SilentlyContinue) {
                    $foundPath = $candidate
                    $installed = $true
                    try {
                        $verInfo = (Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue).VersionInfo
                        if ($verInfo) {
                            $candVer = $null
                            $pv = if (-not [string]::IsNullOrWhiteSpace($verInfo.ProductVersion) -and (($verInfo.ProductVersion.Trim() -replace '^[0\.]+$', '') -ne '')) { $verInfo.ProductVersion.Trim() } else { $null }
                            $fv = if (-not [string]::IsNullOrWhiteSpace($verInfo.FileVersion) -and (($verInfo.FileVersion.Trim() -replace '^[0\.]+$', '') -ne '')) { $verInfo.FileVersion.Trim() } else { $null }
                            $candVer = if ($pv -and $fv) {
                                if ((& $compareVersions $fv $pv) -gt 0) { $fv } else { $pv }
                            } elseif ($pv) {
                                $pv
                            } else {
                                $fv
                            }
                            if ($candVer) {
                                $version = $candVer
                            }
                        }
                    } catch {
                        $null = $_
                    }
                    Write-AppInstallerLog -Message "Found $($def.DisplayName) executable at '$foundPath' (Version: $version)." -Level 'DEBUG' -Component 'Get-ToolkitInstalledApplication'
                    break
                }
            }

            # Inspect version-specific subdirectories for Zalo (e.g. %LOCALAPPDATA%\Programs\Zalo\Zalo-*)
            if ($target -eq 'Zalo') {
                $candidateZaloDirs = [System.Collections.Generic.List[string]]::new()
                if ($foundPath) {
                    $parentDir = Split-Path -Parent $foundPath
                    if ($parentDir -and -not $candidateZaloDirs.Contains($parentDir)) {
                        $candidateZaloDirs.Add($parentDir)
                    }
                }
                $defaultZaloBaseDirs = @(
                    (Join-Path $localAppData 'Programs\Zalo'),
                    (Join-Path $localAppData 'Zalo'),
                    (Join-Path $progFiles 'Zalo'),
                    (Join-Path $progFilesX86 'Zalo')
                )
                foreach ($baseDir in $defaultZaloBaseDirs) {
                    if (-not $candidateZaloDirs.Contains($baseDir)) {
                        $candidateZaloDirs.Add($baseDir)
                    }
                }

                foreach ($zBase in $candidateZaloDirs) {
                    if (Test-Path -LiteralPath $zBase -ErrorAction SilentlyContinue) {
                        try {
                            $versionSubDirs = Get-ChildItem -Path $zBase -Directory -Filter 'Zalo-*' -ErrorAction SilentlyContinue
                            if ($versionSubDirs) {
                                # Sort by parsed semantic version descending first, then LastWriteTime descending
                                $sortedVersionDirs = $versionSubDirs | Sort-Object -Property @(
                                    @{
                                        Expression = {
                                            if ($_.Name -match '^Zalo-([0-9]+(\.[0-9]+){1,3})') {
                                                try { return [version]$Matches[1] } catch { return [version]'0.0.0.0' }
                                            }
                                            return [version]'0.0.0.0'
                                        }
                                        Descending = $true
                                    },
                                    @{
                                        Expression = { $_.LastWriteTime }
                                        Descending = $true
                                    }
                                )
                                foreach ($vDir in $sortedVersionDirs) {
                                    $subExePath = Join-Path $vDir.FullName 'Zalo.exe'
                                    $extractedVer = $null
                                    if (Test-Path -LiteralPath $subExePath -ErrorAction SilentlyContinue) {
                                        if (-not $foundPath) {
                                            $foundPath = $subExePath
                                            $installed = $true
                                        }
                                        try {
                                            $subItem = (Get-Item -LiteralPath $subExePath -ErrorAction SilentlyContinue).VersionInfo
                                             if ($subItem) {
                                                $subPv = if (-not [string]::IsNullOrWhiteSpace($subItem.ProductVersion) -and (($subItem.ProductVersion.Trim() -replace '^[0\.]+$', '') -ne '')) { $subItem.ProductVersion.Trim() } else { $null }
                                                $subFv = if (-not [string]::IsNullOrWhiteSpace($subItem.FileVersion) -and (($subItem.FileVersion.Trim() -replace '^[0\.]+$', '') -ne '')) { $subItem.FileVersion.Trim() } else { $null }
                                                $extractedVer = if ($subPv -and $subFv) {
                                                    if ((& $compareVersions $subFv $subPv) -gt 0) { $subFv } else { $subPv }
                                                } elseif ($subPv) {
                                                    $subPv
                                                } else {
                                                    $subFv
                                                }
                                            }
                                        } catch {
                                            $null = $_
                                        }
                                    }
                                    if (([string]::IsNullOrWhiteSpace($extractedVer) -or ($extractedVer -replace '^[0\.]+$', '') -eq '') -and ($vDir.Name -match '^Zalo-([0-9]+(\.[0-9]+)+)')) {
                                        $extractedVer = $Matches[1].Trim()
                                    }
                                    if (-not [string]::IsNullOrWhiteSpace($extractedVer) -and (($extractedVer -replace '^[0\.]+$', '') -ne '')) {
                                        if (-not $foundPath) {
                                            $foundPath = if (Test-Path -LiteralPath $subExePath -ErrorAction SilentlyContinue) { $subExePath } else { $vDir.FullName }
                                            $installed = $true
                                        }
                                        # Active version subdirectory takes precedence over launcher stub
                                        $version = $extractedVer
                                        break
                                    }
                                }
                            }
                        } catch {
                            $null = $_
                        }
                    }
                    if ($installed -and -not [string]::IsNullOrWhiteSpace($version)) {
                        break
                    }
                }
            }

            # Check registry uninstall keys (authoritative for Zalo DisplayVersion, or fallback if executable/version not found)
            $queryRegistry = (-not $installed) -or ($target -eq 'Zalo') -or [string]::IsNullOrWhiteSpace($version)
            if ($queryRegistry) {
                $regPaths = @(
                    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
                )
                foreach ($pattern in $def.RegistryPatterns) {
                    foreach ($regPath in $regPaths) {
                        try {
                            $rawMatches = @(Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue |
                                Where-Object { ($_.DisplayName -like $pattern) -or ($_.PSChildName -like $pattern) })
                            if ($rawMatches.Count -gt 0) {
                                $matchWithVer = @($rawMatches | Where-Object {
                                    (-not [string]::IsNullOrWhiteSpace($_.DisplayVersion)) -and (($_.DisplayVersion.ToString().Trim() -replace '^[0\.]+$', '') -ne '')
                                })
                                $targetPool = if ($matchWithVer.Count -gt 0) { $matchWithVer } else { $rawMatches }
                                $match = $targetPool | Sort-Object -Property @(
                                    @{
                                        Expression = {
                                            $dn = if ($_.DisplayName) { [string]$_.DisplayName } else { '' }
                                            $cn = if ($_.PSChildName) { [string]$_.PSChildName } else { '' }
                                            if ($dn -in @('Zalo', 'Zalo PC') -or $cn -in @('Zalo', 'Zalo PC')) { 2 }
                                            elseif ($dn -notmatch '(?i)crash|report|update|helper|plugin') { 1 }
                                            else { 0 }
                                        }
                                        Descending = $true
                                    },
                                    @{
                                        Expression = {
                                            $verStr = [string]$_.DisplayVersion
                                            if ($verStr -match '^([0-9]+(\.[0-9]+){1,3})') {
                                                try { return [version]$Matches[1] } catch { return [version]'0.0.0.0' }
                                            }
                                            return [version]'0.0.0.0'
                                        }
                                        Descending = $true
                                    }
                                ) | Select-Object -First 1

                                $regVer = $null
                                if (-not [string]::IsNullOrWhiteSpace($match.DisplayVersion)) {
                                    $trimmedVer = [string]$match.DisplayVersion.Trim()
                                    if (($trimmedVer -replace '^[0\.]+$', '') -ne '') {
                                        $regVer = $trimmedVer
                                    }
                                }

                                if ($regVer) {
                                    if ($target -eq 'Zalo') {
                                        # Prefer the newer/higher version between active directory and registry
                                        if ([string]::IsNullOrWhiteSpace($version) -or ((& $compareVersions $regVer $version) -gt 0)) {
                                            $version = $regVer
                                        }
                                    } elseif ([string]::IsNullOrWhiteSpace($version)) {
                                        $version = $regVer
                                    }
                                }
                                if ($match.InstallLocation -and -not $foundPath) {
                                    $locDir = ([string]$match.InstallLocation).Trim('"', ' ', "`t").TrimEnd('\', '/')
                                    $resolvedExe = $null
                                    if ($def.ExeCandidates -and $def.ExeCandidates.Count -gt 0) {
                                        foreach ($candLeaf in ($def.ExeCandidates | ForEach-Object { Split-Path -Leaf $_ } | Select-Object -Unique)) {
                                            $candFile = Join-Path $locDir $candLeaf
                                            if (Test-Path -LiteralPath $candFile -ErrorAction SilentlyContinue) {
                                                $resolvedExe = $candFile
                                                break
                                            }
                                        }
                                    }
                                    $foundPath = if ($resolvedExe) { $resolvedExe } else { $locDir }
                                }
                                if (-not $foundPath -and $match.DisplayIcon) {
                                    $iconCandidate = ($match.DisplayIcon -split ',')[0].Trim('"', ' ')
                                    if ($iconCandidate -and (Test-Path -LiteralPath $iconCandidate -ErrorAction SilentlyContinue)) {
                                        $foundPath = $iconCandidate
                                    }
                                }
                                if ($regVer -or $foundPath -or $match.UninstallString -or ($target -eq 'VCRedistAIO')) {
                                    $installed = $true
                                }
                                Write-AppInstallerLog -Message "Found $($def.DisplayName) in uninstall registry: $($match.DisplayName) (Version: $version)." -Level 'DEBUG' -Component 'Get-ToolkitInstalledApplication'
                                if ($target -ne 'Zalo' -and ($regVer -or $installed)) {
                                    break
                                }
                            }
                        } catch {
                            $null = $_
                        }
                    }
                    if ($installed -and ($target -ne 'Zalo')) { break }
                }
            }

            $statusText = if ($installed) { "Installed (Path: $foundPath, Version: $version)" } else { "Not Installed" }
            Write-AppInstallerLog -Message "Status for $($def.DisplayName): $statusText." -Level 'DEBUG' -Component 'Get-ToolkitInstalledApplication'

            $results.Add([PSCustomObject]@{
                AppName        = $target
                DisplayName    = $def.DisplayName
                Installed      = $installed
                ExecutablePath = $foundPath
                Version        = $version
            })
        }

        return $results.ToArray()
    }
}
