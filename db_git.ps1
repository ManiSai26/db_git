#!/usr/bin/env pwsh
# db_git - Git‑like tool for PostgreSQL backups
#
# This script is the entry point. It loads command modules and dispatches
# sub‑commands. All public commands are implemented as functions in the
# `Modules/` sub‑directory.

# Ensure we are running PowerShell 7+
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "db_git requires PowerShell 7 or higher."
    exit 1
}

# Resolve script directory (location of db_git.ps1)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$moduleDir = Join-Path $scriptDir 'Modules'

# Import all module files (*.psm1)
if (Test-Path $moduleDir) {
    Get-ChildItem -Path $moduleDir -Filter *.psm1 -File | ForEach-Object {
        Import-Module $_.FullName -Force -DisableNameChecking
    }
}

# Helper: show usage when no arguments or help requested
function Show-Help {
    param([string]$Topic)
    if (-not $Topic) {
        Write-Host "db_git – PostgreSQL backup management`n"
        Write-Host "Usage: db_git <command> [options]`n"
        Write-Host "Common commands:"
        Write-Host "  init               Initialise a repository"
        Write-Host "  status             Show status of repository"
        Write-Host "  info               Show detailed repository metrics"
        Write-Host "  doctor             Run diagnostics on repository"
        Write-Host "  cb, create-backup  Create a backup"
        Write-Host "  ls, list           List all backups"
        Write-Host "  log, history       Show commit history"
        Write-Host "  latest             Show latest backup hash"
        Write-Host "  show <target>      Show details of a specific backup"
        Write-Host "  restore <target>   Restore a backup"
        Write-Host "  reset <target>     Hard reset history to a backup"
        Write-Host "  delete <target>    Delete a backup"
        Write-Host "  amend <target>     Amend backup message"
        Write-Host "  tag <name>         Tag a backup"
        Write-Host "  diff <src> <tgt>   Diff two backups"
        Write-Host "  search <query>     Search backup messages"
        Write-Host "  config             Show or edit configuration"
        Write-Host "  prune              Prune orphan backups and metadata"
        Write-Host "  gc                 Clean up temp folders"
        Write-Host "  verify             Verify backups are restorable`n"
        Write-Host "Run 'db_git help <command>' for detailed help."
        return
    }
    # Dispatch to command‑specific help functions if they exist
    $funcName = "Help-$Topic"
    if (Get-Command $funcName -ErrorAction SilentlyContinue) {
        & $funcName
    } else {
        Write-Warning "No help available for '$Topic'."
    }
}

# Parse arguments
$command = $args[0]
if (-not $command -or $command -in @('help', '--help', '-h')) {
    Show-Help $args[1]
    exit 0
}

# Convert aliases to canonical command names
switch ($command) {
    'cb' { $command = 'create-backup' }
    'ls' { $command = 'list' }
    'log' { $command = 'history' }
    'config' { $command = 'configuration' }
    'tags' { $command = 'list-tags' }
    'remove' { $command = 'delete' }
    default { }
}

# Build a hashtable of available command functions (public functions start with Cmd-)
$available = Get-Command -CommandType Function | Where-Object { $_.Name -like 'Cmd-*' } | ForEach-Object { $_.Name.Substring(4) }
if ($available -notcontains $command) {
    Write-Error "Unknown command: $command"
    Show-Help
    exit 1
}

# Invoke the command function, passing remaining args
$func = "Cmd-$command"
$positionalArgs = @()
$namedParams = @{}

if ($args.Length -gt 1) {
    $remainingArgs = $args[1..($args.Length - 1)]
    
    $cmdObj = Get-Command $func
    $paramMetadata = $cmdObj.Parameters

    $i = 0
    while ($i -lt $remainingArgs.Length) {
        $arg = $remainingArgs[$i]
        if ($arg -like '-*') {
            # Clean parameter name (strip - or --)
            $rawName = $arg.TrimStart('-')
            
            # Find matching parameter name in function (case-insensitive)
            $matchedName = $null
            foreach ($pName in $paramMetadata.Keys) {
                if ($pName -eq $rawName) {
                    $matchedName = $pName
                    break
                }
                # Check aliases
                $aliases = $paramMetadata[$pName].Aliases
                if ($aliases -and $rawName -in $aliases) {
                    $matchedName = $pName
                    break
                }
            }

            if ($matchedName) {
                $pType = $paramMetadata[$matchedName].ParameterType.Name
                if ($pType -eq 'SwitchParameter') {
                    $namedParams[$matchedName] = $true
                    $i++
                } else {
                    # Takes value: get next arg
                    if ($i + 1 -lt $remainingArgs.Length) {
                        $namedParams[$matchedName] = $remainingArgs[$i + 1]
                        $i += 2
                    } else {
                        # No value supplied, pass as true/empty
                        $namedParams[$matchedName] = $true
                        $i++
                    }
                }
            } else {
                # Parameter not found in function metadata: treat as positional
                $positionalArgs += $arg
                $i++
            }
        } else {
            # Positional argument
            $positionalArgs += $arg
            $i++
        }
    }
}

& $func @positionalArgs @namedParams

