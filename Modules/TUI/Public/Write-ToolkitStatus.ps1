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
.PARAMETER NoConsole
    Switch to bypass console host output.
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
        [switch]$NoLog,

        [Parameter(Mandatory = $false)]
        [switch]$NoConsole
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

    [int]$depthVal = 0
    $hasTuiDepth = ($null -ne $global:ToolkitTuiDepth) -and [int]::TryParse([string]$global:ToolkitTuiDepth, [ref]$depthVal) -and ($depthVal -gt 0)

    $isTuiActive = ($null -ne $global:ToolkitTuiActive -and $global:ToolkitTuiActive) -or
                   $hasTuiDepth -or
                   ($null -ne $global:ToolkitTUIMode -and $global:ToolkitTUIMode) -or
                   ($null -ne $global:ToolkitSuppressConsoleLog -and $global:ToolkitSuppressConsoleLog) -or
                   ($env:ITOOLKIT_TUI_MODE -eq '1')

    if ($isTuiActive) {
        switch ($normType) {
            'OK'   { $consolePrefix = '  [+] ' }
            'WARN' { $consolePrefix = '  [!] ' }
            'FAIL' { $consolePrefix = '  [x] ' }
            'INFO' { $consolePrefix = '  [*] ' }
            default { $consolePrefix = '  [*] ' }
        }
    }

    if (-not $NoConsole) {
        Write-Host "$consolePrefix$Message" -ForegroundColor $foregroundColor
    }

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
