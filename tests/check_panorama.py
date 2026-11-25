# Panorama stitch self-check: python3 tests/check_panorama.py (needs only Pillow)
import os, sys, random, tempfile, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "python"))
from PIL import Image, ImageDraw, ImageFilter
import camworker as c

random.seed(1)
W, H = 9000, 2400
scene = Image.new("RGB", (W, H), (120, 150, 200))
d = ImageDraw.Draw(scene)
for _ in range(900):
    x, y, r = random.randrange(W), random.randrange(H), random.randrange(20, 160)
    d.ellipse((x - r, y - r, x + r, y + r), fill=tuple(random.randrange(256) for _ in range(3)))
scene = scene.filter(ImageFilter.GaussianBlur(2))

fw, fh = 1350, 2000          # portrait frames
tmp = tempfile.mkdtemp()
paths = []
x, y = 200, 150
for i in range(14):           # burst: steps of 250-400 px, a bit of vertical wobble
    p = os.path.join(tmp, "IMG_%02d.jpg" % i)
    scene.crop((x, y, x + fw, y + fh)).save(p, quality=90)
    paths.append(p)
    x += random.randrange(250, 400)
    y += random.randrange(-12, 13)
span = x - random.randrange(250, 400) + fw - 200   # covered width of the scene
out = tempfile.mkdtemp()
t = time.time()
res = c.panorama(paths, out)
print("result", res, "%.1fs" % (time.time() - t))
im = Image.open(res[0])
print("size", im.size, "expected width ~", span)
assert abs(im.width - span) < 40, im.width
assert im.height > fh - 60
assert not any(os.path.exists(p) for p in paths)

# wrong direction (turning left) gives the same width
paths2 = []
for i, p in enumerate(range(5)):
    q = os.path.join(tmp, "L_%d.jpg" % i)
    xx = 4000 - i * 350
    scene.crop((xx, 150, xx + fw, 150 + fh)).save(q, quality=90)
    paths2.append(q)
res2 = c.panorama(paths2, out)
w2 = Image.open(res2[0]).width
print("left", res2, w2, "expected", 4 * 350 + fw)
assert abs(w2 - (4 * 350 + fw)) < 20
# a frame that matches nothing is skipped
paths3 = []
for i in range(4):
    q = os.path.join(tmp, "N_%d.jpg" % i)
    img = scene.crop((1000 + i * 500, 150, 1000 + i * 500 + fw, 150 + fh))
    if i == 2:
        img = Image.new("RGB", (fw, fh), (10, 200, 10))
    img.save(q, quality=90)
    paths3.append(q)
res3 = c.panorama(paths3, out)
print("noise", res3, Image.open(res3[0]).width)
print("PANO_OK")
