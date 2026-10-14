function Write-ToolkitLog {
<#
.SYNOPSIS
    Writes structured log entries to the console and to a persistent daily log file.
.DESCRIPTION
    Dual console and file logger for IToolkit. Prints color-coded status messages
    to the active console host and appends structured, timestamped audit entries
    to daily log files (Logs/IToolkit_<yyyyMMdd>.log).
    Implements file locking retry mechanisms to ensure resilience across parallel
    operations without throwing terminating exceptions.
.PARAMETER Message
    The log message string to record. Accepts pipeline input.
.PARAMETER Level
    Severity level of the message: 'INFO', 'WARN', 'ERROR', 'DEBUG', 'SUCCESS'.
    Default is 'INFO'.
.PARAMETER Component
    The originating subsystem or function name. If omitted, automatically attempts
    to resolve the calling function from the call stack or defaults to 'IToolkit'.
.PARAMETER LogDirectory
    Custom log directory path. If not specified, resolves to configured session
    log path, %ProgramData%\IToolkit\Logs, or local Logs\ directory.
.PARAMETER NoConsole
    Switch parameter to suppress console output and record only to log file.
.PARAMETER PassThru
    Returns the formatted log line string.
.EXAMPLE
    Write-ToolkitLog -Message "Administrator privileges verified." -Level SUCCESS -Component "Test-IsAdmin"
.EXAMPLE
    Write-ToolkitLog -Message "Process OUTLOOK.EXE is running." -Level WARN
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Mandatory = $false, Position = 1)]
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG', 'SUCCESS', 'Info', 'Warn', 'Error', 'Debug', 'Success')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory = $false)]
        [string]$Component,

        [Parameter(Mandatory = $false)]
        [string]$LogDirectory,

        [Parameter(Mandatory = $false)]
        [switch]$NoConsole,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    process {
        # 1. Resolve Originating Component Name
        $resolvedComponent = $Component
        if ([string]::IsNullOrWhiteSpace($resolvedComponent)) {
            $callStack = Get-PSCallStack
            if ($callStack.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace($callStack[1].Command)) {
                $resolvedComponent = $callStack[1].Command
            }
            else {
                $resolvedComponent = 'IToolkit'
            }
        }

        # 2. Normalize Level
        $normalizedLevel = $Level.ToUpperInvariant()

        # 3. Generate Timestamps
        $now = Get-Date
        $timestamp = Format-ToolkitTimestamp -DateTime $now -Format 'Log'
        $dateSuffix = Format-ToolkitTimestamp -DateTime $now -Format 'DateOnly'

        # 4. Format Structured Log Record
        $logLine = "[$timestamp] [$normalizedLevel] [$resolvedComponent] $Message"

        # 5. Console Output with Color Mapping (DEBUG and active TUI sessions are suppressed from console/UI output)
        $isTuiActive = ($null -ne $global:ToolkitTuiActive -and $global:ToolkitTuiActive) -or
                       ($null -ne $global:ToolkitTuiDepth -and [int]$global:ToolkitTuiDepth -gt 0) -or
                       ($null -ne $global:ToolkitTUIMode -and $global:ToolkitTUIMode) -or
                       ($null -ne $global:ToolkitSuppressConsoleLog -and $global:ToolkitSuppressConsoleLog) -or
                       ($env:ITOOLKIT_TUI_MODE -eq '1')

        if (-not $NoConsole -and -not $isTuiActive -and $normalizedLevel -ne 'DEBUG') {
            $foregroundColor = [System.ConsoleColor]::White
            $consolePrefix = '[INFO]   '

            switch ($normalizedLevel) {
                'INFO' {
                    $foregroundColor = [System.ConsoleColor]::Cyan
                    $consolePrefix   = '[INFO]   '
                }
                'WARN' {
                    $foregroundColor = [System.ConsoleColor]::Yellow
                    $consolePrefix   = '[WARN]   '
                }
                'ERROR' {
                    $foregroundColor = [System.ConsoleColor]::Red
                    $consolePrefix   = '[FAIL]   '
                }
                'SUCCESS' {
                    $foregroundColor = [System.ConsoleColor]::Green
                    $consolePrefix   = '[OK]     '
                }
            }

            Write-Host "$consolePrefix$Message" -ForegroundColor $foregroundColor
        }

        # 6. Resolve Log Directory
        $targetLogDir = $LogDirectory
        if ([string]::IsNullOrWhiteSpace($targetLogDir)) {
            if (-not [string]::IsNullOrWhiteSpace($global:ToolkitLogDirectory)) {
                $targetLogDir = $global:ToolkitLogDirectory
            }
            elseif (-not [string]::IsNullOrWhiteSpace($script:ToolkitLogDirectory)) {
                $targetLogDir = $script:ToolkitLogDirectory
            }
            elseif (-not [string]::IsNullOrWhiteSpace($env:ITOOLKIT_LOG_DIR)) {
                $targetLogDir = $env:ITOOLKIT_LOG_DIR
            }
            else {
                # Probe upward for IToolkit project root
                $probeDir = $PSScriptRoot
                $foundRoot = $null
                while (-not [string]::IsNullOrWhiteSpace($probeDir)) {
                    if (Test-Path -LiteralPath (Join-Path -Path $probeDir -ChildPath 'IToolkit.psd1')) {
                        $foundRoot = $probeDir
                        break
                    }
                    $parent = Split-Path -Path $probeDir -Parent
                    if ($parent -eq $probeDir) { break }
                    $probeDir = $parent
                }

                if (-not [string]::IsNullOrWhiteSpace($foundRoot)) {
                    $targetLogDir = Join-Path -Path $foundRoot -ChildPath 'Logs'
                }
                elseif (-not [string]::IsNullOrWhiteSpace($global:IToolkitRoot)) {
                    $targetLogDir = Join-Path -Path $global:IToolkitRoot -ChildPath 'Logs'
                }
                else {
                    $targetLogDir = Join-Path -Path (Get-Location).Path -ChildPath 'Logs'
                }
            }
        }

        # Normalize leaf casing: ensure any path ending with 'logs' (case-insensitive) resolves to 'Logs'
        if (-not [string]::IsNullOrWhiteSpace($targetLogDir)) {
            $trimmed = $targetLogDir.TrimEnd('\', '/')
            $leaf = Split-Path -Path $trimmed -Leaf
            if ($leaf -eq 'logs') {
                $parent = Split-Path -Path $trimmed -Parent
                if ([string]::IsNullOrWhiteSpace($parent)) {
                    $targetLogDir = 'Logs'
                }
                else {
                    $targetLogDir = Join-Path -Path $parent -ChildPath 'Logs'
                }
            }
        }

        # 7. Write to File Resiliently with Graceful Fallback
        $logFileName = "IToolkit_$dateSuffix.log"
        $candidateDirs = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($targetLogDir)) {
            $candidateDirs.Add($targetLogDir)
        }
        # Multi-tier fallback directories in case primary location is not writable
        if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
            $candidateDirs.Add((Join-Path -Path $env:ProgramData -ChildPath 'IToolkit\Logs'))
        }
        $tempPath = [System.IO.Path]::GetTempPath()
        if (-not [string]::IsNullOrWhiteSpace($tempPath)) {
            $candidateDirs.Add((Join-Path -Path $tempPath -ChildPath 'IToolkit\Logs'))
        }

        $written = $false
        foreach ($candidateDir in $candidateDirs) {
            try {
                if (-not (Test-Path -LiteralPath $candidateDir)) {
                    $null = [System.IO.Directory]::CreateDirectory($candidateDir)
                }

                $logFilePath = Join-Path -Path $candidateDir -ChildPath $logFileName

                # Concurrency & Lock Retry Loop (3 attempts, 50ms pause)
                $attempt = 0
                while (-not $written -and $attempt -lt 3) {
                    $attempt++
                    try {
                        [System.IO.File]::AppendAllText($logFilePath, "$logLine`r`n", [System.Text.Encoding]::UTF8)
                        $written = $true
                    }
                    catch [System.IO.IOException] {
                        if ($attempt -lt 3) {
                            Start-Sleep -Milliseconds 50
                        }
                    }
                    catch {
                        break
                    }
                }

                if ($written) {
                    $script:ToolkitActiveLogDirectory = $candidateDir
                    break
                }
            }
            catch {
                Write-Verbose "Logging filesystem error in '$candidateDir': $($_.Exception.Message)"
                continue
            }
        }

        # 8. Automatic Daily Log Retention & Rotation (default: 30 days)
        if ($written -and $script:ToolkitLastLogCleanupDate -ne $dateSuffix) {
            $script:ToolkitLastLogCleanupDate = $dateSuffix
            try {
                $retentionDays = 30
                if (-not [string]::IsNullOrWhiteSpace($env:ITOOLKIT_LOG_RETENTION_DAYS)) {
                    $parsedDays = 0
                    if ([int]::TryParse($env:ITOOLKIT_LOG_RETENTION_DAYS, [ref]$parsedDays) -and $parsedDays -gt 0) {
                        $retentionDays = $parsedDays
                    }
                }

                $activeDir = $script:ToolkitActiveLogDirectory
                if (-not [string]::IsNullOrWhiteSpace($activeDir) -and (Test-Path -LiteralPath $activeDir)) {
                    $cutoffDate = (Get-Date).AddDays(-$retentionDays)
                    $oldFiles = Get-ChildItem -LiteralPath $activeDir -Filter 'IToolkit_*.log' -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.LastWriteTime -lt $cutoffDate }

                    foreach ($oldFile in $oldFiles) {
                        try {
                            Remove-Item -LiteralPath $oldFile.FullName -Force -ErrorAction SilentlyContinue
                        }
                        catch {
                            $null = $_
                        }
                    }
                }
            }
            catch {
                $null = $_
            }
        }

        if ($PassThru) {
            return $logLine
        }
    }
}
