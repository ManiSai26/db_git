# Log.psm1

# Implements list, log, latest, show commands.

function Cmd-history {
    <#
    .SYNOPSIS
        Show backup history (alias: log).
    .DESCRIPTION
        Displays backup history in Git-like format. Supports displaying as an ASCII tree using the -Graph switch.
    .PARAMETER Graph
        Show history as a branch tree/graph (alias: -g).
    .EXAMPLE
        db_git log
        db_git log --graph
    #>
    param(
        [Alias('g')]
        [switch]$Graph
    )

    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking
    $history = Get-HistoryEntries
    $headHash = Get-HeadHash

    if ($history.Count -eq 0) {
        Write-Host "No backups created yet. Run 'db_git cb' to create a backup."
        return
    }

    if ($Graph) {
        Render-HistoryGraph -History $history -HeadHash $headHash
        return
    }

    # Output oldest to newest, or newest to oldest? Git outputs newest first.
    for ($i = $history.Count - 1; $i -ge 0; $i--) {
        $entry = $history[$i]
        Write-Host "commit $($entry.Hash)" -NoNewline -ForegroundColor Yellow
        if ($entry.Hash -eq $headHash) {
            Write-Host " (HEAD)" -ForegroundColor Green
        } else {
            Write-Host ""
        }
        if ($entry.Parent) {
            Write-Host "Parent:   $($entry.Parent)" -ForegroundColor Gray
        }
        Write-Host "Date:     $($entry.Date)"
        Write-Host "Database: $($entry.Database)"
        Write-Host "Size:     $([Math]::Round($entry.Size / 1KB, 2)) KB"
        Write-Host "Message:  $($entry.Message)"
        Write-Host ""
    }
}

function Render-HistoryGraph {
    param($History, $HeadHash)

    # Build node map
    $nodes = @{}
    foreach ($entry in $History) {
        $nodes[$entry.Hash] = @{
            Entry    = $entry
            Children = @()
        }
    }

    # Populate children relationships
    $roots = @()
    foreach ($entry in $History) {
        $parent = $entry.Parent
        if ($parent -and $nodes.ContainsKey($parent)) {
            $nodes[$parent].Children += $entry.Hash
        } else {
            $roots += $entry.Hash
        }
    }

    # Walk recursively to print nodes
    function Show-Node {
        param(
            [string]$Hash,
            [string]$Prefix,
            [bool]$IsLast
        )
        $node = $nodes[$Hash]
        $entry = $node.Entry
        
        $marker = if ($entry.Hash -eq $HeadHash) { "*" } else { "o" }
        $markerColor = if ($entry.Hash -eq $HeadHash) { "Green" } else { "Yellow" }
        
        # Format connection line
        Write-Host "$Prefix" -NoNewline -ForegroundColor Gray
        if ($Prefix) {
            Write-Host (if ($IsLast) { "+- " } else { "|- " }) -NoNewline -ForegroundColor Gray
        }
        
        Write-Host $marker -NoNewline -ForegroundColor $markerColor
        Write-Host " [" -NoNewline -ForegroundColor Gray
        Write-Host $entry.Hash -NoNewline -ForegroundColor Cyan
        Write-Host "] " -NoNewline -ForegroundColor Gray
        
        if ($entry.Hash -eq $HeadHash) {
            Write-Host "(HEAD) " -NoNewline -ForegroundColor Green
        }
        Write-Host "$($entry.Message) ($($entry.Date))" -ForegroundColor White

        $children = $node.Children
        for ($i = 0; $i -lt $children.Count; $i++) {
            $nextLast = ($i -eq ($children.Count - 1))
            $nextPrefix = $Prefix + (if ($Prefix) { if ($IsLast) { "   " } else { "|  " } } else { "" })
            Show-Node -Hash $children[$i] -Prefix $nextPrefix -IsLast $nextLast
        }
    }

    Write-Host "=== BACKUP TREE GRAPH ===" -ForegroundColor Green
    for ($i = 0; $i -lt $roots.Count; $i++) {
        $isLast = ($i -eq ($roots.Count - 1))
        Show-Node -Hash $roots[$i] -Prefix "" -IsLast $isLast
    }
}

function Cmd-list {
    <#
    .SYNOPSIS
        List all backups (alias: ls).
    .DESCRIPTION
        Displays all backups in a clean table format showing Parent lineage.
    #>
    param([string[]]$Args)

    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking
    $history = Get-HistoryEntries
    $headHash = Get-HeadHash

    if ($history.Count -eq 0) {
        Write-Host "No backups found."
        return
    }

    $display = @()
    foreach ($entry in $history) {
        $display += [pscustomobject]@{
            Id       = $entry.Id
            Hash     = $entry.Hash
            Parent   = if ($entry.Parent) { $entry.Parent } else { "" }
            HEAD     = if ($entry.Hash -eq $headHash) { "*" } else { "" }
            Date     = $entry.Date
            Database = $entry.Database
            Size     = "$([Math]::Round($entry.Size / 1KB, 2)) KB"
            Message  = $entry.Message
        }
    }

    $display | Format-Table -Property Id, Hash, Parent, HEAD, Date, Database, Size, Message
}

function Cmd-latest {
    <#
    .SYNOPSIS
        Show the latest backup hash.
    .DESCRIPTION
        Displays the hash of the latest backup.
    #>
    param([string[]]$Args)

    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking
    $head = Get-HeadHash
    if ($head) {
        Write-Host $head
    } else {
        Write-Host "No backups found."
    }
}

function Cmd-show {
    <#
    .SYNOPSIS
        Show details of a backup.
    .DESCRIPTION
        Displays metadata for a specific backup identifier (id, hash, latest).
    .PARAMETER Target
        The backup identifier (ID, hash or 'latest').
    #>
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Target
    )

    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking
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
    }

    if (-not $entry) {
        Write-Error "Backup '$Target' not found."
        return
    }

    Write-Host "commit $($entry.Hash)" -ForegroundColor Yellow
    Write-Host "Id:       $($entry.Id)"
    Write-Host "Parent:   $($entry.Parent)"
    Write-Host "Date:     $($entry.Date)"
    Write-Host "Database: $($entry.Database)"
    Write-Host "Filename: $($entry.Filename)"
    Write-Host "Size:     $($entry.Size) bytes ($([Math]::Round($entry.Size / 1KB, 2)) KB)"
    Write-Host "Message:  $($entry.Message)"

    # Look for detailed metadata
    $metadataDir = Get-MetadataDir
    $metaPath = Join-Path $metadataDir "backup_$($entry.Id).json"
    if (Test-Path $metaPath) {
        $metaObj = Get-Content $metaPath -Raw | ConvertFrom-Json
        Write-Host "`nMetadata Summary:" -ForegroundColor Cyan
        Write-Host "Schema Hash: $($metaObj.schema_hash)"
        Write-Host "Tables list and rows:"
        foreach ($t in $metaObj.tables) {
            Write-Host "  - $($t.schema).$($t.name): $($t.rows) rows"
        }
    }
}

Export-ModuleMember -Function Cmd-history, Cmd-list, Cmd-latest, Cmd-show

