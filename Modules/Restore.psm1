# Restore.psm1

# Implements the restore command.
#
# Restore strategy (restore-then-swap):
#   1. pg_restore into a temporary database  <db>_restore_tmp
#      -> on failure the temp db is dropped and the live db is never touched.
#   2. Block + terminate connections to the live db.
#   3. Rename live -> <db>_old, then temp -> live (renames are near-instant).
#   4. Keep <db>_old as a rollback copy (dropped on the next restore, or now with --drop-old).
# If the user lacks CREATEDB, falls back to an in-place pg_restore -c --if-exists.

# Quoting helpers (ConvertTo-PgIdent / ConvertTo-PgLiteral) live in Utils.psm1.
Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -DisableNameChecking

function Invoke-PgAdminSql {
    # Runs one SQL statement against the 'postgres' maintenance db. Returns @{ Ok; Output }.
    param([hashtable]$Config, [string]$Sql)
    $out = & psql -h $Config.host -p $Config.port -U $Config.username -d postgres -v ON_ERROR_STOP=1 -Atc $Sql 2>&1
    return @{ Ok = ($LASTEXITCODE -eq 0); Output = ($out -join "`n").Trim() }
}

function Test-PgDatabaseExists {
    param([hashtable]$Config, [string]$Name)
    $r = Invoke-PgAdminSql -Config $Config -Sql "SELECT 1 FROM pg_database WHERE datname = $(ConvertTo-PgLiteral $Name);"
    return ($r.Ok -and $r.Output -eq '1')
}

function Stop-PgConnections {
    param([hashtable]$Config, [string]$Name)
    Invoke-PgAdminSql -Config $Config -Sql "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $(ConvertTo-PgLiteral $Name) AND pid <> pg_backend_pid();" | Out-Null
}

function Remove-PgDatabase {
    param([hashtable]$Config, [string]$Name)
    Stop-PgConnections -Config $Config -Name $Name
    return Invoke-PgAdminSql -Config $Config -Sql "DROP DATABASE IF EXISTS $(ConvertTo-PgIdent $Name);"
}

function Cmd-restore {
    <#
    .SYNOPSIS
        Restore a backup into the configured database.
    .DESCRIPTION
        Accepts an identifier (numeric id, short hash, "latest", or tag). Prompts for confirmation unless --force is supplied.
        Restores into a temporary database first and only swaps it in (by rename) once pg_restore succeeds, so a failed
        restore never touches the live database. The previous database is kept as <db>_old for rollback.
    .PARAMETER Target
        Identifier of the backup to restore (id, hash, latest, tag).
    .PARAMETER Force
        Bypass confirmation prompts.
    .PARAMETER DropOld
        Drop the previous database (<db>_old) right after a successful swap instead of keeping it for rollback.
    .EXAMPLE
        db_git restore 5
    .EXAMPLE
        db_git restore latest --drop-old
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Target,
        [switch]$Force,
        [Alias('drop-old')][switch]$DropOld
    )

    Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking

    $config = Get-DbGitConfig
    if (-not $config) { return }
    $repo = Get-DbGitRepoPath
    $backupDir = Get-BackupDir
    $history = Get-HistoryEntries

    # Resolve the identifier to a filename
    $entry = $null
    if ($Target -eq 'latest') {
        $headHash = Get-HeadHash
        $entry = $history | Where-Object { $_.Hash -eq $headHash }
    } else {
        # try numeric id
        if ($Target -as [int]) {
            $entry = $history | Where-Object { $_.Id -eq [int]$Target }
        }
        if (-not $entry) {
            # try hash prefix
            $entry = $history | Where-Object { $_.Hash -like "${Target}*" }
        }
        if (-not $entry) {
            # try tag lookup (tags.csv)
            $tagsPath = Join-Path $repo 'tags.csv'
            if (Test-Path $tagsPath) {
                $tagLine = Get-Content $tagsPath | Where-Object { $_ -match "^${Target}," }
                if ($tagLine) {
                    $hash = ($tagLine -split ',')[1]
                    $entry = $history | Where-Object { $_.Hash -eq $hash }
                }
            }
        }
    }

    if (-not $entry) {
        Write-Error "Backup '$Target' not found."
        return
    }

    $dumpPath = Join-Path $backupDir $entry.Filename
    if (-not (Test-Path $dumpPath)) {
        Write-Error "Backup file not found at $dumpPath"
        return
    }

    $liveDb = $config.database
    $tmpDb  = "${liveDb}_restore_tmp"
    $oldDb  = "${liveDb}_old"
    foreach ($n in @($tmpDb, $oldDb)) {
        if ([System.Text.Encoding]::UTF8.GetByteCount($n) -gt 63) {
            Write-Error "Database name '$liveDb' is too long to derive '$n' (PostgreSQL limit is 63 bytes)."
            return
        }
    }

    if (-not $Force) {
        $confirm = Read-Host "Restore backup $($entry.Id) ($($entry.Hash)) into database '$liveDb'? Type 'yes' to continue"
        if ($confirm -ne 'yes') { Write-Host 'Restore aborted.'; return }
    }

    $env:PGPASSWORD = Unprotect-DbGitPassword -StoredPassword $config.password
    try {
        # --- 1. Restore into a temporary database --------------------------------------------
        if (Test-PgDatabaseExists -Config $config -Name $tmpDb) {
            Write-Host "Removing leftover temporary database '$tmpDb' from a previous run..."
            $r = Remove-PgDatabase -Config $config -Name $tmpDb
            if (-not $r.Ok) { throw "Could not drop leftover '$tmpDb': $($r.Output)" }
        }

        $create = Invoke-PgAdminSql -Config $config -Sql "CREATE DATABASE $(ConvertTo-PgIdent $tmpDb);"
        if (-not $create.Ok) {
            # No CREATEDB privilege (or similar): fall back to restoring in place.
            Write-Warning "Could not create temporary database '$tmpDb': $($create.Output)"
            Write-Warning "Falling back to in-place clean restore (pg_restore -c --if-exists) into '$liveDb'."
            Write-Warning "If this fails partway, '$liveDb' may be left partially restored."
            & pg_restore -h $config.host -p $config.port -U $config.username -d $liveDb -c --if-exists -Fc $dumpPath
            if ($LASTEXITCODE -ne 0) { throw "pg_restore exited with code $LASTEXITCODE (see errors above). HEAD was not updated." }
        } else {
            Write-Host "Restoring backup into temporary database '$tmpDb'..."
            & pg_restore -h $config.host -p $config.port -U $config.username -d $tmpDb -Fc $dumpPath
            if ($LASTEXITCODE -ne 0) {
                $code = $LASTEXITCODE
                Remove-PgDatabase -Config $config -Name $tmpDb | Out-Null
                throw "pg_restore exited with code $code (see errors above). '$liveDb' was NOT modified; temporary database removed."
            }
            Write-Host "Restore into temporary database succeeded."

            # --- 2. Swap it in ----------------------------------------------------------------
            $liveExists = Test-PgDatabaseExists -Config $config -Name $liveDb
            $liveOwner = $null
            if ($liveExists) {
                $o = Invoke-PgAdminSql -Config $config -Sql "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = $(ConvertTo-PgLiteral $liveDb);"
                if ($o.Ok) { $liveOwner = $o.Output }

                if (Test-PgDatabaseExists -Config $config -Name $oldDb) {
                    Write-Host "Dropping previous rollback copy '$oldDb'..."
                    $r = Remove-PgDatabase -Config $config -Name $oldDb
                    if (-not $r.Ok) {
                        Remove-PgDatabase -Config $config -Name $tmpDb | Out-Null
                        throw "Could not drop '$oldDb' to make room for the swap: $($r.Output). '$liveDb' was NOT modified."
                    }
                }

                Write-Host "Swapping databases (blocking and closing connections to '$liveDb')..."
                $block = Invoke-PgAdminSql -Config $config -Sql "ALTER DATABASE $(ConvertTo-PgIdent $liveDb) ALLOW_CONNECTIONS false;"
                if (-not $block.Ok) { Write-Warning "Could not block new connections (will still try): $($block.Output)" }

                # Apps with connection pools reconnect fast; retry terminate+rename a few times.
                $renamed = $null
                for ($attempt = 1; $attempt -le 5; $attempt++) {
                    Stop-PgConnections -Config $config -Name $liveDb
                    $renamed = Invoke-PgAdminSql -Config $config -Sql "ALTER DATABASE $(ConvertTo-PgIdent $liveDb) RENAME TO $(ConvertTo-PgIdent $oldDb);"
                    if ($renamed.Ok) { break }
                    Start-Sleep -Milliseconds 500
                }
                if (-not $renamed.Ok) {
                    Invoke-PgAdminSql -Config $config -Sql "ALTER DATABASE $(ConvertTo-PgIdent $liveDb) ALLOW_CONNECTIONS true;" | Out-Null
                    throw "Could not rename '$liveDb' (active connections or insufficient privileges): $($renamed.Output). '$liveDb' was NOT modified; the restored copy is left in '$tmpDb'."
                }
            }

            $promote = Invoke-PgAdminSql -Config $config -Sql "ALTER DATABASE $(ConvertTo-PgIdent $tmpDb) RENAME TO $(ConvertTo-PgIdent $liveDb);"
            if (-not $promote.Ok) {
                if ($liveExists) {
                    # Put the original back.
                    Invoke-PgAdminSql -Config $config -Sql "ALTER DATABASE $(ConvertTo-PgIdent $oldDb) RENAME TO $(ConvertTo-PgIdent $liveDb);" | Out-Null
                    Invoke-PgAdminSql -Config $config -Sql "ALTER DATABASE $(ConvertTo-PgIdent $liveDb) ALLOW_CONNECTIONS true;" | Out-Null
                }
                throw "Could not rename '$tmpDb' to '$liveDb': $($promote.Output). Original database was put back; the restored copy is left in '$tmpDb'."
            }
            Write-Host "Database '$liveDb' now contains backup $($entry.Id) ($($entry.Hash))."

            # Keep the original owner on the restored database.
            if ($liveOwner -and $liveOwner -ne $config.username) {
                $own = Invoke-PgAdminSql -Config $config -Sql "ALTER DATABASE $(ConvertTo-PgIdent $liveDb) OWNER TO $(ConvertTo-PgIdent $liveOwner);"
                if (-not $own.Ok) { Write-Warning "Could not set owner of '$liveDb' back to '$liveOwner': $($own.Output)" }
            }

            # --- 3. Handle the old copy ---------------------------------------------------------
            if ($liveExists) {
                if ($DropOld) {
                    $r = Remove-PgDatabase -Config $config -Name $oldDb
                    if ($r.Ok) { Write-Host "Dropped previous database '$oldDb'." }
                    else { Write-Warning "Could not drop '$oldDb': $($r.Output)" }
                } else {
                    # Connections were only blocked so the rename could succeed; re-enable so it can be inspected.
                    $unblock = Invoke-PgAdminSql -Config $config -Sql "ALTER DATABASE $(ConvertTo-PgIdent $oldDb) ALLOW_CONNECTIONS true;"
                    if (-not $unblock.Ok) { Write-Warning "Could not re-enable connections on '$oldDb': $($unblock.Output)" }
                    Write-Host "Previous database kept as '$oldDb'. It is replaced on the next restore."
                    Write-Host "  Rollback: ALTER DATABASE `"$liveDb`" RENAME TO `"${liveDb}_bad`";"
                    Write-Host "            ALTER DATABASE `"$oldDb`" RENAME TO `"$liveDb`";"
                    Write-Host "  (close any open connections to both databases first)"
                }
            }
        }

        # Update HEAD pointer to the restored backup hash
        Set-HeadHash -Hash $entry.Hash

        Write-Host "Restore completed successfully."
        Write-Host "HEAD updated to point to commit $($entry.Hash)"
    } catch {
        Write-Error "Restore failed: $_"
    } finally {
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Cmd-restore
