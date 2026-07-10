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
stage_full=""   # second stage for the postgres `full` variant (built after the base); may stay unset
work="$(mktemp -d "${TMPDIR:-/tmp}/yerd-build.XXXXXX")"
trap 'rm -rf "$stage" "${stage_full:-}" "$work"' EXIT

echo ">> building service=$service version=$version upstream=$upstream os=$OS arch=$ARCH"

# win_stage_bin <vendor_root> <stage> <exe...>: copy the named vendor executables PLUS
# every sibling DLL from <vendor_root>/bin into <stage>/bin. On Windows the loader finds
# DLLs next to the .exe, so the runtime DLLs (OpenSSL, libpq, libiconv, …) that vendor
# zips keep in bin/ MUST travel with the exes — copying all bin/*.dll is what makes the
# artifact self-contained (the inverse of the Unix lib/ layout).
win_stage_bin() {
  local root="$1" stage="$2"; shift 2
  local e
  for e in "$@"; do
    if   [[ -e "$root/bin/$e" ]];     then cp "$root/bin/$e" "$stage/bin/"
    elif [[ -e "$root/$e" ]];         then cp "$root/$e" "$stage/bin/"   # flat zips (redis)
    else echo "win_stage_bin: missing '$e' under '$root'" >&2; return 1; fi
  done
  cp "$root"/bin/*.dll "$stage/bin/" 2>/dev/null || true
  cp "$root"/*.dll     "$stage/bin/" 2>/dev/null || true   # flat zips (redis)
  # Drop debug-build DLLs the vendor ships alongside the release ones (e.g. MySQL's
  # *-debug.dll for abseil/protobuf) — never imported by the staged exes, just dead weight.
  rm -f "$stage"/bin/*-debug.dll 2>/dev/null || true
  return 0
}

# build_postgres_full <stage_full> <out_full>: build the PostGIS-bearing `full` variant into its
# own stage and pack it, GPL-encumbered and confined to this artifact (the base stays permissive).
# Unix: a SECOND from-source postgres (--with-libxml/ssl/uuid, so pgcrypto/uuid-ossp/sslinfo/xml2
# become buildable) + pgvector + PostGIS-with-raster, with the whole geo chain bundled+relocated.
# Windows: repackage the EDB tree again and overlay the self-contained OSGeo PostGIS bundle.
# Uses script globals: work, repo_root, OS, version, upstream.
build_postgres_full() {
  local sf="$1" of="$2"
  local jobs; jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
  local pgi="$work/pgi_full"

  if [[ "$OS" == windows ]]; then
    # Reuse the EDB tree extracted by the base windows branch ($work/pg -> pgsql/).
    local root; root="$(vendor_root "$work/pg" "pgsql")"
    win_stage_bin "$root" "$sf" postgres.exe initdb.exe pg_ctl.exe psql.exe \
      createdb.exe pg_dump.exe pg_dumpall.exe pg_restore.exe
    cp -R "$root/share" "$sf/share"
    cp -R "$root/lib" "$sf/lib"
    # Overlay the prebuilt, self-contained OSGeo PostGIS bundle (its own GEOS/PROJ/GDAL/libxml
    # DLLs + data) onto the EDB tree. Its bin/ DLLs must sit next to the exes (Windows loader).
    local pgmaj; pgmaj="$(printf '%s\n' "$upstream" | cut -d. -f1)"
    local burl; burl="$(postgis_win_url "$pgmaj")" || { echo "postgres(full,windows): no PostGIS bundle" >&2; return 1; }
    echo ">> postgis(windows) bundle: $burl"
    fetch_to "$burl" "$work/postgis-win.zip"
    unzip_vendor "$work/postgis-win.zip" "$work/pgis"
    local broot; broot="$(vendor_root "$work/pgis")"
    cp -R "$broot"/bin/.   "$sf/bin/"   2>/dev/null || true
    cp -R "$broot"/lib/.   "$sf/lib/"   2>/dev/null || true
    cp -R "$broot"/share/. "$sf/share/" 2>/dev/null || true
    # GDAL's runtime data sits at the bundle ROOT as gdal-data/ (the bundle nests proj.db under
    # share/contrib/ but keeps GDAL data top-level), so the share/ overlay above misses it. Stage
    # it as share/gdal — matching the Unix `full` layout so the daemon/smoke PROJ_DATA/GDAL_DATA
    # probe (which searches the tree for gdalvrt.xsd) resolves it; else postgis_raster reprojection
    # can't find its data files post-relocation.
    [[ -d "$broot/gdal-data" ]] && { mkdir -p "$sf/share/gdal"; cp -R "$broot/gdal-data/." "$sf/share/gdal/"; }
    windows_bundle_runtime "$sf"
    # windows_self_contain_gate scans only bin/*.exe (not the overlaid lib/ DLLs) — the geo-less
    # Windows runner's `CREATE EXTENSION postgis` smoke is the real load test for the overlay.
    windows_self_contain_gate "$sf"
    [[ -n "$(find "$sf/share" -name 'postgis.control' -print -quit)" ]] \
      || { echo "postgres(full,windows): postgis.control missing after overlay" >&2; return 1; }
    [[ -n "$(find "$sf/share" -name 'gdalvrt.xsd' -print -quit)" ]] \
      || { echo "postgres(full,windows): GDAL data (gdalvrt.xsd) missing after overlay" >&2; return 1; }
    # The OSGeo bundle vendors many components beyond PostGIS — SFCGAL/CGAL/GMP, pgRouting,
    # MobilityDB, pgPointCloud, h3, ogr_fdw, pg_sphere, GSL (GPLv3), ... — each with its own
    # license/copyright, none covered by the six geo notices the shared block below stages. Ship
    # the bundle's OWN notice files verbatim (keeping their relative paths under
    # LICENSES/postgis-bundle/) so the redistributed artifact carries the complete set upstream
    # curated, self-updating when the pinned bundle version changes rather than a hand-kept list
    # that drifts. bin/COPYING is the GPLv2 aggregate; LICENSE (Apache-2.0) + the per-component
    # COPYRIGHT/LICENSE files cover the rest.
    local lf rel n=0
    while IFS= read -r -d '' lf; do
      rel="${lf#"$broot"/}"
      mkdir -p "$sf/LICENSES/postgis-bundle/$(dirname "$rel")"
      cp "$lf" "$sf/LICENSES/postgis-bundle/$rel"
      n=$((n + 1))
    done < <(find "$broot" -maxdepth 2 -type f \
               \( -iname '*licen[sc]e*' -o -iname '*copying*' -o -iname '*copyright*' \
                  -o -iname '*notice*' -o -iname 'AUTHORS.md' \) -print0)
    [[ "$n" -gt 0 ]] || { echo "postgres(full,windows): no bundle license/notice files staged" >&2; return 1; }
    echo ">> staged $n postgis-bundle license/notice file(s) under LICENSES/postgis-bundle/"
  else
    # ---- Unix: second from-source postgres with the geo/crypto flags on ----
    ensure_postgis_deps || { echo "postgres(full): geo/build deps unavailable" >&2; return 1; }
    rm -rf "$work/pg_full"; mkdir -p "$work/pg_full"
    tar xf "$work/pg.tar.gz" -C "$work/pg_full" --strip-components 1   # already fetched by base
    local cfg=(--prefix="$pgi" --with-libxml --with-uuid=e2fs --with-ssl=openssl
               --without-icu --without-readline --without-zlib)
    if [[ "$OS" == macos ]]; then
      local ossl; ossl="$(brew --prefix openssl@3 2>/dev/null)"
      [[ -n "$ossl" ]] && cfg+=(--with-includes="$ossl/include" --with-libraries="$ossl/lib")
    fi
    ( cd "$work/pg_full" && ./configure "${cfg[@]}" )
    make -C "$work/pg_full" -j"$jobs"
    make -C "$work/pg_full" install-strip
    # All buildable contrib (the base set + the four the flags above unblock).
    local ce=(pg_stat_statements pg_trgm citext unaccent hstore ltree btree_gin btree_gist
              fuzzystrmatch tablefunc intarray cube earthdistance postgres_fdw dblink pageinspect
              amcheck pgstattuple pg_buffercache pgcrypto sslinfo xml2 uuid-ossp)
    local c
    for c in "${ce[@]}"; do
      make -C "$work/pg_full/contrib/$c" -j"$jobs"
      make -C "$work/pg_full/contrib/$c" install-strip
    done
    # pgvector (fresh extract; OPTFLAGS="" to strip -march=native for portability).
    local pgvector_ver="${PGVECTOR_UPSTREAM:-v0.8.5}"
    rm -rf "$work/pgvector_full"; mkdir -p "$work/pgvector_full"
    tar xf "$work/pgvector.tar.gz" -C "$work/pgvector_full" --strip-components 1   # fetched by base
    make -C "$work/pgvector_full" PG_CONFIG="$pgi/bin/pg_config" OPTFLAGS="" -j"$jobs"
    make -C "$work/pgvector_full" PG_CONFIG="$pgi/bin/pg_config" OPTFLAGS="" install-strip
    # PostGIS (with raster, on by default in 3.x) against the pg we just built.
    local postgis_ver="${POSTGIS_UPSTREAM:-3.6.0}"
    fetch_to "https://download.osgeo.org/postgis/source/postgis-${postgis_ver}.tar.gz" \
      "$work/postgis.tar.gz"
    rm -rf "$work/postgis"; mkdir -p "$work/postgis"
    tar xf "$work/postgis.tar.gz" -C "$work/postgis" --strip-components 1
    # --prefix=$pgi so PostGIS's autoconf @bindir@ (used by the topology module's macOS
    # -bundle_loader) points at OUR postgres, not the /usr/local/bin default (the main module
    # already uses pg_config --bindir; topology uses @bindir@ — they must agree). Extensions still
    # install into the pg tree via pg_config, independent of --prefix. --without-sfcgal keeps the
    # dep set deterministic (else configure opportunistically links a preinstalled brew SFCGAL,
    # an unplanned LGPL/GPL dep absent on clean CI runners).
    # PostGIS raster assumes certain system headers are transitively included, which strict/newer
    # toolchains no longer guarantee — different platforms expose different gaps. Force-include the
    # small set: <sys/param.h> for MIN/MAX (macOS beta SDK) and <sys/stat.h> for `struct stat`,
    # which GDAL's cpl_vsi.h typedefs as VSIStatBufL without including it (ubuntu's GDAL → rt_band.c
    # "storage size unknown"). Both are macro/type guarded, so harmless on the platform that already
    # had them. -Wno-error demotions catch any other implicit decls on very new clang. autoconf
    # carries CFLAGS into every module compile; keep -O2 since we override autoconf's default.
    # _GNU_SOURCE/_LARGEFILE64_SOURCE expose glibc's `struct stat64`, which GDAL typedefs as
    # VSIStatBufL (used by PostGIS raster rt_band.c); without them modern glibc hides it →
    # "storage size unknown". No-ops on macOS.
    ( cd "$work/postgis" \
        && CFLAGS="${CFLAGS:-} -O2 -D_GNU_SOURCE -D_LARGEFILE64_SOURCE -include sys/param.h -include sys/stat.h -Wno-error=implicit-function-declaration -Wno-error=implicit-int" \
           ./configure --prefix="$pgi" --with-pgconfig="$pgi/bin/pg_config" --without-sfcgal )
    make -C "$work/postgis" -j"$jobs"
    make -C "$work/postgis" install
    # Stage the whole install tree.
    cp -R "$pgi/lib" "$sf/lib"
    cp -R "$pgi/share" "$sf/share"
    mkdir -p "$sf/bin"
    cp "$pgi/bin/postgres" "$pgi/bin/initdb" "$pgi/bin/pg_ctl" "$pgi/bin/psql" "$pgi/bin/createdb" \
       "$pgi/bin/pg_dump" "$pgi/bin/pg_dumpall" "$pgi/bin/pg_restore" "$sf/bin/"
    # Bundle PROJ + GDAL runtime data under share/ (the daemon exports PROJ_DATA/GDAL_DATA at it).
    local projdb gdaldata
    projdb="$(find /usr/share /usr/local/share "$(brew --prefix proj 2>/dev/null)/share" -name proj.db -print -quit 2>/dev/null || true)"
    # Bundle ONLY proj.db (the CRS db + standard transforms, ~10MB). NOT the full proj-data grid
    # set (per-country datum .tif grids, 20-77MB each → ~770MB) — those are optional high-accuracy
    # datum shifts, unneeded for standard reprojection and network-fetchable on demand. Copy the
    # small non-grid metadata too, but skip anything grid-sized.
    if [[ -n "$projdb" ]]; then
      mkdir -p "$sf/share/proj"
      cp "$projdb" "$sf/share/proj/"
      find "$(dirname "$projdb")" -maxdepth 1 -type f ! -name '*.tif' -size -1M \
        -exec cp {} "$sf/share/proj/" \; 2>/dev/null || true
    fi
    gdaldata="$(gdal-config --datadir 2>/dev/null || true)"
    [[ -n "$gdaldata" && -d "$gdaldata" ]] && { mkdir -p "$sf/share/gdal"; cp -R "$gdaldata"/. "$sf/share/gdal/"; }
    # Self-contain + relocate the WHOLE stage (the geo chain lives in lib/ + lib/postgresql/).
    if [[ "$OS" == macos ]]; then
      macos_bundle_external "$sf"; macos_make_relocatable "$sf"; macos_self_contain_gate "$sf"
    else
      # Seeds = the server + every extension module; ldd of each yields the full transitive chain.
      local -a seeds=(bin/postgres) so
      while IFS= read -r so; do [[ -n "$so" ]] && seeds+=("$so"); done \
        < <(cd "$sf" && find lib/postgresql -maxdepth 1 -name '*.so' 2>/dev/null)
      linux_bundle_all "$sf" "${seeds[@]}"
      linux_make_relocatable "$sf"
      linux_gate_all_elf "$sf"
    fi
    # Presence asserts — the extensions + data actually made it into the tree.
    local x
    for x in postgis postgis_raster pgcrypto uuid-ossp vector; do
      [[ -n "$(find "$sf/share" -name "$x.control" -print -quit)" ]] \
        || { echo "postgres(full): $x.control missing" >&2; return 1; }
    done
    [[ -n "$(find "$sf/share" -name proj.db -print -quit)" ]] \
      || { echo "postgres(full): proj.db not bundled" >&2; return 1; }
  fi

  # License staging: base PostgreSQL + pgvector (unix) + the GPL/LGPL/permissive geo notices.
  # Map is "<src-basename> <artifact-notice-name>" so json-c/protobuf-c keep their real names.
  cp "$repo_root/LICENSES/postgresql-PostgreSQL-License.txt" "$sf/LICENSE"
  [[ "$OS" != windows ]] && cp "$repo_root/LICENSES/pgvector-PostgreSQL-License.txt" "$sf/LICENSE-pgvector"
  local pair src dst
  for pair in "postgis-GPLv2:postgis" "geos-LGPL-2.1:geos" "proj-X11:proj" \
              "gdal-MIT:gdal" "json-c-MIT:json-c" "protobuf-c-BSD-2-Clause:protobuf-c"; do
    src="${pair%%:*}"; dst="${pair##*:}"
    [[ -f "$repo_root/LICENSES/$src.txt" ]] || { echo "postgres(full): missing LICENSES/$src.txt" >&2; return 1; }
    cp "$repo_root/LICENSES/$src.txt" "$sf/LICENSE-$dst"
  done

  pack_stage "$sf" "$of"
}

if [[ "$OS" == windows ]]; then
  # ---- Windows (x86_64): repackage the official vendor winx64 zips ----
  # No rpath/install_name on Windows: self-containment = DLLs next to the .exe in bin/.
  # vendor zips keep their runtime DLLs in bin/ (NOT lib/), so win_stage_bin copies them.
  case "$service" in
    redis)
      # Windows ships REDIS (native MSVC port), not Valkey (valkey #92: no Windows build).
      # Upstream is platform-divergent: ignore the Valkey tag, use the pinned Redis-port
      # version. Real names kept (redis-server.exe/redis-cli.exe) — no rename to valkey-*.
      win_up="${REDIS_WIN_UPSTREAM:-5.0.14.1}"
      url="$(redis_win_url "$win_up")"
      echo ">> redis(windows) source: $url"
      fetch_to "$url" "$work/redis.zip"
      unzip_vendor "$work/redis.zip" "$work/r"
      root="$(vendor_root "$work/r")"
      win_stage_bin "$root" "$stage" redis-server.exe redis-cli.exe
      windows_bundle_runtime "$stage"
      windows_self_contain_gate "$stage"
      require_files "$stage" bin/redis-server.exe bin/redis-cli.exe
      ;;

    mysql)
      url="$(mysql_win_url "$upstream")"
      echo ">> mysql(windows) source: $url"
      fetch_to "$url" "$work/mysql.zip"
      unzip_vendor "$work/mysql.zip" "$work/m"
      root="$(vendor_root "$work/m" "mysql-${upstream}-winx64")"
      # mysqld.exe + client/dump; NO mysqld_safe (Unix-only shell script).
      win_stage_bin "$root" "$stage" mysqld.exe mysql.exe mysqldump.exe
      # share/ holds errmsg.sys + charsets; lib/plugin holds runtime plugins.
      cp -R "$root/share" "$stage/share"
      [[ -d "$root/lib/plugin" ]] && { mkdir -p "$stage/lib"; cp -R "$root/lib/plugin" "$stage/lib/plugin"; }
      windows_bundle_runtime "$stage"
      windows_self_contain_gate "$stage"
      require_files "$stage" bin/mysqld.exe bin/mysql.exe bin/mysqldump.exe
      ;;

    mariadb)
      url="$(mariadb_win_url "$upstream")"
      echo ">> mariadb(windows) source: $url"
      fetch_to "$url" "$work/mariadb.zip"
      unzip_vendor "$work/mariadb.zip" "$work/m"
      root="$(vendor_root "$work/m" "mariadb-${upstream}-winx64")"
      # Probe the Windows init tool name (varies: mariadb-install-db.exe | mysql_install_db.exe).
      init_tool=""
      for cand in mariadb-install-db.exe mysql_install_db.exe; do
        [[ -e "$root/bin/$cand" ]] && { init_tool="$cand"; break; }
      done
      [[ -n "$init_tool" ]] || { echo "mariadb(windows): no init tool (mariadb-install-db.exe/mysql_install_db.exe)" >&2; exit 1; }
      win_stage_bin "$root" "$stage" mariadbd.exe mariadb.exe mariadb-dump.exe "$init_tool"
      cp -R "$root/share" "$stage/share"
      [[ -d "$root/lib/plugin" ]] && { mkdir -p "$stage/lib"; cp -R "$root/lib/plugin" "$stage/lib/plugin"; }
      # Same bootstrap-input asserts as the Unix paths.
      [[ -n "$(find "$stage/share" -name 'errmsg.sys' -print -quit)" ]] \
        || { echo "mariadb: errmsg.sys missing from share/" >&2; exit 1; }
      [[ -n "$(find "$stage/share" \( -name 'mariadb_system_tables.sql' -o -name 'mysql_system_tables.sql' \) -print -quit)" ]] \
        || { echo "mariadb: system-table SQL missing from share/" >&2; exit 1; }
      windows_bundle_runtime "$stage"
      windows_self_contain_gate "$stage"
      require_files "$stage" bin/mariadbd.exe bin/mariadb.exe bin/mariadb-dump.exe "bin/$init_tool"
      ;;

    postgres)
      url="$(postgres_win_url "$upstream")"
      echo ">> postgres(windows) source: $url"
      fetch_to "$url" "$work/pg.zip"
      unzip_vendor "$work/pg.zip" "$work/pg"
      root="$(vendor_root "$work/pg" "pgsql")"
      win_stage_bin "$root" "$stage" postgres.exe initdb.exe pg_ctl.exe psql.exe \
        createdb.exe pg_dump.exe pg_dumpall.exe pg_restore.exe
      # EDB resolves share/ + lib/ relative to the exe — ship them verbatim.
      cp -R "$root/share" "$stage/share"
      cp -R "$root/lib" "$stage/lib"
      windows_bundle_runtime "$stage"
      windows_self_contain_gate "$stage"
      require_files "$stage" bin/postgres.exe bin/initdb.exe bin/pg_ctl.exe bin/psql.exe \
        bin/createdb.exe bin/pg_dump.exe bin/pg_dumpall.exe bin/pg_restore.exe
      ;;

    *)
      echo "build-service.sh: unhandled service '$service' (windows)" >&2
      exit 1
      ;;
  esac
else
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
    cp "$work/m/bin/mysqld" "$work/m/bin/mysql" "$work/m/bin/mysqld_safe" \
       "$work/m/bin/mysqldump" "$stage/bin/"
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
      linux_self_contain "$stage" bin/mysqld bin/mysql bin/mysqldump
    fi
    require_files "$stage" bin/mysqld bin/mysql bin/mysqld_safe bin/mysqldump
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
    # Bundle a curated set of dependency-free contrib extensions. Built in-tree (each subdir
    # inherits src/Makefile.global -> --prefix=$work/pgi), so install-strip lands the .so under
    # $work/pgi/lib/postgresql and the control/SQL under $work/pgi/share/postgresql/extension —
    # both swept into the stage by the cp -R below and made relocatable with the rest of the tree.
    # Excluded on purpose (need flags/libs we don't configure): pgcrypto/sslinfo (OpenSSL — PG14+
    # dropped pgcrypto's built-in crypto), xml2 (libxml), uuid-ossp (--with-uuid), the pl* companions.
    contrib_exts=(
      pg_stat_statements pg_trgm citext unaccent hstore ltree
      btree_gin btree_gist fuzzystrmatch tablefunc intarray cube earthdistance
      postgres_fdw dblink pageinspect amcheck pgstattuple pg_buffercache
    )
    for c in "${contrib_exts[@]}"; do
      make -C "$work/pg/contrib/$c" -j"$jobs"
      make -C "$work/pg/contrib/$c" install-strip
    done
    # Bundle pgvector (out-of-tree PGXS build against the pg we just built). OPTFLAGS="" strips
    # pgvector's default -march=native so the CI-built .so runs on any CPU of the target arch
    # (it's shipped to arbitrary user machines, not just the builder). install-strip is defined
    # unconditionally in Makefile.global, so it works for this PGXS build too.
    pgvector_ver="${PGVECTOR_UPSTREAM:-v0.8.5}"
    fetch_to "https://github.com/pgvector/pgvector/archive/refs/tags/${pgvector_ver}.tar.gz" \
      "$work/pgvector.tar.gz"
    mkdir -p "$work/pgvector"
    tar xf "$work/pgvector.tar.gz" -C "$work/pgvector" --strip-components 1
    make -C "$work/pgvector" PG_CONFIG="$work/pgi/bin/pg_config" OPTFLAGS="" -j"$jobs"
    make -C "$work/pgvector" PG_CONFIG="$work/pgi/bin/pg_config" OPTFLAGS="" install-strip
    cp "$work/pgi/bin/postgres" "$work/pgi/bin/initdb" "$work/pgi/bin/pg_ctl" \
       "$work/pgi/bin/psql" "$work/pgi/bin/createdb" \
       "$work/pgi/bin/pg_dump" "$work/pgi/bin/pg_dumpall" "$work/pgi/bin/pg_restore" "$stage/bin/"
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
    # Extensions must have actually installed into the staged tree (a silently-empty install
    # would otherwise only surface in the smoke stage). Check one contrib + pgvector control file.
    [[ -f "$stage/share/postgresql/extension/pg_trgm.control" ]] \
      || { echo "postgres: contrib not installed (pg_trgm.control missing)" >&2; exit 1; }
    [[ -f "$stage/share/postgresql/extension/vector.control" ]] \
      || { echo "postgres: pgvector not installed (vector.control missing)" >&2; exit 1; }
    # PG bakes absolute lib paths into the binaries (macOS install names / Linux rpath);
    # rewrite them relative to the executable so the unpacked tree relocates.
    case "$OS" in
      macos) macos_make_relocatable "$stage" ;;
      linux) linux_make_relocatable "$stage" ;;
    esac
    require_files "$stage" bin/postgres bin/initdb bin/pg_ctl bin/psql bin/createdb \
      bin/pg_dump bin/pg_dumpall bin/pg_restore
    ;;

  mariadb)
    # Phase 3 (GPLv2). MariaDB ships ONLY a linux-systemd-x86_64 bintar — no ARM Linux,
    # no macOS — so: repackage for linux-x86_64, build from source (CMake) everywhere else.
    # Helper set: mariadb-install-db is a shell script that runs my_print_defaults and
    # bootstraps via mariadbd, so all of these must ship together.
    helpers=(mariadbd mariadb mariadb-install-db my_print_defaults mariadb-tzinfo-to-sql resolveip mariadb-dump)

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
      linux_self_contain "$stage" bin/mariadbd bin/mariadb bin/my_print_defaults bin/mariadb-dump
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
      # Force BUNDLED pcre/zlib/fmt instead of auto-finding the host's (Homebrew) copies. On a
      # loaded runner `auto` finds brew pcre2/fmt and injects /opt/homebrew/include globally,
      # which breaks libc++'s header search ("<cstddef> ... didn't find <stddef.h>"). Bundling
      # makes the build hermetic across machines (and compiles those libs in — more relocatable).
      cmake -S "$work/src" -B "$work/bld" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$work/mi" \
        -DWITH_UNIT_TESTS=0 -DWITH_MARIABACKUP=0 -DWITH_EMBEDDED_SERVER=OFF \
        -DPLUGIN_PERFSCHEMA=NO "${ssl_args[@]}" \
        -DWITH_PCRE=bundled -DWITH_ZLIB=bundled -DWITH_LIBFMT=bundled \
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
        linux_self_contain "$stage" bin/mariadbd bin/mariadb bin/my_print_defaults bin/mariadb-dump
      fi
    fi

    # Both paths: assert the bootstrap inputs mariadb-install-db needs are present.
    [[ -n "$(find "$stage/share" -name 'errmsg.sys' -print -quit)" ]] \
      || { echo "mariadb: errmsg.sys missing from share/" >&2; exit 1; }
    [[ -n "$(find "$stage/share" \( -name 'mariadb_system_tables.sql' -o -name 'mysql_system_tables.sql' \) -print -quit)" ]] \
      || { echo "mariadb: system-table SQL missing from share/" >&2; exit 1; }
    require_files "$stage" bin/mariadbd bin/mariadb bin/mariadb-install-db bin/my_print_defaults bin/mariadb-dump
    ;;

  *)
    echo "build-service.sh: unhandled service '$service'" >&2
    exit 1
    ;;
esac
fi

# Ship the upstream license inside the artifact (required for GPLv2 redistribution of
# MySQL — which we additionally modify via install_name_tool/codesign on macOS — and
# good practice for the others).
if [[ "$OS" == windows && "$service" == redis ]]; then
  # Windows redis is the native MSVC port of REDIS (pre-7.4 BSD-3), not Valkey. Ship the
  # upstream Redis BSD license, the port's combined BSD-3 notice, AND the notices for the
  # permissive deps statically linked into redis-server.exe (Lua/hiredis/jemalloc/linenoise),
  # all required for binary redistribution.
  mkdir -p "$stage/LICENSES"
  for l in redis-BSD-3-Clause.txt redis-windows-port-BSD-3-Clause.txt redis-windows-third-party-NOTICES.txt; do
    [[ -f "$repo_root/LICENSES/$l" ]] || { echo "missing LICENSES/$l" >&2; exit 1; }
    cp "$repo_root/LICENSES/$l" "$stage/LICENSES/$l"
  done
else
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
  # postgres (unix source build) additionally bundles pgvector, a separately-copyrighted
  # component -> ship its own notice. (Windows postgres repackages the EDB zip, which does not
  # include pgvector, so no pgvector notice there.)
  if [[ "$service" == postgres && "$OS" != windows ]]; then
    pgv_lic="$repo_root/LICENSES/pgvector-PostgreSQL-License.txt"
    [[ -f "$pgv_lic" ]] || { echo "missing LICENSES/pgvector-PostgreSQL-License.txt" >&2; exit 1; }
    cp "$pgv_lic" "$stage/LICENSE-pgvector"
  fi
fi

pack_stage "$stage" "$out"
echo ">> wrote $out"

# postgres builds BOTH the lean base (above) and the PostGIS-bearing `full` variant, shipped as a
# `<version>-full` label (the daemon treats the whole middle segment as an opaque version). The
# base is already packed; build+pack the second artifact into its own stage. A full-build failure
# aborts the leg (atomic publish) so nothing half-ships.
if [[ "$service" == postgres ]]; then
  stage_full="$(make_stage)"
  out_full="$dist/$(artifact_filename postgres "${version}-full" "$OS" "$ARCH")"
  echo ">> building postgres full variant -> $(basename "$out_full")"
  build_postgres_full "$stage_full" "$out_full"
  echo ">> wrote $out_full"
fi
