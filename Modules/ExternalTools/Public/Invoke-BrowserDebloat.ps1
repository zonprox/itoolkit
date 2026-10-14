function Invoke-BrowserDebloat {
<#
.SYNOPSIS
    Pre-flight checks internet connectivity, prompts user confirmation, and launches Browser Debloat.
.DESCRIPTION
    Validates outbound internet reachability, prompts user confirmation via Show-ToolkitConfirmation,
    and launches the Browser Debloat script (https://debloat.yashg.dev/install.ps1).
    Complies with SecurityIntegrity rules by avoiding Invoke-Expression.
.OUTPUTS
    [PSCustomObject] containing ToolName, ScriptUrl, Launched, ExitCode.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$ScriptUrl = 'https://debloat.yashg.dev/install.ps1'
    )

    process {
        # 1. Pre-Flight Internet Connectivity Check
        $online = Test-InternetConnectivity
        if (-not $online) {
            throw "Pre-flight check failed: Internet connectivity is required to download and execute Browser Debloat."
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
            'debloat.yashg.dev'
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
        if (-not $PSCmdlet.ShouldProcess("BrowserDebloat ($ScriptUrl)", "Download and execute external browser debloat utility")) {
            return [PSCustomObject]@{
                ToolName  = 'BrowserDebloat'
                ScriptUrl = $ScriptUrl
                Launched  = $false
                ExitCode  = $null
            }
        }

        # 5. Mandatory User Confirmation Prompt
        $confirmed = $false
        if (Get-Command -Name 'Show-ToolkitConfirmation' -ErrorAction SilentlyContinue) {
            $confirmed = Show-ToolkitConfirmation -Prompt "Browser Debloat will execute external code from $ScriptUrl. Proceed?" -Default $false
        } else {
            try {
                if ($Host -and $Host.UI -and $Host.UI.PromptForChoice) {
                    $caption = "Security Confirmation Required"
                    $message = "Browser Debloat will download and execute external code from $ScriptUrl. Do you want to proceed?"
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
                Write-ToolkitLog -Message "Browser Debloat launch cancelled by user." -Level 'WARN' -Component 'Invoke-BrowserDebloat'
            }
            return [PSCustomObject]@{
                ToolName  = 'BrowserDebloat'
                ScriptUrl = $ScriptUrl
                Launched  = $false
                ExitCode  = $null
            }
        }

        # 6. Secure Temporary File Staging & AST Syntax Pre-Validation
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Downloading and validating Browser Debloat from $ScriptUrl..." -Level 'INFO' -Component 'Invoke-BrowserDebloat'
        }

        $tempScript = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("IToolkit_BrowserDebloat_" + [System.Guid]::NewGuid().ToString('N') + ".ps1")
        try {
            $rawContent = $null
            $webResp = Invoke-WebRequest -Uri $ScriptUrl -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            if ($webResp -is [string]) {
                $rawContent = $webResp
            } elseif ($null -ne $webResp.PSObject.Properties['Content']) {
                $rawContent = [string]$webResp.Content
            } else {
                $rawContent = [string]$webResp
            }

            if ([string]::IsNullOrWhiteSpace($rawContent)) {
                throw "Downloaded payload from '$ScriptUrl' is empty."
            }

            # Safety check: reject HTML landing pages
            if ($rawContent -match '(?i)^\s*<!DOCTYPE\s+html' -or $rawContent -match '(?i)^\s*<html') {
                throw "Remote endpoint returned HTML content instead of an executable script."
            }

            # AST syntax pre-validation (must have 0 parse errors)
            $tokens = $null
            $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseInput($rawContent, [ref]$tokens, [ref]$parseErrors)
            if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
                throw "Remote script failed AST syntax validation ($($parseErrors.Count) syntax error(s))."
            }

            [System.IO.File]::WriteAllText($tempScript, $rawContent, [System.Text.Encoding]::UTF8)

            $processArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`""
            $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $processArgs -Wait -PassThru -ErrorAction Stop

            $exitCode = 0
            if ($null -ne $proc -and $proc.PSObject.Properties['ExitCode'] -and $null -ne $proc.ExitCode) {
                $exitCode = $proc.ExitCode
            }

            return [PSCustomObject]@{
                ToolName  = 'BrowserDebloat'
                ScriptUrl = $ScriptUrl
                Launched  = $true
                ExitCode  = $exitCode
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempScript) {
                Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
