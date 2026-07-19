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

echo
echo "==== $pass passed, $fail failed ===="
[[ "$fail" -eq 0 ]]
