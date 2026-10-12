@{
    # Module Identity & Loader
    RootModule             = 'Printers.psm1'
    ModuleVersion          = '1.0.0'
    GUID                   = '4f8e2a1b-6c3d-4e5f-9a0b-1c2d3e4f5a6b'
    Author                 = 'IToolkit Team'
    CompanyName            = 'Enterprise IT Administration'
    Copyright              = '(c) 2026 IToolkit. All rights reserved.'
    Description            = 'Print Spooler diagnostics, queue purge, component re-registration, NeXX port binding resets, and Point and Print policy remediation.'

    # PowerShell Engine Compatibility
    PowerShellVersion      = '5.1'
    CompatiblePSEditions   = @('Desktop', 'Core')

    # Scripts to run in the caller's session state upon import
    ScriptsToProcess       = @(
        'Public/Get-PrintSpoolerStatus.ps1',
        'Public/Reset-PrintSpoolerQueue.ps1',
        'Public/Register-PrintSpoolerComponents.ps1',
        'Public/Reset-PrinterNePortBindings.ps1',
        'Public/Test-PointAndPrintPolicy.ps1',
        'Public/Set-PointAndPrintRemediation.ps1',
        'Public/Reset-PrinterConnections.ps1',
        'Public/Set-PrinterServerRemediation.ps1',
        'Public/Set-PrinterClientRemediation.ps1',
        'Public/Set-PrinterRemediation.ps1'
    )

    # Explicit Whitelist of Public Functions
    FunctionsToExport      = @(
        'Get-PrintSpoolerStatus',
        'Reset-PrintSpoolerQueue',
        'Register-PrintSpoolerComponents',
        'Reset-PrinterNePortBindings',
        'Test-PointAndPrintPolicy',
        'Set-PointAndPrintRemediation',
        'Reset-PrinterConnections',
        'Set-PrinterServerRemediation',
        'Set-PrinterClientRemediation',
        'Set-PrinterRemediation'
    )

    CmdletsToExport        = @()
    VariablesToExport      = @()
    AliasesToExport        = @()

    PrivateData            = @{
        PSData = @{
            Tags = @('IToolkit', 'Printers', 'PrintSpooler', 'PrintNightmare')
        }
    }
}
