function Reset-WordStartupAddin {
<#
.SYNOPSIS
    Isolates and disables startup template add-ins from Word STARTUP folders.
.DESCRIPTION
    Scans user (%APPDATA%\Microsoft\Word\STARTUP) and system Office STARTUP directories.
    Renames active add-in templates (.dot, .dotm, .wll, .dotx) to .disabled to prevent Word launch crashes.
.PARAMETER DisableAll
    When specified, isolates all active add-ins in all discovered STARTUP directories.
.PARAMETER Force
    Terminates active Word processes before renaming files.
.OUTPUTS
    [PSCustomObject]@{ Status = 'Success'|'Skipped'; AddinsIsolated = <int> }
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$DisableAll,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        # Discover candidate STARTUP directories
        $appData = if ($env:APPDATA) { $env:APPDATA }
                   elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'AppData\Roaming' }
                   elseif ($env:HOME) { Join-Path $env:HOME 'AppData/Roaming' }
                   else { [System.IO.Path]::GetTempPath() }

        $candidateDirs = [System.Collections.Generic.List[string]]::new()
        $candidateDirs.Add((Join-Path (Join-Path $appData 'Microsoft') 'Word\STARTUP'))

        if ($env:ProgramFiles) {
            $candidateDirs.Add((Join-Path $env:ProgramFiles 'Microsoft Office\root\Office16\STARTUP'))
            $candidateDirs.Add((Join-Path $env:ProgramFiles 'Microsoft Office\Office16\STARTUP'))
        }
        $progFilesX86 = ${env:ProgramFiles(x86)}
        if ($progFilesX86) {
            $candidateDirs.Add((Join-Path $progFilesX86 'Microsoft Office\root\Office16\STARTUP'))
            $candidateDirs.Add((Join-Path $progFilesX86 'Microsoft Office\Office16\STARTUP'))
        }

        # Enumerate active add-in files
        $validExts = @('.dotm', '.dot', '.wll', '.dotx')
        $filesToDisable = [System.Collections.Generic.List[psobject]]::new()

        foreach ($dir in $candidateDirs) {
            if (Test-Path -LiteralPath $dir) {
                try {
                    $items = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)
                    foreach ($item in $items) {
                        if ($item.Extension -in $validExts -and $item.Name -notmatch '\.disabled$') {
                            $filesToDisable.Add($item)
                        }
                    }
                } catch {
                    Write-Verbose "Could not scan directory '$dir': $($_.Exception.Message)"
                }
            }
        }

        if ($filesToDisable.Count -eq 0) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "No active Word startup add-ins found in STARTUP folders." -Level 'INFO' -Component 'Reset-WordStartupAddin'
            }
            return [PSCustomObject]@{
                Status         = 'Skipped'
                AddinsIsolated = 0
            }
        }

        # WhatIf check
        if (-not $PSCmdlet.ShouldProcess("Word STARTUP Folders", "Isolate $($filesToDisable.Count) active startup add-in(s)")) {
            return [PSCustomObject]@{
                Status         = 'Success'
                AddinsIsolated = $filesToDisable.Count
            }
        }

        # Pre-flight Word process termination
        $wordProcs = @(Get-Process -Name 'WINWORD' -ErrorAction SilentlyContinue)
        if ($wordProcs.Count -gt 0) {
            if ($Force) {
                if (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                    $null = Stop-ToolkitProcess -ProcessName 'WINWORD' -TimeoutSeconds 5 -Force
                } else {
                    Stop-Process -Name 'WINWORD' -Force -ErrorAction SilentlyContinue
                }
            } else {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Cannot isolate add-ins while Word is running. Close Word or pass -Force." -Level 'WARN' -Component 'Reset-WordStartupAddin'
                }
                return [PSCustomObject]@{
                    Status         = 'Skipped'
                    AddinsIsolated = 0
                }
            }
        }

        # Isolate add-ins
        $isolatedCount = 0
        foreach ($file in $filesToDisable) {
            $disabledName = "$($file.Name).disabled"
            try {
                Rename-Item -LiteralPath $file.FullName -NewName $disabledName -Force -ErrorAction Stop
                $isolatedCount++
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Isolated Word add-in: '$($file.Name)' -> '$disabledName'" -Level 'INFO' -Component 'Reset-WordStartupAddin'
                }
            }
            catch [System.UnauthorizedAccessException] {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Insufficient permissions to isolate system add-in '$($file.FullName)'. Run elevated." -Level 'WARN' -Component 'Reset-WordStartupAddin'
                }
            }
            catch {
                Write-Verbose "Could not rename '$($file.FullName)': $($_.Exception.Message)"
            }
        }

        return [PSCustomObject]@{
            Status         = if ($isolatedCount -gt 0) { 'Success' } else { 'Skipped' }
            AddinsIsolated = $isolatedCount
        }
    }
}
