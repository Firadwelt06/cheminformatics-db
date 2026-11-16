[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    $csvPath = Join-Path $repoRoot 'data\bbbp.csv'
    if (-not (Test-Path -LiteralPath $csvPath -PathType Leaf)) {
        throw "Missing $csvPath. Follow the BBBP data setup instructions in README.md first."
    }

    if (-not $PSCmdlet.ShouldProcess('Docker Compose project and named volumes', 'Remove volumes, rebuild, reload BBBP, and verify counts')) {
        return
    }

    function Invoke-Compose {
        param([Parameter(Mandatory)][string[]]$Arguments)

        & docker compose @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "docker compose $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
        }
    }

    function Invoke-DbSqlFile {
        param(
            [Parameter(Mandatory)][string]$ContainerPath,
            [string]$FileSha256
        )

        $psqlCommand = 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
        if ($FileSha256) {
            $psqlCommand += " -v file_sha256=$FileSha256"
        }
        $psqlCommand += " -f $ContainerPath"
        Invoke-Compose -Arguments @('exec', '-T', 'db', 'sh', '-c', $psqlCommand)
    }

    Invoke-Compose -Arguments @('down', '-v')
    Invoke-Compose -Arguments @('up', '-d', '--build')

    $ready = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        & docker compose exec -T db pg_isready -q
        if ($LASTEXITCODE -eq 0) {
            $ready = $true
            break
        }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) {
        throw 'PostgreSQL did not become ready within 120 seconds.'
    }

    $fileSha256 = (Get-FileHash -LiteralPath $csvPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Invoke-DbSqlFile -ContainerPath '/sql/01_schema.sql'
    Invoke-DbSqlFile -ContainerPath '/sql/02_stage_bbbp.sql'
    Invoke-DbSqlFile -ContainerPath '/sql/02_load_bbbp.sql' -FileSha256 $fileSha256

    $query = "SELECT (SELECT count(*) FROM bbbp_stage), (SELECT count(*) FROM dataset_records WHERE dataset = 'bbbp'), (SELECT count(*) FROM ingest_rejects WHERE dataset = 'bbbp'), (SELECT count(*) FROM molecules);"
    $psqlCommand = 'psql -X -A -t -F "|" -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "' + $query + '"'
    $actual = (& docker compose exec -T db sh -c $psqlCommand | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Count verification query failed with exit code $LASTEXITCODE."
    }

    $expected = '2039|2039|0|1975'
    if ($actual -ne $expected) {
        throw "Count verification failed. Expected $expected but got '$actual'."
    }

    Write-Output "Verification passed: $actual (staged|loaded|rejected|distinct molecules)."
}
finally {
    Pop-Location
}
