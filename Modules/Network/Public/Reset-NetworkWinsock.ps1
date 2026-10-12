function Reset-NetworkWinsock {
<#
.SYNOPSIS
    Resets the Windows Sockets (Winsock) catalog to a clean system default state.
.DESCRIPTION
    Remediates Winsock corruption, third-party LSP hook damage, and socket errors
    (e.g. Socket Error 10013 WSAEACCES, 10054 WSAECONNRESET) by executing:
    'netsh winsock reset catalog'.
    A system restart is recommended following catalog reset to ensure kernel-level
    socket providers reload cleanly.
.OUTPUTS
    [PSCustomObject] containing Success, WinsockReset, RebootRequired, ErrorMessage.
.EXAMPLE
    Reset-NetworkWinsock
.EXAMPLE
    Reset-NetworkWinsock -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param()

    process {
        # 1. Elevation check
        $isAdmin = $true
        if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
            $isAdmin = [bool](Test-IsAdmin)
        }
        if (-not $isAdmin) {
            Write-Warning "Administrative privileges are recommended or required to reset the Winsock catalog."
        }

        # 2. WhatIf / ShouldProcess support
        if (-not $PSCmdlet.ShouldProcess("Windows Sockets Subsystem", "Reset Winsock catalog to default state")) {
            return [PSCustomObject]@{
                Success        = $true
                WinsockReset   = $true
                RebootRequired = $true
                ErrorMessage   = ''
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Resetting Winsock catalog to default state..." -Level 'INFO' -Component 'Network:Winsock'
        }

        $netshExe = 'netsh.exe'
        if ($env:SystemRoot) {
            $candNetsh = Join-Path -Path $env:SystemRoot -ChildPath 'System32\netsh.exe'
            if (Test-Path -LiteralPath $candNetsh) {
                $netshExe = $candNetsh
            }
        }

        $winsockReset  = $false
        $errorMessages = [System.Collections.Generic.List[string]]::new()

        try {
            # Try 'winsock reset catalog'
            $procReset = Start-Process -FilePath $netshExe -ArgumentList @('winsock', 'reset', 'catalog') -Wait -NoNewWindow -PassThru -ErrorAction Stop
            if ($null -ne $procReset -and ($null -eq $procReset.ExitCode -or $procReset.ExitCode -eq 0)) {
                $winsockReset = $true
            }
            else {
                # Fallback to 'winsock reset'
                $procReset2 = Start-Process -FilePath $netshExe -ArgumentList @('winsock', 'reset') -Wait -NoNewWindow -PassThru -ErrorAction SilentlyContinue
                if ($null -ne $procReset2 -and ($null -eq $procReset2.ExitCode -or $procReset2.ExitCode -eq 0)) {
                    $winsockReset = $true
                }
                else {
                    $errorMessages.Add("netsh winsock reset catalog returned non-zero exit code")
                }
            }
        }
        catch {
            $errorMessages.Add("Failed executing netsh winsock reset: $($_.Exception.Message)")
        }

        $errText = if ($errorMessages.Count -gt 0) { $errorMessages -join '; ' } else { '' }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            $level = if ($winsockReset) { 'SUCCESS' } else { 'WARN' }
            Write-ToolkitLog -Message "Winsock reset finished (Success: $winsockReset, RebootRequired: $winsockReset)" -Level $level -Component 'Network:Winsock'
        }

        return [PSCustomObject]@{
            Success        = [bool]$winsockReset
            WinsockReset   = [bool]$winsockReset
            RebootRequired = [bool]$winsockReset
            ErrorMessage   = [string]$errText
        }
    }
}
