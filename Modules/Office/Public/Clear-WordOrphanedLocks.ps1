function Clear-WordOrphanedLocks {
<#
.SYNOPSIS
    Safely purges orphaned Word lock files (~$*.docx) and corrupt AutoRecover files (*.asd).
.DESCRIPTION
    Scans target paths for temporary owner lock files and AutoRecover artifacts.
    Uses .NET FileStream non-shared open probing to ensure no active process holds the file before deletion.
.PARAMETER Path
    Optional directory path to scan. Defaults to Documents, Word AutoRecover, and Desktop.
.PARAMETER Force
    Deletes unlocked orphan files even if WINWORD processes are running.
.OUTPUTS
    [PSCustomObject]@{ Status = 'Success'; CleanedFiles = <string[]> }
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        $searchDirs = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($Path)) {
            $expanded = [System.Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"').Trim("'"))
            if (Test-Path -LiteralPath $expanded) {
                $searchDirs.Add($expanded)
            }
        } else {
            $docs = [System.Environment]::GetFolderPath('MyDocuments')
            if ($docs -and (Test-Path -LiteralPath $docs)) { $searchDirs.Add($docs) }

            $appData = if ($env:APPDATA) { $env:APPDATA } elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'AppData\Roaming' } else { $null }
            if ($appData) {
                $wordDir = Join-Path (Join-Path $appData 'Microsoft') 'Word'
                if (Test-Path -LiteralPath $wordDir) { $searchDirs.Add($wordDir) }
            }

            $desktop = [System.Environment]::GetFolderPath('Desktop')
            if ($desktop -and (Test-Path -LiteralPath $desktop)) { $searchDirs.Add($desktop) }
        }

        if ($searchDirs.Count -eq 0) {
            return [PSCustomObject]@{
                Status       = 'Success'
                CleanedFiles = @()
            }
        }

        # WhatIf evaluation
        if (-not $PSCmdlet.ShouldProcess("File System", "Scan and purge orphaned Word locks in $($searchDirs.Count) directory(ies)")) {
            return [PSCustomObject]@{
                Status       = 'Success'
                CleanedFiles = @('[Simulated - WhatIf]')
            }
        }

        # Check if Word is running
        $wordProcs = @(Get-Process -Name 'WINWORD' -ErrorAction SilentlyContinue)
        if ($wordProcs.Count -gt 0 -and -not $Force) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Word is actively running. Only strictly unheld orphaned lock files will be purged. Use -Force to override." -Level 'INFO' -Component 'Clear-WordOrphanedLocks'
            }
        }

        $cleanedFiles = [System.Collections.Generic.List[string]]::new()
        $patterns = @('~$*.docx', '~$*.doc', '~$*.dotm', '~$*.dot', '*.asd')

        foreach ($dir in $searchDirs) {
            foreach ($pattern in $patterns) {
                try {
                    $found = @(Get-ChildItem -Path $dir -Filter $pattern -File -Recurse -Force -ErrorAction SilentlyContinue)
                    foreach ($f in $found) {
                        # Probe exclusive open lock
                        $isLocked = $false
                        try {
                            $fi = [System.IO.FileInfo]::new($f.FullName)
                            $stream = $fi.Open([System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                            $stream.Close()
                            $stream.Dispose()
                        }
                        catch {
                            $isLocked = $true
                        }

                        if (-not $isLocked) {
                            try {
                                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                                $cleanedFiles.Add($f.FullName)
                                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                                    Write-ToolkitLog -Message "Deleted orphaned Word lock file: '$($f.FullName)'" -Level 'INFO' -Component 'Clear-WordOrphanedLocks'
                                }
                            }
                            catch {
                                Write-Verbose "Failed to remove lock file '$($f.FullName)': $($_.Exception.Message)"
                            }
                        } else {
                            Write-Verbose "Skipped file locked by active process: '$($f.FullName)'"
                        }
                    }
                } catch {
                    Write-Verbose "Error searching directory '$dir' for '$pattern': $($_.Exception.Message)"
                }
            }
        }

        return [PSCustomObject]@{
            Status       = 'Success'
            CleanedFiles = @($cleanedFiles)
        }
    }
}
