@{
    # Module Identity & Loader
    RootModule             = 'Accounts.psm1'
    ModuleVersion          = '1.0.0'
    GUID                   = '3a7b8c9d-1234-4567-89ab-cdef01234567'
    Author                 = 'IToolkit Team'
    CompanyName            = 'Enterprise IT Administration'
    Copyright              = '(c) 2026 IToolkit. All rights reserved.'
    Description            = 'User & Domain Account Administration: Local/Domain account CRUD, ADSI unlock, Zero-RSAT AD management, Built-in Admin activation, and CIM domain join/disjoin.'

    # PowerShell Engine Compatibility
    PowerShellVersion      = '5.1'
    CompatiblePSEditions   = @('Desktop', 'Core')

    # Scripts to run in the caller's session state upon import
    ScriptsToProcess       = @(
        'Public/Get-LocalAccountList.ps1',
        'Public/New-LocalAccountItem.ps1',
        'Public/Unlock-LocalAccountItem.ps1',
        'Public/Set-LocalAccountState.ps1',
        'Public/Get-DomainAccountItem.ps1',
        'Public/Unlock-DomainAccountItem.ps1',
        'Public/Set-DomainAccountState.ps1',
        'Public/Enable-BuiltInAdministrator.ps1',
        'Public/Reset-BuiltInAdministratorPassword.ps1',
        'Public/Test-DomainReachability.ps1',
        'Public/Join-ToolkitDomain.ps1',
        'Public/Disconnect-ToolkitDomain.ps1'
    )

    # Explicit Whitelist of Public Cmdlets
    FunctionsToExport      = @(
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
        'Disconnect-ToolkitDomain'
    )

    CmdletsToExport        = @()
    VariablesToExport      = @()
    AliasesToExport        = @()

    PrivateData            = @{
        PSData = @{
            Tags = @('IToolkit', 'Accounts', 'LocalUser', 'Domain', 'ActiveDirectory', 'ADSI', 'LockoutPrevention')
        }
    }
}
