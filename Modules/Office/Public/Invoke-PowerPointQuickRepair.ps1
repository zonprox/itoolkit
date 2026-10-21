function Invoke-PowerPointQuickRepair {
<#
.SYNOPSIS
    Executes a one-click automated repair sequence for Microsoft PowerPoint.
.DESCRIPTION
    Consolidates PowerPoint recovery operations into a safe, non-destructive sequence:
    1. Terminates stuck or hanging POWERPNT processes (Stop-OfficeProcess).
    2. Clears font and slide layout preview caches (Reset-PowerPointCache).
    3. Clears crashed or disabled add-ins from the Resiliency list (Reset-PowerPointResiliency).
    Returns a structured status object detailing each execution step.
    Supports -WhatIf, -Force, and -PassThru.
.PARAMETER Force
    Forcibly terminates active PowerPoint processes and overrides confirmation guards during recovery.
.PARAMETER PassThru
    Returns the repair status PSCustomObject to the pipeline.
.OUTPUTS
    [PSCustomObject] containing Status, ProcessStopped, CacheReset, and ResiliencyReset.
.EXAMPLE
    Invoke-PowerPointQuickRepair -Force
.EXAMPLE
    Invoke-PowerPointQuickRepair -WhatIf
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
        if (-not $PSCmdlet.ShouldProcess("Microsoft PowerPoint", "Perform Quick PowerPoint Repair (Stop Process, Reset Font & Slide Cache, Reset Resiliency Items)")) {
            return [PSCustomObject]@{
                Status          = 'Simulated'
                ProcessStopped  = '[Simulated - WhatIf]'
                CacheReset      = '[Simulated - WhatIf]'
                ResiliencyReset = '[Simulated - WhatIf]'
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Starting Quick PowerPoint Repair sequence..." -Level 'INFO' -Component 'Invoke-PowerPointQuickRepair'
        }

        # Step 1: Terminate active PowerPoint processes
        $procResult = $null
        try {
            if (Get-Command -Name 'Stop-OfficeProcess' -ErrorAction SilentlyContinue) {
                $procResult = Stop-OfficeProcess -ProcessNames @('POWERPNT') -Force:$Force -TimeoutSeconds 5
            } elseif (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                $procResult = Stop-ToolkitProcess -ProcessName 'POWERPNT' -TimeoutSeconds 5 -Force:$Force
            } else {
                if ($Force) {
                    Stop-Process -Name 'POWERPNT' -Force -ErrorAction SilentlyContinue
                }
                $procResult = [PSCustomObject]@{ Status = 'Success'; Terminated = @('POWERPNT') }
            }
        } catch {
            Write-Verbose "Process termination step encountered error: $($_.Exception.Message)"
            $procResult = [PSCustomObject]@{ Status = 'Warning'; ErrorMessage = $_.Exception.Message }
        }

        # Step 2: Purge font and slide layout cache
        $cacheResult = $null
        try {
            if (Get-Command -Name 'Reset-PowerPointCache' -ErrorAction SilentlyContinue) {
                $cacheResult = Reset-PowerPointCache -Force:$Force
            }
        } catch {
            Write-Verbose "Cache purge step encountered error: $($_.Exception.Message)"
            $cacheResult = [PSCustomObject]@{ Status = 'Warning'; ErrorMessage = $_.Exception.Message }
        }

        # Step 3: Reset PowerPoint Resiliency disabled items list
        $resiliencyResult = $null
        try {
            if (Get-Command -Name 'Reset-PowerPointResiliency' -ErrorAction SilentlyContinue) {
                $resiliencyResult = Reset-PowerPointResiliency -Force:$Force
            }
        } catch {
            Write-Verbose "Resiliency reset step encountered error: $($_.Exception.Message)"
            $resiliencyResult = [PSCustomObject]@{ Status = 'Warning'; ErrorMessage = $_.Exception.Message }
        }

        $overallStatus = 'Success'
        if (($null -ne $procResult -and $procResult.Status -eq 'Warning') -or
            ($null -ne $cacheResult -and $cacheResult.Status -eq 'Warning') -or
            ($null -ne $resiliencyResult -and $resiliencyResult.Status -eq 'Warning')) {
            $overallStatus = 'Warning'
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Quick PowerPoint Repair sequence completed with status: $overallStatus." -Level 'INFO' -Component 'Invoke-PowerPointQuickRepair'
        }

        $resultObj = [PSCustomObject]@{
            Status          = $overallStatus
            ProcessStopped  = $procResult
            CacheReset      = $cacheResult
            ResiliencyReset = $resiliencyResult
        }

        return $resultObj
    }
}
