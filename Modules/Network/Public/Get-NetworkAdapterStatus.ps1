function Get-NetworkAdapterStatus {
<#
.SYNOPSIS
    Enumerates local network adapters and their connectivity status.
.DESCRIPTION
    Retrieves network adapters using Get-NetAdapter / Get-NetIPConfiguration
    or CIM Win32_NetworkAdapter / Win32_NetworkAdapterConfiguration fallbacks,
    returning structured adapter records including Index, Name, Status, IPv4,
    Gateway, and MAC address.
.OUTPUTS
    [PSCustomObject[]] containing Index, Name, Status, IPv4, Gateway, MAC, InterfaceIndex, InterfaceAlias.
.EXAMPLE
    Get-NetworkAdapterStatus
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()

    process {
        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        $adapterIndex = 1

        # 1. Try Get-NetAdapter first if available
        $usedNetAdapter = $false
        if (Get-Command -Name 'Get-NetAdapter' -ErrorAction SilentlyContinue) {
            try {
                $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
                if ($null -ne $adapters -and $adapters.Count -gt 0) {
                    $usedNetAdapter = $true
                    foreach ($ad in $adapters) {
                        if ($null -eq $ad) { continue }
                        $name = if ($ad.Name) { [string]$ad.Name } else { "Adapter$adapterIndex" }
                        $statusRaw = if ($ad.Status) { [string]$ad.Status } else { 'Unknown' }
                        $statusBadge = switch -Regex ($statusRaw) {
                            '^(Up|Connected)$' { '[UP]' }
                            '^(Disabled)$'      { '[DISABLED]' }
                            default             { '[DOWN]' }
                        }
                        $mac = if ($ad.MacAddress) { [string]$ad.MacAddress } else { '--' }
                        $ifIndex = if ($ad.InterfaceIndex) { [int]$ad.InterfaceIndex } else { $adapterIndex }

                        $ipv4 = '--'
                        $gateway = '--'
                        if (Get-Command -Name 'Get-NetIPConfiguration' -ErrorAction SilentlyContinue) {
                            try {
                                $ipConfig = Get-NetIPConfiguration -InterfaceIndex $ifIndex -ErrorAction SilentlyContinue
                                if ($null -ne $ipConfig) {
                                    if ($ipConfig.IPv4Address -and $ipConfig.IPv4Address.IPAddress) {
                                        $ipv4 = [string]($ipConfig.IPv4Address.IPAddress -join ', ')
                                    }
                                    if ($ipConfig.IPv4DefaultGateway -and $ipConfig.IPv4DefaultGateway.NextHop) {
                                        $gateway = [string]($ipConfig.IPv4DefaultGateway.NextHop -join ', ')
                                    }
                                }
                            }
                            catch {
                                $null = $_
                            }
                        }

                        $results.Add([PSCustomObject]@{
                            Index          = $adapterIndex
                            Name           = $name
                            Status         = $statusBadge
                            IPv4           = $ipv4
                            Gateway        = $gateway
                            MAC            = $mac
                            InterfaceIndex = $ifIndex
                            InterfaceAlias = $name
                        })
                        $adapterIndex++
                    }
                }
            }
            catch {
                $usedNetAdapter = $false
            }
        }

        # 2. Fallback to CIM Win32_NetworkAdapter / Win32_NetworkAdapterConfiguration if Get-NetAdapter yielded nothing
        if (-not $usedNetAdapter -or $results.Count -eq 0) {
            if (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
                try {
                    $configs = @{}
                    $cfgList = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue)
                    foreach ($c in $cfgList) {
                        if ($null -ne $c -and $null -ne $c.Index) {
                            $configs[[int]$c.Index] = $c
                        }
                    }

                    $adapters = @(Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction SilentlyContinue)
                    foreach ($ad in $adapters) {
                        if ($null -eq $ad) { continue }
                        if ($null -eq $ad.NetConnectionStatus -and -not $ad.PhysicalAdapter) {
                            continue
                        }
                        $name = if ($ad.NetConnectionID) { [string]$ad.NetConnectionID } elseif ($ad.Name) { [string]$ad.Name } else { "Adapter$adapterIndex" }
                        $statusCode = $ad.NetConnectionStatus
                        $statusBadge = switch ($statusCode) {
                            2       { '[UP]' }
                            0       { '[DISCONNECTED]' }
                            7       { '[MEDIA_DISCONNECTED]' }
                            default {
                                if ($null -ne $statusCode) { '[DOWN]' } else { '[UNKNOWN]' }
                            }
                        }
                        $mac = if ($ad.MACAddress) { [string]$ad.MACAddress } else { '--' }
                        $devId = if ($null -ne $ad.DeviceID) { [int]$ad.DeviceID } elseif ($null -ne $ad.Index) { [int]$ad.Index } else { $adapterIndex }

                        $ipv4 = '--'
                        $gateway = '--'
                        if ($configs.ContainsKey($devId)) {
                            $cfg = $configs[$devId]
                            if ($cfg.IPAddress) {
                                $ipv4List = @($cfg.IPAddress) | Where-Object { $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' }
                                if ($ipv4List.Count -gt 0) {
                                    $ipv4 = $ipv4List -join ', '
                                }
                            }
                            if ($cfg.DefaultIPGateway) {
                                $gwList = @($cfg.DefaultIPGateway) | Where-Object { $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' }
                                if ($gwList.Count -gt 0) {
                                    $gateway = $gwList -join ', '
                                }
                            }
                        }

                        $results.Add([PSCustomObject]@{
                            Index          = $adapterIndex
                            Name           = $name
                            Status         = $statusBadge
                            IPv4           = $ipv4
                            Gateway        = $gateway
                            MAC            = $mac
                            InterfaceIndex = $devId
                            InterfaceAlias = $name
                        })
                        $adapterIndex++
                    }
                }
                catch {
                    $null = $_
                }
            }
        }

        return $results.ToArray()
    }
}
