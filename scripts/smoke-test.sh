#!/usr/bin/env bash
# Smoke test for the portfolio image / deployment.
# Usage: scripts/smoke-test.sh <base-url>     e.g. http://localhost:8080 or https://test.name.vn
set -euo pipefail

BASE_URL="${1:?usage: $0 <base-url>}"
BASE_URL="${BASE_URL%/}"
RETRIES="${SMOKE_RETRIES:-10}"
CURL=(curl -sS --max-time 10)

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# 1. /healthz returns 200 "ok" (retry while the server/ALB warms up)
for i in $(seq 1 "$RETRIES"); do
  body="$("${CURL[@]}" -f "$BASE_URL/healthz" 2>/dev/null || true)"
  [[ "$body" == "ok" ]] && break
  [[ "$i" -eq "$RETRIES" ]] && fail "/healthz did not return 'ok' after $RETRIES attempts (got: '$body')"
  sleep 3
done
pass "/healthz returned ok"

# 2. / serves the SPA HTML
index_html="$("${CURL[@]}" -f "$BASE_URL/")" || fail "GET / failed"
grep -q '<div id="root">' <<<"$index_html" || fail "GET / did not return the SPA index.html"
pass "/ returned index.html"

# 3. A hashed static asset is served with an immutable cache header
asset="$(grep -oE '/static/js/main\.[0-9a-f]+\.js' <<<"$index_html" | head -n1 || true)"
[[ -n "$asset" ]] || fail "no hashed main.*.js asset referenced in index.html"
headers="$("${CURL[@]}" -f -o /dev/null -D - "$BASE_URL$asset")" || fail "GET $asset failed"
grep -qiE '^cache-control:.*immutable' <<<"$headers" || fail "$asset missing immutable Cache-Control"
pass "$asset served with immutable cache"

# 4. Deep links fall back to index.html
deep_html="$("${CURL[@]}" -f "$BASE_URL/some/deep/link")" || fail "GET /some/deep/link failed"
grep -q '<div id="root">' <<<"$deep_html" || fail "deep link did not fall back to index.html"
pass "deep link fell back to index.html"

echo "All smoke tests passed for $BASE_URL"
