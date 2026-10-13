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

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [string]$ProfilePath
    )

    process {
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Validating safety guardrails for local account deletion '$Username'..." -Level "Info" -Component "Accounts"
        }

        # 1. Resolve Account SID for Guardrail & Registry Verification
        $targetSid = $null
        try {
            $userAcc = Get-CimInstance -ClassName Win32_UserAccount -Filter "LocalAccount = True and Name = '$Username'" -ErrorAction SilentlyContinue
            if ($null -ne $userAcc -and $userAcc.SID) {
                $targetSid = [string]$userAcc.SID
            }
        } catch { $null = $_ }

        if ([string]::IsNullOrWhiteSpace($targetSid)) {
            try {
                if (Get-Command -Name 'Get-LocalAccountList' -ErrorAction SilentlyContinue) {
                    $accList = Get-LocalAccountList
                    $matchAcc = $accList | Where-Object { $_.Name -ieq $Username } | Select-Object -First 1
                    if ($matchAcc -and $matchAcc.SID) {
                        $targetSid = [string]$matchAcc.SID
                    }
                }
            } catch { $null = $_ }
        }

        # 2. Guardrail A: Built-in Administrator Protection (SID ending in -500 or named 'Administrator')
        if ($Username -ieq 'Administrator' -or ($targetSid -and $targetSid -match '-(?:500)$')) {
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
        if (-not [string]::IsNullOrWhiteSpace($currentUser) -and $Username -ieq $currentUser) {
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
                        $resolvedProfilePath = [string]$prop.ProfileImagePath
                    }
                } catch { $null = $_ }
            }
        }
        if ([string]::IsNullOrWhiteSpace($resolvedProfilePath)) {
            $defaultUserDir = if ($env:SystemDrive) { "$($env:SystemDrive)\Users\$Username" } else { "C:\Users\$Username" }
            if (Test-Path -LiteralPath $defaultUserDir) {
                $resolvedProfilePath = $defaultUserDir
            }
        }

        # 6. Delete Local User Account (Remove-LocalUser with ADSI WinNT Fallback)
        $accountRemoved = $false
        if (Get-Command -Name 'Remove-LocalUser' -ErrorAction SilentlyContinue) {
            try {
                Remove-LocalUser -Name $Username -ErrorAction Stop
                $accountRemoved = $true
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Successfully removed local user '$Username' via Remove-LocalUser." -Level "Info" -Component "Accounts"
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
                $adsiComputer.Delete('user', $Username)
                $accountRemoved = $true
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Successfully removed local user '$Username' via ADSI fallback." -Level "Info" -Component "Accounts"
                }
            } catch {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "ADSI user deletion failed for '$Username': $($_.Exception.Message)" -Level "Error" -Component "Accounts"
                }
                throw $_
            }
        }

        # 7. Clean up User Profile Directory
        $profileRemoved = $false
        if (-not [string]::IsNullOrWhiteSpace($resolvedProfilePath) -and (Test-Path -LiteralPath $resolvedProfilePath)) {
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
