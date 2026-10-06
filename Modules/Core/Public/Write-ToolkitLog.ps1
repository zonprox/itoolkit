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

        # 5. Console Output with Color Mapping
        if (-not $NoConsole) {
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
                'DEBUG' {
                    $foregroundColor = [System.ConsoleColor]::DarkGray
                    $consolePrefix   = '[DEBUG]  '
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
            if ($null -ne $script:ToolkitLogDirectory -and -not [string]::IsNullOrWhiteSpace($script:ToolkitLogDirectory)) {
                $targetLogDir = $script:ToolkitLogDirectory
            }
            elseif ($null -ne $env:ProgramData -and (Test-Path -LiteralPath $env:ProgramData)) {
                $targetLogDir = Join-Path -Path $env:ProgramData -ChildPath 'IToolkit\Logs'
            }
            else {
                $targetLogDir = Join-Path -Path (Get-Location).Path -ChildPath 'Logs'
            }
        }

        # 7. Ensure Directory Exists and Write to File Resiliently
        try {
            if (-not (Test-Path -LiteralPath $targetLogDir)) {
                $null = [System.IO.Directory]::CreateDirectory($targetLogDir)
            }

            $logFileName = "IToolkit_$dateSuffix.log"
            $logFilePath = Join-Path -Path $targetLogDir -ChildPath $logFileName

            # Concurrency & Lock Retry Loop (3 attempts, 50ms pause)
            $written = $false
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
                    Write-Verbose "Could not append log entry: $($_.Exception.Message)"
                    break
                }
            }
        }
        catch {
            Write-Verbose "Logging filesystem error: $($_.Exception.Message)"
        }

        if ($PassThru) {
            return $logLine
        }
    }
}
