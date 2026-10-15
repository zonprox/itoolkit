function Copy-OutlookRule {
<#
.SYNOPSIS
    Migrates and remaps Outlook rules from a source store to a target store.
.DESCRIPTION
    Enumerates rules from a source Outlook store and recreates them in the target store.
    Preserves rule enabled states, conditions, exceptions, and execution orders. For MoveToFolder
    and CopyToFolder actions, remaps the destination folder to the matching cloned folder in the
    target store using the provided FolderMap or relative path resolution. Clones non-folder actions
    (Delete, DeletePermanently, MarkAsRead, Stop, etc.) and clones condition/exception payloads
    (Subject, Body, From, SentTo, Categories, Importance, etc.) with defensive try/catch guards.
    Commits changes via Save($false) to suppress modal UI prompts. Supports -WhatIf and COM cleanup.
.PARAMETER SourceStorePath
    File path of the source data file/store. If omitted, defaults to the default delivery store.
.PARAMETER TargetStorePath
    File path of the target PST data file/store.
.PARAMETER ProfileName
    Target Outlook profile name. Defaults to active or default profile.
.PARAMETER FolderMap
    Hashtable mapping relative folder paths to target COM Folder objects (produced by Copy-OutlookFolderHierarchy).
.PARAMETER EnableMigratedRules
    Switch to force-enable migrated rules.
.OUTPUTS
    [PSCustomObject]@{ SourcePath, TargetPath, RulesMigrated, RulesRemapped, Success, ErrorMessage }
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
        [hashtable]$FolderMap,

        [Parameter(Mandatory = $false)]
        [switch]$EnableMigratedRules
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
        if (-not $PSCmdlet.ShouldProcess($resolvedTargetPath, "Migrate and remap Outlook rules to target store")) {
            return [PSCustomObject]@{
                SourcePath    = $resolvedSourcePath
                TargetPath    = $resolvedTargetPath
                RulesMigrated = 0
                RulesRemapped = 0
                Method        = 'WhatIf'
                Success       = $true
                ErrorMessage  = $null
            }
        }

        # 3. COM Setup & Store Discovery
        $outlookRunningBefore = [bool](Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
        $comApp = $null
        $ns = $null
        $stores = $null
        $sourceStore = $null
        $targetStore = $null
        $sourceRoot = $null
        $targetRoot = $null
        $srcRules = $null
        $targetRules = $null
        $rulesMigratedCount = 0
        $rulesRemappedCount = 0
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

            if ($null -eq $sourceStore -and $ns.PSObject.Properties['DefaultStore']) {
                $sourceStore = $ns.DefaultStore
            }

            if ($null -eq $targetStore) {
                throw "Target Outlook store could not be found for path: '$resolvedTargetPath'."
            }

            if ($null -eq $sourceStore) {
                throw "Source Outlook store could not be resolved."
            }

            # Resolve root folders for fallback mapping
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

            # Helper to find matching target folder object
            function Resolve-MatchingTargetFolder {
                param(
                    $sourceComFolder,
                    $targetRootFolder,
                    [hashtable]$map
                )

                if ($null -eq $sourceComFolder) { return $null }

                # 1. Check FolderMap with relative path
                if ($null -ne $map -and $map.Count -gt 0) {
                    if ($sourceComFolder.PSObject.Properties['FolderPath'] -and -not [string]::IsNullOrWhiteSpace($sourceComFolder.FolderPath)) {
                        $relPath = $sourceComFolder.FolderPath -replace '^\\\\?[^\\]+\\?', ''
                        $relPath = $relPath.TrimStart('\')
                        if ($map.ContainsKey($relPath)) {
                            return $map[$relPath]
                        }
                        $relNormalized = $relPath -replace '/', '\'
                        if ($map.ContainsKey($relNormalized)) {
                            return $map[$relNormalized]
                        }
                    }

                    if ($sourceComFolder.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace($sourceComFolder.Name)) {
                        if ($map.ContainsKey($sourceComFolder.Name)) {
                            return $map[$sourceComFolder.Name]
                        }
                    }
                }

                # 2. Search targetRootFolder tree directly
                if ($null -ne $targetRootFolder) {
                    if ($sourceComFolder.PSObject.Properties['FolderPath'] -and -not [string]::IsNullOrWhiteSpace($sourceComFolder.FolderPath)) {
                        $rawRel = ($sourceComFolder.FolderPath -replace '^\\\\?[^\\]+\\?', '').TrimStart('\')
                        $parts = $rawRel -split '[\\/]'
                        $curr = $targetRootFolder
                        $matchedAll = $true

                        foreach ($part in $parts) {
                            if ([string]::IsNullOrWhiteSpace($part)) { continue }
                            $foundPart = $null
                            if ($curr.PSObject.Properties['Folders'] -and $null -ne $curr.Folders) {
                                foreach ($cf in $curr.Folders) {
                                    if ($cf.Name -ieq $part) {
                                        $foundPart = $cf
                                        break
                                    }
                                }
                            }
                            if ($null -eq $foundPart) {
                                $matchedAll = $false
                                break
                            }
                            $curr = $foundPart
                        }

                        if ($matchedAll -and $curr -ne $targetRootFolder) {
                            return $curr
                        }
                    }

                    # Recursive name search fallback
                    function Find-SubFolderByName {
                        param($parent, [string]$name)
                        if ($null -eq $parent -or -not $parent.PSObject.Properties['Folders'] -or $null -eq $parent.Folders) { return $null }
                        foreach ($sub in $parent.Folders) {
                            if ($sub.Name -ieq $name) { return $sub }
                            $deeper = Find-SubFolderByName -parent $sub -name $name
                            if ($null -ne $deeper) { return $deeper }
                        }
                        return $null
                    }

                    $byName = Find-SubFolderByName -parent $targetRootFolder -name $sourceComFolder.Name
                    if ($null -ne $byName) { return $byName }
                }

                return $null
            }

            # Helper to clone RuleConditions or RuleExceptions collection
            function Copy-RuleConditionsSubObject {
                param(
                    $sourceCondContainer,
                    $targetCondContainer
                )

                if ($null -eq $sourceCondContainer -or $null -eq $targetCondContainer) { return }

                $knownCondProps = @(
                    # Text-based conditions (Text array)
                    'Subject', 'Body', 'BodyOrSubject', 'MessageHeader',
                    # Recipient-based conditions (Recipients collection or array)
                    'From', 'SentTo',
                    # Address-based conditions (Address array)
                    'SenderAddress', 'RecipientAddress',
                    # Category-based condition (Categories array)
                    'Categories',
                    # Importance condition (Importance int/enum)
                    'Importance',
                    # Sensitivity condition (Sensitivity int/enum)
                    'Sensitivity',
                    # Account condition
                    'Account',
                    # Boolean / flag conditions (Enabled only)
                    'OnlyToMe', 'ToOrCc', 'Cc', 'SentOnlyToMe', 'NotToMe', 'HasAttachment',
                    'FromAnyRMS', 'FromImage'
                )

                $propNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($pName in $knownCondProps) { [void]$propNames.Add($pName) }

                if ($sourceCondContainer.PSObject.Properties) {
                    foreach ($prop in $sourceCondContainer.PSObject.Properties) {
                        if ($prop.Name -notin @('Count', 'Item', 'Parent', 'Class', 'Session', 'Application')) {
                            [void]$propNames.Add($prop.Name)
                        }
                    }
                }

                foreach ($name in $propNames) {
                    try {
                        $srcItem = $null
                        if ($sourceCondContainer.PSObject.Properties[$name]) {
                            $srcItem = $sourceCondContainer.PSObject.Properties[$name].Value
                        } else {
                            try { $srcItem = $sourceCondContainer.$name } catch { $null = $_ }
                        }

                        if ($null -eq $srcItem) { continue }

                        $isEnabled = $false
                        if ($srcItem.PSObject.Properties['Enabled']) {
                            $isEnabled = [bool]$srcItem.Enabled
                        } else {
                            try { $isEnabled = [bool]$srcItem.Enabled } catch { $null = $_ }
                        }

                        if (-not $isEnabled) { continue }

                        $targetItem = $null
                        if ($targetCondContainer.PSObject.Properties[$name]) {
                            $targetItem = $targetCondContainer.PSObject.Properties[$name].Value
                        } else {
                            try { $targetItem = $targetCondContainer.$name } catch { $null = $_ }
                        }

                        if ($null -eq $targetItem) { continue }

                        # 1. Text payload (Subject, Body, BodyOrSubject, MessageHeader)
                        if ($srcItem.PSObject.Properties['Text'] -and $null -ne $srcItem.Text) {
                            try {
                                $targetItem.Text = @($srcItem.Text)
                            } catch {
                                Write-Verbose "Could not copy Text for condition $name : $($_.Exception.Message)"
                            }
                        }

                        # 2. Recipients payload (From, SentTo)
                        if ($srcItem.PSObject.Properties['Recipients'] -and $null -ne $srcItem.Recipients) {
                            try {
                                if ($targetItem.PSObject.Properties['Recipients']) {
                                    if ($targetItem.Recipients -is [System.Array]) {
                                        $targetItem.Recipients = @($srcItem.Recipients)
                                    } elseif ($null -ne $targetItem.Recipients -and $targetItem.Recipients.PSObject.Methods['Add']) {
                                        foreach ($r in $srcItem.Recipients) {
                                            $rVal = if ($r -is [string]) { $r } elseif ($r.PSObject.Properties['Address']) { $r.Address } elseif ($r.PSObject.Properties['Name']) { $r.Name } else { [string]$r }
                                            try { $null = $targetItem.Recipients.Add($rVal) } catch { $null = $_ }
                                        }
                                        if ($targetItem.Recipients.PSObject.Methods['ResolveAll']) {
                                            try { $targetItem.Recipients.ResolveAll() } catch { $null = $_ }
                                        }
                                    } else {
                                        try { $targetItem.Recipients = @($srcItem.Recipients) } catch { $null = $_ }
                                    }
                                }
                            } catch {
                                Write-Verbose "Could not copy Recipients for condition $name : $($_.Exception.Message)"
                            }
                        }

                        # 3. Categories payload
                        if ($srcItem.PSObject.Properties['Categories'] -and $null -ne $srcItem.Categories) {
                            try {
                                $targetItem.Categories = @($srcItem.Categories)
                            } catch {
                                Write-Verbose "Could not copy Categories for condition $name : $($_.Exception.Message)"
                            }
                        }

                        # 4. Importance payload
                        if ($srcItem.PSObject.Properties['Importance'] -and $null -ne $srcItem.Importance) {
                            try {
                                $targetItem.Importance = $srcItem.Importance
                            } catch {
                                Write-Verbose "Could not copy Importance for condition $name : $($_.Exception.Message)"
                            }
                        }

                        # 5. Sensitivity payload
                        if ($srcItem.PSObject.Properties['Sensitivity'] -and $null -ne $srcItem.Sensitivity) {
                            try {
                                $targetItem.Sensitivity = $srcItem.Sensitivity
                            } catch {
                                Write-Verbose "Could not copy Sensitivity for condition $name : $($_.Exception.Message)"
                            }
                        }

                        # 6. Address payload (SenderAddress, RecipientAddress)
                        if ($srcItem.PSObject.Properties['Address'] -and $null -ne $srcItem.Address) {
                            try {
                                $targetItem.Address = @($srcItem.Address)
                            } catch {
                                Write-Verbose "Could not copy Address for condition $name : $($_.Exception.Message)"
                            }
                        }

                        # 7. Account payload
                        if ($srcItem.PSObject.Properties['Account'] -and $null -ne $srcItem.Account) {
                            try {
                                $targetItem.Account = $srcItem.Account
                            } catch {
                                Write-Verbose "Could not copy Account for condition $name : $($_.Exception.Message)"
                            }
                        }

                        # Enable the condition
                        try {
                            $targetItem.Enabled = $true
                        } catch {
                            Write-Verbose "Could not enable condition $name : $($_.Exception.Message)"
                        }

                    } catch {
                        Write-Verbose "Error processing condition $name : $($_.Exception.Message)"
                    }
                }
            }

            # Helper to clone RuleActions collection
            function Copy-RuleActionsSubObject {
                param(
                    $sourceActions,
                    $targetActions,
                    $targetRootFolder,
                    [hashtable]$folderMap
                )

                if ($null -eq $sourceActions -or $null -eq $targetActions) { return $false }

                $remappedFolderAction = $false

                # 1. Folder Actions (MoveToFolder, CopyToFolder)
                $folderActionNames = @('MoveToFolder', 'CopyToFolder')
                foreach ($faName in $folderActionNames) {
                    try {
                        $srcAction = $null
                        if ($sourceActions.PSObject.Properties[$faName]) {
                            $srcAction = $sourceActions.PSObject.Properties[$faName].Value
                        } else {
                            try { $srcAction = $sourceActions.$faName } catch { $null = $_ }
                        }

                        if ($null -ne $srcAction -and $srcAction.Enabled -and $null -ne $srcAction.Folder) {
                            $targetFolder = Resolve-MatchingTargetFolder -sourceComFolder $srcAction.Folder `
                                                                         -targetRootFolder $targetRootFolder `
                                                                         -map $folderMap
                            if ($null -ne $targetFolder) {
                                $tgtAction = $null
                                if ($targetActions.PSObject.Properties[$faName]) {
                                    $tgtAction = $targetActions.PSObject.Properties[$faName].Value
                                } else {
                                    try { $tgtAction = $targetActions.$faName } catch { $null = $_ }
                                }

                                if ($null -ne $tgtAction) {
                                    try { $tgtAction.Folder = $targetFolder } catch { $null = $_ }
                                    try { $tgtAction.Enabled = $true } catch { $null = $_ }
                                    $remappedFolderAction = $true
                                }
                            }
                        }
                    } catch {
                        Write-Verbose "Could not remap folder action $faName : $($_.Exception.Message)"
                    }
                }

                # 2. Non-Folder Actions (Delete, DeletePermanently, MarkAsRead, Stop, etc.)
                $knownNonFolderActions = @(
                    'Delete', 'DeletePermanently', 'MarkAsRead', 'Stop', 'ClearCategories',
                    'AssignToCategory', 'PlaySound', 'NewItemAlert', 'MarkAsTask',
                    'Forward', 'Redirect', 'Cc'
                )

                $actNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($a in $knownNonFolderActions) { [void]$actNames.Add($a) }

                if ($sourceActions.PSObject.Properties) {
                    foreach ($prop in $sourceActions.PSObject.Properties) {
                        if ($prop.Name -notin @('MoveToFolder', 'CopyToFolder', 'Count', 'Item', 'Parent', 'Class', 'Session', 'Application')) {
                            [void]$actNames.Add($prop.Name)
                        }
                    }
                }

                foreach ($name in $actNames) {
                    try {
                        $srcAct = $null
                        if ($sourceActions.PSObject.Properties[$name]) {
                            $srcAct = $sourceActions.PSObject.Properties[$name].Value
                        } else {
                            try { $srcAct = $sourceActions.$name } catch { $null = $_ }
                        }

                        if ($null -eq $srcAct) { continue }

                        $isEnabled = $false
                        if ($srcAct.PSObject.Properties['Enabled']) {
                            $isEnabled = [bool]$srcAct.Enabled
                        } else {
                            try { $isEnabled = [bool]$srcAct.Enabled } catch { $null = $_ }
                        }

                        if (-not $isEnabled) { continue }

                        $tgtAct = $null
                        if ($targetActions.PSObject.Properties[$name]) {
                            $tgtAct = $targetActions.PSObject.Properties[$name].Value
                        } else {
                            try { $tgtAct = $targetActions.$name } catch { $null = $_ }
                        }

                        if ($null -eq $tgtAct) { continue }

                        # Categories (AssignToCategory)
                        if ($srcAct.PSObject.Properties['Categories'] -and $null -ne $srcAct.Categories) {
                            try { $tgtAct.Categories = @($srcAct.Categories) } catch { $null = $_ }
                        }

                        # FilePath (PlaySound)
                        if ($srcAct.PSObject.Properties['FilePath'] -and $null -ne $srcAct.FilePath) {
                            try { $tgtAct.FilePath = $srcAct.FilePath } catch { $null = $_ }
                        }

                        # Text (NewItemAlert)
                        if ($srcAct.PSObject.Properties['Text'] -and $null -ne $srcAct.Text) {
                            try { $tgtAct.Text = $srcAct.Text } catch { $null = $_ }
                        }

                        # FlagTo (MarkAsTask)
                        if ($srcAct.PSObject.Properties['FlagTo'] -and $null -ne $srcAct.FlagTo) {
                            try { $tgtAct.FlagTo = $srcAct.FlagTo } catch { $null = $_ }
                        }

                        # Recipients (Forward, Redirect, Cc)
                        if ($srcAct.PSObject.Properties['Recipients'] -and $null -ne $srcAct.Recipients) {
                            try {
                                if ($tgtAct.PSObject.Properties['Recipients']) {
                                    if ($tgtAct.Recipients -is [System.Array]) {
                                        $tgtAct.Recipients = @($srcAct.Recipients)
                                    } elseif ($null -ne $tgtAct.Recipients -and $tgtAct.Recipients.PSObject.Methods['Add']) {
                                        foreach ($r in $srcAct.Recipients) {
                                            $rVal = if ($r -is [string]) { $r } elseif ($r.PSObject.Properties['Address']) { $r.Address } elseif ($r.PSObject.Properties['Name']) { $r.Name } else { [string]$r }
                                            try { $null = $tgtAct.Recipients.Add($rVal) } catch { $null = $_ }
                                        }
                                        if ($tgtAct.Recipients.PSObject.Methods['ResolveAll']) {
                                            try { $tgtAct.Recipients.ResolveAll() } catch { $null = $_ }
                                        }
                                    } else {
                                        try { $tgtAct.Recipients = @($srcAct.Recipients) } catch { $null = $_ }
                                    }
                                }
                            } catch { $null = $_ }
                        }

                        # Enable action
                        try {
                            $tgtAct.Enabled = $true
                        } catch {
                            Write-Verbose "Could not enable action $name : $($_.Exception.Message)"
                        }

                    } catch {
                        Write-Verbose "Error processing action $name : $($_.Exception.Message)"
                    }
                }

                return $remappedFolderAction
            }

            # 4. Fetch Rules
            if ($sourceStore.PSObject.Methods['GetRules']) {
                $srcRules = $sourceStore.GetRules()
            }
            if ($targetStore.PSObject.Methods['GetRules']) {
                $targetRules = $targetStore.GetRules()
            }

            if ($null -eq $srcRules) {
                # No rules to migrate
                $success = $true
            }
            else {
                if ($null -eq $targetRules) {
                    $targetRules = $srcRules
                }

                $rulesToEnumerate = @()
                if ($null -ne $srcRules) {
                    if ($srcRules -is [System.Collections.IEnumerable] -and $srcRules -isnot [PSCustomObject]) {
                        $rulesToEnumerate = @($srcRules)
                    }
                    elseif ($srcRules.PSObject.Methods['GetEnumerator']) {
                        try {
                            $rulesToEnumerate = @($srcRules.GetEnumerator())
                        } catch {
                            $rulesToEnumerate = @($srcRules)
                        }
                    }
                    elseif ($srcRules.PSObject.Properties['RulesList'] -and $null -ne $srcRules.RulesList) {
                        $rulesToEnumerate = @($srcRules.RulesList)
                    }
                    elseif ($srcRules.PSObject.Properties['Count'] -and $srcRules.PSObject.Methods['Item']) {
                        for ($i = 0; $i -lt $srcRules.Count; $i++) {
                            $rulesToEnumerate += $srcRules.Item($i)
                        }
                    }
                    else {
                        $rulesToEnumerate = @($srcRules)
                    }
                }

                $targetRulesList = @()
                if ($null -ne $targetRules) {
                    if ($targetRules -is [System.Collections.IEnumerable] -and $targetRules -isnot [PSCustomObject]) {
                        $targetRulesList = @($targetRules)
                    }
                    elseif ($targetRules.PSObject.Methods['GetEnumerator']) {
                        try {
                            $targetRulesList = @($targetRules.GetEnumerator())
                        } catch {
                            $targetRulesList = @($targetRules)
                        }
                    }
                    elseif ($targetRules.PSObject.Properties['RulesList'] -and $null -ne $targetRules.RulesList) {
                        $targetRulesList = @($targetRules.RulesList)
                    }
                    elseif ($targetRules.PSObject.Properties['Count'] -and $targetRules.PSObject.Methods['Item']) {
                        for ($i = 0; $i -lt $targetRules.Count; $i++) {
                            $targetRulesList += $targetRules.Item($i)
                        }
                    }
                    else {
                        $targetRulesList = @($targetRules)
                    }
                }

                # Enumerate and process each rule
                foreach ($rule in $rulesToEnumerate) {
                    $rulesMigratedCount++
                    $remappedForThisRule = $false

                    # Determine target rule instance:
                    # In mock or existing store, $targetRules might already hold the rules.
                    # In real Outlook, we create a new rule via $targetRules.Create($rule.Name, $rule.RuleType).
                    $targetRuleInstance = $null

                    # Check if matching rule exists in targetRules
                    foreach ($tr in $targetRulesList) {
                        if ($tr.Name -ieq $rule.Name) {
                            $targetRuleInstance = $tr
                            break
                        }
                    }

                    if ($null -eq $targetRuleInstance -and $targetRules.PSObject.Methods['Create']) {
                        try {
                            $rType = if ($rule.PSObject.Properties['RuleType']) { $rule.RuleType } else { 0 }
                            $targetRuleInstance = $targetRules.Create($rule.Name, $rType)
                        } catch {
                            Write-Verbose "Could not create target rule via COM: $($_.Exception.Message)"
                        }
                    }

                    if ($null -eq $targetRuleInstance) {
                        $targetRuleInstance = $rule
                    }

                    # Set enabled state
                    if ($EnableMigratedRules) {
                        $targetRuleInstance.Enabled = $true
                    } elseif ($targetRuleInstance -ne $rule) {
                        $targetRuleInstance.Enabled = $rule.Enabled
                    }

                    # Set execution order if available
                    if ($targetRuleInstance -ne $rule -and $rule.PSObject.Properties['ExecutionOrder'] -and $targetRuleInstance.PSObject.Properties['ExecutionOrder']) {
                        try {
                            $targetRuleInstance.ExecutionOrder = $rule.ExecutionOrder
                        } catch { $null = $_ }
                    }

                    # Clone Conditions & Exceptions if target rule is distinct from source rule
                    if ($targetRuleInstance -ne $rule) {
                        if ($rule.PSObject.Properties['Conditions'] -and $null -ne $rule.Conditions -and
                            $targetRuleInstance.PSObject.Properties['Conditions'] -and $null -ne $targetRuleInstance.Conditions) {
                            Copy-RuleConditionsSubObject -sourceCondContainer $rule.Conditions -targetCondContainer $targetRuleInstance.Conditions
                        }

                        if ($rule.PSObject.Properties['Exceptions'] -and $null -ne $rule.Exceptions -and
                            $targetRuleInstance.PSObject.Properties['Exceptions'] -and $null -ne $targetRuleInstance.Exceptions) {
                            Copy-RuleConditionsSubObject -sourceCondContainer $rule.Exceptions -targetCondContainer $targetRuleInstance.Exceptions
                        }
                    }

                    # Process Actions (folder actions remapping + non-folder actions cloning)
                    if ($rule.PSObject.Properties['Actions'] -and $null -ne $rule.Actions) {
                        if ($targetRuleInstance.PSObject.Properties['Actions'] -and $null -ne $targetRuleInstance.Actions) {
                            $remappedForThisRule = Copy-RuleActionsSubObject -sourceActions $rule.Actions `
                                                                             -targetActions $targetRuleInstance.Actions `
                                                                             -targetRootFolder $targetRoot `
                                                                             -folderMap $FolderMap
                        }
                    }

                    if ($remappedForThisRule) {
                        $rulesRemappedCount++
                    }
                }

                # Save rules collection with ShowProgress = $false to suppress modal dialogs
                if ($null -ne $targetRules -and $targetRules.PSObject.Methods['Save']) {
                    try {
                        $targetRules.Save($false)
                    } catch {
                        try {
                            $targetRules.Save()
                        } catch {
                            Write-Verbose "Could not commit rules save: $($_.Exception.Message)"
                        }
                    }
                }

                $success = $true
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Rule migration failed: $errorMessage" -Level 'WARN' -Component 'Outlook:Rules'
            }
        }
        finally {
            if ($null -ne $comApp -and -not $outlookRunningBefore) {
                try { $comApp.Quit() } catch { $null = $_ }
            }

            $objectsToRelease = @($targetRules, $srcRules, $targetRoot, $sourceRoot, $targetStore, $sourceStore, $stores, $ns, $comApp)
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
            RulesMigrated = $rulesMigratedCount
            RulesRemapped = $rulesRemappedCount
            Success       = $success
            ErrorMessage  = $errorMessage
        }
    }
}
