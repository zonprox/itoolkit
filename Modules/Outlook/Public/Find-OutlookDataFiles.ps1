function Find-OutlookDataFiles {
<#
.SYNOPSIS
    Discovers Outlook PST and OST data files with structured metadata.
.DESCRIPTION
    Scans Office 16.0, 15.0, and legacy Windows Messaging Subsystem registry profile
    trees, as well as standard Outlook user data directories. Decodes Unicode and ANSI
    MAPI binary properties safely and exposes detailed attributes including size, profile
    binding, cached Exchange mode, and active file lock status.
.PARAMETER Scope
    Search scope: 'All', 'UserProfile', 'Registry', 'Drives'. Default is 'All'.
.PARAMETER ProfileName
    Optional specific Outlook profile name to filter.
.OUTPUTS
    [PSCustomObject[]] Array of data file objects.
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('All', 'UserProfile', 'Registry', 'Drives')]
        [string]$Scope = 'All',

        [Parameter(Mandatory = $false)]
        [string]$ProfileName
    )

    process {
        # Ensure private helper is loaded if running outside imported module
        if (-not (Get-Command -Name 'ConvertFrom-MapiBinaryProperty' -ErrorAction SilentlyContinue)) {
            $privHelper = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Private/ConvertFrom-MapiBinaryProperty.ps1'
            if (Test-Path -LiteralPath $privHelper) {
                . $privHelper
            }
        }

        # Ensure lock tester is loaded if running outside imported module
        if (-not (Get-Command -Name 'Test-OutlookDataFileLock' -ErrorAction SilentlyContinue)) {
            $lockHelper = Join-Path -Path $PSScriptRoot -ChildPath 'Test-OutlookDataFileLock.ps1'
            if (Test-Path -LiteralPath $lockHelper) {
                . $lockHelper
            }
        }

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        # 1. Scope: Registry discovery
        if ($Scope -in @('All', 'Registry')) {
            $profileTargets = @(
                @{
                    BaseKey = 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles'
                    MetaKey = 'HKCU:\Software\Microsoft\Office\16.0\Outlook'
                },
                @{
                    BaseKey = 'HKCU:\Software\Microsoft\Office\15.0\Outlook\Profiles'
                    MetaKey = 'HKCU:\Software\Microsoft\Office\15.0\Outlook'
                },
                @{
                    BaseKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows Messaging Subsystem\Profiles'
                    MetaKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows Messaging Subsystem\Profiles'
                }
            )

            foreach ($target in $profileTargets) {
                $pBase = $target.BaseKey
                $mKey = $target.MetaKey

                if (Test-Path -LiteralPath $pBase) {
                    try {
                        # Resolve default profile for this registry hive
                        $defaultProfile = $null
                        if (Test-Path -LiteralPath $mKey) {
                            $mProp = Get-ItemProperty -LiteralPath $mKey -ErrorAction SilentlyContinue
                            if ($null -ne $mProp -and $mProp.PSObject.Properties['DefaultProfile']) {
                                $defaultProfile = [string]$mProp.DefaultProfile
                            }
                        }

                        $profiles = Get-ChildItem -LiteralPath $pBase -ErrorAction SilentlyContinue
                        foreach ($prof in $profiles) {
                            $pName = $prof.PSChildName
                            if (-not [string]::IsNullOrWhiteSpace($ProfileName) -and $pName -ine $ProfileName) {
                                continue
                            }

                            $isDefault = ($null -ne $defaultProfile -and $pName -ieq $defaultProfile)

                            $subkeys = Get-ChildItem -LiteralPath $prof.PSPath -Recurse -ErrorAction SilentlyContinue
                            foreach ($sk in $subkeys) {
                                $prop = Get-ItemProperty -LiteralPath $sk.PSPath -ErrorAction SilentlyContinue
                                if ($null -ne $prop) {
                                    # Check cached Exchange mode flags on subkey
                                    $isSubkeyCached = $false
                                    if ($null -ne $prop.PSObject.Properties['00036613'] -and $null -ne $prop.'00036613') {
                                        if (([int]$prop.'00036613' -band 0x01) -ne 0) { $isSubkeyCached = $true }
                                    }
                                    if ($null -ne $prop.PSObject.Properties['00036601'] -and $null -ne $prop.'00036601') {
                                        if (([int]$prop.'00036601' -band 0x01) -ne 0) { $isSubkeyCached = $true }
                                    }

                                    foreach ($p in $prop.PSObject.Properties) {
                                        $val = $p.Value
                                        $detectedPath = $null

                                        if ($val -is [byte[]] -or ($val -is [System.Array] -and -not ($val -is [string]))) {
                                            if (Get-Command -Name 'ConvertFrom-MapiBinaryProperty' -ErrorAction SilentlyContinue) {
                                                $detectedPath = ConvertFrom-MapiBinaryProperty -Bytes $val -PropertyName $p.Name
                                            }
                                            elseif ($val.Length -gt 4) {
                                                try {
                                                    $detectedPath = [System.Text.Encoding]::Unicode.GetString($val).TrimEnd([char]0)
                                                }
                                                catch {
                                                    Write-Verbose "Could not decode binary property '$($p.Name)' as Unicode: $($_.Exception.Message)"
                                                }
                                            }
                                        }
                                        elseif ($val -is [string]) {
                                            $detectedPath = [System.Environment]::ExpandEnvironmentVariables($val.Trim())
                                        }

                                        # Validate detected path ends in .pst or .ost
                                        if (-not [string]::IsNullOrWhiteSpace($detectedPath) -and $detectedPath -match '(?i)\.(pst|ost)$') {
                                            if (-not $seen.Contains($detectedPath)) {
                                                $null = $seen.Add($detectedPath)

                                                $fileLength = [int64]0
                                                $lastMod = Get-Date
                                                if (Test-Path -LiteralPath $detectedPath) {
                                                    try {
                                                        $fi = Get-Item -LiteralPath $detectedPath -ErrorAction SilentlyContinue
                                                        if ($null -ne $fi) {
                                                            $fileLength = [int64]$fi.Length
                                                            $lastMod = $fi.LastWriteTime
                                                        }
                                                    }
                                                    catch {
                                                        Write-Verbose "Could not inspect file '$detectedPath': $($_.Exception.Message)"
                                                    }
                                                }

                                                $ext = [System.IO.Path]::GetExtension($detectedPath)
                                                $isOst = ($ext -match '(?i)\.ost$')
                                                $type = if ($isOst) { 'OST' } else { 'PST' }
                                                $cachedMode = ($isOst -or $isSubkeyCached)

                                                # Probe file lock status
                                                $isLocked = $false
                                                if (Get-Command -Name 'Test-OutlookDataFileLock' -ErrorAction SilentlyContinue) {
                                                    $lockResult = Test-OutlookDataFileLock -Path $detectedPath
                                                    $isLocked = [bool]$lockResult.IsLocked
                                                }

                                                $results.Add([PSCustomObject]@{
                                                    Path               = $detectedPath
                                                    SizeBytes          = $fileLength
                                                    SizeGB             = [Math]::Round([double]$fileLength / 1073741824.0, 2)
                                                    Type               = $type
                                                    Profile            = $pName
                                                    LastModified       = $lastMod
                                                    IsDefaultProfile   = $isDefault
                                                    CachedExchangeMode = $cachedMode
                                                    IsLocked           = $isLocked
                                                })
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    catch {
                        Write-Verbose "Registry scan notice: $($_.Exception.Message)"
                    }
                }
            }
        }

        # 2. Scope: Filesystem discovery (UserProfile, Drives, All)
        $searchPaths = [System.Collections.Generic.List[string]]::new()

        if ($Scope -in @('All', 'UserProfile')) {
            if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
                $localOutlook = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft\Outlook'
                $searchPaths.Add($localOutlook)
            }

            if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
                $userDocs = Join-Path -Path $env:USERPROFILE -ChildPath 'Documents\Outlook Files'
                $searchPaths.Add($userDocs)
                $appDataOutlook = Join-Path -Path $env:USERPROFILE -ChildPath 'AppData\Roaming\Microsoft\Outlook'
                $searchPaths.Add($appDataOutlook)
            }

            # If user environment variables are absent (e.g. non-Windows test environment), add candidate paths
            if ($searchPaths.Count -eq 0) {
                $userBase = if (-not [string]::IsNullOrWhiteSpace($env:HOME)) { $env:HOME } else { 'C:\Users\Default' }
                $searchPaths.Add((Join-Path -Path $userBase -ChildPath 'Documents/Outlook Files'))
                $searchPaths.Add((Join-Path -Path $userBase -ChildPath '.local/share/Microsoft/Outlook'))
            }
        }

        if ($Scope -in @('All', 'Drives')) {
            try {
                $drives = @(Get-PSDrive -PSProvider 'FileSystem' -ErrorAction SilentlyContinue)
                foreach ($d in $drives) {
                    if (-not [string]::IsNullOrWhiteSpace($d.Root) -and (Test-Path -LiteralPath $d.Root)) {
                        $candidate = Join-Path -Path $d.Root -ChildPath 'Outlook'
                        $searchPaths.Add($candidate)
                    }
                }
            }
            catch {
                Write-Verbose "Drive discovery notice: $($_.Exception.Message)"
            }
        }

        # Scan resolved search paths (strictly standard directories, NO recursive fallback to Get-Location)
        if ($searchPaths.Count -gt 0 -and $Scope -ne 'Registry') {
            $rawFiles = $null
            try {
                $rawFiles = @(Get-ChildItem -Path $searchPaths -Include '*.pst', '*.ost' -File -Recurse -ErrorAction SilentlyContinue)
            }
            catch {
                Write-Verbose "Error executing Get-ChildItem: $($_.Exception.Message)"
                $rawFiles = @()
            }

            if ($null -ne $rawFiles) {
                foreach ($file in $rawFiles) {
                    $fullName = [string]$file.FullName
                    if (-not [string]::IsNullOrWhiteSpace($fullName) -and -not $seen.Contains($fullName)) {
                        $null = $seen.Add($fullName)

                        $length = [int64]0
                        if ($file.PSObject.Properties['Length'] -and $null -ne $file.Length) {
                            $length = [int64]$file.Length
                        }

                        $sizeGb = [Math]::Round([double]$length / 1073741824.0, 2)

                        $ext = [string]$file.Extension
                        $isOst = ($ext -match '(?i)\.ost$')
                        $type = if ($isOst) { 'OST' } else { 'PST' }

                        $lastMod = Get-Date
                        if ($file.PSObject.Properties['LastWriteTime'] -and $null -ne $file.LastWriteTime) {
                            $lastMod = $file.LastWriteTime
                        }

                        $profile = if (-not [string]::IsNullOrWhiteSpace($ProfileName)) { $ProfileName } else { 'Default' }

                        $isLocked = $false
                        if (Get-Command -Name 'Test-OutlookDataFileLock' -ErrorAction SilentlyContinue) {
                            $lockResult = Test-OutlookDataFileLock -Path $fullName
                            $isLocked = [bool]$lockResult.IsLocked
                        }

                        $results.Add([PSCustomObject]@{
                            Path               = $fullName
                            SizeBytes          = $length
                            SizeGB             = $sizeGb
                            Type               = $type
                            Profile            = $profile
                            LastModified       = $lastMod
                            IsDefaultProfile   = $false
                            CachedExchangeMode = $isOst
                            IsLocked           = $isLocked
                        })
                    }
                }
            }
        }

        return @($results)
    }
}
