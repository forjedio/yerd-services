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
  if [[ -f "$data/postmaster.pid" ]]; then
    "$extract/bin/pg_ctl" -D "$data" -m immediate stop >/dev/null 2>&1 || true
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
    # mariadbd exits cleanly on the trap's SIGTERM; no client shutdown needed.
    ;;

  postgres)
    "$bin/initdb" -A trust -U postgres --locale=C -D "$data" >/dev/null
    # -k sets the socket DIRECTORY; psql -h must be that same directory.
    "$bin/pg_ctl" -D "$data" -o "-k $sockdir -p $port" -w -t 60 start
    out="$("$bin/psql" -h "$sockdir" -p "$port" -U postgres -tAc 'SELECT 1')"
    "$bin/pg_ctl" -D "$data" -m fast stop
    [[ "$out" == "1" ]] || { echo "postgres: SELECT 1 returned '$out'" >&2; exit 1; }
    ;;

  *)
    echo "smoke-test.sh: unhandled service '$service'" >&2
    exit 1
    ;;
esac

echo ">> smoke test OK: $service"
