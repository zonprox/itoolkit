function Format-ToolkitSummary {
<#
.SYNOPSIS
    Renders a formatted ASCII summary box with color indicators in the console.
.DESCRIPTION
    Generates structured, high-visibility summary boxes for operation results,
    displaying metadata items (Status, Target, Duration, Backup File, Log File)
    and optional chronological action details. Compatible with all Windows console hosts.
.PARAMETER Title
    Title of the operation or summary box.
.PARAMETER Items
    Hashtable, ordered dictionary, or array of hashtables containing key/value pairs.
    Example: @( @{ Label = 'PST File Path'; Value = 'C:\Data\archive.pst'; Status = 'OK' } )
.PARAMETER Details
    Optional array of strings representing bullet-point step details.
.PARAMETER Status
    Overall status determining border/header highlight color: 'OK', 'WARN', 'FAIL', 'WHATIF', 'INFO'.
    Default is 'OK'.
.PARAMETER Width
    Total width of the console box in characters. Default is 78.
.PARAMETER PassThru
    Explicit switch to indicate returning the string. Even without -PassThru, the summary is returned.
.OUTPUTS
    [string] Formatted summary box string.
.EXAMPLE
    Format-ToolkitSummary -Title "Migration Summary" -Items @(@{ Label = 'Status'; Value = 'OK' })
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Title,

        [Parameter(Mandatory = $false, Position = 1)]
        [object]$Items,

        [Parameter(Mandatory = $false)]
        [string[]]$Details,

        [Parameter(Mandatory = $false)]
        [ValidateSet('OK', 'WARN', 'FAIL', 'WHATIF', 'INFO', 'Ok', 'Warn', 'Fail', 'WhatIf', 'Info')]
        [string]$Status = 'OK',

        [Parameter(Mandatory = $false)]
        [ValidateRange(40, 120)]
        [int]$Width = 78,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    $normalizedStatus = $Status.ToUpperInvariant()

    $doubleLine = '=' * $Width
    $singleLine = '-' * $Width
    $outputLines = [System.Collections.Generic.List[string]]::new()

    # 1. Header Box
    $outputLines.Add($doubleLine)
    $headerText = "  OPERATION SUMMARY: $Title"
    if ($headerText.Length -gt ($Width - 1)) {
        $headerText = $headerText.Substring(0, $Width - 4) + '...'
    }
    $outputLines.Add($headerText)
    $outputLines.Add($doubleLine)

    # 2. Key-Value Metadata Items
    if ($null -ne $Items) {
        $itemList = [System.Collections.Generic.List[PSCustomObject]]::new()

        if ($Items -is [System.Collections.IDictionary]) {
            foreach ($key in $Items.Keys) {
                $itemList.Add([PSCustomObject]@{
                    Label = [string]$key
                    Value = [string]$Items[$key]
                })
            }
        }
        elseif ($Items -is [System.Collections.IEnumerable]) {
            foreach ($entry in $Items) {
                if ($entry -is [System.Collections.IDictionary]) {
                    if ($entry.ContainsKey('Label') -and $entry.ContainsKey('Value')) {
                        $itemList.Add([PSCustomObject]@{
                            Label = [string]$entry['Label']
                            Value = [string]$entry['Value']
                        })
                    }
                    else {
                        foreach ($k in $entry.Keys) {
                            $itemList.Add([PSCustomObject]@{
                                Label = [string]$k
                                Value = [string]$entry[$k]
                            })
                        }
                    }
                }
                elseif ($entry -is [PSCustomObject]) {
                    if ($entry.PSObject.Properties['Label'] -and $entry.PSObject.Properties['Value']) {
                        $itemList.Add([PSCustomObject]@{
                            Label = [string]$entry.Label
                            Value = [string]$entry.Value
                        })
                    }
                }
            }
        }

        # Calculate label padding
        $maxLabelLength = 14
        foreach ($item in $itemList) {
            if ($item.Label.Length -gt $maxLabelLength) {
                $maxLabelLength = [Math]::Min($item.Label.Length, 30)
            }
        }

        # Render metadata lines
        foreach ($item in $itemList) {
            $paddedLabel = $item.Label.PadRight($maxLabelLength)
            $outputLines.Add("  $paddedLabel : $($item.Value)")
        }
    }

    # 3. Details Section
    if ($null -ne $Details -and $Details.Count -gt 0) {
        $outputLines.Add($singleLine)
        $outputLines.Add("  Execution Steps / Details:")
        foreach ($detail in $Details) {
            $outputLines.Add("  - $detail")
        }
    }

    # 4. Footer Line
    $outputLines.Add($doubleLine)

    $resultText = ($outputLines -join "`r`n")
    return $resultText
}
