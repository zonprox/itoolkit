function Reset-OutlookNavigationPane {
<#
.SYNOPSIS
    Resets corrupted Outlook navigation pane configurations across registry and profile XML views.
.DESCRIPTION
    Provides native pure-PowerShell equivalent of 'outlook.exe /resetnavpane'.
    Purges HKCU:\Software\Microsoft\Office\16.0\Outlook\Preferences\NavPane and
    quarantines %APPDATA%\Microsoft\Outlook\<ProfileName>.xml with timestamped backup.
.PARAMETER ProfileName
    Target Outlook profile name. Defaults to active profile or 'Outlook'.
.PARAMETER Force
    Terminates running OUTLOOK.EXE instances to release locks.
.OUTPUTS
    [PSCustomObject]@{ Status, ProfileName, RegCleared, XmlRemoved, XmlBackupFile, ErrorMessage }
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$ProfileName,

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
                $warnMsg = "Outlook is currently running. Close Outlook or specify -Force before resetting navigation pane."
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message $warnMsg -Level 'WARN' -Component 'Outlook:NavPane'
                }
                return [PSCustomObject]@{
                    Status        = 'Warning'
                    ProfileName   = $targetProfile
                    RegCleared    = $false
                    XmlRemoved    = $false
                    XmlBackupFile = $null
                    ErrorMessage  = $warnMsg
                }
            }
        }

        # 3. SupportsShouldProcess Check
        if (-not $PSCmdlet.ShouldProcess("NavPane ($targetProfile)", "Reset Navigation Pane registry and XML view definitions")) {
            return [PSCustomObject]@{
                Status        = 'Success'
                ProfileName   = $targetProfile
                RegCleared    = $false
                XmlRemoved    = $false
                XmlBackupFile = '[Simulated - WhatIf]'
                ErrorMessage  = $null
            }
        }

        # 4. Registry Reset: HKCU:\Software\Microsoft\Office\16.0\Outlook\Preferences\NavPane
        $prefKey = 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Preferences'
        $regCleared = $false
        if (Test-Path -LiteralPath $prefKey) {
            try {
                $prop = Get-ItemProperty -LiteralPath $prefKey -Name 'NavPane' -ErrorAction SilentlyContinue
                if ($null -ne $prop -and $null -ne $prop.NavPane) {
                    Remove-ItemProperty -LiteralPath $prefKey -Name 'NavPane' -Force -ErrorAction Stop
                    $regCleared = $true
                }
            } catch {
                Write-Verbose "Could not clear NavPane registry property: $($_.Exception.Message)"
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
        $xmlDir = Join-Path -Path $appData -ChildPath 'Microsoft\Outlook'
        $targetXmlFiles = @(
            (Join-Path -Path $xmlDir -ChildPath "$targetProfile.xml"),
            (Join-Path -Path $xmlDir -ChildPath "Outlook.xml")
        ) | Select-Object -Unique

        $xmlRemoved = $false
        $xmlBackupFile = $null

        foreach ($xmlPath in $targetXmlFiles) {
            if (Test-Path -LiteralPath $xmlPath) {
                $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
                $bkPath = "$xmlPath.bak_$ts"
                try {
                    Copy-Item -LiteralPath $xmlPath -Destination $bkPath -Force -ErrorAction Stop
                    $xmlBackupFile = $bkPath
                    Remove-Item -LiteralPath $xmlPath -Force -ErrorAction Stop
                    $xmlRemoved = $true
                } catch {
                    Write-Verbose "Could not reset XML view file '$xmlPath': $($_.Exception.Message)"
                }
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Navigation pane reset complete for profile '$targetProfile' (Registry: $regCleared, XML: $xmlRemoved)." -Level 'SUCCESS' -Component 'Outlook:NavPane'
        }

        return [PSCustomObject]@{
            Status        = 'Success'
            ProfileName   = $targetProfile
            RegCleared    = $regCleared
            XmlRemoved    = $xmlRemoved
            XmlBackupFile = $xmlBackupFile
            ErrorMessage  = $null
        }
    }
}
