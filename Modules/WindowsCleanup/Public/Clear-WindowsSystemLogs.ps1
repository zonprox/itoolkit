<#
.SYNOPSIS
    Purges Windows error reports, memory crash dumps, and archived servicing logs.
.DESCRIPTION
    Safely cleans Windows Error Reporting (WER) queue and archive files, user crash dumps,
    kernel memory dumps (MEMORY.DMP, Minidump), and archived CBS/DISM servicing logs.
    Strictly preserves active diagnostic logs (CBS.log and dism.log) and skips locked files.
.PARAMETER IncludeMemoryDumps
    Purges MEMORY.DMP, Minidump files, and LiveKernelReports.
.PARAMETER IncludeErrorReporting
    Purges WER ReportArchive, ReportQueue, Temp, and user CrashDumps.
.PARAMETER IncludeComponentLogs
    Purges archived CBS logs (CbsPersist_*.log, *.cab) and archived DISM logs (*.bak).
    Active CBS.log and active dism.log are strictly preserved.
.OUTPUTS
    [PSCustomObject] Containing Target, Path, ReclaimedBytes, ItemCount, SkippedCount, Status,
    Success, ErrorMessage.
#>
function Clear-WindowsSystemLogs {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [Alias('IncludeMemoryDump')]
        [switch]$IncludeMemoryDumps,

        [Parameter(Mandatory = $false)]
        [Alias('IncludeWerDumps')]
        [switch]$IncludeErrorReporting,

        [Parameter(Mandatory = $false)]
        [Alias('IncludeArchivedCbs')]
        [switch]$IncludeComponentLogs
    )

    process {
        # 1. Elevation check
        $isAdmin = $true
        if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
            $isAdmin = Test-IsAdmin
        }
        else {
            try {
                $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
                $principal = [Security.Principal.WindowsPrincipal]$identity
                $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            }
            catch {
                $isAdmin = $false
            }
        }

        if (-not $isAdmin) {
            Write-Warning "Administrative privileges are recommended to purge system-level crash dumps and archived logs."
        }

        # 2. Determine Scope (Default to all if none explicitly requested)
        $cleanMemDumps = $IncludeMemoryDumps
        $cleanWer = $IncludeErrorReporting
        $cleanCompLogs = $IncludeComponentLogs

        if (-not $IncludeMemoryDumps -and -not $IncludeErrorReporting -and -not $IncludeComponentLogs) {
            $cleanMemDumps = $true
            $cleanWer = $true
            $cleanCompLogs = $true
        }

        $sysRoot = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
        $progData = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
        $localApp = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { 'C:\Users\Default\AppData\Local' }

        $candidateFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        $candidateDirs = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()

        # 3. Collect Memory Dump Targets
        if ($cleanMemDumps) {
            $memDumpFile = Join-Path $sysRoot 'MEMORY.DMP'
            if (Test-Path -LiteralPath $memDumpFile) {
                $f = Get-Item -LiteralPath $memDumpFile -Force -ErrorAction SilentlyContinue
                if ($null -ne $f -and -not $f.PSIsContainer) { $candidateFiles.Add($f) }
            }

            $miniDumpDir = Join-Path $sysRoot 'Minidump'
            if (Test-Path -LiteralPath $miniDumpDir) {
                $mFiles = Get-ChildItem -LiteralPath $miniDumpDir -Filter '*.dmp' -File -Force -ErrorAction SilentlyContinue
                if ($null -ne $mFiles) { foreach ($mf in $mFiles) { $candidateFiles.Add($mf) } }
            }

            $liveKernelDir = Join-Path $sysRoot 'LiveKernelReports'
            if (Test-Path -LiteralPath $liveKernelDir) {
                $lkFiles = Get-ChildItem -LiteralPath $liveKernelDir -Filter '*.dmp' -Recurse -File -Force -ErrorAction SilentlyContinue
                if ($null -ne $lkFiles) { foreach ($lkf in $lkFiles) { $candidateFiles.Add($lkf) } }
            }
        }

        # 4. Collect Error Reporting (WER) Targets
        if ($cleanWer) {
            $userCrashDir = Join-Path $localApp 'CrashDumps'
            if (Test-Path -LiteralPath $userCrashDir) {
                $cdFiles = Get-ChildItem -LiteralPath $userCrashDir -Filter '*.dmp' -File -Force -ErrorAction SilentlyContinue
                if ($null -ne $cdFiles) { foreach ($cdf in $cdFiles) { $candidateFiles.Add($cdf) } }
            }

            $werPaths = @(
                (Join-Path $progData 'Microsoft\Windows\WER\ReportArchive'),
                (Join-Path $progData 'Microsoft\Windows\WER\ReportQueue'),
                (Join-Path $progData 'Microsoft\Windows\WER\Temp'),
                (Join-Path $localApp 'Microsoft\Windows\WER\ReportArchive'),
                (Join-Path $localApp 'Microsoft\Windows\WER\ReportQueue')
            )

            foreach ($wp in $werPaths) {
                if (Test-Path -LiteralPath $wp) {
                    $wItems = Get-ChildItem -LiteralPath $wp -Recurse -File -Force -ErrorAction SilentlyContinue
                    if ($null -ne $wItems) { foreach ($wi in $wItems) { $candidateFiles.Add($wi) } }
                }
            }
        }

        # 5. Collect Component Servicing Archived Logs (Strictly Exclude Active CBS.log and dism.log)
        if ($cleanCompLogs) {
            $cbsLogDir = Join-Path $sysRoot 'Logs\CBS'
            if (Test-Path -LiteralPath $cbsLogDir) {
                # Only archived persist logs and cabs
                $cbsArchived = Get-ChildItem -LiteralPath $cbsLogDir -Force -ErrorAction SilentlyContinue | Where-Object {
                    -not $_.PSIsContainer -and (
                        $_.Name -like 'CbsPersist_*.log' -or
                        $_.Name -like 'CbsPersist_*.cab'
                    ) -and $_.Name -ne 'CBS.log'
                }
                if ($null -ne $cbsArchived) { foreach ($cf in $cbsArchived) { $candidateFiles.Add($cf) } }
            }

            $dismLogDir = Join-Path $sysRoot 'Logs\DISM'
            if (Test-Path -LiteralPath $dismLogDir) {
                $dismArchived = Get-ChildItem -LiteralPath $dismLogDir -Force -ErrorAction SilentlyContinue | Where-Object {
                    -not $_.PSIsContainer -and (
                        $_.Name -like 'dism.log.*' -or
                        $_.Name -like '*.bak'
                    ) -and $_.Name -ne 'dism.log'
                }
                if ($null -ne $dismArchived) { foreach ($df in $dismArchived) { $candidateFiles.Add($df) } }
            }
        }

        $summaryTargetDesc = 'WER;MemoryDumps;ArchivedCBS'

        # 6. WhatIf Space Analysis
        if (-not $PSCmdlet.ShouldProcess($summaryTargetDesc, "Purge crash dumps, WER reports, and archived servicing logs")) {
            $projectedBytes = [int64]0
            $projectedItems = $candidateFiles.Count

            foreach ($f in $candidateFiles) {
                $projectedBytes += $f.Length
            }

            Write-Verbose "Simulation mode (-WhatIf): Projected $projectedBytes bytes across $projectedItems files."
            return [PSCustomObject]@{
                Target         = 'SystemLogs'
                Path           = $summaryTargetDesc
                ReclaimedBytes = $projectedBytes
                ItemCount      = $projectedItems
                SkippedCount   = 0
                Status         = 'Simulated - WhatIf'
                Success        = $true
                ErrorMessage   = $null
            }
        }

        # 7. Execute Deletion Safely
        $reclaimedBytes = [int64]0
        $itemCount = 0
        $skippedCount = 0

        foreach ($fileItem in $candidateFiles) {
            # Extra safety check against active logs
            if ($fileItem.Name -eq 'CBS.log' -or $fileItem.Name -eq 'dism.log') {
                Write-Verbose "Preserving critical active log: $($fileItem.FullName)"
                $skippedCount++
                continue
            }

            try {
                $len = [int64]$fileItem.Length
                Remove-Item -LiteralPath $fileItem.FullName -Force -ErrorAction Stop
                $reclaimedBytes += $len
                $itemCount++
            }
            catch [System.IO.IOException] {
                Write-Verbose "Skipped locked log/dump file: $($fileItem.FullName)"
                $skippedCount++
            }
            catch [System.UnauthorizedAccessException] {
                Write-Verbose "Access denied for log/dump file: $($fileItem.FullName)"
                $skippedCount++
            }
            catch {
                Write-Verbose "Error removing log/dump file: $($fileItem.FullName) - $($_.Exception.Message)"
                $skippedCount++
            }
        }

        $statusMsg = if ($skippedCount -gt 0) {
            "Completed with $skippedCount skipped item(s)"
        }
        else {
            "Success"
        }

        return [PSCustomObject]@{
            Target         = 'SystemLogs'
            Path           = $summaryTargetDesc
            ReclaimedBytes = [int64]$reclaimedBytes
            ItemCount      = [int]$itemCount
            SkippedCount   = [int]$skippedCount
            Status         = $statusMsg
            Success        = $true
            ErrorMessage   = $null
        }
    }
}
