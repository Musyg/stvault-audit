from playwright.sync_api import sync_playwright
from pypdf import PdfReader, PdfWriter
import os

BASE = "/home/claude/stvault-audit/report"
OUT = "/mnt/user-data/outputs/StVault_Security_Review.pdf"

header_tpl = (
    '<div style="font-family:Arial;font-size:8px;color:#9aa6b2;width:100%;'
    'padding:6px 15mm 0 15mm;text-align:right;">StVault - Security Review</div>'
)
footer_tpl = (
    '<div style="font-family:Arial;font-size:8px;color:#9aa6b2;width:100%;'
    'padding:0 15mm 6px 15mm;">'
    '<table style="width:100%;border:0;border-collapse:collapse;"><tr>'
    '<td style="text-align:left;border:0;">Gilles Musy &middot; Demonstration Review</td>'
    '<td style="text-align:center;border:0;"><span class="pageNumber"></span> / <span class="totalPages"></span></td>'
    '<td style="text-align:right;border:0;">commit 6e0fc09</td>'
    '</tr></table></div>'
)

with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page()

    page.goto(f"file://{BASE}/cover.html", wait_until="networkidle")
    page.pdf(path=f"{BASE}/cover.pdf", format="A4", print_background=True,
             margin={"top": "0", "right": "0", "bottom": "0", "left": "0"})

    page.goto(f"file://{BASE}/body.html", wait_until="networkidle")
    page.pdf(path=f"{BASE}/body.pdf", format="A4", print_background=True,
             display_header_footer=True, header_template=header_tpl, footer_template=footer_tpl,
             margin={"top": "18mm", "right": "15mm", "bottom": "15mm", "left": "15mm"})

    browser.close()

os.makedirs("/mnt/user-data/outputs", exist_ok=True)
writer = PdfWriter()
for f in [f"{BASE}/cover.pdf", f"{BASE}/body.pdf"]:
    for pg in PdfReader(f).pages:
        writer.add_page(pg)
with open(OUT, "wb") as fh:
    writer.write(fh)

print("WROTE", OUT)
print("pages:", len(PdfReader(OUT).pages))
