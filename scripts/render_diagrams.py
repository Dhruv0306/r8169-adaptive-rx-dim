#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Render the Mermaid diagrams of docs/diagrams to SVG and PNG.

Every docs/diagrams/NN-*.md has one ```mermaid block. This script takes the
block, renders it in a headless Chromium with the mermaid library, checks
that it parses, and writes docs/diagrams/img/NN-*.svg and .png. A syntax
error stops the script and names the file; the SVG is serialized as XML and
checked to be well-formed, with SVG text labels and no foreignObject.

Needs the python playwright package with its Chromium, and the mermaid
package from npm in some directory:

    mkdir /tmp/mm && cd /tmp/mm && npm init -y && npm i mermaid@11
    python3 scripts/render_diagrams.py /tmp/mm/node_modules/mermaid/dist/mermaid.min.js

usage: render_diagrams.py MERMAID_JS [DIAGRAM_DIR]
"""

import glob
import json
import os
import re
import sys
from xml.dom import minidom

from playwright.sync_api import sync_playwright

PAGE = "<html><body><div id='out'></div></body></html>"


def blocks(path):
    text = open(path, encoding="utf-8").read()
    m = re.search(r"```mermaid\n(.*?)```", text, re.S)
    if not m:
        raise SystemExit(f"{path}: no mermaid block")
    return m.group(1)


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    js = sys.argv[1]
    ddir = sys.argv[2] if len(sys.argv) > 2 else "docs/diagrams"
    img = os.path.join(ddir, "img")
    os.makedirs(img, exist_ok=True)
    files = sorted(glob.glob(os.path.join(ddir, "[0-9][0-9]-*.md")))
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(device_scale_factor=2)
        page.set_content(PAGE)
        page.add_script_tag(path=js)
        # htmlLabels false at the top level makes mermaid draw labels as SVG
        # text instead of HTML in a foreignObject, which is portable and valid XML
        page.evaluate(
            "mermaid.initialize({startOnLoad:false, theme:'neutral',"
            " securityLevel:'strict', htmlLabels:false,"
            " flowchart:{htmlLabels:false, curve:'basis'}})"
        )
        for f in files:
            name = os.path.basename(f)[:-3]
            src = blocks(f)
            try:
                svg = page.evaluate(
                    "async (s) => (await mermaid.render('d' + Math.random().toString(36).slice(2), s)).svg",
                    src,
                )
            except Exception as e:
                raise SystemExit(f"{f}: mermaid error: {str(e)[:400]}")
            page.evaluate("(s) => { document.getElementById('out').innerHTML = s; }", svg)
            # serialize the parsed SVG as XML: the string from mermaid is HTML
            # (for example an unclosed <br>), which is not valid in an .svg file
            svg = page.evaluate(
                "() => new XMLSerializer().serializeToString(document.querySelector('#out svg'))"
            )
            try:
                minidom.parseString(svg.encode("utf-8"))
            except Exception as e:
                raise SystemExit(f"{f}: the SVG is not valid XML: {str(e)[:200]}")
            if "<foreignObject" in svg:
                raise SystemExit(f"{f}: the SVG still has a foreignObject (HTML labels)")
            with open(os.path.join(img, name + ".svg"), "w", encoding="utf-8") as fh:
                fh.write('<?xml version="1.0" encoding="UTF-8"?>\n' + svg + "\n")
            el = page.query_selector("#out svg")
            el.screenshot(path=os.path.join(img, name + ".png"))
            print("rendered", name)
        browser.close()


if __name__ == "__main__":
    main()
