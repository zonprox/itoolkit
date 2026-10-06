function Get-UserProfileDirectoryMap {
<#
.SYNOPSIS
    Discovers standard user profile directories and detects OneDrive redirection.
.DESCRIPTION
    Resolves filesystem paths for Desktop, Documents, Downloads, Favorites, and Pictures
    by inspecting Windows User Shell Folders registry keys, expanding environment variables,
    and evaluating OneDrive folder redirection.
.OUTPUTS
    [PSCustomObject]@{ Desktop, Documents, Downloads, Favorites, Pictures, IsOneDriveRedirected }
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    process {
        $userProfile = ''
        if ($env:USERPROFILE) {
            $userProfile = $env:USERPROFILE
        } elseif ($env:HOME) {
            $userProfile = $env:HOME
        }

        # Default standard paths
        $desktop   = Join-Path -Path $userProfile -ChildPath 'Desktop'
        $documents = Join-Path -Path $userProfile -ChildPath 'Documents'
        $downloads = Join-Path -Path $userProfile -ChildPath 'Downloads'
        $favorites = Join-Path -Path $userProfile -ChildPath 'Favorites'
        $pictures  = Join-Path -Path $userProfile -ChildPath 'Pictures'

        # Query Windows User Shell Folders registry key
        $shellKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        $regProps = $null
        try {
            $regProps = Get-ItemProperty -Path $shellKey -ErrorAction SilentlyContinue
        }
        catch {
            Write-Verbose "Could not read User Shell Folders registry key: $($_.Exception.Message)"
        }

        if ($null -ne $regProps) {
            if ($regProps.PSObject.Properties['Desktop'] -and -not [string]::IsNullOrWhiteSpace($regProps.Desktop)) {
                $desktop = [System.Environment]::ExpandEnvironmentVariables([string]$regProps.Desktop)
            }
            if ($regProps.PSObject.Properties['Personal'] -and -not [string]::IsNullOrWhiteSpace($regProps.Personal)) {
                $documents = [System.Environment]::ExpandEnvironmentVariables([string]$regProps.Personal)
            }
            if ($regProps.PSObject.Properties['{374DE290-123F-4565-9164-39C4925E467B}'] -and -not [string]::IsNullOrWhiteSpace($regProps.'{374DE290-123F-4565-9164-39C4925E467B}')) {
                $downloads = [System.Environment]::ExpandEnvironmentVariables([string]$regProps.'{374DE290-123F-4565-9164-39C4925E467B}')
            }
            elseif ($regProps.PSObject.Properties['Downloads'] -and -not [string]::IsNullOrWhiteSpace($regProps.Downloads)) {
                $downloads = [System.Environment]::ExpandEnvironmentVariables([string]$regProps.Downloads)
            }
            if ($regProps.PSObject.Properties['Favorites'] -and -not [string]::IsNullOrWhiteSpace($regProps.Favorites)) {
                $favorites = [System.Environment]::ExpandEnvironmentVariables([string]$regProps.Favorites)
            }
            if ($regProps.PSObject.Properties['My Pictures'] -and -not [string]::IsNullOrWhiteSpace($regProps.'My Pictures')) {
                $pictures = [System.Environment]::ExpandEnvironmentVariables([string]$regProps.'My Pictures')
            }
            elseif ($regProps.PSObject.Properties['Pictures'] -and -not [string]::IsNullOrWhiteSpace($regProps.Pictures)) {
                $pictures = [System.Environment]::ExpandEnvironmentVariables([string]$regProps.Pictures)
            }
        }

        # Check for OneDrive redirection
        $isOneDriveRedirected = $false
        $allPaths = @($desktop, $documents, $downloads, $favorites, $pictures)
        foreach ($p in $allPaths) {
            if ($p -match '(?i)OneDrive') {
                $isOneDriveRedirected = $true
                break
            }
        }

        if (-not $isOneDriveRedirected -and $null -ne $regProps) {
            foreach ($prop in $regProps.PSObject.Properties) {
                if ([string]$prop.Value -match '(?i)OneDrive') {
                    $isOneDriveRedirected = $true
                    break
                }
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Resolved user profile paths (OneDrive redirected: $isOneDriveRedirected)" -Level 'INFO' -Component 'Backup:DirectoryMap'
        }

        return [PSCustomObject]@{
            Desktop              = $desktop
            Documents            = $documents
            Downloads            = $downloads
            Favorites            = $favorites
            Pictures             = $pictures
            IsOneDriveRedirected = $isOneDriveRedirected
        }
    }
}
