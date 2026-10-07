@{
    # Module Identity & Loader
    RootModule             = 'IToolkit.psm1'
    ModuleVersion          = '1.0.0'
    GUID                   = 'd2e61a4f-7b19-4b68-9189-e1e3bca019d1'
    Author                 = 'IToolkit Team'
    CompanyName            = 'Enterprise IT Administration'
    Copyright              = '(c) 2026 IToolkit. All rights reserved.'
    Description            = 'Modular, lightweight PowerShell IT Support & Administration Toolkit for Windows 10 and Windows 11.'

    # PowerShell Engine Compatibility
    PowerShellVersion      = '5.1'
    CompatiblePSEditions   = @('Desktop', 'Core')

    # Nested Modules (Loaded automatically in order)
    NestedModules          = @(
        'Modules/Core/Core.psd1',
        'Modules/TUI/TUI.psd1',
        'Modules/Outlook/Outlook.psd1',
        'Modules/Office/Office.psd1',
        'Modules/Printers/Printers.psd1',
        'Modules/Backup/Backup.psd1',
        'Modules/Accounts/Accounts.psd1',
        'Modules/ExternalTools/ExternalTools.psd1'
    )

    # Public Cmdlets & Functions Exported by IToolkit
    FunctionsToExport      = @(
        # Core Services: Pre-Flight & Elevation
        'Test-IsAdmin',
        'Assert-IsAdmin',
        'Start-ToolkitSelfElevation',

        # Core Services: Process Management
        'Test-ProcessRunning',
        'Stop-ToolkitProcess',

        # Core Services: Resource Verification
        'Test-DiskSpaceAvailable',

        # Core Services: Registry Safety Engine
        'Export-RegistryKeyBackup',
        'Restore-RegistryKeyBackup',
        'Set-ToolkitRegistryValue',

        # Core Services: Logging & Console Output
        'Write-ToolkitLog',
        'Format-ToolkitSummary',
        'Show-ToolkitConfirmation',

        # Outlook & PST/OST Management Services
        'Find-OutlookDataFiles',
        'Move-OutlookDataFile',
        'Update-OutlookProfilePath',
        'Set-OutlookPstThreshold',
        'Invoke-OutlookCompaction',
        'Backup-OutlookPst',
        'Restore-OutlookPst',
        'Get-OutlookSystemContext',
        'Get-OutlookPstThreshold',
        'Test-OutlookDataFileLock',

        # Office & Excel Troubleshooting Services
        'Set-ExcelHardwareAcceleration',
        'Reset-ExcelUiCache',
        'Clear-OfficeTempCache',
        'Get-ExcelComAddin',
        'Set-ExcelComAddinState',
        'Reset-ExcelResiliency',
        'Get-ExcelGdiHandleUsage',
        'Stop-ExcelGdiLeakers',
        'Start-OfficeClickToRunRepair',

        # Printers Troubleshooting Services
        'Get-PrintSpoolerStatus',
        'Reset-PrintSpoolerQueue',
        'Register-PrintSpoolerComponents',
        'Reset-PrinterNePortBindings',
        'Test-PointAndPrintPolicy',
        'Set-PointAndPrintRemediation',
        'Test-NetworkPrinterConnectivity',
        'Reset-PrinterConnections',

        # User Data & Profile Backup Services
        'Get-UserProfileDirectoryMap',
        'Export-BrowserBookmarks',
        'Export-PersonalCertificates',
        'Start-ProfileDirectoryBackup',
        'New-BackupIntegrityManifest',
        'Test-BackupIntegrityManifest',
        'Restore-UserProfileData',

        # Accounts & Domain Administration Services
        'Get-LocalAccountList',
        'New-LocalAccountItem',
        'Unlock-LocalAccountItem',
        'Set-LocalAccountState',
        'Get-DomainAccountItem',
        'Unlock-DomainAccountItem',
        'Set-DomainAccountState',
        'Enable-BuiltInAdministrator',
        'Reset-BuiltInAdministratorPassword',
        'Test-DomainReachability',
        'Join-ToolkitDomain',
        'Disconnect-ToolkitDomain',

        # External Tools & Quick Launchers
        'Test-InternetConnectivity',
        'Invoke-Win11Debloat',
        'Invoke-ChrisTitusWinUtil',

        # Interactive Console TUI Menu Services
        'Get-ToolkitLayoutWidth',
        'Write-ToolkitMenuDivider',
        'Show-ToolkitHeader',
        'Show-ToolkitMenuOption',
        'Read-ToolkitMenuChoice',
        'Write-ToolkitStatus',
        'Start-IToolkitMenu',
        'Get-ToolkitTelemetryData',
        'Get-MainSystemInfoLines'
    )

    CmdletsToExport        = @()
    VariablesToExport      = @()
    AliasesToExport        = @()

    # Private Metadata
    PrivateData            = @{
        PSData = @{
            Tags        = @('ITSupport', 'Windows10', 'Windows11', 'AdminToolkit', 'Diagnostics', 'Troubleshooting')
            ProjectUri  = 'https://github.com/itoolkit/itoolkit'
            LicenseUri  = 'https://github.com/itoolkit/itoolkit/blob/main/LICENSE'
        }
    }
}
