# Validation checks

Run these checks in a non-production copy of your network account, with your own firewall. Each one tests a single claim from the blog post. In the lab, `lab-code/run-lab.sh` and the other scripts run these checks (see [Run the lab](../README.md#run-the-lab)); [test-results.md](test-results.md) maps each check to its command, result, and evidence file.

*Validation checks.*

| Check | What you test | How | Expected result (what we saw) |
|----|----|----|----|
| 1 | Requests reach the backend through the resource gateway | Call a tool, then check the backend or ALB access log | Source IP is in the resource gateway range (or your firewall's range if it applies source NAT); for API Gateway, the `vpce` ID is the network account's `execute-api` endpoint |
| 2 | Requests cross the firewall | Check your firewall flow logs for the call | TLS flows from resource gateway addresses to tool account addresses on port 443 |
| 3 | Replies cross the firewall | Add a drop rule for reply traffic (server to client) above your pass rule, call a tool, then remove it (blog Decision 3) | Calls fail while replies are dropped, and the firewall logs `to_client` drops; calls work again after you remove the rule |
| 4 | Managed mode on your shared subnets needs a security group the AgentCore account owns | Create a target with managed mode on a shared subnet, without a security group and with one the AgentCore account owns | Without a security group: `FAILED` with `Security groups are required for shared subnet ... Specify at least one security group that you own (Service: VpcLattice, Status Code: 400)`. With an AgentCore-owned security group: `READY` in about 5 minutes. On 11 November 2026, both failed with `The subnet with ID subnet-... cannot be found (Status Code: 404)`. (us-east-1, retested 23 November 2026) |
| 4c | Managed mode in shared subnets crosses the firewall in both directions | `lab-code/retest-shared-subnet.sh`: call the managed target with the network policy unchanged, then after allowing the agent range in the endpoint security group, then after adding a firewall pass rule; then add a reply-direction drop rule | Unchanged policy: timeout, no firewall alert (the endpoint security group drops the connection before it is established). Security group only: timeout, firewall blocks `10.11.x -> 10.12.x:443 to_server`. Both changes: success, source IP in the agent subnets. Reply drop: timeout and `to_client` drops logged; removing it restores calls. The network account can't list the resource gateway AgentCore created. |
| 5 | The AgentCore account needs no network resources | List resource gateways and subnets in the AgentCore account | No resource gateway; only the shared resource configurations and shared agent subnets |
| 6 | A new API needs no network change | Add a second private API (in any account) behind the existing `execute-api` resource configuration | It works, and the network account's configuration is unchanged |
| 7 | The ALB and the private API are token boundaries | Create a target with no valid bearer token, and one with a token from another identity provider | HTTP 401 at the ALB or API Gateway, backend not invoked; the agent sees a generic internal error |
| 8 | Signing-key fetch uses scoped, inspected egress | Temporarily remove the JWKS rule, call a tool, then restore | ALB returns HTTP 500 and the firewall logs the drop; calls work again after you restore it |
| 9 | The public Gateway endpoint is closed | Attach the `aws:SourceVpce` resource policy, call over the internet and through the endpoint | Internet: JSON-RPC -32002 `Insufficient permissions`; endpoint: success |
| 10 | AWS WAF sees tool-call arguments | Send a script tag, then a SQL injection string, in tool-call arguments | Script tag blocked (`CrossSiteScripting_BODY`); SQL injection passes the common rule set alone, so add `AWSManagedRulesSQLiRuleSet` |
| 11 | The private CA is enforced (MCP server targets) | Create an MCP server target without `certificateConfigurations` | Target `FAILED` with `PKIX path building failed`. An OpenAPI target without the CA reaches `READY` and fails only when a tool is called, with a generic internal error |
| 12 | Every hop is logged | Make one test call and look for it in each source in the [logging table](logging.md) | One record per source, including VPC Lattice access logs in the network account |
| 13 | The interface endpoint reaches only approved gateways | Call a second gateway through the same endpoint | JSON-RPC -32002 for the unlisted gateway; success for the listed one |
| 14 | The Gateway is the only consumer of the shared resource configuration | With the SCP attached, create a resource endpoint and an own service network association for it, then a Gateway target | Endpoint and association denied; Gateway target `READY` and working |

**What we tested.** We ran these checks in us-east-1 between October 1 and November 11, 2026, with AWS Network Firewall in strict rule order (our earlier runs used default action order), no source NAT, an inbound token we obtained outside the agent VPC, and an internal ALB and a private REST API as backends. We didn't test third-party firewalls, source NAT, or other Regions.

---

Back to the [repository README](../README.md). Companion to the blog post *Connect Amazon Bedrock AgentCore Gateway to private APIs in a hub-and-spoke network with centralized inspection*.
