function Exit-ToolkitConsoleView {
<#
.SYNOPSIS
    Restores TUI session mode and log suppression after live console action execution.
.DESCRIPTION
    Restores saved TUI session flags ($global:ToolkitTuiDepth, $global:ToolkitTuiActive,
    $global:ToolkitTUIMode, $global:ToolkitSuppressConsoleLog, $env:ITOOLKIT_TUI_MODE),
    ensuring subsequent TUI menu rendering and background telemetry queries do not
    pollute the interactive console frame.
#>
    [CmdletBinding()]
    param()

    process {
        if (-not $global:ToolkitConsoleViewActive) {
            return
        }

        # Pop non-interactive state stack for current depth
        if ($null -ne $global:ToolkitConsoleNonInteractiveStack -and $global:ToolkitConsoleNonInteractiveStack.Count -gt 0) {
            $null = $global:ToolkitConsoleNonInteractiveStack.Pop()
            $global:ToolkitConsoleNonInteractive = if ($global:ToolkitConsoleNonInteractiveStack.Count -gt 0) {
                $global:ToolkitConsoleNonInteractiveStack.Peek()
            } else {
                $false
            }
        }
        else {
            $global:ToolkitConsoleNonInteractive = $false
        }

        $global:ToolkitConsoleViewDepth = if ($null -ne $global:ToolkitConsoleViewDepth) { [int]$global:ToolkitConsoleViewDepth - 1 } else { 0 }
        if ($global:ToolkitConsoleViewDepth -gt 0) {
            return
        }

        $savedDepth = 0
        if ($null -ne $global:ToolkitPreviousTuiDepth) {
            [void][int]::TryParse([string]$global:ToolkitPreviousTuiDepth, [ref]$savedDepth)
        }

        $wasTuiActive = if ($null -ne $global:ToolkitPreviousTuiActive) { [bool]$global:ToolkitPreviousTuiActive } else { $false }
        if ($wasTuiActive -and $savedDepth -le 0) {
            $savedDepth = 1
        }

        $global:ToolkitTuiDepth              = $savedDepth
        $global:ToolkitTuiActive             = $wasTuiActive
        $global:ToolkitTUIMode               = if ($null -ne $global:ToolkitPreviousTUIMode) { [bool]$global:ToolkitPreviousTUIMode } else { $wasTuiActive }
        $global:ToolkitSuppressConsoleLog    = if ($null -ne $global:ToolkitPreviousSuppressLog) { [bool]$global:ToolkitPreviousSuppressLog } else { $wasTuiActive }
        $global:ToolkitConsoleViewActive      = $false
        $global:ToolkitConsoleViewDepth       = 0
        $global:ToolkitConsoleNonInteractive  = $false
        $global:ToolkitConsoleNonInteractiveStack = $null

        if (-not [string]::IsNullOrWhiteSpace($global:ToolkitPreviousEnvMode)) {
            $env:ITOOLKIT_TUI_MODE = $global:ToolkitPreviousEnvMode
        }
        elseif ($wasTuiActive) {
            $env:ITOOLKIT_TUI_MODE = '1'
        }
        else {
            $env:ITOOLKIT_TUI_MODE = $null
            Remove-Item -Path 'env:ITOOLKIT_TUI_MODE' -ErrorAction SilentlyContinue
        }

        # Clear saved state variables
        $global:ToolkitPreviousTuiDepth    = $null
        $global:ToolkitPreviousTuiActive   = $null
        $global:ToolkitPreviousTUIMode     = $null
        $global:ToolkitPreviousSuppressLog = $null
        $global:ToolkitPreviousEnvMode     = $null
    }
}

if (Get-Command -Name 'Exit-ToolkitConsoleView' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Exit-ToolkitConsoleView' -Value (Get-Command -Name 'Exit-ToolkitConsoleView').ScriptBlock
}
