<#
.SYNOPSIS
    Master test runner for the IToolkit suite.
.DESCRIPTION
    Executes Static Analysis (AST & Security), Modular Unit Tests, and E2E Scenarios (Tiers 1-4).
    Compatible with Windows PowerShell 5.1 (.NET 4.8) and PowerShell 7+ Core.
.PARAMETER Suite
    Target test suite: 'All', 'StaticAnalysis', 'Unit', or 'E2E'. Default is 'All'.
.PARAMETER Tag
    Optional Pester tag filter.
.PARAMETER Detailed
    Switch to output detailed test case results.
.PARAMETER PassThru
    Returns the raw Pester test result object.
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'StaticAnalysis', 'Unit', 'E2E')]
    [string]$Suite = 'All',

    [string]$Tag,

    [switch]$Detailed,

    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$TestsDir = Join-Path $ProjectRoot 'Tests'

# 1. Ensure Pester is loaded
if (-not (Get-Module -Name Pester)) {
    try {
        Import-Module Pester -ErrorAction Stop
    } catch {
        Write-Error "Pester module is required to run the test suite. Please install Pester (v5.x recommended): Install-Module Pester -Scope CurrentUser"
        exit 1
    }
}

# 2. Resolve target test paths
$testPaths = [System.Collections.Generic.List[string]]::new()

switch ($Suite) {
    'All' {
        $testPaths.Add((Join-Path $TestsDir 'StaticAnalysis'))
        $testPaths.Add((Join-Path $TestsDir 'Unit'))
        $testPaths.Add((Join-Path $TestsDir 'E2E'))
    }
    'StaticAnalysis' {
        $testPaths.Add((Join-Path $TestsDir 'StaticAnalysis'))
    }
    'Unit' {
        $testPaths.Add((Join-Path $TestsDir 'Unit'))
    }
    'E2E' {
        $testPaths.Add((Join-Path $TestsDir 'E2E'))
    }
}

# Filter only existing directories
$validPaths = @($testPaths | Where-Object { Test-Path $_ })

if ($validPaths.Count -eq 0) {
    Write-Warning "No valid test paths found for suite '$Suite'."
    exit 0
}

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "           IToolkit Test Framework — Enterprise Test Execution Engine           " -ForegroundColor Cyan
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

if (-not [string]::IsNullOrWhiteSpace($Tag)) {
    $pesterConfig.Filter.Tag = @($Tag)
}

$results = Invoke-Pester -Configuration $pesterConfig

# 4. Format Enterprise Summary Banner
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
