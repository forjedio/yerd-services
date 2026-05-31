#!/usr/bin/env bash
#
# gen-index.sh — read artifact filenames on stdin, emit the listing page on stdout.
#
# This is the daemon's listing: GitHub Releases has no directory autoindex, so we
# publish a generated index.html that the consumer tokenises to discover artifact
# filenames. One <a href> per name.
#
# Input is the live *.tar.gz asset set (already filtered by the caller, so
# index.html / services.json exclude themselves). Names are restricted to
# [A-Za-z0-9._-], so no HTML escaping is required. Empty input still yields a valid
# (header-only) page.

set -euo pipefail

printf '<!doctype html><meta charset=utf-8><title>yerd services</title>\n'

# sort for stable, low-noise output; skip blank lines.
sort | while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  printf '<a href="%s">%s</a>\n' "$name" "$name"
done
