#Requires -Version 7
# Unit tests: no PostgreSQL needed. Run with:  ./tests/Run-Tests.ps1 -Unit

BeforeAll {
    $script:root    = Split-Path -Parent $PSScriptRoot
    $script:modules = Join-Path $root 'Modules'
    $script:entry   = Join-Path $root 'db_git.ps1'
    Get-ChildItem $modules -Filter *.psm1 | ForEach-Object { Import-Module $_.FullName -Force -DisableNameChecking }

    function New-TestRepo {
        # Fresh working dir with an empty .db_git layout, like 'db_git init' without the config step.
        $dir = Join-Path $TestDrive ([guid]::NewGuid())
        foreach ($d in '.db_git', '.db_git/db_backups', '.db_git/metadata', '.db_git/temp') {
            New-Item -ItemType Directory -Path (Join-Path $dir $d) -Force | Out-Null
        }
        foreach ($f in 'HEAD', 'history.csv', 'tags.csv') { New-Item -ItemType File -Path (Join-Path $dir ".db_git/$f") | Out-Null }
        return $dir
    }
}

Describe 'SQL quoting helpers' {
    It 'quotes identifiers: <Name> -> <Expected>' -ForEach @(
        @{ Name = 'my-app-db';     Expected = '"my-app-db"' }
        @{ Name = 'BaseRate';      Expected = '"BaseRate"' }
        @{ Name = 'select';        Expected = '"select"' }
        @{ Name = 'we"ird';        Expected = '"we""ird"' }
        @{ Name = 'x"; DROP TABLE t; --'; Expected = '"x""; DROP TABLE t; --"' }
    ) {
        ConvertTo-PgIdent $Name | Should -BeExactly $Expected
    }

    It 'quotes literals: <Value> -> <Expected>' -ForEach @(
        @{ Value = 'plain';                 Expected = "'plain'" }
        @{ Value = "O'Brien";               Expected = "'O''Brien'" }
        @{ Value = '';                      Expected = "''" }
        @{ Value = "x' OR '1'='1";          Expected = "'x'' OR ''1''=''1'" }
    ) {
        ConvertTo-PgLiteral $Value | Should -BeExactly $Expected
    }

    It 'quotes schema-qualified names from parts' {
        ConvertTo-PgQualifiedName -Schema 'public' -Table 'BaseRate' | Should -BeExactly '"public"."BaseRate"'
    }

    It 'splits "schema.table" on the first dot only' {
        ConvertTo-PgQualifiedName -Name 'public.BaseRateCalculation2' | Should -BeExactly '"public"."BaseRateCalculation2"'
        ConvertTo-PgQualifiedName -Name 'app.odd.name'               | Should -BeExactly '"app"."odd.name"'
    }

    It 'quotes a bare name with no schema as a single identifier' {
        ConvertTo-PgQualifiedName -Name 'NoSchema' | Should -BeExactly '"NoSchema"'
    }
}

Describe 'History file' {
    BeforeEach { Push-Location (New-TestRepo) }
    AfterEach  { Pop-Location }

    It 'starts ids at 1 for an empty history' {
        Get-NextBackupId | Should -Be 1
    }

    It 'round-trips an entry through Write-HistoryEntry / Get-HistoryEntries' {
        Write-HistoryEntry -Id 1 -Hash 'abc123' -ParentHash '' -Date '2026-01-01 10:00:00' -Database 'my-app-db' -Filename 'backup_1.sql' -Size 2048 -Message 'first'
        $e = @(Get-HistoryEntries)
        $e.Count       | Should -Be 1
        $e[0].Id       | Should -Be 1
        $e[0].Hash     | Should -Be 'abc123'
        $e[0].Database | Should -Be 'my-app-db'
        $e[0].Size     | Should -Be 2048
        $e[0].Message  | Should -Be 'first'
    }

    It 'increments the next id' {
        Write-HistoryEntry -Id 1 -Hash 'a' -ParentHash '' -Date 'd' -Database 'db' -Filename 'f' -Size 1 -Message 'm'
        Write-HistoryEntry -Id 2 -Hash 'b' -ParentHash 'a' -Date 'd' -Database 'db' -Filename 'f' -Size 1 -Message 'm'
        Get-NextBackupId | Should -Be 3
    }

    It 'keeps the 8-column layout when the message contains commas' {
        Write-HistoryEntry -Id 1 -Hash 'a' -ParentHash '' -Date 'd' -Database 'db' -Filename 'f' -Size 1 -Message 'before migration, step 1, retry'
        $e = @(Get-HistoryEntries)
        $e[0].Message  | Should -Be 'before migration; step 1; retry'
        $e[0].Filename | Should -Be 'f'
        $e[0].Size     | Should -Be 1
    }
}

Describe 'HEAD and hashing' {
    BeforeEach { Push-Location (New-TestRepo) }
    AfterEach  { Pop-Location }

    It 'returns $null when HEAD is empty' {
        Get-HeadHash | Should -BeNullOrEmpty
    }

    It 'round-trips HEAD' {
        Set-HeadHash -Hash 'ABC123'
        Get-HeadHash | Should -Be 'ABC123'
    }

    It 'computes a stable 6-character hash' {
        $f = Join-Path $TestDrive 'dump.bin'
        Set-Content $f 'some dump content'
        $h = Compute-Hash -FilePath $f
        $h        | Should -Match '^[0-9A-F]{6}$'
        Compute-Hash -FilePath $f | Should -Be $h
    }

    It 'returns $null hash for a missing file' {
        Compute-Hash -FilePath (Join-Path $TestDrive 'missing.bin') | Should -BeNullOrEmpty
    }
}

Describe 'Ensure-DbGitIgnored' {
    BeforeEach {
        $script:dir = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $dir | Out-Null
        Push-Location $dir
    }
    AfterEach { Pop-Location }

    It 'creates .gitignore when missing' {
        Ensure-DbGitIgnored | Should -BeTrue
        Get-Content .gitignore | Should -Contain '.db_git/'
    }

    It 'appends to an existing .gitignore without touching other lines' {
        Set-Content .gitignore @('node_modules/', '*.log')
        Ensure-DbGitIgnored | Should -BeTrue
        $lines = Get-Content .gitignore
        $lines | Should -Contain 'node_modules/'
        $lines | Should -Contain '*.log'
        $lines | Should -Contain '.db_git/'
    }

    It 'is idempotent' {
        Ensure-DbGitIgnored | Out-Null
        Ensure-DbGitIgnored | Should -BeFalse
        @(Get-Content .gitignore | Where-Object { $_ -eq '.db_git/' }).Count | Should -Be 1
    }
}

Describe 'Configuration' {
    BeforeEach { Push-Location (New-TestRepo) }
    AfterEach  { Pop-Location }

    It 'encrypts and decrypts a password (DPAPI)' -Skip:(-not $IsWindows) {
        $enc = Protect-DbGitPassword -PlainPassword 's3cret!'
        $enc | Should -Not -Be 's3cret!'
        Unprotect-DbGitPassword -StoredPassword $enc | Should -BeExactly 's3cret!'
    }

    It 'treats a legacy plaintext password as plaintext' {
        Unprotect-DbGitPassword -StoredPassword 'plain-legacy' | Should -BeExactly 'plain-legacy'
    }

    It 'never writes the password to config.json in plaintext' -Skip:(-not $IsWindows) {
        Set-DbGitConfig -Config @{ database = 'db'; host = 'h'; port = 5432; username = 'u'; password = 'p4ss' }
        Get-Content .db_git/config.json -Raw | Should -Not -Match 'p4ss'
        Unprotect-DbGitPassword -StoredPassword (Get-DbGitConfig).password | Should -BeExactly 'p4ss'
    }

    It 'does not double-encrypt an already encrypted password on re-save' -Skip:(-not $IsWindows) {
        Set-DbGitConfig -Config @{ database = 'db'; password = 'p4ss' }
        $cfg = Get-DbGitConfig
        Set-DbGitConfig -Config $cfg
        Unprotect-DbGitPassword -StoredPassword (Get-DbGitConfig).password | Should -BeExactly 'p4ss'
    }

    It 'reads connection details from command-line flags' {
        $cfg = Initialize-DbGitConfig -InitArgs @('--db', 'my-app-db', '--host', 'db.local', '--port', '6543', '--user', 'me', '--password', 'pw')
        $cfg.database | Should -Be 'my-app-db'
        $cfg.host     | Should -Be 'db.local'
        $cfg.port     | Should -Be 6543
        $cfg.username | Should -Be 'me'
    }

    It 'reads DATABASE_URL from .env (<Url>)' -ForEach @(
        @{ Url = 'postgres://me:pw@db.local:6543/my-app-db';   Port = 6543 }
        @{ Url = 'postgresql://me:pw@db.local/my-app-db';      Port = 5432 }
    ) {
        Set-Content .env @('OTHER=1', "DATABASE_URL=$Url")
        $cfg = Initialize-DbGitConfig
        $cfg.database | Should -Be 'my-app-db'
        $cfg.host     | Should -Be 'db.local'
        $cfg.port     | Should -Be $Port
        $cfg.username | Should -Be 'me'
    }
}

Describe 'Command-line dispatcher' {
    BeforeAll {
        function Invoke-DbGit {
            $out = & pwsh -NoProfile -NonInteractive -File $script:entry @args 2>&1 | Out-String
            [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
        }
    }

    It 'prints usage and exits 0 with no arguments' {
        $r = Invoke-DbGit
        $r.Code   | Should -Be 0
        $r.Output | Should -Match 'Usage: db_git'
    }

    It 'exits 1 on an unknown command' {
        $r = Invoke-DbGit 'definitely-not-a-command'
        $r.Code   | Should -Be 1
        $r.Output | Should -Match 'Unknown command'
    }

    It 'shows per-command help, including --drop-old for restore' {
        (Invoke-DbGit help restore).Output | Should -Match '--drop-old'
    }

    It 'exposes --drop-old as an alias of the DropOld switch' {
        (Get-Command Cmd-restore).Parameters['DropOld'].Aliases | Should -Contain 'drop-old'
    }

    It 'has a Cmd- function for every alias target' -ForEach @(
        @{ Cmd = 'create-backup' }, @{ Cmd = 'list' }, @{ Cmd = 'history' },
        @{ Cmd = 'configuration' }, @{ Cmd = 'list-tags' }, @{ Cmd = 'delete' }
    ) {
        Get-Command "Cmd-$Cmd" -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}
