#!/usr/bin/env bash
#
# smoke-test.sh <service> <tarball>
#
# Extract a packed artifact to a throwaway dir (proving relocatability — the binary
# runs from an arbitrary location, never the build tree), start the server, and run a
# trivial query. Non-zero exit on any failure, so a build leg that can't run its own
# artifact fails before publishing.
#
# Used by the CI build leg (after build-service.sh, before upload-artifact) and
# locally. Covers redis/valkey, mysql, postgres.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

if [[ $# -ne 2 ]]; then
  echo "usage: smoke-test.sh <service> <tarball>" >&2
  exit 2
fi
# Canonicalize first so service=valkey maps to the redis branch (do-not-regress).
service="$(canonical_service "$1")"
tarball="$2"
OS="$(host_os)"   # smoke-test branches on this; lib.sh defines host_os
[[ -f "$tarball" ]] || { echo "smoke-test.sh: tarball not found: $tarball" >&2; exit 2; }

# Extract dir can be deep; the unix socket must NOT live here. macOS caps
# sockaddr_un.sun_path at 104 bytes and runner temp dirs are deep, so keep the socket
# at a short /tmp path (postgres also appends .s.PGSQL.<port> to its -k dir).
extract="$(mktemp -d "${TMPDIR:-/tmp}/yerd-smoke.XXXXXX")"
sockdir="$(mktemp -d /tmp/yerd-sk.XXXXXX)"
data="$extract/data"
srv_pid=""
cleanup() {
  if [[ -n "$srv_pid" ]]; then
    kill "$srv_pid" 2>/dev/null || true
    wait "$srv_pid" 2>/dev/null || true
  fi
  # postgres runs under its own postmaster (not $srv_pid) — stop it if still up.
  # (Git Bash auto-appends .exe, so this resolves pg_ctl.exe on Windows too.)
  if [[ -f "$data/postmaster.pid" ]]; then
    "$extract/bin/pg_ctl" -D "$data" -m immediate stop >/dev/null 2>&1 || true
  fi
  # Windows last-resort reaper: kill "$srv_pid" targets the MSYS pid, which may not reap
  # the native .exe (or its workers). Clean shutdown in each branch is primary; this only
  # fires in CI (avoid taskkilling a dev box's own engines by image name).
  if [[ "$OS" == windows && -n "${GITHUB_ACTIONS:-}${CI:-}" ]]; then
    local img
    for img in redis-server.exe mysqld.exe mariadbd.exe postgres.exe; do
      taskkill //IM "$img" //F >/dev/null 2>&1 || true
    done
  fi
  rm -rf "$extract" "$sockdir"
}
trap cleanup EXIT

tar xf "$tarball" -C "$extract"
bin="$extract/bin"
port=$(( (RANDOM % 20000) + 20000 ))

# wait_for <seconds> <cmd...> — poll until cmd succeeds or timeout.
wait_for() {
  local timeout="$1"; shift
  local i
  for (( i=0; i<timeout*2; i++ )); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  echo "smoke-test: timed out waiting for: $*" >&2
  return 1
}

echo ">> smoke-testing $service from $tarball"

if [[ "$OS" == windows ]]; then
  # Windows: no unix sockets — everything over TCP loopback. Binaries are .exe; the
  # redis slot ships the real REDIS port (redis-server.exe / redis-cli.exe), not Valkey.
  case "$service" in
    redis)
      mkdir -p "$data"
      "$bin/redis-server.exe" --port "$port" --dir "$data" --save '' --appendonly no &
      srv_pid=$!
      wait_for 15 "$bin/redis-cli.exe" -p "$port" ping
      [[ "$("$bin/redis-cli.exe" -p "$port" ping)" == "PONG" ]] || { echo "redis: no PONG" >&2; exit 1; }
      "$bin/redis-cli.exe" -p "$port" set yerd ok >/dev/null
      [[ "$("$bin/redis-cli.exe" -p "$port" get yerd)" == "ok" ]] || { echo "redis: SET/GET failed" >&2; exit 1; }
      "$bin/redis-cli.exe" -p "$port" shutdown nosave 2>/dev/null || true
      ;;

    mysql)
      "$bin/mysqld.exe" --no-defaults --initialize-insecure \
        --basedir="$extract" --datadir="$data"
      "$bin/mysqld.exe" --no-defaults --basedir="$extract" --datadir="$data" \
        --port="$port" --skip-networking=0 --mysqlx=0 &
      srv_pid=$!
      wait_for 60 "$bin/mysql.exe" --protocol=TCP -h 127.0.0.1 -P "$port" -uroot -e 'SELECT 1'
      out="$("$bin/mysql.exe" --protocol=TCP -h 127.0.0.1 -P "$port" -uroot -N -e 'SELECT 1')"
      [[ "$out" == "1" ]] || { echo "mysql: SELECT 1 returned '$out'" >&2; exit 1; }
      "$bin/mysql.exe" --protocol=TCP -h 127.0.0.1 -P "$port" -uroot -e 'CREATE DATABASE bk; CREATE TABLE bk.t(id INT); INSERT INTO bk.t VALUES(42);'
      "$bin/mysqldump.exe" --no-tablespaces --single-transaction --set-gtid-purged=OFF --protocol=TCP -h 127.0.0.1 -P "$port" -uroot bk > "$extract/dump.sql"
      "$bin/mysql.exe" --protocol=TCP -h 127.0.0.1 -P "$port" -uroot -e 'DROP DATABASE bk; CREATE DATABASE bk;'
      "$bin/mysql.exe" --protocol=TCP -h 127.0.0.1 -P "$port" -uroot bk < "$extract/dump.sql"
      rt="$("$bin/mysql.exe" --protocol=TCP -h 127.0.0.1 -P "$port" -uroot -N -e 'SELECT id FROM bk.t')"
      [[ "$rt" == "42" ]] || { echo "mysql: backup/restore roundtrip got '$rt'" >&2; exit 1; }
      "$bin/mysql.exe" --protocol=TCP -h 127.0.0.1 -P "$port" -uroot -e 'SHUTDOWN'
      ;;

    mariadb)
      init=""
      for c in mariadb-install-db.exe mysql_install_db.exe; do
        [[ -e "$bin/$c" ]] && { init="$c"; break; }
      done
      [[ -n "$init" ]] || { echo "mariadb(windows): no init tool in artifact" >&2; exit 1; }
      # Windows install-db: passwordless root by default; pass basedir+datadir.
      "$bin/$init" --no-defaults --datadir="$data" >/dev/null 2>&1 \
        || "$bin/$init" --datadir="$data" >/dev/null
      "$bin/mariadbd.exe" --no-defaults --basedir="$extract" --datadir="$data" \
        --port="$port" --skip-networking=0 &
      srv_pid=$!
      wait_for 60 "$bin/mariadb.exe" --protocol=TCP -h 127.0.0.1 -P "$port" -uroot -e 'SELECT 1'
      out="$("$bin/mariadb.exe" --protocol=TCP -h 127.0.0.1 -P "$port" -uroot -N -e 'SELECT 1')"
      [[ "$out" == "1" ]] || { echo "mariadb: SELECT 1 returned '$out'" >&2; exit 1; }
      "$bin/mariadb.exe" --protocol=TCP -h 127.0.0.1 -P "$port" -uroot -e 'CREATE DATABASE bk; CREATE TABLE bk.t(id INT); INSERT INTO bk.t VALUES(42);'
      "$bin/mariadb-dump.exe" --no-tablespaces --single-transaction --protocol=TCP -h 127.0.0.1 -P "$port" -uroot bk > "$extract/dump.sql"
      "$bin/mariadb.exe" --protocol=TCP -h 127.0.0.1 -P "$port" -uroot -e 'DROP DATABASE bk; CREATE DATABASE bk;'
      "$bin/mariadb.exe" --protocol=TCP -h 127.0.0.1 -P "$port" -uroot bk < "$extract/dump.sql"
      rt="$("$bin/mariadb.exe" --protocol=TCP -h 127.0.0.1 -P "$port" -uroot -N -e 'SELECT id FROM bk.t')"
      [[ "$rt" == "42" ]] || { echo "mariadb: backup/restore roundtrip got '$rt'" >&2; exit 1; }
      "$bin/mariadb.exe" --protocol=TCP -h 127.0.0.1 -P "$port" -uroot -e 'SHUTDOWN' 2>/dev/null || true
      ;;

    postgres)
      # `full` variant? Point PROJ/GDAL at the OSGeo bundle's data (under share/contrib/…) BEFORE
      # the server starts — probe rather than hardcode. (No system geo stack on the Windows runner,
      # so this smoke IS the genuine load-test for the overlaid PostGIS/geo DLLs.)
      pg_full=""
      if [[ -n "$(find "$extract/share" -name postgis.control -print -quit)" ]]; then
        pg_full=1
        pdb="$(find "$extract" -name proj.db -print -quit)"
        [[ -n "$pdb" ]] && { PROJ_DATA="$(dirname "$pdb")"; export PROJ_DATA; }
        gdd="$(find "$extract" -name gdalvrt.xsd -print -quit)"
        [[ -n "$gdd" ]] && { GDAL_DATA="$(dirname "$gdd")"; export GDAL_DATA; }
      fi
      # initdb/postgres auto-drop the runner's admin token on Windows; pg_ctl is the path
      # that performs the de-elevation. -A trust covers local + host(127.0.0.1) auth.
      "$bin/initdb.exe" -A trust -U postgres --locale=C -D "$data" >/dev/null
      "$bin/pg_ctl.exe" -D "$data" -o "-p $port" -w -t 60 start
      out="$("$bin/psql.exe" -h 127.0.0.1 -p "$port" -U postgres -tAc 'SELECT 1')"
      [[ "$out" == "1" ]] || { echo "postgres: SELECT 1 returned '$out'" >&2; exit 1; }
      # extensions: EDB's zip already bundles contrib (shipped via cp -R lib/share), so verify
      # they load. No pgvector on Windows (not in the EDB zip). postgres_fdw/dblink dlopen libpq.
      "$bin/psql.exe" -h 127.0.0.1 -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_trgm;      SELECT similarity('cat','cats');
CREATE EXTENSION IF NOT EXISTS citext;       SELECT 'AbC'::citext = 'abc'::citext;
CREATE EXTENSION IF NOT EXISTS hstore;       SELECT ('a=>1'::hstore)->'a';
CREATE EXTENSION IF NOT EXISTS unaccent;     SELECT unaccent('effect');
CREATE EXTENSION IF NOT EXISTS ltree;        SELECT 'a.b.c'::ltree;
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE EXTENSION IF NOT EXISTS dblink;
SQL
      # full variant: verify the overlaid PostGIS/geo DLLs load + find their bundled data.
      if [[ -n "$pg_full" ]]; then
        "$bin/psql.exe" -h 127.0.0.1 -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE EXTENSION postgis;         SELECT postgis_full_version();
SELECT ST_AsText(ST_Transform(ST_SetSRID(ST_MakePoint(0,0),4326),3857));
CREATE EXTENSION postgis_raster;
SELECT ST_SRID(ST_Transform(ST_SetSRID(ST_AddBand(ST_MakeEmptyRaster(2,2,0,0,1),'8BUI'),4326),3857));
CREATE EXTENSION pgcrypto;        SELECT digest('x','sha256');
CREATE EXTENSION "uuid-ossp";     SELECT uuid_generate_v4();
SQL
      fi
      "$bin/createdb.exe" -h 127.0.0.1 -p "$port" -U postgres bk
      "$bin/psql.exe" -h 127.0.0.1 -p "$port" -U postgres -d bk -c 'CREATE TABLE t(id int); INSERT INTO t VALUES(42);' >/dev/null
      "$bin/pg_dump.exe" -Fc -h 127.0.0.1 -p "$port" -U postgres bk -f "$extract/d.dump"
      "$bin/psql.exe" -h 127.0.0.1 -p "$port" -U postgres -d postgres -c 'DROP DATABASE bk' -c 'CREATE DATABASE bk' >/dev/null
      "$bin/pg_restore.exe" -h 127.0.0.1 -p "$port" -U postgres -d bk "$extract/d.dump" >/dev/null
      rt="$("$bin/psql.exe" -h 127.0.0.1 -p "$port" -U postgres -d bk -tAc 'SELECT id FROM t')"
      [[ "$rt" == "42" ]] || { echo "postgres: backup/restore roundtrip got '$rt'" >&2; exit 1; }
      "$bin/pg_dumpall.exe" --version >/dev/null
      "$bin/pg_ctl.exe" -D "$data" -m fast stop
      ;;

    *)
      echo "smoke-test.sh: unhandled service '$service' (windows)" >&2
      exit 1
      ;;
  esac
  echo ">> smoke test OK: $service"
  exit 0
fi

case "$service" in
  redis)
    mkdir -p "$data"
    "$bin/valkey-server" --port "$port" --dir "$data" --daemonize no \
      --save '' --appendonly no &
    srv_pid=$!
    wait_for 15 "$bin/valkey-cli" -p "$port" ping
    [[ "$("$bin/valkey-cli" -p "$port" ping)" == "PONG" ]] || { echo "redis: no PONG" >&2; exit 1; }
    "$bin/valkey-cli" -p "$port" set yerd ok >/dev/null
    [[ "$("$bin/valkey-cli" -p "$port" get yerd)" == "ok" ]] || { echo "redis: SET/GET failed" >&2; exit 1; }
    "$bin/valkey-cli" -p "$port" shutdown nosave 2>/dev/null || true
    ;;

  mysql)
    # The artifact ships only mysqld/mysql/mysqld_safe (no mysqladmin), so readiness
    # and shutdown both go through the mysql client. --mysqlx=0 avoids the X plugin's
    # fixed side socket/port.
    sock="$sockdir/m.sock"
    "$bin/mysqld" --no-defaults --initialize-insecure \
      --basedir="$extract" --datadir="$data"
    "$bin/mysqld" --no-defaults --basedir="$extract" --datadir="$data" \
      --socket="$sock" --port="$port" --skip-networking=0 --mysqlx=0 &
    srv_pid=$!
    # First start builds the data dictionary and is slow; poll a real query.
    wait_for 60 "$bin/mysql" --socket="$sock" -uroot -e 'SELECT 1'
    out="$("$bin/mysql" --socket="$sock" -uroot -N -e 'SELECT 1')"
    [[ "$out" == "1" ]] || { echo "mysql: SELECT 1 returned '$out'" >&2; exit 1; }
    # backup/restore roundtrip: dump bk, drop it, restore, verify the row survives.
    "$bin/mysql" --socket="$sock" -uroot -e 'CREATE DATABASE bk; CREATE TABLE bk.t(id INT); INSERT INTO bk.t VALUES(42);'
    "$bin/mysqldump" --no-tablespaces --single-transaction --set-gtid-purged=OFF --socket="$sock" -uroot bk > "$extract/dump.sql"
    "$bin/mysql" --socket="$sock" -uroot -e 'DROP DATABASE bk; CREATE DATABASE bk;'
    "$bin/mysql" --socket="$sock" -uroot bk < "$extract/dump.sql"
    rt="$("$bin/mysql" --socket="$sock" -uroot -N -e 'SELECT id FROM bk.t')"
    [[ "$rt" == "42" ]] || { echo "mysql: backup/restore roundtrip got '$rt'" >&2; exit 1; }
    "$bin/mysql" --socket="$sock" -uroot -e 'SHUTDOWN'
    ;;

  mariadb)
    # Init with mariadb-install-db (shells out to my_print_defaults; reads share/), passwordless
    # root via --auth-root-authentication-method=normal. Then start mariadbd and query.
    sock="$sockdir/m.sock"
    "$bin/mariadb-install-db" --no-defaults --basedir="$extract" --datadir="$data" \
      --auth-root-authentication-method=normal >/dev/null
    "$bin/mariadbd" --no-defaults --basedir="$extract" --datadir="$data" \
      --socket="$sock" --port="$port" --skip-networking=0 &
    srv_pid=$!
    wait_for 60 "$bin/mariadb" --socket="$sock" -uroot -e 'SELECT 1'
    out="$("$bin/mariadb" --socket="$sock" -uroot -N -e 'SELECT 1')"
    [[ "$out" == "1" ]] || { echo "mariadb: SELECT 1 returned '$out'" >&2; exit 1; }
    # backup/restore roundtrip: dump bk, drop it, restore, verify the row survives.
    "$bin/mariadb" --socket="$sock" -uroot -e 'CREATE DATABASE bk; CREATE TABLE bk.t(id INT); INSERT INTO bk.t VALUES(42);'
    "$bin/mariadb-dump" --no-tablespaces --single-transaction --socket="$sock" -uroot bk > "$extract/dump.sql"
    "$bin/mariadb" --socket="$sock" -uroot -e 'DROP DATABASE bk; CREATE DATABASE bk;'
    "$bin/mariadb" --socket="$sock" -uroot bk < "$extract/dump.sql"
    rt="$("$bin/mariadb" --socket="$sock" -uroot -N -e 'SELECT id FROM bk.t')"
    [[ "$rt" == "42" ]] || { echo "mariadb: backup/restore roundtrip got '$rt'" >&2; exit 1; }
    # mariadbd exits cleanly on the trap's SIGTERM; no client shutdown needed.
    ;;

  postgres)
    # `full` variant (bundles PostGIS)? Point PROJ/GDAL at the bundled data BEFORE the server
    # starts — libproj/gdal read the POSTMASTER's environment, so this must precede pg_ctl start.
    # (This simulates the yerd daemon, which exports these for full installs; probe rather than
    # hardcode, since unix nests under share/proj while the Windows OSGeo bundle differs.)
    pg_full=""
    if [[ -n "$(find "$extract/share" -name postgis.control -print -quit)" ]]; then
      pg_full=1
      pdb="$(find "$extract" -name proj.db -print -quit)"
      [[ -n "$pdb" ]] && { PROJ_DATA="$(dirname "$pdb")"; export PROJ_DATA; }
      gdd="$(find "$extract" -name gdalvrt.xsd -print -quit)"
      [[ -n "$gdd" ]] && { GDAL_DATA="$(dirname "$gdd")"; export GDAL_DATA; }
    fi
    # TimescaleDB (full/unix only) requires its loader in shared_preload_libraries at postmaster
    # start — probe independently of postgis (a bad/unloadable module then fails `pg_ctl start`,
    # which is the desired fail-closed behavior).
    ts=""
    [[ -n "$(find "$extract/share" -name timescaledb.control -print -quit)" ]] && ts=1
    "$bin/initdb" -A trust -U postgres --locale=C -D "$data" >/dev/null
    # -k sets the socket DIRECTORY; psql -h must be that same directory; -p must match the
    # server's port on every connecting call.
    pgopts="-k $sockdir -p $port"
    [[ -n "$ts" ]] && pgopts="$pgopts -c shared_preload_libraries=timescaledb"
    "$bin/pg_ctl" -D "$data" -o "$pgopts" -w -t 60 start
    out="$("$bin/psql" -h "$sockdir" -p "$port" -U postgres -tAc 'SELECT 1')"
    [[ "$out" == "1" ]] || { echo "postgres: SELECT 1 returned '$out'" >&2; exit 1; }
    # extensions: create + exercise one function each to force the .so to dlopen — proves the
    # bundled module actually relocated, not just that its control file shipped. postgres_fdw and
    # dblink dlopen the bundled libpq; pg_stat_statements is CREATE-only (querying its view would
    # need shared_preload_libraries). ON_ERROR_STOP=1 + set -e fails the leg on any error.
    "$bin/psql" -h "$sockdir" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_trgm;      SELECT similarity('cat','cats');
CREATE EXTENSION IF NOT EXISTS citext;       SELECT 'AbC'::citext = 'abc'::citext;
CREATE EXTENSION IF NOT EXISTS hstore;       SELECT ('a=>1'::hstore)->'a';
CREATE EXTENSION IF NOT EXISTS unaccent;     SELECT unaccent('effect');
CREATE EXTENSION IF NOT EXISTS ltree;        SELECT 'a.b.c'::ltree;
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE EXTENSION IF NOT EXISTS vector;       SELECT '[1,2,3]'::vector;
SQL
    # full variant: prove the GPL geo stack loads AND finds its bundled data post-relocation.
    # ST_Transform reads PROJ's proj.db; postgis_raster + a raster reprojection exercises GDAL.
    if [[ -n "$pg_full" ]]; then
      "$bin/psql" -h "$sockdir" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE EXTENSION postgis;         SELECT postgis_full_version();
SELECT ST_AsText(ST_Transform(ST_SetSRID(ST_MakePoint(0,0),4326),3857));
CREATE EXTENSION postgis_raster;
SELECT ST_SRID(ST_Transform(ST_SetSRID(ST_AddBand(ST_MakeEmptyRaster(2,2,0,0,1),'8BUI'),4326),3857));
CREATE EXTENSION pgcrypto;        SELECT digest('x','sha256');
CREATE EXTENSION "uuid-ossp";     SELECT uuid_generate_v4();
SQL
    fi
    # timescaledb (full/unix): create a hypertable + a compression policy. add_compression_policy is
    # a TSL-only function, so this forces the timescaledb-tsl-<ver>.so to dlopen — proving the TSL
    # module relocated, not just that the loader preloaded. Requires the preload set above.
    if [[ -n "$ts" ]]; then
      "$bin/psql" -h "$sockdir" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE EXTENSION timescaledb;
CREATE TABLE ts_m (t timestamptz NOT NULL, v double precision);
SELECT create_hypertable('ts_m', by_range('t'));
INSERT INTO ts_m VALUES (now(), 1), (now(), 2);
ALTER TABLE ts_m SET (timescaledb.compress);
SELECT add_compression_policy('ts_m', INTERVAL '7 days');
SELECT count(*) FROM ts_m;
SQL
    fi
    # backup/restore roundtrip: dump bk (custom format), drop+recreate from a DIFFERENT db
    # (can't drop the open one), pg_restore, verify the row survives.
    "$bin/createdb" -h "$sockdir" -p "$port" -U postgres bk
    "$bin/psql" -h "$sockdir" -p "$port" -U postgres -d bk -c 'CREATE TABLE t(id int); INSERT INTO t VALUES(42);' >/dev/null
    "$bin/pg_dump" -Fc -h "$sockdir" -p "$port" -U postgres bk -f "$extract/d.dump"
    "$bin/psql" -h "$sockdir" -p "$port" -U postgres -d postgres -c 'DROP DATABASE bk' -c 'CREATE DATABASE bk' >/dev/null
    "$bin/pg_restore" -h "$sockdir" -p "$port" -U postgres -d bk "$extract/d.dump" >/dev/null
    rt="$("$bin/psql" -h "$sockdir" -p "$port" -U postgres -d bk -tAc 'SELECT id FROM t')"
    [[ "$rt" == "42" ]] || { echo "postgres: backup/restore roundtrip got '$rt'" >&2; exit 1; }
    "$bin/pg_dumpall" --version >/dev/null   # 3rd tool: relocatable-runs sanity (shares libpq)
    "$bin/pg_ctl" -D "$data" -m fast stop
    ;;

  meilisearch)
    # Smoke the FINAL packaged binary: it must exist, be executable, start on a loopback port with a
    # throwaway db, and report healthy. Extraction above already proved relocatability (runs from an
    # arbitrary dir). Health contract: GET /health -> 200 with a body containing {"status":"available"}.
    [[ -x "$bin/meilisearch" ]] || { echo "meilisearch: bin/meilisearch missing or not executable" >&2; exit 1; }
    logf="$extract/meilisearch.log"
    healthf="$extract/health.json"
    # --env development + --no-analytics: no master key required and no telemetry. db-path lives under
    # the throwaway extract dir, so it's reaped with everything else on cleanup.
    "$bin/meilisearch" \
      --http-addr "127.0.0.1:$port" \
      --db-path "$data" \
      --env development \
      --no-analytics >"$logf" 2>&1 &
    srv_pid=$!
    # Bounded poll (default 60 tries * 0.5s = 30s; MEILI_HEALTH_TRIES overrides for tests). Bail early
    # if the server process dies. Capture the HTTP status without -f so a non-2xx still yields the code.
    tries="${MEILI_HEALTH_TRIES:-60}"
    ok=""
    for (( i=0; i<tries; i++ )); do
      code="$(curl -sS -o "$healthf" -w '%{http_code}' "http://127.0.0.1:$port/health" 2>/dev/null || echo 000)"
      if [[ "$code" == "200" ]]; then ok=1; break; fi
      kill -0 "$srv_pid" 2>/dev/null || { echo "meilisearch: server exited before becoming healthy" >&2; break; }
      sleep 0.5
    done
    if [[ -z "$ok" ]]; then
      echo "meilisearch: /health did not return HTTP 200 within ${tries} tries" >&2
      echo "---- meilisearch log ----" >&2; cat "$logf" >&2 2>/dev/null || true
      exit 1
    fi
    # Require the availability signal in the JSON body. Whitespace-tolerant so it holds regardless
    # of how the server serializes the object ({"status":"available"} or {"status": "available"}).
    if ! grep -Eq '"status"[[:space:]]*:[[:space:]]*"available"' "$healthf"; then
      echo "meilisearch: /health returned 200 but body lacks {\"status\":\"available\"}:" >&2
      cat "$healthf" >&2 2>/dev/null || true
      echo "---- meilisearch log ----" >&2; cat "$logf" >&2 2>/dev/null || true
      exit 1
    fi
    # Graceful shutdown handled by the EXIT trap (SIGTERM -> meilisearch exits cleanly, then reaped).
    ;;

  versitygw)
    # Smoke the FINAL packaged binary: it must exist, be executable, start on a loopback
    # port over a throwaway posix data root, and answer its unauthenticated health probe.
    # Extraction above already proved relocatability. versitygw refuses to start without
    # root credentials, so pass throwaway ones. Health contract: GET /health -> 200.
    [[ -x "$bin/versitygw" ]] || { echo "versitygw: bin/versitygw missing or not executable" >&2; exit 1; }
    logf="$extract/versitygw.log"
    mkdir -p "$data"
    ROOT_ACCESS_KEY=smoke ROOT_SECRET_ACCESS_KEY=smokesmokesmoke \
      "$bin/versitygw" --port "127.0.0.1:$port" --health /health posix "$data" >"$logf" 2>&1 &
    srv_pid=$!
    tries="${VGW_HEALTH_TRIES:-60}"
    ok=""
    for (( i=0; i<tries; i++ )); do
      code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/health" 2>/dev/null || echo 000)"
      if [[ "$code" == "200" ]]; then ok=1; break; fi
      kill -0 "$srv_pid" 2>/dev/null || { echo "versitygw: server exited before becoming healthy" >&2; break; }
      sleep 0.5
    done
    if [[ -z "$ok" ]]; then
      echo "versitygw: /health did not return HTTP 200 within ${tries} tries" >&2
      echo "---- versitygw log ----" >&2; cat "$logf" >&2 2>/dev/null || true
      exit 1
    fi
    # Graceful shutdown handled by the EXIT trap (SIGTERM -> versitygw exits, then reaped).
    ;;

  *)
    echo "smoke-test.sh: unhandled service '$service'" >&2
    exit 1
    ;;
esac

echo ">> smoke test OK: $service"
