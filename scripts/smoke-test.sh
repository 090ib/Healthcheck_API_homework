#!/usr/bin/env bash
#
# Post-deploy smoke test.
#
#   ./scripts/smoke-test.sh https://abc123.execute-api.eu-central-1.amazonaws.com/staging/health
#
# Verifies both halves of the contract: a well-formed request is accepted and
# persisted, and a malformed one is rejected at the gateway with a 400.

set -euo pipefail

ENDPOINT="${1:?usage: smoke-test.sh <health-endpoint-url>}"
FAILURES=0

check() {
  local description="$1" expected="$2" actual="$3" body="${4:-}"
  if [[ "$actual" == "$expected" ]]; then
    printf '  ok    %-46s %s\n' "$description" "$actual"
  else
    printf '  FAIL  %-46s expected %s, got %s\n' "$description" "$expected" "$actual"
    [[ -n "$body" ]] && printf '        body: %s\n' "$body"
    FAILURES=$((FAILURES + 1))
  fi
}

request() {
  # Prints "<status>\n<body>"; curl never fails the script on a 4xx.
  curl -sS -o /tmp/smoke-body.$$ -w '%{http_code}' --max-time 20 "$@"
  echo
  cat /tmp/smoke-body.$$
  rm -f /tmp/smoke-body.$$
}

echo "Smoke testing ${ENDPOINT}"

# 1. Valid POST -> 200, request stored.
out=$(request -X POST "$ENDPOINT" \
  -H 'Content-Type: application/json' \
  -d '{"payload":{"source":"ci-smoke-test","run":"'"${GITHUB_RUN_ID:-local}"'"}}')
status=$(head -n1 <<<"$out"); body=$(tail -n +2 <<<"$out")
check "POST with payload" 200 "$status" "$body"
grep -q '"status": *"healthy"' <<<"$body" \
  || { echo "  FAIL  response body is not the healthy payload: $body"; FAILURES=$((FAILURES + 1)); }

# 2. POST without the payload key -> rejected at the gateway, never reaches Lambda.
out=$(request -X POST "$ENDPOINT" \
  -H 'Content-Type: application/json' \
  -d '{"nope":true}')
status=$(head -n1 <<<"$out"); body=$(tail -n +2 <<<"$out")
check "POST without payload is rejected" 400 "$status" "$body"

# 3. Valid GET -> 200.
out=$(request "${ENDPOINT}?payload=ci-smoke-test")
status=$(head -n1 <<<"$out"); body=$(tail -n +2 <<<"$out")
check "GET with payload querystring" 200 "$status" "$body"

# 4. GET without the parameter -> 400 from the request validator.
out=$(request "$ENDPOINT")
status=$(head -n1 <<<"$out"); body=$(tail -n +2 <<<"$out")
check "GET without payload is rejected" 400 "$status" "$body"

if (( FAILURES > 0 )); then
  echo "Smoke test failed: ${FAILURES} check(s) did not pass." >&2
  exit 1
fi

echo "All smoke tests passed."
