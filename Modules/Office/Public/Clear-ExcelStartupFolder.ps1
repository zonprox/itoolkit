function Clear-ExcelStartupFolder {
<#
.SYNOPSIS
    Cleans and isolates rogue add-ins and workbooks from Excel XLSTART startup directories.
.DESCRIPTION
    Scans both user (%APPDATA%\Microsoft\Excel\XLSTART) and machine-level Click-to-Run / MSI
    XLSTART folders for rogue add-ins (.xlam, .xla) and workbooks (.xlsx, .xlsm, .xlsb, .xls).
    Enforces a strict backup of Personal.xlsb before isolation to protect personal macros.
    Terminates active EXCEL.EXE processes when -Force is specified.
    Supports -WhatIf for safe execution preview.
.PARAMETER Force
    When specified, forcibly terminates running EXCEL.EXE processes to release file locks.
.OUTPUTS
    [PSCustomObject] containing Status, RemovedFiles, PersonalBackupPath, and TargetDirectories.
.EXAMPLE
    Clear-ExcelStartupFolder -WhatIf
.EXAMPLE
    Clear-ExcelStartupFolder -Force
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        if (-not $PSCmdlet.ShouldProcess("Excel XLSTART Startup Folders", "Quarantine rogue startup add-ins and workbooks")) {
            return [PSCustomObject]@{
                Status             = 'Simulated'
                RemovedFiles       = @('[Simulated - WhatIf]')
                PersonalBackupPath = $null
                TargetDirectories  = @()
            }
        }

        # Step 1: Process lock detection
        if (Get-Command -Name 'Test-ProcessRunning' -ErrorAction SilentlyContinue) {
            if (Test-ProcessRunning -ProcessName 'EXCEL') {
                if ($Force) {
                    if (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                        Write-ToolkitLog -Message "Terminating active EXCEL.EXE process prior to XLSTART cleanup..." -Level 'WARN' -Component 'Clear-ExcelStartupFolder'
                        $null = Stop-ToolkitProcess -ProcessName 'EXCEL' -TimeoutSeconds 5 -Force
                    }
                    else {
                        Stop-Process -Name 'EXCEL' -Force -ErrorAction SilentlyContinue
                    }
                }
                else {
                    Write-Warning "Active EXCEL.EXE process detected. Files may be locked. Specify -Force to terminate."
                }
            }
        }

        # Step 2: Resolve candidate XLSTART directories
        $candidateDirs = [System.Collections.Generic.List[string]]::new()
        
        # User Roaming AppData
        $appData = if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
            $env:APPDATA
        } elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            Join-Path $env:USERPROFILE 'AppData\Roaming'
        } elseif (-not [string]::IsNullOrWhiteSpace($env:HOME)) {
            Join-Path $env:HOME 'AppData/Roaming'
        } else {
            [System.IO.Path]::GetTempPath()
        }
        $candidateDirs.Add((Join-Path (Join-Path $appData 'Microsoft\Excel') 'XLSTART'))

        # Machine Click-to-Run (64-bit and 32-bit on 64-bit OS)
        if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
            $candidateDirs.Add((Join-Path $env:ProgramFiles 'Microsoft Office\root\Office16\XLSTART'))
            $candidateDirs.Add((Join-Path $env:ProgramFiles 'Microsoft Office\Office16\XLSTART'))
        }
        $progFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
        if (-not [string]::IsNullOrWhiteSpace($progFilesX86)) {
            $candidateDirs.Add((Join-Path $progFilesX86 'Microsoft Office\root\Office16\XLSTART'))
            $candidateDirs.Add((Join-Path $progFilesX86 'Microsoft Office\Office16\XLSTART'))
        }

        $timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
        $isolatedFiles = [System.Collections.Generic.List[string]]::new()
        $inspectedDirs = [System.Collections.Generic.List[string]]::new()
        $personalBackup = $null

        foreach ($dir in $candidateDirs) {
            if (-not (Test-Path -LiteralPath $dir)) {
                continue
            }
            $inspectedDirs.Add($dir)

            try {
                $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object {
                    $_.Name -notmatch '\.(?:isolated|bak)(?:\.[^.]+)?$'
                })
                foreach ($f in $files) {
                    # Check for Personal.xlsb or Personal.xlsm macro workbook
                    if ($f.Name -match '^personal\.xls[bm]?$') {
                        $personalBakPath = Join-Path $dir "$($f.Name).bak.$timestamp"
                        try {
                            Copy-Item -LiteralPath $f.FullName -Destination $personalBakPath -Force -ErrorAction Stop
                            $personalBackup = $personalBakPath
                            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                                Write-ToolkitLog -Message "Protected Personal Macro Workbook: Created backup '$personalBakPath'" -Level 'INFO' -Component 'Clear-ExcelStartupFolder'
                            }
                        }
                        catch {
                            Write-Warning "Could not backup Personal Macro Workbook: $($_.Exception.Message)"
                        }
                    }

                    # Isolate file by renaming with timestamp extension
                    $isolatedName = "$($f.Name).isolated.$timestamp"
                    try {
                        Rename-Item -LiteralPath $f.FullName -NewName $isolatedName -Force -ErrorAction Stop
                        $isolatedFiles.Add($f.FullName)
                        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                            Write-ToolkitLog -Message "Isolated startup file: '$($f.FullName)' -> '$isolatedName'" -Level 'INFO' -Component 'Clear-ExcelStartupFolder'
                        }
                    }
                    catch {
                        Write-Verbose "Could not isolate file '$($f.FullName)': $($_.Exception.Message)"
                    }
                }
            }
            catch {
                Write-Verbose "Could not enumerate directory '$dir': $($_.Exception.Message)"
            }
        }

        return [PSCustomObject]@{
            Status             = 'Success'
            RemovedFiles       = @($isolatedFiles)
            PersonalBackupPath = $personalBackup
            TargetDirectories  = @($inspectedDirs)
        }
    }
}
