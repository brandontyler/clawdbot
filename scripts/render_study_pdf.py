#!/usr/bin/env python3
"""Render a sermon-study cover sheet (plain sectioned text) into a quality PDF.

Used by the Sunday sermon-notes print pipeline so the study prints as a clean,
typeset PDF attachment instead of a monospace email body. Reads the study's
own structure (title line, ALL-CAPS / numbered section headers, hyphen bullets,
GROUNDED ON footer) and lays it out with print CSS via WeasyPrint.

Usage: render_study_pdf.py <study.txt> <out.pdf> [title]
Exit 0 on success (PDF written), non-zero on failure so the caller can fall back.
"""
import html
import re
import sys


CSS = """
@page { size: Letter; margin: 0.7in 0.72in;
        @bottom-center { content: counter(page); font-size: 8pt; color: #999; } }
* { box-sizing: border-box; }
body { font-family: Georgia, "DejaVu Serif", "Liberation Serif", serif;
       font-size: 10.6pt; line-height: 1.42; color: #1b1b1b; }
h1 { font-size: 17pt; text-align: center; margin: 0 0 2px 0; line-height: 1.2;
     border-bottom: 2px solid #2a2a2a; padding-bottom: 8px; }
h2 { font-size: 11pt; font-weight: bold; text-transform: uppercase; letter-spacing: 0.6px;
     color: #333; margin: 13px 0 3px 0; padding-bottom: 2px; border-bottom: 0.6px solid #cfcfcf;
     page-break-after: avoid; }
p  { margin: 3px 0; }
ul { margin: 3px 0 5px 0; padding-left: 17px; }
li { margin: 1.5px 0; }
.glance { background: #f5f4f1; border-left: 3px solid #8a6d3b; padding: 7px 11px;
          margin: 8px 0; page-break-inside: avoid; }
.glance h2 { border-bottom: none; margin-top: 0; }
.footer { margin-top: 14px; padding-top: 6px; border-top: 0.6px solid #cfcfcf;
          font-size: 8pt; font-style: italic; color: #777; }
"""

# Known caps headers that aren't numbered.
_CAPS_HEADERS = {"AT A GLANCE"}


def _is_header(line):
    s = line.strip()
    if not s:
        return False
    if s.startswith("-"):        # a hyphen bullet is never a section header
        return False
    if s in _CAPS_HEADERS:
        return True
    if re.match(r"^\d{1,2}\.\s+[A-Z]", s):        # "4. WORD WORK"
        return True
    # fully-uppercase line with a few letters (allow digits/punct/space)
    letters = [c for c in s if c.isalpha()]
    return len(letters) >= 3 and s == s.upper()


def build_html(text, title_override=""):
    lines = text.replace("\r\n", "\n").split("\n")
    # drop leading blanks
    while lines and not lines[0].strip():
        lines.pop(0)
    title = title_override.strip() or (lines[0].strip() if lines else "Sermon Study")
    if lines and lines[0].strip() == title:
        lines = lines[1:]
    elif lines and not title_override:
        lines = lines[1:]

    parts = [f"<h1>{html.escape(title)}</h1>"]
    bullets = []
    in_glance = False

    def flush_bullets():
        nonlocal bullets
        if bullets:
            parts.append("<ul>" + "".join(f"<li>{html.escape(b)}</li>" for b in bullets) + "</ul>")
            bullets = []

    def close_glance():
        nonlocal in_glance
        if in_glance:
            flush_bullets()
            parts.append("</div>")
            in_glance = False

    for raw in lines:
        line = raw.rstrip()
        s = line.strip()
        if not s:
            flush_bullets()
            continue
        if s.startswith("GROUNDED ON"):
            flush_bullets(); close_glance()
            parts.append(f'<p class="footer">{html.escape(s)}</p>')
            continue
        if _is_header(s):
            flush_bullets()
            if s == "AT A GLANCE":
                close_glance()
                parts.append('<div class="glance">')
                in_glance = True
                parts.append(f"<h2>{html.escape(s)}</h2>")
            else:
                close_glance()
                parts.append(f"<h2>{html.escape(s)}</h2>")
            continue
        if s.startswith("-"):
            bullets.append(s.lstrip("- ").rstrip())
            continue
        flush_bullets()
        parts.append(f"<p>{html.escape(s)}</p>")

    flush_bullets(); close_glance()
    return f"<html><head><meta charset='utf-8'><style>{CSS}</style></head><body>{''.join(parts)}</body></html>"


def main():
    if len(sys.argv) < 3:
        print("usage: render_study_pdf.py <study.txt> <out.pdf> [title]", file=sys.stderr)
        return 2
    src, out = sys.argv[1], sys.argv[2]
    title = sys.argv[3] if len(sys.argv) > 3 else ""
    with open(src, "r", encoding="utf-8") as f:
        text = f.read()
    if not text.strip():
        print("empty study text", file=sys.stderr)
        return 3
    from weasyprint import HTML
    HTML(string=build_html(text, title)).write_pdf(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
