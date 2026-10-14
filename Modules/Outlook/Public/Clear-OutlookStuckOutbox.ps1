function Clear-OutlookStuckOutbox {
<#
.SYNOPSIS
    Discovers and clears stuck outgoing email messages from the Outlook Outbox.
.DESCRIPTION
    Safely purges stuck messages from the Outbox folder using Outlook COM automation
    and validates queue registry parameters. Requires Outlook to be closed (or stopped
    via -Force) to release MAPI spooler locks.
.PARAMETER ProfileName
    Target Outlook profile name. Defaults to active or default profile.
.PARAMETER Force
    Forcefully terminates running OUTLOOK.EXE processes to release message locks.
.OUTPUTS
    [PSCustomObject]@{ Status, ClearedMessages, ProfileName, Method, ErrorMessage }
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$ProfileName,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        # 1. Resolve Target Profile
        $targetProfile = $ProfileName
        if ([string]::IsNullOrWhiteSpace($targetProfile)) {
            if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
                try {
                    $ctx = Get-OutlookSystemContext
                    if ($null -ne $ctx -and -not [string]::IsNullOrWhiteSpace($ctx.DefaultProfile) -and $ctx.DefaultProfile -ne 'None') {
                        $targetProfile = $ctx.DefaultProfile
                    }
                } catch { $null = $_ }
            }
        }
        if ([string]::IsNullOrWhiteSpace($targetProfile)) { $targetProfile = 'Outlook' }

        # 2. Process Check & Force Handling
        $isRunning = [bool](Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
        if ($isRunning) {
            if ($Force) {
                if (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                    $null = Stop-ToolkitProcess -ProcessName 'OUTLOOK' -TimeoutSeconds 5 -Force
                } else {
                    Stop-Process -Name 'OUTLOOK' -Force -ErrorAction SilentlyContinue
                }
                Start-Sleep -Milliseconds 500
            } else {
                $warnMsg = "Outlook is currently running and holding Outbox message locks. Close Outlook or specify -Force."
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message $warnMsg -Level 'WARN' -Component 'Outlook:Outbox'
                }
                return [PSCustomObject]@{
                    Status          = 'Warning'
                    ClearedMessages = 0
                    ProfileName     = $targetProfile
                    Method          = 'None'
                    ErrorMessage    = $warnMsg
                }
            }
        }

        # 3. SupportsShouldProcess Check
        if (-not $PSCmdlet.ShouldProcess("Outbox ($targetProfile)", "Clear stuck outgoing messages")) {
            return [PSCustomObject]@{
                Status          = 'Success'
                ClearedMessages = 0
                ProfileName     = $targetProfile
                Method          = 'WhatIf'
                ErrorMessage    = $null
            }
        }

        # 4. COM Outbox Clearing
        $comApp = $null
        $ns = $null
        $outbox = $null
        $clearedCount = 0
        $method = 'COM'
        $err = $null

        try {
            if (Get-Command -Name 'Get-OutlookComApplication' -ErrorAction SilentlyContinue) {
                $comApp = Get-OutlookComApplication
            } else {
                $outlookMod = Get-Module -Name 'Outlook'
                if ($null -ne $outlookMod) {
                    $comApp = & $outlookMod { Get-OutlookComApplication }
                } else {
                    $privCom = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Private/Get-OutlookComApplication.ps1'
                    if (Test-Path -LiteralPath $privCom) {
                        . $privCom
                        $comApp = Get-OutlookComApplication
                    }
                }
            }

            if ($null -ne $comApp) {
                $ns = $comApp.GetNamespace('MAPI')
                if ($null -ne $ns) {
                    try {
                        $ns.Logon($targetProfile, $null, $false, $false)
                    } catch { $null = $_ }

                    # 4 = olFolderOutbox
                    $outbox = $ns.GetDefaultFolder(4)
                    if ($null -ne $outbox -and $null -ne $outbox.Items) {
                        $itemCount = $outbox.Items.Count
                        for ($i = $itemCount; $i -ge 1; $i--) {
                            try {
                                $item = $null
                                if ($outbox.Items -is [Array] -or $outbox.Items -is [System.Collections.IList]) {
                                    $item = $outbox.Items[$i - 1]
                                } else {
                                    try {
                                        $item = $outbox.Items.Item($i)
                                    } catch {
                                        $item = $outbox.Items[$i - 1]
                                    }
                                }
                                if ($null -ne $item) {
                                    $item.Delete()
                                    $clearedCount++
                                }
                            } catch {
                                Write-Verbose "Failed to delete outbox item index ($i): $($_.Exception.Message)"
                            }
                        }
                    }
                }
            } else {
                $method = 'OfflineNotice'
            }
        }
        catch {
            $err = $_.Exception.Message
            Write-Verbose "COM Outbox cleanup encountered error: $err"
        }
        finally {
            if ($null -ne $comApp) {
                try { $comApp.Quit() } catch { $null = $_ }
            }
            $comObjs = @($outbox, $ns, $comApp)
            if (Get-Command -Name 'Remove-ToolkitComObject' -ErrorAction SilentlyContinue) {
                Remove-ToolkitComObject -ComObjects $comObjs
            }
        }

        # 5. Registry Send-Immediate Flag Verification
        $mailOptKey = 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Options\Mail'
        if (Test-Path -LiteralPath $mailOptKey) {
            try {
                if (Get-Command -Name 'Set-ToolkitRegistryValue' -ErrorAction SilentlyContinue) {
                    $null = Set-ToolkitRegistryValue -KeyPath $mailOptKey -ValueName 'Send Mail Immediately' -Value 1 -PropertyType 'DWord'
                }
            } catch { $null = $_ }
        }

        $status = if ($null -eq $err) { 'Success' } else { 'Warning' }
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Cleared $clearedCount stuck message(s) in profile '$targetProfile'." -Level 'INFO' -Component 'Outlook:Outbox'
        }

        return [PSCustomObject]@{
            Status          = $status
            ClearedMessages = $clearedCount
            ProfileName     = $targetProfile
            Method          = $method
            ErrorMessage    = $err
        }
    }
}
