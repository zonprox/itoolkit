function Reset-NetworkTcpIp {
<#
.SYNOPSIS
    Resets the TCP/IP stack parameters and TCP global autotuning.
.DESCRIPTION
    Remediates TCP/IP stack corruption, damaged IP registry parameters, and
    corrupted autotuning settings by executing:
    - netsh int ip reset
    - netsh int tcp reset
    A system restart is recommended to complete IP stack re-initialization.
.OUTPUTS
    [PSCustomObject] containing Success, IpReset, TcpReset, RebootRequired, ErrorMessage.
.EXAMPLE
    Reset-NetworkTcpIp
.EXAMPLE
    Reset-NetworkTcpIp -WhatIf
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
            Write-Warning "Administrative privileges are recommended or required to reset the TCP/IP stack."
        }

        # 2. WhatIf / ShouldProcess support
        if (-not $PSCmdlet.ShouldProcess("TCP/IP Protocol Stack", "Reset IP configuration parameters and TCP autotuning")) {
            return [PSCustomObject]@{
                Success        = $true
                IpReset        = $true
                TcpReset       = $true
                RebootRequired = $true
                ErrorMessage   = ''
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Resetting TCP/IP protocol stack and autotuning parameters..." -Level 'INFO' -Component 'Network:TcpIp'
        }

        $netshExe = 'netsh.exe'
        if ($env:SystemRoot) {
            $candNetsh = Join-Path -Path $env:SystemRoot -ChildPath 'System32\netsh.exe'
            if (Test-Path -LiteralPath $candNetsh) {
                $netshExe = $candNetsh
            }
        }

        $ipReset       = $false
        $tcpReset      = $false
        $errorMessages = [System.Collections.Generic.List[string]]::new()

        # 3. netsh int ip reset
        try {
            $procIp = Start-Process -FilePath $netshExe -ArgumentList @('int', 'ip', 'reset') -Wait -NoNewWindow -PassThru -ErrorAction Stop
            if ($null -ne $procIp -and ($null -eq $procIp.ExitCode -or $procIp.ExitCode -eq 0)) {
                $ipReset = $true
            }
            else {
                $errorMessages.Add("netsh int ip reset returned non-zero exit code")
            }
        }
        catch {
            $errorMessages.Add("Failed executing netsh int ip reset: $($_.Exception.Message)")
        }

        # 4. netsh int tcp reset
        try {
            $procTcp = Start-Process -FilePath $netshExe -ArgumentList @('int', 'tcp', 'reset') -Wait -NoNewWindow -PassThru -ErrorAction Stop
            if ($null -ne $procTcp -and ($null -eq $procTcp.ExitCode -or $procTcp.ExitCode -eq 0)) {
                $tcpReset = $true
            }
            else {
                $errorMessages.Add("netsh int tcp reset returned non-zero exit code")
            }
        }
        catch {
            $errorMessages.Add("Failed executing netsh int tcp reset: $($_.Exception.Message)")
        }

        $overallSuccess = ($ipReset -or $tcpReset)
        $errText = if ($errorMessages.Count -gt 0) { $errorMessages -join '; ' } else { '' }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            $level = if ($overallSuccess) { 'SUCCESS' } else { 'WARN' }
            Write-ToolkitLog -Message "TCP/IP stack reset finished (IpReset: $ipReset, TcpReset: $tcpReset)" -Level $level -Component 'Network:TcpIp'
        }

        return [PSCustomObject]@{
            Success        = [bool]$overallSuccess
            IpReset        = [bool]$ipReset
            TcpReset       = [bool]$tcpReset
            RebootRequired = [bool]$overallSuccess
            ErrorMessage   = [string]$errText
        }
    }
}
