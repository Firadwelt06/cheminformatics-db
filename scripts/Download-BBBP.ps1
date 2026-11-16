[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$outputPath = Join-Path $repoRoot 'data\bbbp.csv'
$outputDirectory = Split-Path -Parent $outputPath
$temporaryPath = Join-Path ([System.IO.Path]::GetTempPath()) ("bbbp-$([guid]::NewGuid().ToString('N')).csv")
$uri = 'https://huggingface.co/datasets/scikit-fingerprints/MoleculeNet_BBBP/resolve/86db3f465c006b230b1e5af9032a1e05be4db618/bbbp.csv'
$expectedSha256 = 'c3847c03b1422471b8e1dc1551cd3bf92428d4f2eac8cc8de9a08b7364eb303c'

if ((Test-Path -LiteralPath $outputPath) -and -not $Force) {
    throw "$outputPath already exists. Review it first, or pass -Force to replace it."
}
if (-not $PSCmdlet.ShouldProcess($outputPath, "Download the pinned BBBP CSV from $uri")) {
    return
}

try {
    Invoke-WebRequest -Uri $Uri -OutFile $temporaryPath
    $sourceRows = @(Import-Csv -LiteralPath $temporaryPath)
    if ($sourceRows.Count -ne 2039) {
        throw "Expected 2039 source rows, found $($sourceRows.Count). The pinned upstream artifact may have changed."
    }
    $columnNames = $sourceRows[0].PSObject.Properties.Name
    if ($columnNames.Count -ne 2 -or $columnNames[0] -ne 'SMILES' -or $columnNames[1] -ne 'label') {
        throw 'The downloaded CSV must contain exactly the SMILES,label columns in that order.'
    }
    foreach ($row in $sourceRows) {
        if ([string]::IsNullOrWhiteSpace($row.SMILES) -or $row.label -notmatch '^[01]$') {
            throw 'The downloaded CSV contains a blank SMILES or a label other than 0 or 1.'
        }
    }

    $actualSha256 = (Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $expectedSha256) {
        throw "Checksum mismatch for the pinned dataset: $actualSha256."
    }

    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    Copy-Item -LiteralPath $temporaryPath -Destination $outputPath -Force:$Force
    Write-Output "Saved $($sourceRows.Count) dataset records to $outputPath."
    Write-Output "SHA-256: $actualSha256"
}
finally {
    if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item -LiteralPath $temporaryPath
    }
}
