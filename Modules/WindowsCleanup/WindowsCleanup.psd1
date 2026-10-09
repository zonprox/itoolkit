@{
    # Module Identity & Loader
    RootModule             = 'WindowsCleanup.psm1'
    ModuleVersion          = '1.0.0'
    GUID                   = 'c8d9e0f1-2233-4455-6677-8899aabbccdd'
    Author                 = 'IToolkit Team'
    CompanyName            = 'Enterprise IT Administration'
    Copyright              = '(c) 2026 IToolkit. All rights reserved.'
    Description            = 'Enterprise Windows 10/11 system cleanup module: deep, non-destructive disk and cache cleanup covering Component Store (WinSxS via DISM), Windows Update cache, Delivery Optimization cache, error logs and crash dumps, and temporary files.'

    # PowerShell Engine Compatibility
    PowerShellVersion      = '5.1'
    CompatiblePSEditions   = @('Desktop', 'Core')

    # Scripts to run in the caller's session state upon import
    ScriptsToProcess       = @(
        'Private/Format-ByteSize.ps1',
        'Private/Get-DirectorySizeMetrics.ps1',
        'Private/Remove-SafeItem.ps1',
        'Public/Invoke-WindowsComponentCleanup.ps1',
        'Public/Clear-WindowsUpdateCache.ps1',
        'Public/Clear-WindowsDeliveryOptimizationCache.ps1',
        'Public/Clear-WindowsSystemLogs.ps1',
        'Public/Clear-WindowsTempCache.ps1',
        'Public/Invoke-WindowsCleanup.ps1'
    )

    # Explicit Whitelist of Public Functions
    FunctionsToExport      = @(
        'Invoke-WindowsComponentCleanup',
        'Clear-WindowsUpdateCache',
        'Clear-WindowsDeliveryOptimizationCache',
        'Clear-WindowsSystemLogs',
        'Clear-WindowsTempCache',
        'Invoke-WindowsCleanup'
    )

    CmdletsToExport        = @()
    VariablesToExport      = @()
    AliasesToExport        = @()

    PrivateData            = @{
        PSData = @{
            Tags = @('IToolkit', 'WindowsCleanup', 'DiskCleanup', 'WinSxS', 'DISM', 'Temp', 'Logs')
        }
    }
}
