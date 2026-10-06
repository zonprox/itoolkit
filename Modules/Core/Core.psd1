@{
    # Module Identity & Loader
    RootModule             = 'Core.psm1'
    ModuleVersion          = '1.0.0'
    GUID                   = 'e83a9d72-4c28-49fb-bf12-7489a29d61c3'
    Author                 = 'IToolkit Team'
    CompanyName            = 'Enterprise IT Administration'
    Copyright              = '(c) 2026 IToolkit. All rights reserved.'
    Description            = 'Core foundational services: pre-flight checks, elevation, process management, reversible registry engine, structured logging, and summaries.'

    # PowerShell Engine Compatibility
    PowerShellVersion      = '5.1'
    CompatiblePSEditions   = @('Desktop', 'Core')

    # Explicit Whitelist of Public Functions (Strictly hides Private helpers)
    FunctionsToExport      = @(
        'Test-IsAdmin',
        'Assert-IsAdmin',
        'Start-ToolkitSelfElevation',
        'Test-ProcessRunning',
        'Stop-ToolkitProcess',
        'Test-DiskSpaceAvailable',
        'Export-RegistryKeyBackup',
        'Restore-RegistryKeyBackup',
        'Set-ToolkitRegistryValue',
        'Write-ToolkitLog',
        'Format-ToolkitSummary',
        'Show-ToolkitConfirmation'
    )

    CmdletsToExport        = @()
    VariablesToExport      = @()
    AliasesToExport        = @()

    PrivateData            = @{
        PSData = @{
            Tags = @('IToolkit', 'Core', 'Logging', 'Registry', 'Process', 'Elevation')
        }
    }
}
