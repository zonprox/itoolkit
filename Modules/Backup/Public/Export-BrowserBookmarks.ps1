function Export-BrowserBookmarks {
<#
.SYNOPSIS
    Extracts Chrome and Edge browser bookmarks to a target backup directory.
.DESCRIPTION
    Scans Google Chrome and Microsoft Edge user data directories across profiles
    (Default, Profile 1, etc.), copies bookmark JSON files, and computes SHA-256 hashes.
.PARAMETER DestinationPath
    Target directory to export bookmark files to.
.PARAMETER Browsers
    Array of browser names to back up (default: @('Chrome', 'Edge')).
.OUTPUTS
    [PSCustomObject[]]@{ Browser, Profile, ExportPath, Hash }
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath,

        [Parameter(Mandatory = $false)]
        [string[]]$Browsers = @('Chrome', 'Edge')
    )

    process {
        if (-not (Test-Path -LiteralPath $DestinationPath)) {
            $null = New-Item -ItemType Directory -Path $DestinationPath -Force -ErrorAction SilentlyContinue
        }

        # Optional process check
        if (Get-Command -Name 'Test-ProcessRunning' -ErrorAction SilentlyContinue) {
            if (Test-ProcessRunning -ProcessName 'chrome') {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Google Chrome is running; bookmarks may be in active use." -Level 'WARN' -Component 'Backup:Bookmarks'
                }
            }
            if (Test-ProcessRunning -ProcessName 'msedge') {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Microsoft Edge is running; bookmarks may be in active use." -Level 'WARN' -Component 'Backup:Bookmarks'
                }
            }
        }

        $baseUserProfile = ''
        if ($env:USERPROFILE) {
            $baseUserProfile = $env:USERPROFILE
        } elseif ($env:HOME) {
            $baseUserProfile = $env:HOME
        }

        $localAppData = ''
        if ($env:LOCALAPPDATA) {
            $localAppData = $env:LOCALAPPDATA
        } else {
            $localAppData = Join-Path $baseUserProfile 'AppData/Local'
        }

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($browser in $Browsers) {
            $baseDir = ''
            if ($browser -eq 'Chrome') {
                $baseDir = Join-Path -Path $localAppData -ChildPath 'Google\Chrome\User Data'
            }
            elseif ($browser -eq 'Edge') {
                $baseDir = Join-Path -Path $localAppData -ChildPath 'Microsoft\Edge\User Data'
            }

            # Candidate profile names - always include Default
            $profiles = [System.Collections.Generic.List[string]]::new()
            $profiles.Add('Default')

            if (Test-Path -LiteralPath $baseDir) {
                try {
                    $foundProfiles = Get-ChildItem -LiteralPath $baseDir -Filter 'Profile *' -Directory -ErrorAction SilentlyContinue
                    if ($null -ne $foundProfiles) {
                        foreach ($p in $foundProfiles) {
                            if (-not $profiles.Contains($p.Name)) {
                                $profiles.Add($p.Name)
                            }
                        }
                    }
                }
                catch {
                    Write-Verbose "Could not enumerate profiles in '$baseDir': $($_.Exception.Message)"
                }
            }

            foreach ($profile in $profiles) {
                $bookmarkPath = Join-Path -Path (Join-Path -Path $baseDir -ChildPath $profile) -ChildPath 'Bookmarks'
                if (Test-Path -LiteralPath $bookmarkPath) {
                    $cleanProfile = $profile -replace '\s+', '_'
                    $exportFileName = "$($browser)_$($cleanProfile)_Bookmarks.json"
                    $targetFilePath = Join-Path -Path $DestinationPath -ChildPath $exportFileName -ErrorAction SilentlyContinue
                    if ([string]::IsNullOrWhiteSpace($targetFilePath)) {
                        $sep = '\'
                        if ($DestinationPath -match '/') {
                            $sep = '/'
                        }
                        $targetFilePath = "$($DestinationPath.TrimEnd('/\'))$sep$exportFileName"
                    }

                    try {
                        Copy-Item -LiteralPath $bookmarkPath -Destination $targetFilePath -Force -ErrorAction Stop

                        $hashVal = $null
                        $hashObj = Get-FileHash -LiteralPath $targetFilePath -Algorithm SHA256 -ErrorAction SilentlyContinue
                        if ($null -ne $hashObj -and $hashObj.PSObject.Properties['Hash']) {
                            $hashVal = $hashObj.Hash
                        }

                        $results.Add([PSCustomObject]@{
                            Browser    = $browser
                            Profile    = $profile
                            ExportPath = $targetFilePath
                            Hash       = $hashVal
                        })

                        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                            Write-ToolkitLog -Message "Exported $browser bookmarks ($profile) to '$targetFilePath'" -Level 'SUCCESS' -Component 'Backup:Bookmarks'
                        }
                    }
                    catch {
                        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                            Write-ToolkitLog -Message "Failed to export $browser bookmarks ($profile): $($_.Exception.Message)" -Level 'WARN' -Component 'Backup:Bookmarks'
                        }
                    }
                }
            }
        }

        return @($results)
    }
}
