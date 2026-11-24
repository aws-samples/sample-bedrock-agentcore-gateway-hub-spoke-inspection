#!/usr/bin/env bash
# Retest 2026-11-23: AgentCore Gateway MANAGED mode with the resource gateway in a SHARED subnet
# (VPC Lattice participant-owned resource gateway, VPC Lattice doc history: 10 November 2026).
#   N1c  call through the managed target with the lab's network policy unchanged (expect blocked)
#   S    network-account changes: execute-api endpoint SG + firewall pass rule for the agent range (expect success)
#   R    reply-direction drop for the agent range (expect timeout + firewall drop log), then restore
# Everything it changes is restored on exit: firewall rule group, endpoint SG rule, target, security group.
set -Eeuo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"
# shellcheck disable=SC1090  # lab state file written by run-lab.sh deploy
source "$LAB_STATE"
HUB_ACCT=$(acct "$HUB")
AGENT_NET=10.11.0.0/16; TOOL_NET=10.12.0.0/16
RG_ARN="arn:aws:network-firewall:$REGION:$HUB_ACCT:stateful-rulegroup/lab-allow-door-to-api"
VPCE_SG=$(aws ec2 describe-vpc-endpoints --profile $HUB --region $REGION --vpc-endpoint-ids "$API_VPCE_ID" --query 'VpcEndpoints[0].Groups[0].GroupId' --output text)
ORIG_RULES="$TMPD/orig-rules.txt"
aws network-firewall describe-rule-group --profile $HUB --region $REGION --rule-group-arn "$RG_ARN" \
  --query 'RuleGroup.RulesSource.RulesString' --output text > "$ORIG_RULES"
TID=""; SG=""; SG_RULE_ADDED=0; RULES_CHANGED=0

set_rules() { # file-with-rules-string: replace ONLY the rules text, keep variables and rule order
  aws network-firewall describe-rule-group --profile $HUB --region $REGION --rule-group-arn "$RG_ARN" --output json > "$TMPD/rg.json"
  python3 - "$1" "$TMPD/rg.json" > "$TMPD/rs.json" <<'PY'
import json,sys
rg=json.load(open(sys.argv[2]))["RuleGroup"]
rg["RulesSource"]={"RulesString":open(sys.argv[1]).read()}
print(json.dumps({k:v for k,v in rg.items() if k in ("RuleVariables","ReferenceSets","RulesSource","StatefulRuleOptions")}))
PY
  local tok; tok=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["UpdateToken"])' "$TMPD/rg.json")
  aws network-firewall update-rule-group --profile $HUB --region $REGION --rule-group-arn "$RG_ARN" \
    --update-token "$tok" --rule-group "file://$TMPD/rs.json" --query 'RuleGroupResponse.RuleGroupStatus' --output text
}
restore() {
  set +e
  echo; echo "==> RESTORE"
  [ $RULES_CHANGED = 1 ] && { set_rules "$ORIG_RULES"; echo "  firewall rules restored"; }
  [ $SG_RULE_ADDED = 1 ] && aws ec2 revoke-security-group-ingress --profile $HUB --region $REGION --group-id "$VPCE_SG" \
      --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":443,\"ToPort\":443,\"IpRanges\":[{\"CidrIp\":\"$AGENT_NET\"}]}]" >/dev/null && echo "  endpoint SG rule removed"
  [ -n "$TID" ] && aws bedrock-agentcore-control delete-gateway-target --profile $S1 --region $REGION --gateway-identifier "$GW_ID" --target-id "$TID" >/dev/null && echo "  target $TID deleted"
  if [ -n "$SG" ]; then
    for _ in $(seq 1 40); do aws ec2 delete-security-group --profile $S1 --region $REGION --group-id "$SG" 2>/dev/null && { echo "  SG $SG deleted"; break; }; sleep 15; done
  fi
}
LAB_EXIT_HOOKS+=(restore)   # lib.sh runs exit hooks, then removes $TMPD

call() { # id -> prints first 300 chars of the response, or a timeout line
  local TOK; TOK=$(lab_token)
  curl -s -m 70 -X POST "$GW_URL" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":$1,\"method\":\"tools/call\",\"params\":{\"name\":\"retest-managed-shared___getEmployee\",\"arguments\":{\"employeeId\":\"$1\"}}}" \
    | cut -c1-400 || echo "  no response within 70s (curl exit $?)"
  echo
}
fw_events() { # since-epoch-s jq-free filter on src or dest in agent range -> prints up to 5 lines
  aws logs filter-log-events --profile $HUB --region $REGION --log-group-name /lab/network-firewall --start-time $(( $1 * 1000 )) \
    --filter-pattern '{ $.event.event_type = "alert" }' --query 'events[].message' --output text | tr '\t' '\n' | python3 -c '
import sys,json
for l in sys.stdin:
    if not l.strip().startswith("{"): continue
    e=json.loads(l)["event"]
    if e["src_ip"].startswith("10.11.") or e["dest_ip"].startswith("10.11."):
        print(" ",e["timestamp"][:19],e["src_ip"],e["src_port"],"->",e["dest_ip"],e["dest_port"],"|",e.get("direction"),"|",e["alert"]["action"],"|",e["alert"]["signature_id"],e["alert"]["signature"])' | tail -5
}
poll_fw() { local h=""; for _ in $(seq 1 10); do sleep 30; h=$(fw_events "$1"); [ -n "$h" ] && break; done; echo "${h:-  (no firewall alert records for 10.11.x)}"; }

say "SETUP managed target in the SHARED agent subnets with an AgentCore-owned SG (egress 443 to the tool VPC only)"
SG=$(aws ec2 create-security-group --profile $S1 --region $REGION --vpc-id "$S1_VPC" --group-name lab-retest-managed-$RANDOM \
      --description "lab retest: AgentCore-owned SG for a managed resource gateway in a shared subnet" --query GroupId --output text)
aws ec2 revoke-security-group-egress --profile $S1 --region $REGION --group-id "$SG" --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null
aws ec2 authorize-security-group-egress --profile $S1 --region $REGION --group-id "$SG" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":443,\"ToPort\":443,\"IpRanges\":[{\"CidrIp\":\"$TOOL_NET\"}]}]" >/dev/null
echo "  SG $SG owner $(aws ec2 describe-security-groups --profile $S1 --region $REGION --group-ids $SG --query 'SecurityGroups[0].OwnerId' --output text)"
python3 - "$API_HOST" "$CP_ARN" "$S1_VPC" "$S1_SUBNETS" "$API_VPCE_DNS" "$SG" > "$TMPD/t.json" <<'PY'
import json,sys
host,cp,vpc,subnets,rdom,sg=sys.argv[1:7]
spec={"openapi":"3.0.1","info":{"title":"retest","version":"1"},"servers":[{"url":f"https://{host}/prod"}],
 "paths":{"/employees/{employeeId}":{"get":{"operationId":"getEmployee","parameters":[{"name":"employeeId","in":"path","required":True,"schema":{"type":"string"}}],
 "responses":{"200":{"description":"ok","content":{"application/json":{"schema":{"type":"object"}}}}}}}}}
print(json.dumps({"name":"retest-managed-shared","targetConfiguration":{"mcp":{"openApiSchema":{"inlinePayload":json.dumps(spec)}}},
 "credentialProviderConfigurations":[{"credentialProviderType":"OAUTH","credentialProvider":{"oauthCredentialProvider":{"providerArn":cp,"scopes":["lab-api/invoke"],"grantType":"CLIENT_CREDENTIALS"}}}],
 "privateEndpoint":{"managedVpcResource":{"vpcIdentifier":vpc,"subnetIds":subnets.split(","),"endpointIpAddressType":"IPV4","routingDomain":rdom,"securityGroupIds":[sg]}}}))
PY
T0=$(date +%s)
TID=$(aws bedrock-agentcore-control create-gateway-target --profile $S1 --region $REGION --gateway-identifier "$GW_ID" --cli-input-json "file://$TMPD/t.json" --query targetId --output text)
for _ in $(seq 1 40); do s=$(aws bedrock-agentcore-control get-gateway-target --profile $S1 --region $REGION --gateway-identifier "$GW_ID" --target-id "$TID" --query status --output text); [ "$s" = CREATING ] || [ "$s" = SYNCHRONIZING ] || break; sleep 15; done
echo "  target $TID status $s after $(( $(date +%s) - T0 ))s"
aws bedrock-agentcore-control get-gateway-target --profile $S1 --region $REGION --gateway-identifier "$GW_ID" --target-id "$TID" --query '{reasons:statusReasons,managed:privateEndpointManagedResources}' --output json
[ "$s" = READY ] || exit 1
sleep 60   # data-path propagation after READY

say "N1c call with the network policy UNCHANGED (endpoint SG allows only 10.0.0.0/16; firewall passes only the resource gateway subnets)"
T1=$(date +%s); call 101
echo "  firewall alerts involving the agent range:"; poll_fw $T1

say "S1 network account: allow the agent range in the execute-api endpoint SG"
SG_RULE_ADDED=1
aws ec2 authorize-security-group-ingress --profile $HUB --region $REGION --group-id "$VPCE_SG" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":443,\"ToPort\":443,\"IpRanges\":[{\"CidrIp\":\"$AGENT_NET\",\"Description\":\"retest: agent subnets (managed resource gateway)\"}]}]" >/dev/null
sleep 20
say "S2 call with the endpoint SG opened but the firewall unchanged"
T2=$(date +%s); call 102
echo "  firewall alerts involving the agent range:"; poll_fw $T2

say "S3 network account: add a firewall pass rule for the agent range -> tool VPC 443"
{ echo "pass tcp $AGENT_NET any -> $TOOL_NET 443 (msg:\"RETEST ALLOW managed resource gateway (agent subnets) -> tool VPC 443\"; flow:to_server; sid:100200; rev:1;)"; cat "$ORIG_RULES"; } > "$TMPD/s3.txt"
RULES_CHANGED=1; set_rules "$TMPD/s3.txt"; sleep 90
say "S4 call with both network changes"
call 103

say "R1 add a reply-direction drop for the agent range (before the pass rules)"
{ echo "drop tcp $TOOL_NET 443 -> $AGENT_NET any (msg:\"RETEST PROOF return path blocked (managed)\"; flow:to_client; sid:100298; rev:1;)"; cat "$TMPD/s3.txt"; } > "$TMPD/r1.txt"
set_rules "$TMPD/r1.txt"; sleep 90
say "R2 call (expect no data)"
T3=$(date +%s); call 104
echo "  firewall drop records (sid 100298):"; poll_fw $T3

say "R3 remove the drop rule, call again"
set_rules "$TMPD/s3.txt"; sleep 90
call 105
