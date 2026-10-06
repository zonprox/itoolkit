function Write-ToolkitStatus {
<#
.SYNOPSIS
    Prints a color-coded status indicator line to the console host and logs the event.
.DESCRIPTION
    Outputs structured status lines to the active console host with standardized
    prefixes ([OK], [WARN], [FAIL], [INFO]) and associated foreground colors.
    Integrates with Write-ToolkitLog for file-based auditing when available.
.PARAMETER Message
    Status message to output.
.PARAMETER Type
    Status category: 'OK', 'WARN', 'FAIL', 'INFO' (case-insensitive).
.PARAMETER NoLog
    Switch to bypass file-based logging.
.EXAMPLE
    Write-ToolkitStatus -Message 'Operation succeeded' -Type 'OK'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateSet('OK', 'WARN', 'FAIL', 'INFO', 'Ok', 'Warn', 'Fail', 'Info')]
        [string]$Type,

        [Parameter(Mandatory = $false)]
        [switch]$NoLog
    )

    $normType = $Type.ToUpperInvariant()
    $foregroundColor = [System.ConsoleColor]::White
    $consolePrefix   = '[INFO]   '
    $logSeverity     = 'INFO'

    switch ($normType) {
        'OK' {
            $foregroundColor = [System.ConsoleColor]::Green
            $consolePrefix   = '[OK]     '
            $logSeverity     = 'SUCCESS'
        }
        'WARN' {
            $foregroundColor = [System.ConsoleColor]::Yellow
            $consolePrefix   = '[WARN]   '
            $logSeverity     = 'WARN'
        }
        'FAIL' {
            $foregroundColor = [System.ConsoleColor]::Red
            $consolePrefix   = '[FAIL]   '
            $logSeverity     = 'ERROR'
        }
        'INFO' {
            $foregroundColor = [System.ConsoleColor]::Cyan
            $consolePrefix   = '[INFO]   '
            $logSeverity     = 'INFO'
        }
    }

    Write-Host "$consolePrefix$Message" -ForegroundColor $foregroundColor

    # Audit to Write-ToolkitLog if loaded
    if (-not $NoLog -and (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue)) {
        try {
            Write-ToolkitLog -Message $Message -Level $logSeverity -Component 'TUI' -NoConsole
        }
        catch {
            $null = $_
        }
    }
}
