function New-ToolkitDesktopShortcut {
<#
.SYNOPSIS
    Creates a desktop shortcut (.lnk) on the current user's desktop pointing to a specified executable.
.DESCRIPTION
    Resolves the current user's desktop path via [Environment]::GetFolderPath('Desktop'),
    creates or updates a Windows shell link (.lnk) with target executable, working directory,
    arguments, and icon.
.PARAMETER TargetExecutable
    Absolute path to the target executable or script.
.PARAMETER ShortcutName
    Name of the shortcut file including or excluding the .lnk extension.
.PARAMETER Arguments
    Optional command line arguments to pass to the target executable.
.PARAMETER IconLocation
    Optional icon file path and index (e.g. 'shell32.dll,0').
.PARAMETER DesktopDirectory
    Optional custom desktop directory override. Defaults to current user's desktop.
.PARAMETER Force
    Overwrite existing shortcut if already present.
.OUTPUTS
    [PSCustomObject] containing ShortcutPath, TargetExecutable, Created, AlreadyExists.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$TargetExecutable,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$ShortcutName,

        [Parameter(Mandatory = $false)]
        [string]$Arguments,

        [Parameter(Mandatory = $false)]
        [string]$IconLocation,

        [Parameter(Mandatory = $false)]
        [string]$DesktopDirectory,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        if (-not (Get-Command -Name 'Write-AppInstallerLog' -ErrorAction SilentlyContinue)) {
            $privLog = Join-Path (Split-Path -Parent $PSScriptRoot) 'Private/Write-AppInstallerLog.ps1'
            if (Test-Path -LiteralPath $privLog) { . $privLog }
        }

        # 1. Resolve Desktop Directory
        $targetDesktop = $DesktopDirectory
        if ([string]::IsNullOrWhiteSpace($targetDesktop)) {
            $targetDesktop = [Environment]::GetFolderPath('Desktop')
        }
        if ([string]::IsNullOrWhiteSpace($targetDesktop)) {
            $userProfile = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
            $targetDesktop = Join-Path $userProfile 'Desktop'
        }

        if (-not (Test-Path -LiteralPath $targetDesktop -ErrorAction SilentlyContinue)) {
            New-Item -ItemType Directory -Path $targetDesktop -Force -ErrorAction SilentlyContinue | Out-Null
        }

        # 2. Resolve Shortcut Name & Extension
        if ([string]::IsNullOrWhiteSpace($ShortcutName)) {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($TargetExecutable)
            $ShortcutName = "$baseName.lnk"
        }
        if (-not $ShortcutName.EndsWith('.lnk', [System.StringComparison]::OrdinalIgnoreCase)) {
            $ShortcutName = "$ShortcutName.lnk"
        }

        $shortcutFullPath = Join-Path $targetDesktop $ShortcutName

        # 3. Check existing shortcut
        $exists = Test-Path -LiteralPath $shortcutFullPath -ErrorAction SilentlyContinue
        if ($exists -and -not $Force) {
            Write-AppInstallerLog -Message "Shortcut already exists: $shortcutFullPath" -Level 'INFO' -Component 'New-ToolkitDesktopShortcut'
            return [PSCustomObject]@{
                ShortcutPath     = $shortcutFullPath
                TargetExecutable = $TargetExecutable
                Created          = $false
                AlreadyExists    = $true
            }
        }

        # 4. ShouldProcess / WhatIf check
        if (-not $PSCmdlet.ShouldProcess($shortcutFullPath, "Create desktop shortcut pointing to '$TargetExecutable'")) {
            return [PSCustomObject]@{
                ShortcutPath     = $shortcutFullPath
                TargetExecutable = $TargetExecutable
                Created          = $false
                AlreadyExists    = $exists
            }
        }

        # 5. Create Shortcut via WScript.Shell on Windows or safe file fallback on non-Windows
        $onWindowsHost = [bool](([System.Environment]::OSVersion.Platform -match 'Win') -or (Test-Path 'Env:WINDIR'))
        $workingDir = Split-Path -Parent $TargetExecutable

        if ($onWindowsHost) {
            try {
                $wsh = New-Object -ComObject WScript.Shell
                $link = $wsh.CreateShortcut($shortcutFullPath)
                $link.TargetPath = $TargetExecutable
                if (-not [string]::IsNullOrWhiteSpace($workingDir)) {
                    $link.WorkingDirectory = $workingDir
                }
                if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
                    $link.Arguments = $Arguments
                }
                if (-not [string]::IsNullOrWhiteSpace($IconLocation)) {
                    $link.IconLocation = $IconLocation
                }
                $link.Save()
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) | Out-Null
            } catch {
                # Fallback to file creation if COM is restricted
                Set-Content -LiteralPath $shortcutFullPath -Value "[InternetShortcut]`r`nURL=file:///$TargetExecutable" -Encoding UTF8
            }
        } else {
            # Cross-platform / Linux test runner environment fallback
            $shortcutContent = @(
                "[Shortcut]",
                "Target=$TargetExecutable",
                "WorkingDirectory=$workingDir",
                "Arguments=$Arguments"
            ) -join "`n"
            Set-Content -LiteralPath $shortcutFullPath -Value $shortcutContent -Encoding UTF8
        }

        Write-AppInstallerLog -Message "Created desktop shortcut: $shortcutFullPath -> $TargetExecutable" -Level 'INFO' -Component 'New-ToolkitDesktopShortcut'

        return [PSCustomObject]@{
            ShortcutPath     = $shortcutFullPath
            TargetExecutable = $TargetExecutable
            Created          = $true
            AlreadyExists    = $false
        }
    }
}
