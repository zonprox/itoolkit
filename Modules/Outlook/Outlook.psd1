@{
    # Module Identity & Loader
    RootModule             = 'Outlook.psm1'
    ModuleVersion          = '1.0.0'
    GUID                   = '3a7d2b84-4e19-4f81-9b23-7e4f1a8c90d5'
    Author                 = 'IToolkit Team'
    CompanyName            = 'Enterprise IT Administration'
    Copyright              = '(c) 2026 IToolkit. All rights reserved.'
    Description            = 'Outlook and PST data management: discovery, safe relocation with SHA-256 verification, profile re-mapping, threshold expansion, compaction guidance, and backup/restore.'

    # PowerShell Engine Compatibility
    PowerShellVersion      = '5.1'
    CompatiblePSEditions   = @('Desktop', 'Core')

    # Scripts to run in the caller's session state upon import
    ScriptsToProcess       = @(
        'Public/Find-OutlookDataFiles.ps1',
        'Public/Move-OutlookDataFile.ps1',
        'Public/Update-OutlookProfilePath.ps1',
        'Public/Set-OutlookPstThreshold.ps1',
        'Public/Invoke-OutlookCompaction.ps1',
        'Public/Backup-OutlookPst.ps1',
        'Public/Restore-OutlookPst.ps1',
        'Public/Get-OutlookSystemContext.ps1',
        'Public/Get-OutlookPstThreshold.ps1',
        'Public/Test-OutlookDataFileLock.ps1'
    )

    # Explicit Whitelist of Public Functions (Strictly hides Private helpers)
    FunctionsToExport      = @(
        'Find-OutlookDataFiles',
        'Move-OutlookDataFile',
        'Update-OutlookProfilePath',
        'Set-OutlookPstThreshold',
        'Invoke-OutlookCompaction',
        'Backup-OutlookPst',
        'Restore-OutlookPst',
        'Get-OutlookSystemContext',
        'Get-OutlookPstThreshold',
        'Test-OutlookDataFileLock'
    )

    CmdletsToExport        = @()
    VariablesToExport      = @()
    AliasesToExport        = @()

    PrivateData            = @{
        PSData = @{
            Tags = @('IToolkit', 'Outlook', 'PST', 'OST', 'MAPI', 'EmailMigration')
        }
    }
}
