#!/usr/bin/env bash
#
# cdn-reconcile-plan.sh — compute the CDN reconcile plan. NO NETWORK: it reads two
# JSON snapshots and writes a plan to stdout, so it is fully unit-testable offline
# (see scripts/test.sh). This is the shell replacement for the Rust xtask the
# sibling `forjedio/yerd` repo uses; yerd-services is a shell-only repo.
#
# Usage:
#   cdn-reconcile-plan.sh --assets-json <file> --cdn-listing <file> \
#                         --checksum-mode <hash|nopopulate|stale|noheader> \
#                         [--verify-checksums]
#
#   --assets-json    GitHub release assets, as returned by
#                    `gh api --paginate repos/<r>/releases/<id>/assets` (a flat array).
#   --cdn-listing    Output of `bunny-list.sh services/` — [{path,size,checksum}, ...]
#                    where `checksum` is an UPPERCASE SHA-256 or null.
#   --checksum-mode  The zone's resolved Bunny-checksum behaviour. REQUIRED, and the
#                    only checksum input: the nulling below and the size_only routing
#                    are both derived from it, so they cannot drift apart. Echoed back
#                    into the output so a summary reading the plan cannot disagree with
#                    what the classifier actually did. See README's CDN section.
#   --verify-checksums  Force every object that could not be hash-compared into
#                    to_update (a deliberate full-mirror repair). Echoed back too.
#
# Output (stdout), all arrays LC_ALL=C-sorted for determinism:
#   {"to_upload":[name...], "to_update":[name...], "to_delete":["services/<key>"...],
#    "unverified":[name...], "size_only":[name...], "not_uploaded":[name...],
#    "counts":{"desired":N,"hash_compared":N,"size_compared":N},
#    "checksum_mode":"<mode>", "verify_checksums":true|false}
#
# THE FOUR SETS
#   D        desired: assets in state `uploaded` whose name ends .tar.gz, mapped to
#            {size, sha}. `sha` is the GitHub `digest` with the `sha256:` prefix
#            stripped and lowercased, or null. D drives uploads and the manifest.
#   P_assets every .tar.gz asset name REGARDLESS of state. Basis for the
#            not_uploaded warning only.
#   P        P_assets + the literal "services.json" (the contract copy that lives at
#            services/services.json). to_delete is C \ P, NEVER C \ D — otherwise an
#            asset stuck mid-upload would orphan its own healthy CDN object, and the
#            contract copy would be pruned on the next sync.
#   C        current: every listing entry, keyed by the path suffix after `services/`.
#            The zone-root services.json is never in C (the listing is prefix-scoped).
set -euo pipefail

assets_json="" cdn_listing="" checksum_mode="" verify=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --assets-json)       assets_json="${2:?--assets-json needs a value}"; shift 2 ;;
    --cdn-listing)       cdn_listing="${2:?--cdn-listing needs a value}"; shift 2 ;;
    --checksum-mode)     checksum_mode="${2:?--checksum-mode needs a value}"; shift 2 ;;
    --verify-checksums)  verify=true; shift ;;
    *) echo "cdn-reconcile-plan.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[[ -n "$assets_json" ]] || { echo "cdn-reconcile-plan.sh: --assets-json is required" >&2; exit 2; }
[[ -n "$cdn_listing" ]] || { echo "cdn-reconcile-plan.sh: --cdn-listing is required" >&2; exit 2; }
[[ -f "$assets_json" ]] || { echo "cdn-reconcile-plan.sh: no such file: $assets_json" >&2; exit 2; }
[[ -f "$cdn_listing" ]] || { echo "cdn-reconcile-plan.sh: no such file: $cdn_listing" >&2; exit 2; }

# --checksum-mode is required and closed-set: a typo must fail loudly rather than
# silently selecting hash comparison on a zone that cannot support it.
case "$checksum_mode" in
  hash|nopopulate|stale|noheader) ;;
  "") echo "cdn-reconcile-plan.sh: --checksum-mode is required (hash|nopopulate|stale|noheader)" >&2; exit 2 ;;
  *)  echo "cdn-reconcile-plan.sh: invalid --checksum-mode '$checksum_mode' (want hash|nopopulate|stale|noheader)" >&2; exit 2 ;;
esac

# The whole classification is one jq program so the sets are built and compared
# without shelling out per object (37+ assets today, and it must stay fast enough
# to run on every dry run).
#
# Guards, in order:
#   - refuse-if-source-empty: an empty D means a partial/failed GitHub read, and
#     proceeding would classify every CDN object as an orphan. Hard-fail instead.
#     The calling workflow asserts this too; this is the defensive backstop so no
#     caller can compute a wipe-everything plan.
#   - the three comparison arms are disjoint and total over D, and the tally
#     assertion at the end proves it.
jq -n \
  --slurpfile assets "$assets_json" \
  --slurpfile listing "$cdn_listing" \
  --arg mode "$checksum_mode" \
  --argjson verify "$verify" '
  ($assets[0] // []) as $A
| ($listing[0] // []) as $L

# --- D: uploaded .tar.gz assets -> {name: {size, sha}} ------------------------
| [ $A[] | select(.state == "uploaded") | select(.name | endswith(".tar.gz")) ] as $dl
| ( $dl | map({ key: .name, value: {
      size: .size,
      # digest is "sha256:<hex>"; strip the prefix and lowercase. Absent/null -> null.
      sha: ( if (.digest // null) == null then null
             else (.digest | sub("^sha256:"; "") | ascii_downcase) end )
    }}) | from_entries ) as $D

# --- P_assets / P: delete protection -----------------------------------------
| [ $A[] | select(.name | endswith(".tar.gz")) | .name ] as $P_assets
| ($P_assets + ["services.json"]) as $P

# --- C: listing keyed by the suffix after "services/" ------------------------
| ( [ $L[]
      | select(.path | startswith("services/"))
      | { key: (.path | sub("^services/"; "")),
          value: { size: .size,
                   # In every mode but `hash` the CDN checksum is unusable: absent
                   # (nopopulate/noheader) or non-null but stale (stale). Nulling it
                   # here is what makes `stale` degrade cleanly to size-only — a
                   # stale checksum IS non-null, so nothing else stops the hash arm
                   # firing and re-uploading the whole mirror on every sync.
                   checksum: ( if $mode == "hash" then (.checksum // null) else null end ) } }
    ] | from_entries ) as $C

| if ($D | length) == 0 then
    ( "cdn-reconcile-plan.sh: 0 desired artifacts - refusing to reconcile (partial GitHub read?)"
      | halt_error(1) )
  else . end

# --- classify D ---------------------------------------------------------------
| [ $D | to_entries[]
    | .key as $n | .value as $m
    | if ($C[$n] // null) == null then
        { bucket: "to_upload", name: $n }
      else
        $C[$n] as $o
        | if ($o.checksum != null and $m.sha != null) then
            ( if ($o.checksum | ascii_downcase) != ($m.sha | ascii_downcase)
              then { bucket: "hash", name: $n, update: true }
              else { bucket: "hash", name: $n, update: false } end )
          elif ($o.size != $m.size) then
            { bucket: "size", name: $n, update: true }
          else
            # Sizes equal and at least one side has no comparable hash.
            # verify_checksums wins; otherwise this is either an anomaly worth
            # repairing (mode `hash`) or the expected steady state (every other
            # mode, where hash comparison is structurally impossible and must NOT
            # raise a call to action that can never converge).
            ( if $verify then { bucket: "size", name: $n, update: true }
              elif $mode != "hash" then { bucket: "size", name: $n, update: false, size_only: true }
              else { bucket: "size", name: $n, update: false, unverified: true } end )
          end
      end
  ] as $cls

| ( [ $cls[] | select(.bucket == "to_upload") | .name ] ) as $to_upload
| ( [ $cls[] | select(.update == true)        | .name ] ) as $to_update
| ( [ $cls[] | select(.size_only == true)     | .name ] ) as $size_only
| ( [ $cls[] | select(.unverified == true)    | .name ] ) as $unverified
| ( [ $cls[] | select(.bucket == "hash") ] | length ) as $hash_compared
| ( [ $cls[] | select(.bucket == "size") ] | length ) as $size_compared

# --- orphans: C \ P (note P, not D) ------------------------------------------
| ( [ $C | keys[] | select(. as $k | ($P | index($k)) == null) | "services/" + . ] ) as $to_delete
# --- assets present but not yet uploaded: P_assets \ D -----------------------
| ( [ $P_assets[] | select(. as $n | ($D | has($n)) | not) ] ) as $not_uploaded

# The three buckets must partition D exactly; a mismatch means a classification
# arm fell through and the reported tally would understate what was checked.
# Whitelist the bucket names rather than summing the three counters: the counters are
# derived from those same buckets, so a sum check is a tautology that would still pass if a
# future arm returned an unrecognised bucket. This catches that.
| if ([ $cls[] | select(.bucket == "to_upload" or .bucket == "hash" or .bucket == "size") ] | length) != ($D | length) then
    ( "cdn-reconcile-plan.sh: internal error - buckets do not partition D" | halt_error(1) )
  else . end

| { to_upload:   ($to_upload   | sort),
    to_update:   ($to_update   | sort),
    to_delete:   ($to_delete   | sort),
    unverified:  ($unverified  | sort),
    size_only:   ($size_only   | sort),
    not_uploaded:($not_uploaded| unique),
    counts: { desired: ($D | length),
              hash_compared: $hash_compared,
              size_compared: $size_compared },
    checksum_mode: $mode,
    verify_checksums: $verify }
'
