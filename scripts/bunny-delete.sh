#!/usr/bin/env bash
#
# Delete one object from a Bunny Storage zone.
#
# Usage: bunny-delete.sh <remote-path>
#   <remote-path> is relative to the storage-zone root, e.g.
#   services/redis-7-linux-x86_64.tar.gz
#
# Requires: BUNNY_STORAGE_ACCESS_KEY, BUNNY_STORAGE_ZONE, BUNNY_STORAGE_ENDPOINT
set -euo pipefail

remote=${1:?usage: bunny-delete.sh <remote-path>}

: "${BUNNY_STORAGE_ACCESS_KEY:?BUNNY_STORAGE_ACCESS_KEY is not set}"
: "${BUNNY_STORAGE_ZONE:?BUNNY_STORAGE_ZONE is not set}"
: "${BUNNY_STORAGE_ENDPOINT:?BUNNY_STORAGE_ENDPOINT is not set (region host)}"

# Refuse anything outside services/ - deletion must never touch the root
# manifest, whatever the caller passes. A `..` segment or a leading slash is
# rejected up front: without that, `services/../services.json` passes the glob
# but curl's default path normalisation would collapse the `..` and issue the
# DELETE against /services.json, escaping services/.
# `services/[!/]*` requires at least one non-slash char after `services/`, so a
# bare `services/` (which would target the whole tree) falls through to the
# reject arm rather than matching. It DOES match `services/sub/x.tar.gz`, which
# is intended: a nested object under services/ is a legitimate orphan the sync
# must be able to prune.
# The zone-root `services.json` is structurally protected: the char after
# `services` is `.`, not `/`, so it can never match the allow arm. The contract
# copy at `services/services.json` (see the CDN section of README.md) matches the
# glob and so is NOT protected here — it is protected by the reconcile's
# protected set, which never emits it as a delete candidate.
case "$remote" in
  /*) echo "::error::bunny-delete: refusing absolute path: $remote" >&2; exit 1 ;;
  *..*) echo "::error::bunny-delete: refusing path with '..': $remote" >&2; exit 1 ;;
  services/[!/]*) ;;
  *) echo "::error::bunny-delete: refusing to delete outside services/: $remote" >&2; exit 1 ;;
esac

url="https://${BUNNY_STORAGE_ENDPOINT}/${BUNNY_STORAGE_ZONE}/${remote}"

# --path-as-is: send the literal (guard-checked) path; do not let curl normalise
# away any dot segment, belt-and-suspenders alongside the `..` rejection above.
curl -fsS --retry 3 --retry-connrefused --retry-delay 2 --path-as-is \
  --connect-timeout 30 --max-time 120 \
  -X DELETE -H "AccessKey: ${BUNNY_STORAGE_ACCESS_KEY}" "$url"

echo "DELETE $remote"
