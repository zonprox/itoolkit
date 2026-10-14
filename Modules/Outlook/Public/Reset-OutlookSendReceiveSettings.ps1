function Reset-OutlookSendReceiveSettings {
<#
.SYNOPSIS
    Resets corrupted Outlook Send/Receive group settings (.srs) with automated backup.
.DESCRIPTION
    Locates and backs up %APPDATA%\Microsoft\Outlook\<ProfileName>.srs, removing
    the corrupted file so Outlook auto-recreates default Send/Receive groups on next launch.
.PARAMETER ProfileName
    Target Outlook profile name. Defaults to active profile or 'Outlook'.
.PARAMETER Backup
    Creates a timestamped backup before deletion. Default is $true.
.PARAMETER Force
    Terminates running OUTLOOK.EXE instances to release file locks.
.OUTPUTS
    [PSCustomObject]@{ Status, ProfileName, TargetFile, BackupFile, RecreatedNotice, ErrorMessage }
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$ProfileName,

        [Parameter(Mandatory = $false)]
        [switch]$Backup = $true,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        # 1. Resolve Profile Name
        $targetProfile = $ProfileName
        if ([string]::IsNullOrWhiteSpace($targetProfile)) {
            if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
                try {
                    $ctx = Get-OutlookSystemContext
                    if ($null -ne $ctx -and -not [string]::IsNullOrWhiteSpace($ctx.DefaultProfile) -and $ctx.DefaultProfile -ne 'None') {
                        $targetProfile = $ctx.DefaultProfile
                    }
                } catch { $null = $_ }
            }
        }
        if ([string]::IsNullOrWhiteSpace($targetProfile)) { $targetProfile = 'Outlook' }

        # 2. Process Check
        $isRunning = [bool](Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
        if ($isRunning) {
            if ($Force) {
                if (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                    $null = Stop-ToolkitProcess -ProcessName 'OUTLOOK' -TimeoutSeconds 5 -Force
                } else {
                    Stop-Process -Name 'OUTLOOK' -Force -ErrorAction SilentlyContinue
                }
                Start-Sleep -Milliseconds 500
            } else {
                $warnMsg = "Outlook is currently running and holding locks on Send/Receive configuration. Close Outlook or specify -Force."
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message $warnMsg -Level 'WARN' -Component 'Outlook:SRS'
                }
                return [PSCustomObject]@{
                    Status          = 'Warning'
                    ProfileName     = $targetProfile
                    TargetFile      = $null
                    BackupFile      = $null
                    RecreatedNotice = $null
                    ErrorMessage    = $warnMsg
                }
            }
        }

        $appData = if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
            $env:APPDATA
        } elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            Join-Path -Path $env:USERPROFILE -ChildPath 'AppData\Roaming'
        } else {
            $baseDir = if ($env:HOME) { $env:HOME } else { [System.IO.Path]::GetTempPath() }
            Join-Path -Path $baseDir -ChildPath 'AppData/Roaming'
        }
        $srsDir = Join-Path -Path $appData -ChildPath 'Microsoft\Outlook'
        $srsFile = Join-Path -Path $srsDir -ChildPath "$targetProfile.srs"

        if (-not (Test-Path -LiteralPath $srsFile)) {
            # Search for any *.srs in directory if profile-specific not found
            $anySrs = Get-ChildItem -Path $srsDir -Filter '*.srs' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $anySrs) {
                $srsFile = $anySrs.FullName
            } else {
                return [PSCustomObject]@{
                    Status          = 'Success'
                    ProfileName     = $targetProfile
                    TargetFile      = $srsFile
                    BackupFile      = $null
                    RecreatedNotice = 'No .srs configuration file found on disk; defaults active.'
                    ErrorMessage    = $null
                }
            }
        }

        # 4. SupportsShouldProcess Check
        if (-not $PSCmdlet.ShouldProcess($srsFile, "Reset Send/Receive settings file")) {
            return [PSCustomObject]@{
                Status          = 'Success'
                ProfileName     = $targetProfile
                TargetFile      = $srsFile
                BackupFile      = '[Simulated - WhatIf]'
                RecreatedNotice = 'Outlook will auto-recreate .srs file on next launch.'
                ErrorMessage    = $null
            }
        }

        # 5. Backup & Removal
        $backupFile = $null
        if ($Backup) {
            $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
            $backupFile = "$srsFile.bak_$ts"
            try {
                Copy-Item -LiteralPath $srsFile -Destination $backupFile -Force -ErrorAction Stop
            } catch {
                Write-Verbose "Backup failed: $($_.Exception.Message)"
            }
        }

        try {
            Remove-Item -LiteralPath $srsFile -Force -ErrorAction Stop
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Send/Receive settings file '$srsFile' successfully reset. Backup: '$backupFile'." -Level 'SUCCESS' -Component 'Outlook:SRS'
            }
        } catch {
            return [PSCustomObject]@{
                Status          = 'Warning'
                ProfileName     = $targetProfile
                TargetFile      = $srsFile
                BackupFile      = $backupFile
                RecreatedNotice = $null
                ErrorMessage    = $_.Exception.Message
            }
        }

        return [PSCustomObject]@{
            Status          = 'Success'
            ProfileName     = $targetProfile
            TargetFile      = $srsFile
            BackupFile      = $backupFile
            RecreatedNotice = 'Outlook will automatically regenerate default Send/Receive settings upon next startup.'
            ErrorMessage    = $null
        }
    }
}
