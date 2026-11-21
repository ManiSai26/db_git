# install.ps1
# Installs db_git globally by adding its directory to the User PATH (Windows)
# or creating a symlink in ~/.local/bin (Linux / macOS).

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "Installing db_git..." -ForegroundColor Cyan
Write-Host "Source directory: $scriptDir"

$isWin = $IsWindows -or ($env:OS -like "*Windows*")

if ($isWin) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $cleanedPath = if ($userPath) { $userPath.TrimEnd(';') } else { "" }

    # Check if already in Path
    if ($cleanedPath -split ';' -contains $scriptDir) {
        Write-Host "db_git is already installed (found in User PATH)." -ForegroundColor Green
    } else {
        $newPath = if ($cleanedPath) { "$cleanedPath;$scriptDir" } else { $scriptDir }
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Host "Successfully added db_git to User PATH." -ForegroundColor Green
        Write-Host "Please restart your terminal to start using 'db_git' from anywhere!" -ForegroundColor Yellow
    }
} else {
    $binDir = [System.IO.Path]::Combine($env:HOME, ".local", "bin")
    if (-not (Test-Path $binDir)) {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    }

    $target = [System.IO.Path]::Combine($scriptDir, "db_git")
    $symlink = [System.IO.Path]::Combine($binDir, "db_git")

    if (Test-Path $symlink) {
        Remove-Item $symlink -Force
    }

    & ln -s $target $symlink
    Write-Host "Successfully linked db_git to $symlink" -ForegroundColor Green

    if ($env:PATH -split ':' -notcontains $binDir) {
        Write-Host "Note: Ensure '$binDir' is on your PATH (e.g. export PATH=`"`$HOME/.local/bin:`$PATH`" in ~/.bashrc or ~/.zshrc)" -ForegroundColor Yellow
    }
}
