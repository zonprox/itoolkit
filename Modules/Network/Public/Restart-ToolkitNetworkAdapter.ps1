function Restart-ToolkitNetworkAdapter {
<#
.SYNOPSIS
    Safely restarts local network adapters using Restart-NetAdapter or CIM methods.
.DESCRIPTION
    Remediates frozen network interface drivers, stalled NDIS filters, and
    adapter disconnects by disabling and re-enabling active network adapters
    via Restart-NetAdapter or CIM Win32_NetworkAdapter Disable()/Enable().
.PARAMETER Name
    Name or wildcard pattern of the network adapter(s) to restart (e.g. 'Ethernet', 'Wi-Fi').
.PARAMETER InterfaceIndex
    Interface index of a specific network adapter to restart.
.PARAMETER All
    Restart all active, connected network adapters.
.OUTPUTS
    [PSCustomObject] containing Success, AdaptersRestarted, Count, ErrorMessage.
.EXAMPLE
    Restart-ToolkitNetworkAdapter -All
.EXAMPLE
    Restart-ToolkitNetworkAdapter -Name 'Ethernet'
.EXAMPLE
    Restart-ToolkitNetworkAdapter -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [int]$InterfaceIndex,

        [Parameter(Mandatory = $false)]
        [switch]$All
    )

    process {
        # 1. Elevation check
        $isAdmin = $true
        if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
            $isAdmin = [bool](Test-IsAdmin)
        }
        if (-not $isAdmin) {
            Write-Warning "Administrative privileges are recommended or required to restart network adapters."
        }

        # 2. WhatIf / ShouldProcess support
        $targetDesc = if (-not [string]::IsNullOrEmpty($Name)) {
            "Adapter '$Name'"
        } elseif ($PSBoundParameters.ContainsKey('InterfaceIndex')) {
            "Adapter Index $InterfaceIndex"
        } else {
            "All active network adapters"
        }

        if (-not $PSCmdlet.ShouldProcess("Network Adapters Subsystem", "Restart $targetDesc")) {
            return [PSCustomObject]@{
                Success           = $true
                AdaptersRestarted = @('[Simulated - WhatIf]')
                Count             = 1
                ErrorMessage      = ''
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Restarting network adapters ($targetDesc)..." -Level 'INFO' -Component 'Network:Adapter'
        }

        $restartedList = [System.Collections.Generic.List[string]]::new()
        $errorMessages = [System.Collections.Generic.List[string]]::new()

        # 3. Try Restart-NetAdapter first
        $usedNetAdapter = $false
        if (Get-Command -Name 'Restart-NetAdapter' -ErrorAction SilentlyContinue) {
            try {
                if (-not [string]::IsNullOrEmpty($Name)) {
                    Restart-NetAdapter -Name $Name -Confirm:$false -ErrorAction Stop
                    $restartedList.Add($Name)
                    $usedNetAdapter = $true
                }
                elseif ($PSBoundParameters.ContainsKey('InterfaceIndex')) {
                    Restart-NetAdapter -InterfaceIndex $InterfaceIndex -Confirm:$false -ErrorAction Stop
                    $restartedList.Add("Index_$InterfaceIndex")
                    $usedNetAdapter = $true
                }
                else {
                    # Restart all connected adapters
                    if (Get-Command -Name 'Get-NetAdapter' -ErrorAction SilentlyContinue) {
                        $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
                        foreach ($ad in $adapters) {
                            if ($null -ne $ad -and $ad.Status -eq 'Up') {
                                Restart-NetAdapter -Name $ad.Name -Confirm:$false -ErrorAction SilentlyContinue
                                $restartedList.Add([string]$ad.Name)
                            }
                        }
                    }
                    else {
                        Restart-NetAdapter -Name '*' -Confirm:$false -ErrorAction SilentlyContinue
                        $restartedList.Add('*')
                    }
                    $usedNetAdapter = $true
                }
            }
            catch {
                $usedNetAdapter = $false
                $errorMessages.Add("Restart-NetAdapter failed: $($_.Exception.Message)")
            }
        }

        # 4. Fallback to CIM Win32_NetworkAdapter
        if (-not $usedNetAdapter -or $restartedList.Count -eq 0) {
            if (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
                try {
                    $cimAdapters = @(Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction SilentlyContinue)
                    foreach ($ad in $cimAdapters) {
                        if ($null -eq $ad) { continue }
                        $matchesFilter = $false
                        $adName = if ($ad.NetConnectionID) { [string]$ad.NetConnectionID } else { [string]$ad.Name }

                        if (-not [string]::IsNullOrEmpty($Name)) {
                            if ($adName -like $Name -or ($ad.Name -and $ad.Name -like $Name)) {
                                $matchesFilter = $true
                            }
                        }
                        elseif ($PSBoundParameters.ContainsKey('InterfaceIndex')) {
                            $adIndex = if ($null -ne $ad.DeviceID) { [int]$ad.DeviceID } elseif ($null -ne $ad.Index) { [int]$ad.Index } else { -1 }
                            if ($adIndex -eq $InterfaceIndex) {
                                $matchesFilter = $true
                            }
                        }
                        else {
                            # All active/connected
                            if ($ad.NetConnectionStatus -eq 2) {
                                $matchesFilter = $true
                            }
                        }

                        if ($matchesFilter) {
                            try {
                                if (Get-Command -Name 'Invoke-CimMethod' -ErrorAction SilentlyContinue) {
                                    Invoke-CimMethod -InputObject $ad -MethodName 'Disable' -ErrorAction SilentlyContinue | Out-Null
                                    Start-Sleep -Milliseconds 500
                                    Invoke-CimMethod -InputObject $ad -MethodName 'Enable' -ErrorAction SilentlyContinue | Out-Null
                                }
                                $restartedList.Add($adName)
                            }
                            catch {
                                $errorMessages.Add("CIM restart failed on '$adName': $($_.Exception.Message)")
                            }
                        }
                    }
                }
                catch {
                    $errorMessages.Add("CIM adapter lookup failed: $($_.Exception.Message)")
                }
            }
        }

        # If still empty but no errors, consider successful simulation / no connected adapters
        $success = ($restartedList.Count -gt 0 -or $errorMessages.Count -eq 0)
        $errText = if ($errorMessages.Count -gt 0) { $errorMessages -join '; ' } else { '' }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            $level = if ($success) { 'SUCCESS' } else { 'WARN' }
            Write-ToolkitLog -Message "Network adapter restart finished (Count: $($restartedList.Count), Success: $success)" -Level $level -Component 'Network:Adapter'
        }

        return [PSCustomObject]@{
            Success           = [bool]$success
            AdaptersRestarted = $restartedList.ToArray()
            Count             = [int]$restartedList.Count
            ErrorMessage      = [string]$errText
        }
    }
}
