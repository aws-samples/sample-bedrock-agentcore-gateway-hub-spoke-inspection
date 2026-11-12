# Troubleshooting

The Gateway often returns a generic error to the agent. This table maps common symptoms to the log that shows the cause. Turn on Gateway application logs ([logging](logging.md)) before you need them.

| Symptom at the agent | Likely cause | Where to look | Field or value |
|----|----|----|----|
| `An internal error occurred. Please retry later.` right after a target becomes `READY` | VPC Lattice data path still propagating | Retry after about a minute | n/a |
| `An internal error occurred` on every call to an ALB target, with ALB log entries | Token rejected at the ALB | ALB access log | `elb_status_code` 401, `actions_executed` includes `jwt-validation` |
| `An internal error occurred` on an OpenAPI target, with no ALB log entry | TLS failed: certificate SAN doesn't match the target host name, or the private CA isn't registered | ALB connection log, `GetGatewayTarget` | TLS handshake failure; `certificateConfigurations` |
| `MCP invocation failed`, ALB returns 500 | ALB can't fetch the JWKS | Firewall alert log | Drops from ALB subnets to a public address on port 443 |
| Call hangs until timeout | Firewall drops replies, or no return route | Firewall alert log | `direction` `to_client`, `action` `blocked` |
| JSON-RPC -32002 `Request forbidden` | AWS WAF block | AWS WAF log | `action` BLOCK, `terminatingRuleId` |
| JSON-RPC -32002 `Insufficient permissions` | Resource policy or endpoint policy denial | Gateway application log | Policy denial entry; compare `aws:SourceVpce` and endpoint policy resources |
| Target `FAILED` with `PKIX path building failed` | Private CA not registered, or wrong CA | `GetGatewayTarget` | `statusReasons` |
| Target `FAILED` with `not authorized to perform: vpc-lattice:...` | Missing IAM permission or SCP for the creating role | `GetGatewayTarget` | `statusReasons` names the action |
| Target `FAILED` with `subnet ... cannot be found` | Managed mode on a shared subnet | `GetGatewayTarget` | `statusReasons` |

---

Back to the [repository README](../README.md). Companion to the blog post *Connect Amazon Bedrock AgentCore Gateway to private APIs in a hub-and-spoke network with centralized inspection*.
