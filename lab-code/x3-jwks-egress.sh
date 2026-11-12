#!/usr/bin/env bash
# Check 8: without the scoped JWKS egress rule, the internal ALB cannot fetch the identity provider's signing keys (JWKS)
# and the call fails.
#   1) firewall -> block-egress (tool VPC -> internet dropped)   2) call (the ALB may still have the keys cached)
#   3) force a JWKS re-fetch by changing the /mcp rule's JwksEndpoint string   4) call again
#   5) firewall -> allow, call   6) restore the original rule actions (no CloudFormation drift)
# Steps 5 and 6 also run if the script fails or is interrupted.
# Needs: ./run-lab.sh deploy and ./run-lab.sh alb first.
set -Eeuo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"
lab_load_state
R=$REGION

ALB=$(aws elbv2 describe-load-balancers --profile $S2 --region $R --names lab-tools-internal --query 'LoadBalancers[0].LoadBalancerArn' --output text) \
  || die "internal ALB lab-tools-internal not found; run ./run-lab.sh alb first"
# jwt-validation lives on each listener rule; the test calls the MCP tool, so it changes the /mcp rule.
RULE=$(aws cloudformation describe-stacks --profile $S2 --region $R --stack-name lab-spoke2-tools-alb \
         --query "Stacks[0].Outputs[?OutputKey=='McpRuleArn'].OutputValue" --output text)
ORIG="$TMPD/orig-actions.json"
aws elbv2 describe-rules --profile $S2 --region $R --rule-arns "$RULE" --query 'Rules[0].Actions' --output json > "$ORIG"
ORIG_JWKS=$(python3 -c 'import json,sys;print([a for a in json.load(open(sys.argv[1])) if a["Type"]=="jwt-validation"][0]["JwtValidationConfig"]["JwksEndpoint"])' "$ORIG")

call() { # id
  curl -s -m 70 -X POST "$GW_URL" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":'"$1"',"method":"tools/call","params":{"name":"classifier___classifyQuestion","arguments":{"question":"jwks test"}}}' | cut -c1-220; echo
}
hub() { # mode
  aws cloudformation deploy --profile $HUB --region $R --stack-name lab-hub-network --template-file "$DIR/01-hub-network.yaml" \
    --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset --parameter-overrides FirewallMode=$1 | tail -1
}
set_jwks() { # url
  python3 - "$1" "$ORIG" > "$TMPD/actions.json" <<'PY'
import json, sys
url, f = sys.argv[1:3]
acts = json.load(open(f))
for a in acts:
    if a["Type"] == "forward":
        a.pop("ForwardConfig", None)   # TargetGroupArn alone is enough on modify
    if a["Type"] == "jwt-validation":
        a["JwtValidationConfig"]["JwksEndpoint"] = url
print(json.dumps(acts))
PY
  aws elbv2 modify-rule --profile $S2 --region $R --rule-arn "$RULE" --actions "file://$TMPD/actions.json" \
    --query 'Rules[0].Actions[?Type==`jwt-validation`].JwtValidationConfig.JwksEndpoint' --output text
}

# Always leave the lab as we found it, even on failure or Ctrl-C.
LAB_EXIT_HOOKS+=("hub allow" "set_jwks '$ORIG_JWKS'")

TOK=$(lab_token)
say "J0 baseline"; call 70
say "J1 firewall -> block-egress"; hub block-egress; sleep 90; T0=$(date +%s)
say "J2 call with egress blocked (JWKS possibly cached by the ALB)"; call 71
say "J3 force JWKS re-fetch: /mcp rule JwksEndpoint -> $ORIG_JWKS?refresh=1"; set_jwks "$ORIG_JWKS?refresh=1"; sleep 20
say "J4 call with egress blocked and no cached keys"; call 72; sleep 5; call 73
say "J5 firewall default-action drops (drop established) for tool VPC -> internet:443"
h=""
for i in $(seq 1 8); do sleep 30
  h=$(aws logs filter-log-events --profile $HUB --region $R --log-group-name /lab/network-firewall --start-time $((T0*1000)) \
    --filter-pattern '{ $.event.event_type = "alert" && $.event.alert.action = "blocked" && $.event.dest_port = 443 }' --query 'events[].message' --output text | tr '\t' '\n' | python3 -c '
import sys, json
for l in sys.stdin:
    if not l.strip().startswith("{"): continue
    e = json.loads(l)["event"]
    if e["src_ip"].startswith("10.12."): print(" ", e["timestamp"][:19], e["src_ip"], "->", e["dest_ip"], e["dest_port"], "| sni", (e.get("tls") or {}).get("sni"), "|", e["alert"]["action"], "|", e["alert"]["signature"])
' | tail -3) || true
  [ -n "$h" ] && break
done
echo "${h:-  (no drop records found)}"
say "J6 firewall -> allow, call again (the ALB can fetch JWKS)"; hub allow; sleep 90; call 74
say "J7 restore original /mcp rule JwksEndpoint ($ORIG_JWKS)"; set_jwks "$ORIG_JWKS"; sleep 10; call 75
LAB_EXIT_HOOKS=()
