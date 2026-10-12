function Reset-NetworkProxy {
<#
.SYNOPSIS
    Resets WinHTTP system proxy configuration and clears user proxy overrides.
.DESCRIPTION
    Remediates proxy server misconfigurations, stale PAC scripts (AutoConfigURL),
    and "No Internet, Secured" connection stalls by:
    - Resetting system WinHTTP proxy to DIRECT access (netsh winhttp reset proxy).
    - Backing up and clearing user proxy settings in HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings:
      - ProxyEnable = 0
      - ProxyServer = ""
      - AutoConfigURL = ""
      - MigrateProxy = 0
      - ProxyOverride = "<local>"
.PARAMETER BackupDirectory
    Optional directory path where pre-modification .reg backup files will be saved.
.OUTPUTS
    [PSCustomObject] containing Success, WinHttpReset, UserProxyCleared, RegBackupFiles, ErrorMessage.
.EXAMPLE
    Reset-NetworkProxy
.EXAMPLE
    Reset-NetworkProxy -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$BackupDirectory
    )

    process {
        # 1. WhatIf / ShouldProcess support
        if (-not $PSCmdlet.ShouldProcess("Windows Proxy & WinHTTP Subsystem", "Reset WinHTTP proxy to DIRECT and clear user Internet Settings proxy configuration")) {
            return [PSCustomObject]@{
                Success          = $true
                WinHttpReset     = $true
                UserProxyCleared = $true
                RegBackupFiles   = @('[Simulated - WhatIf]')
                ErrorMessage     = ''
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Resetting WinHTTP proxy and clearing user Internet Settings proxy overrides..." -Level 'INFO' -Component 'Network:Proxy'
        }

        $regBackupFiles   = [System.Collections.Generic.List[string]]::new()
        $winHttpReset     = $false
        $userProxyCleared = $false
        $errorMessages    = [System.Collections.Generic.List[string]]::new()

        # Helper to set registry value with backup
        $setReg = {
            param([string]$Key, [string]$Name, [object]$Val, [string]$Type = 'DWord')
            $regParams = @{
                KeyPath      = $Key
                ValueName    = $Name
                Value        = $Val
                PropertyType = $Type
            }
            if (-not [string]::IsNullOrEmpty($BackupDirectory)) {
                $regParams['BackupDirectory'] = $BackupDirectory
            }
            try {
                if (Get-Command -Name 'Set-ToolkitRegistryValue' -ErrorAction SilentlyContinue) {
                    $res = Set-ToolkitRegistryValue @regParams
                    if ($null -ne $res) {
                        if ($res.PSObject.Properties['BackupFile'] -and -not [string]::IsNullOrWhiteSpace($res.BackupFile)) {
                            return [string]$res.BackupFile
                        }
                        elseif ($res.PSObject.Properties['RegBackupFile'] -and -not [string]::IsNullOrWhiteSpace($res.RegBackupFile)) {
                            return [string]$res.RegBackupFile
                        }
                    }
                }
                else {
                    if (-not (Test-Path -LiteralPath $Key)) {
                        $null = New-Item -Path $Key -Force -ErrorAction SilentlyContinue
                    }
                    Set-ItemProperty -LiteralPath $Key -Name $Name -Value $Val -Type $Type -Force -ErrorAction Stop
                }
            }
            catch {
                Write-Verbose "Failed writing registry value $Key\$Name : $($_.Exception.Message)"
            }
            return $null
        }

        # 2. netsh winhttp reset proxy
        $netshExe = 'netsh.exe'
        if ($env:SystemRoot) {
            $candNetsh = Join-Path -Path $env:SystemRoot -ChildPath 'System32\netsh.exe'
            if (Test-Path -LiteralPath $candNetsh) {
                $netshExe = $candNetsh
            }
        }

        try {
            $procProxy = Start-Process -FilePath $netshExe -ArgumentList @('winhttp', 'reset', 'proxy') -Wait -NoNewWindow -PassThru -ErrorAction Stop
            if ($null -ne $procProxy -and ($null -eq $procProxy.ExitCode -or $procProxy.ExitCode -eq 0)) {
                $winHttpReset = $true
            }
            else {
                $errorMessages.Add("netsh winhttp reset proxy returned non-zero exit code")
            }
        }
        catch {
            $errorMessages.Add("Failed executing netsh winhttp reset proxy: $($_.Exception.Message)")
        }

        # 3. Clear HKCU Internet Settings
        try {
            $internetSettingsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

            $b1 = & $setReg $internetSettingsKey 'ProxyEnable' 0 'DWord'
            if (-not [string]::IsNullOrWhiteSpace($b1) -and ($b1 -notin $regBackupFiles)) {
                $regBackupFiles.Add($b1)
            }

            $b2 = & $setReg $internetSettingsKey 'ProxyServer' '' 'String'
            if (-not [string]::IsNullOrWhiteSpace($b2) -and ($b2 -notin $regBackupFiles)) {
                $regBackupFiles.Add($b2)
            }

            $b3 = & $setReg $internetSettingsKey 'AutoConfigURL' '' 'String'
            if (-not [string]::IsNullOrWhiteSpace($b3) -and ($b3 -notin $regBackupFiles)) {
                $regBackupFiles.Add($b3)
            }

            $b4 = & $setReg $internetSettingsKey 'MigrateProxy' 0 'DWord'
            if (-not [string]::IsNullOrWhiteSpace($b4) -and ($b4 -notin $regBackupFiles)) {
                $regBackupFiles.Add($b4)
            }

            $b5 = & $setReg $internetSettingsKey 'ProxyOverride' '<local>' 'String'
            if (-not [string]::IsNullOrWhiteSpace($b5) -and ($b5 -notin $regBackupFiles)) {
                $regBackupFiles.Add($b5)
            }

            $userProxyCleared = $true
        }
        catch {
            $errorMessages.Add("Failed updating HKCU Internet Settings: $($_.Exception.Message)")
        }

        $overallSuccess = ($winHttpReset -or $userProxyCleared)
        $errText = if ($errorMessages.Count -gt 0) { $errorMessages -join '; ' } else { '' }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            $level = if ($overallSuccess) { 'SUCCESS' } else { 'WARN' }
            Write-ToolkitLog -Message "Proxy reset finished (WinHTTP: $winHttpReset, UserProxy: $userProxyCleared, Backups: $($regBackupFiles.Count))" -Level $level -Component 'Network:Proxy'
        }

        return [PSCustomObject]@{
            Success          = [bool]$overallSuccess
            WinHttpReset     = [bool]$winHttpReset
            UserProxyCleared = [bool]$userProxyCleared
            RegBackupFiles   = $regBackupFiles.ToArray()
            ErrorMessage     = [string]$errText
        }
    }
}
