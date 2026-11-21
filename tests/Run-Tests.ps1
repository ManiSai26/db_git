#Requires -Version 7
<#
.SYNOPSIS
    Runs the db_git test suite.
.DESCRIPTION
    -Unit         Unit tests only (no database needed). Default when no switch is given.
    -Integration  Integration tests. Unless DBGIT_TEST_HOST is already set, starts a throwaway
                  PostgreSQL container with Docker, runs the tests, then removes the container.
    -All          Both.
.EXAMPLE
    ./tests/Run-Tests.ps1
    ./tests/Run-Tests.ps1 -All
    ./tests/Run-Tests.ps1 -Integration -PostgresImage postgres:16-alpine
#>
param(
    [switch]$Unit,
    [switch]$Integration,
    [switch]$All,
    [string]$PostgresImage = 'postgres:17-alpine',
    [int]$Port = 55432,
    [switch]$CI          # emit NUnit XML to tests/results.xml and exit non-zero on failure
)

$ErrorActionPreference = 'Stop'
if (-not ($Unit -or $Integration -or $All)) { $Unit = $true }
if ($All) { $Unit = $true; $Integration = $true }

if (-not (Get-Module Pester -ListAvailable | Where-Object Version -ge '5.5.0')) {
    throw "Pester 5.5+ is required: Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck"
}
Import-Module Pester -MinimumVersion 5.5.0

$paths = @()
if ($Unit)        { $paths += Join-Path $PSScriptRoot 'Unit.Tests.ps1' }
if ($Integration) { $paths += Join-Path $PSScriptRoot 'Integration.Tests.ps1' }

$container = $null
try {
    if ($Integration -and -not $env:DBGIT_TEST_HOST) {
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            throw "Integration tests need Docker, or DBGIT_TEST_HOST/PORT/USER/PASSWORD pointing at a throwaway server."
        }
        $container = "db_git_test_$(Get-Random -Maximum 99999)"
        Write-Host "Starting $PostgresImage as '$container' on port $Port..."
        docker run -d --rm --name $container -e POSTGRES_PASSWORD=dbgit-test -p "${Port}:5432" $PostgresImage | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "docker run failed" }

        # 127.0.0.1, not 'localhost': on Windows 'localhost' tries IPv6 (::1) first and Docker's
        # port mapping doesn't answer there, so every connection stalls ~20s before falling back.
        $env:DBGIT_TEST_HOST = '127.0.0.1'; $env:DBGIT_TEST_PORT = "$Port"
        $env:DBGIT_TEST_USER = 'postgres';  $env:DBGIT_TEST_PASSWORD = 'dbgit-test'

        $ready = $false
        for ($i = 0; $i -lt 60; $i++) {
            docker exec $container pg_isready -U postgres -h 127.0.0.1 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $ready = $true; break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $ready) { throw "PostgreSQL container did not become ready in 30s" }
    }

    $cfg = New-PesterConfiguration
    $cfg.Run.Path = $paths
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'Detailed'
    if ($CI) {
        $cfg.TestResult.Enabled = $true
        $cfg.TestResult.OutputPath = Join-Path $PSScriptRoot 'results.xml'
    }
    $result = Invoke-Pester -Configuration $cfg
}
finally {
    if ($container) {
        Write-Host "Removing container '$container'..."
        docker rm -f $container 2>$null | Out-Null
        foreach ($v in 'HOST', 'PORT', 'USER', 'PASSWORD') { Remove-Item "Env:DBGIT_TEST_$v" -ErrorAction SilentlyContinue }
    }
}

if ($result.FailedCount -gt 0) { exit 1 }
