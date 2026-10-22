if (-not (Get-Command -Name 'Enter-ToolkitConsoleView' -ErrorAction SilentlyContinue)) {
    $enterConsole = Join-Path $PSScriptRoot 'Enter-ToolkitConsoleView.ps1'
    if (Test-Path -LiteralPath $enterConsole) { . $enterConsole }
}
if (-not (Get-Command -Name 'Exit-ToolkitConsoleView' -ErrorAction SilentlyContinue)) {
    $exitConsole = Join-Path $PSScriptRoot 'Exit-ToolkitConsoleView.ps1'
    if (Test-Path -LiteralPath $exitConsole) { . $exitConsole }
}
if (-not (Get-Command -Name 'Wait-UserAcknowledge' -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot '../Private/Wait-UserAcknowledge.ps1'
    if (Test-Path -LiteralPath $waitScript) { . $waitScript }
}

function Invoke-ToolkitConsoleAction {
<#
.SYNOPSIS
    Executes a script block in live console view with full real-time logging.
.DESCRIPTION
    Transitions out of TUI mode using Enter-ToolkitConsoleView, executes the target
    script block, displays completion status, pauses via Wait-UserAcknowledge, and
    restores TUI mode in a guaranteed finally block.
.PARAMETER ScriptBlock
    The code block to execute in live console view.
.PARAMETER ActionTitle
    Optional human-readable title for the executed action.
.PARAMETER NonInteractive
    Bypasses screen clearing and user pause prompts.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('Action')]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $false)]
        [string]$ActionTitle,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    process {
        Enter-ToolkitConsoleView -ActionTitle $ActionTitle -NonInteractive:$NonInteractive
        try {
            & $ScriptBlock
        }
        catch {
            $errDetail = if ($_.Exception -and -not [string]::IsNullOrWhiteSpace($_.Exception.Message)) {
                $_.Exception.Message
            } else {
                "$_"
            }
            if (Get-Command -Name 'Write-ToolkitStatus' -ErrorAction SilentlyContinue) {
                Write-ToolkitStatus -Message "Action execution failed: $errDetail" -Type 'FAIL'
            }
            throw
        }
        finally {
            if (Get-Command -Name 'Wait-UserAcknowledge' -ErrorAction SilentlyContinue) {
                Wait-UserAcknowledge -NonInteractive:$NonInteractive
            }
            else {
                Exit-ToolkitConsoleView
            }
        }
    }
}

if (Get-Command -Name 'Invoke-ToolkitConsoleAction' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Invoke-ToolkitConsoleAction' -Value (Get-Command -Name 'Invoke-ToolkitConsoleAction').ScriptBlock
}
