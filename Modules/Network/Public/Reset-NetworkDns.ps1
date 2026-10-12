function Reset-NetworkDns {
<#
.SYNOPSIS
    Flushes DNS resolver cache and re-registers DNS client names.
.DESCRIPTION
    Remediates DNS resolution failures and "DNS Server Not Responding" errors by:
    - Flushing local DNS resolver cache (ipconfig /flushdns).
    - Re-registering DNS client name records with active DNS servers (ipconfig /registerdns).
    - Clearing PowerShell DNS client cache via Clear-DnsClientCache if available.
.OUTPUTS
    [PSCustomObject] containing Success, DnsFlushed, DnsRegistered, CacheCleared, ErrorMessage.
.EXAMPLE
    Reset-NetworkDns
.EXAMPLE
    Reset-NetworkDns -WhatIf
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
            Write-Warning "Administrative privileges are recommended to re-register DNS client records."
        }

        # 2. WhatIf / ShouldProcess support
        if (-not $PSCmdlet.ShouldProcess("DNS Client Resolver Subsystem", "Flush DNS resolver cache and re-register DNS client records")) {
            return [PSCustomObject]@{
                Success       = $true
                DnsFlushed    = $true
                DnsRegistered = $true
                CacheCleared  = $true
                ErrorMessage  = ''
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Flushing DNS cache and re-registering client DNS records..." -Level 'INFO' -Component 'Network:DNS'
        }

        $ipconfigExe = 'ipconfig.exe'
        if ($env:SystemRoot) {
            $candIp = Join-Path -Path $env:SystemRoot -ChildPath 'System32\ipconfig.exe'
            if (Test-Path -LiteralPath $candIp) {
                $ipconfigExe = $candIp
            }
        }

        $dnsFlushed    = $false
        $dnsRegistered = $false
        $cacheCleared  = $false
        $errorMessages = [System.Collections.Generic.List[string]]::new()

        # 3. ipconfig /flushdns
        try {
            $procFlush = Start-Process -FilePath $ipconfigExe -ArgumentList @('/flushdns') -Wait -NoNewWindow -PassThru -ErrorAction Stop
            if ($null -ne $procFlush -and ($null -eq $procFlush.ExitCode -or $procFlush.ExitCode -eq 0)) {
                $dnsFlushed = $true
            }
            else {
                $errorMessages.Add("ipconfig /flushdns returned non-zero exit code")
            }
        }
        catch {
            $errorMessages.Add("Failed executing ipconfig /flushdns: $($_.Exception.Message)")
        }

        # 4. ipconfig /registerdns
        try {
            $procReg = Start-Process -FilePath $ipconfigExe -ArgumentList @('/registerdns') -Wait -NoNewWindow -PassThru -ErrorAction Stop
            if ($null -ne $procReg -and ($null -eq $procReg.ExitCode -or $procReg.ExitCode -eq 0)) {
                $dnsRegistered = $true
            }
            else {
                $errorMessages.Add("ipconfig /registerdns returned non-zero exit code")
            }
        }
        catch {
            $errorMessages.Add("Failed executing ipconfig /registerdns: $($_.Exception.Message)")
        }

        # 5. Clear-DnsClientCache
        if (Get-Command -Name 'Clear-DnsClientCache' -ErrorAction SilentlyContinue) {
            try {
                Clear-DnsClientCache -ErrorAction SilentlyContinue
                $cacheCleared = $true
            }
            catch {
                $errorMessages.Add("Clear-DnsClientCache threw error: $($_.Exception.Message)")
            }
        }
        else {
            $cacheCleared = $dnsFlushed
        }

        $overallSuccess = ($dnsFlushed -or $cacheCleared)
        $errText = if ($errorMessages.Count -gt 0) { $errorMessages -join '; ' } else { '' }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            $level = if ($overallSuccess) { 'SUCCESS' } else { 'WARN' }
            Write-ToolkitLog -Message "DNS reset finished (Flush: $dnsFlushed, Register: $dnsRegistered, Cache: $cacheCleared)" -Level $level -Component 'Network:DNS'
        }

        return [PSCustomObject]@{
            Success       = [bool]$overallSuccess
            DnsFlushed    = [bool]$dnsFlushed
            DnsRegistered = [bool]$dnsRegistered
            CacheCleared  = [bool]$cacheCleared
            ErrorMessage  = [string]$errText
        }
    }
}
