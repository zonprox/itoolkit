<#
.SYNOPSIS
    External release pipeline script: Builds clean IToolkit.zip and uploads it to public cloud hosts.

.DESCRIPTION
    Build/Package-And-Upload.ps1 is the dedicated CI/CD and release automation script.
    It builds a standalone, production-only IToolkit.zip archive (with zero tests,
    telemetry, or development residue) and automatically uploads it to public
    file hosting (onlyfiles.com / storage.to / uguu.se), providing an accessible public download URL.

.PARAMETER DestinationPath
    Optional output archive path. Defaults to "$ProjectRoot/IToolkit.zip".

.PARAMETER SkipUpload
    If specified, creates the standalone zip archive locally without uploading.

.PARAMETER Provider
    Public cloud host provider: 'auto' (default: onlyfiles.com and storage.to in parallel with fallback to uguu.se),
    'parallel', 'onlyfiles', 'storage.to', 'storageto', or 'uguu'.

.PARAMETER Force
    Overwrites existing archive at DestinationPath.

.OUTPUTS
    [PSCustomObject] Containing Path, SizeBytes, SHA256, EntriesCount, DownloadUrl, OnlyFilesUrl, StorageToUrl, and Success.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]$DestinationPath,

    [Parameter(Mandatory = $false)]
    [switch]$SkipUpload,

    [Parameter(Mandatory = $false)]
    [ValidateSet('auto', 'parallel', 'onlyfiles', 'storage.to', 'storageto', 'catbox', 'uguu')]
    [string]$Provider = 'auto',

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Resolve Project Root (parent of Build/)
$buildScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($buildScriptDir)) {
    if ($null -ne $MyInvocation.MyCommand.Path) {
        $buildScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    } elseif ($null -ne $MyInvocation.MyCommand.Definition) {
        $buildScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    } else {
        $buildScriptDir = (Get-Location).ProviderPath
    }
}
$ProjectRoot = (Resolve-Path (Join-Path -Path $buildScriptDir -ChildPath '..')).Path

$rootBuilder = Join-Path -Path $ProjectRoot -ChildPath 'Build-IToolkitPackage.ps1'

$shouldUpload = (-not $SkipUpload)

if (Test-Path -LiteralPath $rootBuilder) {
    Write-Verbose "Delegating to root package builder: $rootBuilder"
    $params = @{
        Provider = $Provider
    }
    if (-not [string]::IsNullOrEmpty($DestinationPath)) {
        $params['DestinationPath'] = $DestinationPath
    }
    if ($SkipUpload) {
        $params['SkipUpload'] = $true
    } elseif ($shouldUpload) {
        $params['Upload'] = $true
    }
    if ($Force) {
        $params['Force'] = $true
    }
    if ($PSBoundParameters.ContainsKey('WhatIf')) {
        $params['WhatIf'] = $PSBoundParameters['WhatIf']
    }

    & $rootBuilder @params
} else {
    throw "Packaging script 'Build-IToolkitPackage.ps1' not found at project root: $ProjectRoot"
}
