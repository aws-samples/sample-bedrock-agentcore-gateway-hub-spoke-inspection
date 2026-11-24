#!/usr/bin/env bash
# =====================================================================================
# Lab: AgentCore Gateway reaches private APIs through a VPC Lattice resource gateway that the
# NETWORK account owns, so every request and reply still crosses the central firewall.
#
# What it proves:
#   Agent -> AgentCore Gateway (Cognito JWT + AWS WAF)                      [AgentCore account]
#        -> self-managed VPC Lattice resource configuration, shared with AWS RAM by the network account
#        -> resource gateway in network-account-owned, NON-shared subnets   [network account]
#        -> route table -> Transit Gateway -> inspection VPC (AWS Network Firewall stands in for a third-party firewall)
#        -> Transit Gateway -> network-account-owned execute-api endpoint or internal ALB in a SHARED tool VPC
#        -> private API Gateway REST API, or internal ALB with MCP and REST backends   [tool account]
#   Application accounts never touch VPC, subnet or routing resources.
#
# Usage:  ./run-lab.sh deploy | test | negative | evidence | prove-multi | prove-return | prove-vpce-policy
#                      | prove-ram-permission | prove-sharee-scp | alb | test-alb | extra-tools | runtime | test-runtime | teardown
#         See ../README.md for the order, prerequisites, cost and clean-up notes.
# Needs:  AWS CLI v2 2.37.7 or later, python3, curl, openssl. Three profiles (see lib.sh for the env-var contract):
#         lab-hub, lab-spoke1, lab-spoke2 (for example OrganizationAccountAccessRole from the organization's management account)
# Region: us-east-1 only as shipped (01-hub-network.yaml uses us-east-1 Availability Zone IDs).
# =====================================================================================
set -Eeuo pipefail

usage() { echo "usage: $0 deploy | test | negative | evidence | prove-multi | prove-return | prove-vpce-policy | prove-ram-permission | alb | test-alb | extra-tools | runtime | test-runtime | teardown"; }
case "${1:-}" in
  deploy|test|negative|evidence|prove-multi|prove-return|prove-vpce-policy|prove-ram-permission|prove-sharee-scp|alb|test-alb|extra-tools|runtime|test-runtime|teardown) ;;
  *) usage; exit 1;;
esac

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"
HUB_ACCT=$(acct "$HUB"); S1_ACCT=$(acct "$S1"); S2_ACCT=$(acct "$S2")
export S1_PROFILE=$S1 AWS_REGION=$REGION   # consumed by the Python scripts
STATE="$LAB_STATE"
touch "$STATE"; source "$STATE"

save() { sed -i.bak "/^$1=/d" "$STATE" && rm -f "$STATE.bak"; printf '%s=%q\n' "$1" "$2" >> "$STATE"; export "$1=$2"; }
out()  { # profile stack output-key; fails if the output is missing (set -e does not catch failures inside "$(...)" arguments)
  local v; v=$(aws cloudformation describe-stacks --profile "$1" --region $REGION --stack-name "$2" \
           --query "Stacks[0].Outputs[?OutputKey=='$3'].OutputValue" --output text) || return 1
  [ -n "$v" ] && [ "$v" != None ] || { echo "ERROR: stack $2 has no output $3" >&2; return 1; }
  printf '%s' "$v"; }
saveout() { # VAR profile stack output-key
  local v; v=$(out "$2" "$3" "$4") || exit 1; save "$1" "$v"; }
deploy_stack() { # profile stack template [params...]
  local p=$1 s=$2 t=$3; shift 3
  aws cloudformation deploy --profile "$p" --region $REGION --stack-name "$s" \
    --template-file "$DIR/$t" --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset \
    ${1:+--parameter-overrides "$@"}
}

# Create (or reuse) an AgentCore OAuth2 credential provider for a Cognito app client in another account.
# The client secret never appears on a command line: it goes to a 0600 temp file that --cli-input-json reads.
ensure_oauth_provider() { # provider-name owner-profile user-pool-id client-id -> prints the provider ARN
  local name=$1 owner=$2 pool=$3 cid=$4 f="$TMPD/ocp.$RANDOM.json" arn
  aws cognito-idp describe-user-pool-client --profile "$owner" --region $REGION --user-pool-id "$pool" --client-id "$cid" \
      --query UserPoolClient.ClientSecret --output text \
    | python3 -c 'import json,sys
name, pool, cid, region = sys.argv[1:5]
print(json.dumps({"name": name, "credentialProviderVendor": "CustomOauth2", "oauth2ProviderConfigInput": {"customOauth2ProviderConfig": {
  "oauthDiscovery": {"discoveryUrl": f"https://cognito-idp.{region}.amazonaws.com/{pool}/.well-known/openid-configuration"},
  "clientId": cid, "clientSecret": sys.stdin.read().strip()}}}))' "$name" "$pool" "$cid" "$REGION" > "$f"
  arn=$(aws bedrock-agentcore-control create-oauth2-credential-provider --profile $S1 --region $REGION \
          --cli-input-json "file://$f" --query credentialProviderArn --output text 2>/dev/null) \
    || arn=$(aws bedrock-agentcore-control get-oauth2-credential-provider --profile $S1 --region $REGION \
          --name "$name" --query credentialProviderArn --output text) || { rm -f "$f"; return 1; }
  rm -f "$f"; printf '%s' "$arn"
}

preflight() {
  say "Preflight: identities"
  for p in $HUB $S1 $S2; do
    printf '%-11s ' "$p"; aws sts get-caller-identity --profile "$p" --query Account --output text
  done
  # Confirm the CLI model knows --certificate-configurations. Do NOT grep `... help`:
  # on some CLI builds (e.g. 2.37.9) the help renderer itself errors ("list index out of
  # range"), so the grep finds nothing and falsely reports "CLI too old". Probe parameter
  # validation instead: an old model rejects the flag as an unknown option; a new model
  # accepts the flag and only complains about the (deliberately empty/invalid) value.
  local probe
  probe=$(aws bedrock-agentcore-control create-gateway-target --gateway-identifier _probe --name _probe \
            --target-configuration '{}' --certificate-configurations '[]' \
            --profile "$S1" --region "$REGION" 2>&1 || true)
  case "$probe" in
    *"Unknown options"*|*"nknown option"*)
      die "AWS CLI too old: need 2.37.7 or later (create-gateway-target --certificate-configurations)" ;;
    *) : ;;  # flag recognized; value/validation errors are expected here and are fine
  esac
}

cmd_deploy() {
  preflight

  say "1/7 Hub network + Lattice door + RAM shares (~10-15 min: TGW + Network Firewall)"
  deploy_stack $HUB lab-hub-network 01-hub-network.yaml \
    AgentCoreAccountId=$S1_ACCT ApiAccountId=$S2_ACCT ExtraApiAccountId=$S1_ACCT
  saveout API_VPCE_ID $HUB lab-hub-network ApiVpceId
  saveout API_VPCE_DNS $HUB lab-hub-network ApiVpceDns
  saveout RCFG_ARN $HUB lab-hub-network ResourceConfigArn
  saveout S1_VPC $HUB lab-hub-network Spoke1VpcId
  saveout S1_SUBNETS $HUB lab-hub-network Spoke1SharedSubnets

  say "2/7 API account: private REST API with its own Cognito authorizer"
  deploy_stack $S2 lab-spoke2-api 02-spoke2-api.yaml ApiVpceId=$API_VPCE_ID DomainPrefix=lab-demo-api-$S2_ACCT
  saveout API_HOST $S2 lab-spoke2-api ApiHostname

  say "3/7 AgentCore account: Cognito + WAF + Gateway role"
  deploy_stack $S1 lab-spoke1-inbound 03-spoke1-inbound.yaml DomainPrefix=lab-demo-agentcore-$S1_ACCT
  saveout DISCOVERY_URL $S1 lab-spoke1-inbound DiscoveryUrl
  saveout TOKEN_URL $S1 lab-spoke1-inbound TokenUrl
  saveout CLIENT_ID $S1 lab-spoke1-inbound ClientId
  saveout USER_POOL_ID $S1 lab-spoke1-inbound UserPoolId
  saveout WEB_ACL_ARN $S1 lab-spoke1-inbound WebAclArn
  saveout GW_ROLE_ARN $S1 lab-spoke1-inbound GatewayRoleArn

  say "4/7 Accept any pending RAM invitations in AgentCore account (auto-accepted if org sharing is on)"
  for inv in $(aws ram get-resource-share-invitations --profile $S1 --region $REGION \
                 --query "resourceShareInvitations[?status=='PENDING'].resourceShareInvitationArn" --output text); do
    aws ram accept-resource-share-invitation --profile $S1 --region $REGION --resource-share-invitation-arn "$inv" >/dev/null
  done
  aws vpc-lattice get-resource-configuration --profile $S1 --region $REGION \
    --resource-configuration-identifier "$RCFG_ARN" --query '{name:name,status:status}' --output table

  say "5/7 OAuth credential provider for the API account's Cognito (AgentCore Identity token vault)"
  save CP_ARN "$(ensure_oauth_provider lab-employee-api-oauth "$S2" "$(out $S2 lab-spoke2-api ApiPoolId)" "$(out $S2 lab-spoke2-api ApiClientId)")"

  say "6/7 Gateway (MCP, Cognito JWT) + WAF association"
  if [ -z "${GW_ID:-}" ]; then
    AUTHZ=$(python3 -c 'import json,sys;print(json.dumps({"customJWTAuthorizer":{"discoveryUrl":sys.argv[1],"allowedClients":[sys.argv[2]]}}))' "$DISCOVERY_URL" "$CLIENT_ID")
    GW_ID=$(aws bedrock-agentcore-control create-gateway --profile $S1 --region $REGION \
      --name lab-demo-gateway --role-arn "$GW_ROLE_ARN" --protocol-type MCP \
      --authorizer-type CUSTOM_JWT --authorizer-configuration "$AUTHZ" --query gatewayId --output text)
    save GW_ID "$GW_ID"
  fi
  wait_status gateway
  save GW_URL "$(aws bedrock-agentcore-control get-gateway --profile $S1 --region $REGION --gateway-identifier $GW_ID --query gatewayUrl --output text)"
  save GW_ARN "$(aws bedrock-agentcore-control get-gateway --profile $S1 --region $REGION --gateway-identifier $GW_ID --query gatewayArn --output text)"
  # Right after a Gateway is created, WAF can briefly fail with WAFUnavailableEntityException
  # ("couldn't retrieve the resource ... Retry your request") because the Gateway resource is
  # not yet visible to WAF. Skip if already associated (idempotent re-runs), else retry.
  if aws wafv2 get-web-acl-for-resource --profile $S1 --region $REGION --resource-arn "$GW_ARN" \
       --query 'WebACL.Name' --output text 2>/dev/null | grep -q lab-gateway-waf; then
    echo "WAF already associated."
  else
    local waf_ok=0 waf_err="$TMPD/waf-associate.err"
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      if aws wafv2 associate-web-acl --profile $S1 --region $REGION --web-acl-arn "$WEB_ACL_ARN" --resource-arn "$GW_ARN" 2>"$waf_err"; then
        waf_ok=1; break
      fi
      if grep -qi 'WAFUnavailableEntity\|couldn.t retrieve' "$waf_err"; then
        echo "  WAF not ready yet (attempt $attempt/10), retrying in 15s..."; sleep 15; continue
      fi
      cat "$waf_err" >&2; die "associate-web-acl failed"
    done
    # Without this, exhausting the retries fell through and deploy continued with no web ACL on the Gateway.
    [ "$waf_ok" = 1 ] || { cat "$waf_err" >&2; die "WAF still could not see the Gateway after 10 attempts; re-run deploy"; }
    echo "WAF associated: $(aws wafv2 get-web-acl-for-resource --profile $S1 --region $REGION --resource-arn "$GW_ARN" --query WebACL.Name --output text)"
  fi
  say "6b/7 Network account: Gateway interface endpoint policy allows only this Gateway"
  deploy_stack $HUB lab-hub-network 01-hub-network.yaml AgentCoreAccountId=$S1_ACCT ApiAccountId=$S2_ACCT ApprovedGatewayArns=$GW_ARN

  say "7/7 OpenAPI target -> SELF-MANAGED Lattice (shared address card from hub)"
  python3 - "$API_HOST" "$CP_ARN" "$RCFG_ARN" > "$TMPD/target.json" <<'PY'
import json, sys
host, cp, rcfg = sys.argv[1:4]
spec = {
  "openapi": "3.0.1",
  "info": {"title": "Employee API (private, tool account)", "version": "1.0"},
  "servers": [{"url": f"https://{host}/prod"}],
  "paths": {
    "/": {"get": {"operationId": "listPlans", "summary": "List benefit plans",
                  "responses": {"200": {"description": "ok", "content": {"application/json": {"schema": {"type": "object"}}}}}}},
    "/employees/{employeeId}": {"get": {"operationId": "getEmployee", "summary": "Get an employee by id",
        "parameters": [{"name": "employeeId", "in": "path", "required": True, "schema": {"type": "string"}}],
        "responses": {"200": {"description": "ok", "content": {"application/json": {"schema": {"type": "object"}}}}}}}
  }
}
print(json.dumps({
  "name": "employee-api",
  "description": "Private REST API via hub Lattice door",
  "targetConfiguration": {"mcp": {"openApiSchema": {"inlinePayload": json.dumps(spec)}}},
  "credentialProviderConfigurations": [{
    "credentialProviderType": "OAUTH",
    "credentialProvider": {"oauthCredentialProvider": {
      "providerArn": cp, "scopes": ["lab-api/invoke"], "grantType": "CLIENT_CREDENTIALS"}}}],
  "privateEndpoint": {"selfManagedLatticeResource": {"resourceConfigurationIdentifier": rcfg}}
}))
PY
  if [ -z "${TARGET_ID:-}" ]; then
    TARGET_ID=$(aws bedrock-agentcore-control create-gateway-target --profile $S1 --region $REGION \
      --gateway-identifier "$GW_ID" --cli-input-json "file://$TMPD/target.json" --query targetId --output text)
    save TARGET_ID "$TARGET_ID"
  fi
  wait_status target
  say "DEPLOYED. Next: ./run-lab.sh test"
}

wait_status() { # gateway | target
  for i in $(seq 1 60); do
    if [ "$1" = gateway ]; then
      s=$(aws bedrock-agentcore-control get-gateway --profile $S1 --region $REGION --gateway-identifier $GW_ID --query status --output text)
    else
      s=$(aws bedrock-agentcore-control get-gateway-target --profile $S1 --region $REGION --gateway-identifier $GW_ID --target-id $TARGET_ID --query status --output text)
    fi
    echo "  $1 status: $s"
    case $s in READY) return 0;; *FAILED*|*UNSUCCESSFUL*|*PENDING_AUTH*)
      aws bedrock-agentcore-control get-gateway-target --profile $S1 --region $REGION --gateway-identifier $GW_ID \
        --target-id "${TARGET_ID:-x}" --query statusReasons 2>/dev/null || true; return 1;; esac
    sleep 10
  done; echo "timed out"; return 1
}

token() { lab_token; }
mcp() { # json-rpc body
  curl -s -X POST "$GW_URL" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d "$1"
}
# Right after a target becomes READY, the VPC Lattice data path can take ~30-60s more to propagate; the first
# call then returns a generic "An internal error occurred" (isError). mcp_retry repeats the real call for up to
# ~90s and prints the last response. It returns 1 if the call never succeeded, so callers can fail loudly.
# This is a readiness wait, not a result change: the printed body is the actual check.
mcp_retry() { # json-rpc body
  local out attempt
  for attempt in $(seq 1 9); do
    out=$(mcp "$1")
    case "$out" in
      *'"isError":true'*|*'An internal error occurred'*)
        echo "  data path not ready yet (attempt $attempt/9), waiting 10s..." >&2; sleep 10 ;;
      *) printf '%s' "$out"; return 0 ;;
    esac
  done
  printf '%s' "$out"; return 1
}

cmd_test() {
  TOK=$(token)
  say "T1 tools/list (expect employee-api___listPlans, employee-api___getEmployee)"
  mcp '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | python3 -m json.tool
  say "T2 tools/call getEmployee 12345 (path: Gateway -> hub door -> TGW -> firewall -> VPCE -> private API)"
  local t2out t2rc=0
  t2out=$(mcp_retry '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"employee-api___getEmployee","arguments":{"employeeId":"12345"}}}') || t2rc=1
  echo "$t2out" | python3 -m json.tool
  echo "  -> 'sourceIp' in the body should be a 10.0.x.x DOOR address (hub), proving the API sees the door IP."
  say "T3 no token (expect 401 from Gateway)"
  curl -s -o /dev/null -w '  HTTP %{http_code}\n' -X POST "$GW_URL" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":3,"method":"tools/list"}'
  say "T4 WAF: script tag in the User-Agent header plus a SQLi-style query string (expect a WAF block; a header match returns an HTML HTTP 403 page)"
  curl -s -w '\n  HTTP %{http_code}\n' -X POST "$GW_URL?id=1%27%20OR%20%271%27=%271" -H "Authorization: Bearer $TOK" \
    -H 'Content-Type: application/json' -H 'User-Agent: <script>alert(1)</script>' -d '{"jsonrpc":"2.0","id":4,"method":"tools/list"}'
  say "T5 direct call to private API from the internet (expect DNS/connection failure - API is private)"
  curl -s -m 8 -o /dev/null -w '  HTTP %{http_code}\n' "https://$API_HOST/prod/" || echo "  unreachable (expected)"
  [ "$t2rc" = 0 ] || die "T2 did not succeed within ~90s (see the response above)"
}

cmd_negative() {
  # Check 4. VPC Lattice lets a participant account create a resource gateway in a shared subnet only with a security
  # group the participant owns; the VPC's default security group (owned by the network account) returns "cannot be found".
  #   4a managedVpcResource WITHOUT securityGroupIds -> FAILED, 400 "Security groups are required for shared subnet"
  #   4b managedVpcResource WITH a security group the AgentCore account owns
  # Both use the shared agent subnets, and the execute-api endpoint as routing domain.
  local SG NEG_A
  NEG_B=""
  neg_body() { # name sg-id-or-empty
    python3 - "$API_HOST" "$CP_ARN" "$S1_VPC" "$S1_SUBNETS" "$API_VPCE_DNS" "$1" "$2" <<'PY'
import json, sys
host, cp, vpc, subnets, rdom, name, sg = sys.argv[1:8]
spec = {"openapi":"3.0.1","info":{"title":"neg","version":"1"},"servers":[{"url":f"https://{host}/prod"}],
        "paths":{"/employees/{employeeId}":{"get":{"operationId":"getEmployee","parameters":[{"name":"employeeId","in":"path","required":True,"schema":{"type":"string"}}],
                 "responses":{"200":{"description":"ok","content":{"application/json":{"schema":{"type":"object"}}}}}}}}}
mvr = {"vpcIdentifier":vpc,"subnetIds":subnets.split(","),"endpointIpAddressType":"IPV4","routingDomain":rdom}
if sg: mvr["securityGroupIds"] = [sg]
print(json.dumps({"name":name,
  "targetConfiguration":{"mcp":{"openApiSchema":{"inlinePayload":json.dumps(spec)}}},
  "credentialProviderConfigurations":[{"credentialProviderType":"OAUTH","credentialProvider":{"oauthCredentialProvider":
     {"providerArn":cp,"scopes":["lab-api/invoke"],"grantType":"CLIENT_CREDENTIALS"}}}],
  "privateEndpoint":{"managedVpcResource":mvr}}))
PY
  }
  neg_wait() { # target-id -> prints final status json
    local s i
    for i in $(seq 1 40); do
      s=$(aws bedrock-agentcore-control get-gateway-target --profile $S1 --region $REGION --gateway-identifier "$GW_ID" --target-id "$1" --query status --output text)
      case "$s" in CREATING|UPDATING|SYNCHRONIZING) sleep 15;; *) break;; esac
    done
    aws bedrock-agentcore-control get-gateway-target --profile $S1 --region $REGION --gateway-identifier "$GW_ID" --target-id "$1" \
      --query '{status:status,reasons:statusReasons,managed:privateEndpointManagedResources}' --output json
  }
  neg_delete() { [ -n "${1:-}" ] && aws bedrock-agentcore-control delete-gateway-target --profile $S1 --region $REGION --gateway-identifier "$GW_ID" --target-id "$1" >/dev/null 2>&1 || true; }
  neg_cleanup_sg() { # the managed resource gateway is deleted asynchronously after its last target; the SG can go only after that
    local i
    for i in $(seq 1 40); do aws ec2 delete-security-group --profile $S1 --region $REGION --group-id "$1" 2>/dev/null && { echo "  deleted $1"; return 0; }; sleep 15; done
    echo "  WARNING: security group $1 still in use; delete it by hand later"
  }

  say "N1a (check 4a) MANAGED mode on the SHARED agent subnets, no securityGroupIds (expect FAILED: security groups are required for shared subnets)"
  neg_body neg-managed-default-sg "" > "$TMPD/neg-a.json"
  NEG_A=$(aws bedrock-agentcore-control create-gateway-target --profile $S1 --region $REGION \
    --gateway-identifier "$GW_ID" --cli-input-json "file://$TMPD/neg-a.json" --query targetId --output text 2>&1) || { echo "  rejected at create: $NEG_A"; NEG_A=""; }
  [ -n "$NEG_A" ] && { neg_wait "$NEG_A"; neg_delete "$NEG_A"; }

  say "N1b (check 4b) MANAGED mode on the SAME shared subnets, with a security group the AgentCore account owns"
  SG=$(aws ec2 create-security-group --profile $S1 --region $REGION --vpc-id "$S1_VPC" --group-name lab-neg-managed-rgw-$RANDOM \
        --description "lab check 4b: AgentCore-owned SG for a managed resource gateway" --query GroupId --output text)
  LAB_EXIT_HOOKS+=("neg_delete \"\$NEG_B\"; neg_cleanup_sg $SG")
  aws ec2 revoke-security-group-egress --profile $S1 --region $REGION --group-id "$SG" \
    --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null
  aws ec2 authorize-security-group-egress --profile $S1 --region $REGION --group-id "$SG" \
    --ip-permissions '[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"10.12.0.0/16","Description":"tool VPC"}]}]' >/dev/null
  echo "  security group $SG, owner $(aws ec2 describe-security-groups --profile $S1 --region $REGION --group-ids $SG --query 'SecurityGroups[0].OwnerId' --output text)"
  neg_body neg-managed-own-sg "$SG" > "$TMPD/neg-b.json"
  NEG_B=$(aws bedrock-agentcore-control create-gateway-target --profile $S1 --region $REGION \
    --gateway-identifier "$GW_ID" --cli-input-json "file://$TMPD/neg-b.json" --query targetId --output text 2>&1) || { echo "  rejected at create: $NEG_B"; NEG_B=""; }
  if [ -n "$NEG_B" ]; then
    local res rgw T0 h i
    res=$(neg_wait "$NEG_B"); echo "$res"
    if grep -q '"READY"' <<<"$res"; then
      rgw=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["managed"][0]["resourceGatewayArn"])' <<<"$res" 2>/dev/null || true)
      echo "  managed resource gateway, as the AgentCore account sees it:"
      aws vpc-lattice get-resource-gateway --profile $S1 --region $REGION --resource-gateway-identifier "$rgw" \
        --query '{arn:arn,vpc:vpcIdentifier,subnets:subnetIds,sgs:securityGroupIds,status:status}' --output json || true
      echo "  resource gateways the network account (VPC owner) can list:"
      aws vpc-lattice list-resource-gateways --profile $HUB --region $REGION --query 'items[].{name:name,vpc:vpcIdentifier}' --output json
      say "N1c call through the managed target (its traffic leaves from the agent subnets, which the execute-api endpoint security group and the firewall policy do not allow)"
      T0=$(date +%s); TOK=$(token)
      curl -s -m 70 -X POST "$GW_URL" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"neg-managed-own-sg___getEmployee","arguments":{"employeeId":"4"}}}' | cut -c1-200; echo
      echo "  firewall alerts for agent subnets (10.11.x) -> tool VPC :443, polled for up to 4 minutes:"
      h=""
      for i in $(seq 1 8); do sleep 30
        h=$(aws logs filter-log-events --profile $HUB --region $REGION --log-group-name /lab/network-firewall --start-time $((T0*1000)) \
          --filter-pattern '{ $.event.event_type = "alert" && $.event.dest_port = 443 }' --query 'events[].message' --output text | tr '\t' '\n' | python3 -c '
import sys, json
for l in sys.stdin:
    if not l.strip().startswith("{"): continue
    e = json.loads(l)["event"]
    if e["src_ip"].startswith("10.11."): print(" ", e["timestamp"][:19], e["src_ip"], "->", e["dest_ip"], e["dest_port"], "|", e["alert"]["action"], "|", e["alert"]["signature"])
' | tail -3) || true
        [ -n "$h" ] && break
      done
      echo "${h:-  (no alert records found)}"
    fi
  fi
  say "N1d clean up the 4b target and security group"
  neg_delete "$NEG_B"; NEG_B=""; neg_cleanup_sg "$SG"; LAB_EXIT_HOOKS=()
}

cmd_evidence() {
  say "E0 VPC Lattice association per target (targets on the same resource configuration: shared or separate association?)"
  for t in $(aws bedrock-agentcore-control list-gateway-targets --profile $S1 --region $REGION --gateway-identifier $GW_ID --query 'items[].targetId' --output text); do
    aws bedrock-agentcore-control get-gateway-target --profile $S1 --region $REGION --gateway-identifier $GW_ID --target-id $t \
      --query '[name, privateEndpoint.selfManagedLatticeResource.resourceConfigurationIdentifier, privateEndpointManagedResources[0].resourceAssociationArn]' --output text
  done | awk '{n=split($2,a,"/"); m=split($3,b,"/"); print "  "$1"  rcfg="a[n]"  association="b[m]}'
  aws vpc-lattice list-service-network-resource-associations --profile $S1 --region $REGION \
    --query 'items[].{id:id,rcfg:resourceConfigurationName,status:status}' --output table
  say "E1 Door lives in the HUB, in hub-owned subnets (not shared)"
  aws vpc-lattice list-resource-gateways --profile $HUB --region $REGION --query 'items[].{name:name,subnets:subnetIds,ips:ipv4AddressesPerEni}' --output table
  say "E2 AgentCore account sees the SHARED resource configurations and the shared agent subnets, but no resource gateway"
  aws vpc-lattice list-resource-gateways --profile $S1 --region $REGION --query 'items[].name' --output text; echo "  (no resource gateway should be listed above)"
  aws ram list-resources --profile $S1 --region $REGION --resource-owner OTHER-ACCOUNTS --query 'resources[].{type:type,arn:arn}' --output table
  say "E3 Firewall saw the flow (door 10.0.x.x -> API account 10.12.x.x:443)"
  # Completed TLS flows (netflow records are written when the flow closes, so allow a few minutes after T2).
  aws logs filter-log-events --profile $HUB --region $REGION --log-group-name /lab/network-firewall \
    --start-time $(( ($(date +%s) - 3600) * 1000 )) \
    --filter-pattern '{ $.event.event_type = "netflow" && $.event.app_proto = "tls" && $.event.dest_port = 443 }' \
    --query 'events[].message' --output text | tr '\t' '\n' | python3 -c '
import sys, json
for l in sys.stdin:
    if not l.strip().startswith("{"): continue
    e = json.loads(l)["event"]; n = e["netflow"]
    print(" ", n["start"][:19], e["src_ip"], "->", e["dest_ip"], e["dest_port"], "| app", e["app_proto"], "| pkts", n["pkts"], "bytes", n["bytes"], "| state", n.get("state"))
' | tail -5
}

cmd_prove_multi() {
  # Proves "the network team does it ONCE": a 2nd private API is onboarded by the AgentCore side only (here the 2nd API
  # is hosted in the AgentCore account, i.e. a different account from API #1), reusing the SAME resource gateway and
  # the SAME shared resource configuration. Zero network-account changes.
  local P=$S1 STACK=lab-api2-benefits NAME=lab-benefits-api
  say "M1 Hub stack fingerprint BEFORE onboarding API #2"
  HUB_BEFORE=$(aws cloudformation describe-stacks --profile $HUB --region $REGION --stack-name lab-hub-network --query 'Stacks[0].LastUpdatedTime' --output text)
  echo "  lab-hub-network LastUpdatedTime: $HUB_BEFORE"
  say "M2 API #2 ($NAME) in account $(aws sts get-caller-identity --profile $P --query Account --output text) - allows the SAME hub VPCE"
  deploy_stack $P $STACK 02-spoke2-api.yaml ApiVpceId=$API_VPCE_ID ApiName=$NAME DomainPrefix=lab-demo-api2-$S1_ACCT
  saveout API2_HOST $P $STACK ApiHostname
  CP2_ARN=$(ensure_oauth_provider lab-benefits-api-oauth "$P" "$(out $P $STACK ApiPoolId)" "$(out $P $STACK ApiClientId)")
  save CP2_ARN "$CP2_ARN"
  say "M3 Gateway target #2 -> SAME resource configuration $RCFG_ARN"
  python3 - "$API2_HOST" "$CP2_ARN" "$RCFG_ARN" > "$TMPD/target2.json" <<'PY'
import json, sys
host, cp, rcfg = sys.argv[1:4]
spec = {"openapi":"3.0.1","info":{"title":"Benefits API (private, 2nd account)","version":"1.0"},
        "servers":[{"url":f"https://{host}/prod"}],
        "paths":{"/employees/{employeeId}":{"get":{"operationId":"getEmployee","summary":"Get benefits record",
          "parameters":[{"name":"employeeId","in":"path","required":True,"schema":{"type":"string"}}],
          "responses":{"200":{"description":"ok","content":{"application/json":{"schema":{"type":"object"}}}}}}}}}
print(json.dumps({"name":"benefits-api","description":"2nd private API, same hub door + same resource config",
  "targetConfiguration":{"mcp":{"openApiSchema":{"inlinePayload":json.dumps(spec)}}},
  "credentialProviderConfigurations":[{"credentialProviderType":"OAUTH","credentialProvider":{"oauthCredentialProvider":
     {"providerArn":cp,"scopes":["lab-api/invoke"],"grantType":"CLIENT_CREDENTIALS"}}}],
  "privateEndpoint":{"selfManagedLatticeResource":{"resourceConfigurationIdentifier":rcfg}}}))
PY
  if [ -z "${TARGET2_ID:-}" ]; then
    TARGET2_ID=$(aws bedrock-agentcore-control create-gateway-target --profile $S1 --region $REGION \
      --gateway-identifier "$GW_ID" --cli-input-json "file://$TMPD/target2.json" --query targetId --output text)
    save TARGET2_ID "$TARGET2_ID"
  fi
  local saved=$TARGET_ID; TARGET_ID=$TARGET2_ID; wait_status target; TARGET_ID=$saved
  aws bedrock-agentcore-control get-gateway-target --profile $S1 --region $REGION --gateway-identifier $GW_ID \
    --target-id $TARGET2_ID --query 'privateEndpointManagedResources' --output json
  say "M4 tools/call benefits-api___getEmployee 777"
  TOK=$(token)
  mcp '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"benefits-api___getEmployee","arguments":{"employeeId":"777"}}}' | python3 -m json.tool
  say "M5 Hub stack fingerprint AFTER (must be unchanged)"
  echo "  lab-hub-network LastUpdatedTime: $(aws cloudformation describe-stacks --profile $HUB --region $REGION --stack-name lab-hub-network --query 'Stacks[0].LastUpdatedTime' --output text)"
  aws vpc-lattice list-resource-configurations --profile $HUB --region $REGION --query 'items[].name' --output text | sed 's/^/  hub resource configurations: /'
}

cmd_prove_return() {
  # Proves the RETURN leg (API -> door) is routed through and enforced by the firewall: drop only the return direction.
  # If anything below fails or is interrupted, put the firewall back to normal.
  LAB_EXIT_HOOKS+=("deploy_stack $HUB lab-hub-network 01-hub-network.yaml AgentCoreAccountId=$S1_ACCT ApiAccountId=$S2_ACCT FirewallMode=allow")
  say "R1 Firewall -> block-return mode (forward allowed, return dropped)"
  deploy_stack $HUB lab-hub-network 01-hub-network.yaml AgentCoreAccountId=$S1_ACCT ApiAccountId=$S2_ACCT FirewallMode=block-return
  sleep 90
  local T0; T0=$(date +%s)
  say "R2 tools/call getEmployee (expect NO data: client gives up after 60s)"
  TOK=$(token)
  curl -s -m 60 -X POST "$GW_URL" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"employee-api___getEmployee","arguments":{"employeeId":"12345"}}}' \
    || echo "  no response within 60s (curl exit $?) - return traffic blocked"
  say "R3 Firewall ALERT log: return packets dropped (sid 100098) - polls up to 5 min for log delivery"
  local hits=""
  for i in $(seq 1 10); do
    sleep 30
    hits=$(aws logs filter-log-events --profile $HUB --region $REGION --log-group-name /lab/network-firewall \
    --start-time $(( T0 * 1000 )) --filter-pattern '{ $.event.alert.signature_id = 100098 }' \
    --query 'events[].message' --output text | tr '\t' '\n' | python3 -c '
import sys, json
for l in sys.stdin:
    if not l.strip().startswith("{"): continue
    e = json.loads(l)["event"]
    print(" ", e["timestamp"][:19], e["src_ip"], e["src_port"], "->", e["dest_ip"], e["dest_port"], "|", e.get("direction"), "|", e["alert"]["action"], "|", e["alert"]["signature"])
' | tail -5)
    [ -n "$hits" ] && break
  done
  echo "${hits:-  (no drop records found)}"
  say "R4 Restore firewall -> allow, and confirm T2 works again"
  LAB_EXIT_HOOKS=()
  deploy_stack $HUB lab-hub-network 01-hub-network.yaml AgentCoreAccountId=$S1_ACCT ApiAccountId=$S2_ACCT FirewallMode=allow
  sleep 90
  mcp '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"employee-api___getEmployee","arguments":{"employeeId":"12345"}}}' | python3 -c 'import json,sys;print("  ", json.load(sys.stdin)["result"]["content"][0]["text"])'
}

cmd_prove_vpce_policy() {
  # The Gateway interface endpoint policy lists only the lab Gateway. A second Gateway in the same account, called from
  # the same shared subnet through the same endpoint, must be refused. Endpoint policy changes can take minutes to apply.
  say "V1 create a second Gateway (same authorizer) that the endpoint policy does not list"
  local AUTHZ OTHER OTHER_URL i a b ok=0 saved body
  AUTHZ=$(python3 -c 'import json,sys;print(json.dumps({"customJWTAuthorizer":{"discoveryUrl":sys.argv[1],"allowedClients":[sys.argv[2]]}}))' "$DISCOVERY_URL" "$CLIENT_ID")
  OTHER=$(aws bedrock-agentcore-control create-gateway --profile $S1 --region $REGION --name lab-unapproved-gateway --role-arn "$GW_ROLE_ARN" \
    --protocol-type MCP --authorizer-type CUSTOM_JWT --authorizer-configuration "$AUTHZ" --query gatewayId --output text)
  LAB_EXIT_HOOKS+=("aws bedrock-agentcore-control delete-gateway --profile $S1 --region $REGION --gateway-identifier $OTHER >/dev/null 2>&1")
  for i in $(seq 1 30); do
    [ "$(aws bedrock-agentcore-control get-gateway --profile $S1 --region $REGION --gateway-identifier $OTHER --query status --output text)" = READY ] && break; sleep 10; done
  OTHER_URL=$(aws bedrock-agentcore-control get-gateway --profile $S1 --region $REGION --gateway-identifier $OTHER --query gatewayUrl --output text)
  echo "  endpoint policy resources: $(aws ec2 describe-vpc-endpoints --profile $HUB --region $REGION --vpc-endpoint-ids "$(out $HUB lab-hub-network GatewayVpceId)" \
        --query 'VpcEndpoints[0].PolicyDocument' --output text | python3 -c 'import json,sys;print(json.load(sys.stdin)["Statement"][0]["Resource"])')"
  TOK=$(token); body='{"jsonrpc":"2.0","id":51,"method":"tools/list"}'; saved=$GW_URL
  say "V2 from the shared agent subnet through the endpoint: approved Gateway vs unapproved Gateway (polls up to 15 minutes)"
  for i in $(seq 1 30); do
    GW_URL=$saved;     a=$(probe "$body")
    GW_URL=$OTHER_URL; b=$(probe "$body")
    printf '  +%3ss approved:  %s\n        unapproved:%s\n' $((i*30-30)) "$a" "$b"
    case "$b" in *-32002*|*"HTTP 403"*) ok=1; break;; esac
    sleep 30
  done
  GW_URL=$saved
  say "V3 the unapproved Gateway still answers over its public endpoint (an endpoint policy controls only that endpoint)"
  curl -s -m 20 -o /dev/null -w '  HTTP %{http_code}\n' -X POST "$OTHER_URL" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d "$body"
  aws bedrock-agentcore-control delete-gateway --profile $S1 --region $REGION --gateway-identifier $OTHER >/dev/null; LAB_EXIT_HOOKS=()
  [ $ok = 1 ] || die "the endpoint never refused the unapproved Gateway"
}

cmd_prove_ram_permission() {
  # The AWS managed RAM permission for resource configurations also grants ec2:CreateVpcEndpoint, so the AgentCore
  # account could reach a shared resource configuration through a resource endpoint of its own, not only through the
  # Gateway. Try a customer managed permission without that action, then put the AWS managed permission back.
  # Result on 2026-11-11: RAM rejects vpc-lattice:AssociateViaAWSService in a customer managed permission, and without it
  # Gateway targets FAIL. So the scoped permission blocks the resource endpoint but also the Gateway; use prove-sharee-scp.
  local SHARE MANAGED=arn:aws:ram::aws:permission/AWSRAMPermissionVpcLatticeResourceConfiguration PERM rc=0 V SUB EP RT saved h
  SHARE=$(aws ram get-resource-shares --profile $HUB --region $REGION --resource-owner SELF --name lab-share-address-card \
            --resource-share-status ACTIVE --query 'resourceShares[0].resourceShareArn' --output text)
  say "R0 AWS managed permission on the share today"
  aws ram get-permission --profile $HUB --region $REGION --permission-arn $MANAGED --query permission.permission --output text
  say "R1 customer managed permission without ec2:CreateVpcEndpoint (RAM rejects vpc-lattice:AssociateViaAWSService in a customer managed permission)"
  printf '%s' '{"Effect":"Allow","Action":["vpc-lattice:GetResourceConfiguration","vpc-lattice:CreateServiceNetworkResourceAssociation","vpc-lattice:AssociateViaAWSService-EventsAndStates"]}' > "$TMPD/perm.json"
  PERM=$(aws ram create-permission --profile $HUB --region $REGION --name lab-rcfg-gateway-only --resource-type vpc-lattice:ResourceConfiguration \
           --policy-template "file://$TMPD/perm.json" --query permission.arn --output text 2>/dev/null) \
    || PERM=$(aws ram list-permissions --profile $HUB --region $REGION --permission-type CUSTOMER_MANAGED \
           --query "permissions[?name=='lab-rcfg-gateway-only'].arn | [0]" --output text)
  echo "  $PERM"
  LAB_EXIT_HOOKS+=("aws ram associate-resource-share-permission --profile $HUB --region $REGION --resource-share-arn $SHARE --permission-arn $MANAGED --replace >/dev/null 2>&1; sleep 30; aws ram delete-permission --profile $HUB --region $REGION --permission-arn $PERM >/dev/null 2>&1")
  aws ram associate-resource-share-permission --profile $HUB --region $REGION --resource-share-arn $SHARE --permission-arn $PERM --replace --query returnValue --output text
  sleep 60
  aws ram list-resource-share-permissions --profile $HUB --region $REGION --resource-share-arn $SHARE --query 'permissions[].[name,status]' --output text
  say "R2 AgentCore account: create a resource endpoint for the shared API resource configuration in a temporary VPC it owns (expect denied)"
  V=$(aws ec2 create-vpc --profile $S1 --region $REGION --cidr-block 172.31.250.0/24 --query Vpc.VpcId --output text)
  LAB_EXIT_HOOKS=("aws ec2 delete-vpc --profile $S1 --region $REGION --vpc-id $V >/dev/null 2>&1" "${LAB_EXIT_HOOKS[@]}")
  SUB=$(aws ec2 create-subnet --profile $S1 --region $REGION --vpc-id $V --cidr-block 172.31.250.0/26 --availability-zone-id use1-az1 --query Subnet.SubnetId --output text)
  LAB_EXIT_HOOKS=("aws ec2 delete-subnet --profile $S1 --region $REGION --subnet-id $SUB >/dev/null 2>&1" "${LAB_EXIT_HOOKS[@]}")
  EP=$(aws ec2 create-vpc-endpoint --profile $S1 --region $REGION --vpc-endpoint-type Resource --vpc-id $V --subnet-ids $SUB \
      --resource-configuration-arn "$RCFG_ARN" --query VpcEndpoint.VpcEndpointId --output text 2>&1) || true
  echo "  $EP" | cut -c1-300
  case "$EP" in vpce-*) rc=1; echo "  UNEXPECTED: endpoint created; deleting it"
    aws ec2 delete-vpc-endpoints --profile $S1 --region $REGION --vpc-endpoint-ids $EP >/dev/null; sleep 90;; esac
  say "R3 new Gateway target on the same resource configuration with the scoped permission (2026-11-11: FAILED, needs AssociateViaAWSService)"
  python3 - "$API_HOST" "$CP_ARN" "$RCFG_ARN" > "$TMPD/rp.json" <<'PY'
import json, sys
host, cp, rcfg = sys.argv[1:4]
spec = {"openapi":"3.0.1","info":{"title":"ram scoped","version":"1"},"servers":[{"url":f"https://{host}/prod"}],
        "paths":{"/employees/{employeeId}":{"get":{"operationId":"getEmployee","parameters":[{"name":"employeeId","in":"path","required":True,"schema":{"type":"string"}}],
                 "responses":{"200":{"description":"ok","content":{"application/json":{"schema":{"type":"object"}}}}}}}}}
print(json.dumps({"name":"ram-scoped","targetConfiguration":{"mcp":{"openApiSchema":{"inlinePayload":json.dumps(spec)}}},
  "credentialProviderConfigurations":[{"credentialProviderType":"OAUTH","credentialProvider":{"oauthCredentialProvider":
     {"providerArn":cp,"scopes":["lab-api/invoke"],"grantType":"CLIENT_CREDENTIALS"}}}],
  "privateEndpoint":{"selfManagedLatticeResource":{"resourceConfigurationIdentifier":rcfg}}}))
PY
  RT=$(aws bedrock-agentcore-control create-gateway-target --profile $S1 --region $REGION --gateway-identifier "$GW_ID" \
      --cli-input-json "file://$TMPD/rp.json" --query targetId --output text)
  saved=$TARGET_ID; TARGET_ID=$RT
  if wait_status target; then echo "  target READY: the scoped permission works with the Gateway"; else echo "  target not READY (see reason above)"; fi
  TARGET_ID=$saved
  aws bedrock-agentcore-control delete-gateway-target --profile $S1 --region $REGION --gateway-identifier "$GW_ID" --target-id "$RT" >/dev/null || true
  say "R4 restore the AWS managed permission and delete the temporary resources"
  for h in "${LAB_EXIT_HOOKS[@]}"; do eval "$h" || true; done; LAB_EXIT_HOOKS=()
  aws ram list-resource-share-permissions --profile $HUB --region $REGION --resource-share-arn $SHARE --query 'permissions[].[name,status]' --output text
  [ $rc = 0 ] || die "the AgentCore account created a resource endpoint despite the scoped permission"
}

cmd_prove_sharee_scp() {
  # A customer managed RAM permission can't keep vpc-lattice:AssociateViaAWSService (prove-ram-permission), so the
  # AWS managed permission stays. Close the other paths with an SCP on the AgentCore account instead:
  #   - deny ec2:CreateVpcEndpoint on resource configurations (no resource endpoint of its own)
  #   - deny vpc-lattice:CreateServiceNetworkResourceAssociation unless an AWS service makes the call (AgentCore Gateway does)
  # Then: resource endpoint denied, own service network association denied, Gateway target still READY and working.
  local MGMT=${MGMT_PROFILE:-lab-mgmt} POL rc=0 V SUB EP SN RT saved o h
  say "S0 SCP on the AgentCore account ($S1_ACCT)"
  cat > "$TMPD/scp.json" <<'JSON'
{"Version":"2012-10-17","Statement":[
 {"Sid":"NoOwnEndpointsToSharedResourceConfigurations","Effect":"Deny","Action":"ec2:CreateVpcEndpoint",
  "Resource":"arn:aws:vpc-lattice:*:*:resourceconfiguration/*"},
 {"Sid":"ServiceNetworkAssociationsOnlyThroughAwsServices","Effect":"Deny","Action":"vpc-lattice:CreateServiceNetworkResourceAssociation",
  "Resource":"*","Condition":{"BoolIfExists":{"aws:ViaAWSService":"false"}}}]}
JSON
  cat "$TMPD/scp.json"
  POL=$(aws organizations create-policy --profile $MGMT --type SERVICE_CONTROL_POLICY --name lab-agentcore-sharee-guardrail \
          --description "lab: Gateway is the only consumer of shared resource configurations" --content "file://$TMPD/scp.json" \
          --query Policy.PolicySummary.Id --output text)
  LAB_EXIT_HOOKS+=("aws organizations detach-policy --profile $MGMT --policy-id $POL --target-id $S1_ACCT >/dev/null 2>&1; aws organizations delete-policy --profile $MGMT --policy-id $POL >/dev/null 2>&1")
  aws organizations attach-policy --profile $MGMT --policy-id $POL --target-id $S1_ACCT
  echo "  attached $POL; waiting 90s for propagation"; sleep 90
  say "S1 resource endpoint for the shared API resource configuration in a temporary VPC (expect denied)"
  V=$(aws ec2 create-vpc --profile $S1 --region $REGION --cidr-block 172.31.250.0/24 --query Vpc.VpcId --output text)
  LAB_EXIT_HOOKS=("aws ec2 delete-vpc --profile $S1 --region $REGION --vpc-id $V >/dev/null 2>&1" "${LAB_EXIT_HOOKS[@]}")
  SUB=$(aws ec2 create-subnet --profile $S1 --region $REGION --vpc-id $V --cidr-block 172.31.250.0/26 --availability-zone-id use1-az1 --query Subnet.SubnetId --output text)
  LAB_EXIT_HOOKS=("aws ec2 delete-subnet --profile $S1 --region $REGION --subnet-id $SUB >/dev/null 2>&1" "${LAB_EXIT_HOOKS[@]}")
  EP=$(aws ec2 create-vpc-endpoint --profile $S1 --region $REGION --vpc-endpoint-type Resource --vpc-id $V --subnet-ids $SUB \
      --resource-configuration-arn "$RCFG_ARN" --query VpcEndpoint.VpcEndpointId --output text 2>&1) || true
  echo "  ${EP:0:300}"
  case "$EP" in vpce-*) rc=1; aws ec2 delete-vpc-endpoints --profile $S1 --region $REGION --vpc-endpoint-ids $EP >/dev/null; sleep 90;; esac
  say "S2 own service network, then associate the shared resource configuration directly (expect denied)"
  SN=$(aws vpc-lattice create-service-network --profile $S1 --region $REGION --name lab-sharee-sn-$RANDOM --query id --output text)
  LAB_EXIT_HOOKS=("aws vpc-lattice delete-service-network --profile $S1 --region $REGION --service-network-identifier $SN >/dev/null 2>&1" "${LAB_EXIT_HOOKS[@]}")
  o=$(aws vpc-lattice create-service-network-resource-association --profile $S1 --region $REGION --service-network-identifier $SN \
       --resource-configuration-identifier "$RCFG_ARN" --query id --output text 2>&1) || true
  echo "  ${o:0:300}"
  case "$o" in snra-*) rc=1; aws vpc-lattice delete-service-network-resource-association --profile $S1 --region $REGION --service-network-resource-association-identifier $o >/dev/null; sleep 60;; esac
  say "S3 Gateway target on the same resource configuration (expect READY and a working call)"
  python3 - "$API_HOST" "$CP_ARN" "$RCFG_ARN" > "$TMPD/sp.json" <<'PY'
import json, sys
host, cp, rcfg = sys.argv[1:4]
spec = {"openapi":"3.0.1","info":{"title":"scp","version":"1"},"servers":[{"url":f"https://{host}/prod"}],
        "paths":{"/employees/{employeeId}":{"get":{"operationId":"getEmployee","parameters":[{"name":"employeeId","in":"path","required":True,"schema":{"type":"string"}}],
                 "responses":{"200":{"description":"ok","content":{"application/json":{"schema":{"type":"object"}}}}}}}}}
print(json.dumps({"name":"scp-guarded","targetConfiguration":{"mcp":{"openApiSchema":{"inlinePayload":json.dumps(spec)}}},
  "credentialProviderConfigurations":[{"credentialProviderType":"OAUTH","credentialProvider":{"oauthCredentialProvider":
     {"providerArn":cp,"scopes":["lab-api/invoke"],"grantType":"CLIENT_CREDENTIALS"}}}],
  "privateEndpoint":{"selfManagedLatticeResource":{"resourceConfigurationIdentifier":rcfg}}}))
PY
  RT=$(aws bedrock-agentcore-control create-gateway-target --profile $S1 --region $REGION --gateway-identifier "$GW_ID" \
      --cli-input-json "file://$TMPD/sp.json" --query targetId --output text)
  LAB_EXIT_HOOKS=("aws bedrock-agentcore-control delete-gateway-target --profile $S1 --region $REGION --gateway-identifier $GW_ID --target-id $RT >/dev/null 2>&1; sleep 30" "${LAB_EXIT_HOOKS[@]}")
  saved=$TARGET_ID; TARGET_ID=$RT; wait_status target || rc=1; TARGET_ID=$saved
  TOK=$(token)
  o=$(mcp_retry '{"jsonrpc":"2.0","id":71,"method":"tools/call","params":{"name":"scp-guarded___getEmployee","arguments":{"employeeId":"71"}}}') || rc=1
  echo "  ${o:0:300}"
  say "S4 CloudTrail in the network account: each association by the sharee is logged as ...BySharee (alarm on it)"
  sleep 60
  aws cloudtrail lookup-events --profile $HUB --region $REGION --lookup-attributes AttributeKey=EventName,AttributeValue=CreateServiceNetworkResourceAssociationBySharee \
    --max-results 3 --query 'Events[].[EventTime,Username]' --output text
  say "S5 detach and delete the SCP, delete the temporary resources"
  for h in "${LAB_EXIT_HOOKS[@]}"; do eval "$h" || true; done; LAB_EXIT_HOOKS=()
  aws organizations list-policies-for-target --profile $MGMT --target-id $S1_ACCT --filter SERVICE_CONTROL_POLICY --query 'Policies[].Name' --output text
  [ $rc = 0 ] || die "SCP check did not behave as expected (see above)"
}


cmd_alb() {
  # Customer-shaped backend: internal ALB (JWT-validating) in the tool account -> OpenAPI target + MCP-server target,
  # OAuth client_credentials per tool account, private-CA TLS, same resource gateway. Then private ingress via Gateway VPCE.
  local PY; PY=$(lab_py)
  local PKI=$DIR/.pki; mkdir -p "$PKI"
  if [ ! -f "$PKI/srv.pem" ]; then
    say "A0 Private CA + server cert tools.demo-lab.internal (lab stand-in for a customer's private CA)"
    ( cd "$PKI"
      openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 365 -subj "/CN=Lab Private Root CA" \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
      openssl req -newkey rsa:2048 -nodes -keyout srv.key -out srv.csr -subj "/CN=tools.demo-lab.internal" 2>/dev/null
      printf "subjectAltName=DNS:tools.demo-lab.internal\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n" > ext.cnf
      openssl x509 -req -in srv.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out srv.pem -days 180 -extfile ext.cnf 2>/dev/null
      rm -f ca.key srv.csr ca.srl )   # the CA key is only needed to sign the server certificate
  fi
  [ -n "${TOOLS_CERT_ARN:-}" ] || save TOOLS_CERT_ARN "$(aws acm import-certificate --profile $S2 --region $REGION --certificate "fileb://$PKI/srv.pem" \
      --private-key "fileb://$PKI/srv.key" --certificate-chain "fileb://$PKI/ca.pem" --query CertificateArn --output text)"
  local S2_VPC S2_SUBNETS
  S2_VPC=$(aws ec2 describe-vpcs --profile $HUB --region $REGION --filters Name=tag:Name,Values=lab-spoke2-app-vpc --query 'Vpcs[0].VpcId' --output text)
  S2_SUBNETS=$(aws ec2 describe-subnets --profile $HUB --region $REGION --filters Name=vpc-id,Values=$S2_VPC Name=tag:Name,Values='lab-spoke2-app-*' --query 'Subnets[].SubnetId' --output text | tr '\t' ',')
  [ "$S2_VPC" != "None" ] && [ -n "$S2_SUBNETS" ] || { echo "spoke2 VPC/subnets not found"; return 1; }
  say "A1 Tool account: internal ALB (JWT validation) + backend + tool Cognito  [app team: ALB + SG only]"
  deploy_stack $S2 lab-spoke2-tools-alb 04-spoke2-alb-backend.yaml VpcId=$S2_VPC SubnetIds=$S2_SUBNETS CertificateArn=$TOOLS_CERT_ARN \
    DomainPrefix=lab-demo-tools-$S2_ACCT
  local ALB_DNS; ALB_DNS=$(out $S2 lab-spoke2-tools-alb AlbDns)
  say "A2 Hub (one time per backend ALB): resource configuration -> $ALB_DNS, added to the existing RAM share"
  deploy_stack $HUB lab-hub-network 01-hub-network.yaml AgentCoreAccountId=$S1_ACCT ApiAccountId=$S2_ACCT ToolsAlbDns=$ALB_DNS
  saveout TOOLS_RCFG_ARN $HUB lab-hub-network ToolsResourceConfigArn
  say "A3 AgentCore account: OAuth provider (tool Cognito) + private CA secret + 2 targets"
  local TPOOL TCLIENT; TPOOL=$(out $S2 lab-spoke2-tools-alb ToolPoolId); TCLIENT=$(out $S2 lab-spoke2-tools-alb ToolClientId)
  [ -n "${TOOLS_OCP_ARN:-}" ] || save TOOLS_OCP_ARN "$(ensure_oauth_provider lab-tools-oauth "$S2" "$TPOOL" "$TCLIENT")"
  [ -n "${CA_SECRET_ARN:-}" ] || save CA_SECRET_ARN "$(aws secretsmanager create-secret --profile $S1 --region $REGION \
      --name lab/tools-private-ca --secret-string "file://$PKI/ca.pem" --query ARN --output text)"
  "$PY" "$DIR/tools_targets.py" "$GW_ID" "$TOOLS_RCFG_ARN" "$TOOLS_OCP_ARN" "$CA_SECRET_ARN"
  say "A4 Private ingress probe (Lambda in spoke1 SHARED subnet, no internet route) -> hub-owned Gateway VPCE"
  deploy_stack $S1 lab-spoke1-agent-probe 05-spoke1-agent-probe.yaml VpcId=$S1_VPC SubnetIds=$S1_SUBNETS
}

probe() { # body-json [extra-headers-json]
  python3 -c 'import json,sys;print(json.dumps({"gatewayUrl":sys.argv[1],"token":sys.argv[2],"body":json.loads(sys.argv[3]),"extraHeaders":json.loads(sys.argv[4])}))' \
    "$GW_URL" "$TOK" "$1" "${2:-"{}"}" > "$TMPD/pev.json"
  aws lambda invoke --profile $S1 --region $REGION --function-name lab-agent-probe --cli-read-timeout 90 \
    --payload "fileb://$TMPD/pev.json" "$TMPD/pout.json" >/dev/null; rm -f "$TMPD/pev.json"
  python3 -c '
import json
d = json.load(open("'"$TMPD"'/pout.json")); b = d.get("body", "")
try: b = json.loads(b)["result"]["content"][0]["text"]
except Exception: b = b[:120].replace("\r\n", " ")
print("  resolved", d.get("resolvedTo"), "| HTTP", d.get("status"), "|", b)'
}

cmd_test_alb() {
  TOK=$(token)
  local out rc=0
  say "A5 tools/call tools-rest___getEmployee (OpenAPI -> internal ALB REST, OAuth + private CA)"
  out=$(mcp_retry '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"tools-rest___getEmployee","arguments":{"employeeId":"555"}}}') || rc=1
  echo "$out" | python3 -c 'import json,sys;print("  ", json.load(sys.stdin)["result"]["content"][0]["text"])'
  say "A6 tools/call classifier___classifyQuestion (MCP server -> internal ALB /mcp)"
  out=$(mcp_retry '{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"classifier___classifyQuestion","arguments":{"question":"Is my tooth cleaning covered?"}}}') || rc=1
  echo "$out" | python3 -c 'import json,sys;print("  ", json.load(sys.stdin)["result"]["content"][0]["text"])'
  say "P1 Private ingress: agent in shared subnet -> Gateway VPCE -> classifier"
  probe '{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"classifier___classifyQuestion","arguments":{"question":"dental plan?"}}}'
  say "P2 WAF still enforced on the private path"
  probe '{"jsonrpc":"2.0","id":14,"method":"tools/list"}' '{"User-Agent":"<script>alert(1)</script>"}'
  [ "$rc" = 0 ] || die "A5 or A6 did not succeed within ~90s (see the responses above)"
}

cmd_teardown() {
  say "Teardown (reverse order). Reversible only by redeploying."
  # Observability resources created by observability.sh, then the Gateway resource policy
  [ -n "${GW_ARN:-}" ] && aws bedrock-agentcore-control delete-resource-policy --profile $S1 --region $REGION --resource-arn "$GW_ARN" >/dev/null 2>&1 || true
  for d in $(aws logs describe-deliveries --profile $S1 --region $REGION --query "deliveries[?deliverySourceName=='lab-gw-logs'].id" --output text 2>/dev/null); do
    aws logs delete-delivery --profile $S1 --region $REGION --id $d || true; done
  aws logs delete-delivery-source --profile $S1 --region $REGION --name lab-gw-logs 2>/dev/null || true
  aws logs delete-delivery-destination --profile $S1 --region $REGION --name lab-gw-cwl 2>/dev/null || true
  [ -n "${WEB_ACL_ARN:-}" ] && aws wafv2 delete-logging-configuration --profile $S1 --region $REGION --resource-arn "$WEB_ACL_ARN" 2>/dev/null || true
  for g in /lab/agentcore-gateway aws-waf-logs-lab-gateway; do aws logs delete-log-group --profile $S1 --region $REGION --log-group-name $g 2>/dev/null || true; done
  for r in ${RCFG_ARN:-} ${TOOLS_RCFG_ARN:-}; do
    for a in $(aws vpc-lattice list-access-log-subscriptions --profile $HUB --region $REGION --resource-identifier $r --query 'items[].id' --output text 2>/dev/null); do
      aws vpc-lattice delete-access-log-subscription --profile $HUB --region $REGION --access-log-subscription-identifier $a || true; done; done
  FL=$(aws ec2 describe-flow-logs --profile $HUB --region $REGION --filter Name=log-group-name,Values=/lab/vpc-flow --query 'FlowLogs[].FlowLogId' --output text) || FL=''
  [ -n "$FL" ] && aws ec2 delete-flow-logs --profile $HUB --region $REGION --flow-log-ids $FL >/dev/null || true
  for g in /lab/vpc-flow /lab/lattice-access; do aws logs delete-log-group --profile $HUB --region $REGION --log-group-name $g 2>/dev/null || true; done
  aws iam delete-role-policy --profile $HUB --role-name lab-flowlogs-role --policy-name cwl 2>/dev/null || true
  aws iam delete-role --profile $HUB --role-name lab-flowlogs-role 2>/dev/null || true
  ALB=$(aws elbv2 describe-load-balancers --profile $S2 --region $REGION --names lab-tools-internal --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null) || ALB=None
  [ -n "$ALB" ] && [ "$ALB" != "None" ] && aws elbv2 modify-load-balancer-attributes --profile $S2 --region $REGION --load-balancer-arn $ALB \
    --attributes Key=access_logs.s3.enabled,Value=false Key=connection_logs.s3.enabled,Value=false >/dev/null || true
  aws s3 rb --profile $S2 --region $REGION s3://lab-alb-logs-$S2_ACCT --force 2>/dev/null || true   # WARNING: deletes ALB logs
  [ -n "${GW_ID:-}" ] && {
    for t in $(aws bedrock-agentcore-control list-gateway-targets --profile $S1 --region $REGION --gateway-identifier $GW_ID --query 'items[].targetId' --output text); do
      aws bedrock-agentcore-control delete-gateway-target --profile $S1 --region $REGION --gateway-identifier $GW_ID --target-id $t >/dev/null || true; done
    for i in $(seq 1 30); do   # target deletion is asynchronous; DeleteGateway fails while any target remains
      [ "$(aws bedrock-agentcore-control list-gateway-targets --profile $S1 --region $REGION --gateway-identifier $GW_ID --query 'length(items)' --output text)" = 0 ] && break
      sleep 10; done
    aws wafv2 disassociate-web-acl --profile $S1 --region $REGION --resource-arn "${GW_ARN:-}" || true
    aws bedrock-agentcore-control delete-gateway --profile $S1 --region $REGION --gateway-identifier $GW_ID >/dev/null \
      || echo "  WARNING: Gateway $GW_ID was not deleted (a target may still be deleting). Re-run teardown, or delete it in the console."; }
  for n in lab-employee-api-oauth lab-benefits-api-oauth; do
    aws bedrock-agentcore-control delete-oauth2-credential-provider --profile $S1 --region $REGION --name $n >/dev/null 2>&1 || true; done
  aws cloudformation delete-stack --profile $S1 --region $REGION --stack-name lab-api2-benefits
  # AgentCore Runtime test (runtime_test.py + 06-spoke1-runtime.yaml), if it was run
  if [ -x "${LAB_PY:-$DIR/.venv/bin/python}" ]; then
    "${LAB_PY:-$DIR/.venv/bin/python}" "$DIR/runtime_test.py" delete || echo "  WARNING: Runtime cleanup failed; delete runtime lab_gateway_caller by hand (its ENIs block subnet deletion)"
  else
    echo "  (no Python venv; skipping Runtime cleanup. If you ran the Runtime test, delete runtime lab_gateway_caller by hand.)"
  fi
  aws cloudformation delete-stack --profile $S1 --region $REGION --stack-name lab-spoke1-runtime
  aws cloudformation delete-stack --profile $S1 --region $REGION --stack-name lab-spoke1-agent-probe
  aws bedrock-agentcore-control delete-oauth2-credential-provider --profile $S1 --region $REGION --name lab-tools-oauth >/dev/null 2>&1 || true
  aws secretsmanager delete-secret --profile $S1 --region $REGION --secret-id lab/tools-private-ca --force-delete-without-recovery >/dev/null 2>&1 || true
  aws cloudformation delete-stack --profile $S2 --region $REGION --stack-name lab-spoke2-tools-alb
  aws cloudformation wait stack-delete-complete --profile $S2 --region $REGION --stack-name lab-spoke2-tools-alb || true
  [ -n "${TOOLS_CERT_ARN:-}" ] && aws acm delete-certificate --profile $S2 --region $REGION --certificate-arn "$TOOLS_CERT_ARN" || true
  sleep 30
  aws cloudformation delete-stack --profile $S1 --region $REGION --stack-name lab-spoke1-inbound
  aws cloudformation delete-stack --profile $S2 --region $REGION --stack-name lab-spoke2-api
  aws cloudformation wait stack-delete-complete --profile $S2 --region $REGION --stack-name lab-spoke2-api || true
  # ENIs of Lambda / AgentCore Runtime in the shared spoke1 subnets must be gone before the hub can delete the VPC.
  # Skip the wait for any stack already in a terminal DELETE_FAILED state: `cloudformation wait` would otherwise
  # poll that stack for its full ~30-minute window before giving up (e.g. lab-spoke1-runtime, whose agentic_ai ENIs
  # can take up to 8 hours to release). Proceeding to the hub delete is correct either way: the hub's billable
  # resources (Transit Gateway, firewall, NAT gateway) do not depend on these stacks.
  for s in lab-spoke1-agent-probe lab-spoke1-runtime lab-api2-benefits lab-spoke1-inbound; do
    status=$(aws cloudformation describe-stacks --profile $S1 --region $REGION --stack-name $s --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo GONE)
    case "$status" in
      GONE) : ;;                                   # already deleted
      DELETE_FAILED) echo "  $s is DELETE_FAILED (likely ENIs still in the shared subnets); not waiting. Re-run teardown once they are released." ;;
      *) aws cloudformation wait stack-delete-complete --profile $S1 --region $REGION --stack-name $s || echo "  $s not deleted yet" ;;
    esac
  done
  aws cloudformation delete-stack --profile $HUB --region $REGION --stack-name lab-hub-network
  if ! aws cloudformation wait stack-delete-complete --profile $HUB --region $REGION --stack-name lab-hub-network; then
    say "The network stack did not finish deleting. The Transit Gateway, firewall and NAT gateway are deleted first, so hourly charges stop."
    echo "  Usually the shared agent subnets still hold network interfaces (Lambda, or AgentCore Runtime; the Runtime's can stay up to 8 hours)."
    echo "  Re-run './run-lab.sh teardown' later, or delete stacks lab-spoke1-runtime and lab-hub-network by hand. Local state was kept."
    exit 1
  fi
  # Log groups that Lambda and AgentCore Runtime create for themselves are not part of any stack
  aws logs delete-log-group --profile $S1 --region $REGION --log-group-name /aws/lambda/lab-agent-probe 2>/dev/null || true
  aws logs delete-log-group --profile $S2 --region $REGION --log-group-name /aws/lambda/lab-tools-backend 2>/dev/null || true
  for g in $(aws logs describe-log-groups --profile $S1 --region $REGION --log-group-name-prefix /aws/bedrock-agentcore/runtimes/lab_gateway_caller \
               --query 'logGroups[].logGroupName' --output text 2>/dev/null || true); do
    aws logs delete-log-group --profile $S1 --region $REGION --log-group-name "$g" 2>/dev/null || true; done
  rm -rf "$DIR/.pki"; : > "$STATE"; say "Done. Transit Gateway, Network Firewall and NAT gateway billing stopped."
}

cmd_extra_tools() {
  # The tool team ships a new REST route and a new MCP tool behind the SAME ALB (04 ExtraTools=true).
  # Afterwards run: python extra_tests.py spec-sync   (UpdateGatewayTarget + SynchronizeGatewayTargets)
  say "X4 prep: tool account redeploys the backend with ExtraTools=true (other parameters keep their previous values)"
  HUB_BEFORE=$(aws cloudformation describe-stacks --profile $HUB --region $REGION --stack-name lab-hub-network --query 'Stacks[0].LastUpdatedTime' --output text)
  echo "  lab-hub-network LastUpdatedTime before: $HUB_BEFORE"
  deploy_stack $S2 lab-spoke2-tools-alb 04-spoke2-alb-backend.yaml ExtraTools=true
  echo "  Next: $(lab_py) $DIR/extra_tests.py spec-sync   (then confirm the network stack's LastUpdatedTime is still $HUB_BEFORE)"
}

cmd_runtime() {
  # AgentCore Runtime (VPC mode, direct code deployment) in the SHARED agent subnets calls the Gateway through the interface endpoint.
  local PY; PY=$(lab_py)
  local B="lab-runtime-code-$S1_ACCT" PL
  say "RT1 Network account adds the endpoints a Runtime without internet needs (S3 gateway endpoint for code, CloudWatch Logs)"
  deploy_stack $HUB lab-hub-network 01-hub-network.yaml AgentCoreAccountId=$S1_ACCT ApiAccountId=$S2_ACCT AgentRuntimeEndpoints=true
  say "RT2 AgentCore account: code bucket, Runtime security group and execution role"
  if ! aws s3api head-bucket --profile $S1 --bucket "$B" 2>/dev/null; then
    if [ "$REGION" = us-east-1 ]; then aws s3api create-bucket --profile $S1 --region $REGION --bucket "$B" >/dev/null
    else aws s3api create-bucket --profile $S1 --region $REGION --bucket "$B" --create-bucket-configuration LocationConstraint=$REGION >/dev/null; fi
    aws s3api put-public-access-block --profile $S1 --region $REGION --bucket "$B" \
      --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  fi
  PL=$(aws ec2 describe-managed-prefix-lists --profile $S1 --region $REGION --filters "Name=prefix-list-name,Values=com.amazonaws.$REGION.s3" \
         --query 'PrefixLists[0].PrefixListId' --output text)
  [ -n "$PL" ] && [ "$PL" != None ] || die "could not find the S3 prefix list"
  deploy_stack $S1 lab-spoke1-runtime 06-spoke1-runtime.yaml VpcId=$S1_VPC CodeBucket=$B S3PrefixListId=$PL
  say "RT3 Create the Runtime"
  "$PY" "$DIR/runtime_test.py" deploy
  say "DEPLOYED. Next: ./run-lab.sh test-runtime"
}

cmd_test_runtime() {
  local PY; PY=$(lab_py)
  "$PY" "$DIR/runtime_test.py" invoke
}

case "${1:-}" in
  extra-tools) cmd_extra_tools;; runtime) cmd_runtime;; test-runtime) cmd_test_runtime;;
  deploy) cmd_deploy;; test) cmd_test;; negative) cmd_negative;; evidence) cmd_evidence;; teardown) cmd_teardown;;
  prove-vpce-policy) cmd_prove_vpce_policy;; prove-ram-permission) cmd_prove_ram_permission;; prove-sharee-scp) cmd_prove_sharee_scp;;
  prove-multi) cmd_prove_multi;; prove-return) cmd_prove_return;; alb) cmd_alb;; test-alb) cmd_test_alb;;
  *) usage; exit 1;;
esac
