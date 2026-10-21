<#
.SYNOPSIS
    Root automated test runner for the IToolkit suite.
.DESCRIPTION
    Executes automated Pester test suites across All, Unit, StaticAnalysis, E2E,
    and targeted module test suites (Network, Printers, TUI, AppInstaller).
    Cleanly reports summary metrics (Total, Passed, Failed, Skipped).
    Returns exit code 0 when all tests pass, exit code 1 if any test fails.
    Compatible with PowerShell Core 7+ and Windows PowerShell 5.1.
.PARAMETER Suite
    Target test suite: 'All', 'Unit', 'StaticAnalysis', 'E2E', 'Network', 'Printers', 'TUI', 'AppInstaller'. Default is 'All'.
.PARAMETER Detailed
    Switch to output detailed test case results.
.PARAMETER PassThru
    Returns the raw Pester test result object.
.EXAMPLE
    pwsh -File run-tests.ps1
.EXAMPLE
    pwsh -File run-tests.ps1 -Suite Network -Detailed
.EXAMPLE
    pwsh -File run-tests.ps1 -Suite Unit
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Unit', 'StaticAnalysis', 'E2E', 'Network', 'Printers', 'TUI', 'AppInstaller')]
    [string]$Suite = 'All',

    [switch]$Detailed,

    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path $PSScriptRoot).Path
$TestsDir = Join-Path -Path $ProjectRoot -ChildPath 'Tests'

# 1. Ensure Pester is loaded
if (-not (Get-Module -Name Pester)) {
    try {
        Import-Module Pester -ErrorAction Stop
    } catch {
        Write-Error "Pester module is required to run the test suite. Please install Pester (v5.x recommended): Install-Module Pester -Scope CurrentUser"
        exit 1
    }
}

# 2. Resolve target test paths based on Suite parameter
$testPaths = [System.Collections.Generic.List[string]]::new()

switch ($Suite) {
    'All' {
        $testPaths.Add((Join-Path $TestsDir 'StaticAnalysis'))
        $testPaths.Add((Join-Path $TestsDir 'Unit'))
        $testPaths.Add((Join-Path $TestsDir 'E2E'))
    }
    'Unit' {
        $testPaths.Add((Join-Path $TestsDir 'Unit'))
    }
    'StaticAnalysis' {
        $testPaths.Add((Join-Path $TestsDir 'StaticAnalysis'))
    }
    'E2E' {
        $testPaths.Add((Join-Path $TestsDir 'E2E'))
    }
    'Network' {
        $testPaths.Add((Join-Path $TestsDir 'Unit/Network.Tests.ps1'))
    }
    'Printers' {
        $testPaths.Add((Join-Path $TestsDir 'Unit/Printers.Tests.ps1'))
    }
    'TUI' {
        $testPaths.Add((Join-Path $TestsDir 'Unit/TUI.Tests.ps1'))
    }
    'AppInstaller' {
        $testPaths.Add((Join-Path $TestsDir 'Unit/AppInstaller.Tests.ps1'))
    }
}

# Filter only existing test targets
$validPaths = @($testPaths | Where-Object { Test-Path -LiteralPath $_ })

if ($validPaths.Count -eq 0) {
    Write-Warning "No valid test targets found for suite '$Suite'."
    exit 0
}

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "                  IToolkit Unified Automated Test Engine                        " -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "  Project Root : $ProjectRoot"
Write-Host "  Target Suite : $Suite"
Write-Host "  Pester Ver   : $((Get-Module Pester).Version)"
Write-Host "  PS Version   : $($PSVersionTable.PSVersion)"
Write-Host "================================================================================" -ForegroundColor Cyan

# 3. Configure and execute Pester
$pesterConfig = [PesterConfiguration]::Default
$pesterConfig.Run.Path = $validPaths
$pesterConfig.Run.PassThru = $true

if ($Detailed) {
    $pesterConfig.Output.Verbosity = 'Detailed'
} else {
    $pesterConfig.Output.Verbosity = 'Normal'
}

$results = Invoke-Pester -Configuration $pesterConfig

# 4. Clean summary metrics banner
Write-Host "`n================================================================================" -ForegroundColor Cyan
Write-Host "                        IToolkit Test Execution Summary                         " -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "  Total Executed : $($results.TotalCount)"
Write-Host "  Passed         : $($results.PassedCount)" -ForegroundColor Green
if ($results.FailedCount -gt 0) {
    Write-Host "  Failed         : $($results.FailedCount)" -ForegroundColor Red
} else {
    Write-Host "  Failed         : 0" -ForegroundColor Green
}
Write-Host "  Skipped/Pending: $($results.SkippedCount)" -ForegroundColor Yellow
Write-Host "  Total Duration : $($results.Time)"
Write-Host "================================================================================" -ForegroundColor Cyan

if ($PassThru) {
    return $results
}

if ($results.FailedCount -gt 0) {
    Write-Host "[-] TEST SUITE FAILED with $($results.FailedCount) failure(s)." -ForegroundColor Red
    exit 1
} else {
    Write-Host "[+] ALL TESTS PASSED SUCCESSFULLY (Zero Defect Gate Satisfied)." -ForegroundColor Green
    exit 0
}
