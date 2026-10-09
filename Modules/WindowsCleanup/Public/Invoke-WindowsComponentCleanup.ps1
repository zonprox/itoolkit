<#
.SYNOPSIS
    Cleans up superseded Windows Component Store (WinSxS) packages using official DISM servicing.
.DESCRIPTION
    Executes DISM.exe /Online /Cleanup-Image /StartComponentCleanup with optional /ResetBase
    switch to remove superseded components and reclaim disk space safely.
    Strictly uses Microsoft-supported servicing commands and never performs raw folder deletions.
.PARAMETER ResetBase
    When specified, appends /ResetBase to DISM arguments.
    WARNING: Removes all superseded versions of every component in the component store.
    All installed Windows updates become baseline and CANNOT be uninstalled after this operation.
.PARAMETER AnalyzeOnly
    When specified, runs /AnalyzeComponentStore to inspect reclaimable space without cleaning.
.OUTPUTS
    [PSCustomObject] Containing Target, Path, ReclaimedBytes, ItemCount, SkippedCount, Status,
    Success, ErrorMessage, ExitCode, ResetBaseUsed.
#>
function Invoke-WindowsComponentCleanup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$ResetBase,

        [Parameter(Mandatory = $false)]
        [switch]$AnalyzeOnly
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
            Write-Warning "Administrative privileges are required for component store cleanup."
        }

        # 2. Build argument list
        $argList = [System.Collections.Generic.List[string]]::new()
        $argList.Add('/Online')
        $argList.Add('/Cleanup-Image')

        $targetActionDesc = 'StartComponentCleanup'
        if ($AnalyzeOnly) {
            $argList.Add('/AnalyzeComponentStore')
            $targetActionDesc = 'AnalyzeComponentStore'
        }
        else {
            $argList.Add('/StartComponentCleanup')
            if ($ResetBase) {
                $argList.Add('/ResetBase')
                $targetActionDesc = 'StartComponentCleanup with /ResetBase'
                Write-Warning "WARNING: /ResetBase removes all superseded component versions. Once completed, all installed Windows updates become baseline and CANNOT be uninstalled."
            }
        }

        $targetPath = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'WinSxS' } else { 'C:\Windows\WinSxS' }

        # 3. ShouldProcess / WhatIf check
        $operationDesc = "Execute DISM.exe $($argList -join ' ')"
        if (-not $PSCmdlet.ShouldProcess("Component Store (WinSxS)", $operationDesc)) {
            Write-Verbose "Simulation mode (-WhatIf): $operationDesc"
            return [PSCustomObject]@{
                Target         = 'ComponentStore'
                Path           = $targetPath
                ReclaimedBytes = [int64]0
                ItemCount      = 0
                SkippedCount   = 0
                Status         = 'Simulated - WhatIf'
                Success        = $true
                ErrorMessage   = $null
                ExitCode       = 0
                ResetBaseUsed  = [bool]$ResetBase
            }
        }

        # 4. Resolve DISM executable
        $dismExe = 'DISM.exe'
        if ($env:SystemRoot) {
            $dismCandidate = Join-Path -Path $env:SystemRoot -ChildPath 'System32\DISM.exe'
            if (Test-Path -LiteralPath $dismCandidate) {
                $dismExe = $dismCandidate
            }
        }

        # 5. Execute DISM
        $tempOut = [System.IO.Path]::GetTempFileName()
        $tempErr = [System.IO.Path]::GetTempFileName()
        $exitCode = 0
        $outputLines = [System.Collections.Generic.List[string]]::new()
        $executionError = $null

        try {
            Write-Verbose "Executing: $dismExe $($argList -join ' ')"
            $proc = Start-Process -FilePath $dismExe -ArgumentList $argList -RedirectStandardOutput $tempOut -RedirectStandardError $tempErr -Wait -PassThru -NoNewWindow -ErrorAction Stop
            if ($null -ne $proc -and $null -ne $proc.ExitCode) {
                $exitCode = $proc.ExitCode
            }

            if (Test-Path -LiteralPath $tempOut) {
                $lines = Get-Content -LiteralPath $tempOut -ErrorAction SilentlyContinue
                if ($null -ne $lines) {
                    foreach ($line in $lines) {
                        $outputLines.Add($line)
                    }
                }
            }

            if (Test-Path -LiteralPath $tempErr) {
                $errLines = Get-Content -LiteralPath $tempErr -ErrorAction SilentlyContinue
                if ($null -ne $errLines) {
                    foreach ($errLine in $errLines) {
                        $outputLines.Add($errLine)
                    }
                }
            }
        }
        catch {
            Write-Warning "DISM execution error: $($_.Exception.Message)"
            $exitCode = 1
            $executionError = $_.Exception.Message
            $outputLines.Add("Error: $($_.Exception.Message)")
        }
        finally {
            Remove-Item -LiteralPath $tempOut, $tempErr -Force -ErrorAction SilentlyContinue
        }

        # 6. Evaluate Result
        $status = ''
        $success = $false
        if ($exitCode -eq 0) {
            $status = 'Operation completed successfully'
            $success = $true
        }
        elseif ($exitCode -eq 3010) {
            $status = 'Operation completed successfully. A system restart is required.'
            $success = $true
        }
        else {
            $status = "DISM completed with exit code $exitCode"
            $success = $false
            if ($null -eq $executionError) {
                $executionError = $status
            }
        }

        return [PSCustomObject]@{
            Target         = 'ComponentStore'
            Path           = $targetPath
            ReclaimedBytes = [int64]0
            ItemCount      = 0
            SkippedCount   = 0
            Status         = $status
            Success        = $success
            ErrorMessage   = $executionError
            ExitCode       = $exitCode
            ResetBaseUsed  = [bool]$ResetBase
        }
    }
}
