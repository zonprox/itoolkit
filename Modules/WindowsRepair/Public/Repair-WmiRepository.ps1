function Repair-WmiRepository {
<#
.SYNOPSIS
    Verifies, salvages, or resets the Windows Management Instrumentation (WMI) repository.
.DESCRIPTION
    Runs winmgmt.exe with /verifyrepository, /salvagerepository, or /resetrepository.
    Checks for administrative elevation and returns structured operational status.
.PARAMETER Action
    The WMI repository action to execute. Valid values are Verify, Salvage, and Reset.
    Defaults to Salvage.
.OUTPUTS
    [PSCustomObject] containing Action, ExitCode, Status, and Success.
.EXAMPLE
    Repair-WmiRepository
.EXAMPLE
    Repair-WmiRepository -Action Verify
.EXAMPLE
    Repair-WmiRepository -Action Reset
.EXAMPLE
    Repair-WmiRepository -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('Verify', 'Salvage', 'Reset')]
        [string]$Action = 'Salvage'
    )

    process {
        # 1. Admin elevation check
        $isAdmin = $true
        if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
            $isAdmin = [bool](Test-IsAdmin)
        }
        if (-not $isAdmin) {
            Write-Warning "Administrative privileges are recommended or required for WMI repository operations ($Action). Current session is not elevated."
        }

        # 2. Map action to CLI flag
        $flag = switch ($Action) {
            'Verify'  { '/verifyrepository' }
            'Salvage' { '/salvagerepository' }
            'Reset'   { '/resetrepository' }
        }

        # 3. Support ShouldProcess / WhatIf
        if (-not $PSCmdlet.ShouldProcess("WMI Repository", "Execute winmgmt.exe $flag")) {
            return [PSCustomObject]@{
                Action   = $Action
                ExitCode = 0
                Status   = 'Simulated - WhatIf'
                Success  = $true
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Executing WMI repository operation: winmgmt.exe $flag" -Level 'INFO' -Component 'WindowsRepair:WMI'
        }

        # 4. Locate winmgmt.exe
        $winmgmtExe = 'winmgmt.exe'
        if ($env:SystemRoot) {
            $candidate = Join-Path -Path $env:SystemRoot -ChildPath 'System32\wbem\winmgmt.exe'
            if (Test-Path -LiteralPath $candidate) {
                $winmgmtExe = $candidate
            }
        }

        $exitCode = 0
        $status = ''

        # 5. Execute process
        try {
            $proc = Start-Process -FilePath $winmgmtExe -ArgumentList @($flag) -Wait -NoNewWindow -PassThru -ErrorAction Stop
            if ($null -ne $proc -and $null -ne $proc.ExitCode) {
                $exitCode = $proc.ExitCode
            }
            if ($exitCode -eq 0) {
                $status = "WMI repository $Action operation completed successfully."
            } else {
                $status = "WMI repository $Action operation completed with exit code $exitCode."
            }
        }
        catch {
            Write-Warning "WMI process execution notice: $($_.Exception.Message)"
            $exitCode = 1
            $status = "Execution error: $($_.Exception.Message)"
        }

        $success = ($exitCode -eq 0)

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            $logLevel = if ($success) { 'SUCCESS' } else { 'WARN' }
            Write-ToolkitLog -Message "WMI repository $Action finished with exit code $exitCode ($status)" -Level $logLevel -Component 'WindowsRepair:WMI'
        }

        return [PSCustomObject]@{
            Action   = $Action
            ExitCode = $exitCode
            Status   = $status
            Success  = $success
        }
    }
}
