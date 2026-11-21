# Help.psm1

# Implements command-specific help messages.

function Help-init {
    Write-Host "Command: db_git init`n" -ForegroundColor Yellow
    Write-Host "Description:"
    Write-Host "  Initialises a db_git backup repository in the current working directory."
    Write-Host "  It scans the directory for a '.env' file containing 'DATABASE_URL=' to parse"
    Write-Host "  connection details. If not found, it prompts for them interactively.`n"
    Write-Host "Options:"
    Write-Host "  --db <dbname>      Name of the database"
    Write-Host "  --host <host>      Database host"
    Write-Host "  --port <port>      Database port"
    Write-Host "  --user <user>      Database username"
    Write-Host "  --password <pwd>   Database password`n"
    Write-Host "Example:"
    Write-Host "  db_git init"
}

function Help-create-backup {
    Write-Host "Command: db_git create-backup (alias: cb)`n" -ForegroundColor Yellow
    Write-Host "Description:"
    Write-Host "  Creates a custom-format dump of the configured PostgreSQL database using pg_dump."
    Write-Host "  It writes history to history.csv, updates the HEAD reference, and generates"
    Write-Host "  detailed JSON metadata for schema diff comparisons.`n"
    Write-Host "Options:"
    Write-Host "  -m <message>       Commit message describing the backup.`n"
    Write-Host "Examples:"
    Write-Host "  db_git create-backup -m 'Initial dump'"
    Write-Host "  db_git cb -m 'Pre migration'"
}

function Help-cb { Help-create-backup }

function Help-restore {
    Write-Host "Command: db_git restore`n" -ForegroundColor Yellow
    Write-Host "Description:"
    Write-Host "  Restores a database dump into the active configured database using pg_restore."
    Write-Host "  Restores into a temporary database (<db>_restore_tmp) first, then swaps it in by rename."
    Write-Host "  If the restore fails, the live database is never touched."
    Write-Host "  The previous database is kept as <db>_old for rollback (replaced on the next restore)."
    Write-Host "  Always prompts the user before performing an overwrite unless --force is specified.`n"
    Write-Host "Options:"
    Write-Host "  <target>           Target identifier (Id, short Hash, 'latest', or Tag)"
    Write-Host "  --force            Do not prompt for confirmation"
    Write-Host "  --drop-old         Drop <db>_old right after a successful swap`n"
    Write-Host "Examples:"
    Write-Host "  db_git restore latest"
    Write-Host "  db_git restore 4"
    Write-Host "  db_git restore production --force"
}

function Help-diff {
    Write-Host "Command: db_git diff`n" -ForegroundColor Yellow
    Write-Host "Description:"
    Write-Host "  Compares schema structures and/or database table rows between two backups."
    Write-Host "  Restores both targets into temporary databases (db_git_tmp_a/b) to perform"
    Write-Host "  an active SQL/structure query check, and deletes them afterwards.`n"
    Write-Host "Options:"
    Write-Host "  <source>           Source backup (Id, hash, or tag)"
    Write-Host "  <target>           Target backup (Id, hash, or tag)"
    Write-Host "  --data             Compare data row counts and PK modifications"
    Write-Host "  --all              Compare both schema and data"
    Write-Host "  --table <name>     Only compare details for one specific table"
    Write-Host "  --verbose          Show detailed modified columns/keys for row diff`n"
    Write-Host "Examples:"
    Write-Host "  db_git diff 3 5"
    Write-Host "  db_git diff 3 latest --data --verbose"
}

function Help-tag {
    Write-Host "Command: db_git tag (alias: tags)`n" -ForegroundColor Yellow
    Write-Host "Description:"
    Write-Host "  Manages backup tags."
    Write-Host "  - If name is specified: tags a backup."
    Write-Host "  - If name is omitted: lists all existing tags.`n"
    Write-Host "Options:"
    Write-Host "  <name>             Name of the tag to create"
    Write-Host "  <target>           Specific backup ID/hash to tag (default: HEAD)`n"
    Write-Host "Examples:"
    Write-Host "  db_git tag production"
    Write-Host "  db_git tag before_migration 4"
    Write-Host "  db_git tags"
}

function Help-delete {
    Write-Host "Command: db_git delete`n" -ForegroundColor Yellow
    Write-Host "Description:"
    Write-Host "  Removes a backup file, its metadata file, and its history entry from history.csv."
    Write-Host "  Prompts for validation unless --force is specified.`n"
    Write-Host "Options:"
    Write-Host "  <target>           ID or hash of backup to delete"
    Write-Host "  --force            Do not prompt for confirmation`n"
    Write-Host "Examples:"
    Write-Host "  db_git delete 5"
    Write-Host "  db_git delete a1b2c3 --force"
}

function Help-amend {
    Write-Host "Command: db_git amend`n" -ForegroundColor Yellow
    Write-Host "Description:"
    Write-Host "  Modifies the backup comment (message) in history.csv.`n"
    Write-Host "Options:"
    Write-Host "  <target>           Backup ID or hash prefix"
    Write-Host "  <message>          New description text`n"
    Write-Host "Example:"
    Write-Host "  db_git amend 4 'Fixed description message'"
}

Export-ModuleMember -Function Help-init, Help-create-backup, Help-cb, Help-restore, Help-diff, Help-tag, Help-delete, Help-amend

