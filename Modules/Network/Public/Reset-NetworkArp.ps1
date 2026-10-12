function Reset-NetworkArp {
<#
.SYNOPSIS
    Flushes the ARP cache and IPv4 routing destination cache.
.DESCRIPTION
    Remediates Default Gateway unreachable errors, ARP poisoning, and stale
    MAC address bindings by:
    - Deleting the ARP cache across all network interfaces (netsh interface ip delete arpcache).
    - Deleting the IPv4 route destination cache (netsh interface ipv4 delete destinationcache).
.OUTPUTS
    [PSCustomObject] containing Success, ArpFlushed, DestinationCacheCleared, ErrorMessage.
.EXAMPLE
    Reset-NetworkArp
.EXAMPLE
    Reset-NetworkArp -WhatIf
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
            Write-Warning "Administrative privileges are recommended or required to flush the ARP cache and routing tables."
        }

        # 2. WhatIf / ShouldProcess support
        if (-not $PSCmdlet.ShouldProcess("Network ARP & Routing Subsystem", "Delete ARP neighbor cache and IPv4 destination cache")) {
            return [PSCustomObject]@{
                Success                 = $true
                ArpFlushed              = $true
                DestinationCacheCleared = $true
                ErrorMessage            = ''
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Flushing ARP cache and IPv4 routing destination cache..." -Level 'INFO' -Component 'Network:ARP'
        }

        $netshExe = 'netsh.exe'
        if ($env:SystemRoot) {
            $candNetsh = Join-Path -Path $env:SystemRoot -ChildPath 'System32\netsh.exe'
            if (Test-Path -LiteralPath $candNetsh) {
                $netshExe = $candNetsh
            }
        }

        $arpFlushed     = $false
        $destCleared    = $false
        $errorMessages  = [System.Collections.Generic.List[string]]::new()

        # 3. netsh interface ip delete arpcache
        try {
            $procArp = Start-Process -FilePath $netshExe -ArgumentList @('interface', 'ip', 'delete', 'arpcache') -Wait -NoNewWindow -PassThru -ErrorAction Stop
            if ($null -ne $procArp -and ($null -eq $procArp.ExitCode -or $procArp.ExitCode -eq 0)) {
                $arpFlushed = $true
            }
            else {
                $errorMessages.Add("netsh interface ip delete arpcache returned non-zero exit code")
            }
        }
        catch {
            $errorMessages.Add("Failed executing netsh interface ip delete arpcache: $($_.Exception.Message)")
        }

        # 4. netsh interface ipv4 delete destinationcache
        try {
            $procDest = Start-Process -FilePath $netshExe -ArgumentList @('interface', 'ipv4', 'delete', 'destinationcache') -Wait -NoNewWindow -PassThru -ErrorAction Stop
            if ($null -ne $procDest -and ($null -eq $procDest.ExitCode -or $procDest.ExitCode -eq 0)) {
                $destCleared = $true
            }
            else {
                $errorMessages.Add("netsh interface ipv4 delete destinationcache returned non-zero exit code")
            }
        }
        catch {
            $errorMessages.Add("Failed executing netsh interface ipv4 delete destinationcache: $($_.Exception.Message)")
        }

        $overallSuccess = ($arpFlushed -or $destCleared)
        $errText = if ($errorMessages.Count -gt 0) { $errorMessages -join '; ' } else { '' }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            $level = if ($overallSuccess) { 'SUCCESS' } else { 'WARN' }
            Write-ToolkitLog -Message "ARP reset finished (ArpFlushed: $arpFlushed, DestCleared: $destCleared)" -Level $level -Component 'Network:ARP'
        }

        return [PSCustomObject]@{
            Success                 = [bool]$overallSuccess
            ArpFlushed              = [bool]$arpFlushed
            DestinationCacheCleared = [bool]$destCleared
            ErrorMessage            = [string]$errText
        }
    }
}
