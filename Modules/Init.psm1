# Init.psm1

# Implements the 'init' command for db_git.

function Cmd-init {
    <#
    .SYNOPSIS
        Initialise a db_git repository in the current directory.
    .DESCRIPTION
        Creates the .db_git folder hierarchy and configuration. If a .env file with DATABASE_URL is present, it parses connection details, otherwise it interactively prompts the user.
    .EXAMPLE
        db_git init
    #>
    param([string[]]$Args)

    $repoPath = Join-Path (Get-Location) '.db_git'
    if (Test-Path $repoPath) {
        Write-Error "Repository already initialized in $(Get-Location)."
        return
    }

    # Create folder structure
    $folders = @(
        $repoPath,
        (Join-Path $repoPath 'db_backups'),
        (Join-Path $repoPath 'metadata'),
        (Join-Path $repoPath 'temp')
    )
    foreach ($f in $folders) { New-Item -ItemType Directory -Path $f -Force | Out-Null }

    # Create placeholder files
    New-Item -ItemType File -Path (Join-Path $repoPath 'HEAD') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $repoPath 'history.csv') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $repoPath 'tags.csv') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $repoPath 'config.json') -Force | Out-Null

    Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Utils.psm1') -Force -DisableNameChecking
    $config = Initialize-DbGitConfig -InitArgs $Args
    if ($null -eq $config) {
        Write-Error "Failed to initialise configuration."
        return
    }

    if (Ensure-DbGitIgnored) {
        Write-Host "Updated .gitignore to exclude .db_git/ (it holds SQL dumps and repo config)."
    }

    Write-Host "Repository initialised successfully."
    Write-Host "Configuration saved to .db_git/config.json"
}

Export-ModuleMember -Function Cmd-init

