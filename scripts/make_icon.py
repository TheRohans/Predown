# Draws Predown's app icon. Needs Pillow (pip install pillow).
#   python3 scripts/make_icon.py icon.png                                  # one 1024px PNG
#   python3 scripts/make_icon.py App/Assets.xcassets/AppIcon.appiconset    # every size + Contents.json
import sys, math
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 4                    # supersampling factor
N = 1024 * S
def s(v): return v * S

def squircle(x0, y0, x1, y1, n=5.0, steps=720):
    cx, cy, rx, ry = (x0+x1)/2, (y0+y1)/2, (x1-x0)/2, (y1-y0)/2
    pts = []
    for i in range(steps):
        t = 2*math.pi*i/steps
        c, si = math.cos(t), math.sin(t)
        pts.append((cx + rx*math.copysign(abs(c)**(2/n), c), cy + ry*math.copysign(abs(si)**(2/n), si)))
    return pts

def vgradient(size, top, bottom):
    w, h = size
    g = Image.new('RGBA', (1, h))
    for y in range(h):
        t = y/(h-1)
        g.putpixel((0, y), tuple(int(top[i] + (bottom[i]-top[i])*t) for i in range(4)))
    return g.resize((w, h))

def mask_from(draw_fn):
    m = Image.new('L', (N, N), 0)
    draw_fn(ImageDraw.Draw(m))
    return m

canvas = Image.new('RGBA', (N, N), (0, 0, 0, 0))

# --- squircle body with drop shadow -------------------------------------
body = squircle(s(100), s(100), s(924), s(924))
shadow = mask_from(lambda d: d.polygon([(x, y + s(10)) for x, y in body], fill=110))
shadow = shadow.filter(ImageFilter.GaussianBlur(s(14)))
canvas.paste((0, 0, 0, 255), (0, 0), shadow)

body_mask = mask_from(lambda d: d.polygon(body, fill=255))
bg = vgradient((N, N), (98, 152, 245, 255), (36, 86, 214, 255))
canvas.paste(bg, (0, 0), body_mask)

# soft highlight across the top half
hl = mask_from(lambda d: d.ellipse([s(-80), s(-520), s(1104), s(470)], fill=30)).filter(ImageFilter.GaussianBlur(s(60)))
hl = ImageChops.multiply(hl, body_mask)
canvas.paste((255, 255, 255, 255), (0, 0), hl)

# --- pages ----------------------------------------------------------------
PX0, PY0, PX1, PY1 = 292, 196, 732, 832   # front page
FOLD = 118

def page_layer(color, folded):
    layer = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    r = s(18)
    if folded:
        poly = [(s(PX0), s(PY0)), (s(PX1 - FOLD), s(PY0)), (s(PX1), s(PY0 + FOLD)),
                (s(PX1), s(PY1)), (s(PX0), s(PY1))]
        d.polygon(poly, fill=color)
        # round the three square corners a touch
        m = Image.new('L', (N, N), 0)
        ImageDraw.Draw(m).rounded_rectangle([s(PX0), s(PY0), s(PX1), s(PY1)], radius=r, fill=255)
        ImageDraw.Draw(m).rectangle([s(PX1 - FOLD), s(PY0), s(PX1), s(PY0 + FOLD)], fill=255)
        layer.putalpha(ImageChops.multiply(layer.split()[3], m))
    else:
        d.rounded_rectangle([s(PX0), s(PY0), s(PX1), s(PY1)], radius=r, fill=color)
    return layer

def drop_shadow(layer, dy, blur, alpha):
    a = layer.split()[3].point(lambda v: v * alpha // 255)
    a = ImageChops.offset(a, 0, s(dy)).filter(ImageFilter.GaussianBlur(s(blur)))
    sh = Image.new('RGBA', (N, N), (10, 30, 80, 255)); sh.putalpha(a)
    return sh

# back page, rotated, peeking out to the left
back = page_layer((226, 233, 245, 255), folded=False)
back = back.rotate(8, resample=Image.BICUBIC, center=(s(512), s(560)))
back = ImageChops.offset(back, s(-34), s(6))
canvas.alpha_composite(drop_shadow(back, 8, 12, 90))
canvas.alpha_composite(back)

# front page
front = page_layer((255, 255, 255, 255), folded=True)
canvas.alpha_composite(drop_shadow(front, 12, 16, 120))
canvas.alpha_composite(front)

# fold flap with a little shadow under it
fd = ImageDraw.Draw(canvas)
flap = [(s(PX1 - FOLD), s(PY0)), (s(PX1 - FOLD), s(PY0 + FOLD)), (s(PX1), s(PY0 + FOLD))]
fs = Image.new('L', (N, N), 0)
ImageDraw.Draw(fs).polygon([(x - s(6), y + s(8)) for x, y in flap], fill=90)
fs = ImageChops.multiply(fs.filter(ImageFilter.GaussianBlur(s(8))), front.split()[3])
canvas.paste((20, 40, 90, 255), (0, 0), fs)
fd.polygon(flap, fill=(214, 223, 238, 255))

# --- markdown mark "M↓" ------------------------------------------------------
INK = (34, 40, 52, 255)
cx, top, h = 512, 330, 190       # mark centre x, top y, glyph height
st = 44                          # stroke width
mw = 200                         # M width
mx0 = cx - 150                   # M left edge
m = [
    (mx0, top + h), (mx0, top), (mx0 + st, top),
    (mx0 + mw/2, top + h*0.48), (mx0 + mw - st, top), (mx0 + mw, top),
    (mx0 + mw, top + h), (mx0 + mw - st, top + h), (mx0 + mw - st, top + h*0.36),
    (mx0 + mw/2, top + h*0.80), (mx0 + st, top + h*0.36), (mx0 + st, top + h),
]
fd.polygon([(s(x), s(y)) for x, y in m], fill=INK)

ax = mx0 + mw + 62               # arrow centre x
stem_w, head_w, head_h = 40, 112, 78
arrow = [
    (ax - stem_w/2, top), (ax + stem_w/2, top), (ax + stem_w/2, top + h - head_h),
    (ax + head_w/2, top + h - head_h), (ax, top + h), (ax - head_w/2, top + h - head_h),
    (ax - stem_w/2, top + h - head_h),
]
fd.polygon([(s(x), s(y)) for x, y in arrow], fill=INK)

# --- text lines ------------------------------------------------------------
LINE = (196, 204, 218, 255)
y = 590
for frac in (1.0, 0.92, 1.0, 0.66):
    x0 = PX0 + 58
    x1 = x0 + (PX1 - PX0 - 116) * frac
    fd.rounded_rectangle([s(x0), s(y), s(x1), s(y + 22)], radius=s(11), fill=LINE)
    y += 50

out = canvas.resize((1024, 1024), Image.LANCZOS)
dest = sys.argv[1].rstrip('/')
if dest.endswith('.appiconset'):
    import json, os
    os.makedirs(dest, exist_ok=True)
    images = []
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = f'icon_{pt}x{pt}{"@2x" if scale == 2 else ""}.png'
            out.resize((pt * scale,) * 2, Image.LANCZOS).save(os.path.join(dest, name))
            images.append({"idiom": "mac", "size": f"{pt}x{pt}", "scale": f"{scale}x", "filename": name})
    with open(os.path.join(dest, 'Contents.json'), 'w') as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
else:
    out.save(dest)
