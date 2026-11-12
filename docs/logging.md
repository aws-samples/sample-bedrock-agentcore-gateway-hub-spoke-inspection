# Log every hop

One log source per hop, and the account that owns it. `lab-code/observability.sh enable` turns all of them on in the lab, and `verify` shows one record per source.

| Hop | Log source | Account | What it records |
|----|----|----|----|
| Agent to Gateway interface endpoint | VPC flow logs on the agent VPC | Network | Which caller reached the endpoint |
| Gateway | Gateway application logs (vended to CloudWatch Logs, Amazon S3, or Amazon Data Firehose) | AgentCore | Each request, the tool and target it ran, success or failure, AWS WAF blocks, and resource policy denials. Includes request and response bodies. |
| Gateway | AWS WAF logs (if attached) | AgentCore | Allowed and blocked requests, the matching rule, and the caller's private IP |
| Gateway to resource gateway | VPC Lattice access logs on each resource configuration | Network | Each connection: association ID, resource gateway IP and port, and backend IP and port |
| Resource gateway to transit gateway | VPC flow logs on the resource gateway VPC | Network | Connections from resource gateway interfaces to backends |
| Inspection VPC | Firewall flow and alert logs | Network | Both directions of each flow (IPs, ports, TLS SNI) |
| Internal ALB | Access and connection logs (Amazon S3) | Tool | Request line with host, status code, TLS version, client IP, and token rejects |
| Control plane | AWS CloudTrail | All | Changes to targets, resource configurations, AWS RAM shares, and policies. Each new association appears as `CreateServiceNetworkResourceAssociation` in the AgentCore account and as `CreateServiceNetworkResourceAssociationBySharee` in the network account. |

The VPC Lattice service network belongs to AgentCore, but the network account can still subscribe access logs to its own resource configurations with `aws vpc-lattice create-access-log-subscription`.

---

Back to the [repository README](../README.md). Companion to the blog post *Connect Amazon Bedrock AgentCore Gateway to private APIs in a hub-and-spoke network with centralized inspection*.
