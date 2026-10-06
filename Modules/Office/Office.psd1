@{
    # Module Identity & Loader
    RootModule             = 'Office.psm1'
    ModuleVersion          = '1.0.0'
    GUID                   = '8c2f1e49-9d37-4a65-b108-5d7e3a9c40f2'
    Author                 = 'IToolkit Team'
    CompanyName            = 'Enterprise IT Administration'
    Copyright              = '(c) 2026 IToolkit. All rights reserved.'
    Description            = 'Office and Excel troubleshooting: hardware acceleration toggles, UI cache reset (Excel16.xlb), temporary cache purge, COM add-in management, GDI handle leak remediation, and ClickToRun repair.'

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
        'Public/Start-OfficeClickToRunRepair.ps1'
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
        'Start-OfficeClickToRunRepair'
    )

    CmdletsToExport        = @()
    VariablesToExport      = @()
    AliasesToExport        = @()

    PrivateData            = @{
        PSData = @{
            Tags = @('IToolkit', 'Office', 'Excel', 'ClickToRun', 'GDI', 'COMAddins')
        }
    }
}
