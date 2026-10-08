function Set-ToolkitChromeExtensionPolicy {
<#
.SYNOPSIS
    Configures Google Chrome enterprise policy registry to silently force-install extensions.
.DESCRIPTION
    Configures ExtensionInstallForcelist under HKLM and HKCU Google Chrome policies
    to install and activate extensions (such as uBlock Origin Lite) on browser startup
    without requiring manual user intervention.
.PARAMETER ExtensionId
    Chrome Web Store extension ID. Default is 'ddkjiahejlhfcafbddmgiahcphecmpfh' (uBlock Origin Lite).
.PARAMETER UpdateUrl
    Extension update URL. Default is 'https://clients2.google.com/service/update2/crx'.
.OUTPUTS
    [PSCustomObject] containing ExtensionId, Configured, PolicyEntry, RegistryPaths.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ExtensionId = 'ddkjiahejlhfcafbddmgiahcphecmpfh',

        [Parameter(Mandatory = $false)]
        [string]$UpdateUrl = 'https://clients2.google.com/service/update2/crx'
    )

    process {
        if (-not (Get-Command -Name 'Write-AppInstallerLog' -ErrorAction SilentlyContinue)) {
            $privLog = Join-Path (Split-Path -Parent $PSScriptRoot) 'Private/Write-AppInstallerLog.ps1'
            if (Test-Path -LiteralPath $privLog) { . $privLog }
        }

        $policyEntry = "$ExtensionId;$UpdateUrl"
        $policyRoots = @(
            'HKLM:\Software\Policies\Google\Chrome\ExtensionInstallForcelist',
            'HKCU:\Software\Policies\Google\Chrome\ExtensionInstallForcelist'
        )

        Write-AppInstallerLog -Message "Configuring Chrome ExtensionInstallForcelist policy for extension '$ExtensionId'..." -Level 'INFO' -Component 'Set-ToolkitChromeExtensionPolicy'

        $configuredCount = 0
        $appliedPaths = [System.Collections.Generic.List[string]]::new()

        foreach ($keyPath in $policyRoots) {
            if (-not $PSCmdlet.ShouldProcess($keyPath, "Set ExtensionInstallForcelist value '$policyEntry'")) {
                Write-AppInstallerLog -Message "ShouldProcess: Skipped setting policy in $keyPath (WhatIf mode)." -Level 'DEBUG' -Component 'Set-ToolkitChromeExtensionPolicy'
                continue
            }

            try {
                if (-not (Test-Path -LiteralPath $keyPath -ErrorAction SilentlyContinue)) {
                    New-Item -Path $keyPath -Force -ErrorAction Stop | Out-Null
                }

                $existing = Get-ItemProperty -Path $keyPath -ErrorAction SilentlyContinue
                $alreadyPresent = $false
                if ($existing) {
                    foreach ($prop in $existing.PSObject.Properties) {
                        if ($prop.Value -eq $policyEntry -or ($prop.Value -is [string] -and $prop.Value.StartsWith($ExtensionId, [System.StringComparison]::OrdinalIgnoreCase))) {
                            $alreadyPresent = $true
                            break
                        }
                    }
                }

                if (-not $alreadyPresent) {
                    # Determine next free numeric value name (1, 2, 3...)
                    $index = 1
                    while ($existing -and ($null -ne $existing."$index")) {
                        $index++
                    }
                    Set-ItemProperty -Path $keyPath -Name "$index" -Value $policyEntry -Force -ErrorAction Stop | Out-Null
                    $configuredCount++
                    $appliedPaths.Add($keyPath)
                    Write-AppInstallerLog -Message "Configured Chrome ExtensionInstallForcelist in $keyPath ($index = $policyEntry)." -Level 'INFO' -Component 'Set-ToolkitChromeExtensionPolicy'
                } else {
                    $configuredCount++
                    $appliedPaths.Add($keyPath)
                    Write-AppInstallerLog -Message "Chrome extension policy already configured in $keyPath." -Level 'DEBUG' -Component 'Set-ToolkitChromeExtensionPolicy'
                }
            } catch {
                Write-AppInstallerLog -Message "Failed to configure Chrome extension policy in ${keyPath}: $($_.Exception.Message)" -Level 'WARN' -Component 'Set-ToolkitChromeExtensionPolicy'
            }
        }

        $isSuccess = ($configuredCount -gt 0)
        if ($isSuccess) {
            Write-AppInstallerLog -Message "Chrome extension deployment policy configuration complete." -Level 'SUCCESS' -Component 'Set-ToolkitChromeExtensionPolicy'
        } else {
            Write-AppInstallerLog -Message "Chrome extension policy could not be verified in target registry keys." -Level 'WARN' -Component 'Set-ToolkitChromeExtensionPolicy'
        }

        return [PSCustomObject]@{
            ExtensionId   = $ExtensionId
            Configured    = $isSuccess
            PolicyEntry   = $policyEntry
            RegistryPaths = $appliedPaths.ToArray()
        }
    }
}

if (Get-Command -Name 'Set-ToolkitChromeExtensionPolicy' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Set-ToolkitChromeExtensionPolicy' -Value (Get-Command -Name 'Set-ToolkitChromeExtensionPolicy').ScriptBlock
}
