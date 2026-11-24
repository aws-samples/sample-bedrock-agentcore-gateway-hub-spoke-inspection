# Test results

Results of a clean run on 2026-11-12 (UTC) in us-east-1: a fresh clone of this repository, deployed into empty accounts and run in the order in the README, with AWS CLI 2.40.0 and Boto3 1.43.108. Every step passed. Raw output is in [`evidence/`](../evidence/), with account IDs replaced by placeholders and tokens removed. The check numbers match [validation-checks.md](validation-checks.md). On 2026-11-23 we redeployed the lab with AWS CLI 2.42.1 and Boto3 1.44.0 to retest managed mode in shared subnets (checks 4 and 4c). That output is in [`evidence/retest-2026-11-23/`](../evidence/retest-2026-11-23/).

| Command (in `lab-code/`) | What it tests | Result | Evidence |
|---|---|---|---|
| `run-lab.sh deploy`, `test` | Stacks deploy across three accounts; private REST API reached through the resource gateway, transit gateway, firewall, and `execute-api` endpoint; no token returns 401; AWS WAF blocks an attack payload; the private API isn't reachable from the internet (check 1) | Pass. The API saw a source IP in the resource gateway range and the network account's endpoint ID. | `deploy.log`, `test.log` |
| `run-lab.sh alb`, `test-alb` | OpenAPI and MCP server targets to the internal ALB with OAuth and a private CA; an agent in a subnet with no internet route reaches the Gateway through the interface endpoint; AWS WAF on the private path | Pass | `alb.log`, `test-alb.log` |
| `run-lab.sh negative` | Managed mode on a shared subnet, with no security group and with one the AgentCore account owns (check 4) | Both targets `FAILED` with `The subnet with ID subnet-... cannot be found (Service: VpcLattice, Status Code: 404)`. A direct `CreateResourceGateway` call from the AgentCore account failed the same way; the same call from the network account succeeded. | `negative.log`; `negative-direct-rgw.log` (manual `CreateResourceGateway` calls, 2026-11-11). **Superseded on 2026-11-23, see the next two rows.** |
| `run-lab.sh negative` (retest 2026-11-23, after the VPC Lattice shared-subnet launch) | Same as check 4 | No security group: `FAILED`, `Security groups are required for shared subnet ... Specify at least one security group that you own` (400). AgentCore-owned security group: `READY`; the resource gateway is in the AgentCore account, in the shared agent subnets, and the network account can't list it. | `retest-2026-11-23/negative.log` (its N1a heading still says the target falls back to the default security group; that label was corrected after the run) |
| `retest-shared-subnet.sh` (2026-11-23) | Managed-mode path through the firewall (check 4c) | `READY` in 309 s. Unchanged policy: timeout, no firewall alert. Endpoint security group opened: timeout, firewall `to_server` blocks. Plus firewall pass rule: success, `sourceIp` in 10.11.x. Reply drop (sid 100298): timeout, `to_client` drops logged; removed: success. Everything restored. | `retest-2026-11-23/shared-subnet.log` (run 1, `shared-subnet-run1.log`, stopped at the firewall update because of a script bug fixed before run 2); `versions.txt` (AWS CLI 2.42.1, Boto3 1.44.0) |
| `run-lab.sh evidence` | No resource gateway in the AgentCore account (check 5); one VPC Lattice association per target | Pass. Each target got its own association, including targets on the same resource configuration. | `evidence.log` |
| `run-lab.sh prove-multi` | A second private API in another account works through the same resource configuration (check 6) | Pass; network stack unchanged | `prove-multi.log` |
| `run-lab.sh prove-return` | Replies cross the firewall (check 3) | Pass. Calls hung while the reply-direction drop rule was in place, the firewall logged `to_client` drops, and calls worked after the rule was removed. | `prove-return.log` |
| `run-lab.sh prove-vpce-policy` | The Gateway interface endpoint reaches only listed Gateways (check 13) | Pass. An unlisted Gateway returned -32002 through the endpoint and still answered on its public endpoint. | `prove-vpce-policy.log` |
| `run-lab.sh prove-ram-permission` | Whether a customer managed AWS RAM permission can replace the AWS managed one | Pass: the limitation reproduces. AWS RAM rejects `vpc-lattice:AssociateViaAWSService` in a customer managed permission, and without it Gateway targets fail. The share is restored to the AWS managed permission. | `prove-ram-permission.log` |
| `run-lab.sh prove-sharee-scp` | The SCP keeps the Gateway the only consumer of the shared resource configuration (check 14) | Pass. A resource VPC endpoint and an own service network association were denied; a Gateway target reached `READY` and served calls. The SCP is removed afterwards. | `prove-sharee-scp.log` |
| `extra_tests.py pkix` | Private CA enforcement (check 11) | Pass. An MCP server target without the CA failed with `PKIX path building failed`; an OpenAPI target reached `READY` and failed at call time. | `x1-pkix.log` |
| `extra_tests.py alb-rejects` | The ALB and private API are token boundaries (check 7) | Pass. No token, another identity provider's token, another app client's token (`client_id` pin), and no valid token on the private API all failed; the ALB logged 401s. | `x2-rejects.log` |
| `x3-jwks-egress.sh` | Signing-key fetch needs the scoped egress rule (check 8) | Pass. ALB returned 500 and the firewall logged default-action drops while the rule was removed. | `x3-jwks-egress.log` |
| `extra_tests.py least-priv` | The IAM actions listed in the prerequisites are enough to create and delete a target | Pass, no extra actions needed | `x5-least-priv.log` |
| `run-lab.sh extra-tools`, `extra_tests.py spec-sync` | New tools appear without a new target or association | Pass | `x4-extra-tools.log`, `x4-spec-sync.log` |
| `observability.sh enable`, `traffic`, `verify` | Every hop is logged (check 12) | Pass. Gateway, AWS WAF, VPC Lattice access, flow, ALB, and CloudTrail logs all recorded the calls. | `obs-enable.log`, `obs-traffic.log`, `obs-verify.log` |
| `observability.sh policy-test` | The resource policy closes the public endpoint (check 9) | Pass. Internet calls returned -32002 by the first check, about 32 seconds after the policy was applied; endpoint calls kept working. | `obs-policy.log` |

## Not run in the clean run

- `run-lab.sh runtime` and `test-runtime` (AgentCore Runtime in VPC mode as the caller). These passed in earlier runs with the previous lab code.
- `x8-rate-limit.sh` (AWS WAF rate-based rule).

## Not tested

Third-party firewalls, source NAT on the firewall, Regions other than us-east-1, and private identity providers.

---

Back to the [repository README](../README.md).
