function Reset-WordTemplate {
<#
.SYNOPSIS
    Resets corrupted Microsoft Word Normal.dotm global template.
.DESCRIPTION
    Safely checks for active WINWORD processes, generates a timestamped backup (.bak_yyyyMMdd_HHmmss)
    at the specified or default location, and isolates the corrupted template.
    Word automatically regenerates a clean default Normal.dotm on next startup.
.PARAMETER BackupPath
    Optional custom destination file or directory path for the template backup.
.PARAMETER Force
    Terminates running Word instances prior to template reset.
.OUTPUTS
    [PSCustomObject]@{ Status = 'Success'|'Warning'|'Skipped'; Backup = <string> }
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$BackupPath,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        $appData = if ($env:APPDATA) { $env:APPDATA }
                   elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'AppData\Roaming' }
                   else { [System.IO.Path]::GetTempPath() }
        $templatesDir = Join-Path (Join-Path $appData 'Microsoft') 'Templates'
        $normalFile = Join-Path $templatesDir 'Normal.dotm'

        # Check template existence
        if (-not (Test-Path -LiteralPath $normalFile)) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Normal.dotm not found at '$normalFile'. Clean template state already active." -Level 'INFO' -Component 'Reset-WordTemplate'
            }
            return [PSCustomObject]@{
                Status = 'Skipped'
                Backup = $null
            }
        }

        # Resolve backup destination
        $timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
        $targetBackup = $null
        if (-not [string]::IsNullOrWhiteSpace($BackupPath)) {
            $expanded = [System.Environment]::ExpandEnvironmentVariables($BackupPath.Trim())
            if ((Test-Path -LiteralPath $expanded -PathType Container) -or $expanded.EndsWith('\') -or $expanded.EndsWith('/')) {
                if (-not (Test-Path -LiteralPath $expanded)) {
                    $null = New-Item -ItemType Directory -Path $expanded -Force -ErrorAction SilentlyContinue
                }
                $targetBackup = Join-Path $expanded "Normal.dotm.bak_$timestamp"
            } else {
                $parentDir = Split-Path -Path $expanded -Parent
                if (-not [string]::IsNullOrWhiteSpace($parentDir) -and -not (Test-Path -LiteralPath $parentDir)) {
                    $null = New-Item -ItemType Directory -Path $parentDir -Force -ErrorAction SilentlyContinue
                }
                $targetBackup = $expanded
            }
        } else {
            $targetBackup = Join-Path $templatesDir "Normal.dotm.bak_$timestamp"
        }

        # WhatIf evaluation
        if (-not $PSCmdlet.ShouldProcess($normalFile, "Isolate corrupted template to '$targetBackup'")) {
            return [PSCustomObject]@{
                Status = 'Success'
                Backup = '[Simulated - WhatIf]'
            }
        }

        # Process termination check
        $wordProcs = @(Get-Process -Name 'WINWORD' -ErrorAction SilentlyContinue)
        if ($wordProcs.Count -gt 0) {
            if ($Force) {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Terminating active WINWORD process prior to template reset..." -Level 'WARN' -Component 'Reset-WordTemplate'
                }
                if (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                    $null = Stop-ToolkitProcess -ProcessName 'WINWORD' -TimeoutSeconds 5 -Force
                } else {
                    Stop-Process -Name 'WINWORD' -Force -ErrorAction SilentlyContinue
                }
            } else {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Cannot reset Normal.dotm while Word is running. Close Word or specify -Force." -Level 'WARN' -Component 'Reset-WordTemplate'
                }
                return [PSCustomObject]@{
                    Status = 'Warning'
                    Backup = $null
                }
            }
        }

        # Isolate template file
        try {
            Move-Item -LiteralPath $normalFile -Destination $targetBackup -Force -ErrorAction Stop
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Successfully isolated Normal.dotm to '$targetBackup'." -Level 'INFO' -Component 'Reset-WordTemplate'
            }
            return [PSCustomObject]@{
                Status = 'Success'
                Backup = $targetBackup
            }
        }
        catch {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Failed to isolate Normal.dotm: $($_.Exception.Message)" -Level 'ERROR' -Component 'Reset-WordTemplate'
            }
            return [PSCustomObject]@{
                Status = 'Warning'
                Backup = $null
            }
        }
    }
}
