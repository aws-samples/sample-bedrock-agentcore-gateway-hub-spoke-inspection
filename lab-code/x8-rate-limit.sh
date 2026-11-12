#!/usr/bin/env bash
# AWS WAF rate-based rule on the Gateway (03-spoke1-inbound.yaml: RateLimit, 500 requests per IP, default 5-minute window).
# Sends a burst of tools/list calls from this machine, keeps calling until the first HTTP 403, then reports what AWS WAF logged.
# Your IP address can stay blocked for a few minutes afterwards.
# Needs: ./run-lab.sh deploy, and ./observability.sh enable (for the AWS WAF log group used in B3).
set -Eeuo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"
lab_load_state
R=$REGION
TOK=$(lab_token)
export GW_URL TOK
one() { curl -s -o /dev/null -m 20 -w "%{http_code}\n" -X POST "$GW_URL" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'; }
export -f one
T0=$(date +%s)
echo "==> B1 burst: 800 requests, 25 in parallel"
seq 800 | xargs -P 25 -I{} bash -c one > "$TMPD/burst.txt"
echo "  burst took $(( $(date +%s) - T0 ))s; status counts: $(sort "$TMPD/burst.txt" | uniq -c | tr '\n' ' ')"
echo "==> B2 keep calling at ~2 req/s until 403 (max 4 min)"
for i in $(seq 1 480); do c=$(one); if [ "$c" = 403 ]; then echo "  first 403 at +$(( $(date +%s) - T0 ))s after burst start (follow-up call $i)"; break; fi; sleep 0.5; done
echo "==> B3 WAF log: RateLimit blocks"
sleep 60
aws logs filter-log-events --profile $S1 --region $R --log-group-name aws-waf-logs-lab-gateway --start-time $((T0*1000)) \
  --filter-pattern '{ $.terminatingRuleId = "RateLimit" }' --query 'events[].message' --output json | python3 -c '
import json,sys
ev=json.load(sys.stdin); print("  RateLimit BLOCK events:", len(ev))
for m in ev[:2]:
    d=json.loads(m); print("  ", d["action"], d["terminatingRuleId"], d["terminatingRuleType"], "| clientIp", d["httpRequest"]["clientIp"])'
