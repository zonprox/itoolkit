function Export-OutlookRule {
<#
.SYNOPSIS
    Exports Outlook rules/filters and custom folder paths to a portable JSON manifest.
.DESCRIPTION
    Extracts Inbox rules, rule conditions, exceptions, and actions from a specified
    or default Outlook profile/store into a portable JSON manifest file. Normalizes
    target folder actions (MoveToFolder, CopyToFolder) into store-relative folder paths,
    captures custom folder hierarchies (excluding built-in root system folders), and records
    source profile/store context. Supports -WhatIf, -Force, -PassThru, and headless non-interactive execution.
.PARAMETER Path
    Destination file path for the .json rule manifest. If extension is omitted, .json is appended.
.PARAMETER ProfileName
    Outlook profile to query. If omitted, defaults to the default profile discovered via Get-OutlookSystemContext or 'Outlook'.
.PARAMETER StorePath
    Specific data file path (.pst or .ost) of the store to export rules from.
.PARAMETER StoreName
    Specific display name of the store to export rules from.
.PARAMETER IncludeHierarchy
    Scans and includes all custom folder hierarchy paths from the store into CustomFolders. Default: $true.
.PARAMETER Force
    Overwrites the destination manifest file if it already exists without throwing an error.
.PARAMETER PassThru
    Returns the generated manifest PSCustomObject to the pipeline in addition to writing the file.
.OUTPUTS
    [PSCustomObject]@{ Path, Profile, Store, RulesExported, CustomFoldersExported, FoldersCount, Success, Method, ErrorMessage }
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
        [string]$StorePath,

        [Parameter(Mandatory = $false)]
        [string]$StoreName,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeHierarchy = $true,

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    process {
        # 1. Path Normalization & Pre-Flight Checks
        $resolvedPath = [System.Environment]::ExpandEnvironmentVariables($Path.Trim())
        if ($ExecutionContext.SessionState.Path) {
            try {
                $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($resolvedPath)
            } catch {
                try {
                    $resolvedPath = [System.IO.Path]::GetFullPath($resolvedPath)
                } catch { $null = $_ }
            }
        } else {
            try {
                $resolvedPath = [System.IO.Path]::GetFullPath($resolvedPath)
            } catch { $null = $_ }
        }

        if (-not $resolvedPath.EndsWith('.json', [System.StringComparison]::OrdinalIgnoreCase)) {
            $resolvedPath = "$resolvedPath.json"
        }

        # 2. Resolve Profile Name
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

        # 3. SupportsShouldProcess Check (-WhatIf)
        if (-not $PSCmdlet.ShouldProcess($resolvedPath, "Export Outlook rules and folder hierarchy to JSON manifest")) {
            return [PSCustomObject]@{
                Path                  = $resolvedPath
                Profile               = $targetProfile
                Store                 = if (-not [string]::IsNullOrWhiteSpace($StoreName)) { $StoreName } else { $StorePath }
                RulesExported         = 0
                CustomFoldersExported = 0
                FoldersCount          = 0
                Success               = $true
                Method                = 'WhatIf'
                ErrorMessage          = $null
                ManifestVersion       = '1.0.0'
                SchemaVersion         = '1.0.0'
                SourceContext         = $null
                CustomFolders         = @()
                Rules                 = @()
            }
        }

        # 4. Check existing file without -Force
        if ((Test-Path -LiteralPath $resolvedPath) -and -not $Force) {
            $msg = "Destination manifest file already exists: '$resolvedPath'. Specify -Force to overwrite."
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message $msg -Level 'WARN' -Component 'Outlook:Export'
            }
            return [PSCustomObject]@{
                Path                  = $resolvedPath
                Profile               = $targetProfile
                Store                 = if (-not [string]::IsNullOrWhiteSpace($StoreName)) { $StoreName } else { $StorePath }
                RulesExported         = 0
                CustomFoldersExported = 0
                FoldersCount          = 0
                Success               = $false
                Method                = 'None'
                ErrorMessage          = $msg
                ManifestVersion       = '1.0.0'
                SchemaVersion         = '1.0.0'
                SourceContext         = $null
                CustomFolders         = @()
                Rules                 = @()
            }
        }

        # 5. Process State & COM Setup
        $outlookRunningBefore = [bool](Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
        $comApp = $null
        $ns = $null
        $stores = $null
        $store = $null
        $rootFolder = $null
        $rules = $null
        $didLogon = $false
        $success = $false
        $errorMessage = $null
        $rulesExportedCount = 0
        $customFoldersExportedCount = 0
        $storeDisplayName = $null
        $storeFilePath = $null
        $manifestObj = $null
        $customFoldersList = @()
        $rulesList = [System.Collections.Generic.List[object]]::new()
        $sourceContext = $null

        # 6. Helper: Convert RuleConditions / RuleExceptions to Dictionary
        function ConvertTo-RuleConditionsDictionary {
            param($condContainer)

            $dict = [ordered]@{}
            if ($null -eq $condContainer) { return $dict }

            $knownCondProps = @(
                'Subject', 'Body', 'BodyOrSubject', 'MessageHeader',
                'From', 'SentTo',
                'SenderAddress', 'RecipientAddress',
                'Categories',
                'Importance',
                'Sensitivity',
                'Account',
                'OnlyToMe', 'ToOrCc', 'Cc', 'SentOnlyToMe', 'NotToMe', 'HasAttachment',
                'FromAnyRMS', 'FromImage'
            )

            $propNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($p in $knownCondProps) { [void]$propNames.Add($p) }

            if ($condContainer.PSObject.Properties) {
                foreach ($prop in $condContainer.PSObject.Properties) {
                    if ($prop.Name -notin @('Count', 'Item', 'Parent', 'Class', 'Session', 'Application')) {
                        [void]$propNames.Add($prop.Name)
                    }
                }
            }

            foreach ($name in $propNames) {
                try {
                    $item = $null
                    if ($condContainer.PSObject.Properties[$name]) {
                        $item = $condContainer.PSObject.Properties[$name].Value
                    } else {
                        try { $item = $condContainer.$name } catch { $null = $_ }
                    }

                    if ($null -eq $item) { continue }

                    $isEnabled = $false
                    if ($item.PSObject.Properties['Enabled']) {
                        $isEnabled = [bool]$item.Enabled
                    }

                    $isCustomMock = ($condContainer -is [System.Management.Automation.PSCustomObject])
                    if (-not $isEnabled -and -not $isCustomMock) {
                        continue
                    }

                    $entry = [ordered]@{
                        Enabled = $isEnabled
                    }

                    # 1. Text payload
                    if ($item.PSObject.Properties['Text'] -and $null -ne $item.Text) {
                        $entry['Text'] = @($item.Text)
                    }

                    # 2. Recipients payload
                    if ($item.PSObject.Properties['Recipients'] -and $null -ne $item.Recipients) {
                        $recipList = @()
                        if ($item.Recipients -is [System.Collections.IEnumerable] -and $item.Recipients -isnot [string]) {
                            foreach ($r in $item.Recipients) {
                                if ($null -ne $r) {
                                    $rVal = if ($r -is [string]) { $r }
                                            elseif ($r.PSObject.Properties['Address'] -and -not [string]::IsNullOrWhiteSpace($r.Address)) { [string]$r.Address }
                                            elseif ($r.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace($r.Name)) { [string]$r.Name }
                                            else { [string]$r }
                                    if (-not [string]::IsNullOrWhiteSpace($rVal)) { $recipList += $rVal }
                                }
                            }
                        } elseif ($item.Recipients -is [string]) {
                            if (-not [string]::IsNullOrWhiteSpace($item.Recipients)) {
                                $recipList += [string]$item.Recipients
                            }
                        }
                        $entry['Recipients'] = @($recipList)
                    }

                    # 3. Categories payload
                    if ($item.PSObject.Properties['Categories'] -and $null -ne $item.Categories) {
                        $entry['Categories'] = @($item.Categories)
                    }

                    # 4. Importance payload
                    if ($item.PSObject.Properties['Importance'] -and $null -ne $item.Importance) {
                        $entry['Importance'] = [int]$item.Importance
                    }

                    # 5. Sensitivity payload
                    if ($item.PSObject.Properties['Sensitivity'] -and $null -ne $item.Sensitivity) {
                        $entry['Sensitivity'] = [int]$item.Sensitivity
                    }

                    # 6. Address payload
                    if ($item.PSObject.Properties['Address'] -and $null -ne $item.Address) {
                        $entry['Address'] = @($item.Address)
                    }

                    # 7. Account payload
                    if ($item.PSObject.Properties['Account'] -and $null -ne $item.Account) {
                        $accVal = if ($item.Account.PSObject.Properties['DisplayName']) { [string]$item.Account.DisplayName }
                                  elseif ($item.Account.PSObject.Properties['Name']) { [string]$item.Account.Name }
                                  else { [string]$item.Account }
                        $entry['Account'] = $accVal
                    }

                    $dict[$name] = $entry
                } catch {
                    Write-Verbose "Error serializing condition property '$name': $($_.Exception.Message)"
                }
            }

            return $dict
        }

        # 7. Helper: Convert RuleActions to Dictionary
        function ConvertTo-RuleActionsDictionary {
            param(
                $actionsContainer,
                [System.Collections.Generic.HashSet[string]]$referencedFolders
            )

            $dict = [ordered]@{}
            if ($null -eq $actionsContainer) { return $dict }

            # 1. Folder Actions (MoveToFolder, CopyToFolder)
            $folderActionNames = @('MoveToFolder', 'CopyToFolder')
            foreach ($faName in $folderActionNames) {
                $faItem = $null
                if ($actionsContainer.PSObject.Properties[$faName]) {
                    $faItem = $actionsContainer.PSObject.Properties[$faName].Value
                } else {
                    try { $faItem = $actionsContainer.$faName } catch { $null = $_ }
                }

                $isEnabled = $false
                $folderRelPath = $null
                if ($null -ne $faItem) {
                    if ($faItem.PSObject.Properties['Enabled']) {
                        $isEnabled = [bool]$faItem.Enabled
                    }
                    if ($null -ne $faItem.Folder) {
                        if ($faItem.Folder.PSObject.Properties['FolderPath'] -and -not [string]::IsNullOrWhiteSpace($faItem.Folder.FolderPath)) {
                            $folderRelPath = ($faItem.Folder.FolderPath -replace '^[\\/]+[^\\/]+[\\/]?', '').TrimStart('\/')
                        }
                        if ([string]::IsNullOrWhiteSpace($folderRelPath) -and $faItem.Folder.PSObject.Properties['Name']) {
                            $folderRelPath = [string]$faItem.Folder.Name
                        }
                        if (-not [string]::IsNullOrWhiteSpace($folderRelPath) -and $null -ne $referencedFolders) {
                            [void]$referencedFolders.Add($folderRelPath)
                        }
                    }
                }

                $dict[$faName] = [ordered]@{
                    Enabled    = $isEnabled
                    FolderPath = $folderRelPath
                }
            }

            # 2. Non-Folder Actions
            $knownNonFolderActions = @(
                'Delete', 'DeletePermanently', 'MarkAsRead', 'Stop', 'ClearCategories',
                'AssignToCategory', 'PlaySound', 'NewItemAlert', 'MarkAsTask',
                'Forward', 'Redirect', 'Cc'
            )

            $propNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($a in $knownNonFolderActions) { [void]$propNames.Add($a) }

            if ($actionsContainer.PSObject.Properties) {
                foreach ($prop in $actionsContainer.PSObject.Properties) {
                    if ($prop.Name -notin @('MoveToFolder', 'CopyToFolder', 'Count', 'Item', 'Parent', 'Class', 'Session', 'Application')) {
                        [void]$propNames.Add($prop.Name)
                    }
                }
            }

            foreach ($name in $propNames) {
                try {
                    $act = $null
                    if ($actionsContainer.PSObject.Properties[$name]) {
                        $act = $actionsContainer.PSObject.Properties[$name].Value
                    } else {
                        try { $act = $actionsContainer.$name } catch { $null = $_ }
                    }

                    if ($null -eq $act) { continue }

                    $isEnabled = $false
                    if ($act.PSObject.Properties['Enabled']) {
                        $isEnabled = [bool]$act.Enabled
                    }

                    $isCustomMock = ($actionsContainer -is [System.Management.Automation.PSCustomObject])
                    if (-not $isEnabled -and -not $isCustomMock) {
                        continue
                    }

                    $entry = [ordered]@{
                        Enabled = $isEnabled
                    }

                    # Categories
                    if ($act.PSObject.Properties['Categories'] -and $null -ne $act.Categories) {
                        $entry['Categories'] = @($act.Categories)
                    }

                    # FilePath
                    if ($act.PSObject.Properties['FilePath'] -and $null -ne $act.FilePath) {
                        $entry['FilePath'] = [string]$act.FilePath
                    }

                    # Text
                    if ($act.PSObject.Properties['Text'] -and $null -ne $act.Text) {
                        $entry['Text'] = [string]$act.Text
                    }

                    # FlagTo
                    if ($act.PSObject.Properties['FlagTo'] -and $null -ne $act.FlagTo) {
                        $entry['FlagTo'] = [string]$act.FlagTo
                    }

                    # Recipients
                    if ($act.PSObject.Properties['Recipients'] -and $null -ne $act.Recipients) {
                        $recipList = @()
                        if ($act.Recipients -is [System.Collections.IEnumerable] -and $act.Recipients -isnot [string]) {
                            foreach ($r in $act.Recipients) {
                                if ($null -ne $r) {
                                    $rVal = if ($r -is [string]) { $r }
                                            elseif ($r.PSObject.Properties['Address'] -and -not [string]::IsNullOrWhiteSpace($r.Address)) { [string]$r.Address }
                                            elseif ($r.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace($r.Name)) { [string]$r.Name }
                                            else { [string]$r }
                                    if (-not [string]::IsNullOrWhiteSpace($rVal)) { $recipList += $rVal }
                                }
                            }
                        } elseif ($act.Recipients -is [string]) {
                            if (-not [string]::IsNullOrWhiteSpace($act.Recipients)) {
                                $recipList += [string]$act.Recipients
                            }
                        }
                        $entry['Recipients'] = @($recipList)
                    }

                    $dict[$name] = $entry
                } catch {
                    Write-Verbose "Error serializing action '$name': $($_.Exception.Message)"
                }
            }

            return $dict
        }

        # 8. Helper: Recursive Custom SubFolder Scanning
        function Scan-SubFoldersRecursively {
            param(
                $parentFolder,
                [string]$pathPrefix,
                [System.Collections.Generic.HashSet[string]]$folderSet
            )

            if ($null -eq $parentFolder -or -not $parentFolder.PSObject.Properties['Folders'] -or $null -eq $parentFolder.Folders) {
                return
            }

            foreach ($child in $parentFolder.Folders) {
                if ($null -eq $child) { continue }
                $cName = if ($child.PSObject.Properties['Name']) { [string]$child.Name } else { '' }
                if ([string]::IsNullOrWhiteSpace($cName)) { continue }

                $relPath = if ([string]::IsNullOrWhiteSpace($pathPrefix)) { $cName } else { "$pathPrefix\$cName" }
                [void]$folderSet.Add($relPath)

                Scan-SubFoldersRecursively -parentFolder $child -pathPrefix $relPath -folderSet $folderSet
            }
        }

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

            # 9. Store Discovery & Selection
            $resolvedStorePath = $null
            if (-not [string]::IsNullOrWhiteSpace($StorePath)) {
                $resolvedStorePath = [System.Environment]::ExpandEnvironmentVariables($StorePath.Trim())
                if (-not ($resolvedStorePath -match '^[a-zA-Z]:[/\\]' -and [System.IO.Path]::DirectorySeparatorChar -ne [char]92)) {
                    try {
                        $resolvedStorePath = [System.IO.Path]::GetFullPath($resolvedStorePath)
                    } catch { $null = $_ }
                }
            }

            if ($ns.PSObject.Properties['Stores'] -and $null -ne $ns.Stores) {
                $stores = $ns.Stores
                foreach ($s in $stores) {
                    if ($null -eq $s) { continue }
                    $sp = if ($s.PSObject.Properties['FilePath'] -and $s.FilePath) { [string]$s.FilePath } else { '' }
                    $dn = if ($s.PSObject.Properties['DisplayName'] -and $s.DisplayName) { [string]$s.DisplayName } else { '' }

                    # Match by StorePath
                    if (-not [string]::IsNullOrWhiteSpace($resolvedStorePath)) {
                        if ($sp -ieq $resolvedStorePath -or $sp -ieq $StorePath) {
                            $store = $s
                            break
                        }
                    }
                    # Match by StoreName
                    elseif (-not [string]::IsNullOrWhiteSpace($StoreName)) {
                        if ($dn -ieq $StoreName -or ($s.PSObject.Properties['Name'] -and $s.Name -ieq $StoreName)) {
                            $store = $s
                            break
                        }
                    }
                    # Default store match
                    elseif ($s.PSObject.Properties['IsDefaultStore'] -and $s.IsDefaultStore) {
                        $store = $s
                        break
                    }
                }
            }

            # If no store matched and user did not specify StorePath or StoreName, check DefaultStore
            if ($null -eq $store -and [string]::IsNullOrWhiteSpace($StorePath) -and [string]::IsNullOrWhiteSpace($StoreName)) {
                if ($ns.PSObject.Properties['DefaultStore'] -and $null -ne $ns.DefaultStore) {
                    $store = $ns.DefaultStore
                }
            }

            if ($null -eq $store) {
                $storeTargetName = if (-not [string]::IsNullOrWhiteSpace($StorePath)) {
                    "path '$StorePath'"
                } elseif (-not [string]::IsNullOrWhiteSpace($StoreName)) {
                    "name '$StoreName'"
                } else {
                    "profile '$targetProfile'"
                }
                throw "Outlook store was not found for $storeTargetName."
            }

            $storeDisplayName = if ($store.PSObject.Properties['DisplayName'] -and -not [string]::IsNullOrWhiteSpace($store.DisplayName)) {
                [string]$store.DisplayName
            } elseif ($store.PSObject.Properties['Name']) {
                [string]$store.Name
            } else {
                $targetProfile
            }

            $storeFilePath = if ($store.PSObject.Properties['FilePath'] -and -not [string]::IsNullOrWhiteSpace($store.FilePath)) {
                [string]$store.FilePath
            } else {
                $resolvedStorePath
            }

            # 10. Resolve Root Folder
            if ($store.PSObject.Methods['GetRootFolder']) {
                $rootFolder = $store.GetRootFolder()
            } elseif ($store.PSObject.Properties['RootFolder']) {
                $rootFolder = $store.RootFolder
            }

            # 11. Enumerate and Serialize Rules
            if ($store.PSObject.Methods['GetRules']) {
                $rules = $store.GetRules()
            } elseif ($store.PSObject.Properties['Rules']) {
                $rules = $store.Rules
            }

            $rulesToEnumerate = @()
            if ($null -ne $rules) {
                if ($rules.PSObject.Properties['RulesList'] -and $null -ne $rules.RulesList) {
                    $rulesToEnumerate = @($rules.RulesList)
                }
                elseif ($rules.PSObject.Methods['GetEnumerator']) {
                    try {
                        $rulesToEnumerate = @($rules.GetEnumerator())
                    } catch {
                        $rulesToEnumerate = @($rules)
                    }
                }
                elseif ($rules.PSObject.Properties['Count'] -and $rules.PSObject.Methods['Item']) {
                    try {
                        for ($i = 1; $i -le $rules.Count; $i++) {
                            $rulesToEnumerate += $rules.Item($i)
                        }
                    } catch {
                        try {
                            for ($i = 0; $i -lt $rules.Count; $i++) {
                                $rulesToEnumerate += $rules.Item($i)
                            }
                        } catch { $null = $_ }
                    }
                }
                else {
                    $rulesToEnumerate = @($rules)
                }
            }

            $referencedFolders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

            foreach ($rule in $rulesToEnumerate) {
                if ($null -eq $rule) { continue }

                $rName = if ($rule.PSObject.Properties['Name']) { [string]$rule.Name } else { "Rule_$($rulesList.Count + 1)" }
                $rType = if ($rule.PSObject.Properties['RuleType']) { [int]$rule.RuleType } else { 0 }
                $execOrder = if ($rule.PSObject.Properties['ExecutionOrder']) { [int]$rule.ExecutionOrder } else { 0 }
                $rEnabled = if ($rule.PSObject.Properties['Enabled']) { [bool]$rule.Enabled } else { $true }

                $condDict = if ($rule.PSObject.Properties['Conditions'] -and $null -ne $rule.Conditions) {
                    ConvertTo-RuleConditionsDictionary -condContainer $rule.Conditions
                } else {
                    [ordered]@{}
                }

                $excpDict = if ($rule.PSObject.Properties['Exceptions'] -and $null -ne $rule.Exceptions) {
                    ConvertTo-RuleConditionsDictionary -condContainer $rule.Exceptions
                } else {
                    [ordered]@{}
                }

                $actDict = if ($rule.PSObject.Properties['Actions'] -and $null -ne $rule.Actions) {
                    ConvertTo-RuleActionsDictionary -actionsContainer $rule.Actions -referencedFolders $referencedFolders
                } else {
                    [ordered]@{}
                }

                $serializedRule = [ordered]@{
                    Name           = $rName
                    RuleType       = $rType
                    ExecutionOrder = $execOrder
                    Enabled        = $rEnabled
                    Conditions     = $condDict
                    Exceptions     = $excpDict
                    Actions        = $actDict
                }

                $rulesList.Add($serializedRule)
            }
            $rulesExportedCount = $rulesList.Count

            # 12. Enumerate Custom Folder Hierarchy
            $customFolderSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

            $systemFolderNames = @(
                'Deleted Items', 'Drafts', 'Outbox', 'Sent Items', 'Junk Email',
                'Junk E-mail', 'Calendar', 'Contacts', 'Journal', 'Notes', 'Tasks',
                'RSS Feeds', 'RSS Subscriptions', 'Conversation History',
                'Quick Step Settings', 'Newsfeed', 'Sync Issues', 'Conflicts',
                'Local Failures', 'Server Failures', 'External Contacts', 'Yammer Root', 'Search Folders'
            )

            if ($IncludeHierarchy) {
                if ($null -ne $rootFolder -and $rootFolder.PSObject.Properties['Folders'] -and $null -ne $rootFolder.Folders) {
                    foreach ($rootItem in $rootFolder.Folders) {
                        if ($null -eq $rootItem) { continue }
                        $rName = if ($rootItem.PSObject.Properties['Name']) { [string]$rootItem.Name } else { '' }
                        if ([string]::IsNullOrWhiteSpace($rName)) { continue }

                        if ($rName -ieq 'Inbox') {
                            Scan-SubFoldersRecursively -parentFolder $rootItem -pathPrefix 'Inbox' -folderSet $customFolderSet
                        }
                        elseif ($systemFolderNames -contains $rName) {
                            continue
                        }
                        else {
                            [void]$customFolderSet.Add($rName)
                            Scan-SubFoldersRecursively -parentFolder $rootItem -pathPrefix $rName -folderSet $customFolderSet
                        }
                    }
                }

                # Merge any target folders referenced in rule actions
                foreach ($rf in $referencedFolders) {
                    if (-not [string]::IsNullOrWhiteSpace($rf)) {
                        [void]$customFolderSet.Add($rf)
                    }
                }
            }

            $customFoldersList = @($customFolderSet | Sort-Object)
            $customFoldersExportedCount = $customFoldersList.Count

            # 13. Compile Source Context & Telemetry
            $primaryAccountName = $storeDisplayName
            $primarySmtpAddress = $null
            if ($ns.PSObject.Properties['Accounts'] -and $null -ne $ns.Accounts) {
                foreach ($acc in $ns.Accounts) {
                    if ($null -ne $acc) {
                        if ($acc.PSObject.Properties['DisplayName'] -and -not [string]::IsNullOrWhiteSpace($acc.DisplayName)) {
                            $primaryAccountName = [string]$acc.DisplayName
                        }
                        if ($acc.PSObject.Properties['SmtpAddress'] -and -not [string]::IsNullOrWhiteSpace($acc.SmtpAddress)) {
                            $primarySmtpAddress = [string]$acc.SmtpAddress
                            break
                        }
                    }
                }
            }
            if ([string]::IsNullOrWhiteSpace($primarySmtpAddress)) {
                $primarySmtpAddress = if ($primaryAccountName -match '@') { $primaryAccountName } else { "$primaryAccountName@local" }
            }

            $officeVersion = '16.0'
            if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
                try {
                    $sys = Get-OutlookSystemContext
                    if ($null -ne $sys -and -not [string]::IsNullOrWhiteSpace($sys.Version)) {
                        $officeVersion = [string]$sys.Version
                    }
                } catch { $null = $_ }
            }

            $sourceContext = [ordered]@{
                ProfileName        = $targetProfile
                StoreName          = $storeDisplayName
                StoreDisplayName   = $storeDisplayName
                StoreFilePath      = $storeFilePath
                AccountName        = $primaryAccountName
                PrimarySmtpAddress = $primarySmtpAddress
                OfficeVersion      = $officeVersion
            }

            # 14. Assemble Manifest Object
            $manifestObj = [ordered]@{
                '$schema'         = 'http://json-schema.org/draft-07/schema#'
                ManifestVersion   = '1.0.0'
                SchemaVersion     = '1.0.0'
                ExportTimestamp   = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
                ExportedBy        = 'IToolkit'
                SourceContext     = $sourceContext
                CustomFolders     = $customFoldersList
                Rules             = @($rulesList)
            }

            # 15. Write JSON Manifest to File
            $targetDir = Split-Path -Path $resolvedPath -Parent
            if (-not [string]::IsNullOrWhiteSpace($targetDir) -and -not (Test-Path -LiteralPath $targetDir)) {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            }

            $jsonString = $manifestObj | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText($resolvedPath, $jsonString, [System.Text.Encoding]::UTF8)

            $success = $true
        }
        catch {
            $errorMessage = $_.Exception.Message
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Outlook rule export failed: $errorMessage" -Level 'WARN' -Component 'Outlook:Export'
            }
        }
        finally {
            if ($didLogon -and $null -ne $ns) {
                try { $ns.Logoff() } catch { $null = $_ }
            }

            if ($null -ne $comApp -and -not $outlookRunningBefore) {
                try { $comApp.Quit() } catch { $null = $_ }
            }

            $objectsToRelease = @($rules, $rootFolder, $store, $stores, $ns, $comApp)
            if (Get-Command -Name 'Remove-ToolkitComObject' -ErrorAction SilentlyContinue) {
                Remove-ToolkitComObject -ComObjects $objectsToRelease
            }
            else {
                foreach ($obj in $objectsToRelease) {
                    if ($null -ne $obj -and [System.Runtime.InteropServices.Marshal]::IsComObject($obj)) {
                        try {
                            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($obj) | Out-Null
                        } catch { $null = $_ }
                    }
                }
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
                [System.GC]::Collect()
            }
        }

        # 16. Return Structured Result
        $method = if ($success) { 'COM' } else { 'None' }

        return [PSCustomObject]@{
            Path                  = $resolvedPath
            Profile               = $targetProfile
            Store                 = $storeDisplayName
            RulesExported         = $rulesExportedCount
            CustomFoldersExported = $customFoldersExportedCount
            FoldersCount          = $customFoldersExportedCount
            Success               = $success
            Method                = $method
            ErrorMessage          = $errorMessage
            ManifestVersion       = if ($null -ne $manifestObj) { $manifestObj.ManifestVersion } else { '1.0.0' }
            SchemaVersion         = if ($null -ne $manifestObj) { $manifestObj.SchemaVersion } else { '1.0.0' }
            SourceContext         = if ($null -ne $manifestObj) { $manifestObj.SourceContext } else { $sourceContext }
            CustomFolders         = if ($null -ne $manifestObj) { $manifestObj.CustomFolders } else { $customFoldersList }
            Rules                 = if ($null -ne $manifestObj) { $manifestObj.Rules } else { @($rulesList) }
        }
    }
}
