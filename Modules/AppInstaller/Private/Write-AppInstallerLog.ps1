function Write-AppInstallerLog {
<#
.SYNOPSIS
    Writes structured log entries for AppInstaller operations.
.DESCRIPTION
    Delegates to Write-ToolkitLog if available, or appends structured, timestamped
    log entries to daily log files (Logs/IToolkit_yyyyMMdd.log) and emits console output.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false, Position = 1)]
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG', 'SUCCESS', 'Info', 'Warn', 'Error', 'Debug', 'Success')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory = $false)]
        [string]$Component = 'Install-ToolkitApplication',

        [Parameter(Mandatory = $false)]
        [string]$LogDirectory
    )

    process {
        $normalizedLevel = $Level.ToUpperInvariant()

        # Resolve target log directory
        $targetDir = $LogDirectory
        if ([string]::IsNullOrWhiteSpace($targetDir)) {
            if (-not [string]::IsNullOrWhiteSpace($global:ToolkitLogDirectory)) {
                $targetDir = $global:ToolkitLogDirectory
            } elseif (-not [string]::IsNullOrWhiteSpace($script:ToolkitLogDirectory)) {
                $targetDir = $script:ToolkitLogDirectory
            } elseif (-not [string]::IsNullOrWhiteSpace($env:ITOOLKIT_LOG_DIR)) {
                $targetDir = $env:ITOOLKIT_LOG_DIR
            } else {
                $targetDir = Join-Path -Path (Get-Location).Path -ChildPath 'Logs'
            }
        }

        # If Write-ToolkitLog is available, prioritize standard project logger
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            $logParams = @{
                Message   = $Message
                Level     = $normalizedLevel
                Component = $Component
            }
            if (-not [string]::IsNullOrWhiteSpace($LogDirectory)) {
                $logParams['LogDirectory'] = $targetDir
            }
            Write-ToolkitLog @logParams
        } else {
            # Resilient fallback logging directly to persistent daily log file
            $now = Get-Date
            $dateSuffix = $now.ToString('yyyyMMdd')
            $timeStr = $now.ToString('yyyy-MM-dd HH:mm:ss')

            try {
                if (-not (Test-Path -LiteralPath $targetDir)) {
                    $null = [System.IO.Directory]::CreateDirectory($targetDir)
                }
                $logFile = Join-Path -Path $targetDir -ChildPath "IToolkit_$dateSuffix.log"
                $logLine = "[$timeStr] [$normalizedLevel] [$Component] $Message"
                [System.IO.File]::AppendAllText($logFile, "$logLine`r`n", [System.Text.Encoding]::UTF8)
            } catch {
                Write-Verbose "Could not append log entry: $($_.Exception.Message)"
            }

            # Console output (DEBUG and active TUI sessions are suppressed from console/UI output)
            [int]$depthVal = 0
            $hasTuiDepth = ($null -ne $global:ToolkitTuiDepth) -and [int]::TryParse([string]$global:ToolkitTuiDepth, [ref]$depthVal) -and ($depthVal -gt 0)

            $isTuiActive = ($null -ne $global:ToolkitTuiActive -and $global:ToolkitTuiActive) -or
                           $hasTuiDepth -or
                           ($null -ne $global:ToolkitTUIMode -and $global:ToolkitTUIMode) -or
                           ($null -ne $global:ToolkitSuppressConsoleLog -and $global:ToolkitSuppressConsoleLog) -or
                           ($env:ITOOLKIT_TUI_MODE -eq '1')

            if (-not $isTuiActive -and $normalizedLevel -ne 'DEBUG') {
                $prefix = switch ($normalizedLevel) {
                    'INFO'    { '[INFO]   ' }
                    'WARN'    { '[WARN]   ' }
                    'ERROR'   { '[FAIL]   ' }
                    'SUCCESS' { '[OK]     ' }
                    default   { '[INFO]   ' }
                }
                Write-Host "$prefix$Message"
            }
        }
    }
}

if (Get-Command -Name 'Write-AppInstallerLog' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Write-AppInstallerLog' -Value (Get-Command -Name 'Write-AppInstallerLog').ScriptBlock
}
