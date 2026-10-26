#!/usr/bin/env python3
"""Builds src/partials/logo.svg, the write-on logo, from the app's
ios/CanWeGo/Views/CanWeGoLogoData.swift. Run again if that file changes."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
swift = (ROOT.parent / "ios/CanWeGo/Views/CanWeGoLogoData.swift").read_text()

def const(name):
    return float(re.search(rf"static let {name} = (-?[\d.]+)", swift).group(1))

vx, vy, vw, vh = (const(n) for n in ("viewBoxX", "viewBoxY", "viewBoxWidth", "viewBoxHeight"))
pen_width, dot = const("penWidth"), const("dotDiameter")

letters = []
for block in swift.split("CanWeGoLogoLetter(\n")[1:]:
    letters.append({
        "id": re.search(r'id: "([^"]+)"', block).group(1),
        "outline": re.search(r'outline: "([^"]+)"', block).group(1),
        "strokes": [
            re.findall(r'CanWeGoLogoSegment\(pen: "([^"]+)", length: ([\d.]+), area: (?:"([^"]+)"|nil)\)', stroke)
            for stroke in re.findall(r"\[\n((?:\s+CanWeGoLogoSegment\(.*\n)+)\s+\]", block)
        ],
        "dot": re.search(r"dotCenterX: ([\d.]+), dotCenterY: ([\d.]+)", block),
    })

defs, inks, area = [], [], 0
for li, letter in enumerate(letters):
    marks = []
    if letter["dot"]:
        cx, cy = letter["dot"].groups()
        marks.append(f'<circle class="lw-dot" cx="{cx}" cy="{cy}" r="0" data-r="{dot / 2:g}" fill="#fff" stroke="none"/>')
    for si, stroke in enumerate(letter["strokes"]):
        for pen, length, region in stroke:
            clip = ""
            if region:
                area += 1
                defs.append(f'<clipPath id="lw-a{area}"><path d="{region}"/></clipPath>')
                clip = f' clip-path="url(#lw-a{area})"'
            marks.append(f'<path class="lw-pen" d="{pen}" pathLength="1" data-len="{length}" data-stroke="{si}"{clip}/>')
    defs.append(
        f'<mask id="lw-m{li}" maskUnits="userSpaceOnUse" x="{vx:g}" y="{vy:g}" width="{vw:g}" height="{vh:g}">'
        f'<g fill="none" stroke="#fff" stroke-width="{pen_width:g}" stroke-linecap="round" stroke-linejoin="round">'
        + "".join(marks) + "</g></mask>"
    )
    inks.append(f'<path class="lw-ink" d="{letter["outline"]}" data-mask="url(#lw-m{li})"/>')

svg = (
    f'<svg class="logo" viewBox="{vx:g} {vy:g} {vw:g} {vh:g}" fill="currentColor" role="img" aria-label="Can We Go?">'
    f'<defs>{"".join(defs)}</defs>{"".join(inks)}</svg>\n'
)
out = ROOT / "src/partials/logo.svg"
out.write_text(svg)
print(f"{out.relative_to(ROOT)}: {len(letters)} letters, {len(svg) // 1024} KB")
