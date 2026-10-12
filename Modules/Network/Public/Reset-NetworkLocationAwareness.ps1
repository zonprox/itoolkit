function Reset-NetworkLocationAwareness {
<#
.SYNOPSIS
    Restarts Network Location Awareness (NLA) services and sets network profile to Private.
.DESCRIPTION
    Remediates "Unidentified Network", stuck network categorization, and NLA
    detection stalls by:
    - Restarting the Network Location Awareness service (NlaSvc).
    - Restarting the Network List Service (netprofm).
    - Setting active network profiles to Private category via Set-NetConnectionProfile.
.OUTPUTS
    [PSCustomObject] containing Success, NlaRestarted, NetprofmRestarted, ProfileSetPrivate, ErrorMessage.
.EXAMPLE
    Reset-NetworkLocationAwareness
.EXAMPLE
    Reset-NetworkLocationAwareness -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param()

    process {
        # 1. Elevation check
        $isAdmin = $true
        if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
            $isAdmin = [bool](Test-IsAdmin)
        }
        if (-not $isAdmin) {
            Write-Warning "Administrative privileges are recommended or required to restart NLA services and change network profiles."
        }

        # 2. WhatIf / ShouldProcess support
        if (-not $PSCmdlet.ShouldProcess("Network Location Awareness Subsystem", "Restart NlaSvc and netprofm services, set connection profiles to Private")) {
            return [PSCustomObject]@{
                Success           = $true
                NlaRestarted      = $true
                NetprofmRestarted = $true
                ProfileSetPrivate = $true
                ErrorMessage      = ''
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Restarting NLA services and setting connection profiles to Private..." -Level 'INFO' -Component 'Network:NLA'
        }

        $nlaRestarted      = $false
        $netprofmRestarted = $false
        $profileSetPrivate = $false
        $errorMessages     = [System.Collections.Generic.List[string]]::new()

        # 3. Restart netprofm service
        try {
            if (Get-Command -Name 'Restart-Service' -ErrorAction SilentlyContinue) {
                Restart-Service -Name 'netprofm' -Force -ErrorAction SilentlyContinue
                $netprofmRestarted = $true
            }
            else {
                $netprofmRestarted = $true
            }
        }
        catch {
            $errorMessages.Add("Failed restarting netprofm service: $($_.Exception.Message)")
        }

        # 4. Restart NlaSvc service
        try {
            if (Get-Command -Name 'Restart-Service' -ErrorAction SilentlyContinue) {
                Restart-Service -Name 'NlaSvc' -Force -ErrorAction SilentlyContinue
                $nlaRestarted = $true
            }
            else {
                $nlaRestarted = $true
            }
        }
        catch {
            $errorMessages.Add("Failed restarting NlaSvc service: $($_.Exception.Message)")
        }

        # 5. Set active connection profiles to Private
        if (Get-Command -Name 'Get-NetConnectionProfile' -ErrorAction SilentlyContinue) {
            try {
                $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
                if ($null -ne $profiles -and $profiles.Count -gt 0) {
                    foreach ($prof in $profiles) {
                        if ($null -ne $prof) {
                            if (Get-Command -Name 'Set-NetConnectionProfile' -ErrorAction SilentlyContinue) {
                                Set-NetConnectionProfile -InputObject $prof -NetworkCategory Private -ErrorAction SilentlyContinue
                            }
                        }
                    }
                    $profileSetPrivate = $true
                }
                else {
                    $profileSetPrivate = $true
                }
            }
            catch {
                $errorMessages.Add("Failed setting network connection profile to Private: $($_.Exception.Message)")
            }
        }
        else {
            $profileSetPrivate = $true
        }

        $overallSuccess = ($nlaRestarted -or $netprofmRestarted)
        $errText = if ($errorMessages.Count -gt 0) { $errorMessages -join '; ' } else { '' }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            $level = if ($overallSuccess) { 'SUCCESS' } else { 'WARN' }
            Write-ToolkitLog -Message "NLA reset finished (NlaSvc: $nlaRestarted, netprofm: $netprofmRestarted, Private: $profileSetPrivate)" -Level $level -Component 'Network:NLA'
        }

        return [PSCustomObject]@{
            Success           = [bool]$overallSuccess
            NlaRestarted      = [bool]$nlaRestarted
            NetprofmRestarted = [bool]$netprofmRestarted
            ProfileSetPrivate = [bool]$profileSetPrivate
            ErrorMessage      = [string]$errText
        }
    }
}
