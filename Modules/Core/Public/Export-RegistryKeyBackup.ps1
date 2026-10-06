function Export-RegistryKeyBackup {
<#
.SYNOPSIS
    Exports a target registry key to an auto-generated .reg backup file before modifications.
.DESCRIPTION
    Generates a timestamped .reg backup file inside the specified or default Backups directory.
    Invokes native reg.exe export via Start-Process. If the key exists, reg.exe creates a full export.
    If the key does not yet exist or reg.exe export reports non-zero exit code, generates a reversible
    Windows Registry Editor Version 5.00 deletion sentinel ([-KeyPath]) so rollback cleanly removes
    the newly created key upon restore.
.PARAMETER KeyPath
    The registry key path to back up (supports HKLM:\, HKLM\, HKEY_LOCAL_MACHINE\ formats).
.PARAMETER BackupDirectory
    Optional destination directory for the .reg backup file. Defaults to $Global:IToolkitBackupDirectory
    or <ToolkitRoot>\Backups\Registry.
.OUTPUTS
    [string] The absolute file path to the generated .reg backup file.
.EXAMPLE
    Export-RegistryKeyBackup -KeyPath "HKCU:\Software\Microsoft\Office" -BackupDirectory "C:\Backups"
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$KeyPath,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$BackupDirectory
    )

    process {
        # Normalize path representations
        $nativePath   = Normalize-RegistryPath -Path $KeyPath -Format 'Native'
        $standardPath = Normalize-RegistryPath -Path $KeyPath -Format 'Standard'

        # Resolve destination backup directory
        $targetDir = $BackupDirectory
        if ([string]::IsNullOrWhiteSpace($targetDir)) {
            if ($null -ne $Global:IToolkitBackupDirectory -and -not [string]::IsNullOrWhiteSpace($Global:IToolkitBackupDirectory)) {
                $targetDir = $Global:IToolkitBackupDirectory
            }
            else {
                $moduleRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
                $candidate = Join-Path -Path $moduleRoot -ChildPath 'Backups\Registry'
                if (Test-Path -LiteralPath (Split-Path -Path $candidate -Parent)) {
                    $targetDir = $candidate
                }
                else {
                    $targetDir = Join-Path -Path (Get-Location).Path -ChildPath 'Backups\Registry'
                }
            }
        }

        if (-not (Test-Path -LiteralPath $targetDir)) {
            $null = New-Item -ItemType Directory -LiteralPath $targetDir -Force
        }

        # Build sanitized filename
        $safeSlug = $nativePath -replace '[:\\/ *?"<>|]', '_'
        $timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss_fff')
        $backupFileName = "RegistryBackup_${safeSlug}_${timestamp}.reg"
        $backupFilePath = Join-Path -Path $targetDir -ChildPath $backupFileName

        # Evaluate ShouldProcess
        if (-not $PSCmdlet.ShouldProcess($nativePath, "Export registry key backup to '$backupFilePath'")) {
            return $backupFilePath
        }

        # Locate reg.exe
        $regExe = 'reg.exe'
        if ($env:SystemRoot) {
            $candidateReg = Join-Path -Path $env:SystemRoot -ChildPath 'System32\reg.exe'
            if (Test-Path -LiteralPath $candidateReg) {
                $regExe = $candidateReg
            }
        }

        $exportSucceeded = $false
        try {
            $proc = Start-Process -FilePath $regExe -ArgumentList @('export', "`"$nativePath`"", "`"$backupFilePath`"", '/y') -NoNewWindow -Wait -PassThru -ErrorAction SilentlyContinue
            if ($null -ne $proc -and $proc.PSObject.Properties['ExitCode'] -and $proc.ExitCode -eq 0 -and (Test-Path -LiteralPath $backupFilePath)) {
                $exportSucceeded = $true
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Exported registry backup for key '$nativePath' to '$backupFilePath'" -Level 'INFO' -Component 'Core:Registry'
                }
            }
        } catch {
            Write-Verbose "Start-Process for reg.exe export encountered error: $($_.Exception.Message)"
        }

        # If reg.exe export did not generate the file (e.g. key does not exist yet), write rollback deletion sentinel
        if (-not $exportSucceeded -and -not (Test-Path -LiteralPath $backupFilePath)) {
            $sentinelContent = "Windows Registry Editor Version 5.00`r`n`r`n; IToolkit Rollback Sentinel`r`n; Key did not exist prior to modification. Restore removes this key.`r`n[-$standardPath]`r`n"
            Set-Content -LiteralPath $backupFilePath -Value $sentinelContent -Encoding Unicode

            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Generated rollback deletion sentinel for nonexistent key '$nativePath' at '$backupFilePath'" -Level 'INFO' -Component 'Core:Registry'
            }
        }

        if (Test-Path -LiteralPath $backupFilePath) {
            return (Resolve-Path -LiteralPath $backupFilePath).Path
        } else {
            return $backupFilePath
        }
    }
}
