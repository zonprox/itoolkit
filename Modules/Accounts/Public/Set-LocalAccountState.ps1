function Set-LocalAccountState {
<#
.SYNOPSIS
    Enables or disables a local user account.
.DESCRIPTION
    Toggles the account state using Enable-LocalUser or Disable-LocalUser.
.PARAMETER Username
    The name of the local user account.
.PARAMETER Enabled
    Boolean flag ($true to enable, $false to disable).
.OUTPUTS
    [bool] $true on success.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Username,

        [Parameter(Mandatory = $true, Position = 1)]
        [bool]$Enabled
    )

    process {
        $actionDesc = "Disable account"
        if ($Enabled) {
            $actionDesc = "Enable account"
        }
        if (-not $PSCmdlet.ShouldProcess($Username, $actionDesc)) {
            return $true
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Setting local account '$Username' Enabled state to $Enabled..." -Level "Info" -Component "Accounts"
        }

        try {
            if ($Enabled) {
                Enable-LocalUser -Name $Username -ErrorAction Stop
            }
            else {
                Disable-LocalUser -Name $Username -ErrorAction Stop
            }

            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Successfully updated local account '$Username' state to Enabled=$Enabled." -Level "Info" -Component "Accounts"
            }
            return $true
        }
        catch {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Failed to set state for local account '$Username': $($_.Exception.Message)" -Level "Error" -Component "Accounts"
            }
            throw $_
        }
    }
}
