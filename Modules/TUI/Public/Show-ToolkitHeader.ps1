function Get-ToolkitTelemetryData {
    <#
    .SYNOPSIS
        Gathers detailed, accurate hardware and OS telemetry across Windows and non-Windows environments.
    .DESCRIPTION
        Collects CPU model name (Registry -> CIM -> %PROCESSOR_IDENTIFIER%), physical installed RAM and free RAM
        (CIM Win32_ComputerSystem / Win32_OperatingSystem -> GC fallback), Windows 11 vs 10 build/revision
        (CurrentBuild.UBR & DisplayVersion), BIOS hardware manufacturer and model (Registry -> CIM fallback),
        primary active physical IPv4 address (filtering virtual/loopback), and dynamic system drive metrics.
    #>
        [CmdletBinding()]
        param()

        # 1. OS & Build Detection (Windows 11 vs Windows 10 resolution with DisplayVersion & UBR)
        $productName = $null
        $displayVer = $null
        $buildNumber = $null
        $ubr = $null
        $buildInt = 0

        try {
            if (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue) {
                $reg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
                if ($null -ne $reg) {
                    if (-not [string]::IsNullOrWhiteSpace($reg.ProductName)) {
                        $productName = $reg.ProductName.Trim()
                    }
                    if (-not [string]::IsNullOrWhiteSpace($reg.DisplayVersion)) {
                        $displayVer = $reg.DisplayVersion.Trim()
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace($reg.ReleaseId)) {
                        $displayVer = $reg.ReleaseId.Trim()
                    }

                    if (-not [string]::IsNullOrWhiteSpace($reg.CurrentBuildNumber)) {
                        $buildNumber = $reg.CurrentBuildNumber.Trim()
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace($reg.CurrentBuild)) {
                        $buildNumber = $reg.CurrentBuild.Trim()
                    }

                    if ($null -ne $reg.UBR -and "$($reg.UBR)" -ne '') {
                        $ubr = $reg.UBR
                    }
                }
            }
        }
        catch {
            $null = $_
        }

        # CIM Win32_OperatingSystem fallback
        if ([string]::IsNullOrWhiteSpace($productName) -or [string]::IsNullOrWhiteSpace($buildNumber)) {
            try {
                if (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
                    $cimOs = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($null -ne $cimOs) {
                        if ([string]::IsNullOrWhiteSpace($productName) -and -not [string]::IsNullOrWhiteSpace($cimOs.Caption)) {
                            $productName = $cimOs.Caption.Trim()
                        }
                        if ([string]::IsNullOrWhiteSpace($buildNumber) -and -not [string]::IsNullOrWhiteSpace($cimOs.BuildNumber)) {
                            $buildNumber = $cimOs.BuildNumber.Trim()
                        }
                        if ($null -eq $ubr -and -not [string]::IsNullOrWhiteSpace($cimOs.Version) -and $cimOs.Version -match '^\d+\.\d+\.\d+\.(\d+)$') {
                            $ubr = $Matches[1]
                        }
                    }
                }
            }
            catch {
                $null = $_
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($buildNumber)) {
            $parsedBuild = 0
            if ([int]::TryParse($buildNumber, [ref]$parsedBuild)) {
                $buildInt = $parsedBuild
            }
        }
        elseif ($null -ne [System.Environment]::OSVersion.Version.Build -and [System.Environment]::OSVersion.Version.Build -gt 0) {
            $buildInt = [System.Environment]::OSVersion.Version.Build
            $buildNumber = "$buildInt"
        }

        # Resolve Windows 11 legacy ProductName reporting when build >= 22000
        if ($buildInt -ge 22000) {
            if (-not [string]::IsNullOrWhiteSpace($productName)) {
                if ($productName -match 'Windows 10' -and $productName -notmatch '(?i)Server') {
                    $productName = $productName -replace 'Windows 10', 'Windows 11'
                }
                elseif ($productName -notmatch 'Windows 11' -and $productName -notmatch '(?i)Server') {
                    $productName = "Windows 11 $productName"
                }
            }
            else {
                $productName = 'Windows 11'
            }
        }

        $fullBuild = $buildNumber
        if (-not [string]::IsNullOrWhiteSpace($buildNumber) -and $null -ne $ubr) {
            $fullBuild = "$buildNumber.$ubr"
        }

        if (-not [string]::IsNullOrWhiteSpace($productName)) {
            $dispPart = ''
            if (-not [string]::IsNullOrWhiteSpace($displayVer)) {
                $dispPart = "$displayVer "
            }
            $buildPart = ''
            if (-not [string]::IsNullOrWhiteSpace($fullBuild)) {
                $buildPart = "(Build $fullBuild)"
            }
            $osDisplay = "$productName $dispPart$buildPart".Trim()
            $osDisplay = [regex]::Replace($osDisplay, '\s+', ' ')
        }
        else {
            $osDisplay = [System.Environment]::OSVersion.VersionString
        }

        $osArch = [System.IntPtr]::Size * 8

        # 2. CPU Model Name (Registry -> CIM -> %PROCESSOR_IDENTIFIER%)
        $cpuModel = $null
        try {
            if (Test-Path -Path 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction SilentlyContinue) {
                $regCpu = Get-ItemProperty -Path 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction SilentlyContinue
                if ($null -ne $regCpu -and -not [string]::IsNullOrWhiteSpace($regCpu.ProcessorNameString)) {
                    $cpuModel = $regCpu.ProcessorNameString.Trim()
                }
            }
        }
        catch {
            $null = $_
        }

        if ([string]::IsNullOrWhiteSpace($cpuModel)) {
            try {
                if (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
                    $cimCpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($null -ne $cimCpu -and -not [string]::IsNullOrWhiteSpace($cimCpu.Name)) {
                        $cpuModel = $cimCpu.Name.Trim()
                    }
                }
            }
            catch {
                $null = $_
            }
        }

        if ([string]::IsNullOrWhiteSpace($cpuModel)) {
            try {
                if (Test-Path -Path '/proc/cpuinfo' -ErrorAction SilentlyContinue) {
                    $cpuLines = Get-Content -Path '/proc/cpuinfo' -ErrorAction SilentlyContinue
                    if ($null -ne $cpuLines) {
                        $modelLine = $cpuLines | Where-Object { $_ -match '(?i)model name\s*:\s*(.+)' } | Select-Object -First 1
                        if ($null -ne $modelLine -and $modelLine -match ':\s*(.+)$') {
                            $cpuModel = $Matches[1].Trim()
                        }
                    }
                }
            }
            catch {
                $null = $_
            }
        }

        if ([string]::IsNullOrWhiteSpace($cpuModel)) {
            if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_IDENTIFIER)) {
                $cpuModel = $env:PROCESSOR_IDENTIFIER.Trim()
            }
        }

        $cpuCount = [System.Environment]::ProcessorCount
        if (-not [string]::IsNullOrWhiteSpace($cpuModel)) {
            $cpuClean = [regex]::Replace($cpuModel, '\s+', ' ')
            $cpuDisplay = "$cpuClean ($cpuCount Cores)"
        }
        else {
            $cpuDisplay = "$cpuCount Logical Processors"
        }

        # 3. Physical Installed RAM & Available RAM
        $totalRamGB = $null
        $availRamGB = $null

        try {
            if (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
                $cimCs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($null -ne $cimCs -and $cimCs.TotalPhysicalMemory -gt 0) {
                    $totalRamGB = [math]::Round($cimCs.TotalPhysicalMemory / 1GB, 1)
                }

                $cimOs = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($null -ne $cimOs) {
                    if ($cimOs.FreePhysicalMemory -gt 0) {
                        $availRamGB = [math]::Round(($cimOs.FreePhysicalMemory * 1KB) / 1GB, 1)
                    }
                    if ($null -eq $totalRamGB -and $cimOs.TotalVisibleMemorySize -gt 0) {
                        $totalRamGB = [math]::Round(($cimOs.TotalVisibleMemorySize * 1KB) / 1GB, 1)
                    }
                }
            }
        }
        catch {
            $null = $_
        }

        # Non-Windows / Linux /proc/meminfo fallback
        if ($null -eq $totalRamGB -or $null -eq $availRamGB) {
            try {
                if (Test-Path -Path '/proc/meminfo' -ErrorAction SilentlyContinue) {
                    $memLines = Get-Content -Path '/proc/meminfo' -ErrorAction SilentlyContinue
                    if ($null -ne $memLines) {
                        foreach ($mLine in $memLines) {
                            if ($null -eq $totalRamGB -and $mLine -match 'MemTotal:\s+(\d+)\s+kB') {
                                $totalRamGB = [math]::Round(([double]$Matches[1] * 1KB) / 1GB, 1)
                            }
                            elseif ($null -eq $availRamGB -and $mLine -match 'MemAvailable:\s+(\d+)\s+kB') {
                                $availRamGB = [math]::Round(([double]$Matches[1] * 1KB) / 1GB, 1)
                            }
                        }
                    }
                }
            }
            catch {
                $null = $_
            }
        }

        if ($null -eq $totalRamGB) {
            try {
                $gcMem = [System.GC]::GetGCMemoryInfo().TotalAvailableMemoryBytes
                if ($gcMem -gt 0) {
                    $totalRamGB = [math]::Round($gcMem / 1GB, 1)
                }
            }
            catch {
                $null = $_
            }
        }

        if ($null -ne $totalRamGB -and $null -ne $availRamGB) {
            $ramDisplay = "RAM: ${totalRamGB} GB (${availRamGB} GB Free)"
        }
        elseif ($null -ne $totalRamGB) {
            $ramDisplay = "RAM: ${totalRamGB} GB"
        }
        else {
            $ramDisplay = "RAM: Available"
        }

        # 4. Device Manufacturer & Model (BIOS Registry -> CIM fallback)
        $mfg = $null
        $model = $null

        try {
            if (Test-Path -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -ErrorAction SilentlyContinue) {
                $regBios = Get-ItemProperty -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -ErrorAction SilentlyContinue
                if ($null -ne $regBios) {
                    if (-not [string]::IsNullOrWhiteSpace($regBios.SystemManufacturer)) {
                        $mfg = $regBios.SystemManufacturer.Trim()
                    }
                    if (-not [string]::IsNullOrWhiteSpace($regBios.SystemProductName)) {
                        $model = $regBios.SystemProductName.Trim()
                    }
                    if ([string]::IsNullOrWhiteSpace($mfg) -and -not [string]::IsNullOrWhiteSpace($regBios.BaseBoardManufacturer)) {
                        $mfg = $regBios.BaseBoardManufacturer.Trim()
                    }
                    if ([string]::IsNullOrWhiteSpace($model) -and -not [string]::IsNullOrWhiteSpace($regBios.BaseBoardProduct)) {
                        $model = $regBios.BaseBoardProduct.Trim()
                    }
                }
            }
        }
        catch {
            $null = $_
        }

        # Filter generic OEM placeholder strings
        $oemDummyRegex = '(?i)^(System (manufacturer|Product Name)|To Be Filled By O\.?E\.?M\.?|Default string|None|Not Applicable|N/A|Unknown|All Series|System Version)$'
        if (-not [string]::IsNullOrWhiteSpace($mfg) -and $mfg -match $oemDummyRegex) {
            $mfg = $null
        }
        if (-not [string]::IsNullOrWhiteSpace($model) -and $model -match $oemDummyRegex) {
            $model = $null
        }

        # Check BaseBoard from registry if SystemManufacturer/SystemProductName were dummy strings
        if ($null -ne $regBios) {
            if ([string]::IsNullOrWhiteSpace($mfg) -and -not [string]::IsNullOrWhiteSpace($regBios.BaseBoardManufacturer) -and $regBios.BaseBoardManufacturer -notmatch $oemDummyRegex) {
                $mfg = $regBios.BaseBoardManufacturer.Trim()
            }
            if ([string]::IsNullOrWhiteSpace($model) -and -not [string]::IsNullOrWhiteSpace($regBios.BaseBoardProduct) -and $regBios.BaseBoardProduct -notmatch $oemDummyRegex) {
                $model = $regBios.BaseBoardProduct.Trim()
            }
        }

        if ([string]::IsNullOrWhiteSpace($mfg) -or [string]::IsNullOrWhiteSpace($model)) {
            try {
                if (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
                    $cimCs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($null -ne $cimCs) {
                        if ([string]::IsNullOrWhiteSpace($mfg) -and -not [string]::IsNullOrWhiteSpace($cimCs.Manufacturer)) {
                            $mfg = $cimCs.Manufacturer.Trim()
                        }
                        if ([string]::IsNullOrWhiteSpace($model) -and -not [string]::IsNullOrWhiteSpace($cimCs.Model)) {
                            $model = $cimCs.Model.Trim()
                        }
                    }
                }
            }
            catch {
                $null = $_
            }
        }

        # Fallback to motherboard information (Win32_BaseBoard) if chassis/system product is still missing or generic
        if ([string]::IsNullOrWhiteSpace($mfg) -or [string]::IsNullOrWhiteSpace($model) -or $mfg -match $oemDummyRegex -or $model -match $oemDummyRegex) {
            try {
                if (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
                    $cimBb = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($null -ne $cimBb) {
                        if (([string]::IsNullOrWhiteSpace($mfg) -or $mfg -match $oemDummyRegex) -and -not [string]::IsNullOrWhiteSpace($cimBb.Manufacturer)) {
                            $mfg = $cimBb.Manufacturer.Trim()
                        }
                        if (([string]::IsNullOrWhiteSpace($model) -or $model -match $oemDummyRegex) -and -not [string]::IsNullOrWhiteSpace($cimBb.Product)) {
                            $model = $cimBb.Product.Trim()
                        }
                    }
                }
            }
            catch {
                $null = $_
            }
        }

        # Non-Windows DMI fallback
        if ([string]::IsNullOrWhiteSpace($mfg) -and [string]::IsNullOrWhiteSpace($model)) {
            try {
                if (Test-Path -Path '/sys/class/dmi/id/sys_vendor' -ErrorAction SilentlyContinue) {
                    $mfgContent = Get-Content -Path '/sys/class/dmi/id/sys_vendor' -ErrorAction SilentlyContinue | Select-Object -First 1
                    if (-not [string]::IsNullOrWhiteSpace($mfgContent)) {
                        $mfg = $mfgContent.Trim()
                    }
                }
                if (Test-Path -Path '/sys/class/dmi/id/product_name' -ErrorAction SilentlyContinue) {
                    $prodContent = Get-Content -Path '/sys/class/dmi/id/product_name' -ErrorAction SilentlyContinue | Select-Object -First 1
                    if (-not [string]::IsNullOrWhiteSpace($prodContent)) {
                        $model = $prodContent.Trim()
                    }
                }
            }
            catch {
                $null = $_
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($mfg) -and $mfg -match $oemDummyRegex) {
            $mfg = $null
        }
        if (-not [string]::IsNullOrWhiteSpace($model) -and $model -match $oemDummyRegex) {
            $model = $null
        }

        if (-not [string]::IsNullOrWhiteSpace($mfg) -and -not [string]::IsNullOrWhiteSpace($model)) {
            $mfgFirstWord = ($mfg -split '\s+')[0]
            if ($model.StartsWith($mfg, [System.StringComparison]::OrdinalIgnoreCase) -or
                ($mfgFirstWord.Length -ge 3 -and $model.StartsWith($mfgFirstWord, [System.StringComparison]::OrdinalIgnoreCase))) {
                $hwDisplay = $model
            }
            else {
                $hwDisplay = "$mfg $model"
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($model)) {
            $hwDisplay = $model
        }
        elseif (-not [string]::IsNullOrWhiteSpace($mfg)) {
            $hwDisplay = "$mfg System"
        }
        else {
            $hwDisplay = "Standard Platform"
        }
        $hwDisplay = [regex]::Replace($hwDisplay, '\s+', ' ')

        # 5. Active Primary Network IPv4 (filtering virtual/loopback adapters)
        $primaryIp = $null

        try {
            if (Get-Command -Name 'Get-NetRoute' -ErrorAction SilentlyContinue) {
                $routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Sort-Object -Property @{ Expression = { [int]$_.RouteMetric + [int]$_.InterfaceMetric } }
                if ($null -ne $routes) {
                    foreach ($r in $routes) {
                        $adapter = Get-NetAdapter -InterfaceIndex $r.InterfaceIndex -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($null -ne $adapter) {
                            $isVirtual = $adapter.Virtual
                            $alias = $adapter.InterfaceAlias
                            $desc = $adapter.InterfaceDescription
                            $status = $adapter.Status
                            if (($null -eq $status -or $status -eq 'Up') -and
                                -not $isVirtual -and
                                $alias -notmatch '(?i)vEthernet|WSL|Hyper-V|Virtual|VPN|Loopback|Tailscale|ZeroTier|VMware|VirtualBox|veth|docker|Bluetooth|WireGuard|GlobalProtect|Forti|Nord|Cisco' -and
                                $desc -notmatch '(?i)Virtual|Hyper-V|WSL|VPN|TAP|Loopback|Tunnel|Tailscale|ZeroTier|VMware|VirtualBox|Pseudo|Bluetooth|WireGuard|GlobalProtect|Fortinet|Nord|Cisco'
                            ) {

                                $ipCandidate = Get-NetIPAddress -InterfaceIndex $r.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                                    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.|0\.0\.0\.0)' -and $_.IPAddress -ne '255.255.255.255' } | Select-Object -First 1
                                if ($null -ne $ipCandidate -and -not [string]::IsNullOrWhiteSpace($ipCandidate.IPAddress)) {
                                    $primaryIp = $ipCandidate.IPAddress.Trim()
                                    break
                                }
                            }
                        }
                    }
                }
            }
        }
        catch {
            $null = $_
        }

        if ([string]::IsNullOrWhiteSpace($primaryIp)) {
            try {
                $activeNics = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                    Where-Object {
                        $_.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up -and
                        $_.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback -and
                        $_.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Tunnel -and
                        $_.Name -notmatch '(?i)vEthernet|WSL|Hyper-V|Virtual|VPN|Loopback|Tailscale|ZeroTier|VMware|VirtualBox|veth|docker|br-|Bluetooth|tun|tap|wg|nord|cisco|utun' -and
                        $_.Description -notmatch '(?i)Virtual|Hyper-V|WSL|VPN|TAP|Loopback|Tunnel|Tailscale|ZeroTier|VMware|VirtualBox|Pseudo|P2P|Bluetooth|WireGuard|GlobalProtect|Fortinet|Nord|Cisco'
                    } |
                    Sort-Object -Property @{ Expression = {
                        if ($_.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Ethernet) { 1 }
                        elseif ($_.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Wireless80211) { 2 }
                        else { 3 }
                    } }

                if ($null -ne $activeNics) {
                    foreach ($nic in $activeNics) {
                        $ipProps = $nic.GetIPProperties()
                        $hasGw = @($ipProps.GatewayAddresses | Where-Object {
                            $null -ne $_.Address -and
                            $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                            $_.Address.ToString() -ne '0.0.0.0'
                        }).Count -gt 0

                        if ($hasGw) {
                            $unicast = $ipProps.UnicastAddresses | Where-Object {
                                $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                                $_.Address.ToString() -notmatch '^(127\.|169\.254\.|0\.0\.0\.0)' -and
                                $_.Address.ToString() -ne '255.255.255.255'
                            } | Select-Object -First 1

                            if ($null -ne $unicast) {
                                $primaryIp = $unicast.Address.ToString()
                                break
                            }
                        }
                    }

                    if ([string]::IsNullOrWhiteSpace($primaryIp)) {
                        foreach ($nic in $activeNics) {
                            $ipProps = $nic.GetIPProperties()
                            $unicast = $ipProps.UnicastAddresses | Where-Object {
                                $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                                $_.Address.ToString() -notmatch '^(127\.|169\.254\.|0\.0\.0\.0)' -and
                                $_.Address.ToString() -ne '255.255.255.255'
                            } | Select-Object -First 1

                            if ($null -ne $unicast) {
                                $primaryIp = $unicast.Address.ToString()
                                break
                            }
                        }
                    }
                }
            }
            catch {
                $null = $_
            }
        }

        if ([string]::IsNullOrWhiteSpace($primaryIp)) {
            $primaryIp = '127.0.0.1'
        }

        # 6. Dynamic System Drive Storage
        $driveInfo = "Storage: System Drive"
        try {
            $sysDriveName = $env:SystemDrive
            if ([string]::IsNullOrWhiteSpace($sysDriveName)) {
                if ($null -ne $env:SystemRoot -and $env:SystemRoot.Length -ge 2 -and $env:SystemRoot[1] -eq ':') {
                    $sysDriveName = $env:SystemRoot.Substring(0, 2)
                }
                elseif ($null -ne $env:windir -and $env:windir.Length -ge 2 -and $env:windir[1] -eq ':') {
                    $sysDriveName = $env:windir.Substring(0, 2)
                }
                else {
                    $sysDriveName = 'C:'
                }
            }

            $allDrives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }
            $targetDrive = $allDrives | Where-Object {
                $_.Name -like "$sysDriveName*" -or $_.RootDirectory.FullName -like "$sysDriveName*"
            } | Select-Object -First 1

            if ($null -eq $targetDrive) {
                $targetDrive = $allDrives | Where-Object { $_.RootDirectory.FullName -eq '/' } | Select-Object -First 1
            }
            if ($null -eq $targetDrive) {
                $targetDrive = $allDrives | Select-Object -First 1
            }

            if ($null -ne $targetDrive) {
                try {
                    $freeBytes = $targetDrive.AvailableFreeSpace
                    $totalBytes = $targetDrive.TotalSize
                    $freeGB = [math]::Round($freeBytes / 1GB, 1)
                    $totalGB = [math]::Round($totalBytes / 1GB, 1)
                    $pctFree = 0
                    if ($totalBytes -gt 0) {
                        $pctFree = [math]::Round(($freeBytes / $totalBytes) * 100, 0)
                    }
                    $driveInfo = "System Drive ($($targetDrive.Name)) ${freeGB} GB Free / ${totalGB} GB Total (${pctFree}% Free)"
                }
                catch {
                    $driveInfo = "System Drive ($($targetDrive.Name)) Ready"
                }
            }
        }
        catch {
            $null = $_
        }

        return [PSCustomObject]@{
            OSDisplay       = $osDisplay
            Architecture    = "${osArch}-bit"
            CPUDisplay      = $cpuDisplay
            RAMDisplay      = $ramDisplay
            HardwareDisplay = $hwDisplay
            ActiveIPv4      = $primaryIp
            StorageDisplay  = $driveInfo
        }
    }

if (Get-Command -Name 'Get-ToolkitTelemetryData' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Get-ToolkitTelemetryData' -Value (Get-Command -Name 'Get-ToolkitTelemetryData').ScriptBlock
}

function Show-ToolkitHeader {
<#
.SYNOPSIS
    Renders a consistent enterprise console header banner with title and optional subtitle.
.DESCRIPTION
    Draws a formatted ASCII banner with border lines, system environment info,
    and high-visibility coloring. Optionally clears the console host when running in an interactive terminal.
.PARAMETER Title
    The primary banner title text.
.PARAMETER Subtitle
    Optional subtitle or status description.
.PARAMETER Width
    Width of the banner in characters. Default is 78.
.PARAMETER ClearScreen
    Switch to clear host screen before drawing the banner.
.PARAMETER NoSystemInfo
    Switch to omit the system info status bar.
.PARAMETER InfoLines
    Array of diagnostic information lines to render inside the banner box.
.EXAMPLE
    Show-ToolkitHeader -Title 'IToolkit Main Menu' -Subtitle 'Enterprise IT Support' -ClearScreen -InfoLines @('CPU: 8 Cores', 'RAM: 16 GB')
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Title,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$Subtitle,

        [Parameter(Mandatory = $false)]
        [ValidateRange(40, 120)]
        [int]$Width = 78,

        [Parameter(Mandatory = $false)]
        [switch]$ClearScreen,

        [Parameter(Mandatory = $false)]
        [switch]$NoSystemInfo,

        [Parameter(Mandatory = $false)]
        [string[]]$InfoLines
    )

    if ($ClearScreen) {
        try {
            if (-not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected) {
                Clear-Host
            }
        }
        catch {
            # In non-interactive or Linux test environments, ignore Clear-Host failure
            $null = $_
        }
    }

    $borderLine = '=' * $Width
    $subBorderLine = '-' * $Width

    Write-Host ""
    Write-Host $borderLine -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
        Write-Host "  $Subtitle" -ForegroundColor DarkCyan
    }

    if ($null -ne $InfoLines -and $InfoLines.Count -gt 0) {
        Write-Host $subBorderLine -ForegroundColor DarkGray
        foreach ($line in $InfoLines) {
            $colonIdx = $line.IndexOf(':')
            if ($colonIdx -gt 0) {
                $keyPart = $line.Substring(0, $colonIdx + 1)
                $valPart = $line.Substring($colonIdx + 1)

                # Ensure line width does not exceed $Width to prevent wrapping
                $maxValLen = $Width - 2 - $keyPart.Length
                if ($maxValLen -gt 3 -and $valPart.Length -gt $maxValLen) {
                    $valPart = $valPart.Substring(0, $maxValLen - 3) + '...'
                }

                Write-Host "  $keyPart" -ForegroundColor DarkCyan -NoNewline

                $valColor = [System.ConsoleColor]::White
                if ($valPart -match '(?i)\[Elevated|\[YES\]|\[Safe|Clean|Online|Running|Expanded') {
                    $valColor = [System.ConsoleColor]::Green
                }
                elseif ($valPart -match '(?i)\[Non-Elevated|\[NO\]|\[Default|Stopped|Stuck|Offline|Low') {
                    $valColor = [System.ConsoleColor]::Yellow
                }
                Write-Host "$valPart" -ForegroundColor $valColor
            }
            else {
                $trimmedLine = $line
                if ($trimmedLine.Length -gt ($Width - 4)) {
                    $trimmedLine = $trimmedLine.Substring(0, [math]::Max(0, $Width - 7)) + '...'
                }
                Write-Host "  $trimmedLine" -ForegroundColor DarkCyan
            }
        }
    }
    elseif (-not $NoSystemInfo) {
        $hostName = $env:COMPUTERNAME
        if ([string]::IsNullOrWhiteSpace($hostName)) {
            $hostName = [System.Environment]::MachineName
        }
        $userName = $env:USERNAME
        if ([string]::IsNullOrWhiteSpace($userName)) {
            $userName = [System.Environment]::UserName
        }
        $psVer = "PS " + $PSVersionTable.PSVersion.Major + "." + $PSVersionTable.PSVersion.Minor

        $adminTag = "Admin: [?]"
        if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
            try {
                $isAdmin = Test-IsAdmin
                if ($isAdmin) {
                    $adminTag = "Admin: [YES]"
                }
                else {
                    $adminTag = "Admin: [NO]"
                }
            }
            catch {
                $adminTag = "Admin: [?]"
            }
        }

        Write-Host $subBorderLine -ForegroundColor DarkGray
        $statusLine1 = "  Host: $hostName | User: $userName | $adminTag | $psVer"
        if ($statusLine1.Length -gt $Width) {
            $statusLine1 = $statusLine1.Substring(0, [math]::Max(0, $Width - 3)) + '...'
        }
        Write-Host $statusLine1 -ForegroundColor DarkCyan

        # Deep telemetry summary line (OS & Hardware Platform)
        try {
            $telemetry = Get-ToolkitTelemetryData
            if ($null -ne $telemetry) {
                $platParts = [System.Collections.Generic.List[string]]::new()
                if (-not [string]::IsNullOrWhiteSpace($telemetry.OSDisplay)) {
                    $platParts.Add("OS: $($telemetry.OSDisplay)")
                }
                if (-not [string]::IsNullOrWhiteSpace($telemetry.HardwareDisplay) -and $telemetry.HardwareDisplay -ne 'Standard Platform') {
                    $platParts.Add("Model: $($telemetry.HardwareDisplay)")
                }
                if ($platParts.Count -gt 0) {
                    $statusLine2 = "  " + ($platParts -join ' | ')
                    if ($statusLine2.Length -gt $Width) {
                        $statusLine2 = $statusLine2.Substring(0, [math]::Max(0, $Width - 3)) + '...'
                    }
                    Write-Host $statusLine2 -ForegroundColor DarkCyan
                }
            }
        }
        catch {
            $null = $_
        }
    }

    Write-Host $borderLine -ForegroundColor Cyan
    Write-Host ""
}
