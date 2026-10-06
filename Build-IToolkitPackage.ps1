<#
.SYNOPSIS
    Builds a clean, standalone, production-ready IToolkit.zip package and optionally
    uploads it to public cloud file hosting.

.DESCRIPTION
    Build-IToolkitPackage.ps1 is an external dev/release packaging tool for IToolkit.
    It stages all production runtime files (Root manifests, launchers, documentation,
    and all production modules under Modules/) into an isolated temporary directory,
    validates that zero dev/test artifacts (.git, .agents, Tests, Logs, Backups, dev configs)
    are included, packages the contents into IToolkit.zip, computes SHA-256 checksums,
    and optionally uploads to public hosting services (uguu.se / tmpfiles.org).

.PARAMETER DestinationPath
    Destination file path for the output archive.
    Defaults to "$PSScriptRoot/IToolkit.zip".

.PARAMETER Upload
    Switch to immediately upload the packaged archive to public cloud file hosting.

.PARAMETER SkipUpload
    Switch to explicitly skip uploading the package to public cloud file hosting.
    If specified, disables upload even if -Upload was also passed.

.PARAMETER Provider
    Public upload provider to use. Valid choices: 'auto', 'onlyfiles', 'uguu', 'tmpfiles'.
    Defaults to 'auto' (tries onlyfiles.com first, then uguu.se, falls back to tmpfiles.org).

.PARAMETER Force
    Forces overwriting of any existing archive file at DestinationPath.

.OUTPUTS
    [PSCustomObject] Containing Path, SizeBytes, SHA256, EntriesCount, DownloadUrl, and Success.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]$DestinationPath,

    [Parameter(Mandatory = $false)]
    [switch]$Upload,

    [Parameter(Mandatory = $false)]
    [switch]$SkipUpload,

    [Parameter(Mandatory = $false)]
    [ValidateSet('auto', 'onlyfiles', 'uguu', 'tmpfiles')]
    [string]$Provider = 'auto',

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Handle SkipUpload override
if ($SkipUpload) {
    $Upload = [switch]$false
}

# 1. Resolve Project Root
$ProjectRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($ProjectRoot)) {
    if ($null -ne $MyInvocation.MyCommand.Path) {
        $ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    } elseif ($null -ne $MyInvocation.MyCommand.Definition) {
        $ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
    } else {
        $ProjectRoot = (Get-Location).ProviderPath
    }
}

# Walk upwards if needed to locate repository root containing IToolkit.psd1
$searchDir = $ProjectRoot
while (-not [string]::IsNullOrEmpty($searchDir) -and -not (Test-Path -LiteralPath (Join-Path -Path $searchDir -ChildPath 'IToolkit.psd1'))) {
    $parentDir = Split-Path -Parent $searchDir
    if ($parentDir -eq $searchDir -or [string]::IsNullOrEmpty($parentDir)) {
        break
    }
    $searchDir = $parentDir
}
if (Test-Path -LiteralPath (Join-Path -Path $searchDir -ChildPath 'IToolkit.psd1')) {
    $ProjectRoot = $searchDir
}

# 2. Determine and resolve DestinationPath
if ([string]::IsNullOrEmpty($DestinationPath)) {
    $zipPath = Join-Path -Path $ProjectRoot -ChildPath 'IToolkit.zip'
} else {
    $zipPath = [System.IO.Path]::GetFullPath($DestinationPath)
}

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "                   IToolkit Standalone Distribution Packaging                   " -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "  Project Root     : $ProjectRoot"
Write-Host "  Destination Path : $zipPath"
Write-Host "  Upload Requested : $(if ($Upload) { 'Yes' } else { 'No' })"
Write-Host "================================================================================"

# Evaluate ShouldProcess for WhatIf / Dry-Run simulation
if (-not $PSCmdlet.ShouldProcess($zipPath, 'Create standalone IToolkit package')) {
    return
}

# Handle existing zip file
if (Test-Path -LiteralPath $zipPath) {
    if (-not $Force) {
        throw "Target archive already exists at '$zipPath'. Use -Force to overwrite."
    }
    Write-Host "Removing existing archive: $zipPath" -ForegroundColor Yellow
    Remove-Item -LiteralPath $zipPath -Force
}

# 3. Create isolated staging workspace
$uniqueId = [System.Guid]::NewGuid().ToString('N')
$tempStageDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("IToolkit_PkgStage_" + $uniqueId)
$targetStageRoot = Join-Path -Path $tempStageDir -ChildPath 'Content'

try {
    New-Item -ItemType Directory -Path $targetStageRoot -Force | Out-Null

    # 4. Whitelist copy of production files
    Write-Host "[1/4] Staging production runtime files..." -ForegroundColor Green

    # Root module manifests and loaders
    $rootFiles = @('IToolkit.psd1', 'IToolkit.psm1', 'Start-IToolkit.ps1', 'Run-IToolkit.bat', 'README.md')
    foreach ($file in $rootFiles) {
        $sourceFile = Join-Path -Path $ProjectRoot -ChildPath $file
        if (Test-Path -LiteralPath $sourceFile) {
            Copy-Item -LiteralPath $sourceFile -Destination $targetStageRoot -Force
            Write-Host "  + Staged root file: $file" -ForegroundColor DarkGray
        } else {
            if ($file -match '\.(psd1|psm1)$') {
                throw "Required production file missing: $file"
            }
        }
    }

    # Production Modules
    $modulesSource = Join-Path -Path $ProjectRoot -ChildPath 'Modules'
    $modulesDest = Join-Path -Path $targetStageRoot -ChildPath 'Modules'
    New-Item -ItemType Directory -Path $modulesDest -Force | Out-Null

    $productionModuleNames = @(
        'Core',
        'Outlook',
        'Office',
        'Printers',
        'Backup',
        'Accounts',
        'ExternalTools',
        'TUI'
    )

    foreach ($mod in $productionModuleNames) {
        $srcModDir = Join-Path -Path $modulesSource -ChildPath $mod
        if (Test-Path -LiteralPath $srcModDir) {
            $destModDir = Join-Path -Path $modulesDest -ChildPath $mod
            Copy-Item -Path $srcModDir -Destination $destModDir -Recurse -Force
            Write-Host "  + Staged module: Modules/$mod" -ForegroundColor DarkGray
        } else {
            Write-Warning "Optional module directory not present during packaging: Modules/$mod"
        }
    }

    # 5. Sanitize Staging Directory (purge accidental dev/temp files)
    Write-Host "[2/4] Sanitizing staged package contents..." -ForegroundColor Green
    $stagedItems = Get-ChildItem -Path $targetStageRoot -Recurse -Force

    $prohibitedRegex = '(?i)[\\/](?:\.git|\.agents|\.codebase-memory|Tests|Build|scripts|Logs|Backups|\.idea|\.vscode|\.claude|\.gemini|\.cursor|\.windsurf|\.antigravity|scratch)(?:[\\/]|$)'
    $prohibitedFileRegex = '(?i)\.(?:log|tmp|temp|bak|orig|swp|clixml)$|^RegistryBackup_.*\.reg$|^\.DS_Store$|^Thumbs\.db$|^desktop\.ini$'

    foreach ($item in $stagedItems) {
        if ($item.FullName -match $prohibitedRegex -or $item.Name -match $prohibitedFileRegex) {
            Write-Host "  - Removing disallowed item from staging: $($item.FullName)" -ForegroundColor Yellow
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Verify zero dev leaks
    $verificationItems = Get-ChildItem -Path $targetStageRoot -Recurse -Force
    foreach ($v in $verificationItems) {
        if ($v.FullName -match $prohibitedRegex) {
            throw "Security assertion failed: Prohibited development path found in package staging: $($v.FullName)"
        }
    }

    # 6. Compress staging contents into IToolkit.zip
    Write-Host "[3/4] Compressing archive into $zipPath..." -ForegroundColor Green

    # Ensure parent directory of zip exists
    $zipParent = Split-Path -Parent $zipPath
    if (-not [string]::IsNullOrEmpty($zipParent) -and -not (Test-Path -LiteralPath $zipParent)) {
        New-Item -ItemType Directory -Path $zipParent -Force | Out-Null
    }

    # Load System.IO.Compression.FileSystem for PS 5.1 compatibility
    try {
        Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
    } catch {
        Write-Verbose "Assembly load note: $($_.Exception.Message)"
    }

    [System.IO.Compression.ZipFile]::CreateFromDirectory($targetStageRoot, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)

    if (-not (Test-Path -LiteralPath $zipPath)) {
        throw "Failed to create archive at '$zipPath'."
    }

    # Validate archive readability and entry count
    $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    $entryCount = $zipArchive.Entries.Count
    $zipArchive.Dispose()

    if ($entryCount -le 0) {
        throw "Created archive is invalid or empty (0 entries)."
    }

    # Calculate metrics
    $fileInfo = Get-Item -LiteralPath $zipPath
    $fileSizeBytes = $fileInfo.Length
    $fileSizeKB = [math]::Round($fileSizeBytes / 1024, 2)
    $hashObj = Get-FileHash -LiteralPath $zipPath -Algorithm SHA256
    $sha256Hash = $hashObj.Hash

    Write-Host "  -> Archive created: $zipPath ($fileSizeKB KB, $entryCount files)" -ForegroundColor Green
    Write-Host "  -> SHA-256 Checksum : $sha256Hash" -ForegroundColor Cyan

    # 7. Optional Public Upload Automation
    $downloadUrl = $null
    if ($Upload) {
        Write-Host "[4/4] Uploading to public cloud file host..." -ForegroundColor Green

        # Helper function for OnlyFiles.com upload (https://onlyfiles.com/api)
        $tryOnlyFiles = {
            param([string]$FilePath)
            try {
                $curl = Get-Command -Name 'curl.exe' -ErrorAction SilentlyContinue
                if ($null -eq $curl) {
                    $curl = Get-Command -Name 'curl' -ErrorAction SilentlyContinue
                }
                if ($null -ne $curl) {
                    $raw = & $curl.Source -s -F "file=@$FilePath" -F "expire=0" "https://api.onlyfiles.com/v1/upload"
                    if ($raw) {
                        $rawStr = ($raw -join "`n")
                        $json = ConvertFrom-Json -InputObject $rawStr -ErrorAction SilentlyContinue
                        if ($null -ne $json -and $json.status -and $null -ne $json.data -and $null -ne $json.data.file) {
                            if ($null -ne $json.data.file.url -and -not [string]::IsNullOrEmpty($json.data.file.url.full)) {
                                return [string]$json.data.file.url.full
                            }
                            if ($null -ne $json.data.file.url -and -not [string]::IsNullOrEmpty($json.data.file.url.short)) {
                                return [string]$json.data.file.url.short
                            }
                        }
                    }
                }

                # Fallback to System.Net.Http.HttpClient
                Add-Type -AssemblyName 'System.Net.Http' -ErrorAction SilentlyContinue
                $client = [System.Net.Http.HttpClient]::new()
                try {
                    $content = [System.Net.Http.MultipartFormDataContent]::new()
                    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
                    $byteContent = [System.Net.Http.ByteArrayContent]::new($bytes)
                    $byteContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/zip')
                    $content.Add($byteContent, 'file', [System.IO.Path]::GetFileName($FilePath))
                    $expireContent = [System.Net.Http.StringContent]::new('0')
                    $content.Add($expireContent, 'expire')
                    $response = $client.PostAsync('https://api.onlyfiles.com/v1/upload', $content).GetAwaiter().GetResult()
                    if ($response.IsSuccessStatusCode) {
                        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                        $json = ConvertFrom-Json -InputObject $body -ErrorAction SilentlyContinue
                        if ($null -ne $json -and $json.status -and $null -ne $json.data -and $null -ne $json.data.file) {
                            if ($null -ne $json.data.file.url -and -not [string]::IsNullOrEmpty($json.data.file.url.full)) {
                                return [string]$json.data.file.url.full
                            }
                            if ($null -ne $json.data.file.url -and -not [string]::IsNullOrEmpty($json.data.file.url.short)) {
                                return [string]$json.data.file.url.short
                            }
                        }
                    }
                } finally {
                    $client.Dispose()
                }
            } catch {
                $null = $_
                Write-Verbose "OnlyFiles upload failed: $($_.Exception.Message)"
            }
            return $null
        }

        # Helper function for Uguu.se upload
        $tryUguu = {
            param([string]$FilePath)
            try {
                $curl = Get-Command -Name 'curl.exe' -ErrorAction SilentlyContinue
                if ($null -eq $curl) {
                    $curl = Get-Command -Name 'curl' -ErrorAction SilentlyContinue
                }
                if ($null -ne $curl) {
                    $raw = & $curl.Source -s -F "files[]=@$FilePath" "https://uguu.se/upload.php"
                    if ($raw) {
                        $rawStr = ($raw -join "`n")
                        $json = ConvertFrom-Json -InputObject $rawStr -ErrorAction SilentlyContinue
                        if ($null -ne $json -and $json.success -and $json.files.Count -gt 0) {
                            return [string]$json.files[0].url
                        }
                    }
                }

                # Fallback to System.Net.Http.HttpClient
                Add-Type -AssemblyName 'System.Net.Http' -ErrorAction SilentlyContinue
                $client = [System.Net.Http.HttpClient]::new()
                try {
                    $content = [System.Net.Http.MultipartFormDataContent]::new()
                    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
                    $byteContent = [System.Net.Http.ByteArrayContent]::new($bytes)
                    $byteContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/zip')
                    $content.Add($byteContent, 'files[]', [System.IO.Path]::GetFileName($FilePath))
                    $response = $client.PostAsync('https://uguu.se/upload.php', $content).GetAwaiter().GetResult()
                    if ($response.IsSuccessStatusCode) {
                        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                        $json = ConvertFrom-Json -InputObject $body -ErrorAction SilentlyContinue
                        if ($null -ne $json -and $json.success -and $json.files.Count -gt 0) {
                            return [string]$json.files[0].url
                        }
                    }
                } finally {
                    $client.Dispose()
                }
            } catch {
                $null = $_
                Write-Verbose "Uguu upload failed: $($_.Exception.Message)"
            }
            return $null
        }

        # Helper function for Tmpfiles.org upload
        $tryTmpfiles = {
            param([string]$FilePath)
            try {
                $curl = Get-Command -Name 'curl.exe' -ErrorAction SilentlyContinue
                if ($null -eq $curl) {
                    $curl = Get-Command -Name 'curl' -ErrorAction SilentlyContinue
                }
                if ($null -ne $curl) {
                    $raw = & $curl.Source -s -F "file=@$FilePath" "https://tmpfiles.org/api/v1/upload"
                    if ($raw) {
                        $rawStr = ($raw -join "`n")
                        $json = ConvertFrom-Json -InputObject $rawStr -ErrorAction SilentlyContinue
                        if ($null -ne $json -and $json.status -eq 'success' -and $null -ne $json.data.url) {
                            $rawUrl = [string]$json.data.url
                            $directUrl = $rawUrl -replace '(?i)https://tmpfiles\.org/', 'https://tmpfiles.org/dl/'
                            return $directUrl
                        }
                    }
                }

                # Fallback to System.Net.Http.HttpClient
                Add-Type -AssemblyName 'System.Net.Http' -ErrorAction SilentlyContinue
                $client = [System.Net.Http.HttpClient]::new()
                try {
                    $content = [System.Net.Http.MultipartFormDataContent]::new()
                    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
                    $byteContent = [System.Net.Http.ByteArrayContent]::new($bytes)
                    $byteContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/zip')
                    $content.Add($byteContent, 'file', [System.IO.Path]::GetFileName($FilePath))
                    $response = $client.PostAsync('https://tmpfiles.org/api/v1/upload', $content).GetAwaiter().GetResult()
                    if ($response.IsSuccessStatusCode) {
                        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                        $json = ConvertFrom-Json -InputObject $body -ErrorAction SilentlyContinue
                        if ($null -ne $json -and $json.status -eq 'success' -and $null -ne $json.data.url) {
                            $rawUrl = [string]$json.data.url
                            $directUrl = $rawUrl -replace '(?i)https://tmpfiles\.org/', 'https://tmpfiles.org/dl/'
                            return $directUrl
                        }
                    }
                } finally {
                    $client.Dispose()
                }
            } catch {
                $null = $_
                Write-Verbose "Tmpfiles upload failed: $($_.Exception.Message)"
            }
            return $null
        }

        # Execute upload based on provider choice
        if ($Provider -eq 'onlyfiles') {
            $downloadUrl = & $tryOnlyFiles -FilePath $zipPath
        } elseif ($Provider -eq 'uguu') {
            $downloadUrl = & $tryUguu -FilePath $zipPath
        } elseif ($Provider -eq 'tmpfiles') {
            $downloadUrl = & $tryTmpfiles -FilePath $zipPath
        } else {
            # Auto mode: Prioritize onlyfiles.com first, then fallback to uguu, then tmpfiles
            Write-Host "  Attempting upload via primary provider (onlyfiles.com)..." -ForegroundColor DarkGray
            $downloadUrl = & $tryOnlyFiles -FilePath $zipPath
            if ([string]::IsNullOrEmpty($downloadUrl)) {
                Write-Host "  Primary provider failed. Falling back to secondary provider (uguu.se)..." -ForegroundColor Yellow
                $downloadUrl = & $tryUguu -FilePath $zipPath
            }
            if ([string]::IsNullOrEmpty($downloadUrl)) {
                Write-Host "  Secondary provider failed. Falling back to tertiary provider (tmpfiles.org)..." -ForegroundColor Yellow
                $downloadUrl = & $tryTmpfiles -FilePath $zipPath
            }
        }

        if (-not [string]::IsNullOrEmpty($downloadUrl)) {
            Write-Host "  -> Public Download URL: $downloadUrl" -ForegroundColor Green
        } else {
            Write-Warning "Upload could not be completed. The archive remains available locally at: $zipPath"
        }
    } else {
        Write-Host "[4/4] Upload skipped (Local package build only)." -ForegroundColor DarkGray
    }

    Write-Host "================================================================================" -ForegroundColor Cyan
    Write-Host "                        IToolkit Package Build Complete                         " -ForegroundColor Cyan
    Write-Host "================================================================================" -ForegroundColor Cyan
    Write-Host "  Archive File : $zipPath"
    Write-Host "  File Size    : $fileSizeBytes bytes ($fileSizeKB KB)"
    Write-Host "  Total Files  : $entryCount entries"
    Write-Host "  SHA-256 Hash : $sha256Hash"
    if (-not [string]::IsNullOrEmpty($downloadUrl)) {
        Write-Host "  Download URL : $downloadUrl" -ForegroundColor Green
    }
    Write-Host "================================================================================" -ForegroundColor Cyan

    return [PSCustomObject]@{
        Path         = $zipPath
        SizeBytes    = $fileSizeBytes
        SizeKB       = $fileSizeKB
        EntriesCount = $entryCount
        SHA256       = $sha256Hash
        DownloadUrl  = $downloadUrl
        Success      = $true
    }
} finally {
    # 8. Clean up staging directory
    if ($tempStageDir -and (Test-Path -LiteralPath $tempStageDir)) {
        Remove-Item -LiteralPath $tempStageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
