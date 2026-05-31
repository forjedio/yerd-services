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
