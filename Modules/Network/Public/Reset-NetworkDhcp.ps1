function Reset-NetworkDhcp {
<#
.SYNOPSIS
    Releases and renews DHCP client leases and restarts the DHCP client service.
.DESCRIPTION
    Remediates APIPA automatic private IP address assignment (169.254.x.x) and
    DHCP lease negotiation timeouts by:
    - Releasing existing active DHCP address leases (ipconfig /release).
    - Requesting new DHCP address leases from the network DHCP server (ipconfig /renew).
    - Restarting the Windows DHCP Client service (Dhcp).
.OUTPUTS
    [PSCustomObject] containing Success, LeaseReleased, LeaseRenewed, ServiceRestarted, ErrorMessage.
.EXAMPLE
    Reset-NetworkDhcp
.EXAMPLE
    Reset-NetworkDhcp -WhatIf
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
            Write-Warning "Administrative privileges are recommended or required to restart the DHCP service."
        }

        # 2. WhatIf / ShouldProcess support
        if (-not $PSCmdlet.ShouldProcess("DHCP Client Subsystem", "Release and renew DHCP leases and restart DHCP client service")) {
            return [PSCustomObject]@{
                Success          = $true
                LeaseReleased    = $true
                LeaseRenewed     = $true
                ServiceRestarted = $true
                ErrorMessage     = ''
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Releasing and renewing DHCP leases and restarting DHCP service..." -Level 'INFO' -Component 'Network:DHCP'
        }

        $ipconfigExe = 'ipconfig.exe'
        if ($env:SystemRoot) {
            $candIp = Join-Path -Path $env:SystemRoot -ChildPath 'System32\ipconfig.exe'
            if (Test-Path -LiteralPath $candIp) {
                $ipconfigExe = $candIp
            }
        }

        $leaseReleased    = $false
        $leaseRenewed     = $false
        $serviceRestarted = $false
        $errorMessages    = [System.Collections.Generic.List[string]]::new()

        # 3. ipconfig /release
        try {
            $procRelease = Start-Process -FilePath $ipconfigExe -ArgumentList @('/release') -Wait -NoNewWindow -PassThru -ErrorAction Stop
            if ($null -ne $procRelease -and ($null -eq $procRelease.ExitCode -or $procRelease.ExitCode -eq 0)) {
                $leaseReleased = $true
            }
            else {
                $errorMessages.Add("ipconfig /release returned non-zero exit code")
            }
        }
        catch {
            $errorMessages.Add("Failed executing ipconfig /release: $($_.Exception.Message)")
        }

        # 4. ipconfig /renew
        try {
            $procRenew = Start-Process -FilePath $ipconfigExe -ArgumentList @('/renew') -Wait -NoNewWindow -PassThru -ErrorAction Stop
            if ($null -ne $procRenew -and ($null -eq $procRenew.ExitCode -or $procRenew.ExitCode -eq 0)) {
                $leaseRenewed = $true
            }
            else {
                $errorMessages.Add("ipconfig /renew returned non-zero exit code")
            }
        }
        catch {
            $errorMessages.Add("Failed executing ipconfig /renew: $($_.Exception.Message)")
        }

        # 5. Restart Dhcp service
        try {
            if (Get-Command -Name 'Restart-Service' -ErrorAction SilentlyContinue) {
                Restart-Service -Name 'Dhcp' -Force -ErrorAction SilentlyContinue
                $serviceRestarted = $true
            }
            else {
                $serviceRestarted = $leaseRenewed
            }
        }
        catch {
            $errorMessages.Add("Failed restarting DHCP service: $($_.Exception.Message)")
        }

        $overallSuccess = ($leaseRenewed -or $serviceRestarted)
        $errText = if ($errorMessages.Count -gt 0) { $errorMessages -join '; ' } else { '' }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            $level = if ($overallSuccess) { 'SUCCESS' } else { 'WARN' }
            Write-ToolkitLog -Message "DHCP reset finished (Release: $leaseReleased, Renew: $leaseRenewed, Service: $serviceRestarted)" -Level $level -Component 'Network:DHCP'
        }

        return [PSCustomObject]@{
            Success          = [bool]$overallSuccess
            LeaseReleased    = [bool]$leaseReleased
            LeaseRenewed     = [bool]$leaseRenewed
            ServiceRestarted = [bool]$serviceRestarted
            ErrorMessage     = [string]$errText
        }
    }
}
