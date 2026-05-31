#!/usr/bin/env bash
#
# build-service.sh <service> <version> <upstream>
#
# Build (or repackage) ONE (service, version) for the *host* platform and emit
# dist/<service>-<version>-<os>-<arch>.tar.gz in the uniform shape the yerd daemon
# expects (see the "Artifact contract" section of README.md). Run once per platform by the CI
# matrix; also runnable locally to smoke-test a recipe.
#
#   service   valkey|redis|mysql|mariadb|postgres  (valkey is an alias for redis)
#   version   the published label users install     (e.g. 8, 8.4, 16)
#   upstream  the exact upstream source tag/version to build from (e.g. 9.1.0)

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

if [[ $# -ne 3 ]]; then
  echo "usage: build-service.sh <service> <version> <upstream>" >&2
  exit 2
fi

service="$(canonical_service "$1")"
version="$2"
upstream="$3"
OS="$(host_os)"
ARCH="$(host_arch)"

repo_root="$(cd "$here/.." && pwd)"
dist="$repo_root/dist"
out="$dist/$(artifact_filename "$service" "$version" "$OS" "$ARCH")"

stage="$(make_stage)"
work="$(mktemp -d "${TMPDIR:-/tmp}/yerd-build.XXXXXX")"
trap 'rm -rf "$stage" "$work"' EXIT

echo ">> building service=$service version=$version upstream=$upstream os=$OS arch=$ARCH"

case "$service" in
  redis)
    # redis slot -> Valkey, built from source. BSD-3, relocatable,
    # no exotic deps; ~30s. BUILD_TLS=no keeps it dependency-free.
    curl -fsSL -o "$work/src.tgz" \
      "https://github.com/valkey-io/valkey/archive/refs/tags/${upstream}.tar.gz"
    mkdir -p "$work/src"
    tar xzf "$work/src.tgz" -C "$work/src" --strip-components 1
    jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
    make -C "$work/src" -j"$jobs" BUILD_TLS=no
    # Valkey emits its binaries into its own src/ subdir, so they live at
    # "$work/src/src/valkey-{server,cli}" (the doubled src/ is intentional).
    cp "$work/src/src/valkey-server" "$work/src/src/valkey-cli" "$stage/bin/"
    require_files "$stage" bin/valkey-server bin/valkey-cli
    ;;

  mysql)
    # Phase 2: repackage Oracle's generic binary tarballs ->
    # bin/{mysqld,mysql,mysqld_safe} (+ required lib/). Not yet implemented.
    echo "build-service.sh: mysql not yet implemented (Phase 2)" >&2
    exit 1
    ;;

  postgres)
    # Phase 2: repackage a full EDB build with
    # bin/{postgres,initdb,pg_ctl,psql,createdb}. Not yet implemented.
    echo "build-service.sh: postgres not yet implemented (Phase 2)" >&2
    exit 1
    ;;

  mariadb)
    # Phase 3: repackage Linux x86_64; build-from-source for macOS +
    # Linux arm64 (CMake). Highest-effort engine. Not yet implemented.
    echo "build-service.sh: mariadb not yet implemented (Phase 3)" >&2
    exit 1
    ;;

  *)
    echo "build-service.sh: unhandled service '$service'" >&2
    exit 1
    ;;
esac

pack_stage "$stage" "$out"
echo ">> wrote $out"
