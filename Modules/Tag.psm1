# Tag.psm1

# Implements tag and list-tags (tags) commands.

function Cmd-tag {
    <#
    .SYNOPSIS
        Tag a backup or list tags.
    .DESCRIPTION
        If a name is provided, tags the current HEAD backup with that name.
        If no name is provided, lists all tags.
    .PARAMETER Name
        The name of the tag to create.
    .PARAMETER Target
        The target backup to tag (default: latest HEAD).
    .EXAMPLE
        db_git tag production
        db_git tag before_migration 4
    #>
    param(
        [Parameter(Position=0)]
        [string]$Name,
        [Parameter(Position=1)]
        [string]$Target
    )

    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking
    $repo = Get-DbGitRepoPath
    if (-not $repo) { return }

    $tagsPath = Join-Path $repo 'tags.csv'

    if (-not $Name) {
        # List all tags
        Cmd-list-tags
        return
    }

    # Resolve target backup to a hash
    $hash = ""
    $history = Get-HistoryEntries
    if ($Target) {
        if ($Target -as [int]) {
            $entry = $history | Where-Object { $_.Id -eq [int]$Target }
        } else {
            $entry = $history | Where-Object { $_.Hash -like "${Target}*" }
        }
        if ($entry) {
            $hash = $entry.Hash
        } else {
            Write-Error "Backup target '$Target' not found."
            return
        }
    } else {
        $hash = Get-HeadHash
        if (-not $hash) {
            Write-Error "No backups exist to tag."
            return
        }
    }

    # Update or add tag in tags.csv
    $dateIso = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $existing = @()
    if (Test-Path $tagsPath) {
        $existing = Get-Content $tagsPath | Where-Object { $_ -match '\S' }
    }

    $updated = @()
    $found = $false
    foreach ($line in $existing) {
        $parts = $line -split ','
        if ($parts[0] -eq $Name) {
            $updated += "$Name,$hash,$dateIso"
            $found = $true
        } else {
            $updated += $line
        }
    }

    if (-not $found) {
        $updated += "$Name,$hash,$dateIso"
    }

    $updated | Set-Content -Path $tagsPath -Encoding UTF8
    Write-Host "Tagged commit $hash as '$Name'"
}

function Cmd-list-tags {
    <#
    .SYNOPSIS
        List all tags (alias: tags).
    .DESCRIPTION
        Displays all tags in the repository.
    #>
    param([string[]]$Args)

    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking
    $repo = Get-DbGitRepoPath
    if (-not $repo) { return }
    $tagsPath = Join-Path $repo 'tags.csv'

    if (-not (Test-Path $tagsPath)) {
        Write-Host "No tags created yet."
        return
    }

    $lines = @(Get-Content $tagsPath | Where-Object { $_ -match '\S' })
    if (-not $lines -or $lines.Count -eq 0) {
        Write-Host "No tags created yet."
        return
    }

    $tags = @()
    foreach ($line in $lines) {
        $parts = $line -split ','
        $tags += [pscustomobject]@{
            Tag  = $parts[0]
            Hash = $parts[1]
            Date = $parts[2]
        }
    }

    $tags | Format-Table -Property Tag, Hash, Date
}

Export-ModuleMember -Function Cmd-tag, Cmd-list-tags

