function Remove-OutlookDataFile {
<#
.SYNOPSIS
    Permanently deletes an Outlook PST or OST data file and detaches it from Outlook profiles.
.DESCRIPTION
    Safely verifies file locks and active Outlook processes before deletion.
    If Outlook is not running and the file is unlocked, removes/detaches the data file
    association from candidate Outlook profile registry configuration keys, and permanently
    deletes the physical file from disk. Supports -WhatIf and -Confirm.
.PARAMETER Path
    Path to the PST or OST data file to delete.
.PARAMETER ProfileName
    Outlook profile name to detach from. Defaults to active profile or 'Outlook'.
.PARAMETER Force
    Forces deletion even if non-critical warnings occur.
.OUTPUTS
    [PSCustomObject]@{ Path, Profile, FileDeleted, ProfileDetached, IsLocked, OutlookRunning, Success, ErrorMessage }
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('FilePath', 'SourcePath', 'FullName')]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$ProfileName,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        # Ensure private helper is loaded if running outside imported module
        if (-not (Get-Command -Name 'ConvertFrom-MapiBinaryProperty' -ErrorAction SilentlyContinue)) {
            $privHelper = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Private/ConvertFrom-MapiBinaryProperty.ps1'
            if (Test-Path -LiteralPath $privHelper) {
                . $privHelper
            }
        }

        # 1. Path Normalization & Extension Validation
        if ([string]::IsNullOrWhiteSpace($Path)) {
            throw "The data file path cannot be null, empty, or whitespace-only."
        }
        $cleanPath = $Path.Trim().Trim('"').Trim("'")
        if ([string]::IsNullOrWhiteSpace($cleanPath)) {
            throw "The data file path cannot be null, empty, or whitespace-only."
        }
        if ($cleanPath -notmatch '(?i)\.(pst|ost)$') {
            throw "The data file path must have a .pst or .ost extension: '$Path'"
        }

        $resolvedPath = [System.Environment]::ExpandEnvironmentVariables($cleanPath)
        if (-not ($resolvedPath -match '^[a-zA-Z]:[/\\]' -and [System.IO.Path]::DirectorySeparatorChar -ne [char]92)) {
            try {
                $resolvedPath = [System.IO.Path]::GetFullPath($resolvedPath)
            } catch { $null = $_ }
        }

        # 2. Reject Directory Paths
        if ([System.IO.Directory]::Exists($resolvedPath) -or ((Test-Path -LiteralPath $resolvedPath -PathType Container) -and -not (Test-Path -LiteralPath $resolvedPath -PathType Leaf))) {
            throw "The specified path is a directory, not an Outlook data file: '$Path'"
        }

        # 3. Resolve Target Profile
        $targetProfile = $ProfileName
        if ([string]::IsNullOrWhiteSpace($targetProfile)) {
            if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
                try {
                    $ctx = Get-OutlookSystemContext
                    if ($null -ne $ctx -and -not [string]::IsNullOrWhiteSpace($ctx.DefaultProfile) -and $ctx.DefaultProfile -ne 'None') {
                        $targetProfile = $ctx.DefaultProfile
                    }
                } catch { $null = $_ }
            }
        }
        if ([string]::IsNullOrWhiteSpace($targetProfile)) {
            $targetProfile = 'Outlook'
        }

        # 4. ShouldProcess / WhatIf Support
        $isWhatIf = ($PSBoundParameters.ContainsKey('WhatIf') -and $PSBoundParameters['WhatIf']) -or $WhatIfPreference
        if (-not $PSCmdlet.ShouldProcess($resolvedPath, "Permanently delete Outlook data file and detach from profile '$targetProfile'")) {
            if ($isWhatIf) {
                return [PSCustomObject]@{
                    Path            = $resolvedPath
                    Profile         = $targetProfile
                    FileDeleted     = $true
                    ProfileDetached = $true
                    IsLocked        = $false
                    OutlookRunning  = $false
                    Success         = $true
                    ErrorMessage    = $null
                }
            } else {
                return [PSCustomObject]@{
                    Path            = $resolvedPath
                    Profile         = $targetProfile
                    FileDeleted     = $false
                    ProfileDetached = $false
                    IsLocked        = $false
                    OutlookRunning  = $false
                    Success         = $false
                    ErrorMessage    = "Action cancelled by user confirmation prompt."
                }
            }
        }

        # 5. Pre-flight Process Check (Outlook running)
        $outlookProcs = @(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
        $outlookRunning = ($outlookProcs.Count -gt 0)

        # 6. Pre-flight Lock Check
        $isLocked = $false
        $lockErrorMessage = $null
        if (Get-Command -Name 'Test-OutlookDataFileLock' -ErrorAction SilentlyContinue) {
            $lockCheck = Test-OutlookDataFileLock -Path $resolvedPath
            if ($null -ne $lockCheck) {
                if ($lockCheck.OutlookRunning) {
                    $outlookRunning = $true
                }
                if ($lockCheck.IsLocked) {
                    $isLocked = $true
                    $lockErrorMessage = $lockCheck.ErrorMessage
                }
            }
        }

        if ($outlookRunning -or $isLocked) {
            $errMsg = if ($outlookRunning) {
                "Cannot delete data file while Outlook is running. Please close Outlook and try again."
            } else {
                "Data file is locked by an external process: '$resolvedPath' ($lockErrorMessage)"
            }
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message $errMsg -Level 'ERROR' -Component 'Outlook:Delete'
            }
            return [PSCustomObject]@{
                Path            = $resolvedPath
                Profile         = $targetProfile
                FileDeleted     = $false
                ProfileDetached = $false
                IsLocked        = $isLocked
                OutlookRunning  = $outlookRunning
                Success         = $false
                ErrorMessage    = $errMsg
            }
        }

        # 7. Detach Data File Association from Outlook Profile Registry
        $candidateProfileKeys = @(
            "HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles\$targetProfile",
            "HKCU:\Software\Microsoft\Office\15.0\Outlook\Profiles\$targetProfile",
            "HKCU:\Software\Microsoft\Office\14.0\Outlook\Profiles\$targetProfile",
            "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows Messaging Subsystem\Profiles\$targetProfile"
        )
        if (Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Office') {
            try {
                $officeVers = Get-ChildItem -LiteralPath 'HKCU:\Software\Microsoft\Office' -ErrorAction SilentlyContinue
                foreach ($v in $officeVers) {
                    $basePath = if ($v.PSPath) { [string]$v.PSPath } else { [string]$v.FullName }
                    if (-not [string]::IsNullOrWhiteSpace($basePath)) {
                        $dynKey = "$basePath\Outlook\Profiles\$targetProfile"
                        if ($candidateProfileKeys -notcontains $dynKey) {
                            $candidateProfileKeys += $dynKey
                        }
                    }
                }
            } catch { $null = $_ }
        }

        $targetTags = @('001f6700', '001f6620', '001e6700', '001e6620')
        $profileDetached = $false

        foreach ($profileKey in $candidateProfileKeys) {
            if (Test-Path -LiteralPath $profileKey) {
                try {
                    $subkeys = @(Get-ChildItem -LiteralPath $profileKey -ErrorAction SilentlyContinue)
                    foreach ($subkey in $subkeys) {
                        $itemProp = Get-ItemProperty -LiteralPath $subkey.PSPath -ErrorAction SilentlyContinue
                        if ($null -ne $itemProp) {
                            $matchFound = $false
                            foreach ($tag in $targetTags) {
                                if ($null -ne $itemProp.PSObject.Properties[$tag] -and $null -ne $itemProp.$tag) {
                                    $val = $itemProp.$tag
                                    $currentStr = $null

                                    if (Get-Command -Name 'ConvertFrom-MapiBinaryProperty' -ErrorAction SilentlyContinue) {
                                        $currentStr = ConvertFrom-MapiBinaryProperty -Bytes $val -PropertyName $tag
                                    }
                                    elseif ($val -is [byte[]]) {
                                        try {
                                            if ($tag -like '001e*') {
                                                $currentStr = [System.Text.Encoding]::Default.GetString($val).TrimEnd([char]0)
                                            } else {
                                                $currentStr = [System.Text.Encoding]::Unicode.GetString($val).TrimEnd([char]0)
                                            }
                                        } catch { $null = $_ }
                                    }
                                    elseif ($val -is [string]) {
                                        $currentStr = $val.Trim()
                                    }

                                    if (-not [string]::IsNullOrWhiteSpace($currentStr) -and ($currentStr -ieq $resolvedPath -or $currentStr -ieq $cleanPath -or $currentStr -ieq $Path)) {
                                        $matchFound = $true
                                        Remove-ItemProperty -LiteralPath $subkey.PSPath -Name $tag -Force -ErrorAction SilentlyContinue
                                        $profileDetached = $true
                                    }
                                }
                            }

                            if ($matchFound) {
                                Remove-Item -LiteralPath $subkey.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                            }
                        }
                    }
                }
                catch {
                    Write-Verbose "Error enumerating profile subkeys in '$profileKey': $($_.Exception.Message)"
                }
            }
        }

        # 8. Physical File Deletion
        $fileDeleted = $false
        $fileExists = Test-Path -LiteralPath $resolvedPath -PathType Leaf
        if ($fileExists) {
            try {
                Remove-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
                $fileDeleted = $true
            }
            catch {
                $errMsg = "Failed to delete file from disk: $($_.Exception.Message)"
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message $errMsg -Level 'ERROR' -Component 'Outlook:Delete'
                }
                return [PSCustomObject]@{
                    Path            = $resolvedPath
                    Profile         = $targetProfile
                    FileDeleted     = $false
                    ProfileDetached = $profileDetached
                    IsLocked        = $false
                    OutlookRunning  = $false
                    Success         = $false
                    ErrorMessage    = $errMsg
                }
            }
        }
        elseif (-not $profileDetached -and -not $Force) {
            $errMsg = "Data file does not exist on disk: '$resolvedPath'"
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message $errMsg -Level 'WARN' -Component 'Outlook:Delete'
            }
            return [PSCustomObject]@{
                Path            = $resolvedPath
                Profile         = $targetProfile
                FileDeleted     = $false
                ProfileDetached = $false
                IsLocked        = $false
                OutlookRunning  = $false
                Success         = $false
                ErrorMessage    = $errMsg
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Successfully permanently deleted data file '$resolvedPath' (Profile detached: $profileDetached)." -Level 'SUCCESS' -Component 'Outlook:Delete'
        }

        return [PSCustomObject]@{
            Path            = $resolvedPath
            Profile         = $targetProfile
            FileDeleted     = $fileDeleted
            ProfileDetached = $profileDetached
            IsLocked        = $false
            OutlookRunning  = $false
            Success         = $true
            ErrorMessage    = $null
        }
    }
}
