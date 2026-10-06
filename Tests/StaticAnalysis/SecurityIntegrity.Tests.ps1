# ==============================================================================
# SecurityIntegrity.Tests.ps1
# Static security and credential integrity analysis for IToolkit.
# Enforces zero hardcoded secrets, no Invoke-Expression, SecureString password typing,
# and safe parameter handling across all codebase scripts.
# ==============================================================================

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

BeforeAll {
    function Test-CodeSecurityPatterns {
        param([string]$CodeContent)

        $findings = [System.Collections.Generic.List[PSCustomObject]]::new()

        # 1. Hardcoded plaintext passwords (e.g. $password = 'Secret123')
        $pwdRegex = '(?i)\$(?:pass(?:word)?|secret|token|api_?key)\s*=\s*["''][^"'']{3,}["'']'
        if ($CodeContent -match $pwdRegex) {
            $findings.Add([PSCustomObject]@{
                Rule    = 'ZeroHardcodedSecrets'
                Message = 'Hardcoded password, secret, or API token detected in source code.'
            })
        }

        # 2. Predictable / default password patterns
        $predictableRegex = '(?i)(?:P@ssw0rd|Password123|Admin(?:istrator)?123|Welcome123|Ad#\$|Default#)'
        if ($CodeContent -match $predictableRegex) {
            $findings.Add([PSCustomObject]@{
                Rule    = 'NoPredictablePasswords'
                Message = 'Predictable or default password pattern detected.'
            })
        }

        # 3. Invoke-Expression (iex) usage
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($CodeContent, [ref]$tokens, [ref]$errors)
        $iexNodes = $ast.FindAll({
            param($node)
            if ($node -is [System.Management.Automation.Language.CommandAst]) {
                $name = $node.GetCommandName()
                return ($name -eq 'Invoke-Expression' -or $name -eq 'iex')
            }
            return $false
        }, $true)

        foreach ($iex in $iexNodes) {
            $findings.Add([PSCustomObject]@{
                Rule    = 'NoInvokeExpression'
                Message = "Unsafe Invoke-Expression / iex command detected at line $($iex.Extent.StartLineNumber)."
            })
        }

        # 4. Plaintext password parameters (e.g. [string]$Password instead of [SecureString]$Password)
        $paramNodes = $ast.FindAll({
            param($node)
            if ($node -is [System.Management.Automation.Language.ParameterAst]) {
                $paramName = $node.Name.VariablePath.UserPath
                if ($paramName -match '(?i)^password$') {
                    $typeName = $node.StaticType.Name
                    # Allow SecureString or PSCredential
                    if ($typeName -ne 'SecureString' -and $typeName -ne 'PSCredential' -and $typeName -ne 'Object') {
                        return $true
                    }
                }
            }
            return $false
        }, $true)

        foreach ($p in $paramNodes) {
            $findings.Add([PSCustomObject]@{
                Rule    = 'SecureStringPasswordEnforcement'
                Message = "Parameter '$($p.Name.VariablePath.UserPath)' must be typed as [SecureString] or [PSCredential], not plaintext string."
            })
        }

        return $findings
    }
}

Describe 'StaticAnalysis: Security & Credential Integrity' {

    Context 'Security Rule Engine Verification' {
        It 'Correctly flags hardcoded plaintext secrets' {
            $badCode = '$password = "SuperSecret123!"'
            $findings = Test-CodeSecurityPatterns -CodeContent $badCode
            $findings.Count | Should -BeGreaterThan 0
            $findings.Rule | Should -Contain 'ZeroHardcodedSecrets'
        }

        It 'Correctly flags predictable default passwords' {
            $badCode = '$defaultPass = "Admin123"'
            $findings = Test-CodeSecurityPatterns -CodeContent $badCode
            $findings.Count | Should -BeGreaterThan 0
            $findings.Rule | Should -Contain 'NoPredictablePasswords'
        }

        It 'Correctly flags Invoke-Expression and iex alias' {
            $badCode = 'Invoke-Expression $remoteCommand; iex $userScript'
            $findings = Test-CodeSecurityPatterns -CodeContent $badCode
            $findings.Count | Should -BeGreaterThan 0
            $findings.Rule | Should -Contain 'NoInvokeExpression'
        }

        It 'Correctly flags plaintext string password parameter' {
            $badCode = @'
function Set-ToolkitAccount {
    param([string]$Username, [string]$Password)
}
'@
            $findings = Test-CodeSecurityPatterns -CodeContent $badCode
            $findings.Count | Should -BeGreaterThan 0
            $findings.Rule | Should -Contain 'SecureStringPasswordEnforcement'
        }

        It 'Passes secure code using SecureString and safe cmdlets' {
            $secureCode = @'
function New-ToolkitUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Username,

        [Parameter(Mandatory = $true)]
        [System.Security.SecureString]$Password
    )
    Write-ToolkitLog -Message "Creating user $Username" -Level "Info"
}
'@
            $findings = Test-CodeSecurityPatterns -CodeContent $secureCode
            $findings.Count | Should -Be 0
        }
    }

    Context 'Repository Codebase Security Audit' {
        $sourceFiles = Get-ChildItem -Path $ProjectRoot -Recurse -File | Where-Object {
            ($_.Extension -eq '.ps1' -or $_.Extension -eq '.psm1') -and
            $_.FullName -notmatch '[\\/]\.agents[\\/]' -and
            $_.FullName -notmatch '[\\/]Tests[\\/]'
        }

        It 'Discovered source files pass security audits' {
            foreach ($file in $sourceFiles) {
                $content = Get-Content -Path $file.FullName -Raw
                $findings = Test-CodeSecurityPatterns -CodeContent $content
                if ($findings.Count -gt 0) {
                    $details = ($findings | ForEach-Object { "$($_.Rule): $($_.Message)" }) -join '; '
                    Write-Error "Security issue in $($file.Name): $details"
                }
                $findings.Count | Should -Be 0
            }
            $true | Should -BeTrue
        }
    }
}
