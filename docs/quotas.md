# Quotas that shape the design

Defaults are per account per Region and adjustable unless noted. Sources: [AgentCore quotas](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/bedrock-agentcore-limits.html) and [VPC Lattice quotas](https://docs.aws.amazon.com/vpc-lattice/latest/ug/quotas.html).

| Quota | Default | What it means for this pattern |
|----|----|----|
| Tool-call/tool-list rate, per gateway and per account | 200 transactions per second | The account quota equals the gateway quota, so one busy gateway can use the whole account's allowance. Use a separate AgentCore account per environment. |
| Tool-call/tool-list concurrent connections, per gateway and per account | 5,000 | Same as above. |
| Targets per gateway | 100 | Split gateways by domain or agent group well before the limit. |
| Tools per target | 1,000 | One OpenAPI or MCP server target can expose many tools. |
| Target create/update/delete rate; concurrent target operations per gateway | 5 transactions per second; 5 | Serialize target changes in your deployment pipeline. |
| Gateway invocation timeout; tool-call payload | 15 minutes; 6 MB | Make long-running tools asynchronous, and return large results by reference. |
| Resource configurations per Region (network account) | 2,000 | One per backend load balancer stays well below the limit. |
| Idle timeout for VPC Lattice resource connections | 350 seconds (not adjustable) | Use TCP or application keepalives for long-lived MCP streams. |

To limit individual callers, targets, or tools inside one account, use [gateway rate limits](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-rate-limits.html). They fail open on transient errors, so don't treat them as a security boundary. Also check the VPC endpoint quotas in the network account as you add agent VPCs.

---

Back to the [repository README](../README.md). Companion to the blog post *Connect Amazon Bedrock AgentCore Gateway to private APIs in a hub-and-spoke network with centralized inspection*.
