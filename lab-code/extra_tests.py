#!/usr/bin/env python3
"""Extra lab tests for blog claims that run-lab.sh does not cover.

usage: extra_tests.py pkix | alb-rejects | least-priv | spec-sync
Needs boto3 >= 1.43.106 (certificateConfigurations) and a lab deployed with './run-lab.sh deploy' and './run-lab.sh alb'.
Environment: S1_PROFILE, S2_PROFILE, HUB_PROFILE, AWS_REGION (same contract as the shell scripts).
pkix, alb-rejects and least-priv create temporary resources and delete them in a finally block.
spec-sync is NOT temporary: it adds an operation to the tools-rest target and syncs the classifier target.
Run './run-lab.sh extra-tools' first so the backend serves the new route and tool.
Each subcommand exits non-zero if an expectation is not met.
"""
import base64, json, os, shlex, sys, time, urllib.parse, urllib.request, urllib.error
import boto3, botocore


def https_open(req, **kw):
    """urlopen for HTTPS URLs only (the Cognito token endpoint and the Gateway URL from .lab-state.env)."""
    url = req.full_url if isinstance(req, urllib.request.Request) else req
    if urllib.parse.urlparse(url).scheme != "https":
        raise ValueError(f"refusing non-HTTPS URL: {url}")
    return urllib.request.urlopen(req, **kw)  # nosec B310 - scheme checked above

DIR = os.path.dirname(os.path.abspath(__file__))
REGION = os.environ.get("AWS_REGION", "us-east-1")
S1 = os.environ.get("S1_PROFILE", "lab-spoke1")
S2 = os.environ.get("S2_PROFILE", "lab-spoke2")
HOST = "tools.demo-lab.internal"

st = {}
for line in open(os.path.join(DIR, ".lab-state.env")):
    if "=" in line:
        k, v = line.rstrip("\n").split("=", 1)
        st[k] = shlex.split(v)[0] if v else ""

s1 = boto3.Session(profile_name=S1, region_name=REGION)
s2 = boto3.Session(profile_name=S2, region_name=REGION)
ac = s1.client("bedrock-agentcore-control")
GW = st["GW_ID"]


def log(*a):
    print(*a, flush=True)


FAILS = []


def expect(cond, msg):
    """Record a PASS/FAIL line; the process exits non-zero at the end if any expectation failed."""
    log(("PASS " if cond else "FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def wait_target(client, tid, timeout=600):
    t0 = time.time()
    while True:
        t = client.get_gateway_target(gatewayIdentifier=GW, targetId=tid)
        if t["status"] not in ("CREATING", "UPDATING", "SYNCHRONIZING") or time.time() - t0 > timeout:
            return t
        time.sleep(10)


def delete_target(client, tid):
    try:
        client.delete_gateway_target(gatewayIdentifier=GW, targetId=tid)
    except botocore.exceptions.ClientError as e:
        log("  delete failed:", e.response["Error"]["Code"], e.response["Error"]["Message"][:200])
        return False
    for _ in range(30):
        try:
            client.get_gateway_target(gatewayIdentifier=GW, targetId=tid)
            time.sleep(5)
        except botocore.exceptions.ClientError:
            return True
    return True


def ensure_absent(client, name):
    """Delete any pre-existing target with this name and wait until it is gone.

    These tests use fixed target names and only clean up on a successful run, so an
    interrupted run leaves a target behind and the next create fails with
    ConflictException ('a target with name ... already exists'). Call this before each
    create to make the tests idempotent."""
    try:
        existing = client.list_gateway_targets(gatewayIdentifier=GW).get("items", [])
    except botocore.exceptions.ClientError:
        return
    for t in existing:
        if t.get("name") == name:
            log(f"  pre-clean: deleting leftover target {name} ({t['targetId']})")
            delete_target(client, t["targetId"])


def inbound_token():
    cog = s1.client("cognito-idp")
    sec = cog.describe_user_pool_client(UserPoolId=st["USER_POOL_ID"], ClientId=st["CLIENT_ID"])["UserPoolClient"]["ClientSecret"]
    req = urllib.request.Request(st["TOKEN_URL"], data=b"grant_type=client_credentials&scope=lab-gateway/invoke",
        headers={"Content-Type": "application/x-www-form-urlencoded",
                 "Authorization": "Basic " + base64.b64encode(f"{st['CLIENT_ID']}:{sec}".encode()).decode()})
    return json.load(https_open(req))["access_token"], sec


def mcp_call(token, tool, args, rid=99):
    body = json.dumps({"jsonrpc": "2.0", "id": rid, "method": "tools/call", "params": {"name": tool, "arguments": args}}).encode()
    req = urllib.request.Request(st["GW_URL"], data=body, method="POST",
                                 headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    try:
        with https_open(req, timeout=60) as r:
            return r.status, r.read().decode()[:600]
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:600]


TOOLS_SPEC = {
    "openapi": "3.0.1", "info": {"title": "neg test", "version": "1.0"},
    "servers": [{"url": f"https://{HOST}/api"}],
    "paths": {"/employees/{employeeId}": {"get": {"operationId": "getEmployee", "summary": "Get an employee",
        "parameters": [{"name": "employeeId", "in": "path", "required": True, "schema": {"type": "string"}}],
        "responses": {"200": {"description": "ok", "content": {"application/json": {"schema": {"type": "object"}}}}}}}},
}
PRIV = {"selfManagedLatticeResource": {"resourceConfigurationIdentifier": st.get("TOOLS_RCFG_ARN", "")}}
CA = [{"secretsManager": {"secretArn": st.get("CA_SECRET_ARN", "")}}]
OAUTH = [{"credentialProviderType": "OAUTH", "credentialProvider": {"oauthCredentialProvider": {
    "providerArn": st.get("TOOLS_OCP_ARN", ""), "scopes": ["lab-tools/invoke"], "grantType": "CLIENT_CREDENTIALS"}}}]
# OAuth provider for the private API's own Cognito (the API's Cognito authorizer requires its access token)
API_OAUTH = [{"credentialProviderType": "OAUTH", "credentialProvider": {"oauthCredentialProvider": {
    "providerArn": st.get("CP_ARN", ""), "scopes": ["lab-api/invoke"], "grantType": "CLIENT_CREDENTIALS"}}}]


def dummy_key_provider():
    """A throwaway API-key credential provider whose value is not a token, for targets that must send no valid bearer token."""
    name = "lab-neg-not-a-token"
    try:
        return ac.create_api_key_credential_provider(name=name, apiKey="not-a-token")["credentialProviderArn"]
    except botocore.exceptions.ClientError as e:
        if "already exists" not in e.response["Error"].get("Message", ""):
            raise
        return ac.get_api_key_credential_provider(name=name)["credentialProviderArn"]


def dummy_key(header):
    return [{"credentialProviderType": "API_KEY", "credentialProvider": {"apiKeyCredentialProvider": {
        "providerArn": dummy_key_provider(), "credentialParameterName": header, "credentialLocation": "HEADER"}}}]


# ----------------------------------------------------------------------------------- 1. private CA negative
def t_pkix():
    ids = []
    try:
        log("X1 MCP server target to the internal ALB WITHOUT certificateConfigurations (expect FAILED, PKIX)")
        ensure_absent(ac, "neg-no-ca")
        r = ac.create_gateway_target(gatewayIdentifier=GW, name="neg-no-ca",
            targetConfiguration={"mcp": {"mcpServer": {"endpoint": f"https://{HOST}/mcp"}}},
            credentialProviderConfigurations=OAUTH, privateEndpoint=PRIV)
        ids.append(r["targetId"])
        t = wait_target(ac, r["targetId"])
        log(json.dumps({"status": t["status"], "statusReasons": t.get("statusReasons")}, indent=1))
        expect(t["status"] == "FAILED" and "PKIX" in " ".join(t.get("statusReasons") or []),
               "MCP server target without the CA fails certificate path validation")
        log("X1b OpenAPI target WITHOUT certificateConfigurations: create succeeds? then what does a call return?")
        ensure_absent(ac, "neg-no-ca-oapi")
        r2 = ac.create_gateway_target(gatewayIdentifier=GW, name="neg-no-ca-oapi",
            targetConfiguration={"mcp": {"openApiSchema": {"inlinePayload": json.dumps(TOOLS_SPEC)}}},
            credentialProviderConfigurations=OAUTH, privateEndpoint=PRIV)
        ids.append(r2["targetId"])
        t2 = wait_target(ac, r2["targetId"])
        log("  status:", t2["status"], t2.get("statusReasons"))
        expect(t2["status"] == "READY", "OpenAPI target without the CA reaches READY")
        if t2["status"] == "READY":
            tok, _ = inbound_token()
            code, body = mcp_call(tok, "neg-no-ca-oapi___getEmployee", {"employeeId": "1"})
            log("  call:", code, body)
            expect('"isError":true' in body, "the call to the OpenAPI target without the CA returns an error result")
    finally:
        for tid in ids:
            log("  cleanup", tid, delete_target(ac, tid))


# ----------------------------------------------------------------------------------- 2. ALB rejects bad tokens
def t_alb_rejects():
    tok, inbound_secret = inbound_token()
    ids, provider, extra_cleanup = [], None, []
    try:
        log("X2a OpenAPI target -> internal ALB with an API key only (no bearer token). Expect ALB 401.")
        ensure_absent(ac, "neg-no-tool-token")
        r = ac.create_gateway_target(gatewayIdentifier=GW, name="neg-no-tool-token",
            targetConfiguration={"mcp": {"openApiSchema": {"inlinePayload": json.dumps(TOOLS_SPEC)}}},
            credentialProviderConfigurations=dummy_key("x-api-key"), privateEndpoint=PRIV, certificateConfigurations=CA)
        ids.append(r["targetId"]); t = wait_target(ac, r["targetId"]); log("  target:", t["status"], t.get("statusReasons"))
        code, body = mcp_call(tok, "neg-no-tool-token___getEmployee", {"employeeId": "1"}, 41)
        log("  call:", code, body)
        expect('"isError":true' in body, "no bearer token for the tool account: the call fails")

        log("X2b OpenAPI target -> internal ALB with a token from the WRONG identity provider (AgentCore inbound pool). Expect ALB 401.")
        pool = st["USER_POOL_ID"]
        try:
            provider = ac.create_oauth2_credential_provider(name="lab-neg-wrong-idp", credentialProviderVendor="CustomOauth2",
                oauth2ProviderConfigInput={"customOauth2ProviderConfig": {
                    "oauthDiscovery": {"discoveryUrl": f"https://cognito-idp.{REGION}.amazonaws.com/{pool}/.well-known/openid-configuration"},
                    "clientId": st["CLIENT_ID"], "clientSecret": inbound_secret}})["credentialProviderArn"]
        except botocore.exceptions.ClientError as e:
            # An already-existing provider (left by an interrupted run) is returned as
            # ValidationException, not ConflictException, so match on the message rather than the type;
            # then reuse the existing provider.
            if "already exists" not in e.response["Error"].get("Message", ""):
                raise
            provider = ac.get_oauth2_credential_provider(name="lab-neg-wrong-idp")["credentialProviderArn"]
        wrong = [{"credentialProviderType": "OAUTH", "credentialProvider": {"oauthCredentialProvider": {
            "providerArn": provider, "scopes": ["lab-gateway/invoke"], "grantType": "CLIENT_CREDENTIALS"}}}]
        ensure_absent(ac, "neg-wrong-idp")
        r = ac.create_gateway_target(gatewayIdentifier=GW, name="neg-wrong-idp",
            targetConfiguration={"mcp": {"openApiSchema": {"inlinePayload": json.dumps(TOOLS_SPEC)}}},
            credentialProviderConfigurations=wrong, privateEndpoint=PRIV, certificateConfigurations=CA)
        ids.append(r["targetId"]); t = wait_target(ac, r["targetId"]); log("  target:", t["status"], t.get("statusReasons"))
        code, body = mcp_call(tok, "neg-wrong-idp___getEmployee", {"employeeId": "1"}, 42)
        log("  call:", code, body)
        expect('"isError":true' in body, "token from the wrong identity provider: the call fails")

        log("X2c control: same spec with the correct tool-account OAuth provider. Expect 200.")
        ensure_absent(ac, "pos-right-idp")
        r = ac.create_gateway_target(gatewayIdentifier=GW, name="pos-right-idp",
            targetConfiguration={"mcp": {"openApiSchema": {"inlinePayload": json.dumps(TOOLS_SPEC)}}},
            credentialProviderConfigurations=OAUTH, privateEndpoint=PRIV, certificateConfigurations=CA)
        ids.append(r["targetId"]); t = wait_target(ac, r["targetId"]); log("  target:", t["status"])
        code, body = mcp_call(tok, "pos-right-idp___getEmployee", {"employeeId": "1"}, 43)
        log("  call:", code, body)
        expect('"isError":false' in body, "the correct identity provider: the call succeeds")

        log("X2e same tool user pool and scope, but a DIFFERENT app client (client_id pin). Expect ALB 401.")
        cog2 = s2.client("cognito-idp")
        tpool = s2.client("cloudformation").describe_stacks(StackName="lab-spoke2-tools-alb")["Stacks"][0]["Outputs"]
        tpool = next(o["OutputValue"] for o in tpool if o["OutputKey"] == "ToolPoolId")
        other = cog2.create_user_pool_client(UserPoolId=tpool, ClientName="lab-neg-other-client", GenerateSecret=True,
                    AllowedOAuthFlowsUserPoolClient=True, AllowedOAuthFlows=["client_credentials"],
                    AllowedOAuthScopes=["lab-tools/invoke"], SupportedIdentityProviders=["COGNITO"])["UserPoolClient"]
        extra_cleanup.append(lambda: cog2.delete_user_pool_client(UserPoolId=tpool, ClientId=other["ClientId"]))
        try:
            p2 = ac.create_oauth2_credential_provider(name="lab-neg-other-client", credentialProviderVendor="CustomOauth2",
                oauth2ProviderConfigInput={"customOauth2ProviderConfig": {
                    "oauthDiscovery": {"discoveryUrl": f"https://cognito-idp.{REGION}.amazonaws.com/{tpool}/.well-known/openid-configuration"},
                    "clientId": other["ClientId"], "clientSecret": other["ClientSecret"]}})["credentialProviderArn"]
        except botocore.exceptions.ClientError as e:
            if "already exists" not in e.response["Error"].get("Message", ""):
                raise
            ac.delete_oauth2_credential_provider(name="lab-neg-other-client"); time.sleep(5)
            p2 = ac.create_oauth2_credential_provider(name="lab-neg-other-client", credentialProviderVendor="CustomOauth2",
                oauth2ProviderConfigInput={"customOauth2ProviderConfig": {
                    "oauthDiscovery": {"discoveryUrl": f"https://cognito-idp.{REGION}.amazonaws.com/{tpool}/.well-known/openid-configuration"},
                    "clientId": other["ClientId"], "clientSecret": other["ClientSecret"]}})["credentialProviderArn"]
        extra_cleanup.append(lambda: ac.delete_oauth2_credential_provider(name="lab-neg-other-client"))
        ensure_absent(ac, "neg-other-client")
        r = ac.create_gateway_target(gatewayIdentifier=GW, name="neg-other-client",
            targetConfiguration={"mcp": {"openApiSchema": {"inlinePayload": json.dumps(TOOLS_SPEC)}}},
            credentialProviderConfigurations=[{"credentialProviderType": "OAUTH", "credentialProvider": {"oauthCredentialProvider": {
                "providerArn": p2, "scopes": ["lab-tools/invoke"], "grantType": "CLIENT_CREDENTIALS"}}}],
            privateEndpoint=PRIV, certificateConfigurations=CA)
        ids.append(r["targetId"]); t = wait_target(ac, r["targetId"]); log("  target:", t["status"], t.get("statusReasons"))
        code, body = mcp_call(tok, "neg-other-client___getEmployee", {"employeeId": "1"}, 45)
        log("  call:", code, body)
        expect('"isError":true' in body, "valid token from the right pool but another app client: the call fails (client_id pin)")

        log("X2d private API Gateway path: OpenAPI target with no valid token for the API's Cognito authorizer. Expect API Gateway 401.")
        api_spec = {"openapi": "3.0.1", "info": {"title": "apigw neg", "version": "1"}, "servers": [{"url": f"https://{st['API_HOST']}/prod"}],
                    "paths": {"/employees/{employeeId}": {"get": {"operationId": "getEmployee",
                        "parameters": [{"name": "employeeId", "in": "path", "required": True, "schema": {"type": "string"}}],
                        "responses": {"200": {"description": "ok", "content": {"application/json": {"schema": {"type": "object"}}}}}}}}}
        ensure_absent(ac, "neg-apigw-no-token")
        r = ac.create_gateway_target(gatewayIdentifier=GW, name="neg-apigw-no-token",
            targetConfiguration={"mcp": {"openApiSchema": {"inlinePayload": json.dumps(api_spec)}}},
            credentialProviderConfigurations=dummy_key("Authorization"),
            privateEndpoint={"selfManagedLatticeResource": {"resourceConfigurationIdentifier": st["RCFG_ARN"]}})
        ids.append(r["targetId"]); t = wait_target(ac, r["targetId"]); log("  target:", t["status"], t.get("statusReasons"))
        code, body = mcp_call(tok, "neg-apigw-no-token___getEmployee", {"employeeId": "1"}, 44)
        log("  call:", code, body)
        expect('"isError":true' in body, "private API without a valid access token: the call fails")
        log("  Confirm the 401s in the ALB access log (status 401, actions_executed jwt-validation): ./observability.sh verify, V5")
    finally:
        for tid in ids:
            log("  cleanup", tid, delete_target(ac, tid))
        if provider:
            try:
                ac.delete_oauth2_credential_provider(name="lab-neg-wrong-idp"); log("  cleanup oauth provider lab-neg-wrong-idp")
            except botocore.exceptions.ClientError as e:
                log("  cleanup of lab-neg-wrong-idp failed:", e.response["Error"]["Code"])
        try:
            ac.delete_api_key_credential_provider(name="lab-neg-not-a-token"); log("  cleanup api key provider lab-neg-not-a-token")
        except botocore.exceptions.ClientError:
            pass
        for f in extra_cleanup:
            try:
                f()
            except botocore.exceptions.ClientError as e:
                log("  cleanup failed:", e.response["Error"]["Code"])


# ----------------------------------------------------------------------------------- 5. least privilege
BLOG_LATTICE = ["vpc-lattice:GetResourceConfiguration", "vpc-lattice:CreateServiceNetworkResourceAssociation",
                "vpc-lattice:GetServiceNetworkResourceAssociation", "vpc-lattice:ListServiceNetworkResourceAssociations",
                "vpc-lattice:AssociateViaAWSService"]
AGENTCORE = ["bedrock-agentcore:CreateGatewayTarget", "bedrock-agentcore:GetGatewayTarget",
             "bedrock-agentcore:DeleteGatewayTarget", "bedrock-agentcore:GetGateway"]


def t_least_priv():
    iam = s1.client("iam"); sts = s1.client("sts")
    acct = sts.get_caller_identity()["Account"]; me = sts.get_caller_identity()["Arn"]
    role = "lab-target-creator-minimal"
    me_role = me.split("/")[1]
    try:  # a role can have a path (for example IAM Identity Center roles), so ask IAM for the real ARN
        me_arn = iam.get_role(RoleName=me_role)["Role"]["Arn"]
    except botocore.exceptions.ClientError:
        me_arn = f"arn:aws:iam::{acct}:role/{me_role}"
    trust = {"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "sts:AssumeRole",
             "Principal": {"AWS": me_arn}}]}
    try:
        iam.create_role(RoleName=role, AssumeRolePolicyDocument=json.dumps(trust), Description="lab: least-privilege Gateway target creation test")
    except iam.exceptions.EntityAlreadyExistsException:
        pass
    actions = BLOG_LATTICE + AGENTCORE
    added, result = [], {}
    rcfg = st["RCFG_ARN"]
    spec = {"openapi": "3.0.1", "info": {"title": "lp", "version": "1"}, "servers": [{"url": f"https://{st['API_HOST']}/prod"}],
            "paths": {"/": {"get": {"operationId": "listPlans", "responses": {"200": {"description": "ok"}}}}}}
    ensure_absent(ac, "lp-minimal")  # full-priv client: the minimal role may lack List/Delete target perms
    try:
        for attempt in range(1, 9):
            iam.put_role_policy(RoleName=role, PolicyName="minimal", PolicyDocument=json.dumps(
                {"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": sorted(set(actions)), "Resource": "*"}]}))
            time.sleep(15)
            c = sts.assume_role(RoleArn=f"arn:aws:iam::{acct}:role/{role}", RoleSessionName="lp")["Credentials"]
            lc = boto3.client("bedrock-agentcore-control", region_name=REGION, aws_access_key_id=c["AccessKeyId"],
                              aws_secret_access_key=c["SecretAccessKey"], aws_session_token=c["SessionToken"])
            log(f"X5 attempt {attempt}: policy = blog's 5 vpc-lattice actions + {AGENTCORE + added} (OAuth credential provider)")
            try:
                r = lc.create_gateway_target(gatewayIdentifier=GW, name="lp-minimal",
                    targetConfiguration={"mcp": {"openApiSchema": {"inlinePayload": json.dumps(spec)}}},
                    credentialProviderConfigurations=API_OAUTH,
                    privateEndpoint={"selfManagedLatticeResource": {"resourceConfigurationIdentifier": rcfg}})
            except botocore.exceptions.ClientError as e:
                msg = e.response["Error"]["Message"]; log("  create denied:", e.response["Error"]["Code"], msg[:300])
                missing = [w.strip(".,;:") for w in msg.split() if ":" in w and w.split(":")[0] in ("bedrock-agentcore", "vpc-lattice", "secretsmanager", "iam", "ec2", "kms", "ram")]
                if not missing:
                    result["create"] = "denied, cannot parse missing action"; break
                added += [m for m in missing if m not in actions]; actions += missing; continue
            t = wait_target(lc, r["targetId"])
            log("  target status:", t["status"], t.get("statusReasons"))
            result["create"] = t["status"]; result["reasons"] = t.get("statusReasons"); result["targetId"] = r["targetId"]
            if t["status"] != "READY" and t.get("statusReasons"):
                txt = " ".join(t["statusReasons"])
                missing = [w.strip(".,;:()") for w in txt.split() if w.startswith(("vpc-lattice:", "bedrock-agentcore:"))]
                if missing and attempt < 8:
                    delete_target(ac, r["targetId"]); added += missing; actions += missing; continue
            log("X5 delete the target with the SAME minimal role (blog list has no Delete* lattice action)")
            ok = delete_target(lc, r["targetId"]); result["delete"] = ok
            log("  delete returned:", ok)
            break
    finally:
        try:
            iam.delete_role_policy(RoleName=role, PolicyName="minimal")
            iam.delete_role(RoleName=role)
            log("  cleanup role", role)
        except botocore.exceptions.ClientError as e:
            log("  cleanup of role failed:", e.response["Error"]["Code"], "- delete", role, "by hand")
        log("RESULT", json.dumps({"extraActionsNeeded": added, **result}, default=str))
        expect(result.get("create") == "READY" and result.get("delete") is True,
               "a role with the blog's VPC Lattice actions plus the AgentCore target actions creates and deletes a target")




# ----------------------------------------------------------------------------------- 4. new tools, no new target
def tools_list(token):
    req = urllib.request.Request(st["GW_URL"], data=json.dumps({"jsonrpc": "2.0", "id": 60, "method": "tools/list"}).encode(),
                                 method="POST", headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    return sorted(t["name"] for t in json.load(https_open(req, timeout=60))["result"]["tools"])


def t_spec_sync():
    tok, _ = inbound_token()
    names = {t["name"]: t["targetId"] for t in ac.list_gateway_targets(gatewayIdentifier=GW)["items"]}
    before = tools_list(tok)
    log("X4 tools before:", before)
    snra_before = {n: ac.get_gateway_target(gatewayIdentifier=GW, targetId=i).get("privateEndpointManagedResources")
                   for n, i in names.items() if n in ("tools-rest", "classifier")}

    log("X4a OpenAPI: add operation getBenefits (/benefits/{employeeId}) to the EXISTING tools-rest target via UpdateGatewayTarget")
    cur = ac.get_gateway_target(gatewayIdentifier=GW, targetId=names["tools-rest"])
    spec = json.loads(cur["targetConfiguration"]["mcp"]["openApiSchema"]["inlinePayload"])
    spec["paths"]["/benefits/{employeeId}"] = {"get": {"operationId": "getBenefits", "summary": "Get benefits for an employee",
        "parameters": [{"name": "employeeId", "in": "path", "required": True, "schema": {"type": "string"}}],
        "responses": {"200": {"description": "ok", "content": {"application/json": {"schema": {"type": "object"}}}}}}}
    upd = {k: cur[k] for k in ("credentialProviderConfigurations", "privateEndpoint", "certificateConfigurations") if k in cur}
    ac.update_gateway_target(gatewayIdentifier=GW, targetId=names["tools-rest"], name="tools-rest",
                             description=cur.get("description", ""),
                             targetConfiguration={"mcp": {"openApiSchema": {"inlinePayload": json.dumps(spec)}}}, **upd)
    t = wait_target(ac, names["tools-rest"]); log("  tools-rest:", t["status"], t.get("statusReasons"))

    log("X4b MCP: classifier server now also exposes estimateCost; call SynchronizeGatewayTargets (no target change)")
    mid = tools_list(tok)
    log("  tools after OpenAPI update, before sync:", mid)
    r = ac.synchronize_gateway_targets(gatewayIdentifier=GW, targetIdList=[names["classifier"]])
    log("  sync response targets:", [(x.get("name"), x.get("status")) for x in r.get("targets", [])])
    t = wait_target(ac, names["classifier"]); log("  classifier:", t["status"], t.get("statusReasons"), "lastSynchronizedAt:", t.get("lastSynchronizedAt"))
    after = tools_list(tok)
    log("  tools after sync:", after)
    log("  NEW:", sorted(set(after) - set(before)))
    expect(set(after) - set(before) == {"tools-rest___getBenefits", "classifier___estimateCost"},
           "both new tools appear (run './run-lab.sh extra-tools' first if they do not)")
    log("X4c call the new tools")
    log("  tools-rest___getBenefits:", *mcp_call(tok, "tools-rest___getBenefits", {"employeeId": "77"}, 61))
    log("  classifier___estimateCost:", *mcp_call(tok, "classifier___estimateCost", {"procedure": "cleaning"}, 62))
    snra_after = {n: ac.get_gateway_target(gatewayIdentifier=GW, targetId=names[n]).get("privateEndpointManagedResources")
                  for n in snra_before}
    log("  Lattice associations unchanged:", snra_before == snra_after, json.dumps(snra_after))
    expect(snra_before == snra_after, "no new VPC Lattice association was created")


if __name__ == "__main__":
    tests = {"pkix": t_pkix, "alb-rejects": t_alb_rejects, "least-priv": t_least_priv, "spec-sync": t_spec_sync}
    if len(sys.argv) != 2 or sys.argv[1] not in tests:
        sys.exit("usage: extra_tests.py " + " | ".join(tests))
    tests[sys.argv[1]]()
    if FAILS:
        sys.exit(f"{len(FAILS)} expectation(s) failed")
