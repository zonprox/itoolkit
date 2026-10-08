@{
    # Module Identity & Loader
    RootModule             = 'AppInstaller.psm1'
    ModuleVersion          = '1.0.0'
    GUID                   = '3f8d1e2c-4b5a-6c7d-8e9f-0a1b2c3d4e5f'
    Author                 = 'IToolkit Team'
    CompanyName            = 'Enterprise IT Administration'
    Copyright              = '(c) 2026 IToolkit. All rights reserved.'
    Description            = 'Automated application installer, desktop shortcut generator, and default application association manager.'

    # PowerShell Engine Compatibility
    PowerShellVersion      = '5.1'
    CompatiblePSEditions   = @('Desktop', 'Core')

    # Scripts to run in the caller's session state upon import
    ScriptsToProcess       = @(
        'Public/Get-ToolkitInstalledApplication.ps1',
        'Public/New-ToolkitDesktopShortcut.ps1',
        'Public/Set-ToolkitDefaultApplication.ps1',
        'Public/Install-ToolkitApplication.ps1'
    )

    # Explicit Whitelist of Public Functions
    FunctionsToExport      = @(
        'Get-ToolkitInstalledApplication',
        'New-ToolkitDesktopShortcut',
        'Set-ToolkitDefaultApplication',
        'Install-ToolkitApplication'
    )

    CmdletsToExport        = @()
    VariablesToExport      = @()
    AliasesToExport        = @()

    PrivateData            = @{
        PSData = @{
            Tags = @('IToolkit', 'AppInstaller', 'SoftwareDeployment', 'Shortcuts', 'DefaultApps')
        }
    }
}
