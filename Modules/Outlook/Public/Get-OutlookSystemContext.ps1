function Get-OutlookSystemContext {
<#
.SYNOPSIS
    Gathers comprehensive Outlook and Office system, registry, and data file telemetry.
.DESCRIPTION
    Discovers installed Office versions (15.0, 16.0, C2R, and MSI), installation architecture
    (32-bit / 64-bit), executable path, active process state and process IDs, configured
    and default profiles across modern and legacy hives, PST threshold policies, and bound
    data files. Returns an empty structured object with informational notices without
    throwing terminating errors when Office or Outlook is absent.
.OUTPUTS
    [PSCustomObject]@{ OfficeVersion, InstallType, Bitness, OutlookPath, IsRunning, ProcessId,
                       DefaultProfile, Profiles, ThresholdPolicy, DataFiles, StatusMessage }
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    process {
        # Defensive helpers load
        if (-not (Get-Command -Name 'Get-OutlookPstThreshold' -ErrorAction SilentlyContinue)) {
            $threshScript = Join-Path -Path $PSScriptRoot -ChildPath 'Get-OutlookPstThreshold.ps1'
            if (Test-Path -LiteralPath $threshScript) { . $threshScript }
        }
        if (-not (Get-Command -Name 'Find-OutlookDataFiles' -ErrorAction SilentlyContinue)) {
            $findScript = Join-Path -Path $PSScriptRoot -ChildPath 'Find-OutlookDataFiles.ps1'
            if (Test-Path -LiteralPath $findScript) { . $findScript }
        }

        try {
            $officeVersion = 'None'
            $installType   = 'None'
            $bitness       = 'Unknown'
            $outlookPath   = $null

            # 1. Check Office Click-to-Run (C2R) Configuration
            $c2rKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
            if (Test-Path -LiteralPath $c2rKey) {
                try {
                    $c2rProp = Get-ItemProperty -LiteralPath $c2rKey -ErrorAction SilentlyContinue
                    if ($null -ne $c2rProp) {
                        $installType = 'ClickToRun'
                        if ($null -ne $c2rProp.PSObject.Properties['Platform']) {
                            $platform = [string]$c2rProp.Platform
                            $bitness = if ($platform -match '(?i)x64') { '64-bit' } else { '32-bit' }
                        }
                        if ($null -ne $c2rProp.PSObject.Properties['VersionToReport']) {
                            $vRep = [string]$c2rProp.VersionToReport
                            if ($vRep -match '^16\.') { $officeVersion = '16.0' }
                            elseif ($vRep -match '^15\.') { $officeVersion = '15.0' }
                            else { $officeVersion = '16.0' }
                        }
                        else {
                            $officeVersion = '16.0'
                        }
                    }
                }
                catch {
                    Write-Verbose "C2R detection notice: $($_.Exception.Message)"
                }
            }

            # 2. Check Office MSI InstallRoot (16.0 and 15.0, 64-bit and WOW6432Node)
            if ($installType -eq 'None') {
                $msiTargets = @(
                    @{ Key = 'HKLM:\SOFTWARE\Microsoft\Office\16.0\Outlook\InstallRoot'; Version = '16.0'; Bitness = '64-bit' },
                    @{ Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\16.0\Outlook\InstallRoot'; Version = '16.0'; Bitness = '32-bit' },
                    @{ Key = 'HKLM:\SOFTWARE\Microsoft\Office\15.0\Outlook\InstallRoot'; Version = '15.0'; Bitness = '64-bit' },
                    @{ Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\15.0\Outlook\InstallRoot'; Version = '15.0'; Bitness = '32-bit' }
                )
                foreach ($target in $msiTargets) {
                    if (Test-Path -LiteralPath $target.Key) {
                        try {
                            $msiProp = Get-ItemProperty -LiteralPath $target.Key -ErrorAction SilentlyContinue
                            if ($null -ne $msiProp -and $msiProp.PSObject.Properties['Path']) {
                                $installType   = 'MSI'
                                $officeVersion = $target.Version
                                $bitness       = $target.Bitness
                                $candidateExe  = Join-Path -Path ([string]$msiProp.Path) -ChildPath 'OUTLOOK.EXE'
                                if (Test-Path -LiteralPath $candidateExe) {
                                    $outlookPath = $candidateExe
                                }
                                break
                            }
                        }
                        catch {
                            Write-Verbose "MSI detection notice: $($_.Exception.Message)"
                        }
                    }
                }
            }

            # 3. Check App Paths for OUTLOOK.EXE
            $appPathKeys = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE',
                'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE'
            )
            foreach ($apk in $appPathKeys) {
                if (Test-Path -LiteralPath $apk) {
                    try {
                        $apProp = Get-ItemProperty -LiteralPath $apk -ErrorAction SilentlyContinue
                        if ($null -ne $apProp) {
                            $exeCandidate = $null
                            if ($apProp.PSObject.Properties['(default)']) { $exeCandidate = [string]$apProp.'(default)' }
                            elseif ($apProp.PSObject.Properties['Path']) { $exeCandidate = Join-Path -Path ([string]$apProp.Path) -ChildPath 'OUTLOOK.EXE' }

                            if (-not [string]::IsNullOrWhiteSpace($exeCandidate)) {
                                $outlookPath = $exeCandidate
                                if ($installType -eq 'None') {
                                    if ($exeCandidate -match '(?i)root\\Office1[56]') {
                                        $installType = 'ClickToRun'
                                        $officeVersion = if ($exeCandidate -match 'Office15') { '15.0' } else { '16.0' }
                                    }
                                    else {
                                        $installType = 'MSI'
                                        $officeVersion = if ($exeCandidate -match 'Office15') { '15.0' } else { '16.0' }
                                    }
                                }
                                break
                            }
                        }
                    }
                    catch {
                        Write-Verbose "App Paths notice: $($_.Exception.Message)"
                    }
                }
            }

            # 4. Check Common Filesystem Paths for OUTLOOK.EXE if still not resolved
            if ([string]::IsNullOrWhiteSpace($outlookPath)) {
                $commonExePaths = @(
                    @{ Path = 'C:\Program Files\Microsoft Office\root\Office16\OUTLOOK.EXE'; Ver = '16.0'; Type = 'ClickToRun'; Bits = '64-bit' },
                    @{ Path = 'C:\Program Files (x86)\Microsoft Office\root\Office16\OUTLOOK.EXE'; Ver = '16.0'; Type = 'ClickToRun'; Bits = '32-bit' },
                    @{ Path = 'C:\Program Files\Microsoft Office\Office16\OUTLOOK.EXE'; Ver = '16.0'; Type = 'MSI'; Bits = '64-bit' },
                    @{ Path = 'C:\Program Files (x86)\Microsoft Office\Office16\OUTLOOK.EXE'; Ver = '16.0'; Type = 'MSI'; Bits = '32-bit' },
                    @{ Path = 'C:\Program Files\Microsoft Office\root\Office15\OUTLOOK.EXE'; Ver = '15.0'; Type = 'ClickToRun'; Bits = '64-bit' },
                    @{ Path = 'C:\Program Files (x86)\Microsoft Office\root\Office15\OUTLOOK.EXE'; Ver = '15.0'; Type = 'ClickToRun'; Bits = '32-bit' },
                    @{ Path = 'C:\Program Files\Microsoft Office\Office15\OUTLOOK.EXE'; Ver = '15.0'; Type = 'MSI'; Bits = '64-bit' },
                    @{ Path = 'C:\Program Files (x86)\Microsoft Office\Office15\OUTLOOK.EXE'; Ver = '15.0'; Type = 'MSI'; Bits = '32-bit' }
                )
                foreach ($cp in $commonExePaths) {
                    if (Test-Path -LiteralPath $cp.Path) {
                        $outlookPath = $cp.Path
                        if ($installType -eq 'None') {
                            $officeVersion = $cp.Ver
                            $installType   = $cp.Type
                            $bitness       = $cp.Bits
                        }
                        break
                    }
                }
            }

            # 5. Check Registry Profile Trees for Version Hints if still None
            if ($officeVersion -eq 'None') {
                if (Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Office\16.0\Outlook') {
                    $officeVersion = '16.0'
                    if ($installType -eq 'None') { $installType = 'Standard' }
                }
                elseif (Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Office\15.0\Outlook') {
                    $officeVersion = '15.0'
                    if ($installType -eq 'None') { $installType = 'Standard' }
                }
                elseif (Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows Messaging Subsystem\Profiles') {
                    $officeVersion = 'Legacy'
                    if ($installType -eq 'None') { $installType = 'Legacy' }
                }
            }

            # 6. Running Process & PIDs
            $procs = @(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
            $isRunning = ($procs.Count -gt 0)
            $processIds = @($procs | ForEach-Object { [int]$_.Id })

            # 7. Configured Profiles & Default Profile Enumeration
            $profilesList = [System.Collections.Generic.List[string]]::new()
            $defaultProfile = 'None'

            $profileHives = @(
                @{ Base = 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles'; Meta = 'HKCU:\Software\Microsoft\Office\16.0\Outlook' },
                @{ Base = 'HKCU:\Software\Microsoft\Office\15.0\Outlook\Profiles'; Meta = 'HKCU:\Software\Microsoft\Office\15.0\Outlook' },
                @{ Base = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows Messaging Subsystem\Profiles'; Meta = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows Messaging Subsystem\Profiles' }
            )

            foreach ($h in $profileHives) {
                # Read DefaultProfile if not yet set
                if ($defaultProfile -eq 'None' -and (Test-Path -LiteralPath $h.Meta)) {
                    try {
                        $mProp = Get-ItemProperty -LiteralPath $h.Meta -ErrorAction SilentlyContinue
                        if ($null -ne $mProp -and $mProp.PSObject.Properties['DefaultProfile']) {
                            $dp = [string]$mProp.DefaultProfile
                            if (-not [string]::IsNullOrWhiteSpace($dp)) {
                                $defaultProfile = $dp
                            }
                        }
                    }
                    catch {
                        Write-Verbose "Could not read DefaultProfile from '$($h.Meta)': $($_.Exception.Message)"
                    }
                }

                # Enumerate profile subkeys
                if (Test-Path -LiteralPath $h.Base) {
                    try {
                        $childProfiles = @(Get-ChildItem -LiteralPath $h.Base -ErrorAction SilentlyContinue)
                        foreach ($cp in $childProfiles) {
                            $name = $cp.PSChildName
                            if (-not [string]::IsNullOrWhiteSpace($name) -and -not $profilesList.Contains($name)) {
                                $profilesList.Add($name)
                            }
                        }
                    }
                    catch {
                        Write-Verbose "Could not enumerate child profiles from '$($h.Base)': $($_.Exception.Message)"
                    }
                }
            }

            if ($defaultProfile -eq 'None' -and $profilesList.Count -gt 0) {
                $defaultProfile = $profilesList[0]
            }

            # 8. Active PST Size Threshold Policy
            $vParam = if ($officeVersion -in @('16.0', '15.0')) { $officeVersion } else { $null }
            $threshold = if (Get-Command -Name 'Get-OutlookPstThreshold' -ErrorAction SilentlyContinue) {
                if ($null -ne $vParam) { Get-OutlookPstThreshold -OfficeVersion $vParam } else { Get-OutlookPstThreshold }
            }
            else {
                [PSCustomObject]@{
                    MaxLargeFileSizeMB  = 51200
                    WarnLargeFileSizeMB = 48640
                    IsCustomPolicy      = $false
                    PolicySource        = 'Default'
                    IsExpanded          = $false
                    Description         = 'Default limit (~50 GB threshold)'
                }
            }

            # 9. Discovered Data Files
            $dataFiles = @()
            if (Get-Command -Name 'Find-OutlookDataFiles' -ErrorAction SilentlyContinue) {
                try {
                    $dataFiles = @(Find-OutlookDataFiles -Scope All)
                }
                catch {
                    Write-Verbose "Data file discovery notice: $($_.Exception.Message)"
                    $dataFiles = @()
                }
            }

            # 10. Status Message Formulation
            $statusMessage = if ($officeVersion -eq 'None' -and $profilesList.Count -eq 0 -and $dataFiles.Count -eq 0 -and -not $isRunning) {
                'Office/Outlook not installed'
            }
            else {
                $runStr = if ($isRunning) { "Running (PID: $($processIds -join ', '))" } else { "Stopped" }
                "Office $officeVersion ($installType, $bitness) - $runStr"
            }

            return [PSCustomObject]@{
                OfficeVersion   = $officeVersion
                InstallType     = $installType
                Bitness         = $bitness
                OutlookPath     = $outlookPath
                IsRunning       = $isRunning
                ProcessId       = $processIds
                DefaultProfile  = $defaultProfile
                Profiles        = @($profilesList)
                ThresholdPolicy = $threshold
                DataFiles       = $dataFiles
                StatusMessage   = $statusMessage
            }
        }
        catch {
            # Absolute safe fallback - never throw terminating errors
            return [PSCustomObject]@{
                OfficeVersion   = 'None'
                InstallType     = 'None'
                Bitness         = 'Unknown'
                OutlookPath     = $null
                IsRunning       = $false
                ProcessId       = @()
                DefaultProfile  = 'None'
                Profiles        = @()
                ThresholdPolicy = [PSCustomObject]@{
                    MaxLargeFileSizeMB  = 51200
                    WarnLargeFileSizeMB = 48640
                    IsCustomPolicy      = $false
                    PolicySource        = 'Default'
                    IsExpanded          = $false
                    Description         = 'Default limit (~50 GB threshold)'
                }
                DataFiles       = @()
                StatusMessage   = 'Office/Outlook not installed'
            }
        }
    }
}
