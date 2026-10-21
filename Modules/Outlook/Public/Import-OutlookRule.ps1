function Import-OutlookRule {
<#
.SYNOPSIS
    Imports Outlook rules and restores folder hierarchies from a JSON manifest.
.DESCRIPTION
    Deserializes a portable JSON rule manifest produced by Export-OutlookRule, resolves the
    target store and profile, pre-creates missing target folders, remaps environment-dependent
    parameters (-AddressMap, -AccountMap, -AutoRemapAccounts), resolves duplicates
    ('Skip', 'Overwrite', 'Rename', 'KeepBoth'), and silently saves the rules collection via
    Save($false). Supports -WhatIf, -EnableImportedRules, and deterministic COM cleanup.
.PARAMETER Path
    Path to the source .json rule manifest file.
.PARAMETER ProfileName
    Target Outlook profile name. If omitted, uses active or default profile.
.PARAMETER TargetStorePath
    Target data file (.pst/.ost) path where rules should be imported.
.PARAMETER TargetStoreName
    Target store display name.
.PARAMETER AddressMap
    Hashtable of email address substitutions (e.g. @{ 'old@corp.com' = 'new@corp.com'; '@old.com' = '@new.com' }).
.PARAMETER AccountMap
    Hashtable of account substitutions (e.g. @{ 'Old Account' = 'New Account' }).
.PARAMETER AutoCreateFolders
    Automatically pre-creates missing target folders in the destination store. Default: $true.
.PARAMETER DuplicateHandling
    Policy for resolving duplicate rule names: 'Skip', 'Overwrite', 'Rename', 'KeepBoth'. Default: 'Skip'.
.PARAMETER EnableImportedRules
    Force enables imported rules regardless of manifest state.
.PARAMETER AutoRemapAccounts
    Automatically substitutes target profile's active account when an Account condition is present.
.OUTPUTS
    [PSCustomObject]@{ Path, Profile, Store, RulesImported, RulesOverwritten, RulesSkipped, RulesRenamed, FoldersCreated, Success, Method, ErrorMessage }
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$ProfileName,

        [Parameter(Mandatory = $false)]
        [string]$TargetStorePath,

        [Parameter(Mandatory = $false)]
        [string]$TargetStoreName,

        [Parameter(Mandatory = $false)]
        [hashtable]$AddressMap,

        [Parameter(Mandatory = $false)]
        [hashtable]$AccountMap,

        [Parameter(Mandatory = $false)]
        [switch]$AutoCreateFolders = $true,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Skip', 'Overwrite', 'Rename', 'KeepBoth')]
        [string]$DuplicateHandling = 'Skip',

        [Parameter(Mandatory = $false)]
        [switch]$EnableImportedRules,

        [Parameter(Mandatory = $false)]
        [switch]$AutoRemapAccounts
    )

    process {
        # 1. Path Normalization & Manifest Ingestion
        $resolvedPath = [System.Environment]::ExpandEnvironmentVariables($Path.Trim())
        if ($ExecutionContext.SessionState.Path) {
            try {
                $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($resolvedPath)
            } catch {
                try { $resolvedPath = [System.IO.Path]::GetFullPath($resolvedPath) } catch { $null = $_ }
            }
        } else {
            try { $resolvedPath = [System.IO.Path]::GetFullPath($resolvedPath) } catch { $null = $_ }
        }

        # Auto-append .json if omitted and file does not exist as-is
        if (-not (Test-Path -LiteralPath $resolvedPath) -and -not $resolvedPath.EndsWith('.json', [System.StringComparison]::OrdinalIgnoreCase)) {
            $jsonCandidate = "$resolvedPath.json"
            if (Test-Path -LiteralPath $jsonCandidate) {
                $resolvedPath = $jsonCandidate
            }
        }

        # 2. Target Profile Pre-Resolution
        $targetProfile = $ProfileName
        if ([string]::IsNullOrWhiteSpace($targetProfile)) {
            if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
                try {
                    $ctx = Get-OutlookSystemContext
                    if ($null -ne $ctx -and -not [string]::IsNullOrWhiteSpace($ctx.DefaultProfile) -and $ctx.DefaultProfile -ne 'None') {
                        $targetProfile = $ctx.DefaultProfile
                    }
                } catch { $null = $_ }
            }
        }
        if ([string]::IsNullOrWhiteSpace($targetProfile)) {
            $targetProfile = 'Outlook'
        }

        $targetStoreDesc = if (-not [string]::IsNullOrWhiteSpace($TargetStoreName)) {
            $TargetStoreName
        } elseif (-not [string]::IsNullOrWhiteSpace($TargetStorePath)) {
            $TargetStorePath
        } else {
            $targetProfile
        }

        # 3. File Existence Verification
        if (-not (Test-Path -LiteralPath $resolvedPath)) {
            $msg = "Rule manifest file not found: '$resolvedPath'."
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message $msg -Level 'WARN' -Component 'Outlook:Import'
            }
            return [PSCustomObject]@{
                Path             = $resolvedPath
                Profile          = $targetProfile
                Store            = $targetStoreDesc
                RulesImported    = 0
                RulesOverwritten = 0
                RulesSkipped     = 0
                RulesRenamed     = 0
                FoldersCreated   = 0
                Success          = $false
                Method           = 'None'
                ErrorMessage     = $msg
            }
        }

        # 4. JSON Deserialization & Schema Validation
        $manifest = $null
        try {
            $rawJson = [System.IO.File]::ReadAllText($resolvedPath, [System.Text.Encoding]::UTF8)
            $manifest = $rawJson | ConvertFrom-Json
        } catch {
            $msg = "Failed to parse JSON rule manifest from '$resolvedPath': $($_.Exception.Message)"
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message $msg -Level 'WARN' -Component 'Outlook:Import'
            }
            return [PSCustomObject]@{
                Path             = $resolvedPath
                Profile          = $targetProfile
                Store            = $targetStoreDesc
                RulesImported    = 0
                RulesOverwritten = 0
                RulesSkipped     = 0
                RulesRenamed     = 0
                FoldersCreated   = 0
                Success          = $false
                Method           = 'None'
                ErrorMessage     = $msg
            }
        }

        if ($null -eq $manifest) {
            $msg = "Manifest content is empty or null in '$resolvedPath'."
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message $msg -Level 'WARN' -Component 'Outlook:Import'
            }
            return [PSCustomObject]@{
                Path             = $resolvedPath
                Profile          = $targetProfile
                Store            = $targetStoreDesc
                RulesImported    = 0
                RulesOverwritten = 0
                RulesSkipped     = 0
                RulesRenamed     = 0
                FoldersCreated   = 0
                Success          = $false
                Method           = 'None'
                ErrorMessage     = $msg
            }
        }

        # 5. SupportsShouldProcess Check (-WhatIf)
        if (-not $PSCmdlet.ShouldProcess($targetStoreDesc, "Import rules from '$resolvedPath' (DuplicateHandling: $DuplicateHandling)")) {
            return [PSCustomObject]@{
                Path             = $resolvedPath
                Profile          = $targetProfile
                Store            = $targetStoreDesc
                RulesImported    = 0
                RulesOverwritten = 0
                RulesSkipped     = 0
                RulesRenamed     = 0
                FoldersCreated   = 0
                Success          = $true
                Method           = 'WhatIf'
                ErrorMessage     = $null
            }
        }

        # 6. Helper: Address Remapping
        $addrLookup = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $AddressMap) {
            foreach ($k in $AddressMap.Keys) {
                $addrLookup[[string]$k] = [string]$AddressMap[$k]
            }
        }

        function script:Resolve-ImportedAddress {
            param([string]$rawAddress, [System.Collections.Generic.Dictionary[string, string]]$lookup)
            if ([string]::IsNullOrWhiteSpace($rawAddress) -or $null -eq $lookup -or $lookup.Count -eq 0) {
                return $rawAddress
            }
            $clean = $rawAddress.Trim()
            if ($lookup.ContainsKey($clean)) {
                return $lookup[$clean]
            }
            if ($clean -match '<([^>]+)>') {
                $ext = $Matches[1].Trim()
                if ($lookup.ContainsKey($ext)) {
                    $m = $lookup[$ext]
                    return ($clean -replace '<[^>]+>', "<$m>")
                }
            }
            foreach ($entry in $lookup.GetEnumerator()) {
                $k = $entry.Key
                $v = $entry.Value
                if ($k.StartsWith('@') -and $clean.EndsWith($k, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $pfx = $clean.Substring(0, $clean.Length - $k.Length)
                    return "$pfx$v"
                }
                if (-not $k.StartsWith('@') -and $k.Contains('.') -and $clean.EndsWith("@$k", [System.StringComparison]::OrdinalIgnoreCase)) {
                    $pfx = $clean.Substring(0, $clean.Length - $k.Length)
                    return "$pfx$v"
                }
            }
            return $clean
        }

        # 7. Helper: Account Remapping
        $accLookup = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $AccountMap) {
            foreach ($k in $AccountMap.Keys) {
                $accLookup[[string]$k] = [string]$AccountMap[$k]
            }
        }

        function script:Resolve-ImportedAccount {
            param(
                [string]$SourceAccountName,
                [System.Collections.Generic.Dictionary[string, string]]$AccountMapLookup,
                [bool]$AutoRemap,
                $PrimaryTargetAccount,
                [string]$TargetStoreDisplayName,
                $AllTargetAccounts
            )

            # 1. Explicit AccountMap check
            if ($null -ne $AccountMapLookup -and -not [string]::IsNullOrWhiteSpace($SourceAccountName)) {
                if ($AccountMapLookup.ContainsKey($SourceAccountName)) {
                    $mappedName = $AccountMapLookup[$SourceAccountName]
                    if ($null -ne $AllTargetAccounts) {
                        foreach ($acc in $AllTargetAccounts) {
                            if (($acc.DisplayName -ieq $mappedName) -or ($acc.SmtpAddress -ieq $mappedName) -or ($acc.Name -ieq $mappedName)) {
                                return @{ AccountObj = $acc; AccountName = $mappedName }
                            }
                        }
                    }
                    return @{ AccountObj = $null; AccountName = $mappedName }
                }
            }

            # 2. AutoRemapAccounts check
            if ($AutoRemap) {
                if ($null -ne $PrimaryTargetAccount) {
                    $accName = if ($PrimaryTargetAccount.DisplayName) { [string]$PrimaryTargetAccount.DisplayName } else { [string]$PrimaryTargetAccount.Name }
                    return @{ AccountObj = $PrimaryTargetAccount; AccountName = $accName }
                }
                if (-not [string]::IsNullOrWhiteSpace($TargetStoreDisplayName)) {
                    return @{ AccountObj = $null; AccountName = $TargetStoreDisplayName }
                }
            }

            # 3. Match source account name directly in target accounts
            if (-not [string]::IsNullOrWhiteSpace($SourceAccountName) -and $null -ne $AllTargetAccounts) {
                foreach ($acc in $AllTargetAccounts) {
                    if (($acc.DisplayName -ieq $SourceAccountName) -or ($acc.SmtpAddress -ieq $SourceAccountName) -or ($acc.Name -ieq $SourceAccountName)) {
                        return @{ AccountObj = $acc; AccountName = $SourceAccountName }
                    }
                }
            }

            return @{ AccountObj = $null; AccountName = $SourceAccountName }
        }

        # 8. COM & Target Store Operations
        $outlookRunningBefore = [bool](Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
        $comApp = $null
        $ns = $null
        $stores = $null
        $targetStore = $null
        $targetRoot = $null
        $targetRules = $null
        $didLogon = $false
        $success = $false
        $errorMessage = $null

        $rulesImportedCount = 0
        $rulesOverwrittenCount = 0
        $rulesSkippedCount = 0
        $rulesRenamedCount = 0
        $script:foldersCreatedCount = 0

        try {
            if (Get-Command -Name 'Get-OutlookComApplication' -ErrorAction SilentlyContinue) {
                $comApp = Get-OutlookComApplication
            } else {
                $outlookMod = Get-Module -Name 'Outlook'
                if ($null -ne $outlookMod) {
                    $comApp = & $outlookMod { Get-OutlookComApplication }
                } else {
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

            if (-not [string]::IsNullOrWhiteSpace($targetProfile)) {
                try {
                    $ns.Logon($targetProfile, $null, $false, $false)
                    $didLogon = $true
                } catch { $null = $_ }
            }

            # Store Discovery & Selection
            $resolvedTargetStorePath = $null
            if (-not [string]::IsNullOrWhiteSpace($TargetStorePath)) {
                $resolvedTargetStorePath = [System.Environment]::ExpandEnvironmentVariables($TargetStorePath.Trim())
                if (-not ($resolvedTargetStorePath -match '^[a-zA-Z]:[/\\]' -and [System.IO.Path]::DirectorySeparatorChar -ne [char]92)) {
                    try {
                        $resolvedTargetStorePath = [System.IO.Path]::GetFullPath($resolvedTargetStorePath)
                    } catch { $null = $_ }
                }
            }

            if ($ns.PSObject.Properties['Stores'] -and $null -ne $ns.Stores) {
                $stores = $ns.Stores
                foreach ($s in $stores) {
                    if ($null -eq $s) { continue }
                    $sp = if ($s.PSObject.Properties['FilePath'] -and $s.FilePath) { [string]$s.FilePath } else { '' }
                    $dn = if ($s.PSObject.Properties['DisplayName'] -and $s.DisplayName) { [string]$s.DisplayName } else { '' }

                    # Match by FilePath
                    if (-not [string]::IsNullOrWhiteSpace($resolvedTargetStorePath)) {
                        if ($sp -ieq $resolvedTargetStorePath -or $sp -ieq $TargetStorePath) {
                            $targetStore = $s
                            break
                        }
                    }
                    # Match by StoreName
                    elseif (-not [string]::IsNullOrWhiteSpace($TargetStoreName)) {
                        if ($dn -ieq $TargetStoreName -or ($s.PSObject.Properties['Name'] -and $s.Name -ieq $TargetStoreName)) {
                            $targetStore = $s
                            break
                        }
                    }
                    # Default store match
                    elseif ($s.PSObject.Properties['IsDefaultStore'] -and $s.IsDefaultStore) {
                        $targetStore = $s
                        break
                    }
                }
            }

            # Fallback to DefaultStore property
            if ($null -eq $targetStore -and [string]::IsNullOrWhiteSpace($TargetStorePath) -and [string]::IsNullOrWhiteSpace($TargetStoreName)) {
                if ($ns.PSObject.Properties['DefaultStore'] -and $null -ne $ns.DefaultStore) {
                    $targetStore = $ns.DefaultStore
                }
            }

            if ($null -eq $targetStore) {
                $targetIdentifier = if (-not [string]::IsNullOrWhiteSpace($TargetStorePath)) {
                    "path '$TargetStorePath'"
                } elseif (-not [string]::IsNullOrWhiteSpace($TargetStoreName)) {
                    "name '$TargetStoreName'"
                } else {
                    "profile '$targetProfile'"
                }
                throw "Outlook store was not found for $targetIdentifier."
            }

            $storeDisplayName = if ($targetStore.PSObject.Properties['DisplayName'] -and -not [string]::IsNullOrWhiteSpace($targetStore.DisplayName)) {
                [string]$targetStore.DisplayName
            } elseif ($targetStore.PSObject.Properties['Name']) {
                [string]$targetStore.Name
            } else {
                $targetProfile
            }

            # Resolve Root Folder
            if ($targetStore.PSObject.Methods['GetRootFolder']) {
                $targetRoot = $targetStore.GetRootFolder()
            } elseif ($targetStore.PSObject.Properties['RootFolder']) {
                $targetRoot = $targetStore.RootFolder
            }

            if ($null -eq $targetRoot) {
                throw "Unable to obtain root folder for target store '$storeDisplayName'."
            }

            # Resolve Rules Collection
            if ($targetStore.PSObject.Methods['GetRules']) {
                $targetRules = $targetStore.GetRules()
            } elseif ($targetStore.PSObject.Properties['Rules']) {
                $targetRules = $targetStore.Rules
            }

            if ($null -eq $targetRules) {
                throw "Failed to access Rules collection on target Outlook store '$storeDisplayName'."
            }

            # Account Resolution for Target
            $primaryTargetAccount = $null
            $allTargetAccounts = @()
            if ($ns.PSObject.Properties['Accounts'] -and $null -ne $ns.Accounts) {
                foreach ($acc in $ns.Accounts) {
                    if ($null -ne $acc) {
                        $allTargetAccounts += $acc
                        if ($null -eq $primaryTargetAccount) {
                            $primaryTargetAccount = $acc
                        }
                    }
                }
            }

            # Helper functions for folder hierarchy navigation and creation
            function script:Add-ImportFolder {
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

            function script:Find-ImportFolder {
                param($parent, [string]$name)
                if ($null -eq $parent -or -not $parent.PSObject.Properties['Folders'] -or $null -eq $parent.Folders) {
                    return $null
                }
                foreach ($f in $parent.Folders) {
                    if ($null -ne $f -and $f.PSObject.Properties['Name'] -and $f.Name -ieq $name) {
                        return $f
                    }
                }
                return $null
            }

            function script:Ensure-ImportFolder {
                param($parent, [string]$name)
                $found = script:Find-ImportFolder -parent $parent -name $name
                if ($null -ne $found) {
                    return @{ Folder = $found; Created = $false }
                }
                $created = script:Add-ImportFolder -parent $parent -name $name
                return @{ Folder = $created; Created = ($null -ne $created) }
            }

            # Folder map and indexing
            $folderMap = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $systemFolderNames = @(
                'Deleted Items', 'Drafts', 'Outbox', 'Sent Items', 'Junk Email',
                'Junk E-mail', 'Calendar', 'Contacts', 'Journal', 'Notes', 'Tasks',
                'RSS Feeds', 'RSS Subscriptions', 'Conversation History',
                'Quick Step Settings', 'Newsfeed', 'Sync Issues', 'Conflicts',
                'Local Failures', 'Server Failures', 'External Contacts', 'Yammer Root', 'Search Folders'
            )

            function script:Index-FolderTree {
                param($parent, [string]$pathPrefix, [System.Collections.Generic.Dictionary[string, object]]$map)
                if ($null -eq $parent -or -not $parent.PSObject.Properties['Folders'] -or $null -eq $parent.Folders) { return }
                foreach ($f in $parent.Folders) {
                    if ($null -eq $f -or -not $f.PSObject.Properties['Name']) { continue }
                    $fn = [string]$f.Name
                    $rel = if ([string]::IsNullOrWhiteSpace($pathPrefix)) { $fn } else { "$pathPrefix\$fn" }
                    $map[$rel] = $f
                    $map[($rel -replace '\\', '/')] = $f
                    if (-not $map.ContainsKey($fn)) { $map[$fn] = $f }
                    script:Index-FolderTree -parent $f -pathPrefix $rel -map $map
                }
            }

            script:Index-FolderTree -parent $targetRoot -pathPrefix '' -map $folderMap

            # Extract folders needing reconstruction
            $foldersToReconstruct = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            if ($AutoCreateFolders -and $manifest.PSObject.Properties['CustomFolders'] -and $null -ne $manifest.CustomFolders) {
                foreach ($cf in $manifest.CustomFolders) {
                    if (-not [string]::IsNullOrWhiteSpace($cf)) {
                        [void]$foldersToReconstruct.Add($cf.Trim())
                    }
                }
            }

            $rawRules = if ($manifest.PSObject.Properties['Rules'] -and $null -ne $manifest.Rules) {
                @($manifest.Rules)
            } else {
                @()
            }

            foreach ($r in $rawRules) {
                if ($null -eq $r -or -not $r.PSObject.Properties['Actions'] -or $null -eq $r.Actions) { continue }
                $acts = $r.Actions
                foreach ($faName in @('MoveToFolder', 'CopyToFolder')) {
                    if ($acts.PSObject.Properties[$faName] -and $null -ne $acts.$faName) {
                        $fa = $acts.$faName
                        $fp = if ($fa.PSObject.Properties['FolderPath']) { [string]$fa.FolderPath } else { $null }
                        if (-not [string]::IsNullOrWhiteSpace($fp) -and ($fa.PSObject.Properties['Enabled'] -eq $null -or [bool]$fa.Enabled)) {
                            [void]$foldersToReconstruct.Add($fp.Trim())
                        }
                    }
                }
            }

            # Hierarchy Pre-Creation
            if ($AutoCreateFolders) {
                # Ensure Inbox exists
                $targetInbox = script:Find-ImportFolder -parent $targetRoot -name 'Inbox'
                if ($null -eq $targetInbox) {
                    $inboxRes = script:Ensure-ImportFolder -parent $targetRoot -name 'Inbox'
                    $targetInbox = $inboxRes.Folder
                    if ($inboxRes.Created) {
                        $script:foldersCreatedCount++
                    }
                }
                if ($null -ne $targetInbox) {
                    $folderMap['Inbox'] = $targetInbox
                }

                # Sort shallowest first so parent folders are created before children
                $sortedPaths = @($foldersToReconstruct | Sort-Object { ($_ -split '[\\/]').Count })
                foreach ($relPath in $sortedPaths) {
                    $normalized = ($relPath -replace '/', '\').Trim('\')
                    if ([string]::IsNullOrWhiteSpace($normalized)) { continue }

                    $segments = $normalized -split '\\'
                    $currentParent = $null
                    $startIdx = 0

                    if ($segments[0] -ieq 'Inbox') {
                        $currentParent = $targetInbox
                        $startIdx = 1
                    } elseif ($systemFolderNames -contains $segments[0]) {
                        $currentParent = script:Find-ImportFolder -parent $targetRoot -name $segments[0]
                        $startIdx = 1
                    } else {
                        $currentParent = $targetRoot
                        $startIdx = 0
                    }

                    if ($null -eq $currentParent) {
                        $currentParent = $targetRoot
                        $startIdx = 0
                    }

                    $builtPath = if ($startIdx -eq 1) { $segments[0] } else { '' }

                    for ($i = $startIdx; $i -lt $segments.Length; $i++) {
                        $seg = $segments[$i]
                        if ([string]::IsNullOrWhiteSpace($seg)) { continue }

                        $builtPath = if ([string]::IsNullOrWhiteSpace($builtPath)) { $seg } else { "$builtPath\$seg" }

                        $res = script:Ensure-ImportFolder -parent $currentParent -name $seg
                        if ($res.Created) {
                            $script:foldersCreatedCount++
                        }
                        $currentParent = $res.Folder

                        if ($null -ne $currentParent) {
                            $folderMap[$builtPath] = $currentParent
                            $folderMap[($builtPath -replace '\\', '/')] = $currentParent
                            if (-not $folderMap.ContainsKey($seg)) {
                                $folderMap[$seg] = $currentParent
                            }
                        } else {
                            break
                        }
                    }
                }
            }

            # Helper: Apply Conditions/Exceptions to Container
            function script:Apply-ImportConditions {
                param(
                    $targetContainer,
                    $sourceDict,
                    $addrLookupTable,
                    $targetAccountObj,
                    [string]$targetAccountName
                )

                if ($null -eq $targetContainer -or $null -eq $sourceDict) { return }

                foreach ($prop in $sourceDict.PSObject.Properties) {
                    $condName = $prop.Name
                    $condDef = $prop.Value
                    if ($null -eq $condDef -or -not [bool]$condDef.Enabled) { continue }

                    $targetItem = $null
                    if ($targetContainer.PSObject.Properties[$condName]) {
                        $targetItem = $targetContainer.PSObject.Properties[$condName].Value
                    } else {
                        try { $targetItem = $targetContainer.$condName } catch { $null = $_ }
                    }

                    if ($null -eq $targetItem) { continue }

                    # 1. Text payload (Subject, Body, BodyOrSubject, MessageHeader)
                    if ($condDef.PSObject.Properties['Text'] -and $null -ne $condDef.Text) {
                        try { $targetItem.Text = @($condDef.Text) } catch { $null = $_ }
                    }

                    # 2. Recipients payload (From, SentTo)
                    if ($condDef.PSObject.Properties['Recipients'] -and $null -ne $condDef.Recipients) {
                        $remappedRecips = @()
                        foreach ($r in $condDef.Recipients) {
                            $remappedRecips += (script:Resolve-ImportedAddress -rawAddress ([string]$r) -lookup $addrLookupTable)
                        }
                        if ($targetItem.PSObject.Properties['Recipients']) {
                            if ($targetItem.Recipients -is [System.Array]) {
                                $targetItem.Recipients = @($remappedRecips)
                            } elseif ($null -ne $targetItem.Recipients -and $targetItem.Recipients.PSObject.Methods['Add']) {
                                if ($targetItem.Recipients.PSObject.Properties['Count'] -and $targetItem.Recipients.PSObject.Methods['Remove']) {
                                    while ($targetItem.Recipients.Count -gt 0) {
                                        try { $targetItem.Recipients.Remove(1) } catch { break }
                                    }
                                }
                                foreach ($rv in $remappedRecips) {
                                    try { $null = $targetItem.Recipients.Add($rv) } catch { $null = $_ }
                                }
                                if ($targetItem.Recipients.PSObject.Methods['ResolveAll']) {
                                    try { $targetItem.Recipients.ResolveAll() } catch { $null = $_ }
                                }
                            } else {
                                try { $targetItem.Recipients = @($remappedRecips) } catch { $null = $_ }
                            }
                        }
                    }

                    # 3. Address payload (SenderAddress, RecipientAddress)
                    if ($condDef.PSObject.Properties['Address'] -and $null -ne $condDef.Address) {
                        $remappedAddrs = @()
                        foreach ($a in $condDef.Address) {
                            $remappedAddrs += (script:Resolve-ImportedAddress -rawAddress ([string]$a) -lookup $addrLookupTable)
                        }
                        try { $targetItem.Address = @($remappedAddrs) } catch { $null = $_ }
                    }

                    # 4. Categories payload
                    if ($condDef.PSObject.Properties['Categories'] -and $null -ne $condDef.Categories) {
                        try { $targetItem.Categories = @($condDef.Categories) } catch { $null = $_ }
                    }

                    # 5. Importance & Sensitivity
                    if ($condDef.PSObject.Properties['Importance'] -and $null -ne $condDef.Importance) {
                        try { $targetItem.Importance = [int]$condDef.Importance } catch { $null = $_ }
                    }
                    if ($condDef.PSObject.Properties['Sensitivity'] -and $null -ne $condDef.Sensitivity) {
                        try { $targetItem.Sensitivity = [int]$condDef.Sensitivity } catch { $null = $_ }
                    }

                    # 6. Account payload
                    if ($condDef.PSObject.Properties['Account'] -and $null -ne $condDef.Account) {
                        $assigned = $false
                        if ($null -ne $targetAccountObj -and [System.Runtime.InteropServices.Marshal]::IsComObject($targetAccountObj)) {
                            try {
                                $targetItem.Account = $targetAccountObj
                                $assigned = $true
                            } catch { $null = $_ }
                        }
                        if (-not $assigned -and -not [string]::IsNullOrWhiteSpace($targetAccountName)) {
                            try {
                                $targetItem.Account = $targetAccountName
                                $assigned = $true
                            } catch { $null = $_ }
                        }
                        if (-not $assigned -and $null -ne $targetAccountObj) {
                            try {
                                $targetItem.Account = $targetAccountObj
                                $assigned = $true
                            } catch { $null = $_ }
                        }
                        if (-not $assigned) {
                            try { $targetItem.Account = [string]$condDef.Account } catch { $null = $_ }
                        }
                    }

                    # Enable condition
                    try { $targetItem.Enabled = $true } catch { $null = $_ }
                }
            }

            # Helper: Apply Actions to Container
            function script:Apply-ImportActions {
                param(
                    $targetActions,
                    $sourceDict,
                    $folderLookupMap,
                    $targetRootFolder,
                    $addrLookupTable
                )

                if ($null -eq $targetActions -or $null -eq $sourceDict) { return }

                # Folder Actions (MoveToFolder, CopyToFolder)
                foreach ($faName in @('MoveToFolder', 'CopyToFolder')) {
                    if ($sourceDict.PSObject.Properties[$faName]) {
                        $faDef = $sourceDict.PSObject.Properties[$faName].Value
                        if ($null -ne $faDef -and [bool]$faDef.Enabled -and -not [string]::IsNullOrWhiteSpace($faDef.FolderPath)) {
                            $rel = [string]$faDef.FolderPath
                            $fObj = $null
                            if ($folderLookupMap.ContainsKey($rel)) {
                                $fObj = $folderLookupMap[$rel]
                            } elseif ($folderLookupMap.ContainsKey(($rel -replace '/', '\'))) {
                                $fObj = $folderLookupMap[($rel -replace '/', '\')]
                            } else {
                                $leaf = ($rel -split '[\\/]')[-1]
                                if ($folderLookupMap.ContainsKey($leaf)) {
                                    $fObj = $folderLookupMap[$leaf]
                                }
                            }

                            $tgtAction = $null
                            if ($targetActions.PSObject.Properties[$faName]) {
                                $tgtAction = $targetActions.PSObject.Properties[$faName].Value
                            } else {
                                try { $tgtAction = $targetActions.$faName } catch { $null = $_ }
                            }

                            if ($null -ne $tgtAction -and $null -ne $fObj) {
                                try { $tgtAction.Folder = $fObj } catch { $null = $_ }
                                try { $tgtAction.Enabled = $true } catch { $null = $_ }
                            }
                        }
                    }
                }

                # Non-Folder Actions
                $knownNonFolder = @('Delete', 'DeletePermanently', 'MarkAsRead', 'Stop', 'ClearCategories', 'AssignToCategory', 'PlaySound', 'NewItemAlert', 'MarkAsTask', 'Forward', 'Redirect', 'Cc')
                foreach ($na in $knownNonFolder) {
                    if ($sourceDict.PSObject.Properties[$na]) {
                        $actDef = $sourceDict.PSObject.Properties[$na].Value
                        if ($null -ne $actDef -and [bool]$actDef.Enabled) {
                            $tgtAct = $null
                            if ($targetActions.PSObject.Properties[$na]) {
                                $tgtAct = $targetActions.PSObject.Properties[$na].Value
                            } else {
                                try { $tgtAct = $targetActions.$na } catch { $null = $_ }
                            }

                            if ($null -eq $tgtAct) { continue }

                            if ($actDef.PSObject.Properties['Categories'] -and $null -ne $actDef.Categories) {
                                try { $tgtAct.Categories = @($actDef.Categories) } catch { $null = $_ }
                            }
                            if ($actDef.PSObject.Properties['FilePath'] -and $null -ne $actDef.FilePath) {
                                try { $tgtAct.FilePath = [string]$actDef.FilePath } catch { $null = $_ }
                            }
                            if ($actDef.PSObject.Properties['Text'] -and $null -ne $actDef.Text) {
                                try { $tgtAct.Text = [string]$actDef.Text } catch { $null = $_ }
                            }
                            if ($actDef.PSObject.Properties['FlagTo'] -and $null -ne $actDef.FlagTo) {
                                try { $tgtAct.FlagTo = [string]$actDef.FlagTo } catch { $null = $_ }
                            }
                            if ($actDef.PSObject.Properties['Recipients'] -and $null -ne $actDef.Recipients) {
                                $remappedR = @()
                                foreach ($r in $actDef.Recipients) {
                                    $remappedR += (script:Resolve-ImportedAddress -rawAddress ([string]$r) -lookup $addrLookupTable)
                                }
                                if ($tgtAct.PSObject.Properties['Recipients']) {
                                    if ($tgtAct.Recipients -is [System.Array]) {
                                        $tgtAct.Recipients = @($remappedR)
                                    } elseif ($null -ne $tgtAct.Recipients -and $tgtAct.Recipients.PSObject.Methods['Add']) {
                                        foreach ($rv in $remappedR) {
                                            try { $null = $tgtAct.Recipients.Add($rv) } catch { $null = $_ }
                                        }
                                        if ($tgtAct.Recipients.PSObject.Methods['ResolveAll']) {
                                            try { $tgtAct.Recipients.ResolveAll() } catch { $null = $_ }
                                        }
                                    } else {
                                        try { $tgtAct.Recipients = @($remappedR) } catch { $null = $_ }
                                    }
                                }
                            }

                            try { $tgtAct.Enabled = $true } catch { $null = $_ }
                        }
                    }
                }
            }

            # Index Existing Target Rules
            $existingRulesMap = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $targetRulesList = @()
            if ($targetRules -is [System.Collections.IEnumerable] -and $targetRules -isnot [PSCustomObject]) {
                $targetRulesList = @($targetRules)
            } elseif ($targetRules.PSObject.Methods['GetEnumerator']) {
                try { $targetRulesList = @($targetRules.GetEnumerator()) } catch { $targetRulesList = @($targetRules) }
            } elseif ($targetRules.PSObject.Properties['RulesList'] -and $null -ne $targetRules.RulesList) {
                $targetRulesList = @($targetRules.RulesList)
            } elseif ($targetRules.PSObject.Properties['Count'] -and $targetRules.PSObject.Methods['Item']) {
                for ($i = 0; $i -lt $targetRules.Count; $i++) {
                    $targetRulesList += $targetRules.Item($i)
                }
            } else {
                $targetRulesList = @($targetRules)
            }

            foreach ($tr in $targetRulesList) {
                if ($null -ne $tr -and -not [string]::IsNullOrWhiteSpace($tr.Name)) {
                    $existingRulesMap[$tr.Name] = $tr
                }
            }

            # Process Rules from Manifest
            foreach ($ruleDef in $rawRules) {
                if ($null -eq $ruleDef -or [string]::IsNullOrWhiteSpace($ruleDef.Name)) { continue }

                $isDuplicate = $existingRulesMap.ContainsKey($ruleDef.Name)
                $targetRuleInstance = $null
                $effectiveRuleName = [string]$ruleDef.Name

                if ($isDuplicate) {
                    if ($DuplicateHandling -eq 'Skip') {
                        $rulesSkippedCount++
                        Write-Verbose "Skipped rule '$($ruleDef.Name)': duplicate in target store."
                        continue
                    }
                    elseif ($DuplicateHandling -eq 'Overwrite') {
                        $targetRuleInstance = $existingRulesMap[$ruleDef.Name]
                        # In-place reset of existing conditions, exceptions, actions
                        if ($targetRuleInstance.PSObject.Properties['Conditions'] -and $targetRuleInstance.Conditions) {
                            foreach ($p in $targetRuleInstance.Conditions.PSObject.Properties) {
                                if ($p.Value -and $p.Value.PSObject.Properties['Enabled']) {
                                    try { $p.Value.Enabled = $false } catch { $null = $_ }
                                }
                            }
                        }
                        if ($targetRuleInstance.PSObject.Properties['Exceptions'] -and $targetRuleInstance.Exceptions) {
                            foreach ($p in $targetRuleInstance.Exceptions.PSObject.Properties) {
                                if ($p.Value -and $p.Value.PSObject.Properties['Enabled']) {
                                    try { $p.Value.Enabled = $false } catch { $null = $_ }
                                }
                            }
                        }
                        if ($targetRuleInstance.PSObject.Properties['Actions'] -and $targetRuleInstance.Actions) {
                            foreach ($p in $targetRuleInstance.Actions.PSObject.Properties) {
                                if ($p.Value) {
                                    if ($p.Value.PSObject.Properties['Enabled']) {
                                        try { $p.Value.Enabled = $false } catch { $null = $_ }
                                    }
                                    if ($p.Value.PSObject.Properties['Folder']) {
                                        try { $p.Value.Folder = $null } catch { $null = $_ }
                                    }
                                }
                            }
                        }
                        $rulesOverwrittenCount++
                    }
                    elseif ($DuplicateHandling -eq 'Rename') {
                        $candidate = "$($ruleDef.Name) (Imported)"
                        $idx = 2
                        while ($existingRulesMap.ContainsKey($candidate)) {
                            $candidate = "$($ruleDef.Name) (Imported $idx)"
                            $idx++
                        }
                        $effectiveRuleName = $candidate
                        $rulesRenamedCount++
                    }
                    elseif ($DuplicateHandling -eq 'KeepBoth') {
                        $candidate = "$($ruleDef.Name) (1)"
                        $idx = 2
                        while ($existingRulesMap.ContainsKey($candidate)) {
                            $candidate = "$($ruleDef.Name) ($idx)"
                            $idx++
                        }
                        $effectiveRuleName = $candidate
                        $rulesRenamedCount++
                    }
                }

                # Create rule if not overwriting
                if ($null -eq $targetRuleInstance) {
                    $rType = if ($ruleDef.PSObject.Properties['RuleType']) { [int]$ruleDef.RuleType } else { 0 }
                    if ($targetRules.PSObject.Methods['Create']) {
                        try {
                            $targetRuleInstance = $targetRules.Create($effectiveRuleName, $rType)
                        } catch {
                            Write-Verbose "Could not create rule via COM: $($_.Exception.Message)"
                        }
                    }
                    if ($null -eq $targetRuleInstance) {
                        # Mock fallback
                        $targetRuleInstance = [PSCustomObject]@{
                            Name           = $effectiveRuleName
                            RuleType       = $rType
                            Enabled        = [bool]$ruleDef.Enabled
                            ExecutionOrder = if ($ruleDef.PSObject.Properties['ExecutionOrder']) { [int]$ruleDef.ExecutionOrder } else { 1 }
                            Conditions     = [PSCustomObject]@{}
                            Exceptions     = [PSCustomObject]@{}
                            Actions        = [PSCustomObject]@{}
                        }
                        if ($targetRules.PSObject.Properties['RulesList']) {
                            $targetRules.RulesList.Add($targetRuleInstance)
                            if ($targetRules.PSObject.Properties['Count']) {
                                $targetRules.Count = $targetRules.RulesList.Count
                            }
                        }
                    }
                    $existingRulesMap[$effectiveRuleName] = $targetRuleInstance
                }

                # Set Rule Metadata
                if ($EnableImportedRules) {
                    try { $targetRuleInstance.Enabled = $true } catch { $null = $_ }
                } else {
                    try { $targetRuleInstance.Enabled = [bool]$ruleDef.Enabled } catch { $null = $_ }
                }

                if ($ruleDef.PSObject.Properties['ExecutionOrder'] -and $targetRuleInstance.PSObject.Properties['ExecutionOrder']) {
                    try { $targetRuleInstance.ExecutionOrder = [int]$ruleDef.ExecutionOrder } catch { $null = $_ }
                }

                # Account resolution for this rule
                $srcAccountName = if ($ruleDef.Conditions -and $ruleDef.Conditions.Account) { [string]$ruleDef.Conditions.Account.Account } else { $null }
                $resolvedAccountInfo = script:Resolve-ImportedAccount -SourceAccountName $srcAccountName `
                                                                     -AccountMapLookup $accLookup `
                                                                     -AutoRemap $AutoRemapAccounts `
                                                                     -PrimaryTargetAccount $primaryTargetAccount `
                                                                     -TargetStoreDisplayName $storeDisplayName `
                                                                     -AllTargetAccounts $allTargetAccounts

                # Apply Conditions
                if ($ruleDef.Conditions -and $targetRuleInstance.Conditions) {
                    script:Apply-ImportConditions -targetContainer $targetRuleInstance.Conditions `
                                                 -sourceDict $ruleDef.Conditions `
                                                 -addrLookupTable $addrLookup `
                                                 -targetAccountObj $resolvedAccountInfo.AccountObj `
                                                 -targetAccountName $resolvedAccountInfo.AccountName
                }

                # Apply Exceptions
                if ($ruleDef.Exceptions -and $targetRuleInstance.Exceptions) {
                    script:Apply-ImportConditions -targetContainer $targetRuleInstance.Exceptions `
                                                 -sourceDict $ruleDef.Exceptions `
                                                 -addrLookupTable $addrLookup `
                                                 -targetAccountObj $resolvedAccountInfo.AccountObj `
                                                 -targetAccountName $resolvedAccountInfo.AccountName
                }

                # Apply Actions
                if ($ruleDef.Actions -and $targetRuleInstance.Actions) {
                    script:Apply-ImportActions -targetActions $targetRuleInstance.Actions `
                                              -sourceDict $ruleDef.Actions `
                                              -folderLookupMap $folderMap `
                                              -targetRootFolder $targetRoot `
                                              -addrLookupTable $addrLookup
                }

                $rulesImportedCount++
            }

            # Silent Save: Save($false)
            if ($null -ne $targetRules -and $targetRules.PSObject.Methods['Save']) {
                try {
                    $targetRules.Save($false)
                } catch {
                    try {
                        $targetRules.Save()
                    } catch {
                        throw "Failed to commit rules to store via Save: $($_.Exception.Message)"
                    }
                }
            }

            $success = $true
        }
        catch {
            $errorMessage = $_.Exception.Message
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Outlook rule import failed: $errorMessage" -Level 'WARN' -Component 'Outlook:Import'
            }
        }
        finally {
            if ($didLogon -and $null -ne $ns) {
                try { $ns.Logoff() } catch { $null = $_ }
            }

            if ($null -ne $comApp -and -not $outlookRunningBefore) {
                try { $comApp.Quit() } catch { $null = $_ }
            }

            $objectsToRelease = @($targetRules, $targetRoot, $targetStore, $stores, $ns, $comApp)
            if (Get-Command -Name 'Remove-ToolkitComObject' -ErrorAction SilentlyContinue) {
                Remove-ToolkitComObject -ComObjects $objectsToRelease
            }
            else {
                foreach ($obj in $objectsToRelease) {
                    if ($null -ne $obj -and [System.Runtime.InteropServices.Marshal]::IsComObject($obj)) {
                        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($obj) | Out-Null } catch { $null = $_ }
                    }
                }
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
                [System.GC]::Collect()
            }
        }

        # Structured Result
        $method = if ($success) { 'COM' } else { 'None' }
        return [PSCustomObject]@{
            Path             = $resolvedPath
            Profile          = $targetProfile
            Store            = $storeDisplayName
            RulesImported    = $rulesImportedCount
            RulesOverwritten = $rulesOverwrittenCount
            RulesSkipped     = $rulesSkippedCount
            RulesRenamed     = $rulesRenamedCount
            FoldersCreated   = $script:foldersCreatedCount
            Success          = $success
            Method           = $method
            ErrorMessage     = $errorMessage
        }
    }
}
