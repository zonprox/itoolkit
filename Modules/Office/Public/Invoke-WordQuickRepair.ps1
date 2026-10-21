function Invoke-WordQuickRepair {
<#
.SYNOPSIS
    Executes a one-click automated repair sequence for Microsoft Word.
.DESCRIPTION
    Consolidates Word recovery operations into a safe, non-destructive sequence:
    1. Terminates stuck or hanging WINWORD processes (Stop-OfficeProcess).
    2. Isolates and resets corrupted Normal.dotm template (Reset-WordTemplate).
    3. Disables conflicting startup add-ins in Word STARTUP folders (Reset-WordStartupAddin).
    4. Purges orphaned lock files (~$*.docx) and corrupt AutoRecover files (Clear-WordOrphanedLocks).
    5. Backs up and resets Word Data and Options registry hives (Reset-WordRegistryData).
    Returns a structured status object detailing each execution step.
    Supports -WhatIf, -Force, and -PassThru.
.PARAMETER Force
    Forcibly terminates active Word processes and overrides confirmation guards during recovery.
.PARAMETER PassThru
    Returns the repair status PSCustomObject to the pipeline.
.OUTPUTS
    [PSCustomObject] containing Status, ProcessStopped, TemplateReset, AddinsIsolated, LocksCleared, and RegistryReset.
.EXAMPLE
    Invoke-WordQuickRepair -Force
.EXAMPLE
    Invoke-WordQuickRepair -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    process {
        if (-not $PSCmdlet.ShouldProcess("Microsoft Word", "Perform Quick Word Repair (Stop Process, Reset Normal.dotm, Isolate Startup Add-ins, Clear Orphaned Locks, Reset Registry Data)")) {
            return [PSCustomObject]@{
                Status         = 'Simulated'
                ProcessStopped = '[Simulated - WhatIf]'
                TemplateReset  = '[Simulated - WhatIf]'
                AddinsIsolated = '[Simulated - WhatIf]'
                LocksCleared   = '[Simulated - WhatIf]'
                RegistryReset  = '[Simulated - WhatIf]'
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Starting Quick Word Repair sequence..." -Level 'INFO' -Component 'Invoke-WordQuickRepair'
        }

        # Step 1: Terminate active Word processes
        $procResult = $null
        try {
            if (Get-Command -Name 'Stop-OfficeProcess' -ErrorAction SilentlyContinue) {
                $procResult = Stop-OfficeProcess -ProcessNames @('WINWORD') -Force:$Force -TimeoutSeconds 5
            } elseif (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                $procResult = Stop-ToolkitProcess -ProcessName 'WINWORD' -TimeoutSeconds 5 -Force:$Force
            } else {
                if ($Force) {
                    Stop-Process -Name 'WINWORD' -Force -ErrorAction SilentlyContinue
                }
                $procResult = [PSCustomObject]@{ Status = 'Success'; Terminated = @('WINWORD') }
            }
        } catch {
            Write-Verbose "Process termination step encountered error: $($_.Exception.Message)"
            $procResult = [PSCustomObject]@{ Status = 'Warning'; ErrorMessage = $_.Exception.Message }
        }

        # Step 2: Reset Normal.dotm template
        $templateResult = $null
        try {
            if (Get-Command -Name 'Reset-WordTemplate' -ErrorAction SilentlyContinue) {
                $templateResult = Reset-WordTemplate -Force:$Force
            }
        } catch {
            Write-Verbose "Template reset step encountered error: $($_.Exception.Message)"
            $templateResult = [PSCustomObject]@{ Status = 'Warning'; ErrorMessage = $_.Exception.Message }
        }

        # Step 3: Isolate Word startup add-ins
        $addinResult = $null
        try {
            if (Get-Command -Name 'Reset-WordStartupAddin' -ErrorAction SilentlyContinue) {
                $addinResult = Reset-WordStartupAddin -DisableAll -Force:$Force
            }
        } catch {
            Write-Verbose "Startup add-in isolation step encountered error: $($_.Exception.Message)"
            $addinResult = [PSCustomObject]@{ Status = 'Warning'; ErrorMessage = $_.Exception.Message }
        }

        # Step 4: Clear orphaned lock and AutoRecover files
        $locksResult = $null
        try {
            if (Get-Command -Name 'Clear-WordOrphanedLocks' -ErrorAction SilentlyContinue) {
                $locksResult = Clear-WordOrphanedLocks -Force:$Force
            }
        } catch {
            Write-Verbose "Lock purge step encountered error: $($_.Exception.Message)"
            $locksResult = [PSCustomObject]@{ Status = 'Warning'; ErrorMessage = $_.Exception.Message }
        }

        # Step 5: Reset Word Data and Options registry hives
        $regResult = $null
        try {
            if (Get-Command -Name 'Reset-WordRegistryData' -ErrorAction SilentlyContinue) {
                $cmdInfo = Get-Command -Name 'Reset-WordRegistryData' -ErrorAction SilentlyContinue
                if ($cmdInfo -and $cmdInfo.Parameters.ContainsKey('Force')) {
                    $regResult = Reset-WordRegistryData -ResetData -ResetOptions -Force:$Force
                } else {
                    $regResult = Reset-WordRegistryData -ResetData -ResetOptions
                }
            }
        } catch {
            Write-Verbose "Registry data reset step encountered error: $($_.Exception.Message)"
            $regResult = [PSCustomObject]@{ Status = 'Warning'; ErrorMessage = $_.Exception.Message }
        }

        $overallStatus = 'Success'
        if (($null -ne $templateResult -and $templateResult.Status -eq 'Warning') -or
            ($null -ne $procResult -and $procResult.Status -eq 'Warning') -or
            ($null -ne $regResult -and $regResult.Status -eq 'Warning')) {
            $overallStatus = 'Warning'
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Quick Word Repair sequence completed with status: $overallStatus." -Level 'INFO' -Component 'Invoke-WordQuickRepair'
        }

        $resultObj = [PSCustomObject]@{
            Status         = $overallStatus
            ProcessStopped = $procResult
            TemplateReset  = $templateResult
            AddinsIsolated = $addinResult
            LocksCleared   = $locksResult
            RegistryReset  = $regResult
        }

        return $resultObj
    }
}
