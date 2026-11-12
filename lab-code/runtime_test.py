#!/usr/bin/env python3
"""AgentCore Runtime as the Gateway caller (blog Figure 1), VPC mode in the SHARED agent subnets.

usage: runtime_test.py deploy | invoke | delete   (normally run through ./run-lab.sh runtime | test-runtime | teardown)
deploy: zips runtime_agent/, uploads it, creates the runtime (direct code deployment, network mode VPC).
invoke: calls the runtime; the runtime calls the Gateway through the Gateway interface VPC endpoint.
Needs boto3 >= 1.43.106, the code bucket, and stacks lab-hub-network (AgentRuntimeEndpoints=true) + lab-spoke1-runtime,
all created by './run-lab.sh runtime'. Environment: S1_PROFILE, AWS_REGION (same contract as the shell scripts).
"""
import io, json, os, shlex, sys, time, uuid, zipfile, base64, urllib.parse, urllib.request
import boto3, botocore

DIR = os.path.dirname(os.path.abspath(__file__))
REGION = os.environ.get("AWS_REGION", "us-east-1")
S1 = os.environ.get("S1_PROFILE", "lab-spoke1")
st = {}
for line in open(os.path.join(DIR, ".lab-state.env")):
    if "=" in line:
        k, v = line.rstrip("\n").split("=", 1)
        st[k] = shlex.split(v)[0] if v else ""
s1 = boto3.Session(profile_name=S1, region_name=REGION)
acct = s1.client("sts").get_caller_identity()["Account"]
BUCKET = f"lab-runtime-code-{acct}"
KEY = "lab-gw-caller/code.zip"
NAME = "lab_gateway_caller"
ctl = s1.client("bedrock-agentcore-control")


def out(stack, key):
    cfn = s1.client("cloudformation")
    return next(o["OutputValue"] for o in cfn.describe_stacks(StackName=stack)["Stacks"][0]["Outputs"] if o["OutputKey"] == key)


def find_runtime():
    for page in ctl.get_paginator("list_agent_runtimes").paginate():
        for r in page["agentRuntimes"]:
            if r["agentRuntimeName"] == NAME:
                return r
    return None


def deploy():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(os.path.join(DIR, "runtime_agent", "main.py"), "main.py")
    s1.client("s3").put_object(Bucket=BUCKET, Key=KEY, Body=buf.getvalue())
    print("uploaded", f"s3://{BUCKET}/{KEY}", flush=True)
    subnets = st["S1_SUBNETS"].split(",")
    if not find_runtime():
        r = ctl.create_agent_runtime(
            agentRuntimeName=NAME,
            description="Lab: stands in for an agent calling AgentCore Gateway from a shared subnet",
            agentRuntimeArtifact={"codeConfiguration": {"code": {"s3": {"bucket": BUCKET, "prefix": KEY}},
                                                        "runtime": "PYTHON_3_12", "entryPoint": ["main.py"]}},
            roleArn=out("lab-spoke1-runtime", "RuntimeRoleArn"),
            networkConfiguration={"networkMode": "VPC", "networkModeConfig": {
                "subnets": subnets, "securityGroups": [out("lab-spoke1-runtime", "RuntimeSgId")]}},
            protocolConfiguration={"serverProtocol": "HTTP"})
        print("created", r["agentRuntimeArn"], flush=True)
    for _ in range(60):
        r = find_runtime()
        d = ctl.get_agent_runtime(agentRuntimeId=r["agentRuntimeId"])
        print("  status:", d["status"], d.get("failureReason", ""), flush=True)
        if d["status"] not in ("CREATING", "UPDATING"):
            break
        time.sleep(15)
    print(json.dumps({"arn": d["agentRuntimeArn"], "status": d["status"],
                      "network": d.get("networkConfiguration")}, default=str, indent=1))
    if d["status"] != "READY":
        sys.exit(f"runtime is {d['status']}: {d.get('failureReason', '')}")


def token():
    cog = s1.client("cognito-idp")
    sec = cog.describe_user_pool_client(UserPoolId=st["USER_POOL_ID"], ClientId=st["CLIENT_ID"])["UserPoolClient"]["ClientSecret"]
    req = urllib.request.Request(st["TOKEN_URL"], data=b"grant_type=client_credentials&scope=lab-gateway/invoke",
        headers={"Content-Type": "application/x-www-form-urlencoded",
                 "Authorization": "Basic " + base64.b64encode(f"{st['CLIENT_ID']}:{sec}".encode()).decode()})
    if urllib.parse.urlparse(req.full_url).scheme != "https":
        raise ValueError("token URL must be HTTPS")
    return json.load(urllib.request.urlopen(req, timeout=30))["access_token"]  # nosec B310 - scheme checked above


def invoke():
    r = find_runtime()
    if not r:
        sys.exit("runtime lab_gateway_caller not found; run './run-lab.sh runtime' first")
    dp = s1.client("bedrock-agentcore", config=botocore.config.Config(read_timeout=120, retries={"max_attempts": 1}))
    tok = token()
    cases = [
        ("R1 tools/list", {"jsonrpc": "2.0", "id": 51, "method": "tools/list"}, {}),
        ("R2 classifier via internal ALB", {"jsonrpc": "2.0", "id": 52, "method": "tools/call",
            "params": {"name": "classifier___classifyQuestion", "arguments": {"question": "Is a tooth crown covered?"}}}, {}),
        ("R3 private API via execute-api VPCE", {"jsonrpc": "2.0", "id": 53, "method": "tools/call",
            "params": {"name": "employee-api___getEmployee", "arguments": {"employeeId": "8080"}}}, {}),
        ("R4 WAF on the Runtime path (XSS in tool arguments)", {"jsonrpc": "2.0", "id": 54, "method": "tools/call",
            "params": {"name": "classifier___classifyQuestion", "arguments": {"question": "<script>alert(1)</script>"}}}, {}),
    ]
    for label, body, hdr in cases:
        payload = json.dumps({"gatewayUrl": st["GW_URL"], "token": tok, "body": body, "extraHeaders": hdr}).encode()
        resp = dp.invoke_agent_runtime(agentRuntimeArn=r["agentRuntimeArn"], runtimeSessionId=str(uuid.uuid4()) + "-lab",
                                       payload=payload, contentType="application/json", accept="application/json")
        d = json.loads(resp["response"].read())
        b = d.get("body") or d.get("error", "")
        try:
            b = json.loads(b)
            b = b.get("result", {}).get("content", [{}])[0].get("text") or b.get("error") or b
        except Exception:
            pass
        print(f"{label}\n  caller={d.get('caller')} resolvedTo={d.get('resolvedTo')} HTTP {d.get('status')}\n  {str(b)[:260]}", flush=True)


def delete():
    r = find_runtime()
    if r:
        ctl.delete_agent_runtime(agentRuntimeId=r["agentRuntimeId"])
        print("deleting runtime", r["agentRuntimeId"])
        for _ in range(40):
            if not find_runtime():
                break
            time.sleep(10)
    s3 = s1.resource("s3")
    try:
        b = s3.Bucket(BUCKET); b.object_versions.delete(); b.objects.delete(); b.delete(); print("deleted bucket", BUCKET)
    except botocore.exceptions.ClientError as e:
        print("bucket:", e.response["Error"]["Code"])


if __name__ == "__main__":
    {"deploy": deploy, "invoke": invoke, "delete": delete}[sys.argv[1]]()
