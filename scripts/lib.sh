#!/usr/bin/env bash
#
# lib.sh — shared helpers and the single source of the producer-side artifact
# contract (see the "Artifact contract" section of README.md).
#
# Dependency-free: bash, curl, tar, uname (+ make for the redis recipe).
# Source this from the other scripts; it is not meant to be executed directly.

set -euo pipefail

# --- platform tokens ------------------------------------------------------------

# host_os: map `uname -s` to the contract os token. Fails loudly on anything else.
host_os() {
  local s
  s="$(uname -s)"
  case "$s" in
    Darwin) echo macos ;;
    Linux)  echo linux ;;
    *) echo "lib.sh: unsupported OS '$s' (want Darwin|Linux)" >&2; return 1 ;;
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
#   - redis|mysql|mariadb|postgres pass through unchanged.
#   - anything else is rejected, so a typo fails loudly instead of producing a
#     mis-named artifact the daemon will never see.
# All filenames are built from the canonical id, so the artifact is always
# `redis-…` even when dispatched as `service=valkey`.
canonical_service() {
  local in="${1:-}"
  case "$in" in
    valkey|redis)            echo redis ;;
    mysql|mariadb|postgres)  echo "$in" ;;
    *) echo "lib.sh: unknown service '$in' (want valkey|redis|mysql|mariadb|postgres)" >&2; return 1 ;;
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
require_files() {
  local dir="$1"; shift
  local rel missing=0
  for rel in "$@"; do
    if [[ ! -e "$dir/$rel" ]]; then
      echo "require_files: missing '$rel' in stage '$dir'" >&2; missing=1
    elif [[ ! -x "$dir/$rel" ]]; then
      echo "require_files: '$rel' is not executable" >&2; missing=1
    fi
  done
  return "$missing"
}

# pack_stage <stage_dir> <out_tar>: tar the stage root (so bin/ lands at archive
# root) into out_tar as gzip. Preserves the executable bit; no absolute/.. members.
pack_stage() {
  local stage_dir="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  chmod +x "$stage_dir"/bin/* 2>/dev/null || true
  if [[ "$(host_os)" == macos ]]; then
    # bsdtar: COPYFILE_DISABLE=1 stops AppleDouble ._* companions; --no-xattrs drops
    # extended attrs; the --excludes are defense-in-depth. Dashed -czf (NOT bare czf):
    # bsdtar rejects a bare mode bundle after long options.
    COPYFILE_DISABLE=1 tar --no-xattrs --exclude='.DS_Store' --exclude='._*' \
      -czf "$out" -C "$stage_dir" .
  else
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
# macOS. (Libs that reference siblings via @loader_path are fine here because the binaries link
# both directly, so both get copied.)
macos_bundle_external() {
  local stage="$1" f dep base changed=1
  [[ "$(host_os)" == macos ]] || return 0
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
