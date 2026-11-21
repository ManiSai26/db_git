# db_git

[![CI](https://github.com/ManiSai26/db_git/actions/workflows/ci.yml/badge.svg)](https://github.com/ManiSai26/db_git/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-7%2B-blue.svg)](https://github.com/PowerShell/PowerShell)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-14%2B-336791.svg)](https://www.postgresql.org/)

**Git-style snapshots for your PostgreSQL development databases.**

Take a snapshot before a risky migration, test run or data fix. If something goes wrong, restore it in one command. Compare any two snapshots, schema and data, as a readable diff or an interactive HTML report.

```powershell
db_git cb -m "before pricing migration"   # snapshot
# ... run the migration, break things ...
db_git diff 4 5 --data --gui              # see exactly what changed
db_git restore 4                          # put it back
```

> **Scope:** db_git is for development and staging databases. It is not a production backup system. For production, use tools built for point-in-time recovery, such as [pgBackRest](https://pgbackrest.org/), [Barman](https://pgbarman.org/) or [WAL-G](https://github.com/wal-g/wal-g).

## Features

- **Workflow like Git.** History, `HEAD`, tags, `show`, `amend`, `reset`, and short hashes for each snapshot.
- **Safe restore.** Restores into a temporary database first, then swaps it in by renaming. If the restore fails, the live database is never touched. The previous database is kept as `<db>_old` for a two-rename rollback.
- **Snapshot diff.** Compares tables, columns, indexes, constraints, sequences, views and triggers. With `--data`, it also compares rows, matched by primary key. `--gui` opens an interactive HTML report.
- **Verify.** Test-restores every snapshot into a throwaway database to prove it's restorable.
- **Runs on Windows.** Pure PowerShell 7 with no Python or Docker needed. It only needs the standard PostgreSQL client tools.

## Requirements

- PowerShell 7+ (`pwsh`)
- PostgreSQL client tools on your `PATH`: `pg_dump`, `pg_restore`, `psql`. Run `db_git doctor` to check.
- For safe restore and diff: a database user that can create databases (the `CREATEDB` privilege) and that owns the target database (needed to rename it). Without these, restore falls back to an in-place `pg_restore --clean`.

## Installation

```powershell
git clone https://github.com/ManiSai26/db_git.git
cd db_git
./install.ps1        # adds this folder to your user PATH
```

Open a new terminal, then run `db_git help`.

## Quick start

```powershell
cd my-project

# Create .db_git/ here. Connection details are read from (in order):
#   flags --db --host --port --user --password
#   DATABASE_URL in ./.env  (postgres://user:pass@host:5432/dbname)
#   interactive prompts
db_git init

db_git cb -m "clean seed data"     # create a snapshot
db_git log                         # history (add --graph / -g for a tree)
db_git show latest                 # tables, row counts, size
db_git tag seeded latest           # name it
db_git restore seeded              # restore by tag, id, hash or 'latest'
```

`init` also adds `.db_git/` to your project's `.gitignore`. Snapshots contain your data, so never commit them.

## Commands

| Command | Description |
|---|---|
| `init` | Create a repository in the current folder |
| `create-backup`, `cb` `-m "<msg>"` | Take a snapshot (`pg_dump -Fc`) |
| `history`, `log` `[--graph]` | Show snapshot history |
| `list`, `ls` | Table of all snapshots |
| `show <target>` | Details of one snapshot (tables, row counts) |
| `latest` | Print the `HEAD` hash |
| `restore <target> [--force] [--drop-old]` | Safe restore (see below) |
| `diff <a> <b> [--data] [--all] [--table <regex>] [--gui] [-Verbose]` | Compare two snapshots |
| `tag <name> [target]`, `tags` | Tag a snapshot / list tags |
| `amend <target> "<msg>"` | Change a snapshot's message |
| `delete`, `remove` `<target> [--force]` | Delete a snapshot |
| `reset <target> [--force]` | Rewind history to a snapshot |
| `search <text>` | Search snapshot messages |
| `verify [target]` | Test-restore snapshots into a temporary database |
| `export <path>` / `import [path]` | Export or import history and metadata |
| `prune` / `gc` | Remove orphaned files / clean the temp folder |
| `status` / `info` / `doctor` / `version` | Repository status, metrics, diagnostics |
| `config` / `config set <key> <value>` / `config reload-env` | View or change connection settings |

A `<target>` can be a numeric id, a hash prefix, a tag, or `latest`. Run `db_git help <command>` for details.

## How restore works

```
1. pg_restore  -> <db>_restore_tmp       (fails? temp db dropped, live db untouched)
2. block + close connections to <db>
3. rename <db> -> <db>_old,  <db>_restore_tmp -> <db>
4. keep <db>_old for rollback (replaced next restore, or --drop-old)
```

Downtime is only the moment of the rename, not the whole restore. The restore needs about twice the database's disk space while it runs.

**Rollback** (close all connections to both databases first):

```sql
ALTER DATABASE "mydb"     RENAME TO "mydb_bad";
ALTER DATABASE "mydb_old" RENAME TO "mydb";
```

## Repository layout

```
.db_git/
  config.json        connection settings (password encrypted with Windows DPAPI)
  HEAD               hash of the current snapshot
  history.csv        id, hash, parent, date, database, file, size, message
  tags.csv           tag -> hash
  db_backups/        pg_dump custom-format files
  metadata/          per-snapshot JSON: tables, row counts, columns
  temp/              diff reports and scratch files
```

## Known limitations

- **Windows-first.** The stored password uses Windows DPAPI, so it can only be decrypted by the same user on the same machine. On Linux and macOS it is not properly protected. Use `.pgpass` there until native support lands.
- **Run from the project root.** Commands must be run from the folder that contains `.db_git/`. Parent folders aren't searched yet.
- **Database-level settings** (`ALTER DATABASE ... SET`, database grants) aren't part of `pg_dump` output, so a restore doesn't bring them back.
- **Full dumps only.** Every snapshot is a complete `pg_dump`. That's fine for dev-sized databases, but slow and large for big ones.

## Extending

Each command is a `Cmd-<name>` function in a module under `Modules/`. The dispatcher (`db_git.ps1`) finds it automatically and maps `--flag` arguments to the function's parameters, including `[Alias()]` names. Add a `Help-<name>` function in `Modules/Help.psm1` for `db_git help <name>`.

## Testing

The tests use [Pester](https://pester.dev/) 5.5+ (`Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck`).

```powershell
./tests/Run-Tests.ps1                # unit tests, no database needed (~7s)
./tests/Run-Tests.ps1 -Integration   # end-to-end against a throwaway Postgres in Docker
./tests/Run-Tests.ps1 -All           # both (~35s)
```

The integration tests drive the real CLI: `init`, `cb`, `diff`, `verify` and `restore`, including a restore from a corrupted dump that must leave the live database untouched. They start a `postgres:17-alpine` container and remove it afterwards. To use your own **throwaway** server instead, set `DBGIT_TEST_HOST`, `DBGIT_TEST_PORT`, `DBGIT_TEST_USER` and `DBGIT_TEST_PASSWORD`. The tests create and drop databases.

## Contributing

Contributions are welcome! Please check out [CONTRIBUTING.md](CONTRIBUTING.md) for local setup, testing instructions, and pull request guidelines.

Please note that this project is governed by our [Code of Conduct](CODE_OF_CONDUCT.md). For security vulnerabilities, please refer to [SECURITY.md](SECURITY.md).

## License

See [LICENSE](LICENSE).
