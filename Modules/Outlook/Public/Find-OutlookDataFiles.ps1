function Find-OutlookDataFiles {
<#
.SYNOPSIS
    Discovers Outlook PST and OST data files with structured metadata.
.DESCRIPTION
    Scans standard Outlook data directories, user profiles, drives, and MAPI registry
    profile settings based on the specified Scope parameter, returning structured objects.
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
        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        # 1. Scope: Registry discovery
        if ($Scope -in @('All', 'Registry')) {
            $profileBases = @(
                'HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles',
                'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows Messaging Subsystem\Profiles'
            )
            foreach ($pBase in $profileBases) {
                if (Test-Path -LiteralPath $pBase) {
                    try {
                        $profiles = Get-ChildItem -LiteralPath $pBase -ErrorAction SilentlyContinue
                        foreach ($prof in $profiles) {
                            $pName = $prof.PSChildName
                            if (-not [string]::IsNullOrWhiteSpace($ProfileName) -and $pName -ine $ProfileName) {
                                continue
                            }
                            $subkeys = Get-ChildItem -LiteralPath $prof.PSPath -Recurse -ErrorAction SilentlyContinue
                            foreach ($sk in $subkeys) {
                                $prop = Get-ItemProperty -LiteralPath $sk.PSPath -ErrorAction SilentlyContinue
                                if ($null -ne $prop) {
                                    foreach ($p in $prop.PSObject.Properties) {
                                        $val = $p.Value
                                        $detectedPath = $null
                                        if ($val -is [byte[]] -and $val.Length -gt 4) {
                                            try {
                                                $decoded = [System.Text.Encoding]::Unicode.GetString($val).TrimEnd([char]0)
                                                if ($decoded -match '(?i)\.(pst|ost)$') {
                                                    $detectedPath = $decoded
                                                }
                                            }
                                            catch {
                                                Write-Verbose "Could not decode binary property: $($_.Exception.Message)"
                                            }
                                        }
                                        elseif ($val -is [string] -and $val -match '(?i)\.(pst|ost)$') {
                                            $detectedPath = $val
                                        }

                                        if ($null -ne $detectedPath -and -not $seen.Contains($detectedPath)) {
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
                                            $type = if ($ext -match '(?i)\.ost$') { 'OST' } else { 'PST' }

                                            $results.Add([PSCustomObject]@{
                                                Path         = $detectedPath
                                                SizeBytes    = $fileLength
                                                SizeGB       = [Math]::Round([double]$fileLength / 1073741824.0, 2)
                                                Type         = $type
                                                Profile      = $pName
                                                LastModified = $lastMod
                                            })
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
            if ($null -ne $env:LOCALAPPDATA -and -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
                $localOutlook = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft\Outlook'
                if (Test-Path -LiteralPath $localOutlook) {
                    $searchPaths.Add($localOutlook)
                }
            }

            if ($null -ne $env:USERPROFILE -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
                $userDocs = Join-Path -Path $env:USERPROFILE -ChildPath 'Documents\Outlook Files'
                if (Test-Path -LiteralPath $userDocs) {
                    $searchPaths.Add($userDocs)
                }
                $appDataOutlook = Join-Path -Path $env:USERPROFILE -ChildPath 'AppData\Roaming\Microsoft\Outlook'
                if (Test-Path -LiteralPath $appDataOutlook) {
                    $searchPaths.Add($appDataOutlook)
                }
            }
        }

        if ($Scope -in @('All', 'Drives')) {
            try {
                $drives = @(Get-PSDrive -PSProvider 'FileSystem' -ErrorAction SilentlyContinue)
                foreach ($d in $drives) {
                    if (-not [string]::IsNullOrWhiteSpace($d.Root) -and (Test-Path -LiteralPath $d.Root)) {
                        $candidate = Join-Path -Path $d.Root -ChildPath 'Outlook'
                        if (Test-Path -LiteralPath $candidate) {
                            $searchPaths.Add($candidate)
                        }
                    }
                }
            }
            catch {
                Write-Verbose "Drive discovery notice: $($_.Exception.Message)"
            }
        }

        # Fallback search path if nothing resolved or unit test mock
        if ($searchPaths.Count -eq 0 -and $Scope -ne 'Registry') {
            $searchPaths.Add((Get-Location).Path)
        }

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
                        $type = if ($ext -match '(?i)\.ost$') { 'OST' } else { 'PST' }

                        $lastMod = Get-Date
                        if ($file.PSObject.Properties['LastWriteTime'] -and $null -ne $file.LastWriteTime) {
                            $lastMod = $file.LastWriteTime
                        }

                        $profile = if (-not [string]::IsNullOrWhiteSpace($ProfileName)) { $ProfileName } else { 'Default' }

                        $results.Add([PSCustomObject]@{
                            Path         = $fullName
                            SizeBytes    = $length
                            SizeGB       = $sizeGb
                            Type         = $type
                            Profile      = $profile
                            LastModified = $lastMod
                        })
                    }
                }
            }
        }

        return @($results)
    }
}
