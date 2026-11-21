# Utils.psm1

# Utility functions shared across db_git commands.

function Get-DbGitRepoPath {
    <#
    .SYNOPSIS
        Returns the absolute path to the .db_git directory of the current repository.
    #>
    $repo = Join-Path (Get-Location) '.db_git'
    if (-not (Test-Path $repo)) { return $null }
    return $repo
}

function Get-BackupDir {
    $repo = Get-DbGitRepoPath
    if (-not $repo) { return $null }
    return Join-Path $repo 'db_backups'
}

function Get-MetadataDir {
    $repo = Get-DbGitRepoPath
    if (-not $repo) { return $null }
    return Join-Path $repo 'metadata'
}

function Get-NextBackupId {
    $repo = Get-DbGitRepoPath
    if (-not $repo) { return 1 }
    $historyPath = Join-Path $repo 'history.csv'
    if (-not (Test-Path $historyPath)) { return 1 }
    $lines = @(Get-Content $historyPath | Where-Object { $_ -match '\S' })
    if (-not $lines -or $lines.Count -eq 0) { return 1 }
    $last = $lines[-1]
    $fields = $last -split ','
    return ([int]$fields[0]) + 1
}

function Compute-Hash {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath
    )
    if (-not (Test-Path $FilePath)) { return $null }
    $bytes = Get-FileHash -Path $FilePath -Algorithm SHA256
    return $bytes.Hash.Substring(0,6)  # short hash similar to git
}

function Format-HistoryLine {
    <#
    .SYNOPSIS
        Builds a single, safely-escaped history.csv line from a backup entry.
    .DESCRIPTION
        history.csv is a plain comma-delimited format with no quoting, so any free-text
        field (Message, Database) must have commas stripped before writing or the fixed
        8-column layout breaks on the next read. Every code path that writes history.csv
        should go through this function instead of interpolating fields directly.
    .PARAMETER Entry
        An object with Id, Hash, Parent, Date, Database, Filename, Size, Message properties.
    #>
    param($Entry)
    $safeDatabase = "$($Entry.Database)" -replace ',', ';'
    $safeMessage  = "$($Entry.Message)" -replace ',', ';'
    return "{0},{1},{2},{3},{4},{5},{6},{7}" -f $Entry.Id, $Entry.Hash, $Entry.Parent, $Entry.Date, $safeDatabase, $Entry.Filename, $Entry.Size, $safeMessage
}

function Write-HistoryEntry {
    param(
        [int]$Id,
        [string]$Hash,
        [string]$ParentHash,
        [string]$Date,
        [string]$Database,
        [string]$Filename,
        [int64]$Size,
        [string]$Message
    )
    $repo = Get-DbGitRepoPath
    $historyPath = Join-Path $repo 'history.csv'
    $entry = [pscustomobject]@{
        Id = $Id; Hash = $Hash; Parent = $ParentHash; Date = $Date
        Database = $Database; Filename = $Filename; Size = $Size; Message = $Message
    }
    Add-Content -Path $historyPath -Value (Format-HistoryLine -Entry $entry) -Encoding UTF8
}

function Ensure-DbGitIgnored {
    <#
    .SYNOPSIS
        Ensures the current directory's .gitignore excludes .db_git/.
    .DESCRIPTION
        .db_git/ holds unencrypted SQL dumps and repository config, and sits right next to
        a real .git folder in a project — easy to accidentally commit. Creates .gitignore if
        missing, or appends the entry if it's missing from an existing one.
    .OUTPUTS
        $true if .gitignore was created or modified, $false if it already had the entry.
    #>
    $gitignorePath = Join-Path (Get-Location) '.gitignore'
    $entry = '.db_git/'
    if (Test-Path $gitignorePath) {
        $existing = @(Get-Content $gitignorePath)
        if ($existing -notcontains $entry) {
            Add-Content -Path $gitignorePath -Value $entry -Encoding UTF8
            return $true
        }
        return $false
    }
    Set-Content -Path $gitignorePath -Value $entry -Encoding UTF8
    return $true
}

function ConvertTo-PgIdent {
    <#
    .SYNOPSIS
        Quotes a name as a PostgreSQL identifier: my-app-db -> "my-app-db", BaseRate -> "BaseRate".
        Embedded double quotes are doubled. Use for database, schema, table and role names in SQL text.
    #>
    param([Parameter(Mandatory=$true)][string]$Name)
    return '"' + ($Name -replace '"', '""') + '"'
}

function ConvertTo-PgLiteral {
    <#
    .SYNOPSIS
        Quotes a value as a PostgreSQL string literal: O'Brien -> 'O''Brien'.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function ConvertTo-PgQualifiedName {
    <#
    .SYNOPSIS
        Quotes a schema-qualified table name: ("public","BaseRate") -> "public"."BaseRate".
        Accepts either -Schema/-Table, or a single "schema.table" string via -Name (split on the first dot).
    #>
    param([string]$Schema, [string]$Table, [string]$Name)
    if ($Name) {
        $idx = $Name.IndexOf('.')
        if ($idx -lt 0) { return ConvertTo-PgIdent $Name }
        $Schema = $Name.Substring(0, $idx)
        $Table  = $Name.Substring($idx + 1)
    }
    return (ConvertTo-PgIdent $Schema) + '.' + (ConvertTo-PgIdent $Table)
}

function Get-HeadHash {
    $repo = Get-DbGitRepoPath
    if (-not $repo) { return $null }
    $headPath = Join-Path $repo 'HEAD'
    if (Test-Path $headPath) {
        $content = Get-Content $headPath -Raw
        if ($content) {
            return $content.Trim()
        }
    }
    return $null
}

function Set-HeadHash {
    param([string]$Hash)
    $repo = Get-DbGitRepoPath
    if (-not $repo) { return }
    $headPath = Join-Path $repo 'HEAD'
    Set-Content -Path $headPath -Value $Hash -Encoding UTF8
}

function Get-HistoryEntries {
    $repo = Get-DbGitRepoPath
    if (-not $repo) { return @() }
    $historyPath = Join-Path $repo 'history.csv'
    if (-not (Test-Path $historyPath)) { return @() }
    $entries = Get-Content $historyPath | Where-Object { $_ -match '\S' } | ForEach-Object {
        $parts = $_ -split ','
        [pscustomobject]@{
            Id = [int]$parts[0]
            Hash = $parts[1]
            Parent = $parts[2]
            Date = $parts[3]
            Database = $parts[4]
            Filename = $parts[5]
            Size = [int64]$parts[6]
            Message = $parts[7]
        }
    }
    return $entries
}

Export-ModuleMember -Function Get-DbGitRepoPath, Get-BackupDir, Get-MetadataDir, Get-NextBackupId, Compute-Hash, Write-HistoryEntry, Format-HistoryLine, Get-HeadHash, Set-HeadHash, Get-HistoryEntries, Ensure-DbGitIgnored, ConvertTo-PgIdent, ConvertTo-PgLiteral, ConvertTo-PgQualifiedName

