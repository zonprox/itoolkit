function Reset-OfficeIdentityCache {
<#
.SYNOPSIS
    Resets corrupted Office Modern Authentication (WAM), OneAuth, and Identity caches.
.DESCRIPTION
    Backs up and resets HKCU:\Software\Microsoft\Office\16.0\Common\Identity hives.
    Purges local IdentityCache, OneAuth, and optional WAM broker plugin token caches.
    Resolves Office sign-in loops, Error 1001, and persistent credential prompts.
.PARAMETER PurgeWamTokens
    Purges the AAD BrokerPlugin WAM TokenBroker accounts cache.
.PARAMETER Force
    Terminates active Office processes prior to identity cache reset.
.OUTPUTS
    [PSCustomObject]@{ Status = 'Success'; RegBackup = <string>; CachesCleared = <string[]> }
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$PurgeWamTokens,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        if (-not $PSCmdlet.ShouldProcess("Office Identity Subsystem", "Reset Modern Auth caches and identity registry hives")) {
            return [PSCustomObject]@{
                Status        = 'Success'
                RegBackup     = '[Simulated - WhatIf]'
                CachesCleared = @('[Simulated - WhatIf]')
            }
        }

        # Process termination pre-flight
        if (Get-Command -Name 'Stop-OfficeProcess' -ErrorAction SilentlyContinue) {
            $null = Stop-OfficeProcess -Force:$Force
        } elseif (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
            $procs = @('OUTLOOK', 'WINWORD', 'EXCEL', 'POWERPNT', 'ONENOTE')
            foreach ($p in $procs) {
                $null = Stop-ToolkitProcess -ProcessName $p -TimeoutSeconds 5 -Force:$Force
            }
        }

        # Step 1: Pre-modification Registry Backup
        $regKey = 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity'
        $regBackup = $null
        if (Get-Command -Name 'Export-RegistryKeyBackup' -ErrorAction SilentlyContinue) {
            $regBackup = Export-RegistryKeyBackup -KeyPath $regKey
        }

        # Step 2: Reset Identities and Profiles Subkeys
        $subkeys = @("$regKey\Identities", "$regKey\Profiles")
        foreach ($sk in $subkeys) {
            if (Test-Path -LiteralPath $sk) {
                try {
                    Remove-Item -LiteralPath $sk -Recurse -Force -ErrorAction SilentlyContinue
                    if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                        Write-ToolkitLog -Message "Cleared identity registry hive '$sk'." -Level 'INFO' -Component 'Reset-OfficeIdentityCache'
                    }
                } catch { $null = $_ }
            }
        }

        # Step 3: Purge Filesystem Caches
        $localApp = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'AppData\Local' } else { $null }
        $clearedCaches = [System.Collections.Generic.List[string]]::new()

        if ($localApp) {
            $cacheTargets = [System.Collections.Generic.List[string]]::new()
            $cacheTargets.Add((Join-Path $localApp 'Microsoft\IdentityCache'))
            $cacheTargets.Add((Join-Path $localApp 'Microsoft\OneAuth'))

            if ($PurgeWamTokens) {
                $cacheTargets.Add((Join-Path $localApp 'Packages\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy\AC\TokenBroker\Accounts'))
            }

            foreach ($target in $cacheTargets) {
                if (Test-Path -LiteralPath $target) {
                    try {
                        $items = @(Get-ChildItem -LiteralPath $target -Recurse -ErrorAction SilentlyContinue)
                        foreach ($item in $items) {
                            try {
                                Remove-Item -LiteralPath $item.FullName -Force -Recurse -ErrorAction SilentlyContinue
                            } catch { $null = $_ }
                        }
                        $clearedCaches.Add($target)
                        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                            Write-ToolkitLog -Message "Purged identity cache directory: '$target'" -Level 'INFO' -Component 'Reset-OfficeIdentityCache'
                        }
                    } catch {
                        Write-Verbose "Could not clear cache '$target': $($_.Exception.Message)"
                    }
                }
            }
        }

        return [PSCustomObject]@{
            Status        = 'Success'
            RegBackup     = $regBackup
            CachesCleared = @($clearedCaches)
        }
    }
}
