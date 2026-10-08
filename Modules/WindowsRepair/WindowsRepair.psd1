@{
    # Module Identity & Loader
    RootModule             = 'WindowsRepair.psm1'
    ModuleVersion          = '1.0.0'
    GUID                   = 'b3f5481a-6532-47d0-9941-a1e68c9e54a8'
    Author                 = 'IToolkit Team'
    CompanyName            = 'Enterprise IT Administration'
    Copyright              = '(c) 2026 IToolkit. All rights reserved.'
    Description            = 'Windows System Repair and Diagnostics Engine: SFC system file integrity scanning, DISM component store repair, Windows Update components reset, network stack reset, and WMI repository repair.'

    # PowerShell Engine Compatibility
    PowerShellVersion      = '5.1'
    CompatiblePSEditions   = @('Desktop', 'Core')

    # Scripts to run in the caller's session state upon import
    ScriptsToProcess       = @(
        'Public/Invoke-WindowsSfcScan.ps1',
        'Public/Invoke-WindowsDismRepair.ps1',
        'Public/Reset-WindowsUpdateComponents.ps1',
        'Public/Reset-NetworkStack.ps1',
        'Public/Repair-WmiRepository.ps1'
    )

    # Explicit Whitelist of Public Functions
    FunctionsToExport      = @(
        'Invoke-WindowsSfcScan',
        'Invoke-WindowsDismRepair',
        'Reset-WindowsUpdateComponents',
        'Reset-NetworkStack',
        'Repair-WmiRepository'
    )

    CmdletsToExport        = @()
    VariablesToExport      = @()
    AliasesToExport        = @()

    PrivateData            = @{
        PSData = @{
            Tags = @('IToolkit', 'WindowsRepair', 'Diagnostics', 'SFC', 'DISM', 'WindowsUpdate', 'Netsh', 'WMI')
        }
    }
}
