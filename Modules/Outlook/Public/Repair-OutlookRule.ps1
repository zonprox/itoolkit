function Repair-OutlookRule {
<#
.SYNOPSIS
    Diagnoses and repairs broken, duplicate, or empty Outlook rules.
.DESCRIPTION
    Scans Inbox rules in a specified Outlook store and profile to detect broken
    MoveToFolder and CopyToFolder actions (null folder, COM exception, or unmounted store),
    duplicate rules (identical conditions and actions), and empty rules (zero active conditions
    and actions). In scan-only mode, outputs a diagnostic report without mutations. With -AutoRepair,
    recreates missing folder hierarchies, rebinds broken actions, prunes duplicates and empty rules,
    and commits changes silently via Save($false). Supports -WhatIf and deterministic COM lifecycle cleanup.
.PARAMETER StorePath
    Specific data file path (.pst or .ost) of the store to diagnose and repair.
.PARAMETER ProfileName
    Outlook profile to query. If omitted, uses default profile or active session.
.PARAMETER StoreName
    Specific display name of the store to diagnose and repair.
.PARAMETER AutoRepair
    Performs automated self-healing: recreates missing target folders, rebinds actions,
    and prunes duplicate and empty rules.
.PARAMETER RemoveDuplicates
    Prunes duplicate rules matching previously seen conditions and actions.
.PARAMETER RemoveEmpty
    Prunes empty rules having zero active conditions and zero active actions.
.PARAMETER DefaultFallbackFolder
    Default root/folder under which to recreate missing target folders if no name can be inferred. Default: 'Inbox'.
.OUTPUTS
    [PSCustomObject]@{ StorePath, StoreName, ProfileName, RulesScanned, TotalRules, BrokenRules, DuplicateRules, EmptyRules, DisabledRules, RepairedRulesCount, RemovedDuplicates, RemovedDuplicatesCount, RemovedEmptyCount, Method, Success, ErrorMessage }
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [Alias('Test-OutlookRule')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0, ValueFromPipelineByPropertyName = $true)]
        [string]$StorePath,

        [Parameter(Mandatory = $false, Position = 1, ValueFromPipelineByPropertyName = $true)]
        [string]$ProfileName,

        [Parameter(Mandatory = $false)]
        [string]$StoreName,

        [Parameter(Mandatory = $false)]
        [switch]$AutoRepair,

        [Parameter(Mandatory = $false)]
        [switch]$RemoveDuplicates,

        [Parameter(Mandatory = $false)]
        [switch]$RemoveEmpty,

        [Parameter(Mandatory = $false)]
        [string]$DefaultFallbackFolder = 'Inbox'
    )

    process {
        # 1. Normalize Store Path
        $resolvedStorePath = $null
        if (-not [string]::IsNullOrWhiteSpace($StorePath)) {
            $resolvedStorePath = [System.Environment]::ExpandEnvironmentVariables($StorePath.Trim())
            if ($ExecutionContext.SessionState.Path) {
                try {
                    $resolvedStorePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($resolvedStorePath)
                } catch {
                    try { $resolvedStorePath = [System.IO.Path]::GetFullPath($resolvedStorePath) } catch { $null = $_ }
                }
            } else {
                try { $resolvedStorePath = [System.IO.Path]::GetFullPath($resolvedStorePath) } catch { $null = $_ }
            }
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

        $targetStoreDesc = if (-not [string]::IsNullOrWhiteSpace($StoreName)) {
            $StoreName
        } elseif (-not [string]::IsNullOrWhiteSpace($resolvedStorePath)) {
            $resolvedStorePath
        } else {
            $targetProfile
        }

        # 3. SupportsShouldProcess Check (-WhatIf)
        $actionDesc = if ($AutoRepair -or $RemoveDuplicates -or $RemoveEmpty) {
            "Diagnose and auto-repair Outlook rules (AutoRepair: $AutoRepair, RemoveDuplicates: $RemoveDuplicates, RemoveEmpty: $RemoveEmpty)"
        } else {
            "Scan and diagnose Outlook rules (ScanOnly mode)"
        }

        if (-not $PSCmdlet.ShouldProcess($targetStoreDesc, $actionDesc)) {
            return [PSCustomObject]@{
                StorePath              = $resolvedStorePath
                StoreName              = $StoreName
                ProfileName            = $targetProfile
                RulesScanned           = 0
                TotalRules             = 0
                BrokenRules            = @()
                DuplicateRules         = @()
                EmptyRules             = @()
                DisabledRules          = @()
                RepairedRulesCount     = 0
                RemovedDuplicates      = 0
                RemovedDuplicatesCount = 0
                RemovedEmptyCount      = 0
                Method                 = 'WhatIf'
                Success                = $true
                ErrorMessage           = $null
            }
        }

        # 4. Process State & COM Setup
        $outlookRunningBefore = [bool](Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
        $comApp = $null
        $ns = $null
        $stores = $null
        $store = $null
        $rootFolder = $null
        $inboxFolder = $null
        $rules = $null
        $didLogon = $false
        $success = $false
        $errorMessage = $null

        $brokenRules = [System.Collections.Generic.List[object]]::new()
        $duplicateRules = [System.Collections.Generic.List[object]]::new()
        $emptyRules = [System.Collections.Generic.List[object]]::new()
        $disabledRules = [System.Collections.Generic.List[string]]::new()
        $rulesScanned = 0
        $repairedCount = 0
        $removedDuplicatesCount = 0
        $removedEmptyCount = 0
        $storeDisplayName = $null
        $mutationsPerformed = $false

        # Internal Folder Helpers
        function script:Add-StoreFolder {
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

        function script:Find-StoreFolder {
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

        function script:Ensure-StoreFolder {
            param($parent, [string]$name)
            $found = script:Find-StoreFolder -parent $parent -name $name
            if ($null -ne $found) {
                return @{ Folder = $found; Created = $false }
            }
            $created = script:Add-StoreFolder -parent $parent -name $name
            return @{ Folder = $created; Created = ($null -ne $created) }
        }

        # Internal Rule Collection Helpers
        function script:Get-RuleByIndex {
            param($rulesObj, [int]$idx)
            try {
                if ($rulesObj.PSObject.Methods['Item']) {
                    try {
                        $r = $rulesObj.Item($idx)
                        if ($null -ne $r) { return $r }
                    } catch {
                        try {
                            $r = $rulesObj.Item($idx - 1)
                            if ($null -ne $r) { return $r }
                        } catch { $null = $_ }
                    }
                }
                if ($rulesObj.PSObject.Properties['RulesList'] -and $null -ne $rulesObj.RulesList) {
                    $list = $rulesObj.RulesList
                    if ($idx -ge 1 -and ($idx - 1) -lt $list.Count) { return $list[$idx - 1] }
                }
            } catch { $null = $_ }
            return $null
        }

        function script:Remove-RuleByIndex {
            param($rulesObj, [int]$idx)
            if ($rulesObj.PSObject.Methods['Remove']) {
                try {
                    $rulesObj.Remove($idx)
                } catch {
                    try { $rulesObj.Remove($idx - 1) } catch { $null = $_ }
                }
            } elseif ($rulesObj.PSObject.Properties['RulesList'] -and $rulesObj.RulesList -is [System.Collections.IList]) {
                try {
                    $rulesObj.RulesList.RemoveAt($idx - 1)
                    if ($rulesObj.PSObject.Properties['Count']) {
                        $rulesObj.Count = $rulesObj.RulesList.Count
                    }
                } catch { $null = $_ }
            }
        }

        # Canonical Signature Generation Helper
        function script:Get-OutlookRuleCanonicalSignature {
            param(
                [Parameter(Mandatory = $true)]
                $Rule
            )

            if ($null -eq $Rule) { return [string]::Empty }

            $typeStr = if ($Rule.PSObject.Properties['RuleType']) { [string]$Rule.RuleType } else { '0' }

            # 1. Canonicalize Conditions
            $condParts = [System.Collections.Generic.List[string]]::new()
            if ($Rule.PSObject.Properties['Conditions'] -and $null -ne $Rule.Conditions) {
                $conds = $Rule.Conditions
                if ($conds.PSObject.Properties) {
                    foreach ($prop in $conds.PSObject.Properties) {
                        $item = $prop.Value
                        if ($null -eq $item -or -not ($item.PSObject.Properties['Enabled'] -and $item.Enabled)) { continue }
                        $pName = $prop.Name.ToLowerInvariant()

                        # Text payload (Subject, Body, BodyOrSubject, MessageHeader)
                        if ($item.PSObject.Properties['Text'] -and $null -ne $item.Text) {
                            $sortedText = @($item.Text | ForEach-Object { if ($null -ne $_) { $_.ToString().Trim().ToLowerInvariant() } } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
                            if ($sortedText.Count -gt 0) {
                                $condParts.Add("text:$pName=" + ($sortedText -join ','))
                            }
                        }
                        # Recipients payload (From, SentTo)
                        elseif ($item.PSObject.Properties['Recipients'] -and $null -ne $item.Recipients) {
                            $recips = @()
                            if ($item.Recipients -is [System.Collections.IEnumerable] -and $item.Recipients -isnot [string]) {
                                foreach ($r in $item.Recipients) {
                                    if ($null -ne $r) {
                                        $rStr = if ($r -is [string]) { $r }
                                                elseif ($r.PSObject.Properties['Address'] -and -not [string]::IsNullOrWhiteSpace($r.Address)) { [string]$r.Address }
                                                elseif ($r.PSObject.Properties['Name']) { [string]$r.Name }
                                                else { [string]$r }
                                        if (-not [string]::IsNullOrWhiteSpace($rStr)) { $recips += $rStr.Trim().ToLowerInvariant() }
                                    }
                                }
                            } elseif ($item.Recipients -is [string] -and -not [string]::IsNullOrWhiteSpace($item.Recipients)) {
                                $recips += $item.Recipients.Trim().ToLowerInvariant()
                            }
                            $sortedRecips = @($recips | Sort-Object -Unique)
                            if ($sortedRecips.Count -gt 0) {
                                $condParts.Add("recip:$pName=" + ($sortedRecips -join ','))
                            }
                        }
                        # Categories payload
                        elseif ($item.PSObject.Properties['Categories'] -and $null -ne $item.Categories) {
                            $sortedCats = @($item.Categories | ForEach-Object { if ($null -ne $_) { $_.ToString().Trim().ToLowerInvariant() } } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
                            if ($sortedCats.Count -gt 0) {
                                $condParts.Add("cat:$pName=" + ($sortedCats -join ','))
                            }
                        }
                        # Importance payload
                        elseif ($item.PSObject.Properties['Importance'] -and $null -ne $item.Importance) {
                            $condParts.Add("imp:$pName=" + [string]$item.Importance)
                        }
                        # Sensitivity payload
                        elseif ($item.PSObject.Properties['Sensitivity'] -and $null -ne $item.Sensitivity) {
                            $condParts.Add("sens:$pName=" + [string]$item.Sensitivity)
                        }
                        # Account payload
                        elseif ($item.PSObject.Properties['Account'] -and $null -ne $item.Account) {
                            $accName = if ($item.Account.PSObject.Properties['DisplayName']) { [string]$item.Account.DisplayName }
                                       elseif ($item.Account.PSObject.Properties['Name']) { [string]$item.Account.Name }
                                       else { [string]$item.Account }
                            $condParts.Add("acc:$pName=" + $accName.Trim().ToLowerInvariant())
                        }
                        # Simple boolean conditions
                        else {
                            $condParts.Add("bool:$pName=true")
                        }
                    }
                }
            }
            $sortedConds = @($condParts | Sort-Object)

            # 2. Canonicalize Exceptions
            $excpParts = [System.Collections.Generic.List[string]]::new()
            if ($Rule.PSObject.Properties['Exceptions'] -and $null -ne $Rule.Exceptions) {
                $excps = $Rule.Exceptions
                if ($excps.PSObject.Properties) {
                    foreach ($prop in $excps.PSObject.Properties) {
                        $item = $prop.Value
                        if ($null -eq $item -or -not ($item.PSObject.Properties['Enabled'] -and $item.Enabled)) { continue }
                        $pName = $prop.Name.ToLowerInvariant()

                        if ($item.PSObject.Properties['Text'] -and $null -ne $item.Text) {
                            $sortedText = @($item.Text | ForEach-Object { if ($null -ne $_) { $_.ToString().Trim().ToLowerInvariant() } } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
                            if ($sortedText.Count -gt 0) {
                                $excpParts.Add("text:$pName=" + ($sortedText -join ','))
                            }
                        }
                        elseif ($item.PSObject.Properties['Recipients'] -and $null -ne $item.Recipients) {
                            $recips = @()
                            if ($item.Recipients -is [System.Collections.IEnumerable] -and $item.Recipients -isnot [string]) {
                                foreach ($r in $item.Recipients) {
                                    if ($null -ne $r) {
                                        $rStr = if ($r -is [string]) { $r }
                                                elseif ($r.PSObject.Properties['Address'] -and -not [string]::IsNullOrWhiteSpace($r.Address)) { [string]$r.Address }
                                                elseif ($r.PSObject.Properties['Name']) { [string]$r.Name }
                                                else { [string]$r }
                                        if (-not [string]::IsNullOrWhiteSpace($rStr)) { $recips += $rStr.Trim().ToLowerInvariant() }
                                    }
                                }
                            } elseif ($item.Recipients -is [string] -and -not [string]::IsNullOrWhiteSpace($item.Recipients)) {
                                $recips += $item.Recipients.Trim().ToLowerInvariant()
                            }
                            $sortedRecips = @($recips | Sort-Object -Unique)
                            if ($sortedRecips.Count -gt 0) {
                                $excpParts.Add("recip:$pName=" + ($sortedRecips -join ','))
                            }
                        }
                        elseif ($item.PSObject.Properties['Categories'] -and $null -ne $item.Categories) {
                            $sortedCats = @($item.Categories | ForEach-Object { if ($null -ne $_) { $_.ToString().Trim().ToLowerInvariant() } } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
                            if ($sortedCats.Count -gt 0) {
                                $excpParts.Add("cat:$pName=" + ($sortedCats -join ','))
                            }
                        }
                        else {
                            $excpParts.Add("bool:$pName=true")
                        }
                    }
                }
            }
            $sortedExcps = @($excpParts | Sort-Object)

            # 3. Canonicalize Actions
            $actParts = [System.Collections.Generic.List[string]]::new()
            if ($Rule.PSObject.Properties['Actions'] -and $null -ne $Rule.Actions) {
                $acts = $Rule.Actions
                foreach ($faName in @('MoveToFolder', 'CopyToFolder')) {
                    if ($acts.PSObject.Properties[$faName] -and $acts.$faName.PSObject.Properties['Enabled'] -and $acts.$faName.Enabled) {
                        $f = $null
                        try { $f = $acts.$faName.Folder } catch { $null = $_ }
                        $targetPath = '[null]'
                        if ($null -ne $f) {
                            if ($f.PSObject.Properties['FolderPath'] -and -not [string]::IsNullOrWhiteSpace($f.FolderPath)) {
                                $targetPath = ($f.FolderPath -replace '^[\\/]+[^\\/]+[\\/]?', '').Trim('\/').ToLowerInvariant()
                            } elseif ($f.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace($f.Name)) {
                                $targetPath = $f.Name.Trim().ToLowerInvariant()
                            }
                        }
                        $actParts.Add("folder:$($faName.ToLowerInvariant())=$targetPath")
                    }
                }
                foreach ($na in @('Delete', 'DeletePermanently', 'MarkAsRead', 'Stop', 'ClearCategories')) {
                    if ($acts.PSObject.Properties[$na] -and $acts.$na.PSObject.Properties['Enabled'] -and $acts.$na.Enabled) {
                        $actParts.Add("bool:$($na.ToLowerInvariant())=true")
                    }
                }
                if ($acts.PSObject.Properties['AssignToCategory'] -and $acts.AssignToCategory.PSObject.Properties['Enabled'] -and $acts.AssignToCategory.Enabled -and $acts.AssignToCategory.PSObject.Properties['Categories']) {
                    $sortedCats = @($acts.AssignToCategory.Categories | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() } | Sort-Object -Unique)
                    $actParts.Add("cat:assigntocategory=" + ($sortedCats -join ','))
                }
                foreach ($ra in @('Forward', 'Redirect')) {
                    if ($acts.PSObject.Properties[$ra] -and $acts.$ra.PSObject.Properties['Enabled'] -and $acts.$ra.Enabled -and $acts.$ra.PSObject.Properties['Recipients']) {
                        $recips = @()
                        foreach ($r in $acts.$ra.Recipients) {
                            $rStr = if ($r -is [string]) { $r } elseif ($r.PSObject.Properties['Address']) { $r.Address } elseif ($r.PSObject.Properties['Name']) { $r.Name } else { [string]$r }
                            if (-not [string]::IsNullOrWhiteSpace($rStr)) { $recips += $rStr.Trim().ToLowerInvariant() }
                        }
                        $sortedR = @($recips | Sort-Object -Unique)
                        $actParts.Add("recip:$($ra.ToLowerInvariant())=" + ($sortedR -join ','))
                    }
                }
            }
            $sortedActs = @($actParts | Sort-Object)

            return "T:$typeStr|C:" + ($sortedConds -join ';') + "|E:" + ($sortedExcps -join ';') + "|A:" + ($sortedActs -join ';')
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

            # Locate Store
            if ($ns.PSObject.Properties['Stores'] -and $null -ne $ns.Stores) {
                $stores = $ns.Stores
                foreach ($s in $stores) {
                    if ($null -eq $s) { continue }
                    $sp = if ($s.PSObject.Properties['FilePath'] -and $s.FilePath) { [string]$s.FilePath } else { '' }
                    $dn = if ($s.PSObject.Properties['DisplayName'] -and $s.DisplayName) { [string]$s.DisplayName } else { '' }

                    if (-not [string]::IsNullOrWhiteSpace($resolvedStorePath)) {
                        if ($sp -ieq $resolvedStorePath -or $sp -ieq $StorePath) {
                            $store = $s
                            break
                        }
                    } elseif (-not [string]::IsNullOrWhiteSpace($StoreName)) {
                        if ($dn -ieq $StoreName -or ($s.PSObject.Properties['Name'] -and $s.Name -ieq $StoreName)) {
                            $store = $s
                            break
                        }
                    } elseif ($s.PSObject.Properties['IsDefaultStore'] -and $s.IsDefaultStore) {
                        $store = $s
                        break
                    }
                }
            }

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

            # Resolve Root Folder
            if ($store.PSObject.Methods['GetRootFolder']) {
                $rootFolder = $store.GetRootFolder()
            } elseif ($store.PSObject.Properties['RootFolder']) {
                $rootFolder = $store.RootFolder
            }

            if ($null -eq $rootFolder) {
                throw "Unable to obtain root folder for Outlook store '$storeDisplayName'."
            }

            # Locate Inbox Folder
            if ($rootFolder.PSObject.Properties['Folders'] -and $null -ne $rootFolder.Folders) {
                foreach ($f in $rootFolder.Folders) {
                    if ($null -ne $f -and $f.PSObject.Properties['Name'] -and $f.Name -ieq 'Inbox') {
                        $inboxFolder = $f
                        break
                    }
                }
            }
            if ($null -eq $inboxFolder) { $inboxFolder = $rootFolder }

            # Retrieve Rules Collection
            if ($store.PSObject.Methods['GetRules']) {
                $rules = $store.GetRules()
            } elseif ($store.PSObject.Properties['Rules']) {
                $rules = $store.Rules
            }

            if ($null -eq $rules) {
                throw "Failed to access rules collection on Outlook store '$storeDisplayName'."
            }

            $rulesScanned = if ($rules.PSObject.Properties['Count']) { [int]$rules.Count } else { 0 }
            $seenRuleSignatures = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $rulesToRemoveIndices = [System.Collections.Generic.HashSet[int]]::new()

            $systemFolderNames = @(
                'Deleted Items', 'Drafts', 'Outbox', 'Sent Items', 'Junk Email',
                'Junk E-mail', 'Calendar', 'Contacts', 'Journal', 'Notes', 'Tasks',
                'RSS Feeds', 'RSS Subscriptions', 'Conversation History',
                'Quick Step Settings', 'Newsfeed', 'Sync Issues', 'Conflicts',
                'Local Failures', 'Server Failures', 'External Contacts', 'Yammer Root', 'Search Folders'
            )

            # Pass 1: Scan and Diagnose Rules
            for ($i = 1; $i -le $rulesScanned; $i++) {
                $rule = script:Get-RuleByIndex -rulesObj $rules -idx $i
                if ($null -eq $rule) { continue }

                $rName = if ($rule.PSObject.Properties['Name']) { [string]$rule.Name } else { "Rule_$i" }

                # 1. Disabled Rule Audit
                if ($rule.PSObject.Properties['Enabled'] -and -not [bool]$rule.Enabled) {
                    $disabledRules.Add($rName)
                }

                # 2. Empty Rule Audit (0 active conditions and 0 active actions)
                $activeCondCount = 0
                if ($rule.PSObject.Properties['Conditions'] -and $null -ne $rule.Conditions) {
                    if ($rule.Conditions.PSObject.Properties) {
                        foreach ($p in $rule.Conditions.PSObject.Properties) {
                            $v = $p.Value
                            if ($null -ne $v -and $v.PSObject.Properties['Enabled'] -and $v.Enabled) {
                                $activeCondCount++
                            }
                        }
                    }
                }

                $activeActCount = 0
                if ($rule.PSObject.Properties['Actions'] -and $null -ne $rule.Actions) {
                    if ($rule.Actions.PSObject.Properties) {
                        foreach ($p in $rule.Actions.PSObject.Properties) {
                            $v = $p.Value
                            if ($null -ne $v -and $v.PSObject.Properties['Enabled'] -and $v.Enabled) {
                                $activeActCount++
                            }
                        }
                    }
                }

                $isEmpty = ($activeCondCount -eq 0 -and $activeActCount -eq 0)
                if ($isEmpty) {
                    $emptyRules.Add([PSCustomObject]@{
                        Index  = $i
                        Name   = $rName
                        Reason = 'Zero active conditions and zero active actions'
                    })
                    if ($AutoRepair -or $RemoveEmpty) {
                        [void]$rulesToRemoveIndices.Add($i)
                    }
                }

                # 3. Broken Target Folder Audit (MoveToFolder / CopyToFolder)
                $isBroken = $false
                $brokenActionType = $null
                $brokenReason = $null
                $capturedFolderPath = $null

                if (-not $isEmpty -and $rule.PSObject.Properties['Actions'] -and $null -ne $rule.Actions) {
                    foreach ($faName in @('MoveToFolder', 'CopyToFolder')) {
                        $act = $null
                        if ($rule.Actions.PSObject.Properties[$faName]) {
                            $act = $rule.Actions.PSObject.Properties[$faName].Value
                        } else {
                            try { $act = $rule.Actions.$faName } catch { $null = $_ }
                        }

                        if ($null -eq $act) { continue }

                        $isActEnabled = $false
                        if ($act.PSObject.Properties['Enabled']) {
                            $isActEnabled = [bool]$act.Enabled
                        }

                        if ($isActEnabled) {
                            $folderCom = $null
                            $accessFailed = $false
                            $folderName = $null

                            try {
                                $folderCom = $act.Folder
                                if ($null -ne $folderCom) {
                                    if ($folderCom.PSObject.Properties['Name']) {
                                        $folderName = [string]$folderCom.Name
                                    }
                                    if ($folderCom.PSObject.Properties['FolderPath']) {
                                        $capturedFolderPath = [string]$folderCom.FolderPath
                                    }
                                }
                            } catch {
                                $accessFailed = $true
                                $brokenReason = "Target folder COM property access threw exception: $($_.Exception.Message)"
                            }

                            if ($accessFailed) {
                                $isBroken = $true
                                $brokenActionType = $faName
                            } elseif ($null -eq $folderCom) {
                                $isBroken = $true
                                $brokenActionType = $faName
                                $brokenReason = "Target folder reference is null"
                            } elseif ([string]::IsNullOrWhiteSpace($folderName)) {
                                $isBroken = $true
                                $brokenActionType = $faName
                                $brokenReason = "Target folder Name is empty or inaccessible"
                            } elseif (-not [string]::IsNullOrWhiteSpace($capturedFolderPath)) {
                                if ($capturedFolderPath -match '^\\\\([^\\]+)') {
                                    $targetStoreName = $Matches[1]
                                    $storeMounted = $false
                                    if ($null -ne $stores) {
                                        foreach ($st in $stores) {
                                            $sName = if ($st.PSObject.Properties['DisplayName'] -and $st.DisplayName) { $st.DisplayName } elseif ($st.PSObject.Properties['Name']) { $st.Name } else { '' }
                                            if ($sName -ieq $targetStoreName) { $storeMounted = $true; break }
                                        }
                                    } else {
                                        $storeMounted = $true
                                    }
                                    if (-not $storeMounted) {
                                        $isBroken = $true
                                        $brokenActionType = $faName
                                        $brokenReason = "Target store '$targetStoreName' is unmounted or detached"
                                    }
                                }
                            }

                            if ($isBroken) { break }
                        }
                    }
                }

                if ($isBroken) {
                    # Infer relative target folder path
                    $inferred = $null
                    if (-not [string]::IsNullOrWhiteSpace($capturedFolderPath)) {
                        $inferred = ($capturedFolderPath -replace '^[\\/]+[^\\/]+[\\/]?', '').Trim('\/')
                    }

                    if ([string]::IsNullOrWhiteSpace($inferred)) {
                        if ($rName -match '(?i)(?:move|copy|route|file|sort)\s+(?:to\s+|into\s+)?[''"]([^''"]+)[''"]') {
                            $inferred = $Matches[1].Trim()
                        } elseif ($rName -match '(?i)(?:move|copy|route|file|sort)\s+(?:to\s+|into\s+)([A-Za-z0-9_\-\s\\/]+)$') {
                            $inferred = $Matches[1].Trim()
                        } elseif ($rName -match '(?i)^\[([A-Za-z0-9_\-\s\\/]+)\]') {
                            $inferred = $Matches[1].Trim()
                        } elseif ($rName -match '(?i)^([A-Za-z0-9_\-\s\\/]+?)\s*[-:]\s*(?:move|copy|rule|filter)') {
                            $inferred = $Matches[1].Trim()
                        } elseif ($rName -match '[\\/]') {
                            $inferred = $rName.Trim()
                        }
                    }

                    if ([string]::IsNullOrWhiteSpace($inferred)) {
                        $inferred = $DefaultFallbackFolder
                    }

                    $brokenRules.Add([PSCustomObject]@{
                        Index        = $i
                        Name         = $rName
                        ActionType   = $brokenActionType
                        TargetFolder = $inferred
                        Issue        = $brokenReason
                    })

                    # Auto-Repair broken folder
                    if ($AutoRepair) {
                        try {
                            $normalized = ($inferred -replace '/', '\').Trim('\')
                            $segments = @($normalized -split '\\' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                            if ($segments.Length -eq 0) {
                                $segments = @($DefaultFallbackFolder)
                            }

                            $repairedFolder = $null
                            if ($segments.Length -eq 1) {
                                $singleName = $segments[0]
                                $repairedFolder = script:Find-StoreFolder -parent $inboxFolder -name $singleName
                                if ($null -eq $repairedFolder) {
                                    $repairedFolder = script:Find-StoreFolder -parent $rootFolder -name $singleName
                                }
                                if ($null -eq $repairedFolder -and $singleName -match '\s+([A-Za-z0-9_\-]+)$') {
                                    $lastWord = $Matches[1]
                                    $repairedFolder = script:Find-StoreFolder -parent $inboxFolder -name $lastWord
                                    if ($null -eq $repairedFolder) {
                                        $repairedFolder = script:Find-StoreFolder -parent $rootFolder -name $lastWord
                                    }
                                }
                            }

                            if ($null -eq $repairedFolder) {
                                $currentParent = $null
                                $startIdx = 0

                                if ($segments[0] -ieq 'Inbox') {
                                    $currentParent = $inboxFolder
                                    $startIdx = 1
                                } elseif ($systemFolderNames -contains $segments[0]) {
                                    $currentParent = script:Find-StoreFolder -parent $rootFolder -name $segments[0]
                                    if ($null -eq $currentParent) { $currentParent = $rootFolder }
                                    $startIdx = 1
                                } else {
                                    $underRoot = script:Find-StoreFolder -parent $rootFolder -name $segments[0]
                                    $underInbox = if ($null -ne $inboxFolder) { script:Find-StoreFolder -parent $inboxFolder -name $segments[0] } else { $null }

                                    if ($null -ne $underRoot) {
                                        $currentParent = $underRoot
                                        $startIdx = 1
                                    } elseif ($null -ne $underInbox) {
                                        $currentParent = $underInbox
                                        $startIdx = 1
                                    } else {
                                        if ($segments.Length -eq 1 -and $null -ne $inboxFolder) {
                                            $currentParent = $inboxFolder
                                            $startIdx = 0
                                        } else {
                                            $currentParent = $rootFolder
                                            $startIdx = 0
                                        }
                                    }
                                }

                                if ($null -eq $currentParent) {
                                    $currentParent = if ($null -ne $inboxFolder) { $inboxFolder } else { $rootFolder }
                                }

                                for ($s = $startIdx; $s -lt $segments.Length; $s++) {
                                    $seg = $segments[$s]
                                    if ([string]::IsNullOrWhiteSpace($seg)) { continue }
                                    $res = script:Ensure-StoreFolder -parent $currentParent -name $seg
                                    if ($null -ne $res.Folder) {
                                        $currentParent = $res.Folder
                                    } else {
                                        break
                                    }
                                }
                                $repairedFolder = $currentParent
                            }

                            if ($null -ne $repairedFolder) {
                                $rule.Actions.$brokenActionType.Folder = $repairedFolder
                                $rule.Actions.$brokenActionType.Enabled = $true
                                $repairedCount++
                                $mutationsPerformed = $true
                            }
                        } catch {
                            Write-Verbose "Could not auto-repair broken rule '$rName': $($_.Exception.Message)"
                        }
                    }
                }

                # 4. Duplicate Rule Audit (Canonical Signature)
                if (-not $isEmpty) {
                    $sig = script:Get-OutlookRuleCanonicalSignature -Rule $rule
                    if (-not [string]::IsNullOrWhiteSpace($sig) -and $sig -ne "T:0|C:|E:|A:" -and $sig -ne "T:1|C:|E:|A:") {
                        if ($seenRuleSignatures.ContainsKey($sig)) {
                            $masterRule = $seenRuleSignatures[$sig]
                            $masterName = if ($masterRule.PSObject.Properties['Name']) { [string]$masterRule.Name } else { "Rule_1" }
                            $duplicateRules.Add([PSCustomObject]@{
                                Index       = $i
                                Name        = $rName
                                DuplicateOf = $masterName
                                Signature   = $sig
                            })
                            if ($AutoRepair -or $RemoveDuplicates) {
                                [void]$rulesToRemoveIndices.Add($i)
                            }
                        } else {
                            $seenRuleSignatures[$sig] = $rule
                        }
                    }
                }
            }

            # Pass 2: Reverse-Index Pruning
            if ($rulesToRemoveIndices.Count -gt 0 -and ($AutoRepair -or $RemoveDuplicates -or $RemoveEmpty)) {
                $sortedDesc = @($rulesToRemoveIndices | Sort-Object -Descending)
                foreach ($idx in $sortedDesc) {
                    try {
                        script:Remove-RuleByIndex -rulesObj $rules -idx $idx
                        $mutationsPerformed = $true
                        if ($duplicateRules | Where-Object { $_.Index -eq $idx }) {
                            $removedDuplicatesCount++
                        }
                        if ($emptyRules | Where-Object { $_.Index -eq $idx }) {
                            $removedEmptyCount++
                        }
                    } catch {
                        Write-Verbose "Failed to remove rule at index $($idx): $($_.Exception.Message)"
                    }
                }
            }

            # Pass 3: Silent Save
            if ($mutationsPerformed) {
                if ($rules.PSObject.Methods['Save']) {
                    try {
                        $rules.Save($false)
                    } catch {
                        try {
                            $rules.Save()
                        } catch {
                            throw "Failed to commit rules collection to store via Save: $($_.Exception.Message)"
                        }
                    }
                }
            }

            $success = $true
        }
        catch {
            $errorMessage = $_.Exception.Message
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Rule repair failed: $errorMessage" -Level 'WARN' -Component 'Outlook:RepairRule'
            }
        }
        finally {
            if ($didLogon -and $null -ne $ns) {
                try { $ns.Logoff() } catch { $null = $_ }
            }
            if ($null -ne $comApp -and -not $outlookRunningBefore) {
                try { $comApp.Quit() } catch { $null = $_ }
            }
            $objectsToRelease = @($rules, $inboxFolder, $rootFolder, $store, $stores, $ns, $comApp)
            if (Get-Command -Name 'Remove-ToolkitComObject' -ErrorAction SilentlyContinue) {
                Remove-ToolkitComObject -ComObjects $objectsToRelease
            } else {
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

        $method = if ($AutoRepair -or $RemoveDuplicates -or $RemoveEmpty) {
            'AutoRepair'
        } else {
            'ScanOnly'
        }

        return [PSCustomObject]@{
            StorePath              = $resolvedStorePath
            StoreName              = $storeDisplayName
            ProfileName            = $targetProfile
            RulesScanned           = $rulesScanned
            TotalRules             = $rulesScanned
            BrokenRules            = @($brokenRules)
            DuplicateRules         = @($duplicateRules)
            EmptyRules             = @($emptyRules)
            DisabledRules          = @($disabledRules)
            RepairedRulesCount     = $repairedCount
            RemovedDuplicates      = $removedDuplicatesCount
            RemovedDuplicatesCount = $removedDuplicatesCount
            RemovedEmptyCount      = $removedEmptyCount
            Method                 = $method
            Success                = $success
            ErrorMessage           = $errorMessage
        }
    }
}

if (-not (Get-Alias -Name 'Test-OutlookRule' -ErrorAction SilentlyContinue)) {
    Set-Alias -Name 'Test-OutlookRule' -Value 'Repair-OutlookRule' -Scope Global -ErrorAction SilentlyContinue
}
