# Design notes and considerations

Details that support the blog post but that most readers don't need on a first read.

## AWS Network Firewall rule order

We used AWS Network Firewall with strict rule order: rules run top to bottom and the first match decides. Packets that match no rule get the policy's default actions. We used **Drop established** with **Alert established**. Drop established lets the TCP handshake through so that TLS rules can read the SNI, drops client-to-server packets that no rule passed, and passes server-to-client packets of established connections. That default is why replies of an allowed flow get through: no rule drops them. A rule that does match replies still applies to them, which is how check 3 works. Network Firewall also offers **Application drop established** variants for segmented TLS handshakes; see [Strict evaluation order](https://docs.aws.amazon.com/network-firewall/latest/developerguide/suricata-rule-evaluation-order.html). Don't use **Drop all**, which drops the handshake packets that pass rules need. Our earlier lab runs used default action order, with a drop-all rule limited to client-to-server packets (`flow:to_server`), and passed the same checks.

## AWS WAF rule groups for tool calls

Choose rule groups for what tool calls carry, and test new rules in Count mode first. In our tests, `AWSManagedRulesCommonRuleSet` blocked a script tag in tool-call arguments (`CrossSiteScripting_BODY`), and the Gateway returned JSON-RPC error -32002. A SQL injection string in the arguments passed the common rule set, so also add `AWSManagedRulesSQLiRuleSet`. For AgentCore Gateway, AWS WAF [inspects the first 16 KB of the body by default](https://docs.aws.amazon.com/waf/latest/developerguide/waf-oversize-request-components.html), and you can raise the limit to 64 KB in the web ACL. Choose how each rule handles oversize bodies. The common rule set also [blocks bodies larger than 8 KB](https://docs.aws.amazon.com/waf/latest/developerguide/aws-managed-rule-groups-baseline.html) (`SizeRestrictions_BODY`), which can affect large tool calls.

## Private CA certificates

**Private CA.** The Gateway validates the certificate chain against the CA you register. According to the [AgentCore documentation](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-vpc-egress.html), it doesn't check certificate revocation, and it emits the `EarliestCertificateDaysToExpiry` metric for targets with a private CA. In our tests the metric reported 364 days, the remaining life of the 365-day CA certificate we registered, not of the ALB's 180-day server certificate, so also monitor the server certificate's expiry in AWS Certificate Manager (ACM). To rotate the CA, or to stop trusting a revoked server certificate, store the new CA certificate in the secret and call `UpdateGatewayTarget` with `certificateConfigurations`. New connections use the new trust material immediately; open connections keep the old one until the Gateway recycles them, which can take up to 15 minutes.

## Alternatives we considered

- **Managed mode in subnets the AgentCore account owns.** This works if the network team gives the AgentCore account its own non-shared VPC and subnets, routed through the transit gateway. It breaks the rule that the network account owns every subnet, and it puts a network resource in an application account.
- **Managed mode in shared subnets, where participant resource gateways work.** It failed in our tests ([check 4](validation-checks.md)). Where it works, the resource gateway belongs to the AgentCore account, and the VPC Lattice documentation says the VPC owner can't view or modify it. Its traffic also leaves from the agent subnets, so the firewall needs rules from the agent range to every tool.
- **A resource gateway in each tool account's VPC.** The same participant restrictions apply to tool accounts, and a resource gateway that the network account creates in the same VPC as the backend keeps traffic inside that VPC, so it skips the firewall.
- **A resource gateway in the central endpoints VPC.** If it sits in the same VPC as the `execute-api` endpoint, the traffic to private API Gateway stays inside one VPC and isn't inspected.
- **Internet-facing ALBs with AWS WAF in front of each tool.** This was the workaround before AWS WAF supported the Gateway. It exposes internal tools on the internet and multiplies the load balancers and web ACLs to manage.

Under the constraints in *When to use this pattern* in the blog post, the network-account-owned resource gateway is the option that keeps every subnet and the network entry point with the network team, keeps both directions crossing the firewall, and needs no network change per API.

## Other considerations

- **Source NAT.** If your firewall applies source NAT, backends and the ALB and endpoint security groups see the firewall's addresses, not the resource gateway's. Allow the firewall's addresses, and use the firewall's own logs to map a flow back to a resource gateway address.
- **Multiple Regions.** Resource gateways, resource configurations, AWS RAM shares, and Gateways are Regional, and AgentCore isn't available in every Region. Repeat the network account setup in each Region, and check that Region's feature and Availability Zone lists.
- **Client IP at AWS WAF.** On the interface endpoint path, AWS WAF sees the agent's private IP address, so rate-based rules apply per agent network interface, not per end user.
- **AgentCore Runtime network interfaces.** After you delete a Runtime in VPC mode, its network interfaces [can remain for up to 8 hours](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agentcore-vpc.html), which blocks deleting those subnets until they're released. Plan clean-up and subnet changes around that window.
- **Private identity providers.** If a tool account's identity provider is reachable only privately (for example, on premises), [configure a private endpoint on the credential provider](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/identity-private-idp.html).
- **OpenAPI support.** OpenAPI targets fully support only `application/json` content and require an `operationId` on each operation you expose. `oneOf`, `anyOf`, `allOf`, and parameter serializers aren't supported. Keep tools with custom logic as MCP server targets on the same private path.
- **Inbound authorization is required.** Gateway targets with a `privateEndpoint` [can't use `NO_AUTH`](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-vpc-egress.html) as the inbound authorizer type unless an interceptor AWS Lambda function is configured on the gateway.
- **DNS TTLs.** VPC Lattice [uses IP-based routing](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/vpc-egress-private-endpoints.html), and internal ALB addresses change over time. Keep the DNS TTLs for your resource configuration domains short enough that address changes during rolling deployments don't disrupt connectivity.

## Security checklist

In addition to the controls in the blog post's design decisions:

- Grant the VPC Lattice permissions in the prerequisites only to the roles that create Gateway targets, and scope resource gateway and resource configuration creation to the network account.
- Scope the Gateway execution role to the specific credential providers and the CA secret.
- Log AgentCore, VPC Lattice, and AWS RAM API calls with AWS CloudTrail, and keep firewall flow and alert logs.
- Gateway application logs contain request and response bodies, which can include personal data. Encrypt the log group with AWS Key Management Service (AWS KMS), restrict access, and set a retention period.
- Review AWS RAM shares, service network resource associations, and Gateway targets on a regular schedule.

## What we tested

We ran the checks in us-east-1 between October 1 and November 11, 2026, with AWS Network Firewall in strict rule order (earlier runs used default action order), no source NAT, an inbound token obtained outside the agent VPC, and an internal ALB and a private REST API as backends. We didn't test third-party firewalls, source NAT, or other Regions.

---

Back to the [repository README](../README.md).
