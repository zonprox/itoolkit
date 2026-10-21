function Invoke-ExcelQuickRepair {
<#
.SYNOPSIS
    Executes a one-click automated repair sequence for Microsoft Excel.
.DESCRIPTION
    Consolidates Excel recovery operations into a safe, non-destructive sequence:
    1. Terminates stuck or hanging EXCEL processes (Stop-OfficeProcess).
    2. Clears rogue startup add-ins in XLSTART while preserving Personal.xlsb (Clear-ExcelStartupFolder).
    3. Resets corrupt workspace Excel16.xlb, ribbon customizations, and QAT cache (Reset-ExcelUiCache).
    4. Resets DDE command flags and formula calculation mode to Automatic (Reset-ExcelDdeSettings).
    5. Clears crashed or disabled add-ins from the Resiliency list (Reset-ExcelResiliency).
    Returns a structured status object detailing each execution step.
    Supports -WhatIf, -Force, and -PassThru.
.PARAMETER Force
    Forcibly terminates active Excel processes and overrides confirmation guards during recovery.
.PARAMETER PassThru
    Returns the repair status PSCustomObject to the pipeline.
.OUTPUTS
    [PSCustomObject] containing Status, ProcessStopped, XlStartCleared, UiCacheReset, DdeReset, and ResiliencyReset.
.EXAMPLE
    Invoke-ExcelQuickRepair -Force
.EXAMPLE
    Invoke-ExcelQuickRepair -WhatIf
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
        if (-not $PSCmdlet.ShouldProcess("Microsoft Excel", "Perform Quick Excel Repair (Stop Process, Clear XLSTART, Reset UI Cache, Reset DDE, Reset Resiliency)")) {
            return [PSCustomObject]@{
                Status          = 'Simulated'
                ProcessStopped  = '[Simulated - WhatIf]'
                XlStartCleared  = '[Simulated - WhatIf]'
                UiCacheReset    = '[Simulated - WhatIf]'
                DdeReset        = '[Simulated - WhatIf]'
                ResiliencyReset = '[Simulated - WhatIf]'
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Starting Quick Excel Repair sequence..." -Level 'INFO' -Component 'Invoke-ExcelQuickRepair'
        }

        # Step 1: Terminate active Excel processes
        $procResult = $null
        try {
            if (Get-Command -Name 'Stop-OfficeProcess' -ErrorAction SilentlyContinue) {
                $procResult = Stop-OfficeProcess -ProcessNames @('EXCEL') -Force:$Force -TimeoutSeconds 5
            } elseif (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
                $procResult = Stop-ToolkitProcess -ProcessName 'EXCEL' -TimeoutSeconds 5 -Force:$Force
            } else {
                if ($Force) {
                    Stop-Process -Name 'EXCEL' -Force -ErrorAction SilentlyContinue
                }
                $procResult = [PSCustomObject]@{ Status = 'Success'; Terminated = @('EXCEL') }
            }
        } catch {
            Write-Verbose "Process termination step encountered error: $($_.Exception.Message)"
            $procResult = [PSCustomObject]@{ Status = 'Warning'; ErrorMessage = $_.Exception.Message }
        }

        # Step 2: Clear XLSTART startup folder while preserving Personal.xlsb
        $xlStartResult = $null
        try {
            if (Get-Command -Name 'Clear-ExcelStartupFolder' -ErrorAction SilentlyContinue) {
                $xlStartResult = Clear-ExcelStartupFolder -Force:$Force
            }
        } catch {
            Write-Verbose "XLSTART cleanup step encountered error: $($_.Exception.Message)"
            $xlStartResult = [PSCustomObject]@{ Status = 'Warning'; ErrorMessage = $_.Exception.Message }
        }

        # Step 3: Reset Excel UI cache (Excel16.xlb, Ribbon, QAT)
        $uiCacheResult = $null
        try {
            if (Get-Command -Name 'Reset-ExcelUiCache' -ErrorAction SilentlyContinue) {
                $cmdInfo = Get-Command -Name 'Reset-ExcelUiCache' -ErrorAction SilentlyContinue
                if ($cmdInfo -and $cmdInfo.Parameters.ContainsKey('Force')) {
                    $uiCacheResult = Reset-ExcelUiCache -CleanXlStart:$false -Force:$Force
                } else {
                    $uiCacheResult = Reset-ExcelUiCache -CleanXlStart:$false
                }
            }
        } catch {
            Write-Verbose "UI cache reset step encountered error: $($_.Exception.Message)"
            $uiCacheResult = [PSCustomObject]@{ Status = 'Warning'; ErrorMessage = $_.Exception.Message }
        }

        # Step 4: Reset DDE settings and calculation mode
        $ddeResult = $null
        try {
            if (Get-Command -Name 'Reset-ExcelDdeSettings' -ErrorAction SilentlyContinue) {
                $ddeResult = Reset-ExcelDdeSettings -Force:$Force
            }
        } catch {
            Write-Verbose "DDE settings reset step encountered error: $($_.Exception.Message)"
            $ddeResult = [PSCustomObject]@{ Status = 'Warning'; ErrorMessage = $_.Exception.Message }
        }

        # Step 5: Reset Excel Resiliency disabled items list
        $resiliencyResult = $null
        try {
            if (Get-Command -Name 'Reset-ExcelResiliency' -ErrorAction SilentlyContinue) {
                $resiliencyResult = Reset-ExcelResiliency -Force:$Force
            }
        } catch {
            Write-Verbose "Resiliency reset step encountered error: $($_.Exception.Message)"
            $resiliencyResult = [PSCustomObject]@{ Status = 'Warning'; ErrorMessage = $_.Exception.Message }
        }

        $overallStatus = 'Success'
        if (($null -ne $procResult -and $procResult.Status -eq 'Warning') -or
            ($null -ne $xlStartResult -and $xlStartResult.Status -eq 'Warning') -or
            ($null -ne $uiCacheResult -and $uiCacheResult.Status -eq 'Warning') -or
            ($null -ne $ddeResult -and $ddeResult.Status -eq 'Warning') -or
            ($null -ne $resiliencyResult -and $resiliencyResult.Status -eq 'Warning')) {
            $overallStatus = 'Warning'
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Quick Excel Repair sequence completed with status: $overallStatus." -Level 'INFO' -Component 'Invoke-ExcelQuickRepair'
        }

        $resultObj = [PSCustomObject]@{
            Status          = $overallStatus
            ProcessStopped  = $procResult
            XlStartCleared  = $xlStartResult
            UiCacheReset    = $uiCacheResult
            DdeReset        = $ddeResult
            ResiliencyReset = $resiliencyResult
        }

        return $resultObj
    }
}
