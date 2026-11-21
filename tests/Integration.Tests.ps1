#Requires -Version 7
# Integration tests: run the real db_git CLI against a real PostgreSQL server.
#
# Needs a THROWAWAY server (the tests create and drop databases). Easiest:
#   ./tests/Run-Tests.ps1 -Integration      # starts a postgres container for you
#
# Or point at your own server with:
#   DBGIT_TEST_HOST, DBGIT_TEST_PORT, DBGIT_TEST_USER, DBGIT_TEST_PASSWORD
# The user needs CREATEDB (a superuser in a container is simplest).

BeforeDiscovery {
    $script:skipIntegration = -not $env:DBGIT_TEST_HOST
}

Describe 'db_git end-to-end' -Tag 'Integration' -Skip:$skipIntegration {
    BeforeAll {
        $script:entry = Join-Path (Split-Path -Parent $PSScriptRoot) 'db_git.ps1'
        $script:pg = @{
            Host     = $env:DBGIT_TEST_HOST
            Port     = if ($env:DBGIT_TEST_PORT) { $env:DBGIT_TEST_PORT } else { '5432' }
            User     = if ($env:DBGIT_TEST_USER) { $env:DBGIT_TEST_USER } else { 'postgres' }
            Password = $env:DBGIT_TEST_PASSWORD
        }
        # Hyphenated + mixed-case names on purpose: these broke unquoted SQL before.
        $script:db  = "db-git-Test-$(Get-Random -Maximum 99999)"
        $script:old = "${db}_old"
        $script:tmp = "${db}_restore_tmp"

        function Invoke-Sql {
            param([string]$Database, [string]$Sql)
            $env:PGPASSWORD = $pg.Password
            $out = & psql -h $pg.Host -p $pg.Port -U $pg.User -d $Database -v ON_ERROR_STOP=1 -Atc $Sql 2>&1
            if ($LASTEXITCODE -ne 0) { throw "psql failed on '$Database': $out" }
            return $out
        }
        function Test-Db {
            param([string]$Name)
            (Invoke-Sql postgres "SELECT count(*) FROM pg_database WHERE datname = '$($Name -replace "'", "''")'") -eq '1'
        }
        function Invoke-DbGit {
            $out = & pwsh -NoProfile -NonInteractive -File $script:entry @args 2>&1 | Out-String
            Write-Verbose $out
            return $out
        }
        function Get-History { @(Get-Content .db_git/history.csv | Where-Object { $_ -match '\S' }) }

        # Seed database: a table with a primary key and uppercase names, and one without a PK.
        Invoke-Sql postgres "CREATE DATABASE `"$db`";" | Out-Null
        Invoke-Sql $db @'
CREATE TABLE "BaseRate" (id int PRIMARY KEY, "Age_min" int, "Age_max" int);
INSERT INTO "BaseRate" VALUES (1, 18, 25), (2, 26, 35), (3, 36, 50);
CREATE TABLE "Notes" (body text);
INSERT INTO "Notes" VALUES ('a'), ('b');
'@ | Out-Null

        $script:state = @{}   # values shared between It blocks (hashes)
        $script:work = Join-Path $TestDrive 'project'
        New-Item -ItemType Directory $work | Out-Null
        Push-Location $work
    }

    AfterAll {
        Pop-Location
        foreach ($name in @($db, $old, $tmp, "${db}_bad")) {
            try {
                Invoke-Sql postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$name';" | Out-Null
                Invoke-Sql postgres "DROP DATABASE IF EXISTS `"$name`";" | Out-Null
            } catch { Write-Warning "Cleanup of '$name' failed: $_" }
        }
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    }

    It 'init writes a config for a hyphenated database name' {
        Invoke-DbGit init --db $db --host $pg.Host --port $pg.Port --user $pg.User --password $pg.Password | Out-Null
        (Get-Content .db_git/config.json -Raw | ConvertFrom-Json).database | Should -Be $db
        Get-Content .gitignore | Should -Contain '.db_git/'
    }

    It 'cb creates snapshot 1 and moves HEAD' {
        Invoke-DbGit cb -m 'seed' | Out-Null
        $h = @(Get-History)   # @() : a single line would otherwise come back as a plain string
        $h.Count | Should -Be 1
        $state.hash1 = ($h[0] -split ',')[1]
        (Get-Content .db_git/HEAD -Raw).Trim() | Should -Be $state.hash1
        Test-Path (Join-Path .db_git/db_backups ($h[0] -split ',')[5]) | Should -BeTrue
    }

    It 'records real row counts for mixed-case tables (regression: unquoted COUNT)' {
        $meta = Get-Content .db_git/metadata/backup_1.json -Raw | ConvertFrom-Json
        ($meta.tables | Where-Object name -eq 'BaseRate').rows | Should -Be 3
        ($meta.tables | Where-Object name -eq 'Notes').rows    | Should -Be 2
    }

    It 'cb with commas in the message keeps history parseable' {
        Invoke-Sql $db @'
DELETE FROM "BaseRate" WHERE id = 3;
UPDATE "BaseRate" SET "Age_max" = 30 WHERE id = 1;
INSERT INTO "BaseRate" VALUES (4, 51, 60), (5, 61, 70);
ALTER TABLE "Notes" ADD COLUMN created_on date;
'@ | Out-Null
        Invoke-DbGit cb -m 'changed rates, step 2' | Out-Null
        $h = @(Get-History)   # @() : a single line would otherwise come back as a plain string
        $h.Count | Should -Be 2
        ($h[1] -split ',').Count | Should -Be 8
        $state.hash2 = ($h[1] -split ',')[1]
        ($h[1] -split ',')[2] | Should -Be $state.hash1   # parent
    }

    It 'diff prints schema changes to the console and opens no HTML report without --gui (regression: switch passing)' {
        $out = Invoke-DbGit diff 1 2
        $out | Should -Match 'Columns'
        $out | Should -Match 'created_on'
        $out | Should -Not -Match 'GUI diff report'
        @(Get-ChildItem .db_git/temp -Filter *.html -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'diff --data reports row changes in mixed-case tables (regression: unquoted SELECT)' {
        $out = Invoke-DbGit diff 1 2 --data
        $out | Should -Match 'public\.BaseRate'
        $out | Should -Match '\+2 rows'
        $out | Should -Match '-1 rows'
        $out | Should -Match '~1 modified'
    }

    It 'diff cleans up its temporary databases' {
        Invoke-Sql postgres "SELECT count(*) FROM pg_database WHERE datname LIKE 'db_git_tmp_%'" | Should -Be '0'
    }

    It 'verify passes for a good snapshot' {
        Invoke-DbGit verify 1 | Should -Match 'PASS'
    }

    It 'restore swaps in the snapshot and keeps the previous db as _old' {
        Invoke-DbGit restore 1 --force | Out-Null
        Invoke-Sql $db 'SELECT count(*) FROM "BaseRate"' | Should -Be '3'
        Invoke-Sql $db 'SELECT "Age_max" FROM "BaseRate" WHERE id = 1' | Should -Be '25'
        (Get-Content .db_git/HEAD -Raw).Trim() | Should -Be $state.hash1
        Test-Db $tmp | Should -BeFalse
        Test-Db $old | Should -BeTrue
    }

    It 'leaves _old connectable with the pre-restore data' {
        Invoke-Sql $old 'SELECT count(*) FROM "BaseRate"' | Should -Be '4'
    }

    It 'restore --drop-old removes the previous database' {
        Invoke-DbGit restore 2 --force --drop-old | Out-Null
        Invoke-Sql $db 'SELECT count(*) FROM "BaseRate"' | Should -Be '4'
        (Get-Content .db_git/HEAD -Raw).Trim() | Should -Be $state.hash2
        Test-Db $old | Should -BeFalse
    }

    It 'a failed restore leaves the live database and HEAD untouched' {
        # Corrupt snapshot 1's dump file so pg_restore fails.
        $file = (@(Get-History)[0] -split ',')[5]
        Set-Content (Join-Path .db_git/db_backups $file) 'this is not a pg_dump archive'

        Invoke-DbGit restore 1 --force | Out-Null

        Invoke-Sql $db 'SELECT count(*) FROM "BaseRate"' | Should -Be '4'
        (Get-Content .db_git/HEAD -Raw).Trim() | Should -Be $state.hash2
        Test-Db $tmp | Should -BeFalse
    }

    It 'verify reports the corrupted snapshot as failed' {
        Invoke-DbGit verify 1 | Should -Match 'FAIL'
    }
}
