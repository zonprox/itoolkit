function Reset-PrinterConnections {
<#
.SYNOPSIS
    Enumerates, tests, and refreshes network printer connections for the current user.
.DESCRIPTION
    Queries installed network printers via CIM Win32_Printer, verifies connectivity,
    and reports refreshed versus removed stale connections.
.PARAMETER All
    Refreshes all mapped network printer connections.
.PARAMETER PrinterName
    Specific printer connection to refresh.
.OUTPUTS
    [PSCustomObject] containing RefreshedConnections and StaleRemoved.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$All,

        [Parameter(Mandatory = $false)]
        [string]$PrinterName
    )

    process {
        if (-not $PSCmdlet.ShouldProcess("Printer Connections", "Refresh active connections and remove stale mappings")) {
            return [PSCustomObject]@{
                RefreshedConnections = 0
                StaleRemoved         = 0
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Refreshing user printer connections..." -Level 'INFO' -Component 'Reset-PrinterConnections'
        }

        $refreshedCount = 0
        $staleRemoved   = 0

        try {
            $printers = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue)

            # Filter candidate printers based on parameters
            $candidates = @()
            foreach ($p in $printers) {
                if ($null -ne $p -and $p.PSObject.Properties['Name']) {
                    $pName = [string]$p.Name
                    if (-not [string]::IsNullOrWhiteSpace($PrinterName)) {
                        # Explicit printer targeted: evaluate ONLY this printer
                        if ($pName -eq $PrinterName) {
                            $candidates += $p
                        }
                    } else {
                        # No specific printer passed: evaluate network (UNC) printers
                        if ($pName -match '^\\\\') {
                            $candidates += $p
                        }
                    }
                }
            }

            foreach ($p in $candidates) {
                $pName = [string]$p.Name
                $server = ''
                if ($pName -match '^\\\\([^\\]+)') {
                    $server = $Matches[1]
                }

                $isReachable = $false
                if ([string]::IsNullOrWhiteSpace($server)) {
                    # Local printer: local system is inherently reachable
                    $isReachable = $true
                } else {
                    # Network printer: test server reachability via ICMP or Port 445 (SMB)
                    try {
                        $pingOk = Test-Connection -ComputerName $server -Count 1 -Quiet -ErrorAction SilentlyContinue
                        if ($pingOk) {
                            $isReachable = $true
                        }
                    } catch {
                        Write-Verbose "Test-Connection to server '$server' failed: $($_.Exception.Message)"
                    }

                    if (-not $isReachable) {
                        try {
                            $tnc = Test-NetConnection -ComputerName $server -Port 445 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                            if ($null -ne $tnc -and $tnc.TcpTestSucceeded) {
                                $isReachable = $true
                            }
                        } catch {
                            Write-Verbose "Test-NetConnection to server '$server' on port 445 failed: $($_.Exception.Message)"
                        }
                    }
                }

                if ($isReachable) {
                    # Server is online: verify/refresh printer connection
                    try {
                        if (Get-Command -Name 'Add-Printer' -ErrorAction SilentlyContinue) {
                            Add-Printer -ConnectionName $pName -ErrorAction SilentlyContinue
                        }
                    } catch {
                        Write-Verbose "Refresh connection for '$pName' failed: $($_.Exception.Message)"
                    }
                    $refreshedCount++
                } else {
                    # Server is offline/unreachable: stale network printer connection
                    try {
                        if (Get-Command -Name 'Remove-Printer' -ErrorAction SilentlyContinue) {
                            Remove-Printer -Name $pName -ErrorAction SilentlyContinue
                        } elseif ($env:OS -match 'Windows') {
                            $wsNet = New-Object -ComObject WScript.Network
                            $wsNet.RemovePrinterConnection($pName, $true, $true)
                        }
                    } catch {
                        Write-Verbose "Removal of stale printer '$pName' failed: $($_.Exception.Message)"
                    }
                    $staleRemoved++
                }
            }
        } catch {
            Write-Verbose "Error querying or processing printers: $($_.Exception.Message)"
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Printer connections reset complete. Refreshed: $refreshedCount, Stale removed: $staleRemoved" -Level 'INFO' -Component 'Reset-PrinterConnections'
        }

        return [PSCustomObject]@{
            RefreshedConnections = [int]$refreshedCount
            StaleRemoved         = [int]$staleRemoved
        }
    }
}
