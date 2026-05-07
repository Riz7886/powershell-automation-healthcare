from reportlab.lib.pagesizes import LETTER
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import inch
from reportlab.lib.colors import HexColor
from reportlab.lib.enums import TA_LEFT, TA_JUSTIFY
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, PageBreak, Preformatted
)
from reportlab.platypus.flowables import HRFlowable
from datetime import datetime

OUT = r"C:\Users\PC\Downloads\PYX-scripts\PYX-AFD-Migrate-v5-Runbook.pdf"

ACCENT = HexColor("#1F3D7A")
DARK   = HexColor("#11151C")
MUTED  = HexColor("#555E6D")
RULE   = HexColor("#C8CFD9")
PANEL  = HexColor("#F5F7FA")
GREEN  = HexColor("#1B6B3A")
AMBER  = HexColor("#A06A00")
RED    = HexColor("#9B2226")

styles = getSampleStyleSheet()

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

note_amber = ParagraphStyle("note_amber", parent=body,
    fontSize=10, textColor=AMBER, leading=14, leftIndent=8, spaceAfter=4,
    fontName="Helvetica-Bold")

code = ParagraphStyle("code", parent=styles["Code"],
    fontName="Courier", fontSize=9, textColor=DARK,
    leading=12, leftIndent=10, spaceBefore=4, spaceAfter=8,
    backColor=PANEL, borderColor=RULE, borderWidth=0.5,
    borderPadding=6)

doc = SimpleDocTemplate(OUT, pagesize=LETTER,
    leftMargin=0.7*inch, rightMargin=0.7*inch,
    topMargin=0.7*inch, bottomMargin=0.7*inch,
    title="PYX AFD Migrate v5 Runbook")

story = []

story.append(Paragraph("PYX Front Door Migration", title_style))
story.append(Paragraph("Classic to Standard - v5 Runbook (az CLI path)", subtitle))
story.append(HRFlowable(color=RULE, thickness=0.7, width="100%", spaceAfter=12))

story.append(Paragraph("Overview", h2))
story.append(Paragraph(
    "v5 of the PYX AFD migration script. Uses Azure CLI (az afd profile migrate / az cdn migrate) "
    "instead of PowerShell Az.Cdn cmdlets - version-stable, no module compatibility issues. "
    "Migrates all 5 PYX profiles (4 AFD Classic + 1 CDN classic) to Standard_AzureFrontDoor.",
    body))

story.append(Paragraph("Why v5 (not v2 or v3)", h3))
story.append(Paragraph(
    "v2 and v3 used PowerShell Az.Cdn module cmdlets (Start-AzFrontDoorCdnProfilePrepareMigration, "
    "Move-AzCdnProfileToAFD). The PYX work laptop's Az.Cdn module updated past 6.0.1 and the "
    "cmdlet parameter sets changed - all retries failed with 'Parameter set cannot be resolved'. "
    "v5 sidesteps this entirely by calling Azure CLI directly, the same path that worked April 24 "
    "for survey.farmboxrx.com.",
    body))

story.append(Paragraph("Profiles migrated", h3))
for line in [
    "pyxiq        (AFD Classic) -> pyxiq-std        in RG Production",
    "hipyx        (AFD Classic) -> hipyx-std-v2     in RG production",
    "pyxiq-stage  (AFD Classic) -> pyxiq-stage-std  in RG Stage",
    "pyxpwa-stage (AFD Classic) -> pyxpwa-stage-std in RG Stage",
    "standard     (CDN Classic) -> standard-afdstd  in RG Test",
]:
    story.append(Paragraph("- " + line, bullet))

story.append(PageBreak())

story.append(Paragraph("How to run", h2))

story.append(Paragraph("Prerequisite: Azure CLI installed and logged in (script will prompt if not).", body))

story.append(Paragraph("1. Plan only (no changes)", h3))
story.append(Paragraph("Reads current state of all 5 profiles, prints the action it would take, exits.", body))
story.append(Preformatted(".\\PYX-AFD-Migrate-v5.ps1 -DryRun", code))

story.append(Paragraph("2. Real migration with confirmation", h3))
story.append(Paragraph("Prompts 'Type YES' before any change. Migrates all 5 profiles.", body))
story.append(Preformatted(".\\PYX-AFD-Migrate-v5.ps1", code))

story.append(Paragraph("3. Real migration unattended", h3))
story.append(Paragraph("Skips the YES prompt. Use this when Tony has approved the maintenance window and you don't need to babysit.", body))
story.append(Preformatted(".\\PYX-AFD-Migrate-v5.ps1 -NoConfirm", code))

story.append(Paragraph("Output / artifacts", h2))
story.append(Paragraph(
    "All artifacts go to ~/Desktop/pyx-frontdoor-migration/:", body))
for line in [
    "migration-v5-<timestamp>.log - full transcript of the run",
    "results-v5-<timestamp>.json - per-profile status (migrated-and-committed, committed, already-done, prepare-failed, commit-failed, no-classic)",
]:
    story.append(Paragraph("- " + line, bullet))

story.append(PageBreak())

story.append(Paragraph("What the script does (per profile)", h2))

story.append(Paragraph("Phase 1 - Discovery", h3))
story.append(Paragraph(
    "Looks up Classic profile resource ID via 'az network front-door show' (AFD) or 'az cdn profile show' (CDN). "
    "Then checks if a Standard profile already exists, and what its migration state is.",
    body))

story.append(Paragraph("Phase 2 - Plan", h3))
story.append(Paragraph(
    "Prints the action per profile. Possible actions: MIGRATE (start fresh), COMMIT-ONLY "
    "(prepare already done, just commit), ALREADY-DONE (skip), RESUME-OR-ABORT (mid-migration "
    "but unclear state).",
    body))

story.append(Paragraph("Phase 3 - Execute (per profile)", h3))
story.append(Paragraph("For AFD Classic:", body))
story.append(Preformatted(
    "az afd profile migrate --profile-name <new> -g <RG> --classic-resource-id <id> --sku Standard_AzureFrontDoor\n"
    "az afd profile migration-commit --profile-name <new> -g <RG>",
    code))

story.append(Paragraph("For CDN Classic (the 'standard' profile):", body))
story.append(Preformatted(
    "az cdn migrate --profile-name <classic> -g <RG> --sku Standard_AzureFrontDoor --new-profile-name <new>\n"
    "az cdn profile migration-commit --profile-name <classic> -g <RG>",
    code))

story.append(Paragraph("Idempotency", h3))
story.append(Paragraph(
    "If a profile is already mid-migration (Standard exists, migrationState=Migrated), v5 skips the "
    "'migrate' step and goes straight to 'migration-commit'. If it's already on Standard SKU, v5 "
    "marks it 'already-done' and continues. Safe to re-run.",
    body))

story.append(PageBreak())

story.append(Paragraph("Post-migration: DNS handoff (Maryfin)", h2))
story.append(Paragraph(
    "After successful migration, each custom domain on the new Standard profile needs DNS cutover. "
    "v5 generates the cert/CNAME info you need to send to Maryfin. The pattern:",
    body))
for line in [
    "Publish TXT record _dnsauth.<host> with the validation token from Azure",
    "Wait for cert validationState = Approved in Azure portal (5-30 min)",
    "Publish CNAME <host> -> <new>.azurefd.net",
    "TTL 300 seconds for fast rollback if needed",
]:
    story.append(Paragraph("- " + line, bullet))

story.append(Paragraph("Rollback strategy", h2))
story.append(Paragraph(
    "If something goes wrong AFTER migration-commit, the Classic profile is GONE. Recovery is via:",
    body))
for line in [
    "DNS revert: change CNAME back to old AFD endpoint (Classic still serves for ~15 days post-commit until Azure tears it down)",
    "If pre-commit (only Prepare done): az afd profile migration-stop deletes the new Standard profile and leaves Classic intact",
]:
    story.append(Paragraph("- " + line, bullet))

story.append(Paragraph("Pre-flight checklist", h2))
for line in [
    "Change ticket approved (Tony - May 6)",
    "Maintenance window active (10pm CST)",
    "Maryfin (DNS owner) on standby",
    "az CLI logged in: az account show returns SRizvi@pyxhealth.com",
    "Subscription set: e42e94b5-c6f8-4af0-a41b-16fda520de6e (sub-corp-prod-001)",
]:
    story.append(Paragraph("- " + line, bullet))

story.append(Paragraph("Generated " + datetime.now().strftime("%Y-%m-%d %H:%M:%S"), subtitle))

doc.build(story)
print("OK:", OUT)
