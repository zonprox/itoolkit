@{
    # Module Identity & Loader
    RootModule             = 'ExternalTools.psm1'
    ModuleVersion          = '1.0.0'
    GUID                   = '9b8a7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d'
    Author                 = 'IToolkit Team'
    CompanyName            = 'Enterprise IT Administration'
    Copyright              = '(c) 2026 IToolkit. All rights reserved.'
    Description            = 'External IT scripts and utility launchers with internet reachability pre-flight checks and safety confirmation prompts.'

    # PowerShell Engine Compatibility
    PowerShellVersion      = '5.1'
    CompatiblePSEditions   = @('Desktop', 'Core')

    # Scripts to run in the caller's session state upon import
    ScriptsToProcess       = @(
        'Public/Test-InternetConnectivity.ps1',
        'Public/Invoke-BrowserDebloat.ps1',
        'Public/Invoke-Win11Debloat.ps1'
    )

    # Explicit Whitelist of Public Functions
    FunctionsToExport      = @(
        'Test-InternetConnectivity',
        'Invoke-BrowserDebloat',
        'Invoke-Win11Debloat'
    )

    CmdletsToExport        = @()
    VariablesToExport      = @()
    AliasesToExport        = @()

    PrivateData            = @{
        PSData = @{
            Tags = @('IToolkit', 'ExternalTools', 'BrowserDebloat', 'Win11Debloat', 'Launchers')
        }
    }
}
