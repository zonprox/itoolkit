function Enter-ToolkitConsoleView {
<#
.SYNOPSIS
    Transitions the console from the TUI frame to a live execution console view.
.DESCRIPTION
    Clears the interactive TUI frame and displays a live execution header banner.
    Temporarily suspends TUI mode log suppression flags ($global:ToolkitSuppressConsoleLog,
    $global:ToolkitTuiActive, $global:ToolkitTUIMode, $env:ITOOLKIT_TUI_MODE) so that
    cmdlets and external processes emit full, detailed logs and progress to the console
    in real time.
.PARAMETER ActionTitle
    Optional title of the action or process being executed.
.PARAMETER NonInteractive
    Suppresses screen clearing when running non-interactively or in automated test harnesses.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$ActionTitle,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    process {
        # 1. Determine effective non-interactive mode
        $effectiveNonInteractive = [bool]$NonInteractive
        if (-not $effectiveNonInteractive) {
            if ($env:ITOOLKIT_NON_INTERACTIVE -eq '1' -or $env:ITOOLKIT_NONINTERACTIVE -eq '1') {
                $effectiveNonInteractive = $true
            }
            elseif ($null -ne $global:ToolkitConsoleNonInteractive -and [bool]$global:ToolkitConsoleNonInteractive) {
                $effectiveNonInteractive = $true
            }
            elseif ($null -ne $global:ToolkitNonInteractive -and [bool]$global:ToolkitNonInteractive) {
                $effectiveNonInteractive = $true
            }
            else {
                foreach ($scopeIndex in 1..5) {
                    try {
                        $v = Get-Variable -Name NonInteractive -Scope $scopeIndex -ErrorAction SilentlyContinue
                        if ($null -ne $v -and [bool]$v.Value) {
                            $effectiveNonInteractive = $true
                            break
                        }
                    }
                    catch {
                        break
                    }
                }
            }
        }

        if ($null -eq $global:ToolkitConsoleNonInteractiveStack) {
            $global:ToolkitConsoleNonInteractiveStack = [System.Collections.Generic.Stack[bool]]::new()
        }
        $global:ToolkitConsoleNonInteractiveStack.Push($effectiveNonInteractive)
        $global:ToolkitConsoleNonInteractive = $effectiveNonInteractive

        # If already in console view, increment depth and show sub-banner without resetting saved state
        if ($null -ne $global:ToolkitConsoleViewActive -and $global:ToolkitConsoleViewActive) {
            $global:ToolkitConsoleViewDepth = if ($null -ne $global:ToolkitConsoleViewDepth) { [int]$global:ToolkitConsoleViewDepth + 1 } else { 2 }
            if (-not [string]::IsNullOrWhiteSpace($ActionTitle)) {
                Write-Host ""
                Write-Host "--- [ACTION: $ActionTitle] ---" -ForegroundColor Cyan
            }
            return
        }
        $global:ToolkitConsoleViewDepth = 1

        # 2. Clear TUI frame to live console view (when running interactively)
        if (-not $effectiveNonInteractive -and -not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected) {
            try {
                [Console]::Clear()
            }
            catch {
                try {
                    Clear-Host
                }
                catch {
                    $null = $_
                }
            }
        }

        # 3. Display live console header banner
        Write-Host ""
        Write-Host "==============================================================================" -ForegroundColor DarkCyan
        Write-Host "  ITOOLKIT EXECUTION CONSOLE :: LIVE OUTPUT" -ForegroundColor Cyan
        if (-not [string]::IsNullOrWhiteSpace($ActionTitle)) {
            Write-Host "  Action: $ActionTitle" -ForegroundColor White
        }
        Write-Host "==============================================================================" -ForegroundColor DarkCyan
        Write-Host ""

        # 4. Save existing TUI session depth and state for restoration
        $global:ToolkitPreviousTuiDepth    = $global:ToolkitTuiDepth
        $global:ToolkitPreviousTuiActive   = $global:ToolkitTuiActive
        $global:ToolkitPreviousTUIMode     = $global:ToolkitTUIMode
        $global:ToolkitPreviousSuppressLog = $global:ToolkitSuppressConsoleLog
        $global:ToolkitPreviousEnvMode     = $env:ITOOLKIT_TUI_MODE

        # 5. Suspend TUI suppression so Write-ToolkitLog and child processes emit live console output
        $global:ToolkitSuppressConsoleLog  = $false
        $global:ToolkitTuiActive           = $false
        $global:ToolkitTUIMode             = $false
        $global:ToolkitTuiDepth            = 0
        $global:ToolkitConsoleViewActive   = $true
        $env:ITOOLKIT_TUI_MODE             = $null
        Remove-Item -Path 'env:ITOOLKIT_TUI_MODE' -ErrorAction SilentlyContinue
    }
}

if (Get-Command -Name 'Enter-ToolkitConsoleView' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Enter-ToolkitConsoleView' -Value (Get-Command -Name 'Enter-ToolkitConsoleView').ScriptBlock
}
