# Diff.psm1

# Implements the diff command.

function Cmd-diff {
    <#
    .SYNOPSIS
        Diff two database backups.
    .DESCRIPTION
        Restores both backups into temporary PostgreSQL databases and compares their schema and/or data.
    .PARAMETER Source
        The source backup identifier (ID, hash, or tag).
    .PARAMETER Target
        The target backup identifier (ID, hash, or tag).
    .PARAMETER Data
        Compare table data.
    .PARAMETER All
        Compare both schema and data.
    .PARAMETER Table
        Only compare a specific table.
    .PARAMETER Verbose
        Show detailed modified rows/columns.
    .EXAMPLE
        db_git diff 4 7
        db_git diff 4 7 --data
        db_git diff 4 7 --all --table users --verbose
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Source,
        [Parameter(Mandatory=$true, Position=1)]
        [string]$Target,
        [switch]$Data,
        [switch]$All,
        [string]$Table,
        [Alias('g')]
        [switch]$Gui
    )

    Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking

    $config = Get-DbGitConfig
    if (-not $config) { return }

    $history = Get-HistoryEntries

    # Resolve backup entries
    $entryA = Resolve-BackupEntry -Target $Source -History $history
    $entryB = Resolve-BackupEntry -Target $Target -History $history

    if (-not $entryA) {
        Write-Error "Source backup '$Source' not found."
        return
    }
    if (-not $entryB) {
        Write-Error "Target backup '$Target' not found."
        return
    }

    $backupDir = Get-BackupDir
    $dumpA = Join-Path $backupDir $entryA.Filename
    $dumpB = Join-Path $backupDir $entryB.Filename

    if (-not (Test-Path $dumpA)) {
        Write-Error ("Backup file missing for " + $Source + ": " + $entryA.Filename)
        return
    }
    if (-not (Test-Path $dumpB)) {
        Write-Error ("Backup file missing for " + $Target + ": " + $entryB.Filename)
        return
    }

    $dbA = "db_git_tmp_a_$($entryA.Hash)".ToLower()
    $dbB = "db_git_tmp_b_$($entryB.Hash)".ToLower()

    $pwd = Unprotect-DbGitPassword -StoredPassword $config.password

    Write-Host "Creating temporary databases for comparison..."
    $env:PGPASSWORD = $pwd

    try {
        # Drop if already exist
        & psql -h $config.host -p $config.port -U $config.username -d postgres -c "DROP DATABASE IF EXISTS $(ConvertTo-PgIdent $dbA);" 2>$null | Out-Null
        & psql -h $config.host -p $config.port -U $config.username -d postgres -c "DROP DATABASE IF EXISTS $(ConvertTo-PgIdent $dbB);" 2>$null | Out-Null

        # Create
        & psql -h $config.host -p $config.port -U $config.username -d postgres -c "CREATE DATABASE $(ConvertTo-PgIdent $dbA);" 2>&1 | Out-Null
        & psql -h $config.host -p $config.port -U $config.username -d postgres -c "CREATE DATABASE $(ConvertTo-PgIdent $dbB);" 2>&1 | Out-Null

        Write-Host "Restoring source backup '$Source' ($($entryA.Hash))..."
        $processA = Start-Process -FilePath "pg_restore" -ArgumentList "-h $($config.host) -p $($config.port) -U $($config.username) -d $dbA -Fc `"$dumpA`"" -NoNewWindow -PassThru -Wait
        if ($processA.ExitCode -ne 0) { throw "Failed to restore source backup into $dbA" }

        Write-Host "Restoring target backup '$Target' ($($entryB.Hash))..."
        $processB = Start-Process -FilePath "pg_restore" -ArgumentList "-h $($config.host) -p $($config.port) -U $($config.username) -d $dbB -Fc `"$dumpB`"" -NoNewWindow -PassThru -Wait
        if ($processB.ExitCode -ne 0) { throw "Failed to restore target backup into $dbB" }

        # Run Comparison
        $VerboseMode = $PSBoundParameters.ContainsKey('Verbose')
        Compare-Databases -DbA $dbA -DbB $dbB -Config $config -Data $Data -All $All -TableFilter $Table -VerboseMode $VerboseMode -GuiMode:$Gui

    } catch {
        Write-Error "Diff failed: $_"
    } finally {
        Write-Host "Cleaning up temporary databases..."
        if ($dbA) {
            $termA = "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $(ConvertTo-PgLiteral $dbA) AND pid <> pg_backend_pid();"
            & psql -h $config.host -p $config.port -U $config.username -d postgres -c $termA 2>$null | Out-Null
            & psql -h $config.host -p $config.port -U $config.username -d postgres -c "DROP DATABASE IF EXISTS $(ConvertTo-PgIdent $dbA);" 2>$null | Out-Null
        }
        if ($dbB) {
            $termB = "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $(ConvertTo-PgLiteral $dbB) AND pid <> pg_backend_pid();"
            & psql -h $config.host -p $config.port -U $config.username -d postgres -c $termB 2>$null | Out-Null
            & psql -h $config.host -p $config.port -U $config.username -d postgres -c "DROP DATABASE IF EXISTS $(ConvertTo-PgIdent $dbB);" 2>$null | Out-Null
        }
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    }
}

function Resolve-BackupEntry {
    param($Target, $History)
    $entry = $null
    if ($Target -eq 'latest') {
        $headHash = Get-HeadHash
        $entry = $History | Where-Object { $_.Hash -eq $headHash }
    } else {
        if ($Target -as [int]) {
            $entry = $History | Where-Object { $_.Id -eq [int]$Target }
        }
        if (-not $entry) {
            $entry = $History | Where-Object { $_.Hash -like "${Target}*" }
        }
        if (-not $entry) {
            # Check tags
            $repo = Get-DbGitRepoPath
            $tagsPath = Join-Path $repo 'tags.csv'
            if (Test-Path $tagsPath) {
                $tagLine = Get-Content $tagsPath | Where-Object { $_ -match "^${Target}," }
                if ($tagLine) {
                    $hash = ($tagLine -split ',')[1]
                    $entry = $History | Where-Object { $_.Hash -eq $hash }
                }
            }
        }
    }
    return $entry
}

function Compare-Databases {
    param(
        $DbA,
        $DbB,
        $Config,
        $Data,
        $All,
        $TableFilter,
        $VerboseMode,
        [switch]$GuiMode
    )

    $compareSchema = -not $Data -or $All
    $compareData = $Data -or $All

    $diffResult = [pscustomobject]@{
        Source      = $DbA
        Target      = $DbB
        Tables      = $null
        Columns     = $null
        Indexes     = $null
        Constraints = $null
        Sequences   = $null
        Views       = $null
        Triggers    = $null
        Data        = @()
    }

    # --- SCHEMA COMPARISON ---
    if ($compareSchema) {
        if (-not $GuiMode) {
            Write-Host "`n=== SCHEMA DIFF ===" -ForegroundColor Green
        }

        # Helper to query schema structures
        $queryTables = "SELECT schemaname, tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1,2;"
        $tablesA = Query-Db -Db $DbA -Config $Config -Query $queryTables
        $tablesB = Query-Db -Db $DbB -Config $Config -Query $queryTables
        $diffResult.Tables = Compare-Lists -ListA $tablesA -ListB $tablesB -Label "Tables" -Silent:$GuiMode

        # Compare column details
        $queryColumns = "SELECT table_schema || '.' || table_name, column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema NOT IN ('pg_catalog','information_schema') ORDER BY 1,2;"
        $colsA = Query-Db -Db $DbA -Config $Config -Query $queryColumns
        $colsB = Query-Db -Db $DbB -Config $Config -Query $queryColumns
        $diffResult.Columns = Compare-Lists -ListA $colsA -ListB $colsB -Label "Columns" -Silent:$GuiMode

        # Compare indexes
        $queryIndexes = "SELECT schemaname || '.' || tablename || '.' || indexname, indexdef FROM pg_indexes WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1;"
        $idxA = Query-Db -Db $DbA -Config $Config -Query $queryIndexes
        $idxB = Query-Db -Db $DbB -Config $Config -Query $queryIndexes
        $diffResult.Indexes = Compare-Lists -ListA $idxA -ListB $idxB -Label "Indexes" -Silent:$GuiMode

        # Compare constraints
        $queryConstraints = "SELECT table_schema || '.' || table_name || '.' || constraint_name, constraint_type FROM information_schema.table_constraints WHERE table_schema NOT IN ('pg_catalog','information_schema') AND constraint_name !~ '_not_null$' ORDER BY 1;"
        $conA = Query-Db -Db $DbA -Config $Config -Query $queryConstraints
        $conB = Query-Db -Db $DbB -Config $Config -Query $queryConstraints
        $diffResult.Constraints = Compare-Lists -ListA $conA -ListB $conB -Label "Constraints" -Silent:$GuiMode

        # Compare sequences
        $querySequences = "SELECT sequence_schema || '.' || sequence_name FROM information_schema.sequences WHERE sequence_schema NOT IN ('pg_catalog','information_schema') ORDER BY 1;"
        $seqA = Query-Db -Db $DbA -Config $Config -Query $querySequences
        $seqB = Query-Db -Db $DbB -Config $Config -Query $querySequences
        $diffResult.Sequences = Compare-Lists -ListA $seqA -ListB $seqB -Label "Sequences" -Silent:$GuiMode

        # Compare views
        $queryViews = "SELECT table_schema || '.' || table_name, view_definition FROM information_schema.views WHERE table_schema NOT IN ('pg_catalog','information_schema') ORDER BY 1;"
        $viewA = Query-Db -Db $DbA -Config $Config -Query $queryViews
        $viewB = Query-Db -Db $DbB -Config $Config -Query $queryViews
        $diffResult.Views = Compare-Lists -ListA $viewA -ListB $viewB -Label "Views" -Silent:$GuiMode

        # Compare triggers
        $queryTriggers = "SELECT trigger_schema || '.' || trigger_name || ' ON ' || event_object_table, action_statement FROM information_schema.triggers WHERE trigger_schema NOT IN ('pg_catalog','information_schema') ORDER BY 1;"
        $trgA = Query-Db -Db $DbA -Config $Config -Query $queryTriggers
        $trgB = Query-Db -Db $DbB -Config $Config -Query $queryTriggers
        $diffResult.Triggers = Compare-Lists -ListA $trgA -ListB $trgB -Label "Triggers" -Silent:$GuiMode
    }

    # --- DATA COMPARISON ---
    if ($compareData) {
        if (-not $GuiMode) {
            Write-Host "`n=== DATA DIFF ===" -ForegroundColor Green
        }

        $queryTables = "SELECT schemaname || '.' || tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1;"
        $tables = Query-Db -Db $DbA -Config $Config -Query $queryTables | ForEach-Object { $_.Trim() }

        foreach ($tbl in $tables) {
            if ($TableFilter -and $tbl -notmatch $TableFilter) { continue }

            # Verify table exists in both
            $tblLiteral = ConvertTo-PgLiteral $tbl
            $existsA = Query-Db -Db $DbA -Config $Config -Query "SELECT EXISTS (SELECT FROM pg_tables WHERE schemaname || '.' || tablename = $tblLiteral);"
            $existsB = Query-Db -Db $DbB -Config $Config -Query "SELECT EXISTS (SELECT FROM pg_tables WHERE schemaname || '.' || tablename = $tblLiteral);"

            if ($existsA.Trim() -ne "t") {
                if (-not $GuiMode) {
                    Write-Host ($tbl + ": Added entirely") -ForegroundColor Green
                }
                $diffResult.Data += [pscustomobject]@{
                    TableName = $tbl
                    Status    = "Added"
                    Inserted  = @()
                    Deleted   = @()
                    Modified  = @()
                }
                continue
            }
            if ($existsB.Trim() -ne "t") {
                if (-not $GuiMode) {
                    Write-Host ($tbl + ": Deleted entirely") -ForegroundColor Red
                }
                $diffResult.Data += [pscustomobject]@{
                    TableName = $tbl
                    Status    = "Deleted"
                    Inserted  = @()
                    Deleted   = @()
                    Modified  = @()
                }
                continue
            }

            # Fetch rows
            $rowsA = Query-Db-Rows -Db $DbA -Config $Config -Table $tbl
            $rowsB = Query-Db-Rows -Db $DbB -Config $Config -Table $tbl

            # Find primary key
            $pkQuery = "
                SELECT kcu.column_name 
                FROM information_schema.table_constraints tc 
                JOIN information_schema.key_column_usage kcu ON tc.constraint_name = kcu.constraint_name 
                WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_schema || '.' || tc.table_name = $tblLiteral;
            "
            $pkCols = Query-Db -Db $DbA -Config $Config -Query $pkQuery | ForEach-Object { $_.Trim() }

            if ($pkCols -and $pkCols.Count -gt 0) {
                # PK exists: key-based compare
                $dictA = @{}
                foreach ($r in $rowsA) {
                    $key = ($pkCols | ForEach-Object { $r.$_ }) -join "|"
                    if ($key) { $dictA[$key] = $r }
                }

                $dictB = @{}
                foreach ($r in $rowsB) {
                    $key = ($pkCols | ForEach-Object { $r.$_ }) -join "|"
                    if ($key) { $dictB[$key] = $r }
                }

                $added = 0
                $deleted = 0
                $modified = 0

                $addedKeys = @()
                $deletedKeys = @()
                $modifiedKeys = @{}

                foreach ($k in $dictB.Keys) {
                    if (-not $dictA.ContainsKey($k)) {
                        $added++
                        $addedKeys += $k
                    } else {
                        # Compare columns
                        $diffCols = @()
                        $rA = $dictA[$k]
                        $rB = $dictB[$k]
                        foreach ($prop in $rB.PSObject.Properties) {
                            if ($prop.Name -in $pkCols) { continue }
                            if ($rA.$($prop.Name) -ne $prop.Value) {
                                $diffCols += [pscustomobject]@{
                                    Column = $prop.Name
                                    Old    = $rA.$($prop.Name)
                                    New    = $prop.Value
                                }
                            }
                        }
                        if ($diffCols.Count -gt 0) {
                            $modified++
                            $modifiedKeys[$k] = $diffCols
                        }
                    }
                }

                foreach ($k in $dictA.Keys) {
                    if (-not $dictB.ContainsKey($k)) {
                        $deleted++
                        $deletedKeys += $k
                    }
                }

                if ($added -gt 0 -or $deleted -gt 0 -or $modified -gt 0) {
                    if (-not $GuiMode) {
                        Write-Host "$tbl" -ForegroundColor Yellow
                        if ($added -gt 0)    { Write-Host "  +$added rows" -ForegroundColor Green }
                        if ($deleted -gt 0)  { Write-Host "  -$deleted rows" -ForegroundColor Red }
                        if ($modified -gt 0) { Write-Host "  ~$modified modified" -ForegroundColor Cyan }

                        if ($VerboseMode) {
                            if ($addedKeys.Count -gt 0) {
                                Write-Host "  Added keys: $($addedKeys -join ', ')" -ForegroundColor Green
                            }
                            if ($deletedKeys.Count -gt 0) {
                                Write-Host "  Deleted keys: $($deletedKeys -join ', ')" -ForegroundColor Red
                            }
                            if ($modifiedKeys.Count -gt 0) {
                                Write-Host "  Modified rows detail:" -ForegroundColor Cyan
                                foreach ($k in $modifiedKeys.Keys) {
                                    Write-Host "    Key: $k"
                                    foreach ($diff in $modifiedKeys[$k]) {
                                        Write-Host ("      " + $diff.Column + ": " + $diff.Old + " -> " + $diff.New) -ForegroundColor Gray
                                    }
                                }
                            }
                        }
                    }

                    # Collect modified rows details for GUI
                    $modRowsForGui = @()
                    foreach ($k in $modifiedKeys.Keys) {
                        $modRowsForGui += [pscustomobject]@{
                            PrimaryKey = $k
                            Changes    = $modifiedKeys[$k]
                        }
                    }

                    $diffResult.Data += [pscustomobject]@{
                        TableName = $tbl
                        Status    = "Modified"
                        Inserted  = $addedKeys
                        Deleted   = $deletedKeys
                        Modified  = $modRowsForGui
                    }
                }
            } else {
                # No PK: row counting / general hashing
                $countA = $rowsA.Count
                $countB = $rowsB.Count
                if ($countA -ne $countB) {
                    if (-not $GuiMode) {
                        Write-Host "$tbl" -ForegroundColor Yellow
                        Write-Host "  Count mismatch: Source=$countA, Target=$countB"
                    }
                    $diffResult.Data += [pscustomobject]@{
                        TableName = $tbl
                        Status    = "Modified (Count Mismatch)"
                        Inserted  = @()
                        Deleted   = @()
                        Modified  = @()
                    }
                }
            }
        }
    }

    # Generate HTML if GUI mode is enabled
    if ($GuiMode) {
        $repo = Get-DbGitRepoPath
        $tempDir = Join-Path $repo 'temp'
        if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $hashA = if ($DbA -match 'db_git_tmp_a_(.+)') { $Matches[1] } else { "src" }
        $hashB = if ($DbB -match 'db_git_tmp_b_(.+)') { $Matches[1] } else { "tgt" }
        $reportPath = Join-Path $tempDir "diff_${hashA}_to_${hashB}_$timestamp.html"

        $json = $diffResult | ConvertTo-Json -Depth 100

        $htmlTemplate = @'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>db_git - Database Diff Dashboard</title>
    <style>
        :root {
            --bg-color: #0f172a;
            --card-bg: rgba(30, 41, 59, 0.7);
            --border-color: rgba(255, 255, 255, 0.1);
            --text-color: #f8fafc;
            --text-muted: #94a3b8;
            --primary: #6366f1;
            --primary-hover: #4f46e5;
            --success: #10b981;
            --danger: #ef4444;
            --warning: #f59e0b;
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background-color: var(--bg-color);
            color: var(--text-color);
            margin: 0;
            padding: 20px;
            display: flex;
            flex-direction: column;
            align-items: center;
        }
        .container {
            width: 100%;
            max-width: 1200px;
        }
        header {
            background: linear-gradient(135deg, #3b82f6 0%, #8b5cf6 100%);
            padding: 30px;
            border-radius: 16px;
            margin-bottom: 24px;
            box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.3);
            text-align: center;
        }
        header h1 {
            margin: 0;
            font-size: 2.2rem;
            font-weight: 800;
        }
        header p {
            margin: 8px 0 0 0;
            color: rgba(255, 255, 255, 0.8);
            font-size: 1rem;
        }
        .nav-tabs {
            display: flex;
            gap: 12px;
            margin-bottom: 20px;
        }
        .tab-btn {
            background-color: var(--card-bg);
            border: 1px solid var(--border-color);
            color: var(--text-color);
            padding: 10px 20px;
            border-radius: 8px;
            cursor: pointer;
            font-weight: 600;
            transition: all 0.2s;
        }
        .tab-btn.active, .tab-btn:hover {
            background-color: var(--primary);
            border-color: var(--primary);
            box-shadow: 0 4px 6px -1px rgba(99, 102, 241, 0.4);
        }
        .card {
            background-color: var(--card-bg);
            border: 1px solid var(--border-color);
            border-radius: 12px;
            padding: 24px;
            margin-bottom: 24px;
            backdrop-filter: blur(10px);
        }
        .card h2 {
            margin-top: 0;
            border-bottom: 1px solid var(--border-color);
            padding-bottom: 12px;
            font-size: 1.5rem;
            color: var(--primary);
        }
        .diff-section {
            margin-bottom: 20px;
        }
        .diff-section-title {
            font-weight: bold;
            font-size: 1.1rem;
            margin-bottom: 8px;
            color: var(--warning);
        }
        .diff-list {
            list-style: none;
            padding: 0;
            margin: 0;
        }
        .diff-list li {
            padding: 6px 12px;
            border-radius: 6px;
            margin-bottom: 4px;
            font-family: monospace;
        }
        .diff-list li.added {
            background-color: rgba(16, 185, 129, 0.15);
            color: var(--success);
            border-left: 4px solid var(--success);
        }
        .diff-list li.deleted {
            background-color: rgba(239, 68, 68, 0.15);
            color: var(--danger);
            border-left: 4px solid var(--danger);
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 10px;
            font-size: 0.9rem;
        }
        th, td {
            padding: 10px 12px;
            text-align: left;
            border-bottom: 1px solid var(--border-color);
        }
        th {
            background-color: rgba(255, 255, 255, 0.05);
            color: var(--text-muted);
            font-weight: 600;
        }
        .tag {
            padding: 3px 8px;
            border-radius: 4px;
            font-weight: bold;
            font-size: 0.75rem;
            display: inline-block;
        }
        .tag.added { background-color: var(--success); color: white; }
        .tag.deleted { background-color: var(--danger); color: white; }
        .tag.modified { background-color: var(--warning); color: black; }
        .change-cell {
            background-color: rgba(245, 158, 11, 0.1);
            border-left: 3px solid var(--warning);
        }
        .change-detail {
            font-size: 0.8rem;
            color: var(--text-muted);
            font-family: monospace;
            margin-bottom: 4px;
        }
        .change-old { color: var(--danger); text-decoration: line-through; }
        .change-new { color: var(--success); font-weight: bold; }
        .hidden { display: none; }
        .empty-msg {
            color: var(--text-muted);
            font-style: italic;
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>db_git Diff Dashboard</h1>
            <p>Comparing Source: <strong id="src-db"></strong> vs Target: <strong id="tgt-db"></strong></p>
        </header>

        <div class="nav-tabs">
            <button class="tab-btn active" onclick="switchTab('schema')">Schema Differences</button>
            <button class="tab-btn" onclick="switchTab('data')">Data Differences</button>
        </div>

        <!-- SCHEMA SECTION -->
        <div id="schema-tab" class="tab-content">
            <div class="card">
                <h2>Database Schema Diffs</h2>
                <div id="schema-diff-container"></div>
            </div>
        </div>

        <!-- DATA SECTION -->
        <div id="data-tab" class="tab-content hidden">
            <div class="card">
                <h2>Table Data Diffs</h2>
                <div id="data-diff-container"></div>
            </div>
        </div>
    </div>

    <script>
        const diffData = /*DIFF_JSON_PLACEHOLDER*/;

        document.getElementById('src-db').innerText = diffData.Source;
        document.getElementById('tgt-db').innerText = diffData.Target;

        function switchTab(tab) {
            document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
            document.querySelectorAll('.tab-content').forEach(c => c.classList.add('hidden'));

            if (tab === 'schema') {
                document.querySelector('.tab-btn:nth-child(1)').classList.add('active');
                document.getElementById('schema-tab').classList.remove('hidden');
            } else {
                document.querySelector('.tab-btn:nth-child(2)').classList.add('active');
                document.getElementById('data-tab').classList.remove('hidden');
            }
        }

        function renderSchemaSection(title, diffObj) {
            if (!diffObj || (!diffObj.Added.length && !diffObj.Deleted.length)) return '';

            let html = `<div class="diff-section">
                <div class="diff-section-title">${title}</div>
                <ul class="diff-list">`;
            
            diffObj.Deleted.forEach(d => {
                html += `<li class="deleted">- ${d}</li>`;
            });
            diffObj.Added.forEach(a => {
                html += `<li class="added">+ ${a}</li>`;
            });
            
            html += `</ul></div>`;
            return html;
        }

        // Render Schema Diffs
        const schemaContainer = document.getElementById('schema-diff-container');
        let schemaHtml = '';
        schemaHtml += renderSchemaSection('Tables', diffData.Tables);
        schemaHtml += renderSchemaSection('Columns', diffData.Columns);
        schemaHtml += renderSchemaSection('Indexes', diffData.Indexes);
        schemaHtml += renderSchemaSection('Constraints', diffData.Constraints);
        schemaHtml += renderSchemaSection('Sequences', diffData.Sequences);
        schemaHtml += renderSchemaSection('Views', diffData.Views);
        schemaHtml += renderSchemaSection('Triggers', diffData.Triggers);

        if (!schemaHtml) {
            schemaHtml = '<div class="empty-msg">No schema differences detected.</div>';
        }
        schemaContainer.innerHTML = schemaHtml;

        // Render Data Diffs
        const dataContainer = document.getElementById('data-diff-container');
        let dataHtml = '';

        if (diffData.Data && diffData.Data.length) {
            diffData.Data.forEach(tbl => {
                dataHtml += `<div style="margin-bottom: 30px;">
                    <h3 style="margin-bottom: 8px; color: #a5b4fc;">
                        ${tbl.TableName}
                        <span class="tag ${tbl.Status.toLowerCase()}">${tbl.Status.toUpperCase()}</span>
                    </h3>`;

                if (tbl.Status === 'Added') {
                    dataHtml += `<div class="empty-msg">Entire table was added.</div>`;
                } else if (tbl.Status === 'Deleted') {
                    dataHtml += `<div class="empty-msg">Entire table was deleted.</div>`;
                } else {
                    // Modified table: show rows
                    dataHtml += `<table>
                        <thead>
                            <tr>
                                <th style="width: 250px;">Primary Key</th>
                                <th>Modifications</th>
                            </tr>
                        </thead>
                        <tbody>`;

                    tbl.Modified.forEach(row => {
                        let changeHtml = '';
                        row.Changes.forEach(c => {
                            changeHtml += `<div class="change-detail">
                                <strong>${c.Column}</strong>: 
                                <span class="change-old">${c.Old !== null ? c.Old : 'NULL'}</span> &rarr; 
                                <span class="change-new">${c.New !== null ? c.New : 'NULL'}</span>
                            </div>`;
                        });

                        dataHtml += `<tr>
                            <td style="font-family: monospace; font-weight: 600;">${row.PrimaryKey}</td>
                            <td class="change-cell">${changeHtml}</td>
                        </tr>`;
                    });

                    // Add inserted/deleted summary if any
                    if (tbl.Inserted.length > 0) {
                        dataHtml += `<tr>
                            <td colspan="2" style="color: var(--success); font-weight: bold;">+ ${tbl.Inserted.length} row(s) inserted: ${tbl.Inserted.join(', ')}</td>
                        </tr>`;
                    }
                    if (tbl.Deleted.length > 0) {
                        dataHtml += `<tr>
                            <td colspan="2" style="color: var(--danger); font-weight: bold;">- ${tbl.Deleted.length} row(s) deleted: ${tbl.Deleted.join(', ')}</td>
                        </tr>`;
                    }

                    dataHtml += `</tbody></table>`;
                }
                dataHtml += `</div>`;
            });
        }

        if (!dataHtml) {
            dataHtml = '<div class="empty-msg">No data differences detected or data compare not run.</div>';
        }
        dataContainer.innerHTML = dataHtml;
    </script>
</body>
</html>
'@

        $html = $htmlTemplate.Replace('/*DIFF_JSON_PLACEHOLDER*/', $json)
        Set-Content -Path $reportPath -Value $html -Encoding UTF8
        Write-Host "`nGenerated interactive GUI diff report: $reportPath" -ForegroundColor Green
        Start-Process $reportPath
    }
}

function Compare-Lists {
    param($ListA, $ListB, $Label, [switch]$Silent)
    
    $setA = @{}
    foreach ($item in $ListA) { if ($item) { $setA[$item.Trim()] = $true } }
    
    $setB = @{}
    foreach ($item in $ListB) { if ($item) { $setB[$item.Trim()] = $true } }

    $added = @()
    $deleted = @()

    foreach ($k in $setB.Keys) {
        if (-not $setA.ContainsKey($k)) { $added += $k }
    }
    foreach ($k in $setA.Keys) {
        if (-not $setB.ContainsKey($k)) { $deleted += $k }
    }

    if (-not $Silent -and ($added.Count -gt 0 -or $deleted.Count -gt 0)) {
        Write-Host ($Label + ":") -ForegroundColor Yellow
        foreach ($a in $added) {
            Write-Host "  + $a" -ForegroundColor Green
        }
        foreach ($d in $deleted) {
            Write-Host "  - $d" -ForegroundColor Red
        }
    }

    return [pscustomobject]@{
        Added   = $added
        Deleted = $deleted
    }
}

function Query-Db {
    param($Db, $Config, $Query)
    $res = & psql -h $Config.host -p $Config.port -U $Config.username -d $Db -Atc $Query 2>$null
    return $res
}

function Query-Db-Rows {
    param($Db, $Config, $Table)
    $resText = & psql -h $Config.host -p $Config.port -U $Config.username -d $Db --csv -c "SELECT * FROM $(ConvertTo-PgQualifiedName -Name $Table);" 2>$null
    if ($resText) {
        return $resText | ConvertFrom-Csv
    }
    return @()
}

Export-ModuleMember -Function Cmd-diff

