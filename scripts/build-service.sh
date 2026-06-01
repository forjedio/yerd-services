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
    # Strip debug symbols on Linux (the source build leaves them in the ELF; on macOS
    # they live in a separate .dSYM we don't ship, so it's already lean).
    [[ "$OS" == linux ]] && strip "$stage/bin/valkey-server" "$stage/bin/valkey-cli" 2>/dev/null || true
    require_files "$stage" bin/valkey-server bin/valkey-cli
    ;;

  mysql)
    # Phase 2: repackage Oracle's generic binary tarballs (GPLv2, redistributable).
    # All 3 targets have generic builds; mysqld is relocatable (derives basedir from
    # the binary path, bundled libs load via @loader_path/$ORIGIN).
    url="$(mysql_generic_url "$upstream" "$OS" "$ARCH")"
    echo ">> mysql source: $url"
    fetch_to "$url" "$work/mysql.tar"
    mkdir -p "$work/m"
    # tar xf auto-detects gz/xz (macOS=.tar.gz, linux=.tar.xz); --strip-components 1
    # drops the leading mysql-<...>/ dir.
    tar xf "$work/mysql.tar" -C "$work/m" --strip-components 1
    cp "$work/m/bin/mysqld" "$work/m/bin/mysql" "$work/m/bin/mysqld_safe" "$stage/bin/"
    # Ship lib/ and share/ WHOLESALE (no cherry-pick): mysqld needs errmsg.sys +
    # charsets under share/, plugins under lib/, and --initialize-insecure may consult
    # more. Trimming is a deferred optimization, guarded by the smoke test.
    cp -R "$work/m/lib" "$stage/lib"
    cp -R "$work/m/share" "$stage/share"
    # Drop artifacts that aren't needed to RUN the server (big size wins):
    rm -f  "$stage"/lib/*.a 2>/dev/null || true            # static libs — compile-time only
    rm -rf "$stage"/lib/plugin/debug 2>/dev/null || true   # debug-instrumented plugin builds
    # Guard against an empty bundle (a dead artifact only the smoke test would catch).
    [[ -d "$stage/lib" ]] || { echo "mysql: staged lib/ missing" >&2; exit 1; }
    if [[ "$OS" == macos ]]; then
      [[ -n "$(find "$stage/lib" -name '*.dylib' -print -quit)" ]] \
        || { echo "mysql(macos): no bundled .dylib under lib/" >&2; exit 1; }
      macos_make_relocatable "$stage"
    elif [[ "$OS" == linux ]]; then
      # Sweep non-core deps into lib/private, ensure libaio, strip, rpath, gate (shared helper).
      linux_self_contain "$stage" bin/mysqld bin/mysql
    fi
    require_files "$stage" bin/mysqld bin/mysql bin/mysqld_safe
    ;;

  postgres)
    # Phase 2: build from source (EDB ships no ARM binaries; zonky's ARM builds lack
    # psql/createdb). Release tarball bundles pre-generated gram.c/scan.c -> no
    # flex/bison/perl needed; just cc + make. PostgreSQL License (permissive).
    fetch_to "https://ftp.postgresql.org/pub/source/v${upstream}/postgresql-${upstream}.tar.gz" \
      "$work/pg.tar.gz"
    mkdir -p "$work/pg"
    tar xf "$work/pg.tar.gz" -C "$work/pg" --strip-components 1
    jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
    # Lean + relocatable. SSL is off by default (no --without-ssl flag exists). Loopback
    # 'trust' auth at runtime means no TLS needed.
    ( cd "$work/pg" && ./configure --prefix="$work/pgi" \
        --without-icu --without-readline --without-zlib --without-libxml )
    make -C "$work/pg" -j"$jobs"
    make -C "$work/pg" install-strip   # strip symbols (esp. large on Linux)
    cp "$work/pgi/bin/postgres" "$work/pgi/bin/initdb" "$work/pgi/bin/pg_ctl" \
       "$work/pgi/bin/psql" "$work/pgi/bin/createdb" "$stage/bin/"
    # Postgres resolves share/ + lib/ relative to the executable, so ship them verbatim.
    cp -R "$work/pgi/lib" "$stage/lib"
    cp -R "$work/pgi/share" "$stage/share"
    # initdb needs the timezone db + bootstrap catalog + sample configs. The source
    # build nests these under share/postgresql/ (and lib/postgresql/); postgres resolves
    # them via the compiled-in bin -> ../share/postgresql relative path, so the verbatim
    # copy keeps it relocatable.
    [[ -d "$stage/share/postgresql/timezone" ]] || { echo "postgres: share/postgresql/timezone missing" >&2; exit 1; }
    [[ -f "$stage/share/postgresql/postgres.bki" ]] || { echo "postgres: share/postgresql/postgres.bki missing" >&2; exit 1; }
    ls "$stage"/share/postgresql/*.sample >/dev/null 2>&1 \
      || { echo "postgres: no *.sample configs in share/postgresql/" >&2; exit 1; }
    # PG bakes absolute lib paths into the binaries (macOS install names / Linux rpath);
    # rewrite them relative to the executable so the unpacked tree relocates.
    case "$OS" in
      macos) macos_make_relocatable "$stage" ;;
      linux) linux_make_relocatable "$stage" ;;
    esac
    require_files "$stage" bin/postgres bin/initdb bin/pg_ctl bin/psql bin/createdb
    ;;

  mariadb)
    # Phase 3 (GPLv2). MariaDB ships ONLY a linux-systemd-x86_64 bintar — no ARM Linux,
    # no macOS — so: repackage for linux-x86_64, build from source (CMake) everywhere else.
    # Helper set: mariadb-install-db is a shell script that runs my_print_defaults and
    # bootstraps via mariadbd, so all of these must ship together.
    helpers=(mariadbd mariadb mariadb-install-db my_print_defaults mariadb-tzinfo-to-sql resolveip)

    if [[ "$OS" == linux && "$ARCH" == x86_64 ]]; then
      # ---- repackage the official linux-systemd-x86_64 bintar ----
      url="https://archive.mariadb.org/mariadb-${upstream}/bintar-linux-systemd-x86_64/mariadb-${upstream}-linux-systemd-x86_64.tar.gz"
      echo ">> mariadb source: $url"
      fetch_to "$url" "$work/mariadb.tar.gz"
      mkdir -p "$work/m"
      tar xf "$work/mariadb.tar.gz" -C "$work/m" --strip-components 1
      for h in "${helpers[@]}"; do
        # bintar keeps mariadb-install-db under bin/ or scripts/; binaries under bin/.
        if   [[ -e "$work/m/bin/$h" ]];     then cp "$work/m/bin/$h" "$stage/bin/"
        elif [[ -e "$work/m/scripts/$h" ]]; then cp "$work/m/scripts/$h" "$stage/bin/"
        fi
      done
      cp -R "$work/m/lib" "$stage/lib"
      cp -R "$work/m/share" "$stage/share"
      rm -f  "$stage"/lib/*.a 2>/dev/null || true
      rm -rf "$stage"/lib/plugin/debug 2>/dev/null || true
      # The linux-systemd bintar needs libsystemd + a chain (liblzma/libzstd/liblz4/libcap/…);
      # provision them so linux_self_contain's ldd sweep bundles the whole chain (+ gates it).
      ensure_mariadb_runtime_deps
      linux_self_contain "$stage" bin/mariadbd bin/mariadb bin/my_print_defaults
    else
      # ---- build from source (linux-aarch64, macos-aarch64) ----
      ensure_mariadb_build_deps || { echo "mariadb: build toolchain unavailable" >&2; exit 1; }
      fetch_to "https://archive.mariadb.org/mariadb-${upstream}/source/mariadb-${upstream}.tar.gz" \
        "$work/mariadb-src.tar.gz"
      mkdir -p "$work/src"
      tar xf "$work/mariadb-src.tar.gz" -C "$work/src" --strip-components 1
      jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
      # Build dir is 'bld' NOT 'build' — macOS's case-insensitive fs collides with the
      # in-tree BUILD/ dir. WITH_SSL=system → OpenSSL for BOTH server and the client connector
      # (a small, bundleable 2-dylib tree). DISABLE_FIND_PACKAGE_GnuTLS stops the connector
      # auto-linking brew GnuTLS (a huge p11-kit/nettle tree that's painful to bundle).
      ssl_args=(-DWITH_SSL=system -DCMAKE_DISABLE_FIND_PACKAGE_GnuTLS=ON)
      [[ "$OS" == macos ]] && ssl_args+=(-DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3 2>/dev/null)")
      cmake -S "$work/src" -B "$work/bld" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$work/mi" \
        -DWITH_UNIT_TESTS=0 -DWITH_MARIABACKUP=0 -DWITH_EMBEDDED_SERVER=OFF \
        -DPLUGIN_PERFSCHEMA=NO "${ssl_args[@]}" \
        -DPLUGIN_CONNECT=NO -DPLUGIN_MROONGA=NO -DPLUGIN_ROCKSDB=NO -DPLUGIN_SPIDER=NO \
        -DPLUGIN_COLUMNSTORE=NO -DPLUGIN_OQGRAPH=NO -DPLUGIN_SPHINX=NO -DPLUGIN_S3=NO
      cmake --build "$work/bld" -j"$jobs"
      cmake --install "$work/bld"
      for h in "${helpers[@]}"; do
        if   [[ -e "$work/mi/bin/$h" ]];     then cp "$work/mi/bin/$h" "$stage/bin/"
        elif [[ -e "$work/mi/scripts/$h" ]]; then cp "$work/mi/scripts/$h" "$stage/bin/"
        fi
      done
      cp -R "$work/mi/lib" "$stage/lib"
      cp -R "$work/mi/share" "$stage/share"
      rm -f "$stage"/lib/*.a 2>/dev/null || true
      if [[ "$OS" == macos ]]; then
        macos_bundle_external "$stage"     # copy brew OpenSSL (+ any external) dylibs into lib/
        macos_make_relocatable "$stage"    # rewrite their refs to @rpath + re-sign
        macos_self_contain_gate "$stage"   # fail if anything's still dangling/unbundled
      else
        linux_self_contain "$stage" bin/mariadbd bin/mariadb bin/my_print_defaults
      fi
    fi

    # Both paths: assert the bootstrap inputs mariadb-install-db needs are present.
    [[ -n "$(find "$stage/share" -name 'errmsg.sys' -print -quit)" ]] \
      || { echo "mariadb: errmsg.sys missing from share/" >&2; exit 1; }
    [[ -n "$(find "$stage/share" \( -name 'mariadb_system_tables.sql' -o -name 'mysql_system_tables.sql' \) -print -quit)" ]] \
      || { echo "mariadb: system-table SQL missing from share/" >&2; exit 1; }
    require_files "$stage" bin/mariadbd bin/mariadb bin/mariadb-install-db bin/my_print_defaults
    ;;

  *)
    echo "build-service.sh: unhandled service '$service'" >&2
    exit 1
    ;;
esac

# Ship the upstream license inside the artifact (required for GPLv2 redistribution of
# MySQL — which we additionally modify via install_name_tool/codesign on macOS — and
# good practice for the others).
case "$service" in
  redis)    lic=valkey-BSD-3-Clause.txt ;;
  mysql)    lic=mysql-GPLv2.txt ;;
  postgres) lic=postgresql-PostgreSQL-License.txt ;;
  mariadb)  lic=mariadb-GPLv2.txt ;;
  *)        lic="" ;;
esac
if [[ -n "$lic" ]]; then
  [[ -f "$repo_root/LICENSES/$lic" ]] || { echo "missing LICENSES/$lic" >&2; exit 1; }
  cp "$repo_root/LICENSES/$lic" "$stage/LICENSE"
fi

pack_stage "$stage" "$out"
echo ">> wrote $out"
