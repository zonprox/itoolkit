function Copy-OutlookFolderHierarchy {
<#
.SYNOPSIS
    Recursively clones custom folder structures from a source Outlook store to a target store.
.DESCRIPTION
    Enumerates custom subfolders under Inbox and custom user root folders in a source Outlook store
    and recreates the matching folder hierarchy in the target store. Skips standard built-in system
    folders to prevent duplicate default folders. Returns a FolderMap mapping relative folder paths
    to the target COM folder objects for rule action remapping. Supports -WhatIf and COM cleanup.
.PARAMETER SourceStorePath
    File path of the source data file/store. If omitted, defaults to the default delivery store.
.PARAMETER TargetStorePath
    File path of the target PST data file/store.
.PARAMETER ProfileName
    Target Outlook profile name. Defaults to active or default profile.
.PARAMETER IncludeRootFolders
    Switch to include custom top-level root folders outside Inbox.
.PARAMETER Force
    Switch to overwrite or merge folders without prompting.
.OUTPUTS
    [PSCustomObject]@{ SourcePath, TargetPath, FoldersCloned, FolderMap, Success, ErrorMessage }
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$SourceStorePath,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetStorePath,

        [Parameter(Mandatory = $false)]
        [string]$ProfileName,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeRootFolders,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    process {
        # 1. Path Normalization
        $resolvedTargetPath = [System.Environment]::ExpandEnvironmentVariables($TargetStorePath.Trim())
        if (-not ($resolvedTargetPath -match '^[a-zA-Z]:[/\\]' -and [System.IO.Path]::DirectorySeparatorChar -ne [char]92)) {
            try {
                $resolvedTargetPath = [System.IO.Path]::GetFullPath($resolvedTargetPath)
            } catch { $null = $_ }
        }

        $resolvedSourcePath = $null
        if (-not [string]::IsNullOrWhiteSpace($SourceStorePath)) {
            $resolvedSourcePath = [System.Environment]::ExpandEnvironmentVariables($SourceStorePath.Trim())
            if (-not ($resolvedSourcePath -match '^[a-zA-Z]:[/\\]' -and [System.IO.Path]::DirectorySeparatorChar -ne [char]92)) {
                try {
                    $resolvedSourcePath = [System.IO.Path]::GetFullPath($resolvedSourcePath)
                } catch { $null = $_ }
            }
        }

        # 2. SupportsShouldProcess Check
        if (-not $PSCmdlet.ShouldProcess($resolvedTargetPath, "Clone custom folder hierarchy from source store to target store")) {
            return [PSCustomObject]@{
                SourcePath    = $resolvedSourcePath
                TargetPath    = $resolvedTargetPath
                FoldersCloned = 0
                FolderMap     = @{}
                Method        = 'WhatIf'
                Success       = $true
                ErrorMessage  = $null
            }
        }

        # 3. COM Automation Setup
        $outlookRunningBefore = [bool](Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
        $comApp = $null
        $ns = $null
        $stores = $null
        $sourceStore = $null
        $targetStore = $null
        $sourceRoot = $null
        $targetRoot = $null
        $script:folderMap = @{}
        $script:foldersClonedCount = 0
        $success = $false
        $errorMessage = $null

        try {
            if (Get-Command -Name 'Get-OutlookComApplication' -ErrorAction SilentlyContinue) {
                $comApp = Get-OutlookComApplication
            }
            else {
                $outlookMod = Get-Module -Name 'Outlook'
                if ($null -ne $outlookMod) {
                    $comApp = & $outlookMod { Get-OutlookComApplication }
                }
                else {
                    $privCom = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Private/Get-OutlookComApplication.ps1'
                    if (Test-Path -LiteralPath $privCom) {
                        . $privCom
                        $comApp = Get-OutlookComApplication
                    }
                }
            }

            if ($null -eq $comApp) {
                throw "Outlook COM application is unavailable."
            }

            $ns = $comApp.GetNamespace('MAPI')
            if ($null -eq $ns) {
                throw "Failed to obtain MAPI namespace from Outlook COM."
            }

            # Locate stores
            if ($ns.PSObject.Properties['Stores']) {
                $stores = $ns.Stores
            }

            if ($null -ne $stores) {
                foreach ($s in $stores) {
                    $sp = if ($s.FilePath) { [string]$s.FilePath } else { '' }
                    if (-not [string]::IsNullOrWhiteSpace($sp)) {
                        if ($sp -ieq $resolvedTargetPath -or $sp -ieq $TargetStorePath) {
                            $targetStore = $s
                        }
                        if (-not [string]::IsNullOrWhiteSpace($resolvedSourcePath)) {
                            if ($sp -ieq $resolvedSourcePath -or $sp -ieq $SourceStorePath) {
                                $sourceStore = $s
                            }
                        }
                    }
                }
            }

            # If sourceStore not explicitly found, default to DefaultStore
            if ($null -eq $sourceStore -and $ns.PSObject.Properties['DefaultStore']) {
                $sourceStore = $ns.DefaultStore
            }

            if ($null -eq $targetStore) {
                throw "Target Outlook store could not be found for path: '$resolvedTargetPath'."
            }

            if ($null -eq $sourceStore) {
                throw "Source Outlook store could not be resolved."
            }

            # Resolve root folders
            if ($sourceStore.PSObject.Methods['GetRootFolder']) {
                $sourceRoot = $sourceStore.GetRootFolder()
            } elseif ($sourceStore.PSObject.Properties['RootFolder']) {
                $sourceRoot = $sourceStore.RootFolder
            }

            if ($targetStore.PSObject.Methods['GetRootFolder']) {
                $targetRoot = $targetStore.GetRootFolder()
            } elseif ($targetStore.PSObject.Properties['RootFolder']) {
                $targetRoot = $targetStore.RootFolder
            }

            if ($null -eq $sourceRoot -or $null -eq $targetRoot) {
                throw "Unable to obtain root folders for source or target store."
            }

            # Helper functions for folder navigation and creation
            function Add-FolderObject {
                param($parent, [string]$name)
                if ($null -eq $parent) { return $null }
                if ($parent.PSObject.Methods['AddFolder']) {
                    return $parent.AddFolder($name)
                }
                if ($parent.PSObject.Properties['Folders'] -and $null -ne $parent.Folders) {
                    if ($parent.Folders.PSObject.Methods['Add']) {
                        return $parent.Folders.Add($name)
                    }
                    if ($parent.Folders.PSObject.Methods['AddFolder']) {
                        return $parent.Folders.AddFolder($name)
                    }
                }
                return $null
            }

            function Find-FolderObject {
                param($parent, [string]$name)
                if ($null -eq $parent -or -not $parent.PSObject.Properties['Folders'] -or $null -eq $parent.Folders) {
                    return $null
                }
                foreach ($f in $parent.Folders) {
                    if ($f.Name -ieq $name) {
                        return $f
                    }
                }
                return $null
            }

            function Ensure-FolderObject {
                param($parent, [string]$name)
                $found = Find-FolderObject -parent $parent -name $name
                if ($null -ne $found) { return $found }
                return Add-FolderObject -parent $parent -name $name
            }

            # Standard built-in system folder names to skip at the store root
            $systemFolderNames = @(
                'Deleted Items',
                'Drafts',
                'Outbox',
                'Sent Items',
                'Junk Email',
                'Junk E-mail',
                'Calendar',
                'Contacts',
                'Journal',
                'Notes',
                'Tasks',
                'RSS Feeds',
                'RSS Subscriptions',
                'Conversation History',
                'Quick Step Settings',
                'Newsfeed',
                'Sync Issues',
                'Conflicts',
                'Local Failures',
                'Server Failures',
                'External Contacts',
                'Yammer Root',
                'Search Folders'
            )

            # Recursive folder cloning worker
            function Copy-SubFoldersRecursively {
                param(
                    $srcParent,
                    $dstParent,
                    [string]$pathPrefix
                )
                if ($null -eq $srcParent -or -not $srcParent.PSObject.Properties['Folders'] -or $null -eq $srcParent.Folders) {
                    return
                }

                foreach ($child in $srcParent.Folders) {
                    $childName = $child.Name
                    $relPath = if ([string]::IsNullOrWhiteSpace($pathPrefix)) { $childName } else { "$pathPrefix\$childName" }

                    $clonedChild = Ensure-FolderObject -parent $dstParent -name $childName
                    if ($null -ne $clonedChild) {
                        $script:foldersClonedCount++
                        $script:folderMap[$relPath] = $clonedChild

                        # Recurse down subfolders
                        Copy-SubFoldersRecursively -srcParent $child -dstParent $clonedChild -pathPrefix $relPath
                    }
                }
            }

            # 4. Clone Folders
            if ($sourceRoot.PSObject.Properties['Folders'] -and $null -ne $sourceRoot.Folders) {
                foreach ($rootItem in $sourceRoot.Folders) {
                    $rName = $rootItem.Name

                    if ($rName -ieq 'Inbox') {
                        # Ensure Inbox exists in target store
                        $targetInbox = Ensure-FolderObject -parent $targetRoot -name 'Inbox'
                        if ($null -ne $targetInbox) {
                            $script:folderMap['Inbox'] = $targetInbox
                            # Recursively clone all subfolders under Inbox
                            Copy-SubFoldersRecursively -srcParent $rootItem -dstParent $targetInbox -pathPrefix 'Inbox'
                        }
                    }
                    elseif ($systemFolderNames -contains $rName) {
                        # Skip system default folders
                        continue
                    }
                    else {
                        # Custom user root folder (e.g., 'Finance', 'Projects')
                        $clonedRootFolder = Ensure-FolderObject -parent $targetRoot -name $rName
                        if ($null -ne $clonedRootFolder) {
                            $script:foldersClonedCount++
                            $script:folderMap[$rName] = $clonedRootFolder

                            # Recursively clone subfolders
                            Copy-SubFoldersRecursively -srcParent $rootItem -dstParent $clonedRootFolder -pathPrefix $rName
                        }
                    }
                }
            }

            $success = $true
        }
        catch {
            $errorMessage = $_.Exception.Message
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Folder hierarchy cloning failed: $errorMessage" -Level 'WARN' -Component 'Outlook:Hierarchy'
            }
        }
        finally {
            if ($null -ne $comApp -and -not $outlookRunningBefore) {
                try { $comApp.Quit() } catch { $null = $_ }
            }

            $objectsToRelease = @($targetRoot, $sourceRoot, $targetStore, $sourceStore, $stores, $ns, $comApp)
            if (Get-Command -Name 'Remove-ToolkitComObject' -ErrorAction SilentlyContinue) {
                Remove-ToolkitComObject -ComObjects $objectsToRelease
            }
        }

        $sourceResultPath = if (-not [string]::IsNullOrWhiteSpace($resolvedSourcePath)) {
            $resolvedSourcePath
        } elseif ($null -ne $sourceStore -and $sourceStore.FilePath) {
            [string]$sourceStore.FilePath
        } else {
            $null
        }

        return [PSCustomObject]@{
            SourcePath    = $sourceResultPath
            TargetPath    = $resolvedTargetPath
            FoldersCloned = $script:foldersClonedCount
            FolderMap     = $script:folderMap
            Success       = $success
            ErrorMessage  = $errorMessage
        }
    }
}
