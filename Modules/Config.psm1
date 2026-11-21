# Config.psm1

# Handles repository configuration stored in .db_git/config.json

function Get-DbGitConfig {
    <#
    .SYNOPSIS
        Retrieves the current db_git configuration.
    .DESCRIPTION
        Reads .db_git/config.json in the current directory. Returns a PowerShell object.
    .OUTPUTS
        [hashtable] Configuration data.
    #>
    $configPath = Join-Path (Get-Location) '.db_git' 'config.json'
    if (Test-Path $configPath) {
        $json = Get-Content $configPath -Raw | ConvertFrom-Json
        # Convert PSCustomObject to Hashtable for easier manipulation
        $hash = @{}
        foreach ($prop in $json.PSObject.Properties) {
            $hash[$prop.Name] = $prop.Value
        }
        return $hash
    } else {
        Write-Warning "Configuration not found. Run 'db_git init' first."
        return $null
    }
}

function Protect-DbGitPassword {
    <#
    .SYNOPSIS
        Encrypts a plaintext password for storage using Windows DPAPI (current user + machine).
    .DESCRIPTION
        Falls back to returning the value unchanged (with a warning) if encryption isn't
        available on this platform, so config writes never hard-fail.
    #>
    param([string]$PlainPassword)
    if (-not $PlainPassword) { return $PlainPassword }
    try {
        return ($PlainPassword | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString)
    } catch {
        Write-Warning "Could not encrypt password on this platform; storing as plaintext."
        return $PlainPassword
    }
}

function Unprotect-DbGitPassword {
    <#
    .SYNOPSIS
        Decrypts a password previously stored by Protect-DbGitPassword.
    .DESCRIPTION
        Returns the value unchanged if it isn't a valid encrypted blob for this user/machine
        (e.g. a legacy plaintext config, or one copied from another machine).
    #>
    param([string]$StoredPassword)
    if (-not $StoredPassword) { return $StoredPassword }
    try {
        $secure = ConvertTo-SecureString $StoredPassword -ErrorAction Stop
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    } catch {
        return $StoredPassword
    }
}

function Set-DbGitConfig {
    <#
    .SYNOPSIS
        Writes configuration to .db_git/config.json.
    .DESCRIPTION
        Accepts a hashtable of config keys and updates the file. The password field is
        always persisted encrypted, whether it arrived as plaintext or already-encrypted.
    .PARAMETER Config
        Hashtable of configuration values.
    #>
    param(
        [Parameter(Mandatory=$true)][hashtable]$Config
    )
    $toSave = $Config.Clone()
    if ($toSave.password) {
        $plain = Unprotect-DbGitPassword -StoredPassword $toSave.password
        $toSave.password = Protect-DbGitPassword -PlainPassword $plain
    }
    $configPath = Join-Path (Get-Location) '.db_git' 'config.json'
    $json = $toSave | ConvertTo-Json -Depth 5
    $json | Set-Content -Path $configPath -Encoding UTF8
}

function Initialize-DbGitConfig {
    <#
    .SYNOPSIS
        Creates default configuration after parsing .env, command line args, or user prompts.
    .DESCRIPTION
        Looks for command line args, or a .env file with DATABASE_URL. If not found, prompts for connection parameters.
    #>
    param(
        [string[]]$InitArgs
    )
    $config = @{}

    # 1. Parse command line args if provided
    if ($InitArgs) {
        for ($i = 0; $i -lt $InitArgs.Length; $i++) {
            switch ($InitArgs[$i]) {
                '--db'       { $config.database = $InitArgs[++$i] }
                '--host'     { $config.host = $InitArgs[++$i] }
                '--port'     { $config.port = [int]$InitArgs[++$i] }
                '--user'     { $config.username = $InitArgs[++$i] }
                '--password' { $config.password = $InitArgs[++$i] }
            }
        }
    }

    # 2. Parse from .env if still missing
    if (-not $config.database) {
        $envPath = Join-Path (Get-Location) '.env'
        if (Test-Path $envPath) {
            $envLines = Get-Content $envPath | Where-Object { $_ -match '^\s*DATABASE_URL\s*=' }
            if ($envLines) {
                $url = $envLines -replace '^\s*DATABASE_URL\s*=\s*', ''
                if ($url -match '^postgres(?:ql)?://([^:]+):([^@]+)@([^:]+)(?::(\d+))?/(.+)') {
                    $config.username = $matches[1]
                    $config.password = $matches[2]
                    $config.host = $matches[3]
                    $config.port = if ($matches[4]) { [int]$matches[4] } else { 5432 }
                    $config.database = $matches[5]
                }
            }
        }
    }

    # 3. Interactively prompt if still missing
    if (-not $config.database) {
        Write-Host "Enter PostgreSQL connection details:"
        $config.database = Read-Host "Database"
        $config.host = Read-Host "Host (default: localhost)"
        if (-not $config.host) { $config.host = 'localhost' }
        $portStr = Read-Host "Port (default: 5432)"
        $config.port = if ($portStr) { [int]$portStr } else { 5432 }
        $config.username = Read-Host "Username"
        $config.password = Read-Host "Password"
    }

    $config.created = (Get-Date).ToString('o')
    Set-DbGitConfig -Config $config
    return $config
}

function Cmd-configuration {
    <#
    .SYNOPSIS
        Show or update the configuration (alias: config).
    .DESCRIPTION
        Supports showing, setting, and reloading configurations.
    .EXAMPLE
        db_git config
        db_git config set host localhost
        db_git config reload-env
    #>
    param([string[]]$Args)

    $config = Get-DbGitConfig
    if ($null -eq $config) { return }

    if ($Args.Length -eq 0) {
        # Show configuration
        $config.Keys | ForEach-Object {
            if ($_ -eq 'password') {
                Write-Host "$_ : $(if ($config[$_]) { '********' } else { '(not set)' })"
            } else {
                Write-Host "$_ : $($config[$_])"
            }
        }
        return
    }

    $subCmd = $Args[0]
    if ($subCmd -eq "set" -and $Args.Length -ge 3) {
        $key = $Args[1]
        $val = $Args[2]
        
        if ($key -eq "port") { $val = [int]$val }
        $config[$key] = $val
        Set-DbGitConfig -Config $config
        Write-Host "Configuration updated: $key = $val"
    }
    elseif ($subCmd -eq "reload-env") {
        Write-Host "Reloading configuration from .env file..."
        $newConfig = Initialize-DbGitConfig
        if ($newConfig) {
            Write-Host "Configuration successfully reloaded from .env."
        }
    }
    else {
        Write-Warning "Usage: db_git config [set <key> <val> | reload-env]"
    }
}

Export-ModuleMember -Function Get-DbGitConfig, Set-DbGitConfig, Initialize-DbGitConfig, Cmd-configuration, Protect-DbGitPassword, Unprotect-DbGitPassword


