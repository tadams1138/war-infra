#!/usr/bin/env bash
#
# Post-deploy smoke tests — see specs/war-infra-spec.md §8 and §19.
#
# Usage:
#   smoke-test.sh <environment> api
#   smoke-test.sh <environment> ui-default
#   smoke-test.sh <environment> ui <slug>
#
# <environment> is staging | production. BASE_URL overrides the derived hostname.
#
# These assert the routing and availability contract only. Behavioural coverage
# lives in the repos' own acceptance tests; this is the check that a deployment
# is serving what it should before the pipeline proceeds.

set -euo pipefail

ENVIRONMENT="${1:-}"
TARGET="${2:-}"
SLUG="${3:-}"

usage() {
  sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

[[ -n "$ENVIRONMENT" && -n "$TARGET" ]] || usage

if [[ -z "${BASE_URL:-}" ]]; then
  case "$ENVIRONMENT" in
    staging)    BASE_URL="https://staging.war.tmad.dev" ;;
    production) BASE_URL="https://war.tmad.dev" ;;
    *) echo "unknown environment: $ENVIRONMENT" >&2; exit 2 ;;
  esac
fi
BASE_URL="${BASE_URL%/}"

CURL_TIMEOUT="${CURL_TIMEOUT:-15}"
READY_ATTEMPTS="${READY_ATTEMPTS:-10}"
READY_DELAY="${READY_DELAY:-6}"

failures=0

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1" >&2; failures=$((failures + 1)); }

# status <path> <expected> <description>
status() {
  local path="$1" expected="$2" desc="$3" actual
  actual="$(curl -sS -o /dev/null -w '%{http_code}' \
                 --max-time "$CURL_TIMEOUT" "${BASE_URL}${path}" 2>/dev/null || echo 000)"
  if [[ "$actual" == "$expected" ]]; then
    pass "$desc"
  else
    fail "$desc — expected $expected, got $actual (${BASE_URL}${path})"
  fi
}

# header <path> <header-name> <expected-substring> <description>
header() {
  local path="$1" name="$2" want="$3" desc="$4" value
  value="$(curl -sSI --max-time "$CURL_TIMEOUT" "${BASE_URL}${path}" 2>/dev/null \
           | tr -d '\r' | awk -F': ' -v h="$name" 'tolower($1)==tolower(h){print $2; exit}')"
  if [[ "$value" == *"$want"* ]]; then
    pass "$desc"
  else
    fail "$desc — expected $name to contain '$want', got '${value:-<absent>}'"
  fi
}

# body_contains <path> <substring> <description>
body_contains() {
  local path="$1" want="$2" desc="$3"
  if curl -sS --max-time "$CURL_TIMEOUT" "${BASE_URL}${path}" 2>/dev/null | grep -qF -- "$want"; then
    pass "$desc"
  else
    fail "$desc — response did not contain '$want' (${BASE_URL}${path})"
  fi
}

# Deployments propagate through the edge, so give the target a moment to answer
# before asserting anything. Avoids flaky failures on an otherwise good deploy.
await_ready() {
  local path="$1" attempt=1 code
  while (( attempt <= READY_ATTEMPTS )); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' \
                 --max-time "$CURL_TIMEOUT" "${BASE_URL}${path}" 2>/dev/null || echo 000)"
    if [[ "$code" != 000 && "$code" != 5* ]]; then
      return 0
    fi
    printf '  ..   waiting for %s (attempt %d/%d, last %s)\n' \
           "$path" "$attempt" "$READY_ATTEMPTS" "$code"
    sleep "$READY_DELAY"
    attempt=$((attempt + 1))
  done
  fail "target never became ready: ${BASE_URL}${path}"
  return 1
}

echo "Smoke test: $TARGET @ $BASE_URL"

case "$TARGET" in
  api)
    await_ready "/api/v1/wars" || true

    status "/api/v1/wars"     200 "public war list responds"
    header "/api/v1/wars"     content-type "application/json" "war list returns JSON"
    status "/api/v1/auth/me"  401 "protected endpoint rejects anonymous requests"

    # §6 — internal endpoints must be blocked at the edge. Anything other than a
    # 2xx is a pass; what matters is that it never succeeds from outside.
    code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
                 --max-time "$CURL_TIMEOUT" \
                 "${BASE_URL}/api/v1/internal/close-expired-wars" 2>/dev/null || echo 000)"
    if [[ "$code" == 2* ]]; then
      fail "internal endpoint reachable from the public internet (got $code)"
    else
      pass "internal endpoint blocked from the public internet (got $code)"
    fi
    ;;

  ui-default)
    await_ready "/" || true

    status "/"                200 "home page responds"
    header "/"                content-type "text/html" "home page returns HTML"

    # §6.1 — SPA deep links must return index.html with 200, not 404.
    status "/wars/smoke-test-nonexistent/vote" 200 "SPA deep link returns 200"

    # index.html must not go meaningfully stale after a deploy (§7), but
    # unlike the custom-UI stack below (which we fully control and holds to
    # a strict no-store), App Platform's static-site hosting has a fixed,
    # non-configurable Cache-Control — public, max-age=10, s-maxage=86400 —
    # with no app spec field to override it. s-maxage is currently inert:
    # Cloudflare's default cache level doesn't cache HTML without an
    # explicit "Cache Everything" rule, which nothing here adds, and no
    # other shared cache sits in the path (see terraform/shared/main.tf's
    # cache ruleset comment — if that ever changes, this check needs
    # revisiting). What a browser actually bounds by is max-age=10, which
    # self-heals on the next real navigation — accept no-store or any short
    # bounded max-age, not literally no-store only.
    cc_value="$(curl -sSI --max-time "$CURL_TIMEOUT" "${BASE_URL}/" 2>/dev/null \
                | tr -d '\r' | awk -F': ' 'tolower($1)=="cache-control"{print $2; exit}')"
    max_age="$(printf '%s' "$cc_value" | grep -oE 'max-age=[0-9]+' | head -1 | cut -d= -f2)"
    if [[ "$cc_value" == *"no-store"* ]] || { [[ -n "$max_age" ]] && (( max_age <= 60 )); }; then
      pass "index.html is not meaningfully cached (cache-control: ${cc_value:-<absent>})"
    else
      fail "index.html cache-control too permissive — got '${cc_value:-<absent>}'"
    fi
    ;;

  ui)
    [[ -n "$SLUG" ]] || { echo "target 'ui' requires a slug" >&2; usage; }
    await_ready "/ui/${SLUG}/" || true

    status "/ui/${SLUG}/"     200 "custom UI '${SLUG}' responds"
    header "/ui/${SLUG}/"     content-type "text/html" "custom UI returns HTML"

    # §6.1 — the edge function must rewrite storage 404s to a 200 index.html.
    status "/ui/${SLUG}/smoke-test-nonexistent" 200 "custom UI SPA fallback returns 200"
    ;;

  *)
    echo "unknown target: $TARGET" >&2
    usage
    ;;
esac

echo
if (( failures > 0 )); then
  echo "FAILED — $failures check(s) did not pass" >&2
  exit 1
fi
echo "PASSED"
