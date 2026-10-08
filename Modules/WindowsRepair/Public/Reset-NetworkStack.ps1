function Reset-NetworkStack {
<#
.SYNOPSIS
    Resets Windows network sockets, TCP/IP stack configuration, and flushes DNS cache.
.DESCRIPTION
    Executes 'netsh winsock reset', 'netsh int ip reset', and 'ipconfig /flushdns'
    to remediate network connectivity failures, socket leaks, and stale DNS records.
.OUTPUTS
    [PSCustomObject] containing WinsockReset, IpReset, DnsFlushed, and Success.
.EXAMPLE
    Reset-NetworkStack
.EXAMPLE
    Reset-NetworkStack -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param()

    process {
        # 1. Admin elevation check
        $isAdmin = $true
        if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
            $isAdmin = [bool](Test-IsAdmin)
        }
        if (-not $isAdmin) {
            Write-Warning "Administrative privileges are recommended or required to reset the network stack. Current session is not elevated."
        }

        # 2. Support ShouldProcess / WhatIf
        if (-not $PSCmdlet.ShouldProcess("Network Stack Subsystem", "Reset Winsock catalog, reset TCP/IP stack, and flush DNS cache")) {
            return [PSCustomObject]@{
                WinsockReset = $true
                IpReset      = $true
                DnsFlushed   = $true
                Success      = $true
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Resetting Windows network stack and DNS resolver..." -Level 'INFO' -Component 'WindowsRepair:Network'
        }

        # 3. Locate executables
        $netshExe = 'netsh.exe'
        $ipconfigExe = 'ipconfig.exe'
        if ($env:SystemRoot) {
            $candNetsh = Join-Path -Path $env:SystemRoot -ChildPath 'System32\netsh.exe'
            if (Test-Path -LiteralPath $candNetsh) {
                $netshExe = $candNetsh
            }
            $candIp = Join-Path -Path $env:SystemRoot -ChildPath 'System32\ipconfig.exe'
            if (Test-Path -LiteralPath $candIp) {
                $ipconfigExe = $candIp
            }
        }

        $winsockReset = $false
        $ipReset      = $false
        $dnsFlushed   = $false

        # 4. netsh winsock reset
        try {
            $pWinsock = Start-Process -FilePath $netshExe -ArgumentList @('winsock', 'reset') -Wait -NoNewWindow -PassThru -ErrorAction Stop
            if ($null -ne $pWinsock -and ($null -eq $pWinsock.ExitCode -or $pWinsock.ExitCode -eq 0)) {
                $winsockReset = $true
            }
        }
        catch {
            Write-Warning "Failed executing netsh winsock reset: $($_.Exception.Message)"
        }

        # 5. netsh int ip reset
        try {
            $pIp = Start-Process -FilePath $netshExe -ArgumentList @('int', 'ip', 'reset') -Wait -NoNewWindow -PassThru -ErrorAction Stop
            if ($null -ne $pIp -and ($null -eq $pIp.ExitCode -or $pIp.ExitCode -eq 0)) {
                $ipReset = $true
            }
        }
        catch {
            Write-Warning "Failed executing netsh int ip reset: $($_.Exception.Message)"
        }

        # 6. ipconfig /flushdns
        try {
            $pDns = Start-Process -FilePath $ipconfigExe -ArgumentList @('/flushdns') -Wait -NoNewWindow -PassThru -ErrorAction Stop
            if ($null -ne $pDns -and ($null -eq $pDns.ExitCode -or $pDns.ExitCode -eq 0)) {
                $dnsFlushed = $true
            }
        }
        catch {
            Write-Warning "Failed executing ipconfig /flushdns: $($_.Exception.Message)"
        }

        $success = ($winsockReset -and $ipReset -and $dnsFlushed)

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            $logLevel = if ($success) { 'SUCCESS' } else { 'WARN' }
            Write-ToolkitLog -Message "Network stack reset finished (Winsock: $winsockReset, IP: $ipReset, DNS: $dnsFlushed)" -Level $logLevel -Component 'WindowsRepair:Network'
        }

        return [PSCustomObject]@{
            WinsockReset = [bool]$winsockReset
            IpReset      = [bool]$ipReset
            DnsFlushed   = [bool]$dnsFlushed
            Success      = [bool]$success
        }
    }
}
