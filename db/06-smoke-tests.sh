#!/usr/bin/env bash
# 06-smoke-tests.sh <env> : minimal post-cutover checks (extend with real business flows)
set -euo pipefail
ENV_NAME="${1:?env}"
BASE="${BASE_URL:?e.g. https://shop.example.com}"

check() { curl -fsS --max-time 5 -o /dev/null -w "%{http_code} $1\n" "$BASE$1"; }
check /healthz
check /api/v1/inventory
check /api/v1/orders/health
check /api/v1/payments/health

# Write path test: create a canary order (flagged is_test) and read it back
ID=$(curl -fsS -X POST "$BASE/api/v1/orders" -H 'content-type: application/json' \
      -d '{"sku":"CANARY","qty":1,"is_test":true}' | jq -r .id)
curl -fsS "$BASE/api/v1/orders/$ID" | jq -e '.is_test == true' >/dev/null
echo "smoke tests passed for $ENV_NAME"
