@{
    # Module Identity & Loader
    RootModule             = 'Office.psm1'
    ModuleVersion          = '1.0.0'
    GUID                   = '8c2f1e49-9d37-4a65-b108-5d7e3a9c40f2'
    Author                 = 'IToolkit Team'
    CompanyName            = 'Enterprise IT Administration'
    Copyright              = '(c) 2026 IToolkit. All rights reserved.'
    Description            = 'Office, Word, Excel, and PowerPoint troubleshooting: hardware acceleration toggles, UI and font cache resets, temporary cache purge, COM add-in management, GDI handle leak remediation, template/startup addin isolation, registry data reset, orphaned lock clearance, and ClickToRun repair.'

    # PowerShell Engine Compatibility
    PowerShellVersion      = '5.1'
    CompatiblePSEditions   = @('Desktop', 'Core')

    # Scripts to run in the caller's session state upon import
    ScriptsToProcess       = @(
        'Public/Set-ExcelHardwareAcceleration.ps1',
        'Public/Reset-ExcelUiCache.ps1',
        'Public/Clear-OfficeTempCache.ps1',
        'Public/Get-ExcelComAddin.ps1',
        'Public/Set-ExcelComAddinState.ps1',
        'Public/Reset-ExcelResiliency.ps1',
        'Public/Get-ExcelGdiHandleUsage.ps1',
        'Public/Stop-ExcelGdiLeakers.ps1',
        'Public/Start-OfficeClickToRunRepair.ps1',
        'Public/Reset-WordTemplate.ps1',
        'Public/Reset-WordStartupAddin.ps1',
        'Public/Reset-WordRegistryData.ps1',
        'Public/Clear-WordOrphanedLocks.ps1',
        'Public/Stop-OfficeProcess.ps1',
        'Public/Repair-OfficeClickToRunService.ps1',
        'Public/Reset-OfficeIdentityCache.ps1',
        'Public/Clear-ExcelStartupFolder.ps1',
        'Public/Reset-ExcelDdeSettings.ps1',
        'Public/Set-PowerPointHardwareAcceleration.ps1',
        'Public/Reset-PowerPointCache.ps1',
        'Public/Reset-PowerPointResiliency.ps1',
        'Public/Uninstall-OfficeSuiteCleanly.ps1',
        'Public/Set-OfficeHardwareAcceleration.ps1',
        'Public/Invoke-WordQuickRepair.ps1',
        'Public/Invoke-ExcelQuickRepair.ps1',
        'Public/Invoke-PowerPointQuickRepair.ps1'
    )

    # Explicit Whitelist of Public Functions (Strictly hides Private helpers)
    FunctionsToExport      = @(
        'Set-ExcelHardwareAcceleration',
        'Reset-ExcelUiCache',
        'Clear-OfficeTempCache',
        'Get-ExcelComAddin',
        'Set-ExcelComAddinState',
        'Reset-ExcelResiliency',
        'Get-ExcelGdiHandleUsage',
        'Stop-ExcelGdiLeakers',
        'Start-OfficeClickToRunRepair',
        'Reset-WordTemplate',
        'Reset-WordStartupAddin',
        'Reset-WordRegistryData',
        'Clear-WordOrphanedLocks',
        'Stop-OfficeProcess',
        'Repair-OfficeClickToRunService',
        'Reset-OfficeIdentityCache',
        'Clear-ExcelStartupFolder',
        'Reset-ExcelDdeSettings',
        'Set-PowerPointHardwareAcceleration',
        'Reset-PowerPointCache',
        'Reset-PowerPointResiliency',
        'Uninstall-OfficeSuiteCleanly',
        'Set-OfficeHardwareAcceleration',
        'Invoke-WordQuickRepair',
        'Invoke-ExcelQuickRepair',
        'Invoke-PowerPointQuickRepair'
    )

    CmdletsToExport        = @()
    VariablesToExport      = @()
    AliasesToExport        = @()

    PrivateData            = @{
        PSData = @{
            Tags = @('IToolkit', 'Office', 'Word', 'Excel', 'PowerPoint', 'ClickToRun', 'GDI', 'COMAddins')
        }
    }
}
