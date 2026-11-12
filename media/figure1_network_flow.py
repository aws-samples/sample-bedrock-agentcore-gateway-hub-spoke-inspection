"""Figure 1 for the AgentCore Gateway hub-and-spoke blog (official AWS Architecture Icons, generic names).

Usage:
    AWS_ICONS_DIR=/path/to/extracted/Asset-Package python3 figure1_network_flow.py

AWS_ICONS_DIR is the extracted AWS Architecture Icons asset package
(https://aws.amazon.com/architecture/icons/). Icons are found by file name anywhere under it, so any package
version works as long as it includes the Amazon Bedrock AgentCore icon. Needs Pillow. FIG_FONT can point to a
TrueType font; the default is Helvetica on macOS, then DejaVu Sans.

Step numbers match "The traffic path and where it's inspected" in the blog draft.
"""
import math
import os
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ICON_FILES = {
    "agentcore": "Arch_Amazon-Bedrock-AgentCore_64@5x.png",
    "waf": "Arch_AWS-WAF_64@5x.png",
    "cognito": "Arch_Amazon-Cognito_64@5x.png",
    "vpce": "Res_Amazon-VPC_Endpoints_48.png",
    "lattice": "Arch_Amazon-VPC-Lattice_64@5x.png",
    "tgw": "Arch_AWS-Transit-Gateway_64@5x.png",
    "firewall": "Res_Firewall_48_Light.png",
    "nat": "Res_Amazon-VPC_NAT-Gateway_48.png",
    "alb": "Res_Elastic-Load-Balancing_Application-Load-Balancer_48.png",
    "ecs": "Arch_Amazon-Elastic-Container-Service_64@5x.png",
    "apigw": "Arch_Amazon-API-Gateway_64@5x.png",
    "ram": "Arch_AWS-Resource-Access-Manager_64@5x.png",
    "account": "AWS-Account_32.png",
    "vpc": "Virtual-private-cloud-VPC_32.png",
}


def find_icons():
    root = os.environ.get("AWS_ICONS_DIR")
    if not root or not Path(root).is_dir():
        sys.exit("Set AWS_ICONS_DIR to the extracted AWS Architecture Icons asset package.")
    index = {}
    for p in Path(root).rglob("*.png"):
        if "__MACOSX" not in p.parts:
            index.setdefault(p.name, p)
    missing = [f for f in ICON_FILES.values() if f not in index]
    if missing:
        sys.exit(f"Icons not found under {root}: {', '.join(missing)}")
    return {k: index[v] for k, v in ICON_FILES.items()}


def find_font():
    for cand in (os.environ.get("FIG_FONT"), "/System/Library/Fonts/Helvetica.ttc",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
        if cand and Path(cand).exists():
            return cand
    sys.exit("No font found; set FIG_FONT to a .ttf or .ttc file.")


ICON = find_icons()
FONT = find_font()
S, W, H = 2, 2000, 1130
img = Image.new("RGB", (W * S, H * S), "white")
d = ImageDraw.Draw(img)


def f(size, bold=False):
    if FONT.endswith(".ttc"):
        return ImageFont.truetype(FONT, size * S, index=1 if bold else 0)
    bold_path = FONT.replace("Sans.ttf", "Sans-Bold.ttf")
    return ImageFont.truetype(bold_path if bold and Path(bold_path).exists() else FONT, size * S)


INK, GREY, PINK, VPCG, RAMC = "#232F3E", "#7D8998", "#E7157B", "#8C4FFF", "#DD344C"


def dashed_line(p, q, color, width=2, dash=10):
    (x0, y0), (x1, y1) = p, q
    n = max(int(math.hypot(x1 - x0, y1 - y0) // dash), 1)
    for i in range(0, n, 2):
        t0, t1 = i / n, min((i + 1) / n, 1)
        d.line([((x0 + (x1 - x0) * t0) * S, (y0 + (y1 - y0) * t0) * S),
                ((x0 + (x1 - x0) * t1) * S, (y0 + (y1 - y0) * t1) * S)], fill=color, width=width * S)


def box(x0, y0, x1, y1, color, title, icon=None, dashed=False, size=14):
    if dashed:
        for p, q in (((x0, y0), (x1, y0)), ((x1, y0), (x1, y1)), ((x1, y1), (x0, y1)), ((x0, y1), (x0, y0))):
            dashed_line(p, q, color, width=2, dash=8)
    else:
        d.rounded_rectangle([x0 * S, y0 * S, x1 * S, y1 * S], radius=8 * S, outline=color, width=2 * S, fill="white")
    TITLES.append((x0, y0, color, title, icon, size))


TITLES = []


def draw_titles():
    for x0, y0, color, title, icon, size in TITLES:
        tx = x0 + 10
        if icon:
            ic = Image.open(ICON[icon]).convert("RGBA").resize((26 * S, 26 * S))
            img.paste(ic, (x0 * S, y0 * S), ic)
            tx = x0 + 34
        w = d.textlength(title, font=f(size, True)) / S
        d.rectangle([(tx - 3) * S, (y0 + 4) * S, (tx + w + 3) * S, (y0 + 8 + size + 4) * S], fill="white")
        d.text((tx * S, (y0 + 6) * S), title, font=f(size, True), fill=color)


def node(key, cx, cy, label, size=64):
    ic = Image.open(ICON[key]).convert("RGBA").resize((size * S, size * S), Image.LANCZOS)
    img.paste(ic, (int((cx - size / 2) * S), int((cy - size / 2) * S)), ic)
    for i, line in enumerate(label.split("\n")):
        w = d.textlength(line, font=f(13))
        d.text((cx * S - w / 2, (cy + size / 2 + 5 + i * 17) * S), line, font=f(13), fill=INK)
    return cx, cy


def badge(n, x, y):
    r = 13
    d.ellipse([(x - r) * S, (y - r) * S, (x + r) * S, (y + r) * S], fill=INK)
    w = d.textlength(str(n), font=f(14, True))
    d.text((x * S - w / 2, (y - 9) * S), str(n), font=f(14, True), fill="white")


def text(x, y, s, color=GREY, size=12, center=True, bold=False):
    for i, line in enumerate(s.split("\n")):
        w = d.textlength(line, font=f(size, bold)) / S if center else 0
        d.text(((x - w / 2) * S, (y + i * (size + 3)) * S), line, font=f(size, bold), fill=color)


def arrow(p, q, shrink=(40, 40), color=INK, dashed=False, width=2, head=True):
    """Straight arrow from p to q, shortened by shrink at each end. Returns the drawn end points."""
    (x0, y0), (x1, y1) = p, q
    a = math.atan2(y1 - y0, x1 - x0)
    x0, y0 = x0 + shrink[0] * math.cos(a), y0 + shrink[0] * math.sin(a)
    x1, y1 = x1 - shrink[1] * math.cos(a), y1 - shrink[1] * math.sin(a)
    if dashed:
        dashed_line((x0, y0), (x1, y1), color, width)
    else:
        d.line([(x0 * S, y0 * S), (x1 * S, y1 * S)], fill=color, width=width * S)
    if head:
        h = 11
        pts = [(x1, y1), (x1 - h * math.cos(a - 0.4), y1 - h * math.sin(a - 0.4)),
               (x1 - h * math.cos(a + 0.4), y1 - h * math.sin(a + 0.4))]
        d.polygon([(x * S, y * S) for x, y in pts], fill=color)
    return (x0, y0), (x1, y1)


def polyline(points, color, dashed=False):
    """Arrow along several points; the head is on the last segment."""
    for p, q in zip(points[:-2], points[1:-1]):
        (dashed_line(p, q, color) if dashed else d.line([(p[0] * S, p[1] * S), (q[0] * S, q[1] * S)], fill=color, width=2 * S))
    arrow(points[-2], points[-1], shrink=(0, 0), color=color, dashed=dashed)


text(40, 12, "AgentCore Gateway to private tools: every hop between VPCs after the network-account resource gateway "
             "crosses the central firewall, in both directions", color=INK, size=17, center=False, bold=True)

# ---- Accounts --------------------------------------------------------------------------------------
box(40, 50, 1150, 340, INK, "AgentCore account", "account")
box(1230, 50, 1960, 340, INK, "Tool account", "account")
box(40, 390, 1960, 1035, INK, "Network account (central team): owns every VPC, subnet and route", "account")

# ---- VPCs (all owned by the network account) -------------------------------------------------------
box(70, 650, 480, 1005, VPCG, "Shared agent VPC (AWS RAM)", "vpc")
box(520, 650, 800, 1005, VPCG, "Resource gateway VPC (not shared)", "vpc", size=13)
box(840, 430, 1180, 620, VPCG, "Inspection VPC", "vpc")
box(1220, 650, 1930, 1005, VPCG, "Shared tool VPC (AWS RAM)", "vpc")
# Participant-owned resources inside the shared VPCs
box(88, 700, 262, 900, PINK, "AgentCore account", dashed=True, size=12)
box(1420, 700, 1912, 900, PINK, "Tool account resources", dashed=True, size=12)

# ---- Nodes -----------------------------------------------------------------------------------------
waf = node("waf", 150, 120, "AWS WAF\n(optional)", 48)
cog_in = node("cognito", 150, 250, "Amazon Cognito\n(inbound JWT)", 48)
gw = node("agentcore", 420, 175, "AgentCore Gateway\n(targets, resource policy,\noutbound credentials)", 70)
api = node("apigw", 1340, 185, "Private REST API\n(Amazon API Gateway)", 56)
cog_t = node("cognito", 1800, 185, "Tool account\nidentity provider", 56)
rt = node("agentcore", 175, 790, "AgentCore Runtime\n(agents)", 64)
vpce = node("vpce", 390, 790, "Gateway interface\nVPC endpoint", 64)
rg = node("lattice", 660, 790, "Resource gateway +\nresource configurations", 64)
ram = node("ram", 745, 505, "AWS RAM share\n(resource\nconfigurations)", 50)
fw = node("firewall", 950, 515, "Firewall (AWS Network\nFirewall or third party)", 56)
nat = node("nat", 1100, 515, "NAT gateway\n(central egress)", 50)
tgw = node("tgw", 1010, 790, "Transit Gateway\n(appliance mode on the\ninspection attachment)", 64)
eapi = node("vpce", 1340, 930, "execute-api\nendpoint", 48)
alb = node("alb", 1530, 790, "Internal ALB\n(validates JWT; SG allows\nresource gateway only)", 64)
ecs = node("ecs", 1820, 790, "MCP servers\nand REST APIs", 64)

# ---- Not inspected (grey dashed) ------------------------------------------------------------------
arrow(rt, vpce, shrink=(38, 38), color=GREY, dashed=True)
badge(1, 282, 772)
arrow(vpce, (400, 285), shrink=(40, 0), color=GREY, dashed=True)
text(300, 560, "private DNS,\nno internet route", center=True)
arrow((450, 285), rg, shrink=(0, 40), color=GREY, dashed=True)
badge(3, 533, 470)
text(480, 555, "AWS-managed\nVPC Lattice\npath", center=True)

# ---- Control: authorization and credentials (grey, thin) -------------------------------------------
arrow(waf, gw, shrink=(34, 42), color=GREY, dashed=True)
arrow(cog_in, gw, shrink=(34, 42), color=GREY, dashed=True)
badge(2, 420, 100)
polyline([(460, 160), (1190, 160), (1190, 110), (1800, 110), (1800, 152)], GREY, dashed=True)
text(820, 138, "outbound OAuth token for the tool account (AgentCore Identity)", center=True)
# RAM share to the AgentCore account
arrow(ram, (760, 340), shrink=(32, 4), color=RAMC, dashed=True)
text(775, 360, "shared with the\nAgentCore account", color=RAMC, center=False)
arrow((735, 590), (670, 750), shrink=(0, 0), color=RAMC, dashed=True, head=False)

# ---- Inspected (solid) -----------------------------------------------------------------------------
arrow(rg, tgw, shrink=(40, 40))
badge(4, 835, 772)
arrow((990, 745), (950, 585), shrink=(0, 0))
arrow((965, 585), (1005, 745), shrink=(0, 0))
text(905, 650, "to firewall", center=True)
text(1060, 650, "back after\ninspection", center=True)
arrow(tgw, alb, shrink=(40, 40))
text(1170, 770, "443 to tool ALB", center=True)
arrow((1045, 815), eapi, shrink=(0, 30))
text(1150, 915, "443 to execute-api", center=True)
# Inside the tool VPC / AWS-managed: these legs don't cross the firewall
arrow((1340, 902), (1340, 262), shrink=(0, 0), color=GREY, dashed=True)
text(1395, 600, "inside AWS\n(no firewall)", center=True)
arrow(alb, ecs, shrink=(40, 40), color=GREY, dashed=True)
badge(5, 1675, 772)
text(1675, 850, "inside the\ntool VPC", center=True)
# Central egress for the ALB's signing-key (JWKS) fetch
arrow(fw, nat, shrink=(30, 28))
polyline([(1100, 487), (1100, 420), (1880, 420), (1880, 262)], INK)
text(1600, 426, "ALB signing-key (JWKS) fetch: tool VPC, Transit Gateway,\nfirewall, NAT gateway, identity provider", center=True)

# ---- Legend and footer -----------------------------------------------------------------------------
badge(6, 60, 1062)
text(80, 1053, "Responses return the same way: backend, ALB or execute-api endpoint, Transit Gateway, firewall, Transit Gateway, "
               "resource gateway, Gateway, agent.", color=INK, size=14, center=False)
y = 1095
d.line([(60 * S, y * S), (110 * S, y * S)], fill=INK, width=2 * S)
text(120, y - 8, "Inspected by the central firewall", color=INK, size=13, center=False)
dashed_line((420, y), (470, y), GREY)
text(480, y - 8, "Doesn't cross the firewall: inside one VPC, or AWS managed; also authorization and credentials",
     color=INK, size=13, center=False)
dashed_line((1170, y), (1220, y), RAMC)
text(1230, y - 8, "AWS RAM sharing", color=INK, size=13, center=False)
dashed_line((1400, y), (1440, y), PINK)
text(1450, y - 8, "Resources a participant account owns in a shared VPC", color=INK, size=13, center=False)

draw_titles()
out = Path(__file__).parent / "figure-1-architecture.png"
img.save(out, dpi=(144, 144))
print(out)
