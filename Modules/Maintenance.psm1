# Maintenance.psm1

# Implements delete, amend, prune, gc, verify, export, import, search commands.

function Cmd-delete {
    <#
    .SYNOPSIS
        Delete a backup.
    .DESCRIPTION
        Removes the backup SQL dump, metadata file, and its entry in history.
    .PARAMETER Target
        The backup ID or hash prefix to delete.
    .PARAMETER Force
        Do not prompt for confirmation.
    #>
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Target,
        [switch]$Force
    )

    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking
    $repo = Get-DbGitRepoPath
    if (-not $repo) { return }

    $history = Get-HistoryEntries
    $entry = $null
    if ($Target -as [int]) {
        $entry = $history | Where-Object { $_.Id -eq [int]$Target }
    } else {
        $entry = $history | Where-Object { $_.Hash -like "${Target}*" }
    }

    if (-not $entry) {
        Write-Error "Backup '$Target' not found."
        return
    }

    # Check if backup is tagged
    $tagsPath = Join-Path $repo 'tags.csv'
    $associatedTags = @()
    $tagLines = @()
    if (Test-Path $tagsPath) {
        $tagLines = @(Get-Content $tagsPath | Where-Object { $_ -match '\S' })
        foreach ($line in $tagLines) {
            $parts = $line -split ','
            if ($parts.Length -ge 2 -and $parts[1] -eq $entry.Hash) {
                $associatedTags += $parts[0]
            }
        }
    }

    if ($associatedTags.Count -gt 0) {
        $tagsStr = $associatedTags -join ", "
        if (-not $Force) {
            $confirm = Read-Host "Warning: Backup $($entry.Id) ($($entry.Hash)) is tagged as: '$tagsStr'. Deleting it will also remove these tags. Do you want to proceed? Type 'yes' to confirm"
            if ($confirm -ne 'yes') {
                Write-Host "Deletion cancelled."
                return
            }
        }
        # Remove tags from tags.csv
        $remainingTagLines = @()
        foreach ($line in $tagLines) {
            $parts = $line -split ','
            if ($parts.Length -ge 2 -and $parts[1] -ne $entry.Hash) {
                $remainingTagLines += $line
            }
        }
        Set-Content -Path $tagsPath -Value $remainingTagLines -Encoding UTF8
        Write-Host "Removed tag(s): $tagsStr"
    } else {
        if (-not $Force) {
            $confirm = Read-Host "Are you sure you want to delete backup $($entry.Id) ($($entry.Hash))? Type 'yes' to confirm"
            if ($confirm -ne 'yes') {
                Write-Host "Deletion cancelled."
                return
            }
        }
    }

    # Remove SQL file
    $backupDir = Get-BackupDir
    $sqlPath = Join-Path $backupDir $entry.Filename
    if (Test-Path $sqlPath) {
        Remove-Item $sqlPath -Force
    }

    # Remove metadata file
    $metadataDir = Get-MetadataDir
    $metaPath = Join-Path $metadataDir "backup_$($entry.Id).json"
    if (Test-Path $metaPath) {
        Remove-Item $metaPath -Force
    }

    # Remove from history.csv
    $historyPath = Join-Path $repo 'history.csv'
    $newHistory = $history | Where-Object { $_.Id -ne $entry.Id }
    $lines = @()
    foreach ($h in $newHistory) {
        $lines += Format-HistoryLine -Entry $h
    }
    Set-Content -Path $historyPath -Value $lines -Encoding UTF8

    # If deleted entry was HEAD, update HEAD
    $head = Get-HeadHash
    if ($head -eq $entry.Hash) {
        if ($newHistory.Count -gt 0) {
            Set-HeadHash -Hash $newHistory[-1].Hash
        } else {
            Set-HeadHash -Hash ""
        }
    }

    Write-Host "Backup $($entry.Id) ($($entry.Hash)) deleted successfully."
}

function Cmd-amend {
    <#
    .SYNOPSIS
        Amend a backup message.
    .DESCRIPTION
        Updates the message associated with a backup in history.csv.
    .PARAMETER Target
        The backup ID or hash prefix to amend.
    .PARAMETER Message
        The new backup message.
    #>
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Target,
        [Parameter(Mandatory=$true, Position=1)]
        [string]$Message
    )

    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking
    $repo = Get-DbGitRepoPath
    if (-not $repo) { return }

    $history = Get-HistoryEntries
    $found = $false
    $updatedLines = @()

    foreach ($h in $history) {
        $isMatch = $false
        if ($Target -as [int]) {
            if ($h.Id -eq [int]$Target) { $isMatch = $true }
        } else {
            if ($h.Hash -like "${Target}*") { $isMatch = $true }
        }

        if ($isMatch) {
            $h.Message = $Message
            $found = $true
        }
        $updatedLines += Format-HistoryLine -Entry $h
    }

    if (-not $found) {
        Write-Error "Backup '$Target' not found."
        return
    }

    $historyPath = Join-Path $repo 'history.csv'
    $updatedLines | Set-Content -Path $historyPath -Encoding UTF8
    Write-Host "Backup message updated successfully."
}

function Cmd-prune {
    <#
    .SYNOPSIS
        Prune orphan backups and metadata.
    .DESCRIPTION
        Removes any files under db_backups/ and metadata/ that are not listed in history.csv,
        and removes history.csv entries whose SQL files are missing.
    #>
    param([string[]]$Args)

    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking
    $repo = Get-DbGitRepoPath
    if (-not $repo) { return }

    $history = Get-HistoryEntries
    $backupDir = Get-BackupDir
    $metadataDir = Get-MetadataDir

    Write-Host "Pruning repository files..."

    # 1. Check history entries against existing files
    $validHistory = @()
    foreach ($h in $history) {
        $sqlPath = Join-Path $backupDir $h.Filename
        if (Test-Path $sqlPath) {
            $validHistory += $h
        } else {
            Write-Host "Removing missing backup entry from history: Id $($h.Id) ($($h.Hash))" -ForegroundColor Cyan
        }
    }

    # Rewrite history if needed
    if ($validHistory.Count -lt $history.Count) {
        $lines = @()
        foreach ($h in $validHistory) {
            $lines += "$($h.Id),$($h.Hash),$($h.Parent),$($h.Date),$($h.Database),$($h.Filename),$($h.Size),$($h.Message)"
        }
        $historyPath = Join-Path $repo 'history.csv'
        Set-Content -Path $historyPath -Value $lines -Encoding UTF8
    }

    # 2. Check actual SQL files against history
    $validFilenames = $validHistory | ForEach-Object { $_.Filename }
    Get-ChildItem -Path $backupDir -Filter *.sql | ForEach-Object {
        if ($validFilenames -notcontains $_.Name) {
            Write-Host "Deleting orphan backup file: $($_.Name)" -ForegroundColor Cyan
            Remove-Item $_.FullName -Force
        }
    }

    # 3. Check metadata files against history
    $validMetaNames = $validHistory | ForEach-Object { "backup_$($_.Id).json" }
    Get-ChildItem -Path $metadataDir -Filter *.json | ForEach-Object {
        if ($validMetaNames -notcontains $_.Name) {
            Write-Host "Deleting orphan metadata file: $($_.Name)" -ForegroundColor Cyan
            Remove-Item $_.FullName -Force
        }
    }

    Write-Host "Pruning complete." -ForegroundColor Green
}

function Cmd-gc {
    <#
    .SYNOPSIS
        Clean up temp folders and verify indexes.
    .DESCRIPTION
        Cleans the .db_git/temp/ directory. Future compression features will be added here.
    #>
    param([string[]]$Args)

    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking
    $repo = Get-DbGitRepoPath
    if (-not $repo) { return }

    $tempDir = Join-Path $repo 'temp'
    if (Test-Path $tempDir) {
        Write-Host "Cleaning temporary workspace directory..."
        Get-ChildItem -Path $tempDir -Recurse | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    }
    Write-Host "Garbage collection complete." -ForegroundColor Green
}

function Cmd-verify {
    <#
    .SYNOPSIS
        Verify backups are valid and restorable.
    .DESCRIPTION
        Attempts to restore backup(s) into a disposable temporary database to verify integrity.
    .PARAMETER Target
        Specific backup to verify (default: verify all).
    #>
    param(
        [Parameter(Position=0)]
        [string]$Target
    )

    Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking

    $config = Get-DbGitConfig
    if (-not $config) { return }

    $history = Get-HistoryEntries
    $targetsToVerify = @()

    if ($Target) {
        $entry = $null
        if ($Target -as [int]) {
            $entry = $history | Where-Object { $_.Id -eq [int]$Target }
        } else {
            $entry = $history | Where-Object { $_.Hash -like "${Target}*" }
        }
        if (-not $entry) {
            Write-Error "Backup '$Target' not found."
            return
        }
        $targetsToVerify += $entry
    } else {
        $targetsToVerify = $history
    }

    if ($targetsToVerify.Count -eq 0) {
        Write-Host "No backups to verify."
        return
    }

    $pwd = Unprotect-DbGitPassword -StoredPassword $config.password

    $backupDir = Get-BackupDir

    foreach ($entry in $targetsToVerify) {
        $dumpPath = Join-Path $backupDir $entry.Filename
        if (-not (Test-Path $dumpPath)) {
            Write-Warning "Backup file missing: $($entry.Filename) (Id: $($entry.Id))"
            continue
        }

        Write-Host "Verifying Backup $($entry.Id) ($($entry.Hash))..." -NoNewline

        # Spin up a temporary database
        $tempDb = "db_git_verify_temp_$($entry.Hash)".ToLower()
        $env:PGPASSWORD = $pwd
        
        try {
            # Create temp db
            $createRes = & psql -h $config.host -p $config.port -U $config.username -d postgres -c "CREATE DATABASE $(ConvertTo-PgIdent $tempDb);" 2>&1
            
            # Restore into it
            $restoreProcess = Start-Process -FilePath "pg_restore" -ArgumentList "-h $($config.host) -p $($config.port) -U $($config.username) -d $tempDb -Fc `"$dumpPath`"" -NoNewWindow -PassThru -Wait
            
            if ($restoreProcess.ExitCode -eq 0) {
                Write-Host " [PASS]" -ForegroundColor Green
            } else {
                Write-Host " [FAIL: pg_restore failed]" -ForegroundColor Red
            }
        } catch {
            Write-Host " [FAIL: $_]" -ForegroundColor Red
        } finally {
            # Drop temp db
            & psql -h $config.host -p $config.port -U $config.username -d postgres -c "DROP DATABASE IF EXISTS $(ConvertTo-PgIdent $tempDb);" 2>$null | Out-Null
            Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
        }
    }
}

function Cmd-search {
    <#
    .SYNOPSIS
        Search backup messages.
    .DESCRIPTION
        Searches message text or hash in history.csv for the query pattern.
    .PARAMETER Query
        The pattern or text to search for.
    #>
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Query
    )

    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking
    $history = Get-HistoryEntries

    $results = $history | Where-Object { $_.Message -match $Query -or $_.Hash -match $Query }
    if ($results.Count -eq 0) {
        Write-Host "No backups match query: '$Query'"
        return
    }

    foreach ($entry in $results) {
        Write-Host "commit $($entry.Hash)" -ForegroundColor Yellow
        Write-Host "Date:     $($entry.Date)"
        Write-Host "Message:  $($entry.Message)"
        Write-Host ""
    }
}

function Cmd-export {
    <#
    .SYNOPSIS
        Export backup history and metadata.
    .DESCRIPTION
        Saves backup history to a JSON file format.
    .PARAMETER OutputPath
        The filepath where the JSON metadata export will be saved.
    #>
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$OutputPath
    )

    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking
    $history = Get-HistoryEntries
    $history | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputPath -Encoding UTF8
    Write-Host "Exported backup history to $OutputPath"
}

function Cmd-import {
    <#
    .SYNOPSIS
        Import backup history from an exported history JSON or reconstruct.
    .DESCRIPTION
        Reconstructs history.csv from either an exported file or by scanning db_backups/ and metadata/.
    .PARAMETER InputPath
        Optional path to the exported history JSON file.
    #>
    param(
        [Parameter(Position=0)]
        [string]$InputPath
    )

    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking
    $repo = Get-DbGitRepoPath
    if (-not $repo) { return }

    $historyPath = Join-Path $repo 'history.csv'

    if ($InputPath -and (Test-Path $InputPath)) {
        Write-Host "Importing history from $InputPath..."
        $data = Get-Content $InputPath -Raw | ConvertFrom-Json
        $lines = @()
        foreach ($h in $data) {
            $lines += Format-HistoryLine -Entry $h
        }
        Set-Content -Path $historyPath -Value $lines -Encoding UTF8
        # Set HEAD to the last item
        if ($data.Count -gt 0) {
            Set-HeadHash -Hash $data[-1].Hash
        }
        Write-Host "History imported successfully."
        return
    }

    # Reconstruct from scanning files
    Write-Host "Reconstructing history.csv from db_backups/ and metadata/..."
    $backupDir = Get-BackupDir
    $metadataDir = Get-MetadataDir

    if (-not (Test-Path $backupDir)) {
        Write-Error "No db_backups/ folder found."
        return
    }

    $lines = @()
    $latestHash = ""

    # Sort files by numeric ID in filename
    $files = Get-ChildItem -Path $backupDir -Filter *.sql | Sort-Object {
        if ($_.BaseName -match 'backup_(\d+)_') { [int]$Matches[1] } else { 0 }
    }

    foreach ($file in $files) {
        $id = 0
        if ($file.BaseName -match 'backup_(\d+)_') {
            $id = [int]$Matches[1]
        }
        if ($id -eq 0) { continue }

        $hash = Compute-Hash -FilePath $file.FullName
        $latestHash = $hash
        $size = $file.Length
        
        # Read matching metadata JSON if it exists
        $metaPath = Join-Path $metadataDir "backup_${id}.json"
        $dateIso = $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        $db = "unknown"
        $msg = "Backup $id (Reconstructed)"

        if (Test-Path $metaPath) {
            try {
                $meta = Get-Content $metaPath -Raw | ConvertFrom-Json
                if ($meta.database) { $db = $meta.database }
                if ($meta.timestamp) { $dateIso = $meta.timestamp }
                if ($meta.hash) { $hash = $meta.hash }
            } catch {}
        }

        # Parent is the previous latestHash
        $parent = if ($lines.Count -gt 0) { $lines[-1] -split ',' | Select-Object -Index 1 } else { "" }
        $reconstructedEntry = [pscustomobject]@{
            Id = $id; Hash = $hash; Parent = $parent; Date = $dateIso
            Database = $db; Filename = $file.Name; Size = $size; Message = $msg
        }
        $lines += Format-HistoryLine -Entry $reconstructedEntry
    }

    if ($lines.Count -gt 0) {
        $lines | Set-Content -Path $historyPath -Encoding UTF8
        Set-HeadHash -Hash $latestHash
        Write-Host "Reconstruction complete. $( $lines.Count ) entries imported." -ForegroundColor Green
    } else {
        Write-Warning "No backups found to reconstruct history."
    }
}

function Cmd-reset {
    <#
    .SYNOPSIS
        Reset repository history to a specific backup (alias: reset).
    .DESCRIPTION
        Resets history, HEAD pointer, and the active database state back to the specified backup.
        All backups and metadata created after the target backup are permanently deleted.
    .PARAMETER Target
        The target backup identifier (ID, hash, or tag) to reset to.
    .PARAMETER Force
        Bypass confirmation prompt.
    #>
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Target,
        [switch]$Force
    )

    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Restore.psm1') -Force -DisableNameChecking

    $repo = Get-DbGitRepoPath
    if (-not $repo) { return }

    $history = Get-HistoryEntries
    $entry = $null
    if ($Target -eq 'latest') {
        $headHash = Get-HeadHash
        $entry = $history | Where-Object { $_.Hash -eq $headHash }
    } else {
        if ($Target -as [int]) {
            $entry = $history | Where-Object { $_.Id -eq [int]$Target }
        }
        if (-not $entry) {
            $entry = $history | Where-Object { $_.Hash -like "${Target}*" }
        }
        if (-not $entry) {
            # Check tags
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
        Write-Error "Backup target '$Target' not found."
        return
    }

    # Find the index of the target backup in history
    $targetIndex = -1
    for ($i = 0; $i -lt $history.Count; $i++) {
        if ($history[$i].Hash -eq $entry.Hash) {
            $targetIndex = $i
            break
        }
    }

    if ($targetIndex -eq -1) {
        Write-Error "Backup '$Target' not found in history."
        return
    }

    # backups to delete are all entries after the targetIndex
    $toDelete = @()
    if ($targetIndex -lt ($history.Count - 1)) {
        $toDelete = $history[($targetIndex + 1)..($history.Count - 1)]
    }

    if (-not $Force) {
        $msg = "Are you sure you want to hard reset to backup $($entry.Id) ($($entry.Hash))?`n"
        if ($toDelete.Count -gt 0) {
            $msg += "This will permanently delete the following $($toDelete.Count) subsequent backups:`n"
            foreach ($del in $toDelete) {
                $msg += "  - Backup $($del.Id) ($($del.Hash)): $($del.Message)`n"
            }
        }
        $msg += "It will also restore the database to this state. Type 'yes' to confirm: "
        $confirm = Read-Host $msg
        if ($confirm -ne 'yes') {
            Write-Host "Reset cancelled."
            return
        }
    }

    # 1. Restore the database to the target state
    Write-Host "Restoring database to reset target..."
    Cmd-restore -Target $entry.Hash -Force

    # 2. Delete files for newer backups
    $backupDir = Get-BackupDir
    $metadataDir = Get-MetadataDir
    foreach ($del in $toDelete) {
        # SQL file
        $sqlPath = Join-Path $backupDir $del.Filename
        if (Test-Path $sqlPath) { Remove-Item $sqlPath -Force }

        # Metadata file
        $metaPath = Join-Path $metadataDir "backup_$($del.Id).json"
        if (Test-Path $metaPath) { Remove-Item $metaPath -Force }
    }

    # 3. Rewrite history.csv containing only up to the target backup
    $historyPath = Join-Path $repo 'history.csv'
    $remainingHistory = $history[0..$targetIndex]
    $lines = @()
    foreach ($h in $remainingHistory) {
        $lines += Format-HistoryLine -Entry $h
    }
    Set-Content -Path $historyPath -Value $lines -Encoding UTF8

    # 4. Clean tags.csv pointing to deleted backups
    $tagsPath = Join-Path $repo 'tags.csv'
    if (Test-Path $tagsPath) {
        $tagLines = @(Get-Content $tagsPath | Where-Object { $_ -match '\S' })
        $remainingTags = @()
        $deletedTagNames = @()
        foreach ($line in $tagLines) {
            $parts = $line -split ','
            if ($parts.Length -ge 2) {
                $hash = $parts[1]
                # Keep tag if it points to a remaining backup hash
                $isRemaining = $false
                foreach ($rem in $remainingHistory) {
                    if ($rem.Hash -eq $hash) { $isRemaining = $true; break }
                }
                if ($isRemaining) {
                    $remainingTags += $line
                } else {
                    $deletedTagNames += $parts[0]
                }
            }
        }
        Set-Content -Path $tagsPath -Value $remainingTags -Encoding UTF8
        if ($deletedTagNames.Count -gt 0) {
            Write-Host "Removed tags pointing to deleted backups: $($deletedTagNames -join ', ')"
        }
    }

    # 5. Set HEAD to the target hash
    Set-HeadHash -Hash $entry.Hash

    Write-Host "Hard reset successful. HEAD is now at commit $($entry.Hash)."
}

Export-ModuleMember -Function Cmd-delete, Cmd-amend, Cmd-prune, Cmd-gc, Cmd-verify, Cmd-search, Cmd-export, Cmd-import, Cmd-reset

