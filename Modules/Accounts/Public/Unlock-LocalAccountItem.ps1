function Unlock-LocalAccountItem {
<#
.SYNOPSIS
    Clears the lockout flag for a local user account.
.DESCRIPTION
    Unlocks a local account using Unlock-LocalUser if present, or falling back to
    ADSI WinNT provider ([ADSI]"WinNT://$env:COMPUTERNAME/$Username,user").
.PARAMETER Username
    The local account username to unlock.
.OUTPUTS
    [bool] $true if unlocked successfully.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Username
    )

    process {
        if (-not $PSCmdlet.ShouldProcess($Username, "Unlock local user account lockout flag")) {
            return $true
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Unlocking local account '$Username'..." -Level "Info" -Component "Accounts"
        }

        # 1. Check if Unlock-LocalUser command exists (e.g. Pester mock or future cmdlet)
        if (Get-Command -Name 'Unlock-LocalUser' -ErrorAction SilentlyContinue) {
            try {
                Unlock-LocalUser -Name $Username -ErrorAction Stop
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Successfully unlocked local account '$Username' via Unlock-LocalUser." -Level "Info" -Component "Accounts"
                }
                return $true
            }
            catch {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Unlock-LocalUser failed: $($_.Exception.Message). Falling back to ADSI." -Level "Warn" -Component "Accounts"
                }
            }
        }

        # 2. ADSI WinNT fallback for production Windows
        try {
            $computer = $env:COMPUTERNAME
            $userEntry = [ADSI]"WinNT://$computer/$Username,user"
            if ($null -eq $userEntry -or [string]::IsNullOrWhiteSpace($userEntry.Name)) {
                throw "Local user account '$Username' was not found on computer '$computer'."
            }

            $userEntry.IsAccountLocked = $false
            $userEntry.SetInfo()

            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Successfully unlocked local account '$Username' via ADSI." -Level "Info" -Component "Accounts"
            }
            return $true
        }
        catch {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "ADSI unlock failed for user '$Username': $($_.Exception.Message)" -Level "Error" -Component "Accounts"
            }
            throw $_
        }
    }
}
