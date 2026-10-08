function Write-AppInstallerLog {
<#
.SYNOPSIS
    Writes structured log entries for AppInstaller operations.
.DESCRIPTION
    Delegates to Write-ToolkitLog if available, or appends structured, timestamped
    log entries to daily log files (logs/IToolkit_yyyyMMdd.log) and emits console output.
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
            if ($null -ne $script:ToolkitLogDirectory -and -not [string]::IsNullOrWhiteSpace($script:ToolkitLogDirectory)) {
                $targetDir = $script:ToolkitLogDirectory
            } else {
                $targetDir = Join-Path -Path (Get-Location).Path -ChildPath 'logs'
            }
        }

        # If Write-ToolkitLog is available, prioritize standard project logger
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message $Message -Level $normalizedLevel -Component $Component -LogDirectory $targetDir
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

            # Console output
            $prefix = switch ($normalizedLevel) {
                'INFO'    { '[INFO]   ' }
                'WARN'    { '[WARN]   ' }
                'ERROR'   { '[FAIL]   ' }
                'DEBUG'   { '[DEBUG]  ' }
                'SUCCESS' { '[OK]     ' }
                default   { '[INFO]   ' }
            }
            Write-Host "$prefix$Message"
        }
    }
}

if (Get-Command -Name 'Write-AppInstallerLog' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Write-AppInstallerLog' -Value (Get-Command -Name 'Write-AppInstallerLog').ScriptBlock
}
