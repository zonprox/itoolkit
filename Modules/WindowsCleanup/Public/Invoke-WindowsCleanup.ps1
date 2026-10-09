<#
.SYNOPSIS
    Master coordinator executing safe, deep Windows 10/11 system disk cleanup.
.DESCRIPTION
    Orchestrates cleanup across temporary files, error reporting / system logs, Delivery
    Optimization cache, Windows Update download cache, and DISM Component Store (WinSxS).
    Aggregates reclaimed disk space, item counts, and skipped files across all selected subsystems.
    Fully supports dry-run space analysis (-WhatIf) and strict non-destructive safety invariants.
.PARAMETER Category
    Array of categories to process: 'All', 'TempCache', 'UpdateCache', 'DeliveryOptimization',
    'SystemLogs', 'ComponentStore'. Default is 'All'.
.PARAMETER All
    Switch parameter to run all safe cleanup categories.
.PARAMETER IncludeTempCache
    Runs temporary file cleanup (%TEMP%, System Temp).
.PARAMETER IncludeUpdateCache
    Runs Windows Update download cache cleanup.
.PARAMETER IncludeDeliveryOptimization
    Runs Delivery Optimization cache cleanup.
.PARAMETER IncludeSystemLogs
    Runs error reports, crash dumps, and archived servicing logs cleanup.
.PARAMETER IncludeComponentStore
    Runs DISM Component Store cleanup.
.PARAMETER ResetBase
    When specified, passes /ResetBase to Invoke-WindowsComponentCleanup.
    Note: -All does NOT enable -ResetBase automatically; must be explicitly specified.
.PARAMETER TempAgeHours
    Minimum age in hours for temporary files (default: 24).
.OUTPUTS
    [PSCustomObject] Containing Target, Path, ReclaimedBytes, TotalReclaimedBytes, ItemCount,
    TotalItemsCleaned, SkippedCount, TotalSkipped, Status, Success, ErrorMessage, Summary, Results.
#>
function Invoke-WindowsCleanup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('All', 'ComponentStore', 'UpdateCache', 'DeliveryOptimization', 'SystemLogs', 'TempCache')]
        [string[]]$Category = @('All'),

        [Parameter(Mandatory = $false)]
        [switch]$All,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeTempCache,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeUpdateCache,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeDeliveryOptimization,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeSystemLogs,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeComponentStore,

        [Parameter(Mandatory = $false)]
        [switch]$ResetBase,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 720)]
        [int]$TempAgeHours = 24
    )

    process {
        # 1. Resolve Target Categories
        $runAll = $All -or ($Category -contains 'All')
        $runTemp = $runAll -or $IncludeTempCache -or ($Category -contains 'TempCache')
        $runLogs = $runAll -or $IncludeSystemLogs -or ($Category -contains 'SystemLogs')
        $runDO   = $runAll -or $IncludeDeliveryOptimization -or ($Category -contains 'DeliveryOptimization')
        $runWU   = $runAll -or $IncludeUpdateCache -or ($Category -contains 'UpdateCache')
        $runComp = $runAll -or $IncludeComponentStore -or ($Category -contains 'ComponentStore')

        $selectedCategories = [System.Collections.Generic.List[string]]::new()
        if ($runTemp) { $selectedCategories.Add('TempCache') }
        if ($runLogs) { $selectedCategories.Add('SystemLogs') }
        if ($runDO)   { $selectedCategories.Add('DeliveryOptimization') }
        if ($runWU)   { $selectedCategories.Add('UpdateCache') }
        if ($runComp) { $selectedCategories.Add('ComponentStore') }

        $categoriesDisplay = ($selectedCategories -join ', ')

        # 2. WhatIf Check
        $isWhatIf = [bool]$PSBoundParameters.ContainsKey('WhatIf')
        if (-not $isWhatIf -and $PSCmdlet -and $PSCmdlet.MyInvocation -and $PSCmdlet.MyInvocation.BoundParameters) {
            $isWhatIf = [bool]$PSCmdlet.MyInvocation.BoundParameters.ContainsKey('WhatIf')
        }

        if (-not $PSCmdlet.ShouldProcess("Windows System ($categoriesDisplay)", "Execute system cleanup operations")) {
            $isWhatIf = $true
        }

        # 3. Execution Pipeline
        $resultsList = [System.Collections.Generic.List[PSCustomObject]]::new()

        # Step 1: Temporary Files
        if ($runTemp) {
            Write-Verbose "Processing Temporary Files cleanup..."
            $tempRes = if ($isWhatIf) {
                Clear-WindowsTempCache -AgeHours $TempAgeHours -WhatIf
            }
            else {
                Clear-WindowsTempCache -AgeHours $TempAgeHours
            }
            $resultsList.Add($tempRes)
        }

        # Step 2: System Logs & Crash Dumps
        if ($runLogs) {
            Write-Verbose "Processing System Logs and Crash Dumps cleanup..."
            $logsRes = if ($isWhatIf) {
                Clear-WindowsSystemLogs -WhatIf
            }
            else {
                Clear-WindowsSystemLogs
            }
            $resultsList.Add($logsRes)
        }

        # Step 3: Delivery Optimization Cache
        if ($runDO) {
            Write-Verbose "Processing Delivery Optimization Cache cleanup..."
            $doRes = if ($isWhatIf) {
                Clear-WindowsDeliveryOptimizationCache -WhatIf
            }
            else {
                Clear-WindowsDeliveryOptimizationCache
            }
            $resultsList.Add($doRes)
        }

        # Step 4: Windows Update Download Cache
        if ($runWU) {
            Write-Verbose "Processing Windows Update Cache cleanup..."
            $wuRes = if ($isWhatIf) {
                Clear-WindowsUpdateCache -WhatIf
            }
            else {
                Clear-WindowsUpdateCache
            }
            $resultsList.Add($wuRes)
        }

        # Step 5: DISM Component Store
        if ($runComp) {
            Write-Verbose "Processing DISM Component Store cleanup (ResetBase: $ResetBase)..."
            $compRes = if ($isWhatIf) {
                Invoke-WindowsComponentCleanup -ResetBase:$ResetBase -WhatIf
            }
            else {
                Invoke-WindowsComponentCleanup -ResetBase:$ResetBase
            }
            $resultsList.Add($compRes)
        }

        # 4. Aggregate Metrics
        $totalReclaimed = [int64]0
        $totalItems = 0
        $totalSkipped = 0
        $allSuccess = $true

        foreach ($r in $resultsList) {
            if ($null -ne $r) {
                if ($r.ReclaimedBytes) { $totalReclaimed += [int64]$r.ReclaimedBytes }
                if ($r.ItemCount)      { $totalItems += [int]$r.ItemCount }
                if ($r.SkippedCount)   { $totalSkipped += [int]$r.SkippedCount }
                if (-not $r.Success)   { $allSuccess = $false }
            }
        }

        $overallStatus = if ($isWhatIf) {
            'Simulated - WhatIf'
        }
        elseif ($allSuccess) {
            'Success'
        }
        else {
            'Completed with warnings or failures'
        }

        $resultsArray = @($resultsList)

        return [PSCustomObject]@{
            Target              = 'MasterCleanup'
            Path                = 'All Selected Subsystems'
            ReclaimedBytes      = $totalReclaimed
            TotalReclaimedBytes = $totalReclaimed
            ItemCount           = $totalItems
            TotalItemsCleaned   = $totalItems
            SkippedCount        = $totalSkipped
            TotalSkipped        = $totalSkipped
            Status              = $overallStatus
            Success             = $allSuccess
            ErrorMessage        = $null
            Summary             = $resultsArray
            Results             = $resultsArray
        }
    }
}
