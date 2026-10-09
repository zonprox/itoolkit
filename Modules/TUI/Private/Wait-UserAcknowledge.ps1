<#
.SYNOPSIS
    Waits for user acknowledgement and prompts before returning to the menu.
.DESCRIPTION
    Pauses interactive console execution until the user presses [Enter].
    Automatically bypasses pausing if input is redirected or running in headless mode.
#>
function Wait-UserAcknowledge {
    [CmdletBinding()]
    param()

    try {
        if ([Console]::IsInputRedirected) {
            return
        }
    }
    catch {
        $null = $_
    }

    Write-Host ""
    if (Get-Command -Name 'Write-ToolkitMenuDivider' -ErrorAction SilentlyContinue) {
        Write-ToolkitMenuDivider
    }
    Write-Host "  Press [Enter] to return to menu..." -ForegroundColor Cyan
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

if (Get-Command -Name 'Wait-UserAcknowledge' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Wait-UserAcknowledge' -Value (Get-Command -Name 'Wait-UserAcknowledge').ScriptBlock
}
