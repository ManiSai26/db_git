# Backup.psm1

# Implements the backup (create-backup) command.

function Cmd-create-backup {
    <#
    .SYNOPSIS
        Create a PostgreSQL backup (alias: cb).
    .DESCRIPTION
        Executes pg_dump using the repository configuration, stores the dump under .db_git/db_backups, creates a short hash, writes metadata, and updates history and HEAD.
    .PARAMETER Message
        Commit‑style message describing the backup.
    .EXAMPLE
        db_git create-backup -m "Before migration"
    .EXAMPLE
        db_git cb -m "Initial load"
    #>
    param(
        [Parameter(Mandatory=$false, HelpMessage='Backup message')]
        [string]$Message = ""
    )

    # Load required modules
    Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking

    # Retrieve configuration
    $config = Get-DbGitConfig
    if (-not $config) { return }

    # Resolve paths
    $repoPath = Get-DbGitRepoPath
    $backupDir = Get-BackupDir
    $metadataDir = Get-MetadataDir

    # Determine next numeric id
    $nextId = Get-NextBackupId

    # Build filename (human readable timestamp) and full path
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $dumpFile = "backup_${nextId}_$timestamp.sql"
    $dumpPath = Join-Path $backupDir $dumpFile

    # Prepare pg_dump command and run it
    $pwd = Unprotect-DbGitPassword -StoredPassword $config.password
    $env:PGPASSWORD = $pwd
    Write-Host "Creating backup for database '$($config.database)'..."
    try {
        # Custom format dump (-Fc). Arguments are passed as an array (not one joined string)
        # so names/paths with spaces or special characters reach pg_dump intact.
        & pg_dump -h $config.host -p $config.port -U $config.username -d $config.database -Fc -f $dumpPath
        if ($LASTEXITCODE -ne 0) {
            throw "pg_dump failed with exit code $LASTEXITCODE"
        }
    } catch {
        Write-Error "Failed to execute pg_dump: $_"
        return
    } finally {
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    }

    # Compute short hash of the dump file
    $hash = Compute-Hash -FilePath $dumpPath

    # File size
    $size = (Get-Item $dumpPath).Length

    # Parent hash (current HEAD)
    $parentHash = Get-HeadHash
    if (-not $parentHash) { $parentHash = "" }

    # Record history entry
    $dateIso = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $msg = if ($Message) { $Message } else { "Backup $nextId" }
    Write-HistoryEntry -Id $nextId -Hash $hash -ParentHash $parentHash -Date $dateIso -Database $config.database -Filename $dumpFile -Size $size -Message $msg

    # Update HEAD
    Set-HeadHash -Hash $hash

    # Generate metadata (tables list, row counts, etc.)
    $metadata = @{
        id = $nextId
        hash = $hash
        database = $config.database
        timestamp = $dateIso
        size = $size
        schema_hash = "" # to be computed
        row_hash = "" # to be computed
        tables = @()
    }

    $env:PGPASSWORD = $pwd
    try {
        # Fetch tables
        # Use psql to fetch tables list
        $tblQuery = "SELECT schemaname, tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema');"
        $tablesList = & psql -h $config.host -p $config.port -U $config.username -d $config.database -Atc $tblQuery 2>$null
        
        $tableHashesText = ""
        foreach ($tblLine in $tablesList) {
            if (-not $tblLine) { continue }
            $parts = $tblLine -split '\|'
            if ($parts.Length -lt 2) {
                # sometimes separated by tab or spaces depending on psql output formatting
                $parts = $tblLine -split '\s+'
            }
            $schemaName = $parts[0]
            $tableName = $parts[1]
            $fullTableName = "$schemaName.$tableName"
            
            # Row count
            $countQuery = "SELECT COUNT(*) FROM $(ConvertTo-PgQualifiedName -Schema $schemaName -Table $tableName);"
            $countStr = & psql -h $config.host -p $config.port -U $config.username -d $config.database -Atc $countQuery 2>$null
            [int]$rowCount = 0
            if ($countStr) {
                [int]::TryParse($countStr.Trim(), [ref]$rowCount) | Out-Null
            }
            
            # Simple schema hash component by getting table columns definition
            $colQuery = "SELECT column_name, data_type FROM information_schema.columns WHERE table_schema = $(ConvertTo-PgLiteral $schemaName) AND table_name = $(ConvertTo-PgLiteral $tableName) ORDER BY ordinal_position;"
            $cols = & psql -h $config.host -p $config.port -U $config.username -d $config.database -Atc $colQuery 2>$null
            $colText = ""
            if ($cols) {
                $colText = ($cols -join "`n")
            }
            
            $metadata.tables += @{
                schema = $schemaName
                name = $tableName
                rows = $rowCount
                columns = $cols
            }
            $tableHashesText += "$fullTableName rows=$rowCount cols=$colText`n"
        }
        
        # Simple schema / row hash calculations
        $utf8 = [System.Text.Encoding]::UTF8
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $sha.ComputeHash($utf8.GetBytes($tableHashesText))
        $metadata.schema_hash = ([System.BitConverter]::ToString($hashBytes) -replace '-','').Substring(0,12).ToLower()
        $metadata.row_hash = $metadata.schema_hash # simple placeholder
    } catch {
        Write-Warning "Failed to collect detailed table metadata: $_"
    } finally {
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    }

    $metaPath = Join-Path $metadataDir "backup_${nextId}.json"
    $metadata | ConvertTo-Json -Depth 10 | Set-Content -Path $metaPath -Encoding UTF8

    Write-Host "Backup created successfully."
    Write-Host "commit $hash"
    Write-Host "Message:  $msg"
    Write-Host "Date:     $dateIso"
    Write-Host "Database: $($config.database)"
    Write-Host "Size:     $([Math]::Round($size / 1KB, 2)) KB"
}

Export-ModuleMember -Function Cmd-create-backup

