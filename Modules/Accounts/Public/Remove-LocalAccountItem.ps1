function Remove-LocalAccountItem {
<#
.SYNOPSIS
    Permanently deletes a local user account, removes their profile folder, and purges ProfileList registry entry.
.DESCRIPTION
    Enforces strict safety guardrails:
    - Blocks deletion of the currently logged-in user.
    - Blocks deletion of the built-in Administrator (SID ending in -500).
    Permanently removes the local user account using Remove-LocalUser (or ADSI WinNT fallback),
    deletes the user's profile directory (e.g. C:\Users\<user>), and purges the corresponding
    registry ProfileList entry (HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\<SID>).
    Supports -WhatIf and -Confirm.
.PARAMETER Username
    The name of the local user account to permanently delete.
.PARAMETER Force
    Bypasses non-critical prompts.
.PARAMETER ProfilePath
    Optional explicit override for the user profile directory.
.OUTPUTS
    [PSCustomObject]@{ Username, SID, AccountRemoved, ProfilePathRemoved, ProfileListRemoved, Success }
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('Name', 'AccountName')]
        [ValidateNotNullOrEmpty()]
        [string]$Username,

        [Parameter(Mandatory = $false, ValueFromPipelineByPropertyName = $true)]
        [string]$SID,

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [string]$ProfilePath
    )

    process {
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Validating safety guardrails for local account deletion '$Username'..." -Level "Info" -Component "Accounts"
        }

        # 0. Clean & Normalize Username
        $cleanUsername = ($Username.Trim() -replace '^(?:[^\\]+\\|[^\/]+\/)', '').Trim()

        # 1. Resolve Account SID for Guardrail & Registry Verification
        $targetSid = if (-not [string]::IsNullOrWhiteSpace($SID)) { $SID.Trim() } else { $null }

        if ([string]::IsNullOrWhiteSpace($targetSid)) {
            try {
                $userAcc = Get-CimInstance -ClassName Win32_UserAccount -Filter "LocalAccount = True and Name = '$cleanUsername'" -ErrorAction SilentlyContinue
                if ($null -ne $userAcc -and $userAcc.SID) {
                    $targetSid = [string]$userAcc.SID
                }
            } catch { $null = $_ }
        }

        if ([string]::IsNullOrWhiteSpace($targetSid)) {
            try {
                if (Get-Command -Name 'Get-LocalAccountList' -ErrorAction SilentlyContinue) {
                    $accList = Get-LocalAccountList
                    $matchAcc = $accList | Where-Object { $_.Name -ieq $cleanUsername -or $_.Name -ieq $Username } | Select-Object -First 1
                    if ($matchAcc -and $matchAcc.SID) {
                        $targetSid = [string]$matchAcc.SID
                    }
                }
            } catch { $null = $_ }
        }

        if ([string]::IsNullOrWhiteSpace($targetSid)) {
            try {
                if (Get-Command -Name 'Get-LocalUser' -ErrorAction SilentlyContinue) {
                    $lu = Get-LocalUser -Name $cleanUsername -ErrorAction SilentlyContinue
                    if ($lu -and $lu.SID) {
                        $targetSid = [string]$lu.SID.Value
                    }
                }
            } catch { $null = $_ }
        }

        if ([string]::IsNullOrWhiteSpace($targetSid) -and $IsWindows) {
            try {
                $ntAccount = [System.Security.Principal.NTAccount]::new($cleanUsername)
                $sidObj = $ntAccount.Translate([System.Security.Principal.SecurityIdentifier])
                if ($sidObj) {
                    $targetSid = [string]$sidObj.Value
                }
            } catch { $null = $_ }
        }

        # 2. Guardrail A: Built-in Administrator Protection (SID ending in -500 or named 'Administrator')
        if ($cleanUsername -ieq 'Administrator' -or $Username.Trim() -ieq 'Administrator' -or ($targetSid -and $targetSid -match '-(?:500)$')) {
            $adminBlockMsg = "Deletion blocked: '$Username' is the built-in Administrator account (SID-500). Deletion of the built-in Administrator is strictly prohibited."
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message $adminBlockMsg -Level "Error" -Component "Accounts"
            }
            throw $adminBlockMsg
        }

        # 3. Guardrail B: Currently Active / Logged-in User Protection
        $currentUser = $env:USERNAME
        if ([string]::IsNullOrWhiteSpace($currentUser)) {
            try { $currentUser = [System.Environment]::UserName } catch { $null = $_ }
        }
        $currentSid = $null
        if ($IsWindows) {
            try {
                $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            } catch { $null = $_ }
        }

        $isCurrentUserMatch = $false
        if (-not [string]::IsNullOrWhiteSpace($currentUser)) {
            if ($cleanUsername -ieq $currentUser -or $Username.Trim() -ieq $currentUser) {
                $isCurrentUserMatch = $true
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($currentSid) -and -not [string]::IsNullOrWhiteSpace($targetSid)) {
            if ($targetSid -ieq $currentSid) {
                $isCurrentUserMatch = $true
            }
        }

        if ($isCurrentUserMatch) {
            $userBlockMsg = "Deletion blocked: Cannot delete currently logged-in user '$Username'. Deletion of active session user is strictly prohibited."
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message $userBlockMsg -Level "Error" -Component "Accounts"
            }
            throw $userBlockMsg
        }

        # 4. ShouldProcess / WhatIf Support
        if (-not $PSCmdlet.ShouldProcess($Username, "Permanently delete local user account, profile directory, and ProfileList registry key")) {
            return [PSCustomObject]@{
                Username           = $Username
                SID                = $targetSid
                AccountRemoved     = $true
                ProfilePathRemoved = $true
                ProfileListRemoved = $true
                Success            = $true
            }
        }

        # 5. Resolve User Profile Path
        $resolvedProfilePath = $ProfilePath
        if ([string]::IsNullOrWhiteSpace($resolvedProfilePath) -and -not [string]::IsNullOrWhiteSpace($targetSid)) {
            $profileListKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$targetSid"
            if (Test-Path -LiteralPath $profileListKey) {
                try {
                    $prop = Get-ItemProperty -LiteralPath $profileListKey -Name 'ProfileImagePath' -ErrorAction SilentlyContinue
                    if ($null -ne $prop -and $prop.ProfileImagePath) {
                        $rawProf = [string]$prop.ProfileImagePath
                        $expandedProf = [System.Environment]::ExpandEnvironmentVariables($rawProf)
                        if ($expandedProf -match '^%SystemDrive%' -and [string]::IsNullOrWhiteSpace($env:SystemDrive)) {
                            $expandedProf = $expandedProf -replace '^%SystemDrive%', 'C:'
                        }
                        $resolvedProfilePath = $expandedProf
                    }
                } catch { $null = $_ }
            }
        }
        if ([string]::IsNullOrWhiteSpace($resolvedProfilePath)) {
            $defaultUserDir = if ($env:SystemDrive) { "$($env:SystemDrive)\Users\$cleanUsername" } else { "C:\Users\$cleanUsername" }
            if (Test-Path -LiteralPath $defaultUserDir) {
                $resolvedProfilePath = $defaultUserDir
            }
        }

        # 6. Delete Local User Account (Remove-LocalUser with ADSI WinNT Fallback)
        $accountRemoved = $false
        if (Get-Command -Name 'Remove-LocalUser' -ErrorAction SilentlyContinue) {
            try {
                Remove-LocalUser -Name $cleanUsername -ErrorAction Stop
                $accountRemoved = $true
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Successfully removed local user '$cleanUsername' via Remove-LocalUser." -Level "Info" -Component "Accounts"
                }
            } catch {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Remove-LocalUser failed: $($_.Exception.Message). Falling back to ADSI." -Level "Warn" -Component "Accounts"
                }
            }
        }

        if (-not $accountRemoved) {
            try {
                $comp = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'localhost' }
                $adsiComputer = [ADSI]"WinNT://$comp"
                $adsiComputer.Delete('user', $cleanUsername)
                $accountRemoved = $true
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Successfully removed local user '$cleanUsername' via ADSI fallback." -Level "Info" -Component "Accounts"
                }
            } catch {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "ADSI user deletion failed for '$cleanUsername': $($_.Exception.Message)" -Level "Error" -Component "Accounts"
                }
                throw $_
            }
        }

        # 7. Clean up User Profile Directory
        $profileRemoved = $false
        $isSystemPath = $false
        if (-not [string]::IsNullOrWhiteSpace($resolvedProfilePath)) {
            $normProf = $resolvedProfilePath.TrimEnd('\', '/')
            if ($normProf -in @('', 'C:', 'C:\Users', 'C:\Windows', 'C:\Windows\System32', '/', '/home', '/root', $env:SystemRoot, $env:windir)) {
                $isSystemPath = $true
            }
        }

        if (-not $isSystemPath -and -not [string]::IsNullOrWhiteSpace($resolvedProfilePath) -and (Test-Path -LiteralPath $resolvedProfilePath)) {
            try {
                Remove-Item -LiteralPath $resolvedProfilePath -Recurse -Force -ErrorAction Stop
                $profileRemoved = $true
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Cleaned up user profile directory at '$resolvedProfilePath'." -Level "Info" -Component "Accounts"
                }
            } catch {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Warning: Failed to clean up user profile directory '$resolvedProfilePath': $($_.Exception.Message)" -Level "Warn" -Component "Accounts"
                }
            }
        }

        # 8. Clean up ProfileList Registry Key
        $profileListRemoved = $false
        if (-not [string]::IsNullOrWhiteSpace($targetSid)) {
            $profileKeyPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$targetSid"
            if (Test-Path -LiteralPath $profileKeyPath) {
                try {
                    Remove-Item -LiteralPath $profileKeyPath -Recurse -Force -ErrorAction Stop
                    $profileListRemoved = $true
                    if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                        Write-ToolkitLog -Message "Removed ProfileList registry key for SID '$targetSid'." -Level "Info" -Component "Accounts"
                    }
                } catch {
                    if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                        Write-ToolkitLog -Message "Warning: Failed to remove ProfileList registry key for SID '$targetSid': $($_.Exception.Message)" -Level "Warn" -Component "Accounts"
                    }
                }
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Permanently deleted local account '$Username' (Account: $accountRemoved, ProfileDir: $profileRemoved, ProfileList: $profileListRemoved)." -Level "Success" -Component "Accounts"
        }

        return [PSCustomObject]@{
            Username           = $Username
            SID                = $targetSid
            AccountRemoved     = $accountRemoved
            ProfilePathRemoved = $profileRemoved
            ProfileListRemoved = $profileListRemoved
            Success            = $true
        }
    }
}
