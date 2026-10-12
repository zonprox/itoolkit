function Test-NetworkPrinterConnectivity {
<#
.SYNOPSIS
    Tests network reachability, ping latency, and port connectivity to a printer or print server.
.DESCRIPTION
    Validates ICMP ping reachability and tests TCP ports 445 (SMB), 135 (RPC), and 9100 (RAW print).
.PARAMETER ComputerName
    Host name or IP address of the target printer or print server.
.PARAMETER Ports
    Optional custom array of TCP ports to test.
.OUTPUTS
    [PSCustomObject] containing PingSuccess, SmbPortOpen, RpcPortOpen, RawPrintPortOpen, and CustomPortResults.
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory = $false)]
        [int[]]$Ports
    )

    process {
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Testing network printer connectivity for '$ComputerName'..." -Level 'INFO' -Component 'Test-NetworkPrinterConnectivity'
        }

        # 1. ICMP Ping Test
        $pingSuccess = $false
        try {
            $pingResult = Test-Connection -ComputerName $ComputerName -Count 1 -Quiet -ErrorAction Stop
            if ($pingResult) {
                $pingSuccess = $true
            }
        } catch {
            Write-Verbose "Test-Connection failed for '$ComputerName': $($_.Exception.Message)"
        }

        # 2. Port Testing (SMB 445, RPC 135, RAW 9100)
        $smbPortOpen      = $false
        $rpcPortOpen      = $false
        $rawPrintPortOpen = $false

        # SMB 445
        try {
            $smbTest = Test-NetConnection -ComputerName $ComputerName -Port 445 -WarningAction SilentlyContinue
            if ($null -ne $smbTest -and $smbTest.TcpTestSucceeded) {
                $smbPortOpen = $true
            }
        } catch {
            Write-Verbose "SMB port check failed: $($_.Exception.Message)"
        }

        # RPC 135
        try {
            $rpcTest = Test-NetConnection -ComputerName $ComputerName -Port 135 -WarningAction SilentlyContinue
            if ($null -ne $rpcTest -and $rpcTest.TcpTestSucceeded) {
                $rpcPortOpen = $true
            }
        } catch {
            Write-Verbose "RPC port check failed: $($_.Exception.Message)"
        }

        # RAW 9100
        try {
            $rawTest = Test-NetConnection -ComputerName $ComputerName -Port 9100 -WarningAction SilentlyContinue
            if ($null -ne $rawTest -and $rawTest.TcpTestSucceeded) {
                $rawPrintPortOpen = $true
            }
        } catch {
            Write-Verbose "RAW print port check failed: $($_.Exception.Message)"
        }

        # 3. Custom Ports Testing (if supplied)
        $customPortResults = @{}
        if ($null -ne $Ports -and $Ports.Count -gt 0) {
            foreach ($p in $Ports) {
                $pOpen = $false
                try {
                    $cTest = Test-NetConnection -ComputerName $ComputerName -Port $p -WarningAction SilentlyContinue
                    if ($null -ne $cTest -and $cTest.TcpTestSucceeded) {
                        $pOpen = $true
                    }
                } catch {
                    Write-Verbose "Custom port $p check failed: $($_.Exception.Message)"
                }
                $customPortResults[$p] = [bool]$pOpen

                # Update standard flags if matching standard ports
                if ($p -eq 445) { $smbPortOpen = [bool]$pOpen }
                if ($p -eq 135) { $rpcPortOpen = [bool]$pOpen }
                if ($p -eq 9100) { $rawPrintPortOpen = [bool]$pOpen }
            }
        }

        return [PSCustomObject]@{
            PingSuccess       = [bool]$pingSuccess
            SmbPortOpen       = [bool]$smbPortOpen
            RpcPortOpen       = [bool]$rpcPortOpen
            RawPrintPortOpen  = [bool]$rawPrintPortOpen
            CustomPortResults = $customPortResults
        }
    }
}
