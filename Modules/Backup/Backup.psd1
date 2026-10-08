@{
    # Module Identity & Loader
    RootModule             = 'Backup.psm1'
    ModuleVersion          = '1.0.0'
    GUID                   = 'c4d28e75-9b31-4a5f-8c10-2e4b7a1d90f3'
    Author                 = 'IToolkit Team'
    CompanyName            = 'Enterprise IT Administration'
    Copyright              = '(c) 2026 IToolkit. All rights reserved.'
    Description            = 'User data and profile backup and migration: directory discovery, browser bookmarks, certificate store export/import, Robocopy multithreaded engine, and SHA-256 integrity verification.'

    # PowerShell Engine Compatibility
    PowerShellVersion      = '5.1'
    CompatiblePSEditions   = @('Desktop', 'Core')

    # Scripts to run in the caller's session state upon import
    ScriptsToProcess       = @(
        'Public/Get-UserProfileDirectoryMap.ps1',
        'Public/Export-BrowserBookmarks.ps1',
        'Public/Export-PersonalCertificates.ps1',
        'Public/Export-ToolkitCertificates.ps1',
        'Public/Import-ToolkitCertificates.ps1',
        'Public/Start-ProfileDirectoryBackup.ps1',
        'Public/New-BackupIntegrityManifest.ps1',
        'Public/Test-BackupIntegrityManifest.ps1',
        'Public/Restore-UserProfileData.ps1'
    )

    # Explicit Whitelist of Public Functions
    FunctionsToExport      = @(
        'Get-UserProfileDirectoryMap',
        'Export-BrowserBookmarks',
        'Export-PersonalCertificates',
        'Export-ToolkitCertificates',
        'Import-ToolkitCertificates',
        'Start-ProfileDirectoryBackup',
        'New-BackupIntegrityManifest',
        'Test-BackupIntegrityManifest',
        'Restore-UserProfileData'
    )

    CmdletsToExport        = @()
    VariablesToExport      = @()
    AliasesToExport        = @()

    PrivateData            = @{
        PSData = @{
            Tags = @('IToolkit', 'Backup', 'Restore', 'Migration', 'Robocopy', 'SHA256', 'Certificates', 'Bookmarks')
        }
    }
}
