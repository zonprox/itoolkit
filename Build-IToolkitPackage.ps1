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
    and optionally uploads to public hosting services (catbox.moe / onlyfiles.com / uguu.se).

.PARAMETER DestinationPath
    Destination file path for the output archive.
    Defaults to "$PSScriptRoot/IToolkit.zip".

.PARAMETER Upload
    Switch to immediately upload the packaged archive to public cloud file hosting.

.PARAMETER SkipUpload
    Switch to explicitly skip uploading the package to public cloud file hosting.
    If specified, disables upload even if -Upload was also passed.

.PARAMETER Provider
    Public upload provider to use. Valid choices: 'auto', 'parallel', 'onlyfiles', 'catbox', 'uguu'.
    Defaults to 'auto' (uploads to onlyfiles.com and catbox.moe in parallel with fallback to uguu.se).

.PARAMETER Force
    Forces overwriting of any existing archive file at DestinationPath.

.OUTPUTS
    [PSCustomObject] Containing Path, SizeBytes, SHA256, EntriesCount, DownloadUrl, OnlyFilesUrl, CatboxUrl, and Success.
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
    [ValidateSet('auto', 'parallel', 'onlyfiles', 'catbox', 'uguu')]
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

        # Helper function for Catbox.moe upload (with Litterbox fallback)
        $tryCatbox = {
            param([string]$FilePath)
            try {
                $curl = Get-Command -Name 'curl.exe' -ErrorAction SilentlyContinue
                if ($null -eq $curl) {
                    $curl = Get-Command -Name 'curl' -ErrorAction SilentlyContinue
                }
                if ($null -ne $curl) {
                    # 1. Try permanent Catbox API first
                    $raw = & $curl.Source -m 30 -s -F "reqtype=fileupload" -F "userhash=" -F "fileToUpload=@$FilePath" "https://catbox.moe/user/api.php"
                    if ($raw) {
                        $url = ($raw -join "`n").Trim()
                        if ($url -match '^https?://files\.catbox\.moe/') {
                            return $url
                        }
                    }

                    # 2. Fallback to Litterbox (Catbox official temporary storage)
                    $rawLitter = & $curl.Source -m 30 -s -F "reqtype=fileupload" -F "time=72h" -F "fileToUpload=@$FilePath" "https://litterbox.catbox.moe/resources/internals/api.php"
                    if ($rawLitter) {
                        $url = ($rawLitter -join "`n").Trim()
                        if ($url -match '^https?://litter\.catbox\.moe/') {
                            return $url
                        }
                    }
                }

                # Fallback to System.Net.Http.HttpClient
                Add-Type -AssemblyName 'System.Net.Http' -ErrorAction SilentlyContinue
                $client = [System.Net.Http.HttpClient]::new()
                try {
                    $client.Timeout = [System.TimeSpan]::FromSeconds(45)
                    $bytes = [System.IO.File]::ReadAllBytes($FilePath)

                    # 1. Try permanent Catbox
                    try {
                        $content = [System.Net.Http.MultipartFormDataContent]::new()
                        $content.Add([System.Net.Http.StringContent]::new('fileupload'), 'reqtype')
                        $content.Add([System.Net.Http.StringContent]::new(''), 'userhash')
                        $byteContent = [System.Net.Http.ByteArrayContent]::new($bytes)
                        $byteContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/zip')
                        $content.Add($byteContent, 'fileToUpload', [System.IO.Path]::GetFileName($FilePath))

                        $response = $client.PostAsync('https://catbox.moe/user/api.php', $content).GetAwaiter().GetResult()
                        if ($response.IsSuccessStatusCode) {
                            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult().Trim()
                            if ($body -match '^https?://files\.catbox\.moe/') {
                                return $body
                            }
                        }
                    } catch {
                        Write-Verbose "Permanent Catbox upload failed, attempting Litterbox: $($_.Exception.Message)"
                    }

                    # 2. Try Litterbox
                    try {
                        $content = [System.Net.Http.MultipartFormDataContent]::new()
                        $content.Add([System.Net.Http.StringContent]::new('fileupload'), 'reqtype')
                        $content.Add([System.Net.Http.StringContent]::new('72h'), 'time')
                        $byteContent = [System.Net.Http.ByteArrayContent]::new($bytes)
                        $byteContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/zip')
                        $content.Add($byteContent, 'fileToUpload', [System.IO.Path]::GetFileName($FilePath))

                        $response = $client.PostAsync('https://litterbox.catbox.moe/resources/internals/api.php', $content).GetAwaiter().GetResult()
                        if ($response.IsSuccessStatusCode) {
                            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult().Trim()
                            if ($body -match '^https?://litter\.catbox\.moe/') {
                                return $body
                            }
                        }
                    } catch {
                        Write-Verbose "Litterbox upload failed: $($_.Exception.Message)"
                    }
                } finally {
                    $client.Dispose()
                }
            } catch {
                $null = $_
                Write-Verbose "Catbox upload failed: $($_.Exception.Message)"
            }
            return $null
        }

        # Helper function for parallel upload to both OnlyFiles.com and Catbox.moe
        $tryParallelUpload = {
            param([string]$FilePath)
            $resOnlyFiles = $null
            $resCatbox    = $null

            # 1. Attempt parallel upload via background curl processes if curl is present
            $curl = Get-Command -Name 'curl.exe' -ErrorAction SilentlyContinue
            if ($null -eq $curl) {
                $curl = Get-Command -Name 'curl' -ErrorAction SilentlyContinue
            }

            if ($null -ne $curl) {
                $tmp1 = [System.IO.Path]::GetTempFileName()
                $tmp2 = [System.IO.Path]::GetTempFileName()
                try {
                    $p1 = Start-Process -FilePath $curl.Source -ArgumentList "-m", "35", "-s", "-F", "file=@$FilePath", "-F", "expire=0", "https://api.onlyfiles.com/v1/upload" -RedirectStandardOutput $tmp1 -PassThru -NoNewWindow
                    $p2 = Start-Process -FilePath $curl.Source -ArgumentList "-m", "35", "-s", "-F", "reqtype=fileupload", "-F", "userhash=", "-F", "fileToUpload=@$FilePath", "https://catbox.moe/user/api.php" -RedirectStandardOutput $tmp2 -PassThru -NoNewWindow

                    $null = $p1.WaitForExit(45000)
                    $null = $p2.WaitForExit(45000)

                    if (Test-Path -LiteralPath $tmp1) {
                        $out1 = Get-Content -LiteralPath $tmp1 -Raw -ErrorAction SilentlyContinue
                        if ($out1) {
                            $json1 = ConvertFrom-Json -InputObject $out1 -ErrorAction SilentlyContinue
                            if ($null -ne $json1 -and $json1.status -and $null -ne $json1.data -and $null -ne $json1.data.file) {
                                if ($null -ne $json1.data.file.url -and -not [string]::IsNullOrEmpty($json1.data.file.url.full)) {
                                    $resOnlyFiles = [string]$json1.data.file.url.full
                                } elseif ($null -ne $json1.data.file.url -and -not [string]::IsNullOrEmpty($json1.data.file.url.short)) {
                                    $resOnlyFiles = [string]$json1.data.file.url.short
                                }
                            }
                        }
                    }

                    if (Test-Path -LiteralPath $tmp2) {
                        $out2 = (Get-Content -LiteralPath $tmp2 -Raw -ErrorAction SilentlyContinue)
                        if ($out2) {
                            $trimmed2 = $out2.Trim()
                            if ($trimmed2 -match '^https?://files\.catbox\.moe/') {
                                $resCatbox = $trimmed2
                            }
                        }
                    }

                    # If Catbox returned error or non-URL (e.g. 412 Invalid uploader on cloud IP), fallback to Litterbox
                    if ([string]::IsNullOrEmpty($resCatbox)) {
                        $rawLitter = & $curl.Source -m 30 -s -F "reqtype=fileupload" -F "time=72h" -F "fileToUpload=@$FilePath" "https://litterbox.catbox.moe/resources/internals/api.php"
                        if ($rawLitter) {
                            $trimmedLitter = ($rawLitter -join "`n").Trim()
                            if ($trimmedLitter -match '^https?://litter\.catbox\.moe/') {
                                $resCatbox = $trimmedLitter
                            }
                        }
                    }
                } catch {
                    Write-Verbose "Parallel curl upload failed: $($_.Exception.Message)"
                } finally {
                    Remove-Item -LiteralPath $tmp1, $tmp2 -Force -ErrorAction SilentlyContinue
                }
            }

            # 2. Fallback to System.Net.Http.HttpClient async if both failed and/or curl was unavailable
            if ([string]::IsNullOrEmpty($resOnlyFiles) -and [string]::IsNullOrEmpty($resCatbox)) {
                try {
                    Add-Type -AssemblyName 'System.Net.Http' -ErrorAction SilentlyContinue
                    $client = [System.Net.Http.HttpClient]::new()
                    try {
                        $client.Timeout = [System.TimeSpan]::FromSeconds(45)
                        $bytes = [System.IO.File]::ReadAllBytes($FilePath)

                        # OnlyFiles request
                        $c1 = [System.Net.Http.MultipartFormDataContent]::new()
                        $bc1 = [System.Net.Http.ByteArrayContent]::new($bytes)
                        $bc1.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/zip')
                        $c1.Add($bc1, 'file', [System.IO.Path]::GetFileName($FilePath))
                        $c1.Add([System.Net.Http.StringContent]::new('0'), 'expire')

                        # Catbox request (using Litterbox endpoint for reliable direct access)
                        $c2 = [System.Net.Http.MultipartFormDataContent]::new()
                        $c2.Add([System.Net.Http.StringContent]::new('fileupload'), 'reqtype')
                        $c2.Add([System.Net.Http.StringContent]::new('72h'), 'time')
                        $bc2 = [System.Net.Http.ByteArrayContent]::new($bytes)
                        $bc2.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/zip')
                        $c2.Add($bc2, 'fileToUpload', [System.IO.Path]::GetFileName($FilePath))

                        $t1 = $client.PostAsync('https://api.onlyfiles.com/v1/upload', $c1)
                        $t2 = $client.PostAsync('https://litterbox.catbox.moe/resources/internals/api.php', $c2)

                        $null = [System.Threading.Tasks.Task]::WaitAll(@($t1, $t2), 45000)

                        if ($t1.IsCompleted -and -not $t1.IsFaulted -and $t1.Result.IsSuccessStatusCode) {
                            $b1 = $t1.Result.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                            $j1 = ConvertFrom-Json -InputObject $b1 -ErrorAction SilentlyContinue
                            if ($null -ne $j1 -and $j1.status -and $null -ne $j1.data -and $null -ne $j1.data.file) {
                                if ($null -ne $j1.data.file.url -and -not [string]::IsNullOrEmpty($j1.data.file.url.full)) {
                                    $resOnlyFiles = [string]$j1.data.file.url.full
                                } elseif ($null -ne $j1.data.file.url -and -not [string]::IsNullOrEmpty($j1.data.file.url.short)) {
                                    $resOnlyFiles = [string]$j1.data.file.url.short
                                }
                            }
                        }

                        if ($t2.IsCompleted -and -not $t2.IsFaulted -and $t2.Result.IsSuccessStatusCode) {
                            $b2 = $t2.Result.Content.ReadAsStringAsync().GetAwaiter().GetResult().Trim()
                            if ($b2 -match '^https?://litter\.catbox\.moe/') {
                                $resCatbox = $b2
                            }
                        }
                    } finally {
                        $client.Dispose()
                    }
                } catch {
                    Write-Verbose "Parallel HttpClient upload failed: $($_.Exception.Message)"
                }
            }

            return @{
                OnlyFiles = $resOnlyFiles
                Catbox    = $resCatbox
            }
        }

        $onlyFilesUrl = $null
        $catboxUrl    = $null

        # Execute upload based on provider choice
        if ($Provider -eq 'onlyfiles') {
            $onlyFilesUrl = & $tryOnlyFiles -FilePath $zipPath
            $downloadUrl = $onlyFilesUrl
        } elseif ($Provider -eq 'catbox') {
            $catboxUrl = & $tryCatbox -FilePath $zipPath
            $downloadUrl = $catboxUrl
        } elseif ($Provider -eq 'uguu') {
            $downloadUrl = & $tryUguu -FilePath $zipPath
        } else {
            # 'auto' or 'parallel' mode: Upload to OnlyFiles and Catbox in parallel
            Write-Host "  Attempting parallel upload (onlyfiles.com + catbox.moe)..." -ForegroundColor Cyan
            $parallelResult = & $tryParallelUpload -FilePath $zipPath
            $onlyFilesUrl = $parallelResult.OnlyFiles
            $catboxUrl    = $parallelResult.Catbox

            if (-not [string]::IsNullOrEmpty($onlyFilesUrl)) {
                $downloadUrl = $onlyFilesUrl
            } elseif (-not [string]::IsNullOrEmpty($catboxUrl)) {
                $downloadUrl = $catboxUrl
            } else {
                Write-Host "  Parallel providers failed. Falling back to tertiary provider (uguu.se)..." -ForegroundColor Yellow
                $downloadUrl = & $tryUguu -FilePath $zipPath
            }
        }

        if (-not [string]::IsNullOrEmpty($onlyFilesUrl)) {
            Write-Host "  -> Public Download URL (OnlyFiles) : $onlyFilesUrl" -ForegroundColor Green
        }
        if (-not [string]::IsNullOrEmpty($catboxUrl)) {
            Write-Host "  -> Public Download URL (Catbox)    : $catboxUrl" -ForegroundColor Green
        }
        if ([string]::IsNullOrEmpty($onlyFilesUrl) -and [string]::IsNullOrEmpty($catboxUrl) -and -not [string]::IsNullOrEmpty($downloadUrl)) {
            Write-Host "  -> Public Download URL             : $downloadUrl" -ForegroundColor Green
        }
        if ([string]::IsNullOrEmpty($downloadUrl)) {
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
    if (-not [string]::IsNullOrEmpty($onlyFilesUrl)) {
        Write-Host "  Download URL (OnlyFiles) : $onlyFilesUrl" -ForegroundColor Green
    }
    if (-not [string]::IsNullOrEmpty($catboxUrl)) {
        Write-Host "  Download URL (Catbox)    : $catboxUrl" -ForegroundColor Green
    }
    if ([string]::IsNullOrEmpty($onlyFilesUrl) -and [string]::IsNullOrEmpty($catboxUrl) -and -not [string]::IsNullOrEmpty($downloadUrl)) {
        Write-Host "  Download URL             : $downloadUrl" -ForegroundColor Green
    }
    Write-Host "================================================================================" -ForegroundColor Cyan

    return [PSCustomObject]@{
        Path         = $zipPath
        SizeBytes    = $fileSizeBytes
        SizeKB       = $fileSizeKB
        EntriesCount = $entryCount
        SHA256       = $sha256Hash
        DownloadUrl  = $downloadUrl
        OnlyFilesUrl = $onlyFilesUrl
        CatboxUrl    = $catboxUrl
        Success      = $true
    }
} finally {
    # 8. Clean up staging directory
    if ($tempStageDir -and (Test-Path -LiteralPath $tempStageDir)) {
        Remove-Item -LiteralPath $tempStageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
