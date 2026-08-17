#!/usr/bin/env bash
#
# gen-manifest.sh — read artifact filenames on stdin, emit services.json on stdout.
#
# services.json is THE listing: GitHub Releases has no directory autoindex, so the
# daemon fetches this machine-readable manifest to discover what's installable.
#
# Derived purely from the live *.tar.gz asset filenames,
# grouped service -> version -> [platforms]:
#
#   {"schema":1,"services":{"redis":{"versions":[
#       {"version":"8","platforms":["linux-aarch64","linux-x86_64","macos-aarch64"]}
#   ]}}}
#
# It carries only what filenames encode (service, version, platforms) — no
# upstream/build-flags/status (those aren't in the names; provenance lives in
# README.md). Hard-remove model: deleting a version's assets drops it here for free.
#
# Filenames are [A-Za-z0-9._-] only, so values need no JSON escaping.
# Empty input -> {"schema":1,"services":{}}.

set -euo pipefail

# Parse each filename into  service<TAB>version<TAB>os-arch  (one line per artifact).
# Anchored on the contract shape: <service>-<version>-<os>-<arch>.tar.gz, where os/arch
# are closed token sets containing no '-', so the version (which MAY contain '-') is
# unambiguously the middle. Lines that don't match the contract shape are skipped.
emit_triples() {
  local name base arch rest os rest2 service version
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    [[ "$name" == *.tar.gz ]] || continue
    base="${name%.tar.gz}"
    arch="${base##*-}";  rest="${base%-*}";   [[ "$rest"  != "$base" ]] || continue
    os="${rest##*-}";    rest2="${rest%-*}";  [[ "$rest2" != "$rest" ]] || continue
    service="${rest2%%-*}"; version="${rest2#*-}"; [[ "$version" != "$rest2" ]] || continue
    case "$os"      in linux|macos|windows) ;;    *) continue ;; esac
    case "$arch"    in x86_64|aarch64) ;;         *) continue ;; esac
    case "$service" in redis|mysql|mariadb|postgres|meilisearch|versitygw) ;; *) continue ;; esac
    printf '%s\t%s\t%s-%s\n' "$service" "$version" "$os" "$arch"
  done
}

# Sort triples. Tab (0x09) < any version-legal char, so "service\tversion\t" is a
# clean boundary: no other version can interleave a (service,version) run. LC_ALL=C
# for deterministic byte order.
parsed="$(emit_triples | LC_ALL=C sort)"

printf '{"schema":1,"services":{'

prev_service=""
prev_version=""
while IFS=$'\t' read -r service version platform; do
  [[ -n "$service" ]] || continue
  if [[ "$service" != "$prev_service" ]]; then
    if [[ -n "$prev_service" ]]; then
      printf ']}'   # close platforms[] + current version{}
      printf ']}'   # close versions[] + current service{}
      printf ','    # separator before the next service
    fi
    printf '"%s":{"versions":[' "$service"
    printf '{"version":"%s","platforms":[' "$version"
    printf '"%s"' "$platform"
    prev_service="$service"
    prev_version="$version"
  elif [[ "$version" != "$prev_version" ]]; then
    printf ']}'     # close platforms[] + previous version{}
    printf ','      # separator before the next version
    printf '{"version":"%s","platforms":[' "$version"
    printf '"%s"' "$platform"
    prev_version="$version"
  else
    printf ',"%s"' "$platform"
  fi
done < <(printf '%s\n' "$parsed")

if [[ -n "$prev_service" ]]; then
  printf ']}'       # close platforms[] + last version{}
  printf ']}'       # close versions[] + last service{}
fi

printf '}}\n'
