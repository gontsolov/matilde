#!/usr/bin/env bash
# Usage: scripts/smoke-health.sh https://<host>/v1/health
# Passes when the endpoint answers 200 with "ok":true. Retries briefly because a
# fresh deploy (or a new custom-domain certificate) can take a moment to answer.
set -euo pipefail
url="${1:?usage: smoke-health.sh <url>}"
attempts="${SMOKE_ATTEMPTS:-10}"
body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT
for i in $(seq 1 "$attempts"); do
  status="$(curl -sS -o "$body_file" -w '%{http_code}' --max-time 10 "$url" || echo 000)"
  body="$(cat "$body_file" 2>/dev/null || true)"
  if [ "$status" = "200" ] && printf '%s' "$body" | tr -d ' \n' | grep -q '"ok":true'; then
    echo "OK $url -> $status $body"
    exit 0
  fi
  echo "Attempt $i/$attempts: $url -> $status ${body:0:200}"
  [ "$i" -lt "$attempts" ] && sleep 6
done
echo "::error::Health check failed for $url"
exit 1
