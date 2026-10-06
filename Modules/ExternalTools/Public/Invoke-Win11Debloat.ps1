function Invoke-Win11Debloat {
<#
.SYNOPSIS
    Pre-flight checks internet connectivity, prompts user confirmation, and launches Win11Debloat.
.DESCRIPTION
    Performs outbound internet validation, prompts the user with Show-ToolkitConfirmation,
    and launches the selected Win11Debloat script variant via an elevated external PowerShell process.
    Complies with SecurityIntegrity rules by avoiding Invoke-Expression.
.PARAMETER Variant
    Target script variant: 'Default', 'Raphire', or 'Yashg'. Default is 'Default'.
.OUTPUTS
    [PSCustomObject] containing ToolName, ScriptUrl, Launched, ExitCode.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('Default', 'Raphire', 'Yashg')]
        [string]$Variant = 'Default'
    )

    process {
        # 1. Pre-Flight Internet Connectivity Check
        $online = Test-InternetConnectivity
        if (-not $online) {
            throw "Pre-flight check failed: Internet connectivity is required to download and execute Win11Debloat."
        }

        # 2. Resolve Script URL
        $scriptUrl = 'https://debloat.yashg.dev/install.ps1'
        if ($Variant -eq 'Raphire') {
            $scriptUrl = 'https://debloat.raphi.re/'
        }

        # 3. WhatIf / ShouldProcess Evaluation
        if (-not $PSCmdlet.ShouldProcess("Win11Debloat ($scriptUrl)", "Download and execute external debloat utility")) {
            return [PSCustomObject]@{
                ToolName  = 'Win11Debloat'
                ScriptUrl = $scriptUrl
                Launched  = $false
                ExitCode  = $null
            }
        }

        # 4. Mandatory User Confirmation Prompt
        $confirmed = $false
        if (Get-Command -Name 'Show-ToolkitConfirmation' -ErrorAction SilentlyContinue) {
            $confirmed = Show-ToolkitConfirmation -Prompt "Win11Debloat will execute external code from $scriptUrl. Proceed?" -Default $false
        } else {
            try {
                if ($Host -and $Host.UI -and $Host.UI.PromptForChoice) {
                    $caption = "Security Confirmation Required"
                    $message = "Win11Debloat will download and execute external code from $scriptUrl. Do you want to proceed?"
                    $choices = @(
                        [System.Management.Automation.Host.ChoiceDescription]::new('&Yes', 'Execute external script'),
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
                Write-ToolkitLog -Message "Win11Debloat launch cancelled by user." -Level 'WARN' -Component 'Invoke-Win11Debloat'
            }
            return [PSCustomObject]@{
                ToolName  = 'Win11Debloat'
                ScriptUrl = $scriptUrl
                Launched  = $false
                ExitCode  = $null
            }
        }

        # 5. Launch Process safely without Invoke-Expression
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Launching Win11Debloat from $scriptUrl..." -Level 'INFO' -Component 'Invoke-Win11Debloat'
        }

        $commandPayload = "& { [scriptblock]::Create((Invoke-RestMethod '$scriptUrl')).Invoke() }"
        $processArgs = "-NoProfile -ExecutionPolicy Bypass -Command `"$commandPayload`""

        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $processArgs -Wait -PassThru -ErrorAction Stop

        $exitCode = 0
        if ($null -ne $proc -and $proc.PSObject.Properties['ExitCode'] -and $null -ne $proc.ExitCode) {
            $exitCode = $proc.ExitCode
        }

        return [PSCustomObject]@{
            ToolName  = 'Win11Debloat'
            ScriptUrl = $scriptUrl
            Launched  = $true
            ExitCode  = $exitCode
        }
    }
}
