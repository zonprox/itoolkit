function Start-ToolkitSelfElevation {
<#
.SYNOPSIS
    Relaunches the current script or PowerShell session with elevated Administrator privileges.
.DESCRIPTION
    Detects if the current process is unelevated, prompts for UAC elevation via
    Start-Process with -Verb RunAs, preserves arguments and working directory,
    and optionally exits the caller.
.PARAMETER ScriptPath
    Path to the script to execute in the elevated session. Defaults to calling script if omitted.
.PARAMETER Arguments
    Additional command-line arguments to pass to the elevated process.
.PARAMETER WorkingDirectory
    Directory to preserve in the elevated session. Defaults to current working directory.
.PARAMETER ExitCurrent
    If specified, exits the current unelevated PowerShell process after launching the elevated process.
.PARAMETER PassThru
    Returns a status object with details of the launched process.
.PARAMETER Force
    Forces relaunch even if the current session already has administrative privileges.
.OUTPUTS
    [PSCustomObject] containing Relaunched, Elevated, and ProcessId (when PassThru is specified).
.EXAMPLE
    Start-ToolkitSelfElevation -ScriptPath "C:\IToolkit\Start-IToolkit.ps1" -ExitCurrent
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$Arguments,

        [Parameter(Mandatory = $false)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $false)]
        [switch]$ExitCurrent,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    # 1. Check if already elevated
    if (-not $Force -and (Test-IsAdmin)) {
        Write-Verbose "Session already running with administrative privileges. Elevation not required."
        if ($PassThru) {
            return [PSCustomObject]@{
                Relaunched = $false
                Elevated   = $true
                ProcessId  = $PID
            }
        }
        return
    }

    # 2. Determine target working directory
    $targetWorkDir = (Get-Location).ProviderPath
    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) {
        try {
            $targetWorkDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkingDirectory)
        } catch {
            $targetWorkDir = $WorkingDirectory
        }
    }

    # 3. Detect PowerShell executable (pwsh.exe for Core, powershell.exe for Desktop)
    $psExe = 'powershell.exe'
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $psExe = 'pwsh.exe'
    }
    if (-not (Get-Command -Name $psExe -ErrorAction SilentlyContinue)) {
        $psExe = 'powershell.exe'
    }

    # 4. Construct argument list
    $argTokens = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    if (-not [string]::IsNullOrEmpty($ScriptPath)) {
        $targetScript = $ScriptPath
        try {
            $targetScript = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ScriptPath)
        } catch {
            $targetScript = $ScriptPath
        }
        $argTokens += @('-File', "`"$targetScript`"")
    }
    if (-not [string]::IsNullOrEmpty($Arguments)) {
        $argTokens += $Arguments
    }

    $fullArgString = $argTokens -join ' '

    # 5. Launch elevated process with UAC prompt
    try {
        $startParams = @{
            FilePath         = $psExe
            ArgumentList     = $fullArgString
            Verb             = 'RunAs'
            WorkingDirectory = $targetWorkDir
        }
        if ($PassThru) {
            $startParams['PassThru'] = $true
        }

        Write-Verbose "Launching elevated process: $psExe $fullArgString"
        $proc = Start-Process @startParams

        if ($ExitCurrent) {
            exit 0
        }

        if ($PassThru) {
            $procId = $null
            if ($null -ne $proc -and $proc.PSObject.Properties['Id']) {
                $procId = $proc.Id
            }
            return [PSCustomObject]@{
                Relaunched = $true
                Elevated   = $true
                ProcessId  = $procId
                Process    = $proc
            }
        }
    } catch [System.ComponentModel.Win32Exception] {
        if ($_.Exception.NativeErrorCode -eq 1223) {
            $cancelMsg = "UAC elevation prompt was cancelled by the user."
            Write-Warning $cancelMsg
            if (Get-Command -Name Write-ToolkitLog -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message $cancelMsg -Level 'WARN' -Component 'Start-ToolkitSelfElevation'
            }
            throw New-Object -TypeName System.Security.SecurityException -ArgumentList @($cancelMsg, $_.Exception)
        } else {
            throw
        }
    }
}
