#!/usr/bin/env python3
"""Build the tvOS brand assets (layered icon + Top Shelf) from the iOS icon.

Splits App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png into the
parallax layers tvOS wants: Back = sky gradient, Middle = cat (parts hidden
by the paws in-painted, body extended below the ledge), Front = white ledge +
both paws. Also writes a flattened composite used for the Top Shelf images.
Needs numpy, opencv-python and Pillow.

    usage: generate-tv-brand-assets.py <AppIcon.png> <out-dir> <y0> <y1> <width> <WxH>...

y0/y1/width are the canvas in 1024-px icon coordinates; the ledge is row 638.
    icon:          20 900 1467 1280x768 800x480 400x240
    top shelf:   -370 1070 3840 3840x1440 1920x720
    top shelf w: -370 1070 4640 4640x1440 2320x720
"""
import sys
import numpy as np, cv2
from PIL import Image, ImageDraw, ImageFilter

src = np.asarray(Image.open(sys.argv[1]).convert('RGB')).astype(np.float32)
LEDGE = 638                     # first ledge row in art coordinates
Y0, Y1 = int(sys.argv[3]), int(sys.argv[4])   # art rows; may exceed 0..1023
H = Y1 - Y0
W = int(sys.argv[5])
X0 = 512 - W // 2
ys = np.arange(Y0, Y1)
xs = np.arange(X0, X0 + W)

def rgba(rgb, a):
    return np.dstack([np.clip(rgb, 0, 255), np.clip(a, 0, 1) * 255]).astype(np.uint8)

# ---- Back: per-row linear fit of the sky over visible sky pixels ----------
r, g, b = src[..., 0], src[..., 1], src[..., 2]
skyish = (b > 200) & (r < 130) & (g > 120)
coef = {}
for y in range(110, LEDGE - 4):
    x = np.nonzero(skyish[y, 40:984])[0] + 40
    if len(x) < 40:
        continue
    A = np.c_[x, np.ones_like(x)]
    coef[y] = np.linalg.lstsq(A, src[y, x], rcond=None)[0]   # (2,3)
rows = np.array(sorted(coef))
C = np.stack([coef[y] for y in rows])                          # (n,2,3)
C = cv2.GaussianBlur(C.reshape(len(rows), 6), (1, 31), 0).reshape(-1, 2, 3) if len(rows) > 31 else C
def coef_at(y):
    if y < rows[0]:                       # extrapolate upward from first 120 rows
        k = rows[:120]; c = C[:120]
        fit = [np.polyfit(k, c[:, i, j], 1) for i in range(2) for j in range(3)]
        return np.array([np.polyval(f, y) for f in fit]).reshape(2, 3)
    return C[min(np.searchsorted(rows, y), len(rows) - 1)]
back = np.zeros((H, W, 3), np.float32)
for i, y in enumerate(ys):
    if y < rows[0]:                                   # ease the gradient out above the art
        t = rows[0] - y
        c = C[0] + (C[0] - C[60]) / 60 * 180 * (1 - np.exp(-t / 180))
    else:
        c = coef_at(min(y, rows[-1]))
    back[i] = np.clip(xs, 60, 964)[:, None] * c[0] + c[1]   # flat beyond the sides
back = cv2.GaussianBlur(back, (0, 0), sigmaX=6, sigmaY=12)

def sky_at(y, x):
    c = coef_at(min(max(y, 0), rows[-1]))
    return x * c[0] + c[1]

# ---- paw masks (above the ledge line), drawn at 4x for anti-aliasing -------
S = 4
def poly_mask(pts):
    m = Image.new('L', (1024 * S, 1024 * S), 0)
    ImageDraw.Draw(m).polygon([(x * S, y * S) for x, y in pts], fill=255)
    return np.asarray(m.resize((1024, 1024), Image.LANCZOS)).astype(np.float32) / 255
left_arm = [(112, 645), (113, 610), (120, 580), (134, 554), (154, 534), (180, 519), (206, 511),
            (236, 511), (266, 519), (296, 535), (326, 558), (351, 585), (371, 612), (387, 645)]
right_paw = [(718, 645), (721, 614), (734, 594), (759, 579), (790, 573), (821, 575),
             (851, 585), (876, 605), (890, 632), (891, 645)]
paws = np.maximum(poly_mask(left_arm), poly_mask(right_paw))
paws[LEDGE:] = 0

# ---- matte: r-b mixes linearly between sky (~-235) and cat (>~150) --------
full_sky = np.zeros_like(src)
for y in range(0, LEDGE):
    full_sky[y] = sky_at(y, np.arange(1024)[:, None])
v = src[..., 0] - src[..., 2]
sv = full_sky[..., 0] - full_sky[..., 2]
fg = np.clip((v - sv - 25) / (150 - sv - 25), 0, 1)
fg[LEDGE:] = 0
# keep only the cat: largest component, holes (eyes) filled
bin_ = (fg > 0.5).astype(np.uint8)
n, lab, stats, _ = cv2.connectedComponentsWithStats(bin_, 8)
keep = (lab == 1 + np.argmax(stats[1:, cv2.CC_STAT_AREA])).astype(np.uint8)
flood = keep.copy(); m = np.zeros((1026, 1026), np.uint8)
cv2.floodFill(flood, m, (0, 0), 1)
solid = keep | (1 - flood)
near = cv2.dilate(solid, np.ones((7, 7), np.uint8))
fg = np.where(solid > 0, 1.0, np.where(near > 0, fg, 0.0))
fg[LEDGE:] = 0
# un-premultiply against the known sky
a3 = np.maximum(fg, 1e-3)[..., None]
unmixed = np.clip((src - (1 - a3) * full_sky) / a3, 0, 255)
unmixed = np.where(solid[..., None] > 0, src, unmixed)

# ---- Front: ledge (original + horizontal extension) + paws above the line --
R0, R1 = min(Y0, 0), max(Y1, 1024)                # row buffer covering art + canvas
front = np.zeros((R1 - R0, W, 3), np.float32)
front_a = np.zeros((R1 - R0, W), np.float32)
band = np.r_[60:110, 914:964]
def ramp(v, a, b):
    return np.clip((v - a) / (b - a), 0, 1)
hx = ramp(xs, 60, 160) * ramp(-xs, -964, -864)
for y in range(LEDGE, Y1):
    sy = min(y, 899)                                  # below the art: repeat last clean row
    edge = np.median(src[sy, band], axis=0)
    row = np.tile(edge, (W, 1))
    inside = (xs >= 60) & (xs < 964)
    w = hx * (1 - ramp(y, 820, 899))
    row[inside] = edge + w[inside, None] * (src[sy, xs[inside]] - edge)
    front[y - R0] = row
    front_a[y - R0] = 1
# paws above the ledge
pa = paws * fg                   # matte against sky only
for y in range(500, LEDGE):
    j = np.arange(1024) - X0
    ok = (j >= 0) & (j < W)
    front[y - R0, j[ok]] = np.where(pa[y, ok, None] > 0, unmixed[y, ok], 0)
    front_a[y - R0, j[ok]] = pa[y, ok]

# ---- Middle: cat, with paw areas in-painted and body pushed below the ledge
cat = unmixed.copy()
cat_a = fg.copy()
head_left, head_right = 172, 858
under = (paws > 0.01)
yy, xx = np.mgrid[0:1024, 0:1024]
head_under = under & (xx >= head_left) & (xx <= head_right)
cat_a = np.where(head_under, 1, np.where(under, 0, cat_a))
paw_zone = cv2.dilate((paws > 0).astype(np.uint8), np.ones((9, 9), np.uint8)) > 0
cat_a = np.where(paw_zone & ~((xx >= head_left) & (xx <= head_right)), 0, cat_a)
hole = (head_under | (under & (fg < 0.99))).astype(np.uint8)
known = np.clip(cat, 0, 255).astype(np.uint8)
bad = ((fg < 0.98) | (hole > 0)).astype(np.uint8)
bad = cv2.dilate(bad, np.ones((5, 5), np.uint8)) | hole
known = cv2.inpaint(known, bad, 9, cv2.INPAINT_TELEA).astype(np.float32)
cat = np.where(hole[..., None] > 0, known, cat)
# extend the bottom row of the head down behind the ledge
base = LEDGE - 6
for y in range(base, 760):
    cat[y] = cat[base - 1]
    cat_a[y] = np.maximum(cat_a[base - 1], (xx[0] >= head_left) & (xx[0] <= head_right))
    cat_a[y, :head_left] = 0; cat_a[y, head_right + 1:] = 0

mid = np.zeros((R1 - R0, W, 3), np.float32); mid_a = np.zeros((R1 - R0, W), np.float32)
j = np.arange(1024) - X0; ok = (j >= 0) & (j < W)
mid[-R0:1024 - R0, j[ok]] = cat[:, ok]; mid_a[-R0:1024 - R0, j[ok]] = cat_a[:, ok]

layers = {
    'back': rgba(back, np.ones((H, W))),
    'middle': rgba(mid[Y0 - R0:Y1 - R0], mid_a[Y0 - R0:Y1 - R0]),
    'front': rgba(front[Y0 - R0:Y1 - R0], front_a[Y0 - R0:Y1 - R0]),
}
out = sys.argv[2]
sizes = [tuple(map(int, a.split('x'))) for a in sys.argv[6:]]
ims = {}
for name, arr in layers.items():
    ims[name] = Image.fromarray(arr, 'RGBA')
flat = ims['back'].copy()
for n in ('middle', 'front'):
    flat.alpha_composite(ims[n])
ims['flat'] = flat
for name, im in ims.items():
    for size in sizes:
        o = im.resize(size, Image.LANCZOS)
        if name in ('back', 'flat'):
            o = o.convert('RGB')
        o.save(f'{out}/{name}-{size[0]}x{size[1]}.png')
print('ok', W, H, X0)
