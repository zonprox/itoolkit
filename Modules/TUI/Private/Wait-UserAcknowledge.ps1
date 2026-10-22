<#
.SYNOPSIS
    Waits for user acknowledgement and prompts before returning to the TUI.
.DESCRIPTION
    Pauses interactive console execution until the user presses [Enter].
    Automatically bypasses pausing if input is redirected or running in headless mode.
.PARAMETER Prompt
    Custom prompt text. Defaults to '  Press [Enter] to return to TUI...'.
.PARAMETER NonInteractive
    Bypasses user prompt in non-interactive/automated execution modes.
#>
function Wait-UserAcknowledge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Prompt = "  Press [Enter] to return to TUI...",

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    try {
        $effectiveNonInteractive = [bool]$NonInteractive
        if (-not $effectiveNonInteractive) {
            if ($null -ne $global:ToolkitConsoleNonInteractive -and [bool]$global:ToolkitConsoleNonInteractive) {
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

        if ($effectiveNonInteractive -or $env:ITOOLKIT_NON_INTERACTIVE -eq '1' -or $env:ITOOLKIT_NONINTERACTIVE -eq '1' -or [Console]::IsInputRedirected) {
            return
        }

        Write-Host ""
        if (Get-Command -Name 'Write-ToolkitMenuDivider' -ErrorAction SilentlyContinue) {
            Write-ToolkitMenuDivider
        }
        Write-Host $Prompt -ForegroundColor Cyan
        try {
            $ack = Read-Host
            if ($null -eq $ack) {
                return
            }
        }
        catch {
            $null = $_
        }
    }
    finally {
        if (Get-Command -Name 'Exit-ToolkitConsoleView' -ErrorAction SilentlyContinue) {
            Exit-ToolkitConsoleView
        }
    }
}

if (Get-Command -Name 'Wait-UserAcknowledge' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Wait-UserAcknowledge' -Value (Get-Command -Name 'Wait-UserAcknowledge').ScriptBlock
}
