@{
    # Module Identity & Loader
    RootModule             = 'Network.psm1'
    ModuleVersion          = '1.0.0'
    GUID                   = 'f249654b-f32c-42fe-b34d-68a4ac453c46'
    Author                 = 'IToolkit Team'
    CompanyName            = 'Enterprise IT Administration'
    Copyright              = '(c) 2026 IToolkit. All rights reserved.'
    Description            = 'Windows 10/11 Network Diagnostics, Stack Repair, and Remediation Module'

    # PowerShell Engine Compatibility
    PowerShellVersion      = '5.1'
    CompatiblePSEditions   = @('Desktop', 'Core')

    # Scripts to run in the caller's session state upon import
    ScriptsToProcess       = @(
        'Public/Test-NetworkPrinterConnectivity.ps1',
        'Public/Get-NetworkAdapterStatus.ps1',
        'Public/Set-NetworkSmbConfiguration.ps1',
        'Public/Reset-NetworkDns.ps1',
        'Public/Reset-NetworkDhcp.ps1',
        'Public/Reset-NetworkArp.ps1',
        'Public/Reset-NetworkWinsock.ps1',
        'Public/Reset-NetworkTcpIp.ps1',
        'Public/Reset-NetworkLocationAwareness.ps1',
        'Public/Reset-NetworkProxy.ps1',
        'Public/Restart-ToolkitNetworkAdapter.ps1',
        'Public/Set-NetworkRemediation.ps1'
    )

    # Explicit Whitelist of Public Functions
    FunctionsToExport      = @(
        'Test-NetworkPrinterConnectivity',
        'Get-NetworkAdapterStatus',
        'Set-NetworkSmbConfiguration',
        'Reset-NetworkDns',
        'Reset-NetworkDhcp',
        'Reset-NetworkArp',
        'Reset-NetworkWinsock',
        'Reset-NetworkTcpIp',
        'Reset-NetworkLocationAwareness',
        'Reset-NetworkProxy',
        'Restart-ToolkitNetworkAdapter',
        'Set-NetworkRemediation'
    )

    CmdletsToExport        = @()
    VariablesToExport      = @()
    AliasesToExport        = @()

    PrivateData            = @{
        PSData = @{
            Tags = @('IToolkit', 'Network', 'Diagnostics', 'TcpIp', 'DNS', 'Winsock', 'DHCP', 'Remediation')
        }
    }
}
