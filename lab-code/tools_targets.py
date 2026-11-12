#!/usr/bin/env python3
"""Create the two targets of the internal-ALB scenario on the lab Gateway (needs boto3 >= 1.43.106 for certificateConfigurations).
Targets that already exist are left as they are; delete them first to change their configuration.

  tools-rest  : OpenAPI target -> REST API behind the tool account's INTERNAL ALB
  classifier  : MCP-server target -> MCP server behind the SAME internal ALB
Both: self-managed Lattice (hub resource configuration -> ALB DNS), OAuth client_credentials against the
tool account's Cognito, and trust of the PRIVATE CA (no public cert, no extra ALB).

usage: tools_targets.py <gateway_id> <rcfg_arn> <oauth_provider_arn> <ca_secret_arn>
"""
import json, os, sys, time, boto3

gw, rcfg, ocp, ca = sys.argv[1:5]
HOST = "tools.demo-lab.internal"
c = boto3.Session(profile_name=os.environ.get("S1_PROFILE", "lab-spoke1"),
                  region_name=os.environ.get("AWS_REGION", "us-east-1")).client("bedrock-agentcore-control")

spec = {
    "openapi": "3.0.1",
    "info": {"title": "Employee REST API (internal ALB)", "version": "1.0"},
    "servers": [{"url": f"https://{HOST}/api"}],
    "paths": {
        "/plans": {"get": {"operationId": "listPlans", "summary": "List benefit plans",
                           "responses": {"200": {"description": "ok", "content": {"application/json": {"schema": {"type": "object"}}}}}}},
        "/employees/{employeeId}": {"get": {"operationId": "getEmployee", "summary": "Get an employee",
            "parameters": [{"name": "employeeId", "in": "path", "required": True, "schema": {"type": "string"}}],
            "responses": {"200": {"description": "ok", "content": {"application/json": {"schema": {"type": "object"}}}}}}},
    },
}
common = {
    "credentialProviderConfigurations": [{"credentialProviderType": "OAUTH", "credentialProvider": {
        "oauthCredentialProvider": {"providerArn": ocp, "scopes": ["lab-tools/invoke"], "grantType": "CLIENT_CREDENTIALS"}}}],
    "privateEndpoint": {"selfManagedLatticeResource": {"resourceConfigurationIdentifier": rcfg}},
    "certificateConfigurations": [{"secretsManager": {"secretArn": ca}}],
}
targets = {
    "tools-rest": {"description": "OpenAPI -> internal ALB REST (Service Gateway)",
                   "targetConfiguration": {"mcp": {"openApiSchema": {"inlinePayload": json.dumps(spec)}}}},
    "classifier": {"description": "MCP server -> internal ALB /mcp (Classifier MCP)",
                   "targetConfiguration": {"mcp": {"mcpServer": {"endpoint": f"https://{HOST}/mcp"}}}},
}
existing = {t["name"]: t["targetId"] for page in c.get_paginator("list_gateway_targets").paginate(gatewayIdentifier=gw) for t in page["items"]}
ids = {}
for name, body in targets.items():
    if name in existing:
        ids[name] = existing[name]
        continue
    r = c.create_gateway_target(gatewayIdentifier=gw, name=name, **body, **common)
    ids[name] = r["targetId"]
    print(f"created {name}: {ids[name]}", flush=True)

for _ in range(60):
    st = {n: c.get_gateway_target(gatewayIdentifier=gw, targetId=i) for n, i in ids.items()}
    if all(s["status"] not in ("CREATING", "UPDATING", "SYNCHRONIZING") for s in st.values()):
        break
    time.sleep(15)
bad = []
for n, s in st.items():
    print(json.dumps({"name": n, "id": ids[n], "status": s["status"], "reasons": s.get("statusReasons"),
                      "lattice": s.get("privateEndpointManagedResources")}, default=str))
    if s["status"] != "READY":
        bad.append(n)
if bad:
    sys.exit(f"targets not READY: {', '.join(bad)}")
