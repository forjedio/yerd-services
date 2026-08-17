# yerd-services

Build (or repackage) database/cache **server binaries**, package them in one uniform
shape, and publish them to a single rolling [GitHub Release](https://github.com/forjedio/yerd-services/releases/tag/services)
where the [Yerd](https://github.com/forjedio/yerd) daemon downloads them on demand
(`yerd service install <svc> <version>`).

There is no static-php-cli equivalent for databases — no single project ships clean,
multi-platform prebuilt binaries for Redis/Valkey, MySQL, MariaDB, Postgres, and Meilisearch.
So Yerd hosts its own. This repo is that host.

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
| `meilisearch` | Meilisearch **Community Edition** (MIT) | 4 | ✅ implemented (build from source, all platforms) |
| `versitygw` | [versitygw](https://github.com/versity/versitygw) S3 gateway (Apache-2.0) | _(rolling)_ | ✅ implemented (repackage prebuilt binary, all platforms) |

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
- `service-id ∈ redis | mysql | mariadb | postgres | meilisearch | versitygw` (the `redis` slot is
  served by Valkey on Linux/macOS, and by the native MSVC Redis port on Windows — see below)
- `os ∈ linux | macos | windows`, `arch ∈ x86_64 | aarch64` (Windows is `x86_64` only)
- examples: `redis-8-linux-x86_64.tar.gz`, `postgres-16-macos-aarch64.tar.gz`,
  `mysql-8.4.9-windows-x86_64.tar.gz`, `meilisearch-1.49.0-linux-aarch64.tar.gz`

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
| `meilisearch` | `meilisearch` | _(single self-contained binary; no client/init tools)_ |
| `versitygw` | `versitygw` | _(single self-contained binary; no client/init tools)_ |

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
a file, restore loads it back. (redis is excluded — its snapshot mechanism is RDB/AOF, not SQL;
meilisearch is excluded too — it is a search engine with its own dump API, not an SQL server.)

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

## CDN mirror

The escape hatch above is implemented: every artifact is mirrored to a **BunnyCDN storage
zone**, and the consumer can be pointed at it by changing `SERVICES_BASE_URL` alone. GitHub
Releases remains the source of truth — the CDN is a mirror, never the primary.

**Zone layout** (flat, no history — only the current file for each `(service, version, platform)`):

```
services/<service>-<version>-<os>-<arch>.tar.gz   the artifacts
services/services.json                            listing, contract copy
services.json                                     listing, zone-root copy
```

The listing is **written to both locations**, byte-identical, in the same step. That is what
keeps the artifact contract intact: with `SERVICES_BASE_URL = https://<pullzone>/services`,
both `{base}/services.json` and `{base}/<filename>` resolve, so **no consumer change beyond
the base URL**. The zone-root copy is for browsing and tooling. There is no signature file —
`services.json` is unsigned here exactly as it is on the GitHub release.

**Two workflows:**

| workflow | trigger | what it does |
|---|---|---|
| `release.yml` job `cdn-mirror` | automatic, after `finalize` | Mirrors just the dispatched `(service, version)`. On `build`: uploads the platforms, publishes both manifest copies, purges. On `remove`: publishes + purges the shrunken manifest **first**, then deletes the objects. `continue-on-error` — a CDN hiccup never fails a release. |
| `cdn-sync.yml` | manual `workflow_dispatch` | Reconciles the whole zone against the live release: uploads missing, re-uploads changed, deletes orphans. **Defaults to a dry run** — prints the plan and mutates nothing until re-run with `apply=true`. Run this whenever the CDN and the release have drifted. |

Both hold the same `services-release` concurrency group, so a manual sync and an automatic
mirror can never interleave writes to the manifest.

**Change detection** uses the per-asset SHA-256 that GitHub already publishes (`digest` on the
release asset) compared against Bunny's listing `Checksum`, with object size as the fallback.
No `SHA256SUMS` file is involved. `scripts/cdn-reconcile-plan.sh` computes the plan offline
from two JSON snapshots and is unit-tested in `scripts/test.sh`.

Two safety properties are worth knowing because they are easy to break:

- An asset that exists on the release but is **not yet in state `uploaded`** (a half-finished
  publish) is excluded from the manifest but its CDN object is **preserved**, never treated as
  an orphan. The sync warns instead.
- `services/services.json` is in the reconcile's protected set, so the contract copy is never
  pruned. `bunny-delete.sh` independently refuses any path outside `services/`.

### `CDN_CHECKSUM_MODE` — set this before the first sync

Bunny's checksum behaviour varies by zone, and getting it wrong causes either silent
non-verification or permanent re-upload churn. The resolved answer lives in **one** place, the
`CDN_CHECKSUM_MODE` constant in `scripts/lib.sh`, read by both writers and echoed into every
sync plan so a run summary can never claim a mode different from the one that ran.

Determine the zone's behaviour once (does a PUT accept a `Checksum:` header? does the listing
`Checksum` get populated? is it **refreshed on in-place overwrite**?) and set the matching value:

| mode | zone behaviour | digest sent on PUT | comparison |
|---|---|---|---|
| `hash` | accepts, populates, **refreshes** | yes | full hash comparison |
| `nopopulate` | accepts but never populates | yes | size-only |
| `stale` | accepts and populates, **never refreshes** | yes | size-only; CDN checksums nulled first |
| `noheader` | does not accept the header | no | size-only; downloads verified locally instead |

**The default is `noheader`** — the fail-safe cell: it never churns, never relies on unverified
behaviour, and still verifies content via a local `sha256sum` before upload. Setting `hash` on a
zone that does not refresh on overwrite makes every sync re-upload the whole mirror forever,
which the summary would report as healthy. `stale` exists precisely because a stale checksum is
non-null, so it mismatches forever unless the reconcile ignores CDN checksums outright.

The `verify_checksums` input on `cdn-sync.yml` is a deliberate **full-mirror repair**, not
routine maintenance. Outside mode `hash`, size-only comparison is the expected steady state and
the plan reports it without a call to action.

### Prerequisites (one-time, per repo)

GitHub secrets and variables are per-repository, so these must be configured on
`forjedio/yerd-services` even if the sibling `forjedio/yerd` repo already has them.

- Secrets: `BUNNY_STORAGE_ACCESS_KEY` (storage-zone password), `BUNNY_PURGE_API_KEY`
  (account-scoped purge key — scope and rotate it as narrowly as Bunny allows).
- Variables: `BUNNY_STORAGE_ZONE`, `BUNNY_STORAGE_ENDPOINT` (the **region host**, e.g.
  `ny.storage.bunnycdn.com` — a wrong region 401s indistinguishably from a bad key),
  `BUNNY_PULLZONE_HOST`.
- Set `CDN_CHECKSUM_MODE` in `scripts/lib.sh` per the table above.

Then, **before pointing any consumer at the CDN**: run `cdn-sync.yml` with `apply=false`,
review the printed plan, then re-run with `apply=true` to backfill every existing artifact. The
mirror is incomplete until that has succeeded — `services.json` lists all live versions, so
CDN-derived URLs for pre-existing versions 404 until the backfill runs. Confirm in the Actions
tab that each run actually **executed** (GitHub keeps only one pending run per concurrency
group, so a queued run can be superseded by a later dispatch).

## Provenance

| service | version | upstream source | how | notes |
|---------|---------|-----------------|-----|-------|
| `redis` | _(label)_ | [Valkey](https://github.com/valkey-io/valkey) tag `<upstream>` | build from source | `make -j BUILD_TLS=no` |
| `mysql` | _(label)_ | [Oracle MySQL](https://dev.mysql.com/downloads/mysql/) generic tarball `<upstream>` (e.g. 8.4.9 LTS) | repackage | `bin/{mysqld,mysql,mysqld_safe,mysqldump}` + bundled `lib/`+`share/`; macOS dylib install-names made relocatable |
| `postgres` | _(label)_ | [postgresql.org](https://ftp.postgresql.org/pub/source/) source `<upstream>` (e.g. 17.10) | build from source | `./configure --without-icu --without-readline --without-zlib --without-libxml` (no compressed `pg_dump`); macOS made relocatable. Also bundles a curated set of contrib extensions + **pgvector** (`PGVECTOR_UPSTREAM`, default `v0.8.5`) — see [Bundled extensions](#bundled-extensions) |
| `mariadb` | _(label)_ | [archive.mariadb.org](https://archive.mariadb.org/) `<upstream>` (e.g. 11.8.8 LTS) | repackage (linux-x86_64) / build from source (ARM Linux + macOS) | MariaDB ships only a `linux-systemd-x86_64` bintar; CMake build for the rest (`-DWITH_SSL=system`, heavy plugins trimmed). `bin/{mariadbd,mariadb,mariadb-install-db,my_print_defaults,mariadb-dump,…}` + `lib/`+`share/`; made relocatable + self-contained |
| `meilisearch` | _(label)_ | [Meilisearch](https://github.com/meilisearch/meilisearch) source tag `<upstream>` (e.g. `v1.49.0`) | build from source (all platforms) | **Community Edition** via `cargo build --release --locked -p meilisearch` (default features — the `enterprise` feature is **not** enabled, so BUSL-1.1 EE code is compiled out; MIT-only). Rust toolchain auto-selected from the source's `rust-toolchain.toml`. Single self-contained `bin/meilisearch` (`bin/meilisearch.exe` on Windows, where the VC++ runtime is bundled; no `lib/`). **No `macos-x86_64` leg** — see [Platform matrix](#platform-matrix) |
| `versitygw` | _(label)_ | [versitygw](https://github.com/versity/versitygw) release tag `<upstream>` (e.g. `1.7.0`) | repackage prebuilt (all platforms) | **Pure repackage, no toolchain**: download upstream's official static Go binary (`versitygw_v<up>_<Darwin\|Linux>_<x86_64\|arm64>.tar.gz`; `…_Windows_x86_64.zip` on Windows), lift out `bin/versitygw` (`bin/versitygw.exe` on Windows), ship its `LICENSE` + `NOTICE` (Apache-2.0). Single self-contained binary (no `lib/`). **Windows note:** the exe imports only `kernel32.dll` (static Go), so nothing is bundled, but its posix backend needs `--sidecar` at runtime — see the Windows table below |

**Windows (`windows-x86_64`)** — all repackaged from official vendor zips (no service has a
native Windows ARM64 build, so Windows is x86_64-only; Windows-on-ARM runs x64 via emulation):

| service | windows source | notes |
|---------|----------------|-------|
| `redis` | [tporadowski/redis](https://github.com/tporadowski/redis) `Redis-x64-<redis_win_upstream>.zip` (default `5.0.14.1`) | **native MSVC port of Redis (pre-7.4, BSD-3) — NOT Valkey** (valkey has no Windows build). Version is independent of the Valkey `<upstream>` (set via `redis_win_upstream`). Note the version skew: Windows redis is 5.x while Linux/macOS run Valkey 8/9.x. Ships real `redis-server.exe`/`redis-cli.exe` (plus the port's `EventLog.dll`, covered by the port's BSD-3 notice). redis-server.exe statically links Lua/hiredis/jemalloc/linenoise — their notices ship in `redis-windows-third-party-NOTICES.txt`. |
| `mysql` | [Oracle MySQL](https://dev.mysql.com/downloads/mysql/) `mysql-<upstream>-winx64.zip` | repackage `bin/` (exes + sibling DLLs) + `share/` + `lib/plugin/`; no `mysqld_safe` |
| `mariadb` | [archive.mariadb.org](https://archive.mariadb.org/) `mariadb-<upstream>-winx64.zip` | repackage `bin/` + `share/`; init tool `mariadb-install-db.exe`/`mysql_install_db.exe` |
| `postgres` | [EDB](https://www.enterprisedb.com/download-postgresql-binaries) `postgresql-<upstream>-<N>-windows-x64-binaries.zip` | repackage `pgsql/{bin,lib,share}`; the build-number `<N>` is set via `postgres_win_buildno` (else probed). The EDB zip already carries the contrib extensions (shipped via the verbatim `lib/`+`share/` copy); **pgvector is not bundled on Windows** — see [Bundled extensions](#bundled-extensions) |
| `meilisearch` | _(from source)_ [Meilisearch](https://github.com/meilisearch/meilisearch) source tag `<upstream>` | **Not repackaged** — built from Rust source with `cargo build --release --locked -p meilisearch` on the windows runner, identical CE recipe to the Unix legs, emitting `bin/meilisearch.exe`. Rust's MSVC target dynamically links the VC++ runtime, so those DLLs are bundled into `bin/` and pass `windows_self_contain_gate` |
| `versitygw` | [versitygw](https://github.com/versity/versitygw) `versitygw_v<up>_Windows_x86_64.zip` | repackage the single `bin/versitygw.exe`. It is a **static Go binary** importing only `kernel32.dll`, so no VC++ runtime is bundled (the gate still runs and passes). **Runtime divergence:** versitygw's posix backend stores S3 object metadata in POSIX extended attributes, which NTFS lacks — on Windows it must be launched with `--sidecar <dir>` (metadata in a directory) or `--nometa`; the daemon must pass this for Windows installs. The smoke test exercises the `--sidecar` path |

Every Windows artifact that links the VC++ runtime bundles those DLLs into `bin/`, and **all**
pass `windows_self_contain_gate` (a `dumpbin -dependents` check, mandatory in CI). The lone
exception to bundling is `versitygw` — a static Go exe that imports only system DLLs, so it needs
nothing bundled and passes the gate with an empty bin/ DLL set. The UCRT
(`ucrtbase`/`api-ms-win-*`) ships with Windows 10+ and is treated as system. No Cygwin is
used (its `cygwin1.dll` is GPLv3). Redistribution of the bundled VC++ runtime DLLs is
covered by the folder-level grant for `VC\Redist` (https://aka.ms/vs/17/redist.txt), not a
per-file enumeration.

The **postgres `full`** variant (see [Variants](#variants)) additionally builds from:
[PostGIS](https://postgis.net/) `POSTGIS_UPSTREAM` (default 3.6.0, GPLv2, with raster),
[GEOS](https://libgeos.org/) (LGPL-2.1), [PROJ](https://proj.org/) (X/MIT),
[GDAL](https://gdal.org/) (MIT) + json-c/protobuf-c — GEOS/PROJ/GDAL provisioned from the
platform package manager (apt/brew) and bundled+relocated into the artifact; Windows overlays the
prebuilt [OSGeo PostGIS bundle](https://download.osgeo.org/postgis/windows/) (`POSTGIS_WIN_UPSTREAM`).
Unix `full` also bundles [TimescaleDB](https://github.com/timescale/timescaledb) Community edition
(`TIMESCALEDB_UPSTREAM`, default `2.28.3`, [TSL](https://github.com/timescale/timescaledb/blob/main/tsl/LICENSE-TIMESCALE)) —
see [Bundled extensions](#bundled-extensions).

Each `(service, version)` is built per dispatch; the `<upstream>` actually used is whatever
you pass. Every published artifact is **smoke-tested** on its native platform (start the
server, run `SELECT 1`/`PING`; on Windows over TCP loopback) before it's allowed onto the release.

Surface names with trademark care in the UI: **"Redis (Valkey)"** (BSD-3) on Linux/macOS,
plain **"Redis"** (BSD-3) on Windows; **"MySQL (Oracle)"** (GPLv2, preserve notices) /
MariaDB (GPLv2), PostgreSQL (permissive), **Meilisearch** (MIT, Community Edition). Upstream
license texts live in [`LICENSES/`](LICENSES/) (Windows redis carries `redis-BSD-3-Clause.txt`
+ the port's combined `redis-windows-port-BSD-3-Clause.txt`).

## Meilisearch (Community Edition)

Meilisearch fills the `meilisearch` service slot: a single self-contained search-engine binary,
built **from source** on Linux and macOS.

- **Selected version / tag.** Pinned stable release **`v1.49.0`** (the label users install is
  `1.49.0`; the exact upstream git tag is `v1.49.0`). Any current stable tag can be built by
  dispatching with a new `version`/`upstream` — the recipe accepts the tag with or without the
  leading `v`. Keep the `version` label equal to the numeric release so it matches the version
  embedded in the artifact filename (the daemon and `services.json` require that exact match).
- **Community Edition provenance.** Meilisearch dual-licenses its tree `MIT AND BUSL-1.1`: the
  Enterprise Edition parts are gated behind the `enterprise` cargo feature and licensed
  BUSL-1.1; everything else is MIT. The build enables **only default features** (never
  `--features enterprise` / `--all-features`), so the EE code is compiled out and the artifact is
  the **MIT-licensed Community Edition** — the same build as upstream's `meilisearch-*` release
  binaries (not their `meilisearch-enterprise-*` ones). The tarball ships `LICENSE` (the upstream
  `MIT AND BUSL-1.1` SPDX explainer) and `LICENSE-MIT` (the operative MIT text); `LICENSE-EE` is
  intentionally **not** shipped because no Business-Source-licensed code is present in a CE build.
- **Build prerequisites / toolchain.** A Rust toolchain reachable as `cargo` (GitHub runners
  preinstall rustup+cargo; a bare host just needs rustup on `PATH`). The exact compiler is **not**
  pinned here — the Meilisearch source tree carries a `rust-toolchain.toml` (channel `1.91.1` for
  `v1.49.0`) that rustup honors automatically, so the right toolchain is fetched at build time.
  Dependencies are resolved reproducibly from the committed `Cargo.lock` via `--locked`; the build
  is `cargo build --release --locked -p meilisearch`.
- **Artifact layout / filename.** `meilisearch-<version>-<os>-<arch>.tar.gz`, whose root holds
  `bin/meilisearch` (executable) plus `LICENSE` + `LICENSE-MIT`. No `lib/` (the binary is
  self-contained), no top-level version directory. Example verbose listing:

  ```
  ./LICENSE
  ./LICENSE-MIT
  ./bin/meilisearch          (0755, executable)
  ```
- **Smoke-test contract.** Every published platform is smoke-tested on its native runner against
  the *final packaged* binary (extract → run, never the pre-package build output): extract to a
  throwaway dir, assert `bin/meilisearch` exists and is executable, start it on an unused loopback
  port with a temporary db path
  (`bin/meilisearch --http-addr 127.0.0.1:<port> --db-path <tmp> --env development --no-analytics`),
  then poll `GET http://127.0.0.1:<port>/health` (bounded, ~30s) until it returns **HTTP 200** with
  a body containing **`{"status":"available"}`**. Startup logs are captured on failure; the process
  is always terminated/reaped and the temp data removed. A platform is added to `services.json` /
  published **only** if this passes.
- **How `services.json` is generated.** Identical to every other service: the workflow derives the
  manifest purely from the release's live `*.tar.gz` asset filenames (`gen-manifest.sh`), so a
  meilisearch entry appears iff its artifacts were built, smoke-tested, and uploaded. See
  [Listing](#the-two-on-demand-flows) / the [Artifact contract](#artifact-contract-the-binding-interface--do-not-drift).
- **Add / update a version.** Dispatch the release workflow:

  ```sh
  gh workflow run release.yml \
    -f action=build -f service=meilisearch -f version=1.49.0 -f upstream=v1.49.0
  #  → builds linux-x86_64, linux-aarch64, macos-aarch64, windows-x86_64; uploads
  #    meilisearch-1.49.0-*.tar.gz; refreshes services.json. Repoint the label by rebuilding the
  #    same version with a new tag. Add `-f targets=windows-x86_64` to rebuild just one platform.
  gh workflow run release.yml -f action=remove -f service=meilisearch -f version=1.49.0
  ```
- **Windows.** Built from the same Rust source on the `windows-latest` runner (emitting
  `bin/meilisearch.exe`); Rust's MSVC target dynamically links the VC++ runtime, so those DLLs are
  bundled into `bin/` and pass `windows_self_contain_gate`, matching every other Windows artifact.
- **Intentionally omitted platform.**
  - **`macos-x86_64`** — no Intel macOS runner exists (GitHub retired `macos-13` in Dec 2025), the
    same floor as every other service here.

  Building meilisearch from source on the same native runners as Valkey/Postgres neither raises the
  glibc floor nor the macOS deployment target.

## Bundled extensions

The `postgres` artifact ships a curated set of PostgreSQL extensions so common dev workflows
work out of the box (`CREATE EXTENSION <name>`), with no daemon or install changes — the
extensions live under the `lib/`+`share/` trees the artifact already ships and are made
relocatable with everything else.

- **contrib (Linux/macOS, built from the same source tree):** `pg_stat_statements`, `pg_trgm`,
  `citext`, `unaccent`, `hstore`, `ltree`, `btree_gin`, `btree_gist`, `fuzzystrmatch`,
  `tablefunc`, `intarray`, `cube`, `earthdistance`, `postgres_fdw`, `dblink`, `pageinspect`,
  `amcheck`, `pgstattuple`, `pg_buffercache`. All are core PostgreSQL License (covered by the
  shipped `LICENSE`). On Windows these ride the EDB zip verbatim.
- **pgvector (Linux/macOS only):** built out-of-tree against the same server, pinned to
  `PGVECTOR_UPSTREAM` (default `v0.8.5`), compiled with `OPTFLAGS=""` so the CI-built `.so`
  has no `-march=native` and runs on any CPU of the target arch. Ships its own notice as
  `LICENSE-pgvector`. Not bundled on Windows (absent from the EDB zip; a native MSVC build is
  a separate effort).

- **TimescaleDB (Linux/macOS `full` variant only):** Community edition (TSL — hypertables plus
  compression, continuous aggregates, retention/reorder policies), built with CMake against the same
  server, pinned to `TIMESCALEDB_UPSTREAM` (default `2.28.3`), telemetry and OpenSSL compiled out
  (`-DUSE_TELEMETRY=OFF -DUSE_OPENSSL=OFF`) so it phones home to nothing and self-contains like the
  contrib `.so`s. Only bundled for **PostgreSQL 15–18** (upstream cmake supports no other majors); on
  any other major the step is **skipped** and `full` still builds without it. Ships its notices as
  `LICENSE-timescaledb` (dual-license explainer), `LICENSE-timescaledb-apache`, `LICENSE-timescaledb-tsl`,
  and `NOTICE-timescaledb`. Not bundled on Windows (upstream ships a `setup.exe` wizard, not a
  file-drop — deferred, like pgvector). **Requires `shared_preload_libraries = 'timescaledb'`** at
  runtime (see [Variants](#variants)).

Not in the lean base (they need OpenSSL/libxml/uuid or heavy GPL/TSL deps): `pgcrypto`, `uuid-ossp`,
`sslinfo`, `xml2`, **PostGIS**, and **TimescaleDB** — these ship in the **`full` variant** instead
(see below).
Every build **smoke-tests** each bundled extension by creating it and calling a function (forcing
the `.so` to load post-relocation) before publishing.

## Variants

Some builds ship in more than one flavour. A variant is a **label suffix**:
`<version>-<variant>` (e.g. `17-full`), which the daemon treats as an ordinary opaque version —
`yerd service install postgres 17-full`. No daemon awareness or Yerd release is needed for the
label/install path; it rides the existing "filenames are the source of truth" design.

**Convention:** always `<version>-<variant>`, `variant` ∈ lowercase `[a-z0-9]+`. The base (no
suffix) is the lean, 100%-permissive default. Reserved variant names:

| variant | service | contents | license |
|---------|---------|----------|---------|
| _(none)_ | all | lean base (permissive) | per-service base |
| `full` | `postgres` | base + pgvector (unix) + **PostGIS w/ raster** + **TimescaleDB** (unix, PG 15–18) + all now-buildable contrib (`pgcrypto`, `uuid-ossp`, `sslinfo`, `xml2`) | **GPLv2** (PostGIS) + LGPL-2.1 (GEOS) + **TSL** (TimescaleDB) + permissive |

One `service=postgres` dispatch builds **both** `postgres-<ver>` and `postgres-<ver>-full`.
`action=remove version=<ver>` removes both. Key properties:

- **GPL/TSL are confined to `full`.** The default `postgres` artifact stays 100% PostgreSQL License;
  only `full` carries GPLv2 (PostGIS) / LGPL-2.1 (GEOS) / TSL (TimescaleDB). PostgreSQL core is
  unaffected (each is a runtime-loaded module + mere aggregation in the tarball); each component's
  notice ships inside the `full` tarball (`LICENSE-postgis`, `LICENSE-geos`, `LICENSE-proj`,
  `LICENSE-gdal`, `LICENSE-timescaledb*`, …). The **Timescale License** is source-available and
  permits redistributing binaries in a tool like this; it only forbids offering the software as a
  managed database-as-a-service — not applicable to local `yerd` installs.
- **TimescaleDB needs a preload.** `CREATE EXTENSION timescaledb` fails unless
  `shared_preload_libraries = 'timescaledb'` is set at postmaster start. The launcher (yerd daemon)
  must add it to `postgresql.conf` for `full` installs — a **prerequisite for using `full`'s
  TimescaleDB** (a required follow-up in the daemon repo; the label/install path itself needs no
  daemon change). The build's smoke test starts the server with
  `-c shared_preload_libraries=timescaledb` and exercises a hypertable + compression policy, so it
  validates the exact preload the daemon will configure. Bundled only for PostgreSQL 15–18; other
  majors skip it. Build against **17.2+/16.6+** (avoid the ABI-broken 17.1/16.5/15.9 minors).
- **Datadirs are isolated.** `17` and `17-full` are distinct labels → distinct installs + datadirs.
  A datadir with PostGIS objects can only be opened by the `full` build; base→full is safe (full is
  a superset), full→base is not once PostGIS is used. Do not point one variant's binaries at the
  other's datadir.
- **Runtime data (PostGIS reprojection/raster):** the `full` artifact bundles PROJ's `proj.db` +
  GDAL data under `share/`, but PROJ/GDAL locate them via `PROJ_DATA`/`GDAL_DATA`. The launcher
  (yerd daemon) must export those for `full` installs — a **prerequisite for publishing `full`**
  (the label/install path needs no daemon change; reprojection/raster runtime does). The build's
  smoke test exports them at the bundled dirs and runs `ST_Transform`, so it validates the exact
  bundle+env the daemon will use.
- **Windows `full`** overlays the prebuilt OSGeo PostGIS bundle onto the EDB tree (pin
  `POSTGIS_WIN_UPSTREAM`); it has no pgvector and no TimescaleDB (both absent from the file-drop
  path — TimescaleDB ships a `setup.exe` wizard upstream). Unix `full` is source-built
  (`POSTGIS_UPSTREAM` default `3.6.0`, GEOS/PROJ/GDAL from the platform package manager, the whole
  geo chain bundled + relocated + gated; TimescaleDB `TIMESCALEDB_UPSTREAM` default `2.28.3`).

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
│   ├── pgvector-PostgreSQL-License.txt  # bundled with postgres on Linux/macOS
│   ├── mariadb-GPLv2.txt
│   ├── postgis-GPLv2.txt               # postgres `full` variant (GPLv2)
│   ├── geos-LGPL-2.1.txt               #   "   (LGPL-2.1)
│   ├── proj-X11.txt                    #   "   (X/MIT)
│   ├── gdal-MIT.txt                    #   "   (MIT)
│   ├── json-c-MIT.txt                  #   "   (MIT)
│   ├── protobuf-c-BSD-2-Clause.txt     #   "   (BSD-2)
│   ├── meilisearch-MIT.txt             # Meilisearch Community Edition (MIT)
│   └── versitygw-Apache-2.0.txt        # versitygw S3 gateway (Apache-2.0; backfill only)
│                                       # TimescaleDB notices are copied from its source tree at
│                                       # build time (LICENSE-timescaledb*, NOTICE-timescaledb)
├── scripts/
│   ├── lib.sh                      # os/arch tokens, canonical_service, artifact_filename, pack_stage, macos_make_relocatable, …
│   ├── build-service.sh            # build/repackage ONE (service,version,upstream) for the host platform
│   ├── smoke-test.sh               # extract a built artifact + run the server (SELECT 1 / PING / GET /health) — each build leg, pre-publish
│   ├── gen-manifest.sh             # *.tar.gz names (stdin) → services.json (the daemon's listing)
│   ├── bunny-put.sh                # PUT one file to the Bunny storage zone + verify it landed
│   ├── bunny-list.sh               # recursively list a zone prefix → [{path,size,checksum}]
│   ├── bunny-delete.sh             # DELETE one object; refuses any path outside services/
│   ├── bunny-purge.sh              # purge pull-zone URLs from the edge cache (rides 429 throttling)
│   ├── cdn-reconcile-plan.sh       # two JSON snapshots → upload/update/delete plan (no network)
│   └── test.sh                     # dependency-free unit tests (naming, archive layout, manifest merge, meilisearch smoke harness, CDN reconcile + delete guard)
└── .github/workflows/
    ├── release.yml                 # workflow_dispatch: ensure-release → build (build+smoke) → finalize → cdn-mirror
    └── cdn-sync.yml                # workflow_dispatch: reconcile the CDN against the live release (dry run by default)
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

**Every service now covers all four targets** (`linux-x86_64`, `linux-aarch64`, `macos-aarch64`,
`windows-x86_64`); `macos-x86_64` is the only universally-omitted target (no Intel runner). The
last two Windows gaps were closed by building `meilisearch` from Rust source on `windows-latest`
(emitting `meilisearch.exe`) and repackaging `versitygw`'s official Windows binary — so `set-matrix`
no longer drops any per-service Windows leg. `meilisearch`/`versitygw` build from source / repackage
on the same native runners, so no glibc floor or macOS deployment target is silently raised.

**`versitygw` on Windows** ships a working exe but its posix backend can't use NTFS for S3 metadata
(no extended attributes); it must be launched with `--sidecar <dir>` (or `--nometa`). This is a
**daemon-side runtime prerequisite** for Windows versitygw installs — the label/install path itself
needs no change, but the launcher must add `--sidecar` on Windows. The build's smoke test starts it
exactly that way, so it validates the invocation the daemon will use.
