# ==============================================================================
# TestOutlookLockStress.ps1
# Empirical Adversarial Stress Harness for Test-OutlookDataFileLock
# Validates directory safety, non-existent path handling, exclusive locks,
# unlocked data files, handle cleanup, and boundary edge cases.
# ==============================================================================

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = (Resolve-Path (Join-Path $ScriptDir '../..')).Path

# Load Module
Import-Module (Join-Path $ProjectRoot 'Modules/Outlook/Outlook.psd1') -Force

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "        Empirical Adversarial Stress Harness: Test-OutlookDataFileLock         " -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan

$testResults = [System.Collections.Generic.List[PSCustomObject]]::new()

function Assert-TestCase {
    param(
        [string]$Category,
        [string]$Scenario,
        [scriptblock]$TestBlock
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $status = 'PASS'
    $errorDetail = $null

    try {
        & $TestBlock
    }
    catch {
        $status = 'FAIL'
        $errorDetail = $_.Exception.Message
    }
    finally {
        $stopwatch.Stop()
    }

    $entry = [PSCustomObject]@{
        Category = $Category
        Scenario = $Scenario
        Status   = $status
        Duration = "$($stopwatch.ElapsedMilliseconds)ms"
        Error    = $errorDetail
    }

    $testResults.Add($entry)

    if ($status -eq 'PASS') {
        Write-Host "  [+] PASS: [$Category] $Scenario ($($stopwatch.ElapsedMilliseconds)ms)" -ForegroundColor Green
    }
    else {
        Write-Host "  [-] FAIL: [$Category] $Scenario -> $errorDetail" -ForegroundColor Red
    }
}

# ------------------------------------------------------------------------------
# CATEGORY 1: DIRECTORY INPUTS (Exists = $true, IsLocked = $false)
# ------------------------------------------------------------------------------
Write-Host "`n-- Executing Category 1: Directory Inputs --" -ForegroundColor Yellow

$tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ("stress_dir_" + [System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tempBase -Force | Out-Null

try {
    # 1.1 Empty directory
    $emptyDir = Join-Path $tempBase "empty_dir"
    New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
    Assert-TestCase -Category "Directories" -Scenario "Empty directory reports Exists=$true, IsLocked=$false" -TestBlock {
        $res = Test-OutlookDataFileLock -Path $emptyDir
        if ($res.Exists -ne $true) { throw "Expected Exists = `$true, got $($res.Exists)" }
        if ($res.IsLocked -ne $false) { throw "Expected IsLocked = `$false, got $($res.IsLocked)" }
        if ($res.ErrorMessage -notmatch "directory, not an Outlook data file") { throw "Unexpected ErrorMessage: $($res.ErrorMessage)" }
    }

    # 1.2 Nested directories (deep chain)
    $nestedDir = Join-Path $tempBase "level1/level2/level3/level4/level5"
    New-Item -ItemType Directory -Path $nestedDir -Force | Out-Null
    Assert-TestCase -Category "Directories" -Scenario "Deeply nested directory reports Exists=$true, IsLocked=$false" -TestBlock {
        $res = Test-OutlookDataFileLock -Path $nestedDir
        if ($res.Exists -ne $true) { throw "Expected Exists = `$true, got $($res.Exists)" }
        if ($res.IsLocked -ne $false) { throw "Expected IsLocked = `$false, got $($res.IsLocked)" }
        if ($res.ErrorMessage -notmatch "directory, not an Outlook data file") { throw "Unexpected ErrorMessage: $($res.ErrorMessage)" }
    }

    # 1.3 Directory with single trailing slash
    Assert-TestCase -Category "Directories" -Scenario "Directory with trailing slash reports Exists=$true, IsLocked=$false" -TestBlock {
        $pathWithSlash = "$emptyDir/"
        $res = Test-OutlookDataFileLock -Path $pathWithSlash
        if ($res.Exists -ne $true) { throw "Expected Exists = `$true, got $($res.Exists)" }
        if ($res.IsLocked -ne $false) { throw "Expected IsLocked = `$false, got $($res.IsLocked)" }
        if ($res.ErrorMessage -notmatch "directory, not an Outlook data file") { throw "Unexpected ErrorMessage: $($res.ErrorMessage)" }
    }

    # 1.4 Directory with multiple trailing slashes
    Assert-TestCase -Category "Directories" -Scenario "Directory with multiple trailing slashes reports Exists=$true, IsLocked=$false" -TestBlock {
        $pathWithMultiSlash = "$nestedDir///"
        $res = Test-OutlookDataFileLock -Path $pathWithMultiSlash
        if ($res.Exists -ne $true) { throw "Expected Exists = `$true, got $($res.Exists)" }
        if ($res.IsLocked -ne $false) { throw "Expected IsLocked = `$false, got $($res.IsLocked)" }
        if ($res.ErrorMessage -notmatch "directory, not an Outlook data file") { throw "Unexpected ErrorMessage: $($res.ErrorMessage)" }
    }

    # 1.5 Non-empty directory containing child files
    $nonEmptyDir = Join-Path $tempBase "populated_dir"
    New-Item -ItemType Directory -Path $nonEmptyDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $nonEmptyDir "child1.txt"), "sample data")
    [System.IO.File]::WriteAllText((Join-Path $nonEmptyDir "child2.pst"), "sample pst")
    Assert-TestCase -Category "Directories" -Scenario "Non-empty directory with child files reports Exists=$true, IsLocked=$false" -TestBlock {
        $res = Test-OutlookDataFileLock -Path $nonEmptyDir
        if ($res.Exists -ne $true) { throw "Expected Exists = `$true, got $($res.Exists)" }
        if ($res.IsLocked -ne $false) { throw "Expected IsLocked = `$false, got $($res.IsLocked)" }
        if ($res.ErrorMessage -notmatch "directory, not an Outlook data file") { throw "Unexpected ErrorMessage: $($res.ErrorMessage)" }
    }

    # 1.6 Directory containing exclusively locked file inside
    $lockedChildPath = Join-Path $nonEmptyDir "locked_child.pst"
    $lockedChildStream = [System.IO.File]::Open($lockedChildPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        Assert-TestCase -Category "Directories" -Scenario "Directory containing locked file reports Exists=$true, IsLocked=$false" -TestBlock {
            $res = Test-OutlookDataFileLock -Path $nonEmptyDir
            if ($res.Exists -ne $true) { throw "Expected Exists = `$true, got $($res.Exists)" }
            if ($res.IsLocked -ne $false) { throw "Expected IsLocked = `$false, got $($res.IsLocked)" }
            if ($res.ErrorMessage -notmatch "directory, not an Outlook data file") { throw "Unexpected ErrorMessage: $($res.ErrorMessage)" }
        }
    }
    finally {
        $lockedChildStream.Close()
        $lockedChildStream.Dispose()
    }

    # 1.7 Directory named with .pst extension
    $pstNamedDir = Join-Path $tempBase "FakeArchive.pst"
    New-Item -ItemType Directory -Path $pstNamedDir -Force | Out-Null
    Assert-TestCase -Category "Directories" -Scenario "Directory named with .pst extension reports Exists=$true, IsLocked=$false" -TestBlock {
        $res = Test-OutlookDataFileLock -Path $pstNamedDir
        if ($res.Exists -ne $true) { throw "Expected Exists = `$true, got $($res.Exists)" }
        if ($res.IsLocked -ne $false) { throw "Expected IsLocked = `$false, got $($res.IsLocked)" }
        if ($res.ErrorMessage -notmatch "directory, not an Outlook data file") { throw "Unexpected ErrorMessage: $($res.ErrorMessage)" }
    }

    # 1.8 Directory with spaces and brackets in name
    $specialDir = Join-Path $tempBase "My [Special] Outlook Dir"
    New-Item -ItemType Directory -Path $specialDir -Force | Out-Null
    Assert-TestCase -Category "Directories" -Scenario "Directory with spaces and brackets reports Exists=$true, IsLocked=$false" -TestBlock {
        $res = Test-OutlookDataFileLock -Path $specialDir
        if ($res.Exists -ne $true) { throw "Expected Exists = `$true, got $($res.Exists)" }
        if ($res.IsLocked -ne $false) { throw "Expected IsLocked = `$false, got $($res.IsLocked)" }
        if ($res.ErrorMessage -notmatch "directory, not an Outlook data file") { throw "Unexpected ErrorMessage: $($res.ErrorMessage)" }
    }

    # 1.9 System temp root directory
    Assert-TestCase -Category "Directories" -Scenario "System temp root directory reports Exists=$true, IsLocked=$false" -TestBlock {
        $res = Test-OutlookDataFileLock -Path ([System.IO.Path]::GetTempPath())
        if ($res.Exists -ne $true) { throw "Expected Exists = `$true, got $($res.Exists)" }
        if ($res.IsLocked -ne $false) { throw "Expected IsLocked = `$false, got $($res.IsLocked)" }
        if ($res.ErrorMessage -notmatch "directory, not an Outlook data file") { throw "Unexpected ErrorMessage: $($res.ErrorMessage)" }
    }
}
finally {
    Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------------
# CATEGORY 2: NON-EXISTENT PATHS (Exists = $false, IsLocked = $false)
# ------------------------------------------------------------------------------
Write-Host "`n-- Executing Category 2: Non-Existent Paths --" -ForegroundColor Yellow

# 2.1 Non-existent file path
Assert-TestCase -Category "NonExistent" -Scenario "Non-existent file reports Exists=$false, IsLocked=$false" -TestBlock {
    $bogus = "/tmp/nonexistent_datafile_" + [System.Guid]::NewGuid().ToString() + ".pst"
    $res = Test-OutlookDataFileLock -Path $bogus
    if ($res.Exists -ne $false) { throw "Expected Exists = `$false, got $($res.Exists)" }
    if ($res.IsLocked -ne $false) { throw "Expected IsLocked = `$false, got $($res.IsLocked)" }
    if ($res.ErrorMessage -notmatch "File does not exist") { throw "Unexpected ErrorMessage: $($res.ErrorMessage)" }
}

# 2.2 Non-existent directory path with trailing slash
Assert-TestCase -Category "NonExistent" -Scenario "Non-existent directory path with slash reports Exists=$false, IsLocked=$false" -TestBlock {
    $bogusDir = "/tmp/nonexistent_dir_" + [System.Guid]::NewGuid().ToString() + "/"
    $res = Test-OutlookDataFileLock -Path $bogusDir
    if ($res.Exists -ne $false) { throw "Expected Exists = `$false, got $($res.Exists)" }
    if ($res.IsLocked -ne $false) { throw "Expected IsLocked = `$false, got $($res.IsLocked)" }
    if ($res.ErrorMessage -notmatch "File does not exist") { throw "Unexpected ErrorMessage: $($res.ErrorMessage)" }
}

# 2.3 Non-existent deeply nested path
Assert-TestCase -Category "NonExistent" -Scenario "Non-existent deeply nested path reports Exists=$false, IsLocked=$false" -TestBlock {
    $bogusDeep = "/tmp/a/b/c/d/e/f/nonexistent.ost"
    $res = Test-OutlookDataFileLock -Path $bogusDeep
    if ($res.Exists -ne $false) { throw "Expected Exists = `$false, got $($res.Exists)" }
    if ($res.IsLocked -ne $false) { throw "Expected IsLocked = `$false, got $($res.IsLocked)" }
    if ($res.ErrorMessage -notmatch "File does not exist") { throw "Unexpected ErrorMessage: $($res.ErrorMessage)" }
}

# 2.4 Whitespace path
Assert-TestCase -Category "NonExistent" -Scenario "Whitespace path reports Exists=$false, IsLocked=$false" -TestBlock {
    $res = Test-OutlookDataFileLock -Path "   "
    if ($res.Exists -ne $false) { throw "Expected Exists = `$false, got $($res.Exists)" }
    if ($res.IsLocked -ne $false) { throw "Expected IsLocked = `$false, got $($res.IsLocked)" }
    if ($res.ErrorMessage -notmatch "cannot be null, empty, or whitespace") { throw "Unexpected ErrorMessage: $($res.ErrorMessage)" }
}

# 2.5 Wildcard path
Assert-TestCase -Category "NonExistent" -Scenario "Wildcard path reports Exists=$false, IsLocked=$false" -TestBlock {
    $res = Test-OutlookDataFileLock -Path "/tmp/*.pst"
    if ($res.Exists -ne $false) { throw "Expected Exists = `$false, got $($res.Exists)" }
    if ($res.IsLocked -ne $false) { throw "Expected IsLocked = `$false, got $($res.IsLocked)" }
    if ($res.ErrorMessage -notmatch "cannot contain wildcard") { throw "Unexpected ErrorMessage: $($res.ErrorMessage)" }
}

# ------------------------------------------------------------------------------
# CATEGORY 3: EXCLUSIVELY LOCKED FILES (Exists = $true, IsLocked = $true)
# ------------------------------------------------------------------------------
Write-Host "`n-- Executing Category 3: Exclusively Locked Files --" -ForegroundColor Yellow

$tempFile = [System.IO.Path]::GetTempFileName()
try {
    # 3.1 Locked with FileShare.None and FileAccess.ReadWrite
    $fsNone = [System.IO.File]::Open($tempFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        Assert-TestCase -Category "LockedFiles" -Scenario "File locked with FileShare.None reports Exists=$true, IsLocked=$true" -TestBlock {
            $res = Test-OutlookDataFileLock -Path $tempFile
            if ($res.Exists -ne $true) { throw "Expected Exists = `$true, got $($res.Exists)" }
            if ($res.IsLocked -ne $true) { throw "Expected IsLocked = `$true, got $($res.IsLocked)" }
            if ([string]::IsNullOrEmpty($res.ErrorMessage)) { throw "Expected ErrorMessage to describe lock failure" }
        }
    }
    finally {
        $fsNone.Close()
        $fsNone.Dispose()
    }

    # 3.2 Locked with FileShare.Read (ReadWrite access requested by probe fails)
    $fsReadShare = [System.IO.File]::Open($tempFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        Assert-TestCase -Category "LockedFiles" -Scenario "File locked with FileShare.Read reports Exists=$true, IsLocked=$true" -TestBlock {
            $res = Test-OutlookDataFileLock -Path $tempFile
            if ($res.Exists -ne $true) { throw "Expected Exists = `$true, got $($res.Exists)" }
            if ($res.IsLocked -ne $true) { throw "Expected IsLocked = `$true, got $($res.IsLocked)" }
            if ([string]::IsNullOrEmpty($res.ErrorMessage)) { throw "Expected ErrorMessage to describe lock failure" }
        }
    }
    finally {
        $fsReadShare.Close()
        $fsReadShare.Dispose()
    }

    # 3.3 File with chmod 000 permissions (access denied)
    Assert-TestCase -Category "LockedFiles" -Scenario "File with chmod 000 permissions reports Exists=$true, IsLocked=$true" -TestBlock {
        chmod 000 $tempFile
        try {
            $res = Test-OutlookDataFileLock -Path $tempFile
            if ($res.Exists -ne $true) { throw "Expected Exists = `$true, got $($res.Exists)" }
            if ($res.IsLocked -ne $true) { throw "Expected IsLocked = `$true, got $($res.IsLocked)" }
            if ($res.ErrorMessage -notmatch "Access denied|locked") { throw "Unexpected ErrorMessage: $($res.ErrorMessage)" }
        }
        finally {
            chmod 644 $tempFile
        }
    }

    # 3.4 File with chmod 444 permissions (read-only file denies ReadWrite access)
    Assert-TestCase -Category "LockedFiles" -Scenario "Read-only file (chmod 444) reports Exists=$true, IsLocked=$true" -TestBlock {
        chmod 444 $tempFile
        try {
            $res = Test-OutlookDataFileLock -Path $tempFile
            if ($res.Exists -ne $true) { throw "Expected Exists = `$true, got $($res.Exists)" }
            if ($res.IsLocked -ne $true) { throw "Expected IsLocked = `$true, got $($res.IsLocked)" }
            if ($res.ErrorMessage -notmatch "Access denied|locked") { throw "Unexpected ErrorMessage: $($res.ErrorMessage)" }
        }
        finally {
            chmod 644 $tempFile
        }
    }
}
finally {
    chmod 644 $tempFile
    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------------
# CATEGORY 4: UNLOCKED PST/OST FILES (Exists = $true, IsLocked = $false)
# ------------------------------------------------------------------------------
Write-Host "`n-- Executing Category 4: Unlocked PST/OST Files --" -ForegroundColor Yellow

$pstTestDir = Join-Path ([System.IO.Path]::GetTempPath()) ("stress_pst_" + [System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $pstTestDir -Force | Out-Null

try {
    # 4.1 Empty PST file (0 bytes)
    $emptyPst = Join-Path $pstTestDir "empty.pst"
    [System.IO.File]::WriteAllBytes($emptyPst, [byte[]]@())
    Assert-TestCase -Category "UnlockedFiles" -Scenario "Empty 0-byte PST reports Exists=$true, IsLocked=$false" -TestBlock {
        $res = Test-OutlookDataFileLock -Path $emptyPst
        if ($res.Exists -ne $true) { throw "Expected Exists = `$true, got $($res.Exists)" }
        if ($res.IsLocked -ne $false) { throw "Expected IsLocked = `$false, got $($res.IsLocked)" }
        if ($null -ne $res.ErrorMessage) { throw "Expected ErrorMessage = `$null, got $($res.ErrorMessage)" }
    }

    # 4.2 Simulated binary PST header file
    $binaryPst = Join-Path $pstTestDir "archive_header.pst"
    $dummyHeader = [byte[]]@(0x21, 0x42, 0x44, 0x4E, 0x00, 0x01, 0x02, 0x03) # !BDN magic
    [System.IO.File]::WriteAllBytes($binaryPst, $dummyHeader)
    Assert-TestCase -Category "UnlockedFiles" -Scenario "Simulated binary header PST reports Exists=$true, IsLocked=$false" -TestBlock {
        $res = Test-OutlookDataFileLock -Path $binaryPst
        if ($res.Exists -ne $true) { throw "Expected Exists = `$true, got $($res.Exists)" }
        if ($res.IsLocked -ne $false) { throw "Expected IsLocked = `$false, got $($res.IsLocked)" }
        if ($null -ne $res.ErrorMessage) { throw "Expected ErrorMessage = `$null, got $($res.ErrorMessage)" }
    }

    # 4.3 Multi-megabyte file (10 MB payload)
    $largeOst = Join-Path $pstTestDir "large_mailbox.ost"
    $tenMb = [byte[]]::new(10 * 1024 * 1024)
    [System.IO.File]::WriteAllBytes($largeOst, $tenMb)
    Assert-TestCase -Category "UnlockedFiles" -Scenario "10 MB OST file reports Exists=$true, IsLocked=$false" -TestBlock {
        $res = Test-OutlookDataFileLock -Path $largeOst
        if ($res.Exists -ne $true) { throw "Expected Exists = `$true, got $($res.Exists)" }
        if ($res.IsLocked -ne $false) { throw "Expected IsLocked = `$false, got $($res.IsLocked)" }
        if ($null -ne $res.ErrorMessage) { throw "Expected ErrorMessage = `$null, got $($res.ErrorMessage)" }
    }

    # 4.4 File with spaces in path
    $spacedPst = Join-Path $pstTestDir "Outlook Data File (Archived).pst"
    [System.IO.File]::WriteAllBytes($spacedPst, [byte[]]@(0x01, 0x02))
    Assert-TestCase -Category "UnlockedFiles" -Scenario "PST with spaces in path reports Exists=$true, IsLocked=$false" -TestBlock {
        $res = Test-OutlookDataFileLock -Path $spacedPst
        if ($res.Exists -ne $true) { throw "Expected Exists = `$true, got $($res.Exists)" }
        if ($res.IsLocked -ne $false) { throw "Expected IsLocked = `$false, got $($res.IsLocked)" }
        if ($null -ne $res.ErrorMessage) { throw "Expected ErrorMessage = `$null, got $($res.ErrorMessage)" }
    }

    # 4.5 Immediate write verification (file handle released cleanly)
    Assert-TestCase -Category "UnlockedFiles" -Scenario "Releases file handle cleanly allowing immediate subsequent write" -TestBlock {
        $res = Test-OutlookDataFileLock -Path $binaryPst
        if ($res.IsLocked -ne $false) { throw "Expected IsLocked = `$false" }
        # Attempt write immediately
        [System.IO.File]::AppendAllText($binaryPst, "Appended verify token")
        $readBack = [System.IO.File]::ReadAllText($binaryPst)
        if ($readBack -notmatch "Appended verify token") { throw "Failed to append after lock test" }
    }

    # 4.6 Sequential stress loop (100 rapid lock-probe iterations)
    Assert-TestCase -Category "UnlockedFiles" -Scenario "100 rapid sequential lock-probes without handle leak or failure" -TestBlock {
        for ($i = 1; $i -le 100; $i++) {
            $res = Test-OutlookDataFileLock -Path $emptyPst
            if ($res.IsLocked -ne $false -or $res.Exists -ne $true) {
                throw "Iteration $i failed: Exists=$($res.Exists), IsLocked=$($res.IsLocked)"
            }
        }
    }
}
finally {
    Remove-Item -LiteralPath $pstTestDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------------
# SUMMARY & EXIT
# ------------------------------------------------------------------------------
Write-Host "`n================================================================================" -ForegroundColor Cyan
Write-Host "                       STRESS TEST EXECUTION SUMMARY                            " -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan

$passed = ($testResults | Where-Object { $_.Status -eq 'PASS' }).Count
$failed = ($testResults | Where-Object { $_.Status -eq 'FAIL' }).Count
$total = $testResults.Count

Write-Host "  Total Tests Executed : $total"
Write-Host "  Passed               : $passed" -ForegroundColor Green
if ($failed -gt 0) {
    Write-Host "  Failed               : $failed" -ForegroundColor Red
    Write-Host "================================================================================" -ForegroundColor Cyan
    exit 1
}
else {
    Write-Host "  Failed               : 0" -ForegroundColor Green
    Write-Host "================================================================================" -ForegroundColor Cyan
    Write-Host "[+] ALL 24 STRESS SCENARIOS PASSED WITH ZERO DEFECTS" -ForegroundColor Green
    exit 0
}
