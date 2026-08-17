#!/usr/bin/env bash
#
# test.sh — dependency-free unit tests for the service pipeline (packaging, naming, the
# services.json generator, and the meilisearch /health smoke-test harness).
#
# Deliberately matches the repo's "just bash" convention: no bats/pytest, only bash + the
# same tools the pipeline already uses (tar, jq, curl; python3 for the smoke mock). Run it
# from anywhere:  scripts/test.sh
#
# Scope: everything that is verifiable WITHOUT a from-source engine build. The real
# from-source build of each engine is exercised by the CI build legs; here we prove the
# glue (filename contract, archive layout + exec bit, manifest merge/exclusion, and that the
# meilisearch smoke harness actually launches a binary, polls /health, and passes iff it
# reports {"status":"available"}). The smoke test uses a tiny mock server so it is fast and
# needs no network or the 100MB+ real binary.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; }
# eq <label> <expected> <actual>
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
# contains <label> <haystack> <needle>
contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "[$2] does not contain [$3]"; fi; }
# absent <label> <haystack> <needle>
absent() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "[$2] unexpectedly contains [$3]"; fi; }

work="$(mktemp -d "${TMPDIR:-/tmp}/yerd-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

gen="$here/gen-manifest.sh"
smoke="$here/smoke-test.sh"

echo "== 1. artifact filename generation =="
eq "meilisearch linux-x86_64"  "meilisearch-1.49.0-linux-x86_64.tar.gz"  "$(artifact_filename meilisearch 1.49.0 linux x86_64)"
eq "meilisearch linux-aarch64" "meilisearch-1.49.0-linux-aarch64.tar.gz" "$(artifact_filename meilisearch 1.49.0 linux aarch64)"
eq "meilisearch macos-aarch64" "meilisearch-1.49.0-macos-aarch64.tar.gz" "$(artifact_filename meilisearch 1.49.0 macos aarch64)"
eq "canonical_service passthrough" "meilisearch" "$(canonical_service meilisearch)"
# The Windows redis leg publishes under its OWN Redis version, not the Valkey label.
eq "redis windows 7.2.15" "redis-7.2.15-windows-x86_64.tar.gz" "$(artifact_filename redis 7.2.15 windows x86_64)"
eq "canonical_service valkey->redis" "redis" "$(canonical_service valkey)"

echo "== 2. archive layout + 3. executable permissions =="
# Stage exactly as the recipe does: bin/meilisearch (executable) + LICENSE files at the root.
stage="$(make_stage)"
cat >"$stage/bin/meilisearch" <<'EOF'
#!/bin/sh
echo mock
EOF
chmod +x "$stage/bin/meilisearch"
cp "$here/../LICENSES/meilisearch-MIT.txt" "$stage/LICENSE-MIT"
printf 'SPDX-License-Identifier: MIT AND BUSL-1.1\n' > "$stage/LICENSE"
require_files "$stage" bin/meilisearch && ok "require_files accepts staged bin/meilisearch" \
  || bad "require_files accepts staged bin/meilisearch"
out="$work/meilisearch-1.49.0-macos-aarch64.tar.gz"
pack_stage "$stage" "$out"
listing="$(tar -tzf "$out")"
# bin/ must be at the archive root — NO extra top-level <version> dir.
contains "archive contains bin/meilisearch at root" "$listing" "bin/meilisearch"
contains "archive contains LICENSE"                 "$listing" "LICENSE"
contains "archive contains LICENSE-MIT"             "$listing" "LICENSE-MIT"
# Reject a nested top-level version dir like meilisearch-1.49.0/bin/meilisearch.
absent "no top-level version dir" "$listing" "meilisearch-1.49.0/bin"
# Extract and confirm the exec bit survived the round-trip.
ex="$work/extract"; mkdir -p "$ex"; tar xf "$out" -C "$ex"
[[ -f "$ex/bin/meilisearch" ]] && ok "extracted bin/meilisearch is a file" || bad "extracted bin/meilisearch is a file"
[[ -x "$ex/bin/meilisearch" ]] && ok "extracted bin/meilisearch is executable" || bad "extracted bin/meilisearch is executable"
[[ -f "$ex/LICENSE" ]] && ok "extracted LICENSE present" || bad "extracted LICENSE present"
rm -rf "$stage"

echo "== 4. services.json meilisearch entry + platform tokens =="
# Feed the three platforms meilisearch actually publishes (linux x86_64/aarch64, macos aarch64).
names_meili=$'meilisearch-1.49.0-linux-x86_64.tar.gz\nmeilisearch-1.49.0-linux-aarch64.tar.gz\nmeilisearch-1.49.0-macos-aarch64.tar.gz'
mani="$(printf '%s\n' "$names_meili" | "$gen")"
eq  "schema is 1"              "1"          "$(jq -r '.schema' <<<"$mani")"
eq  "meilisearch version"      "1.49.0"     "$(jq -r '.services.meilisearch.versions[0].version' <<<"$mani")"
eq  "meilisearch platform count" "3"        "$(jq -r '.services.meilisearch.versions[0].platforms | length' <<<"$mani")"
plats="$(jq -c '.services.meilisearch.versions[0].platforms' <<<"$mani")"
contains "has linux-x86_64"  "$plats" '"linux-x86_64"'
contains "has linux-aarch64" "$plats" '"linux-aarch64"'
contains "has macos-aarch64" "$plats" '"macos-aarch64"'

echo "== 4b. redis slot: version lists are disjoint per platform =="
# The post-cutover redis asset set. This pins the whole point of the Windows rename as a
# test rather than a hope: the Valkey label must never regain a windows platform, and the
# Redis label must never gain a unix one. A regression in set-matrix's redis filter shows
# up here as `9.1.0` sprouting windows-x86_64.
names_redis=$'redis-9.1.0-linux-x86_64.tar.gz\nredis-9.1.0-linux-aarch64.tar.gz\nredis-9.1.0-macos-aarch64.tar.gz\nredis-7.2.15-windows-x86_64.tar.gz'
rmani="$(printf '%s\n' "$names_redis" | "$gen")"
eq "redis has two version entries" "2" "$(jq -r '.services.redis.versions | length' <<<"$rmani")"
r72="$(jq -c '.services.redis.versions[] | select(.version=="7.2.15") | .platforms' <<<"$rmani")"
r91="$(jq -c '.services.redis.versions[] | select(.version=="9.1.0")  | .platforms' <<<"$rmani")"
eq "7.2.15 is windows-only"     '["windows-x86_64"]' "$r72"
eq "9.1.0 has three platforms"  "3" "$(jq -r 'length' <<<"$r91")"
absent "9.1.0 has NO windows leg" "$r91" 'windows'
contains "9.1.0 has linux-x86_64"  "$r91" '"linux-x86_64"'
contains "9.1.0 has linux-aarch64" "$r91" '"linux-aarch64"'
contains "9.1.0 has macos-aarch64" "$r91" '"macos-aarch64"'

echo "== 5. exclusion of failed/untested platforms =="
# macos-x86_64 is never published (no Intel runner); a hypothetical failed leg simply has no
# artifact, so its token must NOT appear. Also a garbage / wrong-service filename is skipped.
absent "macos-x86_64 excluded (no artifact)" "$plats" '"macos-x86_64"'
absent "windows-x86_64 excluded (no artifact)" "$plats" '"windows-x86_64"'
names_partial=$'meilisearch-1.49.0-linux-x86_64.tar.gz\nmeilisearch-1.49.0-macos-aarch64.tar.gz\nnot-an-artifact.txt\nmeilisearch-1.49.0-solaris-sparc.tar.gz'
mani_partial="$(printf '%s\n' "$names_partial" | "$gen")"
eq "only the two valid platforms listed" "2" "$(jq -r '.services.meilisearch.versions[0].platforms | length' <<<"$mani_partial")"
absent "unknown os token dropped" "$(jq -c '.services.meilisearch.versions[0].platforms' <<<"$mani_partial")" "solaris"

echo "== 7. preservation of existing service entries (merge) =="
# A realistic mixed live asset set: existing services + the new meilisearch one.
names_mixed=$'redis-8-linux-x86_64.tar.gz\nredis-8-macos-aarch64.tar.gz\npostgres-17-linux-x86_64.tar.gz\npostgres-17-full-linux-x86_64.tar.gz\nmysql-8.4.9-linux-x86_64.tar.gz\nmeilisearch-1.49.0-linux-x86_64.tar.gz\nmeilisearch-1.49.0-macos-aarch64.tar.gz'
mani_mixed="$(printf '%s\n' "$names_mixed" | "$gen")"
eq "redis preserved"                "8"        "$(jq -r '.services.redis.versions[0].version' <<<"$mani_mixed")"
eq "mysql preserved"                "8.4.9"    "$(jq -r '.services.mysql.versions[0].version' <<<"$mani_mixed")"
# postgres keeps BOTH its base and -full labels alongside meilisearch.
pg_vers="$(jq -c '[.services.postgres.versions[].version]' <<<"$mani_mixed")"
contains "postgres base label kept"  "$pg_vers" '"17"'
contains "postgres full label kept"  "$pg_vers" '"17-full"'
eq "meilisearch present in merge"    "1.49.0"   "$(jq -r '.services.meilisearch.versions[0].version' <<<"$mani_mixed")"
eq "all four services present"       "4"        "$(jq -r '.services | keys | length' <<<"$mani_mixed")"
# Valid JSON overall.
jq -e . <<<"$mani_mixed" >/dev/null 2>&1 && ok "merged manifest is valid JSON" || bad "merged manifest is valid JSON"

echo "== 6. launch + /health smoke-test validation =="
if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP (python3 unavailable for the mock server)"
else
  # A mock 'meilisearch' that honors the exact flags the smoke test passes and serves /health.
  # MOCK_MODE=available -> 200 {"status":"available"}; anything else -> 503 (never healthy).
  mkstage() {
    local s mode="$1"; s="$(make_stage)"
    cat >"$s/bin/meilisearch" <<EOF
#!/usr/bin/env bash
addr=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --http-addr) addr="\$2"; shift 2;;
    --http-addr=*) addr="\${1#*=}"; shift;;
    *) shift;;
  esac
done
host="\${addr%%:*}"; port="\${addr##*:}"
exec python3 - "\$host" "\$port" "$mode" <<'PY'
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer
host, port, mode = sys.argv[1], int(sys.argv[2]), sys.argv[3]
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health" and mode == "available":
            b = json.dumps({"status": "available"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers(); self.wfile.write(b)
        else:
            self.send_response(503); self.end_headers()
    def log_message(self, *a): pass
HTTPServer((host, port), H).serve_forever()
PY
EOF
    chmod +x "$s/bin/meilisearch"
    printf 'MIT\n' > "$s/LICENSE"
    echo "$s"
  }

  # positive: healthy mock -> smoke passes
  ps="$(mkstage available)"; pt="$work/meili-ok.tar.gz"; pack_stage "$ps" "$pt"; rm -rf "$ps"
  if "$smoke" meilisearch "$pt" >"$work/smoke-ok.log" 2>&1; then
    ok "smoke passes for a healthy meilisearch"
  else
    bad "smoke passes for a healthy meilisearch" "$(tail -3 "$work/smoke-ok.log" | tr '\n' '|')"
  fi

  # negative: never-healthy mock -> smoke fails fast (bounded tries kept low for the test)
  ns="$(mkstage loading)"; nt="$work/meili-bad.tar.gz"; pack_stage "$ns" "$nt"; rm -rf "$ns"
  if MEILI_HEALTH_TRIES=3 "$smoke" meilisearch "$nt" >"$work/smoke-bad.log" 2>&1; then
    bad "smoke fails for an unhealthy meilisearch" "unexpectedly exited 0"
  else
    ok "smoke fails for an unhealthy meilisearch"
  fi
fi

echo "== 8. CDN reconcile plan classification =="
# cdn-reconcile-plan.sh is pure bash+jq with NO network, so the whole classifier is
# testable here from two JSON fixtures. These cases pin the defects that are easy to
# reintroduce: protecting a not-yet-uploaded asset's object, protecting the services/
# contract copy, and never letting an unusable CDN checksum cause perpetual re-upload.
plan="$here/cdn-reconcile-plan.sh"
cdn="$work/cdn"; mkdir -p "$cdn"

cat >"$cdn/assets.json" <<'EOF'
[
 {"name":"redis-8-linux-x86_64.tar.gz","size":100,"state":"uploaded","digest":"sha256:aaaa"},
 {"name":"redis-8-macos-aarch64.tar.gz","size":200,"state":"uploaded","digest":"sha256:bbbb"},
 {"name":"postgres-17-linux-x86_64.tar.gz","size":300,"state":"uploaded","digest":"sha256:cccc"},
 {"name":"postgres-17-full-linux-x86_64.tar.gz","size":400,"state":"uploaded","digest":"sha256:dddd"},
 {"name":"mysql-8-linux-x86_64.tar.gz","size":500,"state":"open","digest":null},
 {"name":"services.json","size":50,"state":"uploaded","digest":"sha256:eeee"}
]
EOF
cat >"$cdn/listing.json" <<'EOF'
[
 {"path":"services/redis-8-linux-x86_64.tar.gz","size":100,"checksum":"AAAA"},
 {"path":"services/redis-8-macos-aarch64.tar.gz","size":200,"checksum":"FFFF"},
 {"path":"services/postgres-17-linux-x86_64.tar.gz","size":999,"checksum":null},
 {"path":"services/mysql-8-linux-x86_64.tar.gz","size":500,"checksum":null},
 {"path":"services/services.json","size":50,"checksum":null},
 {"path":"services/junk-orphan.tar.gz","size":7,"checksum":null},
 {"path":"services/nested/deep.tar.gz","size":8,"checksum":null}
]
EOF
# rp <mode> [extra args...] -> plan JSON on stdout
rp() { local m="$1"; shift; "$plan" --assets-json "$cdn/assets.json" --cdn-listing "$cdn/listing.json" --checksum-mode "$m" "$@"; }
q()  { jq -c "$1"; }

h="$(rp hash)"
eq "hash: absent object -> to_upload"          '["postgres-17-full-linux-x86_64.tar.gz"]' "$(printf '%s' "$h" | q '.to_upload')"
eq "hash: digest!=checksum -> to_update"       'true' "$(printf '%s' "$h" | q '.to_update | index("redis-8-macos-aarch64.tar.gz") != null')"
eq "hash: case-folded match -> in sync"        'true' "$(printf '%s' "$h" | q '.to_update | index("redis-8-linux-x86_64.tar.gz") == null')"
eq "hash: null checksum + size differs -> to_update" 'true' "$(printf '%s' "$h" | q '.to_update | index("postgres-17-linux-x86_64.tar.gz") != null')"
eq "orphan + nested orphan -> to_delete"       '["services/junk-orphan.tar.gz","services/nested/deep.tar.gz"]' "$(printf '%s' "$h" | q '.to_delete')"
# The two protections. A `state: open` asset is excluded from the desired set, but its
# CDN object must NOT be treated as an orphan, or a sync run during a half-finished
# publish would delete a healthy artifact. And the services/ contract copy underpins
# SERVICES_BASE_URL, so pruning it would break every consumer.
eq "not-yet-uploaded asset's object PRESERVED" 'true' "$(printf '%s' "$h" | q '[.to_delete[] | select(test("mysql"))] | length == 0')"
eq "not-yet-uploaded asset warned"             '["mysql-8-linux-x86_64.tar.gz"]' "$(printf '%s' "$h" | q '.not_uploaded')"
eq "services/services.json PRESERVED"          'true' "$(printf '%s' "$h" | q '[.to_delete[] | select(test("services.json"))] | length == 0')"
eq "hash: three buckets partition D"           'true' "$(printf '%s' "$h" | q '.counts.hash_compared + .counts.size_compared + (.to_upload|length) == .counts.desired')"
eq "hash: null digest vs checksum -> unverified, not size_only" 'true' "$(printf '%s' "$h" | q '.size_only | length == 0')"

# Every mode except `hash` must route the un-hash-comparable objects to size_only[] with
# unverified[] EMPTY. unverified[] carries a "re-run with verify_checksums" cue, and on a
# zone that can never populate a usable checksum that cue can never converge — it would
# move the whole mirror on every run, forever.
for m in nopopulate stale noheader; do
  o="$(rp "$m")"
  eq "$m: unverified is empty"                 '0'    "$(printf '%s' "$o" | q '.unverified | length')"
  eq "$m: un-comparable -> size_only"          'true' "$(printf '%s' "$o" | q '.size_only | length > 0')"
  eq "$m: no hash comparison happened"         '0'    "$(printf '%s' "$o" | q '.counts.hash_compared')"
  eq "$m: buckets still partition D"           'true' "$(printf '%s' "$o" | q '.counts.hash_compared + .counts.size_compared + (.to_upload|length) == .counts.desired')"
  eq "$m: echoes checksum_mode"                "\"$m\"" "$(printf '%s' "$o" | q '.checksum_mode')"
done
# The anti-churn property, stated directly: under `stale` the CDN checksum is non-null but
# untrustworthy, so a mismatch must NOT schedule a re-upload.
eq "stale: mismatching checksum does NOT churn" 'true' \
  "$(rp stale | q '.to_update | index("redis-8-macos-aarch64.tar.gz") == null')"
eq "verify_checksums off by default"            'false' "$(rp stale | q '.verify_checksums')"
# Opt-in repair: forces the size_only set into to_update and reports itself as on.
v="$(rp stale --verify-checksums)"
eq "verify: size_only becomes empty"            '0'    "$(printf '%s' "$v" | q '.size_only | length')"
eq "verify: forces re-upload"                   'true' "$(printf '%s' "$v" | q '.to_update | index("redis-8-macos-aarch64.tar.gz") != null')"
eq "verify: echoed into the plan"               'true' "$(printf '%s' "$v" | q '.verify_checksums')"

# Guards. An empty desired set means a partial GitHub read; proceeding would classify
# every live object as an orphan, so it must hard-fail rather than plan a wipe.
printf '[]\n' > "$cdn/empty.json"
if "$plan" --assets-json "$cdn/empty.json" --cdn-listing "$cdn/listing.json" --checksum-mode hash >/dev/null 2>&1; then
  bad "empty desired set hard-fails" "unexpectedly exited 0"
else ok "empty desired set hard-fails"; fi
if rp bogus >/dev/null 2>&1; then bad "invalid --checksum-mode rejected" "exited 0"; else ok "invalid --checksum-mode rejected"; fi
if "$plan" --assets-json "$cdn/assets.json" --cdn-listing "$cdn/listing.json" >/dev/null 2>&1; then
  bad "missing --checksum-mode rejected" "exited 0"
else ok "missing --checksum-mode rejected"; fi
# Determinism: arrays are LC_ALL=C-sorted, so two runs are byte-identical.
eq "plan output is deterministic" "$(rp hash)" "$(rp hash)"

echo "== 9. bunny-delete.sh path guard =="
# The guard is the last line of defence for the destructive path, so test it directly.
# Dummy creds satisfy the `:?` asserts; every rejection below returns before any network
# call, so nothing here can touch a real zone.
del="$here/bunny-delete.sh"
dguard() {
  BUNNY_STORAGE_ACCESS_KEY=x BUNNY_STORAGE_ZONE=z BUNNY_STORAGE_ENDPOINT=e \
    "$del" "$1" >/dev/null 2>&1
}
for bad_path in \
  "/services/x.tar.gz" \
  "services/../services.json" \
  "services/" \
  "services.json" \
  "releases/foo.tar.gz" \
  "services//x.tar.gz"
do
  if dguard "$bad_path"; then bad "guard rejects '$bad_path'" "exited 0"; else ok "guard rejects '$bad_path'"; fi
done
# Accepted paths must get PAST the guard and fail only at the network boundary. The
# scripts hardcode https:// so a local mock can't serve them; reaching curl is the
# strongest offline signal, so assert the failure is NOT the guard's message.
for good_path in "services/redis-8-linux-x86_64.tar.gz" "services/nested/deep.tar.gz"; do
  out="$(BUNNY_STORAGE_ACCESS_KEY=x BUNNY_STORAGE_ZONE=z BUNNY_STORAGE_ENDPOINT=e \
    "$del" "$good_path" 2>&1 || true)"
  absent "guard accepts '$good_path' (reaches network)" "$out" "refusing"
done

echo "== 10. manifest derivation parity with finalize =="
# The sync regenerates services.json itself while cdn-mirror reuses finalize's asset.
# They must agree whenever every asset is `uploaded` (the steady state) — and must
# DIVERGE in the intended direction when one is mid-upload, since only the sync filters
# on state (finalize's `gh release view` does not).
mk_names_all() { jq -r '.[] | select(.state=="uploaded") | .name' "$1" | { grep '\.tar\.gz$' || true; } | LC_ALL=C sort; }
mk_names_finalize() { jq -r '.[].name' "$1" | { grep '\.tar\.gz$' || true; } | LC_ALL=C sort; }
jq '[.[] | select(.state=="open") | .name] | length' "$cdn/assets.json" >/dev/null
jq 'map(if .state=="open" then .state="uploaded" else . end)' "$cdn/assets.json" > "$cdn/all-uploaded.json"
eq "parity when every asset is uploaded" \
  "$(mk_names_finalize "$cdn/all-uploaded.json" | "$gen")" \
  "$(mk_names_all "$cdn/all-uploaded.json" | "$gen")"
sync_mf="$(mk_names_all "$cdn/assets.json" | "$gen")"
fin_mf="$(mk_names_finalize "$cdn/assets.json" | "$gen")"
absent "sync omits a state:open asset"   "$sync_mf" "mysql"
contains "finalize includes it (intended divergence)" "$fin_mf" "mysql"

echo
echo "==== $pass passed, $fail failed ===="
[[ "$fail" -eq 0 ]]
