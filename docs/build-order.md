# Build order across accounts

Each step runs in the account named. Decision numbers refer to the blog post.

Steps 1–3 happen once; steps 4–7 repeat for each new backend or tool account.

1. **Management account:** enable resource sharing with AWS Organizations in AWS RAM.
2. **Network account:** create the VPCs, subnets, transit gateway and its two route tables, the inspection VPC with the firewall (strict order, rules from Decision 3) and NAT gateway, and the route tables in [lab-layout.md](lab-layout.md). Share the agent and tool subnets through AWS RAM.
3. **Network account:** create the resource gateway (Decision 1), and the Gateway interface endpoint in the agent VPC.
4. **Tool account:** create the identity provider and an app client for the Gateway, then the internal ALB with its security group and listener rules (Decision 4), or the private REST API with its authorizer and a resource policy that allows the network account's `execute-api` endpoint through `aws:SourceVpce`. For private APIs, the network account first creates the `execute-api` endpoint and its policy.
5. **Network account:** create the resource configuration for the ALB or `execute-api` endpoint, and add it to the AWS RAM share (Decision 2).
6. **AgentCore account:** create the Gateway with its JWT authorizer, the OAuth credential provider for the tool account, the CA secret if needed, and the target (Decision 5). Associate the AWS WAF web ACL.
7. **Network account:** add the Gateway's ARN to the interface endpoint policy. **AgentCore account:** attach the resource policy (Decision 6). **Management account:** attach the SCP from Decision 5 to the AgentCore account.

Test the target over the Gateway's public endpoint after step 6, and again through the interface endpoint after step 7.

## Values passed between teams

| From | To | Values |
|----|----|----|
| AgentCore team | Network team | AgentCore account ID (for the AWS RAM share and SCP), Gateway ARN (for the endpoint policy) |
| Tool team | Network team | Internal ALB DNS name and its subnets (for the resource configuration and firewall rules); API account IDs (for the `execute-api` endpoint policy) |
| Network team | AgentCore team | Resource configuration ARNs, Gateway interface endpoint ID (for the resource policy) |
| Network team | Tool team | Resource gateway subnet ranges, or the firewall's addresses if it applies source NAT (for the ALB or endpoint security group) |
| Tool team | AgentCore team | Identity provider discovery URL, app client ID and secret, scope, target host name, private CA certificate if used |

---

Back to the [repository README](../README.md). Companion to the blog post *Connect Amazon Bedrock AgentCore Gateway to private APIs in a hub-and-spoke network with centralized inspection*.
