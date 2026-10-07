if (-not (Get-Command -Name 'Get-ToolkitLayoutWidth' -ErrorAction SilentlyContinue)) {
    $widthScript = Join-Path $PSScriptRoot 'Get-ToolkitLayoutWidth.ps1'
    if (Test-Path $widthScript) {
        . $widthScript
    }
}

function Show-ToolkitItemTable {
<#
.SYNOPSIS
    Renders an item-centric console table with calculated dynamic column widths, status badges, and ASCII borders.
.DESCRIPTION
    Formats and displays a structured tabular view of items with calculated column widths fitting the
    console window. Formats row indices [1], [2], ... in brackets, highlights known status badges with
    color coding, and renders clean ASCII borders (+, -, |). Handles empty item collections gracefully.
.PARAMETER Items
    Array of objects or hashtables to display as table rows.
.PARAMETER Columns
    Array of property names to display as table columns.
.PARAMETER Headers
    Optional custom header titles corresponding to Columns. If omitted, column names are used.
.PARAMETER Title
    Optional section title displayed in the table header banner.
.PARAMETER Width
    Target display width in columns. If 0 or omitted, automatically calculated via Get-ToolkitLayoutWidth.
.EXAMPLE
    $accounts = @(
        [PSCustomObject]@{ Name = 'Administrator'; Status = '[DISABLED]'; Description = 'Built-in administrator' }
    )
    Show-ToolkitItemTable -Items $accounts -Columns @('Name', 'Status', 'Description') -Title 'LOCAL USER ACCOUNTS'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Items,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]]$Columns,

        [Parameter(Mandatory = $false, Position = 2)]
        [string[]]$Headers,

        [Parameter(Mandatory = $false)]
        [string]$Title,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 300)]
        [int]$Width = 0
    )

    # 1. Determine effective layout width
    if ($Width -le 0) {
        if (Get-Command -Name 'Get-ToolkitLayoutWidth' -ErrorAction SilentlyContinue) {
            $Width = Get-ToolkitLayoutWidth
        }
        else {
            $Width = 78
        }
    }
    $tableWidth = [math]::Max(40, $Width)

    # 2. Handle empty items collection gracefully
    if ($null -eq $Items -or $Items.Count -eq 0) {
        $boxBorder = '+' + ('-' * ($tableWidth - 2)) + '+'
        Write-Host $boxBorder -ForegroundColor DarkGray

        if (-not [string]::IsNullOrWhiteSpace($Title)) {
            $cleanTitle = $Title.Trim()
            $maxTitleLen = $tableWidth - 4
            if ($cleanTitle.Length -gt $maxTitleLen) {
                $cleanTitle = $cleanTitle.Substring(0, [math]::Max(0, $maxTitleLen - 3)) + '...'
            }
            $tPad = ' ' * ($maxTitleLen - $cleanTitle.Length)
            Write-Host "| $cleanTitle$tPad |" -ForegroundColor Yellow
            Write-Host $boxBorder -ForegroundColor DarkGray
        }

        $msg = '[No items found]'
        $maxMsgLen = $tableWidth - 4
        $msgPad = ' ' * ($maxMsgLen - $msg.Length)
        Write-Host "| $msg$msgPad |" -ForegroundColor DarkGray
        Write-Host $boxBorder -ForegroundColor DarkGray
        return
    }

    # 3. Helper: Extract property value from PSCustomObject, hashtable, or string
    function Get-ToolkitPropertyValue {
        param($Object, [string]$PropertyName)
        if ($null -eq $Object) { return '' }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.ContainsKey($PropertyName)) { return "$($Object[$PropertyName])" }
        }
        elseif ($Object -is [PSCustomObject] -or $Object.PSObject) {
            $prop = $Object.PSObject.Properties[$PropertyName]
            if ($null -ne $prop) { return "$($prop.Value)" }
        }
        elseif ($Object -is [string]) {
            if ($PropertyName -eq 'Name' -or $PropertyName -eq 'Value' -or $PropertyName -eq 'Item') {
                return $Object
            }
        }
        return ''
    }

    # 4. Helper: Determine ConsoleColor for status badge text
    function Get-ToolkitBadgeColor {
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
        $t = $Text.Trim()
        # Green: [ENABLED], [RUNNING], [ACTIVE], [READY], [OK], unbracketed equivalents
        if ($t -match '^(?i)\[?(ENABLED|RUNNING|ACTIVE|READY|OK)\]?$') {
            return [System.ConsoleColor]::Green
        }
        # Red: [LOCKED], [FAIL], [ERROR], FAILED
        if ($t -match '^(?i)\[?(LOCKED|FAIL|ERROR|FAILED)\]?$') {
            return [System.ConsoleColor]::Red
        }
        # Yellow: [WARN], [WARNING]
        if ($t -match '^(?i)\[?(WARN|WARNING)\]?$') {
            return [System.ConsoleColor]::Yellow
        }
        # DarkGray: [DISABLED]
        if ($t -match '^(?i)\[?DISABLED\]?$') {
            return [System.ConsoleColor]::DarkGray
        }
        # Yellow: [STOPPED]
        if ($t -match '^(?i)\[?STOPPED\]?$') {
            return [System.ConsoleColor]::Yellow
        }
        return $null
    }

    # 5. Resolve Columns if not supplied or empty
    if ($null -eq $Columns -or $Columns.Count -eq 0) {
        $first = $Items[0]
        if ($first -is [System.Collections.IDictionary]) {
            $Columns = @($first.Keys | ForEach-Object { "$_" })
        }
        elseif ($first.PSObject) {
            $Columns = @($first.PSObject.Properties | Where-Object { $_.MemberType -match 'Property' } | ForEach-Object { $_.Name })
        }
        if ($null -eq $Columns -or $Columns.Count -eq 0) {
            $Columns = @('Name', 'Status', 'Details')
        }
    }

    # 6. Resolve Headers
    $resolvedHeaders = [System.Collections.Generic.List[string]]::new()
    for ($c = 0; $c -lt $Columns.Count; $c++) {
        if ($null -ne $Headers -and $c -lt $Headers.Count -and -not [string]::IsNullOrWhiteSpace($Headers[$c])) {
            $resolvedHeaders.Add($Headers[$c].Trim())
        }
        else {
            $resolvedHeaders.Add($Columns[$c].ToUpper().Trim())
        }
    }

    # 7. Dynamic Column Width Budgeting
    $totalCols = 1 + $Columns.Count
    $borderOverhead = 3 * $totalCols + 1

    $maxIdxStr = "[$($Items.Count)]"
    $idxColWidth = [math]::Max(5, $maxIdxStr.Length + 2)

    $availContent = $tableWidth - $borderOverhead
    $availUserWidth = $availContent - $idxColWidth
    if ($availUserWidth -lt ($Columns.Count * 4)) {
        $availUserWidth = $Columns.Count * 4
        $tableWidth = $borderOverhead + $idxColWidth + $availUserWidth
    }

    $desiredWidths = [System.Collections.Generic.List[int]]::new()
    $totalDesired = 0
    for ($c = 0; $c -lt $Columns.Count; $c++) {
        $desired = $resolvedHeaders[$c].Length
        foreach ($item in $Items) {
            $v = Get-ToolkitPropertyValue -Object $item -PropertyName $Columns[$c]
            if ($v.Length -gt $desired) {
                $desired = $v.Length
            }
        }
        $desired = [math]::Max(4, $desired)
        $desiredWidths.Add($desired)
        $totalDesired += $desired
    }

    $colWidths = [System.Collections.Generic.List[int]]::new()
    if ($totalDesired -le $availUserWidth) {
        for ($c = 0; $c -lt $Columns.Count; $c++) {
            $colWidths.Add($desiredWidths[$c])
        }
        $extra = $availUserWidth - $totalDesired
        if ($extra -gt 0) {
            $colWidths[$Columns.Count - 1] += $extra
        }
    }
    else {
        $allocatedSum = 0
        for ($c = 0; $c -lt $Columns.Count; $c++) {
            $ratio = $desiredWidths[$c] / [double]$totalDesired
            $wAlloc = [int][math]::Floor($availUserWidth * $ratio)
            if ($wAlloc -lt 4) { $wAlloc = 4 }
            $colWidths.Add($wAlloc)
            $allocatedSum += $wAlloc
        }
        $diff = $availUserWidth - $allocatedSum
        if ($diff -gt 0) {
            $colWidths[$Columns.Count - 1] += $diff
        }
        elseif ($diff -lt 0) {
            while ($diff -lt 0) {
                $maxW = 0
                $maxIdx = 0
                for ($k = 0; $k -lt $colWidths.Count; $k++) {
                    if ($colWidths[$k] -gt $maxW) {
                        $maxW = $colWidths[$k]
                        $maxIdx = $k
                    }
                }
                if ($colWidths[$maxIdx] -gt 4) {
                    $colWidths[$maxIdx]--
                    $diff++
                }
                else {
                    break
                }
            }
        }
    }

    # 8. Build ASCII Borders (+, -, |)
    $borderParts = [System.Collections.Generic.List[string]]::new()
    $borderParts.Add('-' * ($idxColWidth + 2))
    for ($c = 0; $c -lt $Columns.Count; $c++) {
        $borderParts.Add('-' * ($colWidths[$c] + 2))
    }
    $tableBorder = '+' + ($borderParts -join '+') + '+'

    # 9. Render Title banner if present
    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $topBorder = '+' + ('-' * ($tableBorder.Length - 2)) + '+'
        Write-Host $topBorder -ForegroundColor DarkGray
        $cleanTitle = $Title.Trim()
        $maxTLen = $tableBorder.Length - 4
        if ($cleanTitle.Length -gt $maxTLen) {
            $cleanTitle = $cleanTitle.Substring(0, [math]::Max(0, $maxTLen - 3)) + '...'
        }
        $tPad = ' ' * ($maxTLen - $cleanTitle.Length)
        Write-Host "| $cleanTitle$tPad |" -ForegroundColor Yellow
    }

    # 10. Render Header Row
    Write-Host $tableBorder -ForegroundColor DarkGray
    Write-Host '| ' -ForegroundColor DarkGray -NoNewline
    $idxHdr = '#'
    $idxHdrPad = ' ' * ($idxColWidth - $idxHdr.Length)
    Write-Host "$idxHdr$idxHdrPad" -ForegroundColor DarkCyan -NoNewline
    for ($c = 0; $c -lt $Columns.Count; $c++) {
        Write-Host ' | ' -ForegroundColor DarkGray -NoNewline
        $hText = $resolvedHeaders[$c]
        $cWidth = $colWidths[$c]
        if ($hText.Length -gt $cWidth) {
            $hText = $hText.Substring(0, [math]::Max(0, $cWidth - 3)) + '...'
        }
        $hPad = ' ' * ($cWidth - $hText.Length)
        Write-Host "$hText$hPad" -ForegroundColor DarkCyan -NoNewline
    }
    Write-Host ' |' -ForegroundColor DarkGray
    Write-Host $tableBorder -ForegroundColor DarkGray

    # 11. Render Data Rows
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $rowItem = $Items[$i]
        Write-Host '| ' -ForegroundColor DarkGray -NoNewline

        $idxText = "[$($i + 1)]"
        Write-Host $idxText -ForegroundColor Yellow -NoNewline
        $idxPad = ' ' * ($idxColWidth - $idxText.Length)
        Write-Host $idxPad -NoNewline

        for ($c = 0; $c -lt $Columns.Count; $c++) {
            Write-Host ' | ' -ForegroundColor DarkGray -NoNewline
            $cWidth = $colWidths[$c]
            $cellRaw = Get-ToolkitPropertyValue -Object $rowItem -PropertyName $Columns[$c]

            $displayCell = $cellRaw
            if ($displayCell.Length -gt $cWidth) {
                $displayCell = $displayCell.Substring(0, [math]::Max(0, $cWidth - 3)) + '...'
            }
            $cellPad = ' ' * ($cWidth - $displayCell.Length)

            $badgeColor = Get-ToolkitBadgeColor -Text $displayCell
            if ($null -ne $badgeColor) {
                Write-Host $displayCell -ForegroundColor $badgeColor -NoNewline
            }
            else {
                Write-Host $displayCell -ForegroundColor White -NoNewline
            }
            Write-Host $cellPad -NoNewline
        }
        Write-Host ' |' -ForegroundColor DarkGray
    }

    # 12. Closing Table Border
    Write-Host $tableBorder -ForegroundColor DarkGray
}

if (Get-Command -Name 'Show-ToolkitItemTable' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-Item -Path 'function:global:Show-ToolkitItemTable' -Value (Get-Command -Name 'Show-ToolkitItemTable').ScriptBlock
}
