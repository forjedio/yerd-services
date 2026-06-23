# yerd-services

Build (or repackage) database/cache **server binaries**, package them in one uniform
shape, and publish them to a single rolling [GitHub Release](https://github.com/forjedio/yerd-services/releases/tag/services)
where the [Yerd](https://github.com/forjedio/yerd) daemon downloads them on demand
(`yerd service install <svc> <version>`).

There is no static-php-cli equivalent for databases — no single project ships clean,
multi-platform prebuilt binaries for Redis/Valkey, MySQL, MariaDB, and Postgres. So Yerd
hosts its own. This repo is that host.

It is intentionally **isolated** from the main app:

- **No dependency on the main repo** — CI here never clones `forjedio/yerd`. The build
  logic is self-contained (shell + one GitHub Actions workflow).
- **Independent lifecycle** — rebuild a single `(service, version)` whenever an upstream
  release lands, without cutting an app release.
- **Its own provenance + license home** — documents which upstream source each artifact was
  built from, and carries the upstream license texts (see [`LICENSES/`](LICENSES/)).

## Status

| service    | slot filled by | phase | state |
|------------|----------------|-------|-------|
| `redis`    | **Valkey** (BSD-3) | 1 | ✅ implemented (build from source) |
| `mysql`    | Oracle MySQL (GPLv2) | 2 | ✅ implemented (repackage generic tarball) |
| `postgres` | PostgreSQL (PostgreSQL License) | 2 | ✅ implemented (build from source) |
| `mariadb`  | MariaDB (GPLv2) | 3 | ✅ implemented (repackage x86_64 + build from source for ARM/macOS) |

The `redis` slot ships **[Valkey](https://github.com/valkey-io/valkey)** (Linux Foundation,
BSD-3, wire-compatible) because Redis 7.4+ is SSPL/RSALv2 (redistribution-restricted).
`service=valkey` is accepted as a friendly alias for the `redis` slot; the published artifact
is always named `redis-…`.

## The two on-demand flows

Both are one `gh workflow run` (or the Actions **Run workflow** button, or an agent):

```sh
# Release a NEW version — e.g. Valkey 9.1 lands upstream:
gh workflow run release.yml \
  -f action=build -f service=valkey -f version=9.1 -f upstream=9.1.0
#  → builds all platforms, uploads redis-9.1-*.tar.gz, refreshes services.json.
#    Everything else (redis 9.0, mysql, …) is untouched.

# EXCLUDE a bad version — e.g. pull Valkey 9.0:
gh workflow run release.yml \
  -f action=remove -f service=valkey -f version=9.0
#  → deletes redis-9.0-*.tar.gz, refreshes services.json so 9.0 disappears.
#    (upstream is ignored for remove.) Copies already installed on user disks keep working.
```

- `version` is the **label** users type (`9`, `9.1`); `upstream` is the **exact source tag**
  to build (`9.1.0`). Keep the label meaningful — match it to the upstream major/minor (don't
  label a 9.x build `8`). A label like `9` can be repointed to a newer upstream by rebuilding
  with the same `version` and a new `upstream` (the asset is replaced via `--clobber`).
- Removal deletes a version's assets and refreshes the listing; it does not reach back to
  already-installed copies.

## Artifact contract (the binding interface — do not drift)

This is the entire coupling with `forjedio/yerd`. The consumer there
(`crates/yerd-services/src/release.rs` + `bin/yerdd/src/service_install.rs`) parses exactly
this shape.

**Filename:** `<service-id>-<version>-<os>-<arch>.tar.gz`
- `service-id ∈ redis | mysql | mariadb | postgres` (the `redis` slot is served by Valkey on
  Linux/macOS, and by the native MSVC Redis port on Windows — see below)
- `os ∈ linux | macos | windows`, `arch ∈ x86_64 | aarch64` (Windows is `x86_64` only)
- examples: `redis-8-linux-x86_64.tar.gz`, `postgres-16-macos-aarch64.tar.gz`,
  `mysql-8.4.9-windows-x86_64.tar.gz`

**Archive:** a gzip tar whose **root** holds a `bin/` directory with the server executable
(and client/init tools where noted). No absolute/`..` members. Executable bit preserved.
Binaries must be **relocatable** — the daemon runs them from an arbitrary per-user data dir
and points data/socket/port at user paths via config, never compiled-in defaults. Required
`bin/` per service (Unix names shown):

| service    | server binary | also include |
|------------|---------------|--------------|
| `redis`    | `valkey-server` | `valkey-cli` |
| `mysql`    | `mysqld` | `mysql`, `mysqld_safe`, `mysqldump` |
| `mariadb`  | `mariadbd` | `mariadb`, `mariadb-install-db`, `mariadb-dump` |
| `postgres` | `postgres` | `initdb`, `pg_ctl`, `psql`, `createdb`, `pg_dump`, `pg_dumpall`, `pg_restore` |

**Windows differs** from the table above:
- Executables carry `.exe` (`mysqld.exe`, `postgres.exe`, …). Only the **server binary** is
  verified at install; the other tools are advisory.
- **No rpath/install_name on Windows** — the loader finds DLLs next to the `.exe`, so
  self-containment means every non-system DLL (OpenSSL, `libpq`, … plus the bundled VC++
  runtime) lives in `bin/`, *not* `lib/`. (`windows_self_contain_gate` enforces this.)
- `mysql` omits `mysqld_safe` (a Unix-only shell script). `mariadb`'s init tool is
  `mariadb-install-db.exe` or `mysql_install_db.exe` (version-dependent).
- The `redis` slot ships the real **Redis** port binaries `redis-server.exe` / `redis-cli.exe`
  — *not* renamed to `valkey-*`, because on Windows it genuinely is Redis (pre-7.4 BSD), not
  Valkey (which has no native Windows build). So the redis slot's server-binary name is
  platform-divergent.

**Listing (`services.json`):** GitHub Releases has no directory autoindex, so the workflow
publishes a generated `services.json` manifest as a release asset; the daemon fetches it to
discover what's installable. It is derived purely from the release's live `*.tar.gz` assets,
so it can't drift, and is regenerated after every build/remove.

```json
{ "schema": 1,
  "services": {
    "redis": { "versions": [
      { "version": "8", "platforms": ["linux-aarch64","linux-x86_64","macos-aarch64"] }
    ] } } }
```

It carries only what the filenames encode (service, version, platforms); provenance/build
flags live in this README. (A legacy `index.html` listing was dropped in favour of this
manifest; the workflow deletes any leftover `index.html` asset.)

**URLs the consumer hard-codes:**
```
SERVICES_BASE_URL = https://github.com/forjedio/yerd-services/releases/download/services
listing           = {SERVICES_BASE_URL}/services.json
artifact          = {SERVICES_BASE_URL}/<filename>
```
Integrity is TLS-only today (no checksum pinning), matching the PHP path.

## Backup & restore

Each **SQL** service ships the standard logical dump/restore tools in `bin/` so the daemon
(`forjedio/yerd`) can shell out for `yerd service backup/restore` — backup runs the dump tool to
a file, restore loads it back. (redis is excluded — its snapshot mechanism is RDB/AOF, not SQL.)

| service | backup | restore | file |
|---------|--------|---------|------|
| `mysql`    | `mysqldump --no-tablespaces --single-transaction <db>` | `mysql <db> < dump.sql` | `.sql` |
| `mariadb`  | `mariadb-dump --no-tablespaces --single-transaction <db>` | `mariadb <db> < dump.sql` | `.sql` |
| `postgres` | `pg_dump <db>` (plain `.sql`) or `pg_dump -Fc <db>` (custom); `pg_dumpall` for cluster/roles | `psql <db> < dump.sql` (plain) or `pg_restore -d <db> dump.dump` (custom) | `.sql` / custom |

Notes for the daemon: pass `--no-tablespaces` to mysqldump/mariadb-dump so a **non-root** backup
user (no `PROCESS` privilege) works; `--single-transaction` gives a consistent InnoDB dump
without `LOCK TABLES`. Every build smoke-tests a full backup→restore roundtrip before publishing,
so these tools are verified relocatable and functional in the artifact.

## Hosting model

A single **rolling release tagged `services`** holds every artifact + the listing as a flat
bag of independent assets. Each `(service, version, platform)` is one asset; multiple
versions coexist. Adding/rebuilding a `(service, version)` uploads its per-platform assets
with `--clobber` (replacing only same-named assets) — everything else is untouched. This is
within GitHub's acceptable-use posture: artifacts are downloaded once per install and cached
on the user's disk, so traffic scales with installs, not usage. If volume ever warranted it,
the escape hatch is to move `SERVICES_BASE_URL` to a CDN while keeping this artifact contract.

## Provenance

| service | version | upstream source | how | notes |
|---------|---------|-----------------|-----|-------|
| `redis` | _(label)_ | [Valkey](https://github.com/valkey-io/valkey) tag `<upstream>` | build from source | `make -j BUILD_TLS=no` |
| `mysql` | _(label)_ | [Oracle MySQL](https://dev.mysql.com/downloads/mysql/) generic tarball `<upstream>` (e.g. 8.4.9 LTS) | repackage | `bin/{mysqld,mysql,mysqld_safe,mysqldump}` + bundled `lib/`+`share/`; macOS dylib install-names made relocatable |
| `postgres` | _(label)_ | [postgresql.org](https://ftp.postgresql.org/pub/source/) source `<upstream>` (e.g. 17.10) | build from source | `./configure --without-icu --without-readline --without-zlib --without-libxml` (no compressed `pg_dump`); macOS made relocatable |
| `mariadb` | _(label)_ | [archive.mariadb.org](https://archive.mariadb.org/) `<upstream>` (e.g. 11.8.8 LTS) | repackage (linux-x86_64) / build from source (ARM Linux + macOS) | MariaDB ships only a `linux-systemd-x86_64` bintar; CMake build for the rest (`-DWITH_SSL=system`, heavy plugins trimmed). `bin/{mariadbd,mariadb,mariadb-install-db,my_print_defaults,mariadb-dump,…}` + `lib/`+`share/`; made relocatable + self-contained |

**Windows (`windows-x86_64`)** — all repackaged from official vendor zips (no service has a
native Windows ARM64 build, so Windows is x86_64-only; Windows-on-ARM runs x64 via emulation):

| service | windows source | notes |
|---------|----------------|-------|
| `redis` | [tporadowski/redis](https://github.com/tporadowski/redis) `Redis-x64-<redis_win_upstream>.zip` (default `5.0.14.1`) | **native MSVC port of Redis (pre-7.4, BSD-3) — NOT Valkey** (valkey has no Windows build). Version is independent of the Valkey `<upstream>` (set via `redis_win_upstream`). Note the version skew: Windows redis is 5.x while Linux/macOS run Valkey 8/9.x. Ships real `redis-server.exe`/`redis-cli.exe` (plus the port's `EventLog.dll`, covered by the port's BSD-3 notice). redis-server.exe statically links Lua/hiredis/jemalloc/linenoise — their notices ship in `redis-windows-third-party-NOTICES.txt`. |
| `mysql` | [Oracle MySQL](https://dev.mysql.com/downloads/mysql/) `mysql-<upstream>-winx64.zip` | repackage `bin/` (exes + sibling DLLs) + `share/` + `lib/plugin/`; no `mysqld_safe` |
| `mariadb` | [archive.mariadb.org](https://archive.mariadb.org/) `mariadb-<upstream>-winx64.zip` | repackage `bin/` + `share/`; init tool `mariadb-install-db.exe`/`mysql_install_db.exe` |
| `postgres` | [EDB](https://www.enterprisedb.com/download-postgresql-binaries) `postgresql-<upstream>-<N>-windows-x64-binaries.zip` | repackage `pgsql/{bin,lib,share}`; the build-number `<N>` is set via `postgres_win_buildno` (else probed) |

All Windows artifacts bundle the VC++ runtime DLLs into `bin/` and pass
`windows_self_contain_gate` (a `dumpbin -dependents` check, mandatory in CI). The UCRT
(`ucrtbase`/`api-ms-win-*`) ships with Windows 10+ and is treated as system. No Cygwin is
used (its `cygwin1.dll` is GPLv3). Redistribution of the bundled VC++ runtime DLLs is
covered by the folder-level grant for `VC\Redist` (https://aka.ms/vs/17/redist.txt), not a
per-file enumeration.

Each `(service, version)` is built per dispatch; the `<upstream>` actually used is whatever
you pass. Every published artifact is **smoke-tested** on its native platform (start the
server, run `SELECT 1`/`PING`; on Windows over TCP loopback) before it's allowed onto the release.

Surface names with trademark care in the UI: **"Redis (Valkey)"** (BSD-3) on Linux/macOS,
plain **"Redis"** (BSD-3) on Windows; **"MySQL (Oracle)"** (GPLv2, preserve notices) /
MariaDB (GPLv2), PostgreSQL (permissive). Upstream license texts live in
[`LICENSES/`](LICENSES/) (Windows redis carries `redis-BSD-3-Clause.txt` + the port's
combined `redis-windows-port-BSD-3-Clause.txt`).

## Repo layout

```
yerd-services/
├── README.md
├── LICENSES/                       # upstream license texts (BSD/GPL/PostgreSQL)
│   ├── valkey-BSD-3-Clause.txt
│   ├── redis-BSD-3-Clause.txt       # Windows redis slot (Redis pre-7.4)
│   ├── redis-windows-port-BSD-3-Clause.txt  # tporadowski port combined notice
│   ├── redis-windows-third-party-NOTICES.txt  # Lua/hiredis/jemalloc/linenoise (linked deps)
│   ├── mysql-GPLv2.txt
│   ├── postgresql-PostgreSQL-License.txt
│   └── mariadb-GPLv2.txt
├── scripts/
│   ├── lib.sh                      # os/arch tokens, canonical_service, artifact_filename, pack_stage, macos_make_relocatable, …
│   ├── build-service.sh            # build/repackage ONE (service,version,upstream) for the host platform
│   ├── smoke-test.sh               # extract a built artifact + run the server (SELECT 1 / PING) — each build leg, pre-publish
│   └── gen-manifest.sh             # *.tar.gz names (stdin) → services.json (the daemon's listing)
└── .github/workflows/
    └── release.yml                 # workflow_dispatch: ensure-release → build (build+smoke) → finalize
```

## Platform matrix

| target           | runner            |
|------------------|-------------------|
| `linux-x86_64`   | `ubuntu-latest`   |
| `linux-aarch64`  | `ubuntu-24.04-arm`|
| `macos-aarch64`  | `macos-14`        |
| `windows-x86_64` | `windows-latest`  |

**macOS is arm64 (Apple Silicon) only.** GitHub retired the last Intel macOS image
(`macos-13`) in December 2025, and `macos-14`/`macos-15` are arm64-only, so we do not ship a
`macos-x86_64` artifact.

**Windows is x86_64 only.** No service has a native Windows ARM64 upstream binary (Oracle,
MariaDB, and EDB ship win-x64 only; Valkey has no Windows build at all), and Windows-on-ARM
runs x64 binaries via built-in emulation — so a single `windows-x86_64` artifact covers ARM
hardware too. Building from source for ARM Windows is deferred. **Daemon note:** consuming
`windows-*` artifacts requires companion changes in `forjedio/yerd` (its `Os` enum +
`current_os_arch()` currently reject Windows); publishing them here is forward-compatible
(existing daemons only request their own platform token).
