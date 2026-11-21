# Contributing to db_git

Thank you for your interest in contributing to **db_git**! We welcome bug reports, feature requests, documentation improvements, and pull requests.

## Code of Conduct

By participating in this project, you agree to abide by the [Code of Conduct](CODE_OF_CONDUCT.md).

## Development Setup

### Prerequisites
- **PowerShell 7+** (`pwsh`): Required to run and test `db_git`.
- **PostgreSQL Client Tools**: `psql`, `pg_dump`, and `pg_restore` on your system `PATH`.
- **Pester 5.5+**: For running the test suite (`Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck`).
- **Docker** (optional): Needed only for running integration tests against a containerized PostgreSQL instance.

### Repository Layout
```text
db_git/
├── Modules/             # Core functionality modules (Backup, Restore, Diff, etc.)
│   ├── Backup.psm1
│   ├── Config.psm1
│   ├── Diff.psm1
│   ├── Help.psm1
│   ├── Init.psm1
│   ├── Log.psm1
│   ├── Maintenance.psm1
│   ├── Restore.psm1
│   ├── Status.psm1
│   ├── Tag.psm1
│   └── Utils.psm1
├── tests/               # Test suites (Pester)
│   ├── Unit.Tests.ps1
│   ├── Integration.Tests.ps1
│   └── Run-Tests.ps1
├── db_git               # Unix/macOS launcher
├── db_git.cmd           # Windows Command Prompt launcher
├── db_git.ps1           # PowerShell entrypoint and command dispatcher
└── install.ps1          # PATH installation script
```

## Running Tests

Before submitting any code changes, ensure all tests pass:

```powershell
# Run unit tests (~7s, no database required)
./tests/Run-Tests.ps1

# Run integration tests (starts a temporary postgres:17-alpine Docker container)
./tests/Run-Tests.ps1 -Integration

# Run everything
./tests/Run-Tests.ps1 -All
```

## Adding a New Command

1. Create or open the relevant module file in `Modules/<Name>.psm1`.
2. Define your function named `Cmd-<CommandName>`. The dispatcher (`db_git.ps1`) dynamically resolves `Cmd-<CommandName>` and maps `--flag` parameters automatically.
3. Export the function at the bottom using `Export-ModuleMember -Function ...`.
4. Add user-facing help in `Modules/Help.psm1` by implementing `Help-<CommandName>`.
5. Add unit tests in `tests/Unit.Tests.ps1`.

## Submitting Pull Requests

1. Fork the repository and create a descriptive branch:
   ```bash
   git checkout -b feature/my-cool-feature
   ```
2. Commit changes with clear, descriptive commit messages.
3. Ensure unit tests pass locally.
4. Push your branch to GitHub and open a Pull Request.
5. GitHub Actions will run automated checks on Windows and Linux.
