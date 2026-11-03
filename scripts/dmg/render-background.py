#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Render the DMG window background from background.svg (1x and 2x).

    pip install cairosvg
    python3 scripts/dmg/render-background.py
"""
from pathlib import Path

import cairosvg

HERE = Path(__file__).resolve().parent
for scale, name in ((1, "background.png"), (2, "background@2x.png")):
    cairosvg.svg2png(url=str(HERE / "background.svg"), write_to=str(HERE / name),
                     output_width=660 * scale, output_height=400 * scale)
