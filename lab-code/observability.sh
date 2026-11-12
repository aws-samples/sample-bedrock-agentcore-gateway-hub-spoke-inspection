#!/usr/bin/env bash
# =====================================================================================
# Gateway resource policy (check 9) and one log source per hop (check 12, docs/logging.md) for the lab.
# run-lab.sh does not automate these; resource names match what run-lab.sh teardown deletes.
#
# Needs:  ./run-lab.sh deploy and ./run-lab.sh alb first (enable needs the internal ALB; policy-test and traffic use the probe Lambda from alb).
#         Gateway application logs contain request AND response bodies, and AWS WAF logs are written without the Authorization header.
# Usage:  ./observability.sh enable        # turn on every log source in the Step 7 table
#         ./observability.sh traffic       # generate test calls (public + private ingress)
#         ./observability.sh verify        # show what each log source recorded
#         ./observability.sh policy-test   # attach aws:SourceVpce policy, time the lock-down, then remove it
# =====================================================================================
set -Eeuo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"
case "${1:-}" in enable|traffic|verify|policy-test) ;; *) echo "usage: $0 enable | traffic | verify | policy-test"; exit 1;; esac
lab_load_state
HUB_ACCT=$(acct "$HUB"); S1_ACCT=$(acct "$S1"); S2_ACCT=$(acct "$S2")
hubout() { aws cloudformation describe-stacks --profile $HUB --region $REGION --stack-name lab-hub-network \
             --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
mklg() { aws logs create-log-group --profile "$1" --region $REGION --log-group-name "$2" 2>/dev/null || true
         aws logs put-retention-policy --profile "$1" --region $REGION --log-group-name "$2" --retention-in-days 7; }
lgarn() { echo "arn:aws:logs:$REGION:$2:log-group:$1"; }
GW_VPCE=$(hubout GatewayVpceId)
ALB_BUCKET=lab-alb-logs-$S2_ACCT
token() { lab_token; }
public_call() { # prints "HTTP <code> <first 110 chars>"
  local out; out=$(curl -s -m 20 -w '\n%{http_code}' -X POST "$GW_URL" -H "Authorization: Bearer $TOK" \
    -H 'Content-Type: application/json' -d "$1" || true)
  printf 'HTTP %s %s' "$(tail -n1 <<<"$out")" "$(sed '$d' <<<"$out" | tr -d '\n' | cut -c1-110)"
}
probe_call() { # via Lambda in shared spoke1 subnet -> Gateway VPCE
  python3 -c 'import json,sys;print(json.dumps({"gatewayUrl":sys.argv[1],"token":sys.argv[2],"body":json.loads(sys.argv[3]),"extraHeaders":json.loads(sys.argv[4])}))' \
    "$GW_URL" "$TOK" "$1" "${2:-"{}"}" > "$TMPD/pev.json"
  aws lambda invoke --profile $S1 --region $REGION --function-name lab-agent-probe --cli-read-timeout 90 \
    --payload "fileb://$TMPD/pev.json" "$TMPD/pout.json" >/dev/null; rm -f "$TMPD/pev.json"
  python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print("HTTP",d.get("status"),(d.get("body") or d.get("error",""))[:110].replace("\n"," "))' "$TMPD/pout.json"
}

cmd_enable() {
  ALB=$(aws elbv2 describe-load-balancers --profile $S2 --region $REGION --names lab-tools-internal --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null) \
    || die "internal ALB lab-tools-internal not found; run ./run-lab.sh alb first"
  say "L1 Gateway application logs (vended logs -> CloudWatch Logs)  [AgentCore account]"
  mklg $S1 /lab/agentcore-gateway
  aws logs put-delivery-source --profile $S1 --region $REGION --name lab-gw-logs --resource-arn "$GW_ARN" \
    --log-type APPLICATION_LOGS --query deliverySource.name --output text
  DD_ARN=$(aws logs put-delivery-destination --profile $S1 --region $REGION --name lab-gw-cwl \
    --delivery-destination-configuration destinationResourceArn="$(lgarn /lab/agentcore-gateway $S1_ACCT)" \
    --query deliveryDestination.arn --output text); echo "$DD_ARN"
  aws logs create-delivery --profile $S1 --region $REGION --delivery-source-name lab-gw-logs \
    --delivery-destination-arn "$DD_ARN" --query delivery.id --output text 2>&1 | tail -1 || true   # ConflictException on re-run

  say "L2 AWS WAF logs  [AgentCore account]"
  mklg $S1 aws-waf-logs-lab-gateway
  # The Authorization header carries each caller's bearer token, so redact it from the AWS WAF logs.
  aws wafv2 put-logging-configuration --profile $S1 --region $REGION \
    --logging-configuration "{\"ResourceArn\":\"$WEB_ACL_ARN\",\"LogDestinationConfigs\":[\"$(lgarn aws-waf-logs-lab-gateway $S1_ACCT)\"],\"RedactedFields\":[{\"SingleHeader\":{\"Name\":\"authorization\"}}]}" \
    --query LoggingConfiguration.LogDestinationConfigs --output text

  say "L3 VPC Lattice access logs on each resource configuration  [network account]"
  mklg $HUB /lab/lattice-access
  # create-access-log-subscription is low-TPS: firing it for both resource configurations
  # back-to-back can throw ThrottlingException on the second call, leaving one configuration
  # without a subscription. Retry on throttling; treat an existing subscription as success.
  for r in $RCFG_ARN ${TOOLS_RCFG_ARN:-}; do
    for attempt in 1 2 3 4 5; do
      out=$(aws vpc-lattice create-access-log-subscription --profile $HUB --region $REGION --resource-identifier "$r" \
            --destination-arn "$(lgarn /lab/lattice-access $HUB_ACCT)" --query id --output text 2>&1) && { echo "  $out"; break; }
      case "$out" in
        *ConflictException*) echo "  (already subscribed for ${r##*/})"; break ;;
        *Throttling*|*TooManyRequests*|*Rate\ exceeded*)
          if [ "$attempt" = 5 ]; then echo "  WARNING: still throttled after 5 attempts; ${r##*/} has NO access-log subscription. Re-run enable."; break; fi
          echo "  throttled (attempt $attempt/5), retrying..."; sleep $((attempt * 3)); continue ;;
        *) echo "  $out"; break ;;   # other errors: report but don't fail the whole enable
      esac
    done
  done

  say "L4 VPC flow logs: agent VPC (Gateway VPCE) + resource gateway (central) VPC  [network account]"
  mklg $HUB /lab/vpc-flow
  if ! aws iam get-role --profile $HUB --role-name lab-flowlogs-role >/dev/null 2>&1; then
    aws iam create-role --profile $HUB --role-name lab-flowlogs-role --assume-role-policy-document \
      '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"vpc-flow-logs.amazonaws.com"},"Action":"sts:AssumeRole","Condition":{"StringEquals":{"aws:SourceAccount":"'"$HUB_ACCT"'"}}}]}' >/dev/null
    aws iam put-role-policy --profile $HUB --role-name lab-flowlogs-role --policy-name cwl --policy-document \
      '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:CreateLogStream","logs:PutLogEvents","logs:DescribeLogGroups","logs:DescribeLogStreams"],"Resource":"'"$(lgarn /lab/vpc-flow $HUB_ACCT)"':*"}]}'
    sleep 10
  fi
  CENTRAL_VPC=$(aws ec2 describe-vpcs --profile $HUB --region $REGION --filters Name=tag:Name,Values=lab-central-vpc --query 'Vpcs[0].VpcId' --output text)
  aws ec2 create-flow-logs --profile $HUB --region $REGION --resource-type VPC --resource-ids "$S1_VPC" "$CENTRAL_VPC" \
    --traffic-type ALL --log-destination-type cloud-watch-logs --log-group-name /lab/vpc-flow \
    --deliver-logs-permission-arn "arn:aws:iam::$HUB_ACCT:role/lab-flowlogs-role" --max-aggregation-interval 60 \
    --query '{ids:FlowLogIds,errors:Unsuccessful[].Error.Message}' --output json

  say "L5 Internal ALB access + connection logs -> S3  [tool account]  (the bucket policy's second statement is the us-east-1 ELB log-delivery account; other Regions need their own, see the ELB documentation)"
  if [ "$REGION" = us-east-1 ]; then aws s3api create-bucket --profile $S2 --region $REGION --bucket $ALB_BUCKET >/dev/null 2>&1 || true
  else aws s3api create-bucket --profile $S2 --region $REGION --bucket $ALB_BUCKET --create-bucket-configuration LocationConstraint=$REGION >/dev/null 2>&1 || true; fi
  aws s3api put-public-access-block --profile $S2 --region $REGION --bucket $ALB_BUCKET \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-policy --profile $S2 --region $REGION --bucket $ALB_BUCKET --policy '{"Version":"2012-10-17","Statement":[
    {"Sid":"ElbLogDeliveryPrincipal","Effect":"Allow","Principal":{"Service":"logdelivery.elasticloadbalancing.amazonaws.com"},"Action":"s3:PutObject","Resource":"arn:aws:s3:::'"$ALB_BUCKET"'/AWSLogs/'"$S2_ACCT"'/*","Condition":{"StringEquals":{"aws:SourceAccount":"'"$S2_ACCT"'"}}},
    {"Sid":"ElbAccountUsEast1Only","Effect":"Allow","Principal":{"AWS":"arn:aws:iam::127311923021:root"},"Action":"s3:PutObject","Resource":"arn:aws:s3:::'"$ALB_BUCKET"'/AWSLogs/'"$S2_ACCT"'/*"}]}'
  aws elbv2 modify-load-balancer-attributes --profile $S2 --region $REGION --load-balancer-arn "$ALB" --attributes \
    Key=access_logs.s3.enabled,Value=true Key=access_logs.s3.bucket,Value=$ALB_BUCKET \
    Key=connection_logs.s3.enabled,Value=true Key=connection_logs.s3.bucket,Value=$ALB_BUCKET \
    --query 'Attributes[?contains(Key,`logs.s3.enabled`)].[Key,Value]' --output text
  say "Logging enabled. Run: ./observability.sh traffic, wait ~5-10 min, then ./observability.sh verify"
}

cmd_traffic() {
  TOK=$(token)
  say "G1 public: employee-api___getEmployee";  public_call '{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"employee-api___getEmployee","arguments":{"employeeId":"4242"}}}'; echo
  say "G2 public: classifier (internal ALB)";   public_call '{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"classifier___classifyQuestion","arguments":{"question":"dental?"}}}'; echo
  say "G3 public: tools-rest (internal ALB)";   public_call '{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"tools-rest___getEmployee","arguments":{"employeeId":"9"}}}'; echo
  say "G4 private ingress: classifier via VPCE"; probe_call '{"jsonrpc":"2.0","id":24,"method":"tools/call","params":{"name":"classifier___classifyQuestion","arguments":{"question":"tooth"}}}'
  say "G5 private ingress: WAF XSS in tool-call ARGUMENTS (body), no bad header"
  probe_call '{"jsonrpc":"2.0","id":25,"method":"tools/call","params":{"name":"classifier___classifyQuestion","arguments":{"question":"<script>alert(1)</script>"}}}'
  say "G6 public: SQLi string in tool-call ARGUMENTS (body)"
  public_call '{"jsonrpc":"2.0","id":26,"method":"tools/call","params":{"name":"classifier___classifyQuestion","arguments":{"question":"1 OR 1=1; DROP TABLE users--"}}}'; echo
  say "G7 public: XSS in tool-call ARGUMENTS (body)"
  public_call '{"jsonrpc":"2.0","id":27,"method":"tools/call","params":{"name":"classifier___classifyQuestion","arguments":{"question":"<script>alert(1)</script>"}}}'; echo
}

lg_tail() { # profile group start_ms filter
  aws logs filter-log-events --profile "$1" --region $REGION --log-group-name "$2" --start-time "$3" \
    ${4:+--filter-pattern "$4"} --query 'events[].message' --output json
}
cmd_verify() {
  local T0=$(( ($(date +%s) - 3600) * 1000 ))
  say "V1 Gateway application logs (/lab/agentcore-gateway)"
  lg_tail $S1 /lab/agentcore-gateway $T0 | python3 -c '
import json,sys
ev=json.load(sys.stdin); print("  events:",len(ev))
for m in ev[-60:]:
    try: d=json.loads(m)
    except Exception: continue
    b=d.get("body") or d
    s=json.dumps(b)
    print("  ",d.get("event_timestamp") or d.get("timestamp",""), "|", s[:260])
' | tail -8
  say "V2 AWS WAF logs (aws-waf-logs-lab-gateway): blocked requests"
  lg_tail $S1 aws-waf-logs-lab-gateway $T0 '{ $.action = "BLOCK" }' | python3 -c '
import json,sys
for m in json.load(sys.stdin)[-6:]:
    d=json.loads(m); r=d["httpRequest"]
    sub=[x["terminatingRule"]["ruleId"] for x in d.get("ruleGroupList",[]) if x.get("terminatingRule")]
    print("  ",d["action"], d.get("terminatingRuleId"), sub, "| clientIp", r["clientIp"], "| uri", r["uri"])'
  say "V3 VPC Lattice access logs (/lab/lattice-access)"
  lg_tail $HUB /lab/lattice-access $T0 | python3 -c '
import json,sys
ev=json.load(sys.stdin); print("  events:",len(ev))
for m in ev[-4:]: print("  ",m[:330])'
  say "V4 VPC flow logs: resource gateway (10.0.x) -> tool VPC (10.12.x):443, and agent (10.11.x) -> Gateway VPCE:443"
  lg_tail $HUB /lab/vpc-flow $T0 '[v, acct, eni, src="10.0.*", dst="10.12.*", sp, dp=443, ...]' | python3 -c '
import json,sys; ev=json.load(sys.stdin); print("  door->tools records:",len(ev)); [print("  ",m) for m in ev[-3:]]'
  lg_tail $HUB /lab/vpc-flow $T0 '[v, acct, eni, src="10.11.*", dst="10.11.*", sp, dp=443, ...]' | python3 -c '
import json,sys; ev=json.load(sys.stdin); print("  agent->VPCE records:",len(ev)); [print("  ",m) for m in ev[-3:]]'
  say "V5 ALB access + connection logs (s3://$ALB_BUCKET)"
  for kind in access conn; do
    if [ $kind = conn ]; then flt="contains(Key,'conn_log')"; else flt="!contains(Key,'conn_log')"; fi
    key=$(aws s3api list-objects-v2 --profile $S2 --region $REGION --bucket $ALB_BUCKET --prefix "AWSLogs/$S2_ACCT/" \
      --query "sort_by(Contents[?$flt],&LastModified)[-1].Key" --output text 2>/dev/null)
    echo "  latest $kind-log object: $key"
    [ -n "$key" ] && [ "$key" != None ] && aws s3 cp --profile $S2 --region $REGION "s3://$ALB_BUCKET/$key" - | gunzip -c | tail -2 | cut -c1-400 | sed 's/^/    /'
  done
  say "V6 CloudTrail: the AgentCore account logs CreateServiceNetworkResourceAssociation; the network account (owner of the shared resource configuration) logs CreateServiceNetworkResourceAssociationBySharee"
  for p in $S1 $HUB; do
    # The event name differs by account: the network account owns the shared resource configuration and logs the
    # ...BySharee variant, because the association was created by the account it is shared with (AgentCore).
    if [ "$p" = "$HUB" ]; then ev=CreateServiceNetworkResourceAssociationBySharee; else ev=CreateServiceNetworkResourceAssociation; fi
    echo "  [$p] $ev: $(aws cloudtrail lookup-events --profile $p --region $REGION --lookup-attributes AttributeKey=EventName,AttributeValue=$ev \
      --max-results 10 --query 'length(Events)' --output text) events; latest:"
    aws cloudtrail lookup-events --profile $p --region $REGION --lookup-attributes AttributeKey=EventName,AttributeValue=$ev \
      --max-results 1 --query 'Events[0].CloudTrailEvent' --output text | python3 -c '
import sys; raw=sys.stdin.read().strip()
if raw in ("", "None"): print("     (none)"); sys.exit(0)
sys.stdin=__import__("io").StringIO(raw)
import json,sys; e=json.load(sys.stdin); print("    ",e["eventTime"], e["userIdentity"].get("type"), e["userIdentity"].get("invokedBy") or e["userIdentity"].get("arn"), "| src", e.get("sourceIPAddress"), "| recipientAccount", e.get("recipientAccountId"))'
  done
}

cmd_policy_test() {
  local POLICY="$TMPD/gw-policy.json"
  sed -e "s#arn:aws:bedrock-agentcore:us-east-1:<agentcore-account-id>:gateway/<gateway-id>#$GW_ARN#g" \
      -e "s#<gateway-vpce-id>#$GW_VPCE#g" "$DIR/gateway-resource-policy.example.json" > "$POLICY"
  TOK=$(token); local body='{"jsonrpc":"2.0","id":31,"method":"tools/list"}'
  say "S0 before policy"; echo "  PUBLIC: $(public_call "$body") | VPCE: $(probe_call "$body")"
  say "S1 put-resource-policy (aws:SourceVpce = $GW_VPCE)"
  # If this script fails or is interrupted after the policy is attached, remove it so the Gateway is not left locked.
  LAB_EXIT_HOOKS+=("aws bedrock-agentcore-control delete-resource-policy --profile $S1 --region $REGION --resource-arn $GW_ARN >/dev/null 2>&1")
  aws bedrock-agentcore-control put-resource-policy --profile $S1 --region $REGION --resource-arn "$GW_ARN" --policy "file://$POLICY" >/dev/null
  local t0; t0=$(date +%s); local ok=0
  for i in $(seq 1 32); do
    sleep 30
    local p v; p=$(public_call "$body"); v=$(probe_call "$body")
    printf '  +%4ss  PUBLIC: %s | VPCE: %s\n' $(( $(date +%s) - t0 )) "${p:0:120}" "${v:0:60}"
    if [[ "$p" == "HTTP 403"* ]]; then ok=$((ok+1)); else ok=0; fi
    [ $ok -ge 3 ] && break
  done
  say "S2 delete-resource-policy (restore public path for the remaining lab tests)"
  aws bedrock-agentcore-control delete-resource-policy --profile $S1 --region $REGION --resource-arn "$GW_ARN" >/dev/null
  LAB_EXIT_HOOKS=()
  t0=$(date +%s)
  for i in $(seq 1 32); do
    sleep 30; local p; p=$(public_call "$body"); printf '  +%4ss  PUBLIC: %s\n' $(( $(date +%s) - t0 )) "${p:0:100}"
    [[ "$p" == "HTTP 200"* ]] && break
  done
}

case "${1:-}" in
  enable) cmd_enable;; traffic) cmd_traffic;; verify) cmd_verify;; policy-test) cmd_policy_test;;
  *) exit 1;;
esac
