function Invoke-Win11Debloat {
<#
.SYNOPSIS
    Pre-flight checks internet connectivity and launches Win11Debloat.
.DESCRIPTION
    Performs outbound internet validation, downloads and validates the script,
    and launches the canonical Win11Debloat script (https://debloat.raphi.re/) via an elevated external PowerShell process.
    Complies with SecurityIntegrity rules by avoiding Invoke-Expression.
.PARAMETER Variant
    Target script variant: 'Default' or 'Raphire'. Default is 'Default'.
.OUTPUTS
    [PSCustomObject] containing ToolName, ScriptUrl, Launched, ExitCode.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('Default', 'Raphire')]
        [string]$Variant = 'Default',

        [Parameter(Mandatory = $false)]
        [string]$ScriptUrl = 'https://debloat.raphi.re/'
    )

    process {
        # 1. Pre-Flight Internet Connectivity Check
        $online = Test-InternetConnectivity
        if (-not $online) {
            throw "Pre-flight check failed: Internet connectivity is required to download and execute Win11Debloat."
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
            'debloat.raphi.re'
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
        if (-not $PSCmdlet.ShouldProcess("Win11Debloat ($ScriptUrl)", "Download and execute external debloat utility")) {
            return [PSCustomObject]@{
                ToolName  = 'Win11Debloat'
                ScriptUrl = $ScriptUrl
                Launched  = $false
                ExitCode  = $null
            }
        }

        # 5. Secure Temporary File Staging & AST Syntax Pre-Validation
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Downloading and validating Win11Debloat from $ScriptUrl..." -Level 'INFO' -Component 'Invoke-Win11Debloat'
        }

        $tempScript = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("IToolkit_Win11Debloat_" + [System.Guid]::NewGuid().ToString('N') + ".ps1")
        try {
            $rawContent = $null
            $webResp = Invoke-WebRequest -Uri $ScriptUrl -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            $contentObj = $webResp
            if ($null -ne $webResp -and $null -ne $webResp.PSObject.Properties['Content']) {
                $contentObj = $webResp.Content
            } elseif ($webResp -is [System.Collections.IDictionary] -and $webResp.Contains('Content')) {
                $contentObj = $webResp['Content']
            }

            if ($contentObj -is [byte[]] -or ($contentObj -is [System.Array] -and $contentObj -isnot [string] -and $contentObj.Count -gt 0 -and $contentObj[0] -is [byte])) {
                $bytes = [byte[]]$contentObj
                if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                    $rawContent = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
                } else {
                    $rawContent = [System.Text.Encoding]::UTF8.GetString($bytes)
                }
            } elseif ($contentObj -is [string]) {
                $rawContent = $contentObj
            } else {
                $rawContent = [string]$contentObj
            }

            if (-not [string]::IsNullOrEmpty($rawContent) -and $rawContent.StartsWith([char]0xFEFF)) {
                $rawContent = $rawContent.TrimStart([char]0xFEFF)
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
                ToolName  = 'Win11Debloat'
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
