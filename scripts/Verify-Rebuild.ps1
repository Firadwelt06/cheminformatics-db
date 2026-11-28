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

    function Get-DbSchemaDump {
        $pgDumpCommand = 'pg_dump --schema-only --no-owner --no-privileges -U "$POSTGRES_USER" "$POSTGRES_DB"'
        $dump = & docker compose exec -T db sh -c $pgDumpCommand
        if ($LASTEXITCODE -ne 0) {
            throw "pg_dump --schema-only failed with exit code $LASTEXITCODE."
        }
        # pg_dump emits a per-run random psql restriction key and object order can vary.
        $normalizedDump = @(
            $dump |
                Where-Object { $_ -notmatch '^\\(un)?restrict\s' } |
                Sort-Object -CaseSensitive
        )
        return ($normalizedDump -join "`n")
    }

    & docker compose exec -T db pg_isready -q
    if ($LASTEXITCODE -ne 0) {
        throw 'A running database is required to capture the live schema before the destructive rebuild.'
    }
    $liveSchema = Get-DbSchemaDump

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
    Invoke-DbSqlFile -ContainerPath '/sql/05_build_mol_gist_index.sql'
    Invoke-DbSqlFile -ContainerPath '/sql/03_bench_schema.sql'
    Invoke-DbSqlFile -ContainerPath '/sql/04_seed_query_catalog.sql'
    Invoke-DbSqlFile -ContainerPath '/sql/06_fingerprint_index.sql'

    & py .\scripts\run_benchmark.py --variants --label rebuild_smoke --target-query-seconds 1 --max-iterations 1
    if ($LASTEXITCODE -ne 0) {
        throw "The paired benchmark smoke run failed with exit code $LASTEXITCODE."
    }

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

    $rebuiltSchema = Get-DbSchemaDump
    if ($liveSchema -cne $rebuiltSchema) {
        $differences = Compare-Object `
            -ReferenceObject ($liveSchema -split "`n") `
            -DifferenceObject ($rebuiltSchema -split "`n") |
            Select-Object -First 20
        throw "Rebuilt schema differs from the live schema:`n$($differences | Out-String)"
    }

    Write-Output "Verification passed: $actual (staged|loaded|rejected|distinct molecules); paired smoke run and schema dump match passed."
}
finally {
    Pop-Location
}
