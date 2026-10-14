function Export-PersonalCertificates {
<#
.SYNOPSIS
    Exports user certificates from Cert:\CurrentUser\My with SecureString password protection.
.DESCRIPTION
    Enumerates personal certificates in Cert:\CurrentUser\My. For certificates with exportable
    private keys, exports to .pfx using the supplied SecureString password. For certificates without
    private keys or non-exportable hardware keys, falls back to public .cer export.
.PARAMETER DestinationPath
    Destination directory to save exported certificates.
.PARAMETER Password
    Password required to protect exported private key (.pfx) files. Must be [SecureString].
.OUTPUTS
    [PSCustomObject[]]@{ Thumbprint, Subject, HasPrivateKey, ExportFormat, FilePath }
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [System.Security.SecureString]$Password,

        [Parameter(Mandatory = $false)]
        [string[]]$StoreNames = @('My'),

        [Parameter(Mandatory = $false)]
        [string[]]$StoreLocations = @('CurrentUser')
    )

    process {
        if (-not (Get-Command -Name 'Export-ToolkitCertificates' -ErrorAction SilentlyContinue)) {
            $helperScript = Join-Path -Path $PSScriptRoot -ChildPath 'Export-ToolkitCertificates.ps1'
            if (Test-Path -LiteralPath $helperScript) {
                . $helperScript
            }
        }

        $rawResults = Export-ToolkitCertificates -DestinationPath $DestinationPath `
                                                -StoreNames $StoreNames `
                                                -StoreLocations $StoreLocations `
                                                -Password $Password

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        if ($rawResults) {
            foreach ($r in $rawResults) {
                $results.Add([PSCustomObject]@{
                    Thumbprint    = $r.Thumbprint
                    Subject       = $r.Subject
                    HasPrivateKey = $r.HasPrivateKey
                    ExportFormat  = $r.Format
                    FilePath      = $r.ExportPath
                })
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Exported $($results.Count) certificate(s) to '$DestinationPath'" -Level 'INFO' -Component 'Backup:Certs'
        }

        return @($results)
    }
}
