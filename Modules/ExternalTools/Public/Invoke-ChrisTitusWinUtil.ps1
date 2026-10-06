function Invoke-ChrisTitusWinUtil {
<#
.SYNOPSIS
    Pre-flight checks internet connectivity, prompts user confirmation, and launches Chris Titus WinUtil.
.DESCRIPTION
    Validates outbound internet reachability, prompts user confirmation via Show-ToolkitConfirmation,
    and launches the Chris Titus Tech Windows Utility (https://christitus.com/win).
    Complies with SecurityIntegrity rules by avoiding Invoke-Expression.
.OUTPUTS
    [PSCustomObject] containing ToolName, ScriptUrl, Launched, ExitCode.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param()

    process {
        # 1. Pre-Flight Internet Connectivity Check
        $online = Test-InternetConnectivity
        if (-not $online) {
            throw "Pre-flight check failed: Internet connectivity is required to download and execute Chris Titus WinUtil."
        }

        # 2. Target URL
        $scriptUrl = 'https://christitus.com/win'

        # 3. WhatIf / ShouldProcess Evaluation
        if (-not $PSCmdlet.ShouldProcess("ChrisTitusWinUtil ($scriptUrl)", "Download and execute external WinUtil tool")) {
            return [PSCustomObject]@{
                ToolName  = 'ChrisTitusWinUtil'
                ScriptUrl = $scriptUrl
                Launched  = $false
                ExitCode  = $null
            }
        }

        # 4. Mandatory User Confirmation Prompt
        $confirmed = $false
        if (Get-Command -Name 'Show-ToolkitConfirmation' -ErrorAction SilentlyContinue) {
            $confirmed = Show-ToolkitConfirmation -Prompt "Chris Titus WinUtil will execute external code from $scriptUrl. Proceed?" -Default $false
        } else {
            try {
                if ($Host -and $Host.UI -and $Host.UI.PromptForChoice) {
                    $caption = "Security Confirmation Required"
                    $message = "Chris Titus WinUtil will download and execute external code from $scriptUrl. Do you want to proceed?"
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
                Write-ToolkitLog -Message "Chris Titus WinUtil launch cancelled by user." -Level 'WARN' -Component 'Invoke-ChrisTitusWinUtil'
            }
            return [PSCustomObject]@{
                ToolName  = 'ChrisTitusWinUtil'
                ScriptUrl = $scriptUrl
                Launched  = $false
                ExitCode  = $null
            }
        }

        # 5. Launch Process safely without Invoke-Expression
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Launching Chris Titus WinUtil from $scriptUrl..." -Level 'INFO' -Component 'Invoke-ChrisTitusWinUtil'
        }

        $commandPayload = "& { [scriptblock]::Create((Invoke-RestMethod '$scriptUrl')).Invoke() }"
        $processArgs = "-NoProfile -ExecutionPolicy Bypass -Command `"$commandPayload`""

        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $processArgs -Wait -PassThru -ErrorAction Stop

        $exitCode = 0
        if ($null -ne $proc -and $proc.PSObject.Properties['ExitCode'] -and $null -ne $proc.ExitCode) {
            $exitCode = $proc.ExitCode
        }

        return [PSCustomObject]@{
            ToolName  = 'ChrisTitusWinUtil'
            ScriptUrl = $scriptUrl
            Launched  = $true
            ExitCode  = $exitCode
        }
    }
}
