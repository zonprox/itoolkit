@{
    # Module Identity & Loader
    RootModule             = 'TUI.psm1'
    ModuleVersion          = '1.0.0'
    GUID                   = 'c7f20815-62d4-42b7-a359-4d6cb7f938a1'
    Author                 = 'IToolkit Team'
    CompanyName            = 'Enterprise IT Administration'
    Copyright              = '(c) 2026 IToolkit. All rights reserved.'
    Description            = 'Terminal User Interface (TUI) interactive console menu system, headers, colored status indicators, and category navigation.'

    # PowerShell Engine Compatibility
    PowerShellVersion      = '5.1'
    CompatiblePSEditions   = @('Desktop', 'Core')

    # Scripts to run in the caller's session state upon import
    ScriptsToProcess       = @(
        'Public/Get-ToolkitLayoutWidth.ps1',
        'Public/Show-ToolkitHeader.ps1',
        'Public/Show-ToolkitMenuOption.ps1',
        'Public/Show-ToolkitActionCatalog.ps1',
        'Public/Show-ToolkitDetailPanel.ps1',
        'Public/Show-ToolkitStatusPanel.ps1',
        'Public/Show-ToolkitItemTable.ps1',
        'Public/Read-ToolkitMenuChoice.ps1',
        'Public/Read-ToolkitItemSelection.ps1',
        'Public/Write-ToolkitStatus.ps1',
        'Public/Start-IToolkitMenu.ps1',
        'Public/Invoke-ToolkitSubmenuSystemHealth.ps1',
        'Public/Invoke-ToolkitSubmenuOfficeSuite.ps1',
        'Public/Invoke-ToolkitSubmenuOfficeCommon.ps1',
        'Public/Invoke-ToolkitSubmenuOfficeWord.ps1',
        'Public/Invoke-ToolkitSubmenuOfficeExcel.ps1',
        'Public/Invoke-ToolkitSubmenuOfficePowerPoint.ps1',
        'Public/Invoke-ToolkitSubmenuOfficeOutlook.ps1',
        'Public/Invoke-ToolkitSubmenuConnectivity.ps1',
        'Public/Invoke-ToolkitSubmenuIdentityBackup.ps1',
        'Public/Invoke-ToolkitSubmenuSoftwareOptimization.ps1'
    )

    # Explicit Whitelist of Public Functions
    FunctionsToExport      = @(
        'Get-ToolkitLayoutWidth',
        'Write-ToolkitMenuDivider',
        'Show-ToolkitHeader',
        'Show-ToolkitMenuOption',
        'Show-ToolkitActionCatalog',
        'Show-ToolkitDetailPanel',
        'Show-ToolkitStatusPanel',
        'Show-ToolkitItemTable',
        'Read-ToolkitMenuChoice',
        'Read-ToolkitItemSelection',
        'Write-ToolkitStatus',
        'Start-IToolkitMenu',
        'Get-ToolkitTelemetryData',
        'Clear-ToolkitTelemetryCache',
        'Get-MainSystemInfoLines',
        'Get-SystemHealthContextInfoLines',
        'Invoke-ToolkitSubmenuSystemHealth',
        'Get-OfficeSuiteContextInfoLines',
        'Invoke-ToolkitSubmenuOfficeSuite',
        'Invoke-ToolkitSubmenuOfficeCommon',
        'Invoke-ToolkitSubmenuOfficeWord',
        'Invoke-ToolkitSubmenuOfficeExcel',
        'Invoke-ToolkitSubmenuOfficePowerPoint',
        'Invoke-ToolkitSubmenuOfficeOutlook',
        'Get-ConnectivityContextInfoLines',
        'Invoke-ToolkitSubmenuConnectivity',
        'Get-IdentityBackupContextInfoLines',
        'Invoke-ToolkitSubmenuIdentityBackup',
        'Get-SoftwareOptimizationContextInfoLines',
        'Invoke-ToolkitSubmenuSoftwareOptimization',
        'Get-WindowsRepairContextInfoLines',
        'Invoke-ToolkitSubmenuWindowsRepair',
        'Get-AppInstallerContextInfoLines',
        'Invoke-ToolkitSubmenuAppInstaller',
        'Get-WindowsCleanupContextInfoLines',
        'Invoke-ToolkitSubmenuWindowsCleanup',
        'Get-NetworkContextInfoLines',
        'Invoke-ToolkitSubmenuNetwork',
        'Get-AccountsContextInfoLines',
        'Invoke-ToolkitSubmenuAccounts',
        'Get-BackupContextInfoLines',
        'Invoke-ToolkitSubmenuBackup',
        'Get-ExternalToolsContextInfoLines',
        'Invoke-ToolkitSubmenuExternalTools',
        'Get-OfficeContextInfoLines',
        'Invoke-ToolkitSubmenuOffice',
        'Get-OutlookContextInfoLines',
        'Invoke-ToolkitSubmenuOutlook',
        'Get-PrintersContextInfoLines',
        'Invoke-ToolkitSubmenuPrinters'
    )

    CmdletsToExport        = @()
    VariablesToExport      = @()
    AliasesToExport        = @()

    PrivateData            = @{
        PSData = @{
            Tags = @('IToolkit', 'TUI', 'Menu', 'Console', 'Interactive', 'CLI')
        }
    }
}
