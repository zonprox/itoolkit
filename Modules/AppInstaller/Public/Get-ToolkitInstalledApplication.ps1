function Get-ToolkitInstalledApplication {
<#
.SYNOPSIS
    Discovers installation status, executable path, and version for standard enterprise applications.
.DESCRIPTION
    Checks standard 32-bit and 64-bit installation directories and registry uninstall keys
    for UniKey, UltraVNC, K-Lite Codec Pack, Google Chrome, Visual C++ Redistributable AIO, and Foxit Reader.
.PARAMETER AppName
    Target application name. Valid values: 'UniKey', 'UltraVNC', 'KLiteCodec', 'Chrome', 'VCRedistAIO', 'FoxitReader', or 'All'. Default is 'All'.
.OUTPUTS
    [PSCustomObject[]] containing AppName, DisplayName, Installed, ExecutablePath, Version.
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('UniKey', 'UltraVNC', 'KLiteCodec', 'Chrome', 'VCRedistAIO', 'FoxitReader', 'All')]
        [string]$AppName = 'All'
    )

    process {
        if (-not (Get-PSDrive -Name 'C' -ErrorAction SilentlyContinue)) {
            New-PSDrive -Name 'C' -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) -ErrorAction SilentlyContinue -WhatIf:$false | Out-Null
        }
        $progFiles = if ($env:ProgramFiles) { $env:ProgramFiles } else { 'C:\Program Files' }
        $progFilesX86 = if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)} } else { 'C:\Program Files (x86)' }
        $userProf = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { [System.IO.Path]::GetTempPath() }
        $localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $userProf 'AppData\Local' }

        $appCatalog = @{
            'UniKey' = @{
                DisplayName     = 'UniKey Vietnamese Input Method'
                ExeCandidates   = @(
                    (Join-Path $progFiles 'UniKey\UniKeyNT.exe'),
                    (Join-Path $progFilesX86 'UniKey\UniKeyNT.exe'),
                    (Join-Path $localAppData 'Programs\UniKey\UniKeyNT.exe'),
                    'C:\UniKey\UniKeyNT.exe'
                )
                RegistryPatterns = @('*UniKey*')
            }
            'UltraVNC' = @{
                DisplayName     = 'UltraVNC Remote Support'
                ExeCandidates   = @(
                    (Join-Path $progFiles 'uvnc bvba\UltraVNC\vncviewer.exe'),
                    (Join-Path $progFilesX86 'uvnc bvba\UltraVNC\vncviewer.exe'),
                    (Join-Path $progFiles 'uvnc bvba\UltraVNC\winvnc.exe'),
                    (Join-Path $progFilesX86 'uvnc bvba\UltraVNC\winvnc.exe')
                )
                RegistryPatterns = @('*UltraVNC*')
            }
            'KLiteCodec' = @{
                DisplayName     = 'K-Lite Codec Pack & MPC-HC'
                ExeCandidates   = @(
                    (Join-Path $progFilesX86 'K-Lite Codec Pack\MPC-HC64\mpc-hc64.exe'),
                    (Join-Path $progFiles 'K-Lite Codec Pack\MPC-HC64\mpc-hc64.exe'),
                    (Join-Path $progFilesX86 'K-Lite Codec Pack\MPC-HC\mpc-hc.exe'),
                    (Join-Path $progFilesX86 'K-Lite Codec Pack\Tools\CodecTweakTool.exe')
                )
                RegistryPatterns = @('*K-Lite Codec Pack*')
            }
            'Chrome' = @{
                DisplayName     = 'Google Chrome Browser'
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
        }

        $targets = if ($AppName -eq 'All') {
            @('UniKey', 'UltraVNC', 'KLiteCodec', 'Chrome', 'VCRedistAIO', 'FoxitReader')
        } else {
            @($AppName)
        }

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($target in $targets) {
            $def = $appCatalog[$target]
            $foundPath = $null
            $version = $null
            $installed = $false

            # Check candidate executable paths
            foreach ($candidate in $def.ExeCandidates) {
                if (Test-Path -LiteralPath $candidate -ErrorAction SilentlyContinue) {
                    $foundPath = $candidate
                    $installed = $true
                    try {
                        $verInfo = (Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue).VersionInfo
                        if ($verInfo -and $verInfo.ProductVersion) {
                            $version = $verInfo.ProductVersion
                        }
                    } catch {
                        $null = $_
                    }
                    break
                }
            }

            # Check registry if executable not found (or for VCRedistAIO)
            if (-not $installed -and (Test-Path -LiteralPath 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue)) {
                $regPaths = @(
                    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
                )
                foreach ($pattern in $def.RegistryPatterns) {
                    foreach ($regPath in $regPaths) {
                        try {
                            $match = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue |
                                Where-Object { $_.DisplayName -like $pattern } |
                                Select-Object -First 1
                            if ($match) {
                                $installed = $true
                                if ($match.DisplayVersion) { $version = $match.DisplayVersion }
                                if ($match.InstallLocation -and -not $foundPath) { $foundPath = $match.InstallLocation }
                                break
                            }
                        } catch {
                            $null = $_
                        }
                    }
                    if ($installed) { break }
                }
            }

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
