function Start-ProfileDirectoryBackup {
<#
.SYNOPSIS
    Performs multithreaded directory backup using Robocopy with bitmask exit code verification.
.DESCRIPTION
    Invokes robocopy.exe with /MT, /E (or /MIR), /COPY:DAT, /R:2, /W:2, /XJ, /ZB, /NP.
    Evaluates bitmask exit codes: $exitCode < 8 is treated as success; $exitCode >= 8 is failure.
.PARAMETER SourceDirectories
    Array of source directories to copy.
.PARAMETER DestinationPath
    Destination target path.
.PARAMETER Threads
    Number of parallel threads for Robocopy (default: 16).
.PARAMETER Mirror
    When set to $true, uses /MIR (mirror/purge); otherwise uses /E (copy subdirectories).
.OUTPUTS
    [PSCustomObject]@{ CopiedCount, FailedCount, TotalBytes, ExitCode }
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]]$SourceDirectories,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath,

        [Parameter(Mandatory = $false)]
        [int]$Threads = 16,

        [Parameter(Mandatory = $false)]
        [bool]$Mirror = $false
    )

    process {
        if (-not (Test-Path -LiteralPath $DestinationPath)) {
            $null = New-Item -ItemType Directory -Path $DestinationPath -Force -ErrorAction SilentlyContinue
        }

        $overallExitCode = 0
        $copiedCount = 0
        $failedCount = 0

        foreach ($src in $SourceDirectories) {
            $targetDir = $DestinationPath
            if ($SourceDirectories.Count -gt 1) {
                $leafName = Split-Path -Path $src -Leaf
                $targetDir = Join-Path -Path $DestinationPath -ChildPath $leafName
                if (-not (Test-Path -LiteralPath $targetDir)) {
                    $null = New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction SilentlyContinue
                }
            }

            $modeArg = '/E'
            if ($Mirror) {
                $modeArg = '/MIR'
            }

            $threadArg = "/MT:$Threads"
            $roboArgs = @(
                "`"$src`"",
                "`"$targetDir`"",
                $modeArg,
                $threadArg,
                '/COPY:DAT',
                '/R:2',
                '/W:2',
                '/XJ',
                '/ZB',
                '/NP'
            )

            $exitCode = 0
            try {
                $proc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $roboArgs -Wait -NoNewWindow -PassThru -ErrorAction Stop
                if ($null -ne $proc -and $proc.PSObject.Properties['ExitCode'] -and $null -ne $proc.ExitCode) {
                    $exitCode = [int]$proc.ExitCode
                } else {
                    $exitCode = 16
                }
            }
            catch {
                Write-Verbose "Robocopy process execution notice: $($_.Exception.Message)"
                $exitCode = 16
            }

            $overallExitCode = [System.Math]::Max($overallExitCode, $exitCode)

            # Robocopy bitmask: < 8 is success, >= 8 is failure
            if ($exitCode -ge 8) {
                $failedCount++
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Robocopy failed for '$src' with exit code $exitCode" -Level 'ERROR' -Component 'Backup:Robocopy'
                }
            }
            else {
                if ($exitCode -gt 0) {
                    $copiedCount++
                }
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Robocopy succeeded for '$src' with exit code $exitCode" -Level 'SUCCESS' -Component 'Backup:Robocopy'
                }
            }
        }

        return [PSCustomObject]@{
            CopiedCount = $copiedCount
            FailedCount = $failedCount
            TotalBytes  = [int64]0
            ExitCode    = $overallExitCode
        }
    }
}
