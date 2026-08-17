#!/usr/bin/env bash
#
# Upload one file to a Bunny Storage zone and verify it landed.
#
# Usage: bunny-put.sh <local-file> <remote-path> [<expected-sha256>]
#   <remote-path> is relative to the storage-zone root, e.g.
#   services/redis-8-linux-x86_64.tar.gz
#   <expected-sha256> is the LOWERCASE hex digest (no `sha256:` prefix). When
#   present and non-empty it is sent as Bunny's `Checksum:` header, upper-cased
#   here — this script is the SINGLE owner of the case transform, so callers pass
#   the digest exactly as GitHub reports it and never pre-transform. An empty or
#   absent third argument means "no header", so a null-digest asset can never
#   produce an empty `Checksum:`.
#
# This script is deliberately MODE-AGNOSTIC: it knows nothing about
# CDN_CHECKSUM_MODE. Whether a digest is available at all is the caller's
# decision (see the step-0 matrix in the CDN section of README.md); having a
# second gate here would silently discard a digest a caller meant to send.
#
# Requires: BUNNY_STORAGE_ACCESS_KEY, BUNNY_STORAGE_ZONE, BUNNY_STORAGE_ENDPOINT
# (the region host, e.g. ny.storage.bunnycdn.com - a wrong/absent region host
# hard-401s indistinguishably from a bad key, so it is mandatory).
set -euo pipefail

local_file=${1:?usage: bunny-put.sh <local-file> <remote-path> [<expected-sha256>]}
remote=${2:?usage: bunny-put.sh <local-file> <remote-path> [<expected-sha256>]}
expected_sha=${3:-}

: "${BUNNY_STORAGE_ACCESS_KEY:?BUNNY_STORAGE_ACCESS_KEY is not set}"
: "${BUNNY_STORAGE_ZONE:?BUNNY_STORAGE_ZONE is not set}"
: "${BUNNY_STORAGE_ENDPOINT:?BUNNY_STORAGE_ENDPOINT is not set (region host, e.g. ny.storage.bunnycdn.com)}"

[ -f "$local_file" ] || { echo "::error::bunny-put: no such file: $local_file" >&2; exit 1; }

url="https://${BUNNY_STORAGE_ENDPOINT}/${BUNNY_STORAGE_ZONE}/${remote}"

# Bunny's Edge Storage API compares an uploaded body against a `Checksum:` header
# (uppercase hex SHA-256) and rejects a mismatch server-side, so a corrupt
# transfer fails the PUT instead of silently landing. Build the header args only
# when a non-empty digest was supplied.
hdr=()
if [ -n "$expected_sha" ]; then
  hdr=(-H "Checksum: $(printf '%s' "$expected_sha" | tr '[:lower:]' '[:upper:]')")
fi

# -T streams the file (implies PUT, sets Content-Length; no chunked, which Bunny
# rejects). -f makes any non-2xx a hard failure.
# --max-time is generous here: service artifacts run to hundreds of MB, so the
# upload budget is far larger than the small requests in the sibling scripts.
# --connect-timeout bounds a hung connect either way.
curl -fsS --retry 3 --retry-connrefused --retry-delay 2 \
  --connect-timeout 30 --max-time 1800 \
  -T "$local_file" \
  -H "AccessKey: ${BUNNY_STORAGE_ACCESS_KEY}" \
  -H "Content-Type: application/octet-stream" \
  "${hdr[@]+"${hdr[@]}"}" \
  "$url"

# Bunny Storage has no HEAD method; a ranged GET with the AccessKey is the
# documented existence check. NOTE: this proves existence only, not content —
# content integrity comes from the `Checksum:` header above when one was sent,
# and from the caller's local sha256sum verify otherwise.
curl -fsS -o /dev/null -r 0-0 --connect-timeout 30 --max-time 120 \
  -H "AccessKey: ${BUNNY_STORAGE_ACCESS_KEY}" "$url" \
  || { echo "::error::bunny-put: post-upload verify failed for $remote" >&2; exit 1; }

echo "PUT $remote${expected_sha:+ (checksum sent)}"
