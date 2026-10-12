function Invoke-OfficeToolPlus {
<#
.SYNOPSIS
    Pre-flight checks internet connectivity, prompts user confirmation, and launches Office Tool Plus.
.DESCRIPTION
    Validates outbound internet reachability, prompts user confirmation via Show-ToolkitConfirmation,
    and launches the Office Tool Plus deployment utility (https://otp.landian.vip/) for Office installation,
    KMS/MAK activation, and channel configuration.
    Complies with SecurityIntegrity rules by avoiding Invoke-Expression.
.PARAMETER Variant
    Target variant: 'Default' or 'Portable'. Default is 'Default'.
.OUTPUTS
    [PSCustomObject] containing ToolName, ScriptUrl, Launched, ExitCode.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('Default', 'Portable')]
        [string]$Variant = 'Default',

        [Parameter(Mandatory = $false)]
        [string]$ScriptUrl = 'https://otp.landian.vip/'
    )

    process {
        # 1. Pre-Flight Internet Connectivity Check
        $online = Test-InternetConnectivity
        if (-not $online) {
            throw "Pre-flight check failed: Internet connectivity is required to download and execute Office Tool Plus."
        }

        # 2. HTTPS Protocol Enforcement
        if ([string]::IsNullOrWhiteSpace($ScriptUrl) -or -not ($ScriptUrl.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase))) {
            throw "Security validation failed: ScriptUrl must use HTTPS protocol ('$ScriptUrl')."
        }

        # 3. Domain Whitelist Verification
        $targetUri = $null
        try {
            $targetUri = [System.Uri]$ScriptUrl
        } catch {
            throw "Security validation failed: Invalid ScriptUrl format ('$ScriptUrl')."
        }

        $allowedDomains = @(
            'raw.githubusercontent.com',
            'github.com',
            'otp.landian.vip',
            'packages.officetoolplus.net'
        )

        $domainAllowed = $false
        foreach ($d in $allowedDomains) {
            if ($targetUri.Host -eq $d -or $targetUri.Host.EndsWith(".$d", [System.StringComparison]::OrdinalIgnoreCase)) {
                $domainAllowed = $true
                break
            }
        }

        if (-not $domainAllowed) {
            throw "Security validation failed: Domain '$($targetUri.Host)' is not permitted by domain whitelist."
        }

        # 4. WhatIf / ShouldProcess Evaluation
        if (-not $PSCmdlet.ShouldProcess("Office Tool Plus ($ScriptUrl)", "Download and execute external Office deployment utility")) {
            return [PSCustomObject]@{
                ToolName  = 'OfficeToolPlus'
                ScriptUrl = $ScriptUrl
                Launched  = $false
                ExitCode  = $null
            }
        }

        # 5. Mandatory User Confirmation Prompt
        $confirmed = $false
        if (Get-Command -Name 'Show-ToolkitConfirmation' -ErrorAction SilentlyContinue) {
            $confirmed = Show-ToolkitConfirmation -Prompt "Office Tool Plus will execute external deployment tools from $ScriptUrl. Proceed?" -Default $false
        } else {
            try {
                if ($Host -and $Host.UI -and $Host.UI.PromptForChoice) {
                    $caption = "Security Confirmation Required"
                    $message = "Office Tool Plus will download and execute external code from $ScriptUrl. Do you want to proceed?"
                    $choices = @(
                        [System.Management.Automation.Host.ChoiceDescription]::new('&Yes', 'Execute external utility'),
                        [System.Management.Automation.Host.ChoiceDescription]::new('&No', 'Cancel execution')
                    )
                    $choice = $Host.UI.PromptForChoice($caption, $message, $choices, 1)
                    $confirmed = ($choice -eq 0)
                } else {
                    $confirmed = $false
                }
            } catch {
                $confirmed = $false
            }
        }

        if (-not $confirmed) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Office Tool Plus launch cancelled by user." -Level 'WARN' -Component 'Invoke-OfficeToolPlus'
            }
            return [PSCustomObject]@{
                ToolName  = 'OfficeToolPlus'
                ScriptUrl = $ScriptUrl
                Launched  = $false
                ExitCode  = $null
            }
        }

        # 6. Robust Utility Launch (winget first, portal fallback)
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Launching Office Tool Plus from $ScriptUrl..." -Level 'INFO' -Component 'Invoke-OfficeToolPlus'
        }

        $exitCode = 0
        $launched = $false

        # First attempt winget if available
        $wingetCmd = Get-Command -Name 'winget' -ErrorAction SilentlyContinue
        if ($null -ne $wingetCmd -and $Variant -ne 'Portable') {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Deploying Office Tool Plus via winget (Yerong.OfficeToolPlus)..." -Level 'INFO' -Component 'Invoke-OfficeToolPlus'
            }
            $wingetArgs = "install --id Yerong.OfficeToolPlus --silent --accept-package-agreements --accept-source-agreements"
            $proc = Start-Process -FilePath "winget" -ArgumentList $wingetArgs -Wait -PassThru -ErrorAction SilentlyContinue
            if ($null -ne $proc) {
                $launched = $true
                if ($proc.PSObject.Properties['ExitCode'] -and $null -ne $proc.ExitCode) {
                    $exitCode = $proc.ExitCode
                }
            }
        }

        # If winget unavailable or failed, launch official portal or portable package site
        if (-not $launched) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Winget unavailable. Launching Office Tool Plus portal at $ScriptUrl..." -Level 'INFO' -Component 'Invoke-OfficeToolPlus'
            }
            $proc = Start-Process -FilePath $ScriptUrl -PassThru -ErrorAction Stop
            $launched = $true
            if ($null -ne $proc -and $proc.PSObject.Properties['ExitCode'] -and $null -ne $proc.ExitCode) {
                $exitCode = $proc.ExitCode
            }
        }

        return [PSCustomObject]@{
            ToolName  = 'OfficeToolPlus'
            ScriptUrl = $ScriptUrl
            Launched  = $launched
            ExitCode  = $exitCode
        }
    }
}
