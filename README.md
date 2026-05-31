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
| `mysql`    | Oracle MySQL (GPLv2) | 2 | ⏳ stub |
| `postgres` | PostgreSQL (PostgreSQL License) | 2 | ⏳ stub |
| `mariadb`  | MariaDB (GPLv2) | 3 | ⏳ stub |

The `redis` slot ships **[Valkey](https://github.com/valkey-io/valkey)** (Linux Foundation,
BSD-3, wire-compatible) because Redis 7.4+ is SSPL/RSALv2 (redistribution-restricted).
`service=valkey` is accepted as a friendly alias for the `redis` slot; the published artifact
is always named `redis-…`.

## The two on-demand flows

Both are one `gh workflow run` (or the Actions **Run workflow** button, or an agent):

```sh
# Release a NEW version — e.g. Valkey 8.1 lands upstream:
gh workflow run release.yml \
  -f action=build -f service=valkey -f version=8.1 -f upstream=8.1.0
#  → builds 4 platforms, uploads redis-8.1-*.tar.gz, refreshes index.html + services.json.
#    Everything else (redis 8, mysql, …) is untouched.

# EXCLUDE a bad version — e.g. pull Valkey 8.0:
gh workflow run release.yml \
  -f action=remove -f service=valkey -f version=8.0
#  → deletes redis-8.0-*.tar.gz, refreshes index.html + services.json so 8.0 disappears.
#    (upstream is ignored for remove.) Copies already installed on user disks keep working.
```

- `version` is the **label** users type (`8`, `8.4`); `upstream` is the **exact source tag**
  to build (`8.4.0`). A label like `8` can be repointed to a newer upstream by rebuilding with
  the same `version` and a new `upstream` (the asset is replaced via `--clobber`).
- Removal deletes a version's assets and refreshes the listing; it does not reach back to
  already-installed copies.

## Artifact contract (the binding interface — do not drift)

This is the entire coupling with `forjedio/yerd`. The consumer there
(`crates/yerd-services/src/release.rs` + `bin/yerdd/src/service_install.rs`) parses exactly
this shape.

**Filename:** `<service-id>-<version>-<os>-<arch>.tar.gz`
- `service-id ∈ redis | mysql | mariadb | postgres` (the `redis` slot is served by Valkey)
- `os ∈ linux | macos`, `arch ∈ x86_64 | aarch64`
- examples: `redis-8-linux-x86_64.tar.gz`, `postgres-16-macos-aarch64.tar.gz`

**Archive:** a gzip tar whose **root** holds a `bin/` directory with the server executable
(and client/init tools where noted). No absolute/`..` members. Executable bit preserved.
Binaries must be **relocatable** — the daemon runs them from an arbitrary per-user data dir
and points data/socket/port at user paths via config, never compiled-in defaults. Required
`bin/` per service:

| service    | server binary | also include |
|------------|---------------|--------------|
| `redis`    | `valkey-server` | `valkey-cli` |
| `mysql`    | `mysqld` | `mysql`, `mysqld_safe` |
| `mariadb`  | `mariadbd` | `mariadb`, `mariadb-install-db` |
| `postgres` | `postgres` | `initdb`, `pg_ctl`, `psql`, `createdb` |

**Listing (`index.html`):** GitHub Releases has no directory autoindex, so the workflow
publishes a generated `index.html` (one `<a href>` per artifact) as a release asset. The
daemon fetches it as the listing. Always regenerated from the release's live asset set.

**URLs the consumer hard-codes:**
```
SERVICES_BASE_URL = https://github.com/forjedio/yerd-services/releases/download/services
listing           = {SERVICES_BASE_URL}/index.html
artifact          = {SERVICES_BASE_URL}/<filename>
```
Integrity is TLS-only today (no checksum pinning), matching the PHP path.

### `services.json` (additive — not part of the frozen contract)

Alongside `index.html` the workflow also publishes a machine-readable
[`services.json`](https://github.com/forjedio/yerd-services/releases/download/services/services.json)
for agents/tooling to parse the available versions. It is derived from the same live asset
set, so it can't drift. **The daemon still parses `index.html`** — `services.json` is purely
additive and nothing in `forjedio/yerd` depends on it.

```json
{ "schema": 1,
  "services": {
    "redis": { "versions": [
      { "version": "8", "platforms": ["linux-aarch64","linux-x86_64","macos-aarch64","macos-x86_64"] }
    ] } } }
```

## Hosting model

A single **rolling release tagged `services`** holds every artifact + the listing as a flat
bag of independent assets. Each `(service, version, platform)` is one asset; multiple
versions coexist. Adding/rebuilding a `(service, version)` uploads its per-platform assets
with `--clobber` (replacing only same-named assets) — everything else is untouched. This is
within GitHub's acceptable-use posture: artifacts are downloaded once per install and cached
on the user's disk, so traffic scales with installs, not usage. If volume ever warranted it,
the escape hatch is to move `SERVICES_BASE_URL` to a CDN while keeping this artifact contract.

## Provenance

| service | version | upstream project | exact tag | build flags |
|---------|---------|------------------|-----------|-------------|
| `redis` | _(label)_ | [Valkey](https://github.com/valkey-io/valkey) | _`<upstream>` per dispatch_ | `make -j BUILD_TLS=no` |

Surface names with trademark care in the UI: **"Redis (Valkey)"** (BSD-3),
"MySQL (Oracle)" / MariaDB (GPLv2, preserve notices), PostgreSQL (permissive). Upstream
license texts live in [`LICENSES/`](LICENSES/).

## Repo layout

```
yerd-services/
├── README.md
├── LICENSES/                       # upstream license texts (BSD/GPL/PostgreSQL)
│   └── valkey-BSD-3-Clause.txt
├── scripts/
│   ├── lib.sh                      # os/arch tokens, canonical_service, artifact_filename, pack_stage, …
│   ├── build-service.sh            # build/repackage ONE (service,version,upstream) for the host platform
│   ├── gen-index.sh                # *.tar.gz names (stdin) → index.html (daemon's listing)
│   └── gen-manifest.sh             # *.tar.gz names (stdin) → services.json (additive)
└── .github/workflows/
    └── release.yml                 # workflow_dispatch: ensure-release → build matrix → finalize
```

## Platform matrix

| target          | runner            |
|-----------------|-------------------|
| `linux-x86_64`  | `ubuntu-latest`   |
| `linux-aarch64` | `ubuntu-24.04-arm`|
| `macos-x86_64`  | `macos-13`        |
| `macos-aarch64` | `macos-14`        |

(Windows is out of scope — mac/Linux-first, matching the main repo.)
