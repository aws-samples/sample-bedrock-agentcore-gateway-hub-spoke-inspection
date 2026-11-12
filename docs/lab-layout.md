# Lab layout: addresses, routes, and Availability Zones

The lab templates in `lab-code/` use this address plan. The firewall rule variables (`RGW_NET`, `TOOL_NET`, `ALB_NET`) and the blog snippets use the same ranges.

## Address plan and route tables

*Address plan used in the lab and in the snippets.*

| Range | VPC or subnet | Owner of the VPC | Used by |
|----|----|----|----|
| 10.0.0.0/16 | Resource gateway VPC, not shared; holds no backend | Network | Resource gateway and transit gateway attachment only |
| 10.0.1.0/24, 10.0.2.0/24, 10.0.3.0/24 | Resource gateway subnets (`use1-az1`, `az2`, `az4`), not shared | Network | Resource gateway network interfaces (`RGW_NET` in the firewall rules) |
| 10.0.250.0/28, 10.0.250.16/28, 10.0.250.32/28 | Transit gateway attachment subnets in the resource gateway VPC | Network | Transit gateway |
| 10.1.0.0/16 | Inspection VPC | Network | Firewall endpoint, NAT gateway |
| 10.11.0.0/16 | Shared agent VPC | Network (shared to AgentCore account) | Agents, Gateway interface endpoint |
| 10.12.0.0/16 | Shared tool VPC (`TOOL_NET`); ALB subnets 10.12.1.0/24 and 10.12.2.0/24 (`ALB_NET`) | Network (shared to tool account) | Internal ALB, `execute-api` endpoint |

*Route tables. Spoke attachments associate with one transit gateway route table that sends everything to inspection; the inspection attachment associates with a second table that holds the propagated spoke routes. Appliance mode on the inspection attachment keeps both directions of a flow on the same firewall endpoint.*

| Route table | Destination | Target |
|----|----|----|
| Resource gateway subnets | 10.0.0.0/8 | Transit gateway |
| Shared agent VPC | 10.0.0.0/8 | Transit gateway (no internet route in the lab; see the inbound token note in Decision 6 of the blog post) |
| Shared tool VPC | 10.0.0.0/8 and 0.0.0.0/0 | Transit gateway |
| Transit gateway route table for spoke attachments (resource gateway VPC, agent VPC, tool VPC) | 0.0.0.0/0 | Inspection VPC attachment |
| Transit gateway route table for the inspection attachment | Propagated spoke ranges | Spoke attachments |
| Inspection VPC, transit gateway subnet | 0.0.0.0/0 | Firewall endpoint (the firewall's interface in the inspection VPC) |
| Inspection VPC, firewall subnet | 10.0.0.0/8 | Transit gateway |
| Inspection VPC, firewall subnet | 0.0.0.0/0 | NAT gateway |
| Inspection VPC, NAT subnet | 0.0.0.0/0 | Internet gateway |
| Inspection VPC, NAT subnet | 10.0.0.0/8 | Firewall endpoint |

## Availability Zones

We placed the resource gateway in the Availability Zone IDs `use1-az1`, `use1-az2`, and `use1-az4`. AgentCore Runtime, AgentCore Gateway managed mode, and VPC Lattice each publish their own zone list:

- AgentCore Runtime and built-in tools in VPC mode [support](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agentcore-vpc.html) `use1-az1`, `use1-az2`, and `use1-az4` in us-east-1. Agent subnets must be in these zones.
- AgentCore Gateway managed mode [supports](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/vpc-egress-private-endpoints.html) `use1-az1`, `use1-az2`, `use1-az4`, `use1-az5`, and `use1-az6`. This list doesn't apply to the self-managed resource gateway in this pattern.
- VPC Lattice [doesn't support](https://docs.aws.amazon.com/vpc-lattice/latest/ug/quotas.html) the zone IDs `use1-az3`, `usw1-az2`, `apne1-az3`, `euw1-az4`, `cac1-az3`, and `ilc1-az2`. Don't place resource gateway subnets there.

Check a subnet's zone ID, not its name, because zone names map to different IDs in each account.

## Size the resource gateway subnets and choose its permanent settings

- **IP addresses.** Used only with AgentCore, a self-managed resource gateway [consumes one IP address per subnet](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/vpc-egress-private-endpoints.html). It uses more addresses, up to its IPv4-addresses-per-ENI setting, only if you also attach it to other VPC Lattice service networks. A small subnet per Availability Zone is enough.
- **Two settings can't be changed after creation.** [IPv4 addresses per ENI](https://docs.aws.amazon.com/vpc-lattice/latest/ug/resource-gateway.html) (`Ipv4AddressesPerEni`, 1–62, default 16) matters only if you attach the resource gateway to other service networks, where each address supports up to 55,000 concurrent connections per destination. Resource configuration DNS resolution (`ResourceConfigDnsResolution`) is `PUBLIC` by default, or `IN_VPC` if your resource configuration domains resolve only in a private hosted zone or a private DNS server. To change either, create a new resource gateway.
- **Connections.** AgentCore documents a 350-second port cooldown after a connection ends before the port can be reused, and VPC Lattice closes idle connections to resources after 350 seconds. See [quotas](quotas.md).

---

Back to the [repository README](../README.md). Companion to the blog post *Connect Amazon Bedrock AgentCore Gateway to private APIs in a hub-and-spoke network with centralized inspection*.
