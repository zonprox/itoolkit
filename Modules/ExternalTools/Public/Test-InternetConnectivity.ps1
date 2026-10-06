function Test-InternetConnectivity {
<#
.SYNOPSIS
    Verifies outbound internet connectivity using ICMP ping and HTTP/HTTPS web requests.
.DESCRIPTION
    Tests reachability against default or specified public endpoints (1.1.1.1, github.com, etc.).
    Returns $true if any target endpoint responds, and $false if all fail or are unreachable.
.PARAMETER TargetHosts
    Optional list of host names, IP addresses, or URLs to test.
.OUTPUTS
    [bool] Returns $true if internet access is detected, $false otherwise.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string[]]$TargetHosts
    )

    process {
        if ($null -eq $TargetHosts -or $TargetHosts.Count -eq 0) {
            $TargetHosts = @('1.1.1.1', '8.8.8.8', 'github.com', 'www.microsoft.com')
        }

        # 1. ICMP Ping Check
        foreach ($hostItem in $TargetHosts) {
            try {
                $pingSuccess = Test-Connection -ComputerName $hostItem -Count 1 -Quiet -ErrorAction Stop
                if ($pingSuccess) {
                    return $true
                }
            } catch {
                Write-Verbose "Test-Connection failed for '$hostItem': $($_.Exception.Message)"
            }
        }

        # 2. HTTP/HTTPS Web Request Fallback
        foreach ($hostItem in $TargetHosts) {
            try {
                $uri = $hostItem
                if ($uri -notmatch '^https?://') {
                    $uri = "https://$hostItem"
                }
                $webResp = Invoke-WebRequest -Uri $uri -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
                if ($null -ne $webResp -and $webResp.StatusCode -ge 200 -and $webResp.StatusCode -lt 400) {
                    return $true
                }
            } catch {
                Write-Verbose "Invoke-WebRequest failed for '$hostItem': $($_.Exception.Message)"
            }
        }

        return $false
    }
}
