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
      # The Linux generic tarball dynamically links a few non-glibc system libs it
      # doesn't bundle (notably libaio; sometimes libnuma/libtinfo). Copy them into
      # lib/private/ so the artifact is self-contained on user machines, not just the CI
      # runner. Leave glibc core + libstdc++/libgcc to the host to avoid ABI mixing.
      #
      mkdir -p "$stage/lib/private"
      # Bundle whatever non-core deps are already resolvable on the host (libssl/libcrypto
      # are already in lib/private from Oracle; this catches e.g. libnuma if present).
      while IFS= read -r dep; do
        cp -n "$dep" "$stage/lib/private/" 2>/dev/null || true
      done < <(ldd "$stage/bin/mysqld" "$stage/bin/mysql" 2>/dev/null \
        | awk '/=> \// && !/libc\.so|libm\.so|libpthread|libdl\.so|librt\.so|libresolv|ld-linux|linux-vdso|libstdc\+\+|libgcc_s/ {print $3}' \
        | sort -u)
      ensure_patchelf || true   # for the rpath fixup + self-containment gate below
      # libaio.so.1 is hard-required and often absent from a bare build env; install it
      # (root-aware) and copy it into lib/private. The gate below reports if it's missing.
      ensure_libaio "$stage/lib/private" \
        || echo "mysql(linux): could not provision libaio (gate will report)" >&2
      # Strip debug symbols from the Linux binaries + shared libs — the main reason the
      # Linux artifact dwarfs macOS. --strip-unneeded keeps the dynamic symbols .so files
      # need; plain strip on the executables. (Skip the bundled host libs we just copied.)
      strip "$stage/bin/mysqld" "$stage/bin/mysql" 2>/dev/null || true
      find "$stage/lib" -type f \( -name '*.so' -o -name '*.so.*' \) \
        -exec strip --strip-unneeded {} + 2>/dev/null || true
      # Don't trust Oracle's baked rpath to cover lib/private — add it explicitly.
      if command -v patchelf >/dev/null 2>&1; then
        for b in "$stage/bin/mysqld" "$stage/bin/mysql"; do
          patchelf --add-rpath '$ORIGIN/../lib/private' "$b" 2>/dev/null || true
          patchelf --add-rpath '$ORIGIN/../lib' "$b" 2>/dev/null || true
        done
      fi
      # Self-containment gate: every non-glibc/non-libstdc++ NEEDED lib of mysqld must be
      # bundled under lib/, else the artifact runs on the CI host (which has the system
      # lib) but breaks on a user machine — exactly the libaio.so.1 failure mode. Fail
      # the build with a clear message instead of shipping it.
      if command -v patchelf >/dev/null 2>&1; then
        core='^(libc|libm|libmvec|libpthread|libdl|librt|libresolv|libstdc\+\+|libgcc_s|ld-linux.*)\.so'
        while IFS= read -r need; do
          [[ -z "$need" ]] && continue
          echo "$need" | grep -Eq "$core" && continue
          find "$stage/lib" -name "$need" | grep -q . || {
            echo "mysql(linux): required lib '$need' is not bundled. Install it on the" >&2
            echo "  build host before building (e.g. 'apt-get install -y libaio1t64')." >&2
            exit 1
          }
        done < <(patchelf --print-needed "$stage/bin/mysqld" 2>/dev/null)
      fi
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

# Ship the upstream license inside the artifact (required for GPLv2 redistribution of
# MySQL — which we additionally modify via install_name_tool/codesign on macOS — and
# good practice for the others).
case "$service" in
  redis)    lic=valkey-BSD-3-Clause.txt ;;
  mysql)    lic=mysql-GPLv2.txt ;;
  postgres) lic=postgresql-PostgreSQL-License.txt ;;
  *)        lic="" ;;
esac
if [[ -n "$lic" ]]; then
  [[ -f "$repo_root/LICENSES/$lic" ]] || { echo "missing LICENSES/$lic" >&2; exit 1; }
  cp "$repo_root/LICENSES/$lic" "$stage/LICENSE"
fi

pack_stage "$stage" "$out"
echo ">> wrote $out"
