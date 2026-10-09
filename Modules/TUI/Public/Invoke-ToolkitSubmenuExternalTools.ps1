if (-not (Get-Command -Name Wait-UserAcknowledge -ErrorAction SilentlyContinue)) {
    $waitScript = Join-Path $PSScriptRoot ../Private/Wait-UserAcknowledge.ps1
    if (Test-Path $waitScript) {
        . $waitScript
    }
}

function Get-ExternalToolsContextInfoLines {
    $lines = [System.Collections.Generic.List[string]]::new()

    # 1. Internet Status
    $netStatus = "Checking Connectivity..."
    try {
        if (Get-Command -Name 'Test-InternetConnectivity' -ErrorAction SilentlyContinue) {
            $isOnline = Test-InternetConnectivity
            if ($isOnline) {
                $netStatus = "ONLINE [READY]"
            }
            else {
                $netStatus = "OFFLINE [BLOCKED]"
            }
        }
        else {
            $netStatus = "ONLINE [READY]"
        }
    }
    catch {
        $netStatus = "OFFLINE [BLOCKED]"
    }
    $lines.Add("Internet Check : $netStatus")

    # 2. Integrated Launchers
    $lines.Add("Tool 1         : Browser Debloat (Chrome & Chromium cleanup & debloat) [READY]")
    $lines.Add("Tool 2         : Win11Debloat (Windows 11 bloatware & telemetry purge) [READY]")

    return $lines.ToArray()
}

function Invoke-ToolkitSubmenuExternalTools {
<#
.SYNOPSIS
    Submenu for External Tools & Utilities with Tri-Panel UI/UX.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$ExitImmediately,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    if ($ExitImmediately) {
        Write-ToolkitStatus -Message "Submenu launched with -ExitImmediately flag. Returning." -Type 'INFO'
        return
    }

    $subnav = @(
        @{ Key = 'B'; Label = 'Back to Main Menu' },
        @{ Key = 'Q'; Label = 'Exit Console' }
    )
    $toolsDetails = @(
        @{ Key = '1'; Action = 'Run Browser Debloat'; Description = 'Launch Chrome/Browser debloat utility.'; Prerequisite = 'Internet access [READY]' },
        @{ Key = '2'; Action = 'Run Win11Debloat'; Description = 'Launch Win11Debloat script for bloatware/telemetry purge.'; Prerequisite = 'Internet access [READY]' },
        @{ Key = '3'; Action = 'Run Office Tool Plus'; Description = 'Launch Office Tool Plus for deployment and activation.'; Prerequisite = 'Internet access [READY]' },
        @{ Key = '4'; Action = 'Test Connectivity'; Description = 'Test ICMP ping, HTTP, and HTTPS endpoints.'; Prerequisite = 'Network adapter [READY]' }
    )

    $inSubmenu = $true
    while ($inSubmenu) {
        $clear = if ($NonInteractive) { $false } else { $true }
        $toolsInfo = Get-ExternalToolsContextInfoLines
        Show-ToolkitHeader -Title 'ITOOLKIT > EXTERNAL TOOLS & UTILITIES' -Subtitle 'Pre-Flight Internet Check & External Utility Launchers' -ClearScreen:$clear -InfoLines $toolsInfo
        Show-ToolkitDetailPanel -Details $toolsDetails -NavActions $subnav -Title 'ACTIONS & COMMANDS'

        if ($NonInteractive) {
            Write-ToolkitStatus -Message "Non-interactive category listing complete for 'External Tools & Quick Launchers'." -Type 'INFO'
            return
        }

        $sub = Read-ToolkitMenuChoice -Prompt 'Select' -ValidKeys @('1', '2', '3', '4', 'B', 'Q')
        if ([string]::IsNullOrWhiteSpace($sub) -or $sub.ToUpperInvariant() -eq 'B') {
            $inSubmenu = $false
            break
        }
        if ($sub.ToUpperInvariant() -eq 'Q') {
            $inSubmenu = $false
            return
        }

        switch ($sub) {
            '1' {
                if (Get-Command -Name 'Invoke-BrowserDebloat' -ErrorAction SilentlyContinue) {
                    Invoke-BrowserDebloat | Format-List
                }
            }
            '2' {
                if (Get-Command -Name 'Invoke-Win11Debloat' -ErrorAction SilentlyContinue) {
                    Invoke-Win11Debloat | Format-List
                }
            }
            '3' {
                if (Get-Command -Name 'Invoke-OfficeToolPlus' -ErrorAction SilentlyContinue) {
                    Invoke-OfficeToolPlus | Format-List
                }
                else {
                    Write-ToolkitStatus -Message "Invoke-OfficeToolPlus command not available." -Type 'WARN'
                }
            }
            '4' {
                if (Get-Command -Name 'Test-InternetConnectivity' -ErrorAction SilentlyContinue) {
                    $reachable = Test-InternetConnectivity
                    if ($reachable) {
                        Write-ToolkitStatus -Message "Internet connectivity verified." -Type 'OK'
                    }
                    else {
                        Write-ToolkitStatus -Message "No internet access detected." -Type 'FAIL'
                    }
                }
            }
        }
        Wait-UserAcknowledge
    }
}

if (Get-Command -Name Get-ExternalToolsContextInfoLines -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path function:global:Get-ExternalToolsContextInfoLines -Value (Get-Command -Name Get-ExternalToolsContextInfoLines).ScriptBlock
}
if (Get-Command -Name Invoke-ToolkitSubmenuExternalTools -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path function:global:Invoke-ToolkitSubmenuExternalTools -Value (Get-Command -Name Invoke-ToolkitSubmenuExternalTools).ScriptBlock
}

