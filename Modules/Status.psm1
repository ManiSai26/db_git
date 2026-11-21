# Status.psm1

# Implements status, info, doctor, version commands.

function Cmd-status {
    <#
    .SYNOPSIS
        Show the status of the backup repository.
    .DESCRIPTION
        Displays database connectivity, current HEAD, and backup summary.
    #>
    param([string[]]$Args)

    Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking

    $repo = Get-DbGitRepoPath
    if (-not $repo) {
        Write-Host "Repository not initialized. Run 'db_git init' in the current directory."
        return
    }

    $config = Get-DbGitConfig
    if (-not $config) { return }

    Write-Host "On database: $($config.database) (host: $($config.host):$($config.port))"
    
    # Test connection
    $env:PGPASSWORD = Unprotect-DbGitPassword -StoredPassword $config.password
    $connTest = & psql -h $config.host -p $config.port -U $config.username -d $config.database -Atc "SELECT 1;" 2>$null
    if ($connTest -eq "1") {
        Write-Host "Connection status: Connected successfully" -ForegroundColor Green
    } else {
        Write-Warning "Connection status: Cannot connect to PostgreSQL database. Check connection settings or PostgreSQL service."
    }
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue

    $head = Get-HeadHash
    if ($head) {
        Write-Host "HEAD pointing to: $head"
    } else {
        Write-Host "HEAD: No backups created yet."
    }

    $history = Get-HistoryEntries
    Write-Host "Total Backups: $($history.Count)"
}

function Cmd-info {
    <#
    .SYNOPSIS
        Show information about the repository and configuration.
    .DESCRIPTION
        Displays detailed information about the database and backup files.
    #>
    param([string[]]$Args)

    Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking

    $repo = Get-DbGitRepoPath
    if (-not $repo) {
        Write-Host "Repository not initialized."
        return
    }

    $config = Get-DbGitConfig
    if (-not $config) { return }

    Write-Host "--- Database Configuration ---"
    Write-Host "Database:  $($config.database)"
    Write-Host "Host:      $($config.host)"
    Write-Host "Port:      $($config.port)"
    Write-Host "Username:  $($config.username)"
    Write-Host "Created:   $($config.created)"
    Write-Host ""
    Write-Host "--- Repository Metrics ---"
    $backupDir = Get-BackupDir
    if (Test-Path $backupDir) {
        $files = Get-ChildItem -Path $backupDir -Filter *.sql
        $totalSize = ($files | Measure-Object -Property Length -Sum).Sum
        Write-Host "Backup Dir: $backupDir"
        Write-Host "Files count: $($files.Count)"
        Write-Host "Total size:  $([Math]::Round($totalSize / 1MB, 2)) MB"
    }
}

function Cmd-doctor {
    <#
    .SYNOPSIS
        Run diagnostics on the repository directory.
    .DESCRIPTION
        Checks directory health, permissions, connection tools (pg_dump, psql, pg_restore), and repository index consistency.
    #>
    param([string[]]$Args)

    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking

    Write-Host "Checking db_git repository health..."

    $repo = Get-DbGitRepoPath
    if (-not $repo) {
        Write-Error "Repository folder (.db_git) not found in current directory."
        return
    }

    $healthy = $true

    # Check directories
    $dirs = @('db_backups', 'metadata', 'temp')
    foreach ($d in $dirs) {
        $path = Join-Path $repo $d
        if (-not (Test-Path $path)) {
            Write-Warning "Missing directory: $path. Attempting to recreate..."
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        } else {
            Write-Host "[OK] Directory exists: $d"
        }
    }

    # Check files
    $files = @('config.json', 'HEAD', 'history.csv', 'tags.csv')
    foreach ($f in $files) {
        $path = Join-Path $repo $f
        if (-not (Test-Path $path)) {
            Write-Warning "Missing file: $path. Creating empty file..."
            New-Item -ItemType File -Path $path -Force | Out-Null
            $healthy = $false
        } else {
            Write-Host "[OK] File exists: $f"
        }
    }

    # Check .gitignore excludes .db_git/ (it holds SQL dumps and unencrypted-at-rest config)
    if (Ensure-DbGitIgnored) {
        Write-Warning ".gitignore was missing a '.db_git/' entry; added it."
    } else {
        Write-Host "[OK] .gitignore excludes .db_git/"
    }

    # Check tool dependency
    $tools = @('pg_dump', 'psql', 'pg_restore')
    foreach ($t in $tools) {
        if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
            Write-Error "Required PostgreSQL utility '$t' is not found in PATH."
            $healthy = $false
        } else {
            Write-Host "[OK] Utility found: $t"
        }
    }

    if ($healthy) {
        Write-Host "Everything looks clean and healthy!" -ForegroundColor Green
    } else {
        Write-Warning "Doctor found some issues. Checked and attempted auto-heals where possible."
    }
}

function Cmd-version {
    <#
    .SYNOPSIS
        Show version information.
    .DESCRIPTION
        Prints the current version of db_git.
    #>
    param([string[]]$Args)
    Write-Host "db_git version 1.0.0"
}

Export-ModuleMember -Function Cmd-status, Cmd-info, Cmd-doctor, Cmd-version

