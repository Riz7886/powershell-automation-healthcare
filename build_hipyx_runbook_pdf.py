from reportlab.lib.pagesizes import LETTER
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import inch
from reportlab.lib.colors import HexColor
from reportlab.lib.enums import TA_LEFT, TA_JUSTIFY
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, PageBreak, Table, TableStyle, Preformatted
)
from reportlab.platypus.flowables import HRFlowable
from datetime import datetime

OUT = r"C:\Users\PC\Downloads\PYX-scripts\hipyx-fx-migration-runbook.pdf"

ACCENT = HexColor("#1F3D7A")
DARK   = HexColor("#11151C")
MUTED  = HexColor("#555E6D")
RULE   = HexColor("#C8CFD9")
PANEL  = HexColor("#F5F7FA")
GREEN  = HexColor("#1B6B3A")
AMBER  = HexColor("#A06A00")
RED    = HexColor("#9B2226")

styles = getSampleStyleSheet()

cover_label = ParagraphStyle("cover_label", parent=styles["Normal"],
    fontName="Helvetica-Bold", fontSize=9, textColor=MUTED,
    leading=12, spaceAfter=10, alignment=TA_LEFT)

title_style = ParagraphStyle("title", parent=styles["Title"],
    fontName="Helvetica-Bold", fontSize=22, textColor=DARK,
    leading=27, spaceAfter=10, alignment=TA_LEFT)

subtitle = ParagraphStyle("subtitle", parent=styles["Normal"],
    fontName="Helvetica", fontSize=11, textColor=MUTED,
    leading=16, spaceAfter=14, alignment=TA_JUSTIFY)

h2 = ParagraphStyle("h2", parent=styles["Heading2"],
    fontName="Helvetica-Bold", fontSize=14, textColor=ACCENT,
    leading=18, spaceBefore=16, spaceAfter=6)

h3 = ParagraphStyle("h3", parent=styles["Heading3"],
    fontName="Helvetica-Bold", fontSize=11, textColor=DARK,
    leading=14, spaceBefore=10, spaceAfter=4)

body = ParagraphStyle("body", parent=styles["Normal"],
    fontName="Helvetica", fontSize=10, textColor=DARK,
    leading=14, spaceAfter=6, alignment=TA_JUSTIFY)

bullet = ParagraphStyle("bullet", parent=body,
    leftIndent=14, bulletIndent=2, spaceAfter=2)

note = ParagraphStyle("note", parent=body,
    fontSize=9, textColor=MUTED, leading=12, leftIndent=8, spaceAfter=4)

code = ParagraphStyle("code", parent=styles["Code"],
    fontName="Courier", fontSize=8.5, textColor=DARK,
    leading=11, leftIndent=10, spaceBefore=4, spaceAfter=8,
    backColor=PANEL, borderColor=RULE, borderWidth=0.5,
    borderPadding=6)

footer = ParagraphStyle("footer", parent=body,
    fontSize=8, textColor=MUTED, leading=10, alignment=TA_LEFT)


def add_footer(canvas, doc):
    canvas.saveState()
    canvas.setFont("Helvetica", 8)
    canvas.setFillColor(MUTED)
    canvas.drawString(0.75 * inch, 0.5 * inch, "Syed Rizvi  -  PYX Health Production")
    canvas.drawRightString(LETTER[0] - 0.75 * inch, 0.5 * inch, "Page %d" % canvas.getPageNumber())
    canvas.setStrokeColor(RULE)
    canvas.setLineWidth(0.5)
    canvas.line(0.75 * inch, 0.7 * inch, LETTER[0] - 0.75 * inch, 0.7 * inch)
    canvas.restoreState()


story = []

story.append(Paragraph("RUNBOOK", cover_label))
story.append(Paragraph("hipyx Front Door - Classic to Standard Migration", title_style))
story.append(Paragraph(
    "Operational runbook for migrating the remaining custom domain on the Classic Front Door "
    "profile (<b>hipyx</b>) to the Standard profile (<b>hipyx-std</b>). Includes pre-flight checks, "
    "run command, the JSON parsing fix that was applied during this session, troubleshooting paths, "
    "DNS handoff procedure, validation, and rollback.",
    subtitle))
story.append(HRFlowable(width="100%", thickness=1, color=RULE, spaceBefore=4, spaceAfter=14))

# Quick facts
quick_data = [
    ["Subscription",      "sub-corp-prod-001  (e42e94b5-c6f8-4af0-a41b-16fda520de6e)"],
    ["Resource group",    "production"],
    ["Classic profile",   "hipyx  (Microsoft.Network/frontDoors)"],
    ["Standard profile",  "hipyx-std  (Microsoft.Cdn/profiles)"],
    ["WAF policy",        "hipyxWafPolicy  (Standard_AzureFrontDoor, Detection mode)"],
    ["Domain to migrate", "www.hipyx.com  (managed cert, SNI)"],
    ["Already on Standard", "survey.farmboxrx.com  (migrated previously)"],
    ["Script",            "hipyx-migrate-all.ps1"],
    ["Run as",            "Administrator in Windows PowerShell ISE 5.1"],
]
quick_tbl = Table(quick_data, colWidths=[1.6 * inch, 4.6 * inch])
quick_tbl.setStyle(TableStyle([
    ("FONTNAME", (0, 0), (0, -1), "Helvetica-Bold"),
    ("FONTNAME", (1, 0), (1, -1), "Helvetica"),
    ("FONTSIZE", (0, 0), (-1, -1), 9.5),
    ("TEXTCOLOR", (0, 0), (0, -1), ACCENT),
    ("TEXTCOLOR", (1, 0), (1, -1), DARK),
    ("VALIGN", (0, 0), (-1, -1), "TOP"),
    ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
    ("TOPPADDING", (0, 0), (-1, -1), 5),
    ("LINEBELOW", (0, 0), (-1, -2), 0.5, RULE),
    ("BACKGROUND", (0, 0), (0, -1), PANEL),
]))
story.append(quick_tbl)
story.append(Spacer(1, 14))

# 1. Overview
story.append(Paragraph("1.  Overview", h2))
story.append(Paragraph(
    "Azure Front Door Classic is end-of-life. The Standard profile <b>hipyx-std</b> already exists "
    "and serves <b>survey.farmboxrx.com</b> (migrated in a prior session via "
    "<font face='Courier'>az afd profile migrate</font> + <font face='Courier'>migration-commit</font>). "
    "<b>www.hipyx.com</b> is still pinned to Classic <b>hipyx</b> with HTTPS (managed cert, SNI). "
    "Goal: move <b>www.hipyx.com</b> off Classic and onto <b>hipyx-std</b> alongside survey.",
    body))
story.append(Paragraph(
    "Because <b>hipyx-std</b> already exists as a separate Standard profile, "
    "<font face='Courier'>az afd profile migrate</font> cannot be reused (it creates a NEW Standard "
    "profile from Classic, will not merge into existing). The script therefore performs a manual "
    "cutover: detach the hostname from Classic to release Azure's hostname lock, then create the "
    "Standard endpoint, custom-domain, origin group, route, and WAF binding. Brief outage window "
    "during the release-and-recreate (typically 60-120 seconds plus DNS propagation).",
    body))

# 2. Prerequisites
story.append(Paragraph("2.  Prerequisites", h2))
prereq_items = [
    "Azure CLI installed (script auto-checks).",
    "Signed in to Azure as a user with Owner / Contributor on the <b>production</b> resource group "
    "(script auto-runs <font face='Courier'>az login</font> if not signed in).",
    "<font face='Courier'>front-door</font> CLI extension installed (script auto-installs / auto-updates).",
    "DNS owner (Skye) on standby to publish records once the script finishes.",
    "Outage window approved (~5-10 minute window covers the worst case).",
]
for item in prereq_items:
    story.append(Paragraph("&bull;  " + item, bullet))

# 3. Run
story.append(Paragraph("3.  Run", h2))
story.append(Paragraph("Standard run (auto-detects backend host from Classic):", body))
story.append(Preformatted(".\\hipyx-migrate-all.ps1", code))

story.append(Paragraph("If auto-detection fails (you will see "
    "<font face='Courier'>[ERR] Could not detect Classic backend ...</font>), pass the origin host explicitly:", body))
story.append(Preformatted(".\\hipyx-migrate-all.ps1 -DefaultOriginHost <fqdn-of-real-backend>", code))

story.append(Paragraph("Optional dry-run (inventory + plan only, no changes):", body))
story.append(Preformatted(".\\hipyx-migrate-all.ps1 -DryRun", code))

# 4. What the script does, phase-by-phase
story.append(Paragraph("4.  What the script does", h2))
phase_items = [
    ("Phase 0",  "Pre-flight: az CLI present, signed in, subscription set, front-door extension ready."),
    ("Phase 1",  "Inventory the Classic profile's frontend-endpoints. Filters out the default azurefd.net endpoint."),
    ("Phase 2",  "Inventory the Standard profile's existing custom-domains so duplicates are skipped."),
    ("Phase 3",  "Build a migration plan and save plan-&lt;timestamp&gt;.json."),
    ("Phase 4",  "Verify Standard profile and WAF policy exist (creates WAF in Detection mode if missing)."),
    ("Phase 5",  "Per-domain: detect Classic backend host, detach the hostname from Classic routing rules, "
                 "delete the Classic frontend-endpoint to release the hostname, wait, create endpoint on "
                 "Standard, create custom-domain on Standard with managed cert, create / reuse origin group, "
                 "create route, bind WAF security policy."),
    ("Phase 6",  "Generate DNS handoff package: dns-handoff-&lt;timestamp&gt;.txt, .csv, and .html."),
    ("Phase 7",  "Generate full HTML summary report."),
    ("Phase 8",  "Final summary on the console: counts and artifact paths."),
]
phase_tbl = Table(phase_items, colWidths=[0.7 * inch, 5.5 * inch])
phase_tbl.setStyle(TableStyle([
    ("FONTNAME", (0, 0), (0, -1), "Helvetica-Bold"),
    ("FONTNAME", (1, 0), (1, -1), "Helvetica"),
    ("FONTSIZE", (0, 0), (-1, -1), 9),
    ("TEXTCOLOR", (0, 0), (0, -1), ACCENT),
    ("TEXTCOLOR", (1, 0), (1, -1), DARK),
    ("VALIGN", (0, 0), (-1, -1), "TOP"),
    ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ("TOPPADDING", (0, 0), (-1, -1), 4),
    ("LINEBELOW", (0, 0), (-1, -2), 0.5, RULE),
]))
story.append(phase_tbl)

# 5. Bug fix that was applied this session
story.append(PageBreak())
story.append(Paragraph("5.  Bug fix applied this session  (PSv5.1 JSON wrapper)", h2))
story.append(Paragraph(
    "On the first run of the script today, Phase 1 reported <i>1 frontend endpoint</i> and Phase 3's "
    "plan row showed both hostnames jammed into a single object: "
    "<font face='Courier'>{hipyx.azurefd.net, www.hipyx.com}</font>. Phase 5 then failed with "
    "<font face='Courier'>Could not detect Classic backend</font> and the DNS handoff came out empty.",
    body))
story.append(Paragraph(
    "<b>Root cause:</b> Windows PowerShell 5.1 + the older <font face='Courier'>front-door</font> "
    "CLI extension can return JSON output that <font face='Courier'>ConvertFrom-Json</font> "
    "interprets as one wrapper object whose properties are equal-length arrays "
    "(name=[a,b], hostName=[a,b], etc.) instead of two separate objects. The pipeline-vs-string-array "
    "behavior of native command capture compounds this.",
    body))
story.append(Paragraph(
    "<b>Fix:</b> two helper functions added near the top of the script:",
    body))
story.append(Paragraph(
    "&bull;  <b>_AzList</b> &mdash; runs an <font face='Courier'>az ... -o json</font> command, "
    "coerces output to a single string with <font face='Courier'>Out-String</font>, parses, and "
    "auto-detects the wrapper-object pattern. If detected, it explodes the wrapper back into "
    "N separate objects.", bullet))
story.append(Paragraph(
    "&bull;  <b>_AzShow</b> &mdash; same coercion, returns one object (or <font face='Courier'>$null</font>) "
    "for show-style commands.", bullet))
story.append(Paragraph(
    "All Phase 1 / 2 / 5 JSON-parse call sites now go through these helpers.",
    body))

# 6. Common errors + fixes
story.append(Paragraph("6.  Common errors + fixes", h2))

story.append(Paragraph("ERR &mdash; Could not detect Classic backend ...", h3))
story.append(Paragraph(
    "Cause: Classic routing rule for the domain is a redirect (no backend pool), or the rule was "
    "removed by a previous partial run. "
    "Fix: pass <font face='Courier'>-DefaultOriginHost</font> with the real backend FQDN. "
    "To find the backend manually:", body))
story.append(Preformatted(
    "az network front-door routing-rule list -g production --front-door-name hipyx \\\n"
    "  --query \"[?contains(to_string(frontendEndpoints), 'www-hipyx-com')].routeConfiguration.backendPool.id\" \\\n"
    "  -o tsv\n\n"
    "az network front-door backend-pool show -g production --front-door-name hipyx --name <bp-name> \\\n"
    "  --query \"backends[].address\" -o tsv",
    code))

story.append(Paragraph("ERR &mdash; (Conflict) Another custom domain with the same host name already exists", h3))
story.append(Paragraph(
    "Cause: Classic still owns the hostname. The script normally handles this by detaching from "
    "Classic first, but if the detach failed silently you may need to clean up by hand:", body))
story.append(Preformatted(
    "az network front-door frontend-endpoint delete -g production --front-door-name hipyx --name www-hipyx-com\n"
    "Start-Sleep -Seconds 60\n"
    ".\\hipyx-migrate-all.ps1",
    code))

story.append(Paragraph("WARN &mdash; Could not read validation token", h3))
story.append(Paragraph(
    "Cause: the <font face='Courier'>validationProperties</font> field hasn't populated yet. "
    "Wait 1-2 minutes and re-query:", body))
story.append(Preformatted(
    "az afd custom-domain show -g production --profile-name hipyx-std \\\n"
    "  --custom-domain-name www-hipyx-com \\\n"
    "  --query validationProperties.validationToken -o tsv",
    code))

# 7. DNS handoff
story.append(Paragraph("7.  DNS handoff", h2))
story.append(Paragraph(
    "After the script finishes, three artifacts contain the records DNS needs to publish:", body))
story.append(Paragraph(
    "&bull;  <b>dns-handoff-&lt;timestamp&gt;.txt</b> &mdash; engineer-friendly plain text.", bullet))
story.append(Paragraph(
    "&bull;  <b>dns-handoff-&lt;timestamp&gt;.csv</b> &mdash; machine-readable.", bullet))
story.append(Paragraph(
    "&bull;  <b>dns-handoff-&lt;timestamp&gt;.html</b> &mdash; clean styled HTML, no admin clutter, "
    "this is the file to email to the DNS owner. Open in browser, Ctrl+P, Save as PDF if PDF is preferred.", bullet))
story.append(Paragraph(
    "<b>Order of operations</b> for the DNS owner (this is on the HTML page too):", body))
story.append(Paragraph(
    "1.  Publish the TXT record(s) first &mdash; this validates the AFD managed cert.", bullet))
story.append(Paragraph(
    "2.  Wait for <font face='Courier'>domainValidationState</font> to flip to "
    "<font face='Courier'>Approved</font> (5-30 minutes).", bullet))
story.append(Paragraph(
    "3.  Publish the CNAME record(s) &mdash; this cuts traffic over to Standard.", bullet))
story.append(Paragraph(
    "4.  TTL is 300 seconds, so any rollback is fast.", bullet))

# 8. Validation
story.append(Paragraph("8.  Validation", h2))
story.append(Paragraph("Before publishing CNAME, confirm the cert is approved:", body))
story.append(Preformatted(
    "az afd custom-domain show -g production --profile-name hipyx-std \\\n"
    "  --custom-domain-name www-hipyx-com \\\n"
    "  --query domainValidationState -o tsv",
    code))
story.append(Paragraph("After CNAME is live, confirm traffic is hitting Standard:", body))
story.append(Preformatted(
    "nslookup www.hipyx.com\n"
    "curl -I https://www.hipyx.com/",
    code))
story.append(Paragraph(
    "The <font face='Courier'>Server</font> header is no longer present on AFD Standard, but the "
    "<font face='Courier'>x-azure-ref</font> header should be there. CNAME chain should resolve "
    "through <font face='Courier'>*.z01.azurefd.net</font> (Standard) instead of "
    "<font face='Courier'>hipyx.azurefd.net</font> (Classic).",
    body))

# 9. Rollback
story.append(Paragraph("9.  Rollback", h2))
story.append(Paragraph(
    "DNS-only rollback (works as long as the Classic profile has not been deprovisioned):",
    body))
story.append(Paragraph(
    "1.  Repoint the public CNAME for <b>www.hipyx.com</b> back to <font face='Courier'>hipyx.azurefd.net</font>.", bullet))
story.append(Paragraph(
    "2.  Wait the TTL window (300 seconds).", bullet))
story.append(Paragraph(
    "3.  Traffic returns to Classic.", bullet))
story.append(Paragraph(
    "If the Classic frontend-endpoint was deleted (Phase 5.3 success), the rollback also requires "
    "re-creating it before the CNAME flip. The script does NOT automate the re-create; do it manually "
    "from the saved plan JSON if needed.",
    note))

# 10. Artifacts produced
story.append(Paragraph("10.  Artifacts produced per run", h2))
artifacts = [
    "run-<timestamp>.log              - timestamped log of the run",
    "plan-<timestamp>.json            - migration plan (1 entry per Classic custom domain)",
    "dns-handoff-<timestamp>.txt      - DNS records, plain text",
    "dns-handoff-<timestamp>.csv      - DNS records, CSV",
    "dns-handoff-<timestamp>.html     - DNS records, styled (email this to DNS owner)",
    "summary-<timestamp>.html         - full migration report for ops review",
]
story.append(Preformatted("\n".join(artifacts), code))

story.append(HRFlowable(width="100%", thickness=0.5, color=RULE, spaceBefore=18, spaceAfter=8))
story.append(Paragraph(
    "Prepared by Syed Rizvi  -  PYX Health Production  -  " + datetime.now().strftime("%Y-%m-%d"),
    footer))


doc = SimpleDocTemplate(
    OUT, pagesize=LETTER,
    leftMargin=0.75 * inch, rightMargin=0.75 * inch,
    topMargin=0.75 * inch, bottomMargin=0.85 * inch,
    title="hipyx Front Door - Classic to Standard Migration Runbook",
    author="Syed Rizvi",
)
doc.build(story, onFirstPage=add_footer, onLaterPages=add_footer)
print("Wrote " + OUT)
