#!/usr/bin/env bash
#
# lib.sh — shared helpers and the single source of the producer-side artifact
# contract (see the "Artifact contract" section of README.md).
#
# Dependency-free: bash, curl, tar, uname (+ make for the redis recipe).
# Source this from the other scripts; it is not meant to be executed directly.

set -euo pipefail

# --- CDN mirror configuration -----------------------------------------------------

# CDN_CHECKSUM_MODE: the resolved Bunny-checksum behaviour of the storage zone, and
# the SINGLE source of truth for it. Both writers read this constant — release.yml's
# `cdn-mirror` job and cdn-sync.yml — and cdn-sync passes it verbatim to
# cdn-reconcile-plan.sh as --checksum-mode, which echoes it into the plan so the run
# summary can never claim a comparison mode different from the one that ran.
#
# It encodes the answers to three questions about the zone (see the "CDN mirror"
# section of README.md for the full matrix and how to resolve them):
#   hash       accepts a `Checksum:` header, populates it on PUT, AND refreshes it on
#              in-place overwrite  -> full hash comparison
#   nopopulate accepts the header but never populates the listing `Checksum`
#              -> size-only comparison (digest still sent: free server-side rejection)
#   stale      accepts and populates, but does NOT refresh on overwrite
#              -> size-only, and the reconcile nulls the CDN checksums first. Without
#                 that, a stale (non-null!) checksum mismatches forever and every sync
#                 re-uploads the whole mirror.
#   noheader   does not accept the header at all -> size-only, no digest sent, and the
#              callers verify each download locally with sha256sum instead
#
# DEFAULT `noheader`: the fail-safe cell. It never churns and never depends on
# unverified Bunny behaviour, and content integrity still comes from the local
# sha256sum verify. Change it only after empirically confirming the zone's behaviour;
# setting `hash` on a zone that does not refresh on overwrite causes permanent
# re-upload churn that the run summary would report as healthy.
CDN_CHECKSUM_MODE="${CDN_CHECKSUM_MODE:-noheader}"

# --- platform tokens ------------------------------------------------------------

# host_os: map `uname -s` to the contract os token. Fails loudly on anything else.
# Git Bash / MSYS2 report MINGW64_NT-*, MSYS_NT-*, CYGWIN_NT-* (and some shells set
# Windows_NT) — all map to the `windows` token.
host_os() {
  local s
  s="$(uname -s)"
  case "$s" in
    Darwin)                          echo macos ;;
    Linux)                           echo linux ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT) echo windows ;;
    *) echo "lib.sh: unsupported OS '$s' (want Darwin|Linux|MINGW*/MSYS*/CYGWIN*)" >&2; return 1 ;;
  esac
}

# host_arch: map `uname -m` to the contract arch token.
# macOS reports arm64, Linux arm reports aarch64 — both map to aarch64.
host_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64)   echo x86_64 ;;
    arm64|aarch64)  echo aarch64 ;;
    *) echo "lib.sh: unsupported arch '$m' (want x86_64|amd64|arm64|aarch64)" >&2; return 1 ;;
  esac
}

# --- service id ------------------------------------------------------------------

# canonical_service: normalize the input service id.
#   - `valkey` is the friendly alias for the `redis` slot (the redis slot ships Valkey).
#   - redis|mysql|mariadb|postgres|meilisearch pass through unchanged.
#   - anything else is rejected, so a typo fails loudly instead of producing a
#     mis-named artifact the daemon will never see.
# All filenames are built from the canonical id, so the artifact is always
# `redis-…` even when dispatched as `service=valkey`.
canonical_service() {
  local in="${1:-}"
  case "$in" in
    valkey|redis)                                  echo redis ;;
    mysql|mariadb|postgres|meilisearch|versitygw)  echo "$in" ;;
    *) echo "lib.sh: unknown service '$in' (want valkey|redis|mysql|mariadb|postgres|meilisearch|versitygw)" >&2; return 1 ;;
  esac
}

# --- artifact naming + packaging -------------------------------------------------

# artifact_filename <service> <version> <os> <arch> -> <service>-<version>-<os>-<arch>.tar.gz
# Caller passes the already-canonicalized service id.
artifact_filename() {
  local service="$1" version="$2" os="$3" arch="$4"
  printf '%s-%s-%s-%s.tar.gz\n' "$service" "$version" "$os" "$arch"
}

# make_stage: create a fresh, empty staging root with a bin/ dir and print its path.
# The caller must register cleanup, e.g.:  stage="$(make_stage)"; trap 'rm -rf "$stage"' EXIT
make_stage() {
  local stage
  stage="$(mktemp -d "${TMPDIR:-/tmp}/yerd-stage.XXXXXX")"
  mkdir -p "$stage/bin"
  echo "$stage"
}

# require_files <dir> <relpath...>: assert each path exists under <dir> and is
# executable, so a broken build fails the runner instead of shipping a bad archive.
# On Windows the `-x` test is unreliable under Git Bash on NTFS-extracted files (it
# depends on the mount's acl/noacl mode and how the file arrived), so there we assert
# `-f` (a regular file) instead — which still catches a stray directory or a
# zero-byte/failed copy, just not the meaningless exec bit.
require_files() {
  local dir="$1"; shift
  local rel missing=0 os
  os="$(host_os)"
  for rel in "$@"; do
    if [[ ! -e "$dir/$rel" ]]; then
      echo "require_files: missing '$rel' in stage '$dir'" >&2; missing=1
    elif [[ "$os" == windows ]]; then
      [[ -f "$dir/$rel" ]] || { echo "require_files: '$rel' is not a regular file" >&2; missing=1; }
    elif [[ ! -x "$dir/$rel" ]]; then
      echo "require_files: '$rel' is not executable" >&2; missing=1
    fi
  done
  return "$missing"
}

# pack_stage <stage_dir> <out_tar>: tar the stage root (so bin/ lands at archive
# root) into out_tar as gzip. Preserves the executable bit; no absolute/.. members.
pack_stage() {
  local stage_dir="$1" out="$2" os
  os="$(host_os)"
  mkdir -p "$(dirname "$out")"
  if [[ "$os" == macos ]]; then
    chmod +x "$stage_dir"/bin/* 2>/dev/null || true
    # bsdtar: COPYFILE_DISABLE=1 stops AppleDouble ._* companions; --no-xattrs drops
    # extended attrs; the --excludes are defense-in-depth. Dashed -czf (NOT bare czf):
    # bsdtar rejects a bare mode bundle after long options.
    COPYFILE_DISABLE=1 tar --no-xattrs --exclude='.DS_Store' --exclude='._*' \
      -czf "$out" -C "$stage_dir" .
  elif [[ "$os" == windows ]]; then
    # NTFS has no exec bit; force a deterministic 0755 mode (what GNU tar writes into
    # the header) rather than relying on the ambiguous extracted bit. The WRITE path
    # uses Git's GNU tar — fine for emitting .tar.gz (MSYS paths are /c/..., no
    # drive-colon issue); only zip READS need bsdtar (see unzip_vendor).
    chmod 0755 "$stage_dir"/bin/* 2>/dev/null || true
    tar -czf "$out" -C "$stage_dir" .
  else
    chmod +x "$stage_dir"/bin/* 2>/dev/null || true
    tar -czf "$out" -C "$stage_dir" .
  fi
}

# --- macOS relocatability --------------------------------------------------------

# macos_make_relocatable <stage>: make every Mach-O under <stage> self-contained and
# runnable from an arbitrary dir. Vendors/builds on macOS often bake absolute dylib
# paths (Postgres: $prefix/lib/libpq…) or bare @loader_path/<lib> sibling refs that
# actually live in lib/ (Oracle MySQL: libprotobuf-lite). For each Mach-O we:
#   - add an LC_RPATH so @rpath resolves to <stage>/lib from that file's location,
#   - set each dylib's own id to @rpath/<name>,
#   - rewrite non-system absolute deps and bad @loader_path sibling deps to @rpath/<name>,
#   - re-sign ad-hoc (install_name_tool invalidates the signature; arm64 won't run an
#     invalidly-signed binary).
# No-op on Linux (handled there by the $ORIGIN rpath the linker bakes in).
macos_make_relocatable() {
  local stage="$1" f base dep rest reldir
  [[ "$(host_os)" == macos ]] || return 0
  while IFS= read -r f; do
    file -b "$f" | grep -q 'Mach-O' || continue
    reldir="$(python3 -c 'import os,sys;print(os.path.relpath(sys.argv[1],sys.argv[2]))' \
              "$stage/lib" "$(dirname "$f")")"
    install_name_tool -add_rpath "@loader_path/$reldir" "$f" 2>/dev/null || true
    if file -b "$f" | grep -q 'shared library'; then
      install_name_tool -id "@rpath/$(basename "$f")" "$f" 2>/dev/null || true
    fi
    while IFS= read -r dep; do
      base="${dep##*/}"
      case "$dep" in
        /usr/lib/*|/System/*|@rpath/*|@executable_path/*) : ;;
        /*) install_name_tool -change "$dep" "@rpath/$base" "$f" 2>/dev/null || true ;;
        @loader_path/*)
          rest="${dep#@loader_path/}"
          [[ "$rest" == */* ]] && continue            # already a path (../lib/…), leave it
          if [[ -e "$stage/lib/$rest" && ! -e "$(dirname "$f")/$rest" ]]; then
            install_name_tool -change "$dep" "@rpath/$base" "$f" 2>/dev/null || true
          fi
          ;;
      esac
    done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
    codesign --force --sign - "$f" 2>/dev/null || true
  done < <(find "$stage" -type f)
}

# macos_bundle_external <stage>: copy external (Homebrew/MacPorts) dylib dependencies of the
# staged Mach-O files INTO <stage>/lib so the tree is self-contained, looping to pick up
# transitive external deps. Run BEFORE macos_make_relocatable (which then rewrites the
# now-local refs to @rpath). The macOS analogue of linux_self_contain's ldd sweep. No-op off
# macOS.
#
# Two dep flavours are resolved: (a) ABSOLUTE package-manager paths (brew Cellar/opt, MacPorts),
# and (b) @rpath/<lib> deps that resolve via the file's OWN LC_RPATH entries — brew libs like
# libgeos_c reference their sibling (libgeos) by @rpath, and NOTHING links that sibling directly,
# so the absolute-only sweep would miss it (the geo stack: GEOS/GDAL). The while-changed loop
# makes both transitive.
macos_bundle_external() {
  local stage="$1" f dep base changed=1 rpdir cand brewpfx
  [[ "$(host_os)" == macos ]] || return 0
  brewpfx="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
  mkdir -p "$stage/lib"
  while [[ "$changed" -eq 1 ]]; do
    changed=0
    while IFS= read -r f; do
      file -b "$f" 2>/dev/null | grep -q 'Mach-O' || continue
      while IFS= read -r dep; do
        case "$dep" in
          /opt/homebrew/*|/usr/local/Cellar/*|/usr/local/opt/*|/opt/local/*)
            base="${dep##*/}"
            if [[ ! -e "$stage/lib/$base" ]]; then
              cp -L "$dep" "$stage/lib/$base" 2>/dev/null \
                && { chmod u+w "$stage/lib/$base" 2>/dev/null; changed=1; }
            fi
            ;;
          @rpath/*)
            base="${dep##*/}"
            if [[ ! -e "$stage/lib/$base" ]]; then
              cand=""
              # (a) Resolve against THIS file's LC_RPATH dirs (each may embed @loader_path).
              while IFS= read -r rpdir; do
                [[ -n "$rpdir" ]] || continue
                rpdir="${rpdir//@loader_path/$(dirname "$f")}"
                rpdir="${rpdir//@executable_path/$(dirname "$f")}"
                [[ -e "$rpdir/${dep#@rpath/}" ]] && { cand="$rpdir/${dep#@rpath/}"; break; }
              done < <(otool -l "$f" | awk '/ LC_RPATH$/{r=1;next} r&&/ path /{print $2;r=0}')
              # (b) Fallback: brew libs like libgeos_c carry NO rpath of their own — the resolving
              # rpath lives on the consumer. Search the brew tree for the basename.
              if [[ -z "$cand" ]]; then
                for rpdir in "$brewpfx/lib" /usr/local/lib; do
                  [[ -e "$rpdir/$base" ]] && { cand="$rpdir/$base"; break; }
                done
                [[ -z "$cand" ]] && cand="$(find "$brewpfx/Cellar" "$brewpfx/opt" -name "$base" -print -quit 2>/dev/null || true)"
              fi
              if [[ -n "$cand" && -e "$cand" ]]; then
                cp -L "$cand" "$stage/lib/$base" 2>/dev/null \
                  && { chmod u+w "$stage/lib/$base" 2>/dev/null; changed=1; }
              fi
            fi
            ;;
        esac
      done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
    done < <(find "$stage" -type f)
  done
}

# macos_self_contain_gate <stage>: fail if any staged Mach-O has a dependency that won't
# resolve on a clean Mac — an @rpath/@loader_path/@executable_path/<lib> with no matching file
# under <stage>, or an absolute path under a package-manager prefix (/opt/homebrew, /usr/local,
# /opt/local). System libs (/usr/lib, /System) are allowed. Catches the
# "rewritten-to-@rpath-but-never-bundled" dylib that a brew-equipped build machine's smoke test
# wouldn't surface. No-op off macOS.
macos_self_contain_gate() {
  local stage="$1" f dep base
  [[ "$(host_os)" == macos ]] || return 0
  while IFS= read -r f; do
    file -b "$f" 2>/dev/null | grep -q 'Mach-O' || continue
    while IFS= read -r dep; do
      case "$dep" in
        /usr/lib/*|/System/*) : ;;
        /opt/homebrew/*|/usr/local/*|/opt/local/*)
          echo "macos_self_contain_gate: ${f#"$stage"/} depends on unbundled '$dep'" >&2; return 1 ;;
        @rpath/*|@loader_path/*|@executable_path/*)
          base="${dep##*/}"
          [[ -n "$(find "$stage" -name "$base" -print -quit 2>/dev/null)" ]] || {
            echo "macos_self_contain_gate: ${f#"$stage"/} has dangling '$dep' (not bundled)" >&2; return 1; }
          ;;
        /*) echo "macos_self_contain_gate: ${f#"$stage"/} depends on non-system abs path '$dep'" >&2; return 1 ;;
      esac
    done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
  done < <(find "$stage" -type f)
}

# linux_make_relocatable <stage>: set an $ORIGIN-relative RUNPATH on every ELF under
# <stage> so binaries find bundled libs after the tree is moved. Postgres' Linux build
# bakes an ABSOLUTE rpath to its build libdir, so a relocated initdb/psql can't find
# libpq.so without this. Requires patchelf. No-op on macOS (handled by install names).
# (MySQL's Linux generic tarball is already $ORIGIN-relative, so it doesn't need this.)
linux_make_relocatable() {
  local stage="$1" f
  [[ "$(host_os)" == linux ]] || return 0
  ensure_patchelf || { echo "linux_make_relocatable: patchelf not found and could not be installed" >&2; return 1; }
  while IFS= read -r f; do
    file -b "$f" 2>/dev/null | grep -q '^ELF' || continue
    # Generous multi-entry rpath covering every file location: bin/ (-> ../lib), libs in
    # lib/ ($ORIGIN), and nested lib/postgresql/*.so reaching lib/ ($ORIGIN/..).
    patchelf --set-rpath '$ORIGIN:$ORIGIN/..:$ORIGIN/../lib:$ORIGIN/../lib/postgresql' "$f" 2>/dev/null || true
  done < <(find "$stage/bin" "$stage/lib" -type f 2>/dev/null)
}

# linux_self_contain <stage> <bin-relpath...>: make the listed Linux ELF executables run from
# an arbitrary location with NO dependency on the build host's system libs. For each binary:
# sweep its non-core shared-lib deps into <stage>/lib/private, ensure libaio, strip symbols,
# add an $ORIGIN-relative rpath, then GATE that every non-core NEEDED lib is actually bundled
# (fail loudly otherwise — else it runs on the CI host but breaks on a clean user machine).
# Shared by mysql (repackage) and mariadb (both Linux paths). No-op on macOS.
linux_self_contain() {
  local stage="$1"; shift
  [[ "$(host_os)" == linux ]] || return 0
  ensure_patchelf || true
  mkdir -p "$stage/lib/private"
  local b bins=()
  for b in "$@"; do bins+=("$stage/$b"); done

  # 1) bundle non-core deps (leave glibc core + libstdc++/libgcc to the host — ABI safety)
  local dep
  while IFS= read -r dep; do
    cp -n "$dep" "$stage/lib/private/" 2>/dev/null || true
  done < <(ldd "${bins[@]}" 2>/dev/null \
    | awk '/=> \// && !/libc\.so|libm\.so|libmvec|libpthread|libdl\.so|librt\.so|libresolv|ld-linux|linux-vdso|libstdc\+\+|libgcc_s/ {print $3}' \
    | sort -u)

  # 2) libaio.so.1 (hard-required by mysql/mariadb; time64-renamed on Ubuntu 24.04)
  ensure_libaio "$stage/lib/private" \
    || echo "linux_self_contain: could not provision libaio (gate will report)" >&2

  # 3) strip symbols (size) from the binaries + bundled .so
  strip "${bins[@]}" 2>/dev/null || true
  find "$stage/lib" -type f \( -name '*.so' -o -name '*.so.*' \) \
    -exec strip --strip-unneeded {} + 2>/dev/null || true

  # 4) rpath so the binaries find lib/private + lib regardless of any baked rpath
  if command -v patchelf >/dev/null 2>&1; then
    for b in "${bins[@]}"; do
      patchelf --add-rpath '$ORIGIN/../lib/private' "$b" 2>/dev/null || true
      patchelf --add-rpath '$ORIGIN/../lib' "$b" 2>/dev/null || true
    done
  fi

  # 5) self-containment gate over each binary
  if command -v patchelf >/dev/null 2>&1; then
    local core='^(libc|libm|libmvec|libpthread|libdl|librt|libresolv|libstdc\+\+|libgcc_s|ld-linux.*)\.so'
    local need
    for b in "${bins[@]}"; do
      while IFS= read -r need; do
        [[ -z "$need" ]] && continue
        echo "$need" | grep -Eq "$core" && continue
        find "$stage/lib" -name "$need" | grep -q . || {
          echo "linux_self_contain: required lib '$need' (needed by ${b##*/}) is not bundled." >&2
          echo "  Install it on the build host before building (e.g. 'apt-get install -y libaio1t64')." >&2
          return 1
        }
      done < <(patchelf --print-needed "$b" 2>/dev/null)
    done
  fi
}

# apt_get <args...>: run apt-get as root directly, or via sudo if not root. Many CI
# runners (root containers) have no `sudo` binary, so blindly prefixing sudo silently
# fails — this picks the right one.
apt_get() {
  if [[ "$(id -u)" -eq 0 ]]; then apt-get "$@"; else sudo apt-get "$@"; fi
}

# ensure_patchelf: install patchelf (root-aware) if absent. Used by the Linux relocation
# helpers so the build is self-sufficient regardless of the calling workflow. Returns
# non-zero if it still isn't available.
ensure_patchelf() {
  command -v patchelf >/dev/null 2>&1 && return 0
  command -v apt-get  >/dev/null 2>&1 || return 1
  apt_get install -y patchelf >/dev/null 2>&1 || true
  command -v patchelf >/dev/null 2>&1
}

# _libaio_path: print the path of a libaio shared object on the host, matching BOTH the
# classic name (libaio.so.1[.x]) and Ubuntu 24.04's time64-renamed libaio.so.1t64[.x].
# The time64 sweep renamed the SONAME but did not change the ABI.
_libaio_path() {
  local s
  s="$(ldconfig -p 2>/dev/null | grep -oE '/[^ ]*libaio\.so\.1[^ ]*' | head -1)"
  [[ -z "$s" ]] && s="$(find /usr/lib /usr/lib64 /lib /lib64 -name 'libaio.so.1*' 2>/dev/null | head -1)"
  [[ -n "$s" ]] && printf '%s\n' "$s"
}

# ensure_libaio <dest_dir>: make sure libaio.so.1 lands in <dest_dir>. MySQL's Linux
# generic binaries hard-link libaio.so.1, which a bare build env often lacks (and on
# Ubuntu 24.04 the package only provides libaio.so.1t64). Install it (root-aware) if
# absent, then copy whatever object we find as libaio.so.1 — the name mysqld's DT_NEEDED
# wants. Returns non-zero if still unavailable (caller's gate reports it).
ensure_libaio() {
  local dest="$1" src
  mkdir -p "$dest"
  src="$(_libaio_path)"
  if [[ -z "$src" ]] && command -v apt-get >/dev/null 2>&1; then
    apt_get install -y libaio1t64 >/dev/null 2>&1 \
      || apt_get install -y libaio1 >/dev/null 2>&1 || true
    src="$(_libaio_path)"
  fi
  [[ -n "$src" && -e "$src" ]] && { cp -L "$src" "$dest/libaio.so.1"; return 0; }
  return 1
}

# ensure_mariadb_build_deps: install the MariaDB-from-source toolchain (root-aware). MariaDB
# source tarballs are NOT pre-generated, so bison (3+) is mandatory. On macOS we deliberately
# do NOT install brew ncurses — the client links the system libncurses/libedit in /usr/lib
# (present on every Mac, excluded from relocation); brew ncurses would leave a dangling @rpath.
ensure_mariadb_build_deps() {
  if [[ "$(host_os)" == linux ]]; then
    command -v apt-get >/dev/null 2>&1 \
      && apt_get install -y cmake bison libncurses-dev zlib1g-dev libevent-dev libssl-dev >/dev/null 2>&1 || true
  else
    if command -v brew >/dev/null 2>&1; then
      command -v cmake >/dev/null 2>&1 || brew install cmake >/dev/null 2>&1 || true
      brew list bison    >/dev/null 2>&1 || brew install bison    >/dev/null 2>&1 || true
      brew list openssl@3 >/dev/null 2>&1 || brew install openssl@3 >/dev/null 2>&1 || true
      PATH="$(brew --prefix bison 2>/dev/null)/bin:$PATH"; export PATH
    fi
  fi
  cmake --version >/dev/null 2>&1 || { echo "ensure_mariadb_build_deps: cmake not found" >&2; return 1; }
  local bmaj
  bmaj="$(bison --version 2>/dev/null | sed -n '1s/.* //p' | cut -d. -f1)"
  [[ "${bmaj:-0}" -ge 3 ]] || { echo "ensure_mariadb_build_deps: bison >= 3 required ($(bison --version 2>/dev/null | head -1))" >&2; return 1; }
}

# ensure_cmake: install cmake (>= 3.15) if absent, root-aware. TimescaleDB's build (postgres `full`
# variant) needs it — the rest of the postgres path uses autoconf/make, so cmake isn't otherwise
# provisioned. Assert the version, since an old-distro apt cmake can be < 3.15 (GitHub runners ship a
# modern one, so the install path is rarely taken); fail loudly here rather than at configure time.
ensure_cmake() {
  if ! command -v cmake >/dev/null 2>&1; then
    if [[ "$(host_os)" == macos ]]; then
      command -v brew >/dev/null 2>&1 && brew install cmake >/dev/null 2>&1 || true
    else
      command -v apt-get >/dev/null 2>&1 && apt_get install -y cmake >/dev/null 2>&1 || true
    fi
  fi
  command -v cmake >/dev/null 2>&1 || { echo "ensure_cmake: cmake not found and could not be installed" >&2; return 1; }
  local cv cmaj cmin
  cv="$(cmake --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  cmaj="${cv%%.*}"; cmin="${cv##*.}"
  [[ "${cmaj:-0}" -gt 3 || ( "${cmaj:-0}" -eq 3 && "${cmin:-0}" -ge 15 ) ]] \
    || { echo "ensure_cmake: cmake >= 3.15 required (found ${cv:-none})" >&2; return 1; }
}

# ensure_rust: make sure `cargo` is on PATH so the meilisearch source build (a Rust project) can
# run. The meilisearch source tree pins its exact toolchain via rust-toolchain.toml, so once a
# rustup-managed cargo is reachable the right compiler is fetched automatically at build time — we
# do NOT pin a channel here (that would fight the upstream pin). GitHub runners preinstall
# rustup+cargo; this only fixes up PATH for a bare host that has cargo under the standard rustup
# home. Returns non-zero if cargo still can't be found (the caller fails loudly).
ensure_rust() {
  command -v cargo >/dev/null 2>&1 && return 0
  local c
  for c in "${CARGO_HOME:-}/bin/cargo" "$HOME/.cargo/bin/cargo"; do
    [[ -n "$c" && -x "$c" ]] && { PATH="$(dirname "$c"):$PATH"; export PATH; return 0; }
  done
  command -v cargo >/dev/null 2>&1
}

# ensure_msys2: make a POSIX toolchain reachable so the Windows redis leg can build vanilla
# Redis from source. Redis has no MSVC build — src/Makefile branches on `uname_S` for
# Linux/SunOS/Darwin/AIX/*BSD/Haiku only, and the sources need sys/mman.h, sys/un.h,
# syslog.h and sys/wait.h, none of which mingw-w64 provides — so a POSIX emulation layer is
# mandatory, not a preference. MSYS2 is preinstalled at C:\msys64 on windows-latest.
#
# STDOUT CONTRACT: prints the installation ROOT and nothing else. Callers append
# /usr/bin/bash.exe for the shell and /usr/bin for the runtime DLLs, so one value serves
# both. Every diagnostic goes to stderr — the caller captures this with
# `msys_root="$(ensure_msys2)"`, so a stray stdout line would land inside the path and turn
# both derived values into garbage. Same shape as _vs_dir, which emits only the path.
#
# Returns non-zero when unavailable so the caller fails loudly (the ensure_rust contract).
# No-op off Windows: the arm that calls this is inside the windows branch.
ensure_msys2() {
  [[ "$(host_os)" == windows ]] || return 0
  local root="${MSYS2_ROOT:-/c/msys64}" bash_exe
  bash_exe="$root/usr/bin/bash.exe"
  [[ -x "$bash_exe" ]] || {
    echo "ensure_msys2: no MSYS2 bash at $bash_exe (set MSYS2_ROOT)" >&2
    return 1
  }
  # --needed makes this a no-op when the packages are already present, so a preinstalled
  # runner costs nothing. Failure is tolerated here and caught by the gcc probe below:
  # pacman can exit non-zero on a runtime self-update while still leaving a usable gcc.
  "$bash_exe" -lc 'pacman -S --noconfirm --needed gcc make' >&2 2>&1 || true
  "$bash_exe" -lc 'command -v gcc >/dev/null' || {
    echo "ensure_msys2: gcc not available in MSYS2 after pacman install" >&2
    return 1
  }
  # Diagnostics to STDERR — they belong in the build log, not in the caller's variable.
  "$bash_exe" -lc 'gcc --version | head -1; pacman -Q msys2-runtime' >&2 2>&1 || true
  printf '%s\n' "$root"
}

# ensure_mariadb_runtime_deps: install the linux-systemd bintar's runtime chain (root-aware) so
# linux_self_contain's ldd sweep can bundle it. Tolerant per package (names vary across releases).
ensure_mariadb_runtime_deps() {
  [[ "$(host_os)" == linux ]] || return 0
  command -v apt-get >/dev/null 2>&1 || return 0
  local p
  for p in libsystemd-dev liblzma5 libzstd1 liblz4-1 libcap2 libgcrypt20; do
    apt_get install -y "$p" >/dev/null 2>&1 || true
  done
}

# ensure_postgis_deps: install the geo stack + the libs the `full` postgres configure needs
# (OpenSSL/libxml/uuid/PCRE for pgcrypto/uuid-ossp/xml2/address_standardizer, and
# GEOS/PROJ/GDAL/json-c/protobuf-c for PostGIS-with-raster), root-aware. Tolerant per package
# (names vary across releases); the caller's configure/build fails loudly if something's absent.
# On macOS, keg-only formulae (openssl@3, libxml2) are surfaced to configure via PKG_CONFIG_PATH
# + the caller's --with-includes/--with-libraries; we do NOT install ossp-uuid (the full build
# configures --with-uuid=e2fs, whose API macOS provides in the base system).
ensure_postgis_deps() {
  if [[ "$(host_os)" == linux ]]; then
    command -v apt-get >/dev/null 2>&1 || { echo "ensure_postgis_deps: apt-get unavailable" >&2; return 1; }
    apt_get update >/dev/null 2>&1 || true
    # bison/flex: the full variant recompiles postgres (configure hard-requires them on PG17);
    # xsltproc: PostGIS's build generates postgis_comments.sql via XSLT. These are preinstalled on
    # GitHub runners but NOT on minimal images, so provision them for a self-sufficient build.
    apt_get install -y \
      pkg-config bison flex xsltproc libssl-dev uuid-dev libxml2-dev libpcre2-dev \
      libgeos-dev libproj-dev libgdal-dev libjson-c-dev libprotobuf-c-dev protobuf-c-compiler \
      >/dev/null 2>&1 || true
    # Hard-require the load-bearing configs so a silent apt miss fails here, not mid-build.
    command -v geos-config >/dev/null 2>&1 && command -v gdal-config >/dev/null 2>&1 && command -v proj >/dev/null 2>&1 \
      || { echo "ensure_postgis_deps: geos/gdal/proj dev packages missing after apt" >&2; return 1; }
  else
    command -v brew >/dev/null 2>&1 || { echo "ensure_postgis_deps: brew unavailable" >&2; return 1; }
    local f
    for f in pkg-config openssl@3 libxml2 pcre2 geos proj gdal json-c protobuf-c; do
      brew list "$f" >/dev/null 2>&1 || brew install "$f" >/dev/null 2>&1 || true
    done
    # Surface keg-only openssl@3 + libxml2 to pg_config/pkg-config-driven configure.
    local ic
    ic="$(brew --prefix openssl@3 2>/dev/null)/lib/pkgconfig:$(brew --prefix libxml2 2>/dev/null)/lib/pkgconfig"
    PKG_CONFIG_PATH="${ic}${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"; export PKG_CONFIG_PATH
    command -v geos-config >/dev/null 2>&1 && command -v gdal-config >/dev/null 2>&1 \
      || { echo "ensure_postgis_deps: geos/gdal missing after brew" >&2; return 1; }
  fi
}

# postgis_win_url <pg_major> [postgis_ver]: the prebuilt, self-contained OSGeo PostGIS bundle
# for the EDB PostgreSQL <pg_major> (carries its own GEOS/PROJ/GDAL/libxml DLLs + data). The
# exact PostGIS version isn't derivable from the pg major, and OSGeo hosts only the *current*
# bundle per major (no version archive) — so a POSTGIS_WIN_UPSTREAM pin goes stale the moment
# they publish a newer one. Prefer the pin when set (and still present); otherwise scrape the
# per-major directory listing and take the highest bundle version there.
postgis_win_url() {
  local pgmaj="$1" pv="${2:-${POSTGIS_WIN_UPSTREAM:-}}" dir url
  dir="https://download.osgeo.org/postgis/windows/pg${pgmaj}/"
  if [[ -n "$pv" ]]; then
    url="${dir}postgis-bundle-pg${pgmaj}-${pv}x64.zip"
    _url_ok "$url" && { echo "$url"; return 0; }
    echo "postgis_win_url: pinned POSTGIS_WIN_UPSTREAM '$pv' not found: $url" >&2
    return 1
  fi
  # Auto-discover: OSGeo keeps only the latest bundle per pg major, so scrape the listing and
  # pick the highest version present (sort -V). Pin POSTGIS_WIN_UPSTREAM to override.
  pv="$(curl -fsSL "$dir" 2>/dev/null \
        | grep -oE "postgis-bundle-pg${pgmaj}-[0-9.]+x64\.zip" \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
        | sort -V | tail -1)"
  [[ -n "$pv" ]] || { echo "postgis_win_url: no bundle found under $dir (set POSTGIS_WIN_UPSTREAM to pin)" >&2; return 1; }
  url="${dir}postgis-bundle-pg${pgmaj}-${pv}x64.zip"
  _url_ok "$url" || { echo "postgis_win_url: not found: $url" >&2; return 1; }
  echo "$url"
}

# _linux_core_lib_re: the shared allowlist of libs we deliberately DO NOT bundle — glibc core +
# the C++/GCC runtime (ABI-tied to the host toolchain; bundling them causes more breakage than it
# fixes). Kept in one place so the geo bundler and its gate agree with linux_self_contain.
_linux_core_lib_re='libc\.so|libm\.so|libmvec|libpthread|libdl\.so|librt\.so|libresolv|ld-linux|linux-vdso|libstdc\+\+|libgcc_s'

# linux_bundle_all <stage> <seed-relpath...>: bundle the FULL transitive shared-lib closure of the
# seed ELF files into <stage>/lib so a relocated tree resolves everything with no host deps. For a
# heavy chain (PostGIS -> GEOS/PROJ/GDAL -> curl/sqlite/tiff/...) where the modules live in
# lib/postgresql/, this + linux_make_relocatable (which stamps $ORIGIN-relative RUNPATH on every
# staged ELF, reaching lib/ from lib/postgresql/ via $ORIGIN/..) replaces linux_self_contain's
# bin/-only lib/private scheme. ldd is transitive, so one pass per seed yields the whole closure.
#
# Collision policy (a distro libgdal drags its OWN libpq.so.5/libxml2 sharing sonames with the
# source-built libs we already cp -R'd into lib/): for a dep whose dest already exists —
#   (1) identical content            -> skip (debug);
#   (2) staged copy is ours          -> keep ours, WARN (naming the shadowed system path);
#   (3) differs and neither is ours  -> hard-fail.
# Keep-first is an explicit -e test (NOT cp -n: coreutils 9.2-9.4 exit 1 on a skip -> set -e abort).
linux_bundle_all() {
  local stage="$1"; shift
  [[ "$(host_os)" == linux ]] || return 0
  mkdir -p "$stage/lib"
  local seed dep dest base
  for seed in "$@"; do
    while IFS= read -r dep; do
      [[ -n "$dep" && -e "$dep" ]] || continue
      base="${dep##*/}"
      echo "$base" | grep -Eq "$_linux_core_lib_re" && continue
      dest="$stage/lib/$base"
      if [[ -e "$dest" ]]; then
        if cmp -s "$dep" "$dest"; then
          :                                            # (1) identical — already bundled
        elif [[ "$dep" == "$stage/"* || "$dep" == *"/pgi_full/"* ]]; then
          :                                            # our own copy is the source — nothing to do
        else
          # dest exists, differs, and the incoming copy is a *system* lib -> ours wins (case 2).
          echo "linux_bundle_all: keeping staged $base; not overwriting with system '$dep'" >&2
        fi
        continue
      fi
      cp -L "$dep" "$dest" 2>/dev/null && chmod u+w "$dest" 2>/dev/null || true
    done < <(ldd "$stage/$seed" 2>/dev/null | awk '/=> \// {print $3}' | sort -u)
  done
}

# linux_gate_all_elf <stage>: fail unless every non-core NEEDED lib of every ELF under bin/ AND
# lib/ is bundled in <stage>/lib. The all-ELF scope (vs linux_self_contain's named-bins-only gate)
# is what catches an unbundled transitive dep of a lib/postgresql/*.so — the failure the geo chain
# would otherwise hide behind the build host's system libs.
linux_gate_all_elf() {
  local stage="$1" f need
  [[ "$(host_os)" == linux ]] || return 0
  command -v patchelf >/dev/null 2>&1 || { echo "linux_gate_all_elf: patchelf unavailable" >&2; return 1; }
  local rc=0
  while IFS= read -r f; do
    file -b "$f" 2>/dev/null | grep -q '^ELF' || continue
    while IFS= read -r need; do
      [[ -z "$need" ]] && continue
      echo "$need" | grep -Eq "$_linux_core_lib_re" && continue
      find "$stage/lib" -name "$need" | grep -q . || {
        echo "linux_gate_all_elf: '$need' (needed by ${f#"$stage"/}) is not bundled." >&2; rc=1; }
    done < <(patchelf --print-needed "$f" 2>/dev/null)
  done < <(find "$stage/bin" "$stage/lib" -type f 2>/dev/null)
  return "$rc"
}

# --- Windows: extraction, runtime bundling, self-containment ---------------------

# unzip_vendor <zip> <dest>: extract a vendor .zip into <dest>. Git Bash's `tar` is
# GNU tar (/usr/bin/tar), which does NOT read zip and SHADOWS the System32 bsdtar on
# PATH, so we invoke the Windows system bsdtar by absolute path (resolved defensively —
# the Windows SystemRoot value is a backslashed C:\Windows that bash can't path-resolve
# and may be unset). 7-Zip (preinstalled on GitHub windows runners) is the fallback.
# `unzip` is intentionally not used (not guaranteed in Git Bash). No-op-safe off Windows.
unzip_vendor() {
  [[ "$(host_os)" == windows ]] || return 0   # honor the "No-op-safe off Windows" header
  local zip="$1" dest="$2" sysroot bsdtar
  mkdir -p "$dest"
  sysroot="${SYSTEMROOT:-${WINDIR:-C:\\Windows}}"
  if command -v cygpath >/dev/null 2>&1; then sysroot="$(cygpath -u "$sysroot")"; fi
  bsdtar="$sysroot/System32/tar.exe"
  if [[ -x "$bsdtar" ]]; then
    "$bsdtar" -xf "$zip" -C "$dest"
  elif command -v 7z >/dev/null 2>&1; then
    7z x -y -o"$dest" "$zip" >/dev/null
  else
    echo "unzip_vendor: no zip extractor found (need System32 tar.exe/bsdtar or 7z)" >&2
    return 1
  fi
}

# vendor_root <extract_dir> [expected_subdir]: print the directory that holds bin/.
# Some vendor zips nest everything under a single top-level dir (mysql/mariadb under
# <name>-winx64/, EDB under pgsql/); others (the tporadowski Redis zip) are flat. We
# locate the dir that actually contains a bin/ so callers don't hard-code layouts.
vendor_root() {
  local dir="$1" want="${2:-}"
  if [[ -n "$want" && -d "$dir/$want/bin" ]]; then echo "$dir/$want"; return 0; fi
  if [[ -d "$dir/bin" || -e "$dir/redis-server.exe" ]]; then echo "$dir"; return 0; fi
  local d
  for d in "$dir"/*/; do
    [[ -d "${d}bin" || -e "${d}redis-server.exe" ]] && { echo "${d%/}"; return 0; }
  done
  echo "vendor_root: no bin/ found under '$dir'" >&2
  return 1
}

# _vs_dir: print the VS install dir via vswhere (preinstalled on windows-latest). The
# env var holding the x86 Program Files path has parens in its name (PROGRAMFILES(X86)),
# which bash can't reference via ${...}, so we read it through `printenv` and fall back
# to the canonical path.
_vs_dir() {
  local pfx86 vswhere p
  pfx86="$(printenv 'ProgramFiles(x86)' 2>/dev/null | tr -d '\r')"
  [[ -n "$pfx86" ]] && command -v cygpath >/dev/null 2>&1 && pfx86="$(cygpath -u "$pfx86")"
  [[ -n "$pfx86" ]] || pfx86="/c/Program Files (x86)"
  vswhere="$pfx86/Microsoft Visual Studio/Installer/vswhere.exe"
  [[ -x "$vswhere" ]] || return 1
  p="$("$vswhere" -latest -products '*' -property installationPath 2>/dev/null | tr -d '\r')"
  [[ -n "$p" ]] || return 1
  command -v cygpath >/dev/null 2>&1 && p="$(cygpath -u "$p")"
  printf '%s\n' "$p"
}

# windows_bundle_runtime <stage>: copy the VC++ runtime redist DLLs into <stage>/bin so
# the artifact runs on a clean Win10+ box that lacks the VC++ Redistributable. Bundle
# only the DLLs that exist for the installed toolset (vcruntime140_1.dll/concrt140.dll
# are newer-only). UCRT (ucrtbase/api-ms-win-*) ships with Windows 10+, so it is NOT
# bundled. No-op off Windows.
windows_bundle_runtime() {
  local stage="$1" vs redist crtdir f copied=0
  [[ "$(host_os)" == windows ]] || return 0
  mkdir -p "$stage/bin"
  # In CI, inability to bundle the runtime is a hard error (windows-latest always has VS):
  # fail here with a clear message rather than letting the gate report it one step later as
  # an "imports unbundled vcruntime140.dll". Best-effort (warn + continue) only locally.
  local ci_fail=0; [[ -n "${GITHUB_ACTIONS:-}${CI:-}" ]] && ci_fail=1
  vs="$(_vs_dir)" || { echo "windows_bundle_runtime: VS install not found (vswhere)" >&2; return "$ci_fail"; }
  # Newest x64 CRT redist dir (…/VC/Redist/MSVC/<ver>/x64/Microsoft.VC*.CRT).
  crtdir="$(ls -d "$vs"/VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT 2>/dev/null | sort -V | tail -1)"
  [[ -n "$crtdir" && -d "$crtdir" ]] || { echo "windows_bundle_runtime: no CRT redist dir under $vs" >&2; return "$ci_fail"; }
  # Copy the whole CRT redist folder's DLLs, not a hardcoded allowlist: msvcp140* /
  # vcruntime140* / concrt140 plus their satellites (msvcp140_atomic_wait.dll,
  # msvcp140_codecvt_ids.dll, …) that newer engines import. A per-file list silently breaks
  # the self-contain gate whenever an engine picks up a CRT satellite it didn't before
  # (e.g. MySQL 9.7's mysqld.exe → msvcp140_atomic_wait.dll). UCRT (ucrtbase/api-ms-win-*)
  # ships with Windows 10+, so it is NOT here (the folder doesn't contain it).
  for f in "$crtdir"/*.dll; do
    [[ -e "$f" ]] || continue   # nullglob-safe: literal pattern when the folder is empty
    cp -f "$f" "$stage/bin/"; copied=1
  done
  [[ "$copied" == 1 ]] || { echo "windows_bundle_runtime: no DLLs found in $crtdir" >&2; return "$ci_fail"; }
  # Redistribution of these DLLs is licensed by the folder-level grant for VC\Redist
  # (https://aka.ms/vs/17/redist.txt), not a per-file enumeration; they come straight from
  # that folder as a unit. (On Build Tools the on-disk Redist.txt is just a pointer to that URL.)
  echo ">> windows_bundle_runtime: from $crtdir (license: https://aka.ms/vs/17/redist.txt)"
}

# _dumpbin: print the absolute path to dumpbin.exe. Invoke it by that full path — Windows
# loads dumpbin's sibling MSVC DLLs from its own directory automatically, so no PATH setup
# is needed (and any export here would die with the command-substitution subshell anyway).
_dumpbin() {
  local vs binroot
  vs="$(_vs_dir)" || return 1
  binroot="$(ls -d "$vs"/VC/Tools/MSVC/*/bin/Hostx64/x64 2>/dev/null | sort -V | tail -1)"
  [[ -n "$binroot" && -x "$binroot/dumpbin.exe" ]] || return 1
  printf '%s\n' "$binroot/dumpbin.exe"
}

# windows_self_contain_gate <stage>: fail if any staged .exe imports a non-system DLL
# that is not bundled in bin/. Analogue of macos_self_contain_gate — the smoke test runs
# on a redist-equipped runner, so it proves "runs on a dev box," NOT self-containment.
# MANDATORY in CI: if dumpbin can't be resolved while GITHUB_ACTIONS/CI is set, hard-fail
# (dumpbin + vswhere are always present on windows-latest). Best-effort no-op only locally.
windows_self_contain_gate() {
  local stage="$1" db f dep base lc
  [[ "$(host_os)" == windows ]] || return 0
  db="$(_dumpbin)" || {
    if [[ -n "${GITHUB_ACTIONS:-}${CI:-}" ]]; then
      echo "windows_self_contain_gate: dumpbin not resolvable in CI (must be present on windows-latest)" >&2
      return 1
    fi
    echo "windows_self_contain_gate: dumpbin unavailable; skipping (local best-effort)" >&2
    return 0
  }
  shopt -s nocasematch
  local rc=0 deps_out
  while IFS= read -r f; do
    deps_out="$("$db" -dependents "$f" 2>/dev/null | sed -n '/following dependencies/,/Summary/p')"
    # Every PE has at least KERNEL32 — empty output means dumpbin failed or the binary is
    # unreadable/locked. Don't let that vacuously "pass" the gate in CI.
    if [[ -z "$deps_out" ]]; then
      if [[ -n "${GITHUB_ACTIONS:-}${CI:-}" ]]; then
        echo "windows_self_contain_gate: no dependency output for ${f#"$stage"/} (dumpbin failed?)" >&2
        rc=1
      fi
      continue
    fi
    while IFS= read -r dep; do
      dep="$(echo "$dep" | tr -d '\r' | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
      [[ "$dep" == *.dll ]] || continue   # nocasematch makes this match .DLL/.Dll too
      base="${dep##*/}"
      # OS DLLs shipped with Windows 10+. NOTE: msvcrt.dll (versionless) IS the OS C
      # runtime, but the VC++ redist family (vcruntime140*/msvcp140*/concrt140*/msvcrNNN)
      # is deliberately NOT here — it must be bundled, so it falls through to the
      # bundled-in-bin/ check below (catches the "installed on the runner but not on a
      # clean user box" case, the Windows analogue of the macOS-brew gate).
      # (pdh.dll = Performance Data Helper, a System32 component present on all Windows;
      # meilisearch.exe pulls it in via the `sysinfo` crate — it is NOT redistributable/bundleable.)
      case "$base" in
        kernel32.dll|kernelbase.dll|kernel.appcore.dll|ntdll.dll|advapi32.dll|sechost.dll|\
        rpcrt4.dll|user32.dll|win32u.dll|gdi32.dll|gdi32full.dll|shell32.dll|shlwapi.dll|\
        shcore.dll|ole32.dll|oleaut32.dll|combase.dll|comdlg32.dll|comctl32.dll|\
        ws2_32.dll|wsock32.dll|mswsock.dll|dnsapi.dll|iphlpapi.dll|winhttp.dll|wininet.dll|\
        secur32.dll|sspicli.dll|crypt32.dll|bcrypt.dll|bcryptprimitives.dll|ncrypt.dll|\
        cryptbase.dll|cryptsp.dll|netapi32.dll|authz.dll|userenv.dll|version.dll|winmm.dll|\
        psapi.dll|setupapi.dll|cfgmgr32.dll|powrprof.dll|pdh.dll|profapi.dll|normaliz.dll|\
        dbghelp.dll|dbgcore.dll|imagehlp.dll|msvcrt.dll|ucrtbase.dll|\
        wldap32.dll|wtsapi32.dll|wintrust.dll|cabinet.dll|mpr.dll|samlib.dll|dsrole.dll|\
        api-ms-win-*|ext-ms-*) continue ;;
      esac
      lc="$(echo "$base" | tr '[:upper:]' '[:lower:]')"
      # Only bin/ counts: the Windows loader resolves an exe's import-table DLLs from the
      # exe's own dir (bin/), system dirs, and PATH — NOT a sibling lib/. (lib/ DLLs are
      # server-loaded plugins resolved by the engine itself, not import-table deps.)
      if [[ -z "$(find "$stage/bin" -iname "$lc" -print -quit 2>/dev/null)" ]]; then
        echo "windows_self_contain_gate: ${f#"$stage"/} imports unbundled '$base'" >&2
        rc=1
      fi
    done <<< "$deps_out"
  done < <(find "$stage/bin" -iname '*.exe' -type f)
  shopt -u nocasematch
  return "$rc"
}

# --- downloads -------------------------------------------------------------------

# fetch_to <url> <out>: download url to out with retries. Fails loudly on HTTP errors.
fetch_to() {
  local url="$1" out="$2"
  curl -fsSL --retry 3 --retry-delay 2 -o "$out" "$url"
}

# _url_ok <url>: true if the URL resolves to a 2xx (follows redirects, HEAD only).
_url_ok() {
  curl -fsIL -o /dev/null "$1"
}

# mysql_generic_url <upstream> <os> <arch>: echo the resolved download URL for the
# Oracle MySQL generic binary tarball matching the host platform, or fail loudly.
#
# Filenames (verified against cdn.mysql.com):
#   linux: mysql-<up>-linux-glibc2.28-<x86_64|aarch64>.tar.xz
#   macos: mysql-<up>-macos<NN>-arm64.tar.gz   (macOS uses 'arm64', our token is 'aarch64';
#          the macos<NN> build-OS tag changes per release, so probe NN in {15,14,13})
# Base dir is MySQL-<maj.min> (e.g. MySQL-8.4); cdn.mysql.com first, dev.mysql.com mirror.
mysql_generic_url() {
  local up="$1" os="$2" arch="$3"
  local majmin file
  majmin="$(printf '%s\n' "$up" | cut -d. -f1,2)"

  local -a files=()
  case "$os" in
    linux)
      files=("mysql-${up}-linux-glibc2.28-${arch}.tar.xz")
      ;;
    macos)
      # we only build macOS on arm64
      local nn
      for nn in 15 14 13; do
        files+=("mysql-${up}-macos${nn}-arm64.tar.gz")
      done
      ;;
    *) echo "mysql_generic_url: unsupported os '$os'" >&2; return 1 ;;
  esac

  local f base url
  for f in "${files[@]}"; do
    for base in "https://cdn.mysql.com/Downloads/MySQL-${majmin}" \
                "https://dev.mysql.com/get/Downloads/MySQL-${majmin}"; do
      url="$base/$f"
      if _url_ok "$url"; then echo "$url"; return 0; fi
    done
  done
  echo "mysql_generic_url: no MySQL generic tarball found for $up $os $arch" >&2
  return 1
}

# --- Windows vendor download URLs (x86_64 only) ----------------------------------
# These resolve the official Windows binary archives we repackage. All use _url_ok HEAD
# probes and fail loudly so a bad version aborts the leg instead of producing nothing.

# mysql_win_url <upstream>: Oracle MySQL winx64 zip. Same cdn/dev base as the generic
# tarball; asserts the EXACT mysql-<up>-winx64.zip (not the -winx64-debug-test sibling).
mysql_win_url() {
  local up="$1" majmin base url
  majmin="$(printf '%s\n' "$up" | cut -d. -f1,2)"
  for base in "https://cdn.mysql.com/Downloads/MySQL-${majmin}" \
              "https://dev.mysql.com/get/Downloads/MySQL-${majmin}"; do
    url="$base/mysql-${up}-winx64.zip"
    if _url_ok "$url"; then echo "$url"; return 0; fi
  done
  echo "mysql_win_url: no MySQL winx64 zip found for $up" >&2
  return 1
}

# mariadb_win_url <upstream>: MariaDB winx64 zip from archive.mariadb.org. EXACT filename
# (the same dir also holds the much larger -winx64-debugsymbols.zip — never glob).
mariadb_win_url() {
  local up="$1" url
  url="https://archive.mariadb.org/mariadb-${up}/winx64-packages/mariadb-${up}-winx64.zip"
  _url_ok "$url" || { echo "mariadb_win_url: not found: $url" >&2; return 1; }
  echo "$url"
}

# postgres_win_url <upstream> [buildno]: EDB PostgreSQL windows-x64 binaries zip. The
# build-number suffix <N> isn't derivable from <up>; prefer an explicit buildno (from the
# workflow's postgres_win_buildno input / POSTGRES_WIN_BUILDNO), else probe N highest-first.
postgres_win_url() {
  local up="$1" buildno="${2:-${POSTGRES_WIN_BUILDNO:-}}" n url
  if [[ -n "$buildno" ]]; then
    url="https://get.enterprisedb.com/postgresql/postgresql-${up}-${buildno}-windows-x64-binaries.zip"
    _url_ok "$url" && { echo "$url"; return 0; }
    echo "postgres_win_url: pinned buildno '$buildno' not found: $url" >&2
    return 1
  fi
  for n in $(seq 25 -1 1); do
    url="https://get.enterprisedb.com/postgresql/postgresql-${up}-${n}-windows-x64-binaries.zip"
    if _url_ok "$url"; then echo "$url"; return 0; fi
  done
  echo "postgres_win_url: no EDB windows-x64 binaries zip found for $up (set postgres_win_buildno or supply a direct URL)" >&2
  return 1
}

# --- windows redis: vanilla Redis source, version+hash pinned together ------------
#
# The Windows leg of the `redis` slot builds VANILLA Redis from source (see the windows
# `redis)` arm in build-service.sh). It is not Valkey — valkey has no Windows build — and
# it is no longer the tporadowski MSVC port, which is EOL at 5.0.14.1 (pre-ACL, pre-RESP3,
# pre-functions) and unpatched.
#
# 7.2.x IS THE CEILING, for licensing: Redis 1.0-7.2 is BSD-3-Clause and freely
# redistributable; 7.4-7.8 is RSALv2/SSPLv1; 8.0+ adds AGPLv3 to that pair. 7.2.x is
# therefore the newest freely redistributable line. Do NOT raise these past 7.2.
#
# VERSION AND HASH ARE PINNED TOGETHER, DELIBERATELY. They are a matched pair, so a bump is
# one reviewed commit touching both lines — the hash lands in version control beside the
# version it pins, rather than being typed into a dispatch box where a stale or mistyped
# value is invisible. There is intentionally NO per-version table and NO workflow input for
# the hash: dispatching a non-default REDIS_WIN_UPSTREAM fails loudly (see
# redis_win_sha256) and directs the operator here.
REDIS_WIN_UPSTREAM_DEFAULT="7.2.15"
# sha256 of https://download.redis.io/releases/redis-7.2.15.tar.gz, verbatim from
# https://github.com/redis/redis-hashes (the project's own published hash list).
REDIS_WIN_SHA256_DEFAULT="7bf7975331511fdb788e85dae63964b128fccee1df026a10db57444babc9c9c4"

# redis_win_url <upstream>: the official Redis source tarball. download.redis.io is the
# canonical distribution — redis/redis publishes no release assets for 7.2.x, so the
# GitHub auto-generated tag tarball is not the authoritative artifact (and its bytes are
# not contractually stable, which would make a pinned hash a maintenance liability).
redis_win_url() {
  local up="$1" url
  url="https://download.redis.io/releases/redis-${up}.tar.gz"
  _url_ok "$url" || { echo "redis_win_url: not found: $url" >&2; return 1; }
  echo "$url"
}

# redis_win_sha256 <upstream>: the pinned digest for <upstream>, or a loud failure telling
# the operator how to pin a new one. Only the version pinned above has a recorded hash —
# that is the point: an unpinned version must not build silently unverified.
redis_win_sha256() {
  local up="$1"
  if [[ "$up" == "$REDIS_WIN_UPSTREAM_DEFAULT" ]]; then
    printf '%s\n' "$REDIS_WIN_SHA256_DEFAULT"
    return 0
  fi
  cat >&2 <<EOF
redis_win_sha256: no pinned sha256 for Redis '$up' (pinned version is $REDIS_WIN_UPSTREAM_DEFAULT).
Bumping the Windows redis version is a code change, not a dispatch parameter: update
REDIS_WIN_UPSTREAM_DEFAULT and REDIS_WIN_SHA256_DEFAULT together in scripts/lib.sh, taking
the digest from https://github.com/redis/redis-hashes. Keep it <= 7.2.x (7.4+ is RSALv2/SSPL).
EOF
  return 1
}
