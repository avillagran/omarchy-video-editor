#!/usr/bin/env python3
"""Generate the Omareel app icon (256x256 PNG) with Pillow."""
from PIL import Image, ImageDraw

S = 256
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# Rounded-square background (TokyoNight-ish deep blue)
bg = (26, 27, 38, 255)
radius = 56
d.rounded_rectangle([4, 4, S - 4, S - 4], radius=radius, fill=bg)

# Vertical 9:16 clip frame (the "reel")
fw, fh = 90, 150
fx, fy = (S - fw) // 2, (S - fh) // 2 - 6
frame_col = (122, 162, 247, 255)  # blue
d.rounded_rectangle([fx, fy, fx + fw, fy + fh], radius=18, outline=frame_col, width=9)

# Reel sprocket holes along the left edge of the frame
hole = (192, 202, 245, 255)
for i in range(4):
    hy = fy + 22 + i * 34
    d.ellipse([fx - 26, hy, fx - 12, hy + 14], fill=hole)

# Play triangle centered in the frame
accent = (158, 206, 106, 255)  # green
cx, cy = fx + fw // 2 + 6, fy + fh // 2
r = 26
d.polygon([(cx - r * 0.6, cy - r), (cx - r * 0.6, cy + r), (cx + r, cy)], fill=accent)

img.save("assets/omareel.png")
print("wrote assets/omareel.png")
