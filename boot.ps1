<#
.SYNOPSIS
    IToolkit Web Bootstrap & Cloud Launcher
.DESCRIPTION
    Downloads and launches the latest version of IToolkit directly:
    irm <url> | iex
#>
[CmdletBinding()]
param(
    [switch]$SkipElevation,
    [switch]$NonInteractive,
    [string]$MenuOption
)

# Enforce TLS 1.2 for legacy Windows PowerShell 5.1 compatibility
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    # Ignore on PowerShell Core / Linux where TLS 1.2+ is already standard
}

# 1. Administrator Privilege Check & Self-Elevation (Windows only)
if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin -and -not $SkipElevation) {
        Write-Host "[!] Dang yeu cau quyen Administrator (UAC)..." -ForegroundColor Yellow
        $scriptUrl = "https://raw.githubusercontent.com/zonprox/itoolkit/main/boot.ps1"
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"irm $scriptUrl | iex`""
        return
    }
}

# 2. Setup download parameters
$repoOwner = "zonprox"
$repoName  = "itoolkit"
$zipUrl    = "https://github.com/$repoOwner/$repoName/archive/refs/heads/main.zip"
$tempBase  = Join-Path ([System.IO.Path]::GetTempPath()) "IToolkit_$(Get-Random)"
$zipPath   = Join-Path ([System.IO.Path]::GetTempPath()) "IToolkit_Live_$(Get-Random).zip"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "       IToolkit - Khoi chay truc tiep tu Cloud            " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

try {
    Write-Host "[-] Dang tai phien ban moi nhat tu GitHub..." -ForegroundColor Gray
    $webClient = New-Object System.Net.WebClient
    $webClient.Headers.Add("User-Agent", "IToolkit-WebBootstrapper/1.0")
    $webClient.DownloadFile($zipUrl, $zipPath)

    Write-Host "[-] Dang giai nen vao thu muc tam..." -ForegroundColor Gray
    if (Test-Path -LiteralPath $tempBase) {
        Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
    Expand-Archive -Path $zipPath -DestinationPath $tempBase -Force

    # Locate extracted root folder containing Start-IToolkit.ps1
    $projectRoot = Get-ChildItem -Path $tempBase -Directory | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName "Start-IToolkit.ps1")
    } | Select-Object -First 1

    if (-not $projectRoot) {
        $projectRoot = Get-Item -LiteralPath $tempBase
    }

    $launcher = Join-Path $projectRoot.FullName "Start-IToolkit.ps1"
    if (-not (Test-Path -LiteralPath $launcher)) {
        throw "Khong tim thay Start-IToolkit.ps1 trong goi ma nguon."
    }

    Write-Host "[+] Khoi dong IToolkit..." -ForegroundColor Green

    $runParams = @{}
    if ($SkipElevation) { $runParams['SkipElevation'] = $true }
    if ($NonInteractive) { $runParams['NonInteractive'] = $true }
    if (-not [string]::IsNullOrEmpty($MenuOption)) { $runParams['MenuOption'] = $MenuOption }

    & $launcher @runParams
}
catch {
    Write-Error "Loi trong qua trinh tai hoac khoi chay IToolkit: $_"
}
finally {
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }
}
