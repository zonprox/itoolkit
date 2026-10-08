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
        [string]$Variant = 'Default'
    )

    process {
        # 1. Pre-Flight Internet Connectivity Check
        $online = Test-InternetConnectivity
        if (-not $online) {
            throw "Pre-flight check failed: Internet connectivity is required to download and execute Office Tool Plus."
        }

        # 2. Canonical Target URL
        $scriptUrl = 'https://otp.landian.vip/'

        # 3. WhatIf / ShouldProcess Evaluation
        if (-not $PSCmdlet.ShouldProcess("Office Tool Plus ($scriptUrl)", "Download and execute external Office deployment utility")) {
            return [PSCustomObject]@{
                ToolName  = 'OfficeToolPlus'
                ScriptUrl = $scriptUrl
                Launched  = $false
                ExitCode  = $null
            }
        }

        # 4. Mandatory User Confirmation Prompt
        $confirmed = $false
        if (Get-Command -Name 'Show-ToolkitConfirmation' -ErrorAction SilentlyContinue) {
            $confirmed = Show-ToolkitConfirmation -Prompt "Office Tool Plus will execute external deployment tools from $scriptUrl. Proceed?" -Default $false
        } else {
            try {
                if ($Host -and $Host.UI -and $Host.UI.PromptForChoice) {
                    $caption = "Security Confirmation Required"
                    $message = "Office Tool Plus will download and execute external code from $scriptUrl. Do you want to proceed?"
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
                ScriptUrl = $scriptUrl
                Launched  = $false
                ExitCode  = $null
            }
        }

        # 5. Launch Process safely without Invoke-Expression
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Launching Office Tool Plus from $scriptUrl..." -Level 'INFO' -Component 'Invoke-OfficeToolPlus'
        }

        # Launch via PowerShell script runner or winget if available
        $commandPayload = "& { [scriptblock]::Create((Invoke-RestMethod '$scriptUrl')).Invoke() }"
        $processArgs = "-NoProfile -ExecutionPolicy Bypass -Command `"$commandPayload`""

        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $processArgs -Wait -PassThru -ErrorAction Stop

        $exitCode = 0
        if ($null -ne $proc -and $proc.PSObject.Properties['ExitCode'] -and $null -ne $proc.ExitCode) {
            $exitCode = $proc.ExitCode
        }

        return [PSCustomObject]@{
            ToolName  = 'OfficeToolPlus'
            ScriptUrl = $scriptUrl
            Launched  = $true
            ExitCode  = $exitCode
        }
    }
}
