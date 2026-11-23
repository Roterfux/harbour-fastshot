"""Photo Enhance engine: an "auto enhance" in plain Pillow (no numpy, no OpenCV).

Every effect is a number from 0 (off) to 100 (strong):

    exposure   brighten or darken towards a pleasant average brightness
    contrast   stretch the tonal range so blacks are black and whites are white
    shadows    lift dark areas
    highlights recover bright areas
    local      local contrast ("punch", like CLAHE / Google Photos "Pop")
    wb         grey-world white balance (removes colour casts)
    color      colour saturation
    denoise    colour + luminance noise reduction (phone sensors are noisy)
    sharpen    sharpening, applied to luminance only

The module is used from QML through PyOtherSide (see start_batch / make_preview) and
can also be run from a terminal:  python3 enhance.py photo.jpg [more.jpg ...] -o outdir
"""

import math
import os
import threading
from urllib.parse import unquote

from PIL import Image, ImageChops, ImageEnhance, ImageFilter, ImageOps, ImageStat

try:  # present when running inside PyOtherSide
    import pyotherside
except ImportError:  # command line / tests
    pyotherside = None

_RES = getattr(Image, "Resampling", Image)  # Pillow >= 9.1 moved the filters
BILINEAR = _RES.BILINEAR
BOX = _RES.BOX
LANCZOS = _RES.LANCZOS

KEYS = ("exposure", "contrast", "shadows", "highlights", "local", "wb", "color", "denoise", "sharpen")
EXIF_ORIENTATION = 0x0112
JPEG_QUALITY = 93
SUFFIX = "_enhanced"
PREVIEW_SIZE = 1000


# --------------------------------------------------------------------------- helpers

def to_path(value):
    """'file:///home/x/a%20b.jpg' (or a plain path) -> '/home/x/a b.jpg'."""
    value = str(value)
    if value.startswith("file://"):
        value = unquote(value[7:])
    return value


def _norm(settings):
    """Settings as {key: 0.0 .. 1.0}; unknown or missing keys count as 0."""
    out = {}
    for key in KEYS:
        try:
            out[key] = max(0.0, min(1.0, float(settings.get(key, 0)) / 100.0))
        except (TypeError, ValueError):
            out[key] = 0.0
    return out


def _clamp8(v):
    return 0 if v <= 0 else 255 if v >= 255 else int(v + 0.5)


def default_out_dir():
    return os.path.join(os.path.expanduser("~"), "Pictures", "Enhanced")


def default_cache_dir():
    import tempfile  # the sandbox gives every app its own private /tmp
    return os.path.join(tempfile.gettempdir(), "harbour-photoenhance")


def _send(*args):
    if pyotherside is not None:
        pyotherside.send(*args)


# --------------------------------------------------------------------------- pipeline

def _scale(img):
    """Pixel sizes of radii are tuned for a ~4000 px photo and scaled for smaller images."""
    return max(img.size) / 4000.0


def _denoise(img, amount):
    """Noise reduction. Colour noise (the red and green dots of high-ISO photos) is what makes
    dark phone photos ugly, so most of the work goes there:
      1. the colour planes are smoothed at 1/4 size (the eye sees colour at much lower
         resolution than brightness) — the downscale kills individual colour dots and the
         blur handles blotches;
      2. the darkest areas, where colour noise is worst and real colour is weak, are made
         less colourful.
    Brightness gets a light box blur, and at high amounts _smooth_flat keeps edges."""
    scale = _scale(img)
    w, h = img.size
    y, cb, cr = img.convert("YCbCr").split()

    # 1. colour planes smoothed at 1/4 size: the BOX downscale averages 4x4 blocks, which
    #    already kills individual colour dots; the blur handles larger blotches
    small = (max(1, w // 4), max(1, h // 4))
    radius = max(0.6, (2.0 + 8.0 * amount) * scale / 4)

    def smooth(plane):
        return plane.resize(small, BOX).filter(
            ImageFilter.GaussianBlur(max(radius, 0.8))
        ).resize((w, h), BILINEAR)

    cb, cr = smooth(cb), smooth(cr)

    # 2. less colour in the deep shadows (below ~25 % brightness, fully at ~8 %)
    k = 0.7 * amount
    if k > 0:
        dark = y.point(lambda v: int(255 * k * max(0.0, min(1.0, (64 - v) / 44.0))))
        neutral = Image.new("L", (w, h), 128)
        cb = Image.composite(neutral, cb, dark)
        cr = Image.composite(neutral, cr, dark)

    # brightness: a box blur blended in (the blend factor keeps it subtle at low amounts)
    med = y.filter(ImageFilter.BoxBlur(1))
    y = Image.blend(y, med, min(1.0, 0.25 + 0.75 * amount))
    if amount > 0.4:
        y = _smooth_flat(y, (amount - 0.4) / 0.4, scale)
    return Image.merge("YCbCr", (y, cb, cr)).convert("RGB")


def _smooth_flat(y, strength, scale):
    """Strong grain (night photos): smooth the brightness where the picture is flat and leave
    edges alone. 'Flat' is measured as local activity compared with the photo's own noise
    level: areas no busier than the noise itself are noise; clearly busier ones are detail.

    Works on a 1/4 size copy: the phone's own noise reduction already removes the fine grain
    and leaves blotches of about 8-15 px at 12 MP (night photos of 2026-11-11), which a
    pixel-sized filter does not touch."""
    w, h = y.size
    f = max(1, int(round(4 * scale)))
    small = y.resize((max(1, w // f), max(1, h // f)), BOX) if f > 1 else y
    smooth = small.filter(ImageFilter.GaussianBlur(2.0))
    activity = ImageChops.difference(small, smooth).filter(ImageFilter.GaussianBlur(3.0))
    floor = max(1, _percentile(activity.histogram(), 0.5))       # typical activity = the noise
    lo, hi = 1.3 * floor, 2.6 * floor
    k = min(1.0, strength) * 0.85

    def weight(v):
        t = 1.0 if v <= lo else 0.0 if v >= hi else (hi - v) / (hi - lo)
        return int(255 * k * t)

    mask = activity.point(weight)
    if f > 1:
        smooth = smooth.resize((w, h), BILINEAR)
        mask = mask.resize((w, h), BILINEAR)
    return Image.composite(smooth, y, mask)


def _skin_mask(thumb):
    """255 where a pixel has skin colour (YCbCr thresholds), else 0."""
    y, cb, cr = thumb.convert("YCbCr").split()
    y_ok = y.point(lambda v: 255 if 60 < v < 240 else 0)
    cb_ok = cb.point(lambda v: 255 if 77 <= v <= 127 else 0)
    cr_ok = cr.point(lambda v: 255 if 133 <= v <= 173 else 0)
    return ImageChops.multiply(ImageChops.multiply(y_ok, cb_ok), cr_ok)


def _neutral_means(thumb):
    """Average R, G, B of the pixels that should be grey: not strongly coloured, not skin, not
    nearly black or blown out. A big red jacket, a face or a green lawn is left out, so it
    does not count as a colour cast (FastShot 0.4.0-23: selfies in a red jacket came out teal).
    Falls back to all pixels when hardly any are near grey."""
    _, s, v = thumb.convert("HSV").split()
    low_sat = s.point(lambda x: 255 if x < 128 else 0)
    mid = v.point(lambda x: 255 if 40 < x < 245 else 0)
    mask = ImageChops.subtract(ImageChops.multiply(low_sat, mid), _skin_mask(thumb))
    count = mask.histogram()[255]
    if count >= 0.05 * thumb.size[0] * thumb.size[1]:
        return ImageStat.Stat(thumb, mask).mean
    return ImageStat.Stat(thumb).mean


def _grey_world_gains(thumb, amount):
    """Per-channel multipliers that make the near-grey pixels grey (limited, and blended)."""
    means = _neutral_means(thumb)
    if min(means) < 1.0:
        return [1.0, 1.0, 1.0]
    grey = sum(means) / 3.0
    gains = [grey / m for m in means]
    gains = [1.0 + amount * (max(0.82, min(1.22, g)) - 1.0) for g in gains]
    norm = 3.0 / sum(gains)  # keep overall brightness; exposure is handled separately
    return [g * norm for g in gains]


def _levels(hist, amount):
    """Black and white point (0..255) that clip 0.5 % of the pixels at each end."""
    total = float(sum(hist)) or 1.0
    clip = total * 0.005
    acc, lo = 0.0, 0
    for i in range(256):
        acc += hist[i]
        if acc > clip:
            lo = i
            break
    acc, hi = 0.0, 255
    for i in range(255, -1, -1):
        acc += hist[i]
        if acc > clip:
            hi = i
            break
    # never stretch a dark night scene into daylight
    lo = min(lo, 45) * amount
    hi = 255 - (255 - max(hi, 200)) * amount
    return lo, max(hi, lo + 32)


def _gamma(hist, lo, hi, amount):
    """Exponent that moves the mean brightness (after the level stretch) towards ~0.42."""
    total = float(sum(hist)) or 1.0
    span = hi - lo
    mean = sum(n * max(0.0, min(1.0, (i - lo) / span)) for i, n in enumerate(hist)) / total
    if mean < 0.02 or mean > 0.98:
        return 1.0
    g = math.log(0.42) / math.log(mean)
    g = max(0.7, min(1.25, g))
    return 1.0 + amount * (g - 1.0)


def _tone_lut(gain, lo, hi, gamma, shadows, highlights):
    span = max(hi - lo, 1.0)
    lut = []
    for i in range(256):
        x = (i * gain - lo) / span
        x = 0.0 if x < 0 else 1.0 if x > 1 else x
        x = x ** gamma
        x += shadows * 0.8 * x * (1 - x) ** 2          # lift the darks (peaks around x = 1/3)
        x -= highlights * 0.8 * x * x * (1 - x)        # pull down the brights (peaks around 2/3)
        lut.append(_clamp8(x * 255.0))
    return lut


def _local_contrast(y, amount):
    """Unsharp mask with a very large radius, computed on a reduced copy for speed."""
    w, h = y.size
    down = max(1, max(w, h) // 500)
    small = y.resize((max(1, w // down), max(1, h // down)), BILINEAR)
    radius = 0.04 * max(small.size)
    blurred = small.filter(ImageFilter.GaussianBlur(radius)).resize((w, h), BILINEAR)
    return Image.blend(blurred, y, 1.0 + 0.6 * amount)   # alpha > 1 extrapolates: y + a * (y - blur)


def _local_tonemap(y, amount):
    """Dodge-and-burn: locally brighten shadows and compress highlights.
    Works on the luminance channel only; colour is untouched."""
    w, h = y.size
    down = max(1, max(w, h) // 300)
    small = y.resize((max(1, w // down), max(1, h // down)), BOX)
    radius = max(3, int(max(small.size) * 0.12))
    local_avg = small.filter(ImageFilter.GaussianBlur(radius)).resize((w, h), BILINEAR)
    k = min(1.0, amount)
    lift_lut = [_clamp8(255 * ((v / 255.0) ** 0.65)) for v in range(256)]
    lifted = y.point(lift_lut)
    dark_mask_lut = [_clamp8(255 * k * max(0.0, min(1.0, (110 - v) / 70.0))) for v in range(256)]
    dark_mask = local_avg.point(dark_mask_lut)
    result = Image.composite(lifted, y, dark_mask)
    compress_lut = [_clamp8(255 * ((v / 255.0) ** 1.3)) for v in range(256)]
    compressed = y.point(compress_lut)
    bright_mask_lut = [_clamp8(255 * k * 0.6 * max(0.0, min(1.0, (v - 170) / 50.0))) for v in range(256)]
    bright_mask = local_avg.point(bright_mask_lut)
    return Image.composite(compressed, result, bright_mask)


def _vignette_correct(img):
    """Compensate corner brightness fall-off (lens vignetting).
    Parametric model for a typical f/1.8 phone camera (~15 % drop at corners)."""
    w, h = img.size
    gs = 64
    gh = max(1, int(gs * h / w))
    cx, cy = gs / 2.0, gh / 2.0
    max_r2 = cx * cx + cy * cy
    strength = 0.15
    mask_data = [_clamp8(255 * strength * ((px - cx) ** 2 + (py - cy) ** 2) / max_r2)
                 for py in range(gh) for px in range(gs)]
    mask = Image.new("L", (gs, gh))
    mask.putdata(mask_data)
    mask = mask.resize((w, h), BILINEAR).convert("RGB")
    return ImageChops.add(img, ImageChops.multiply(img, mask))


def _ca_correct(img):
    """Correct lateral chromatic aberration by scaling R and B relative to G.
    Conservative values for a typical phone camera."""
    w, h = img.size
    if max(w, h) < 1000:
        return img
    r, g, b = img.split()
    r_scale = 1.00025
    b_scale = 0.99970

    def fix_ch(ch, scale):
        if abs(scale - 1.0) < 1e-5:
            return ch
        nw, nh = max(1, int(round(w * scale))), max(1, int(round(h * scale)))
        resized = ch.resize((nw, nh), LANCZOS)
        if nw >= w and nh >= h:
            dx, dy = (nw - w) // 2, (nh - h) // 2
            return resized.crop((dx, dy, dx + w, dy + h))
        result = ch.copy()
        dx, dy = (w - nw) // 2, (h - nh) // 2
        result.paste(resized, (dx, dy))
        return result

    return Image.merge("RGB", (fix_ch(r, r_scale), g, fix_ch(b, b_scale)))


def tone_params(img, settings):
    """What the tone curve needs, measured on a small copy of `img`: per-channel white-balance
    gains, black and white point (0..255), gamma, shadows and highlights (0..1). None when no
    tone effect is on. Shared by the CPU path below and FastShot's GPU shader."""
    s = _norm(settings)
    if not (s["exposure"] or s["contrast"] or s["shadows"] or s["highlights"] or s["wb"]):
        return None
    w, h = img.size
    r = min(256.0 / max(w, 1), 256.0 / max(h, 1))
    thumb = img.resize((max(1, int(w * r)), max(1, int(h * r))), BOX)
    if thumb.mode != "RGB":
        thumb = thumb.convert("RGB")
    gains = _grey_world_gains(thumb, s["wb"]) if s["wb"] > 0 else [1.0, 1.0, 1.0]
    # measure the brightness distribution after white balance, on the small copy
    luts = [[_clamp8(i * g) for i in range(256)] for g in gains]
    hist = thumb.point(luts[0] + luts[1] + luts[2]).convert("L").histogram()
    lo, hi = _levels(hist, s["contrast"]) if s["contrast"] > 0 else (0.0, 255.0)
    gamma = _gamma(hist, lo, hi, s["exposure"]) if s["exposure"] > 0 else 1.0
    return {"gains": [float(g) for g in gains], "lo": float(lo), "hi": float(hi), "gamma": float(gamma),
            "shadows": s["shadows"], "highlights": s["highlights"]}


def gpu_params(img, settings):
    """Everything FastShot's GPU shader needs, as plain numbers (see EnhanceEffect.qml).
    `settings` must already be resolved (no 'auto' flag)."""
    s = _norm(settings)
    t = tone_params(img, settings) or {"gains": [1.0, 1.0, 1.0], "lo": 0.0, "hi": 255.0, "gamma": 1.0,
                                        "shadows": 0.0, "highlights": 0.0}
    t.update(local=s["local"], color=s["color"], denoise=s["denoise"], sharpen=s["sharpen"])
    return t


def enhance(img, settings):
    """Return an enhanced copy of an RGB image."""
    s = _norm(settings)
    tonemap = max(0.0, min(1.0, float(settings.get("tonemap", 0)) / 100.0))
    if img.mode != "RGB":
        img = img.convert("RGB")

    if settings.get("_lens_correct"):
        img = _ca_correct(img)
        img = _vignette_correct(img)

    if s["denoise"] > 0:
        img = _denoise(img, s["denoise"])

    t = tone_params(img, settings)
    if t is not None:
        tables = []
        for g in t["gains"]:
            tables += _tone_lut(g, t["lo"], t["hi"], t["gamma"], t["shadows"], t["highlights"])
        img = img.point(tables)

    if tonemap > 0 or s["local"] > 0 or s["sharpen"] > 0:
        y, cb, cr = img.convert("YCbCr").split()
        if tonemap > 0:
            y = _local_tonemap(y, tonemap)
        if s["local"] > 0:
            y = _local_contrast(y, s["local"])
        if s["sharpen"] > 0:
            radius = max(0.6, 0.0004 * max(img.size))
            y = y.filter(ImageFilter.UnsharpMask(radius, int(20 + 130 * s["sharpen"]), 2))
        img = Image.merge("YCbCr", (y, cb, cr)).convert("RGB")

    if s["color"] > 0:
        img = ImageEnhance.Color(img).enhance(1.0 + 0.6 * s["color"])
    return img


# --------------------------------------------------------------------------- smart auto

def _percentile(hist, fraction):
    total = float(sum(hist)) or 1.0
    acc = 0.0
    for i, n in enumerate(hist):
        acc += n
        if acc >= total * fraction:
            return i
    return len(hist) - 1


def _ramp(value, lo, hi, out_lo, out_hi):
    """Linear map of value from [lo, hi] to [out_lo, out_hi], clamped."""
    t = 0.0 if hi == lo else (value - lo) / float(hi - lo)
    t = max(0.0, min(1.0, t))
    return out_lo + (out_hi - out_lo) * t


def _skin_stats(thumb):
    """Detect skin-coloured pixels on a thumbnail (YCbCr thresholding).
    Returns (fraction of image that is skin, mean luminance of skin 0..1)."""
    y = thumb.convert("L")
    skin_y = ImageChops.multiply(y, _skin_mask(thumb))
    h = skin_y.histogram()
    skin_count = sum(h[1:])
    total = thumb.size[0] * thumb.size[1]
    if skin_count < total * 0.02:
        return 0.0, 0.0
    return skin_count / float(total), sum(i * h[i] for i in range(1, 256)) / skin_count / 255.0


def analyze(img):
    """Measurements the auto mode decides from. `img` must be the full-resolution photo,
    because noise can only be measured at the real pixel size."""
    rgb = img if img.mode == "RGB" else img.convert("RGB")
    w, h = rgb.size
    r = min(256.0 / max(w, 1), 256.0 / max(h, 1))
    thumb = rgb.resize((max(1, int(w * r)), max(1, int(h * r))), BOX)
    gray = thumb.convert("L")
    hist = gray.histogram()
    total = float(sum(hist)) or 1.0
    means = _neutral_means(thumb)                # colour cast of what should be grey
    grey = sum(means) / 3.0 or 1.0

    # noise and texture from a full-resolution crop of the centre
    w, h = rgb.size
    cs = min(256, w, h)
    x0, y0 = (w - cs) // 2, (h - cs) // 2
    crop = rgb.crop((x0, y0, x0 + cs, y0 + cs)).convert("L")
    resid = ImageChops.difference(crop, crop.filter(ImageFilter.GaussianBlur(1.2)))
    rhist = resid.histogram()

    # faces are looked for after a full white balance: a camera's colour cast (the selfie camera's
    # teal, lamp light) otherwise moves skin out of the skin colours and the face rules never run
    gains = _grey_world_gains(thumb, 1.0)
    balanced = thumb.point([_clamp8(i * g) for g in gains for i in range(256)])
    skin_frac, skin_mean = _skin_stats(balanced)
    return {
        "mean": sum(i * n for i, n in enumerate(hist)) / total / 255.0,
        "std": ImageStat.Stat(gray).stddev[0],
        "spread": _percentile(hist, 0.99) - _percentile(hist, 0.01),
        "dark": sum(hist[:50]) / total,
        "bright": sum(hist[220:]) / total,
        "clipped": sum(hist[240:]) / total,
        "cast": max(abs(m / grey - 1.0) for m in means),
        "warmth": (means[0] - means[2]) / grey,                 # > 0: orange (lamp light), < 0: blue
        "saturation": ImageStat.Stat(thumb.convert("HSV").split()[1]).mean[0] / 255.0,
        "noise": _percentile(rhist, 0.5),                       # residual in flat areas
        "texture": ImageStat.Stat(resid).mean[0],
        "skin_fraction": skin_frac,
        "skin_mean": skin_mean,
    }


def auto_settings(img, info=None):
    """The effects this particular photo needs, as {key: 0..100}.

    Dark photos get more exposure, shadows and denoising; hazy ones more contrast;
    a colour cast gets white balance; flat colours get more saturation; clipped skies get
    highlight recovery; noisy photos get less sharpening. Night scenes are kept dark on purpose.
    With `info` (see capture_info) the settings are also adapted to the light the photo was
    taken in (see LIGHT_SCENES).
    """
    return auto_with_scene(img, info)[0]


def auto_with_scene(img, info=None):
    """auto_settings plus the light scene it chose: (settings, scene name, backlit)."""
    a = analyze(img)
    base = _auto_from_analysis(a)
    scene = light_scene(info, a)
    backlit = is_backlit(a, scene)
    result = _adapt_to_light(base, a, info or {}, scene, backlit)
    tonemap = 0
    if a["spread"] > 180 and a["dark"] > 0.10 and a["bright"] > 0.05:
        tonemap = _ramp(a["spread"], 180, 240, 15, 50)
    if backlit:
        tonemap = max(tonemap, 40)
    has_face = a.get("skin_fraction", 0) > 0.03
    if has_face and a.get("skin_mean", 0) < 0.35:
        tonemap = max(tonemap, 30)
    if scene in ("night", "dim"):
        # every low-light photo, not only those with a face (before 0.4.0-22 only selfies got it)
        tonemap = max(tonemap, 35)
    rounded = {k: int(round(v / 5.0) * 5) for k, v in result.items()}
    rounded["tonemap"] = int(round(tonemap / 5.0) * 5)
    rounded["_lens_correct"] = 1
    return rounded, scene, backlit


def _auto_from_analysis(a):
    night = a["mean"] < 0.15
    has_face = a.get("skin_fraction", 0) > 0.03
    skin_mean = a.get("skin_mean", 0)

    exposure = _ramp(abs(0.42 - a["mean"]), 0.03, 0.25, 0, 100)
    if a["mean"] > 0.42:
        exposure = min(exposure, 60)          # darkening is limited anyway
    if night:
        exposure = min(exposure, 70)
    contrast = _ramp(a["spread"], 235, 125, 15, 100)
    shadows = max(10, min(70, a["dark"] * 160))
    if night:
        shadows = min(shadows, 45)
    highlights = max(8, min(70, a["clipped"] * 500))
    if a["cast"] > 0.30:
        wb = 25                                # a strongly coloured scene (sunset, foliage): be careful
    else:
        # measured on near-grey pixels only (0.4.0-23), so it can correct more firmly than before
        wb = _ramp(a["cast"], 0.03, 0.15, 0, 85)
    color = _ramp(a["saturation"], 0.55, 0.10, 5, 65)
    local = _ramp(a["std"], 45, 80, 50, 15)
    denoise = _ramp(a["noise"], 0.8, 3.5, 10, 70)
    if night:
        denoise = max(denoise, 40)
    sharpen = 35 + (10 if 1.2 < a["texture"] < 2.5 else 0) - (15 if denoise > 55 else 0)

    if has_face and skin_mean > 0 and skin_mean < a["mean"]:
        face_deficit = a["mean"] - skin_mean
        face_boost = _ramp(face_deficit, 0.05, 0.25, 5, 30)
        exposure = min(100, exposure + face_boost)
        shadows = min(70, shadows + face_boost * 0.5)

    return dict(exposure=exposure, contrast=contrast, shadows=shadows, highlights=highlights,
                local=local, wb=wb, color=color, denoise=denoise, sharpen=sharpen)


# --------------------------------------------------------------------------- light-aware auto
#
# How bright the scene really was cannot be read from the picture: the camera's auto exposure
# makes a dark room and a sunny street look about equally bright. It can be worked out from how
# the camera exposed the photo (EXIF exposure time, aperture, ISO), as the scene brightness in
# EV at ISO 100: EV = log2(N^2 / t) - log2(ISO / 100). Without EXIF the phone's light sensor is
# used (lux = 2.5 * 2^EV); it faces the user, not the scene, so it is only the fallback.
#
# Typical values: night street 0-3, dim room 3-5.5, lit room / office 5.5-9,
# overcast / shade 9-13, sunshine 13 and above.

EXIF_IFD = 0x8769
TAG_EXPOSURE_TIME = 0x829A
TAG_FNUMBER = 0x829D
TAG_ISO = 0x8827
TAG_FLASH = 0x9209
DEFAULT_FNUMBER = 1.8           # Xperia 10 III main camera; only used when EXIF has none

LIGHT_SCENES = ("night", "dim", "indoor", "daylight", "sun")


def _num(value):
    """An EXIF number (int, float, rational, (num, den) or a list of them) as float, or None."""
    try:
        if isinstance(value, (list, tuple)):
            if len(value) == 2 and all(isinstance(v, int) for v in value) and value[1] > 1:
                return float(value[0]) / float(value[1])    # (numerator, denominator)
            value = value[0]
        v = float(value)
        return v if v > 0 else None
    except (TypeError, ValueError, ZeroDivisionError, IndexError):
        return None


def _exif_tags(im):
    """Exposure tags of an open image, from the Exif sub-IFD (any Pillow version)."""
    tags = {}
    try:
        ex = im.getexif()
        if ex:
            tags.update(ex)
            if hasattr(ex, "get_ifd"):
                tags.update(ex.get_ifd(EXIF_IFD))
    except Exception:
        pass
    if TAG_ISO not in tags and hasattr(im, "_getexif"):   # older Pillow: flattened dictionary
        try:
            tags.update(im._getexif() or {})
        except Exception:
            pass
    return tags


def _capture_info_from_tags(tags, lux=None):
    """Build capture info from a pre-read EXIF tags dict (avoids reopening the file)."""
    info = {"iso": None, "exposure": None, "fnumber": None, "flash": None, "lux": None, "ev": None,
            "source": "none"}
    info["iso"] = _num(tags.get(TAG_ISO))
    info["exposure"] = _num(tags.get(TAG_EXPOSURE_TIME))
    info["fnumber"] = _num(tags.get(TAG_FNUMBER))
    flash = tags.get(TAG_FLASH)
    if isinstance(flash, int):
        info["flash"] = bool(flash & 1)
    try:
        if lux is not None and float(lux) >= 0:
            info["lux"] = float(lux)
    except (TypeError, ValueError):
        pass
    if info["iso"] and info["exposure"]:
        n = info["fnumber"] or DEFAULT_FNUMBER
        info["ev"] = math.log(n * n / info["exposure"], 2) - math.log(info["iso"] / 100.0, 2)
        info["source"] = "exif"
    elif info["lux"] is not None:
        info["ev"] = math.log(max(info["lux"], 0.3) / 2.5, 2)
        info["source"] = "sensor"
    return info


def capture_info(path, lux=None, im=None):
    """How a photo was taken: {"iso", "exposure" (seconds), "fnumber", "flash" (True/False/None),
    "lux" (light sensor, if given), "ev" (scene brightness, EV at ISO 100), "source"}.
    When `im` is an already-open Image, its EXIF is read without reopening the file.
    Unknown values are None; it never raises."""
    info = {"iso": None, "exposure": None, "fnumber": None, "flash": None, "lux": None, "ev": None,
            "source": "none"}
    try:
        if im is not None:
            tags = _exif_tags(im)
        else:
            with Image.open(to_path(path)) as opened:
                tags = _exif_tags(opened)
    except Exception:
        tags = {}
    info["iso"] = _num(tags.get(TAG_ISO))
    info["exposure"] = _num(tags.get(TAG_EXPOSURE_TIME))
    info["fnumber"] = _num(tags.get(TAG_FNUMBER))
    flash = tags.get(TAG_FLASH)
    if isinstance(flash, int):
        info["flash"] = bool(flash & 1)
    try:
        if lux is not None and float(lux) >= 0:
            info["lux"] = float(lux)
    except (TypeError, ValueError):
        pass
    if info["iso"] and info["exposure"]:
        n = info["fnumber"] or DEFAULT_FNUMBER
        info["ev"] = math.log(n * n / info["exposure"], 2) - math.log(info["iso"] / 100.0, 2)
        info["source"] = "exif"
    elif info["lux"] is not None:
        info["ev"] = math.log(max(info["lux"], 0.3) / 2.5, 2)
        info["source"] = "sensor"
    return info


def light_scene(info, a=None):
    """The light the photo was taken in, one of LIGHT_SCENES, or None when unknown.
    A high ISO alone already says it was dark (the camera needed the gain)."""
    info = info or {}
    ev, iso = info.get("ev"), info.get("iso")
    if ev is None:
        if iso is None:
            return None
        ev = 99.0                       # no exposure time: decide from the ISO alone
    if ev < 3 or (iso and iso >= 1600):
        return "night"
    if ev < 5.5 or (iso and iso >= 640):
        return "dim"
    if ev < 9:
        return "indoor"
    if ev < 13:
        return "daylight"
    return "sun"


def is_backlit(a, scene):
    """Bright background and a dark subject: many very dark AND many very bright pixels
    (the camera exposed for the bright part). Not at night (lamps in the dark look the same)."""
    if scene in ("night", "dim"):
        return False
    return a["dark"] > 0.18 and a["bright"] > 0.08 and 0.2 < a["mean"] < 0.6


def _adapt_to_light(s, a, info, scene, backlit):
    """Adjust the picture-based settings to the light (see LIGHT_SCENES)."""
    s = dict(s)
    iso = info.get("iso")
    has_face = a.get("skin_fraction", 0) > 0.03
    skin_mean = a.get("skin_mean", 0)
    if scene == "night":
        s["denoise"] = min(max(s["denoise"], _ramp(iso or 1600, 1600, 6400, 55, 65)), 65)
        s["sharpen"] = min(s["sharpen"], 25)
        s["local"] = min(s["local"], 25)
        s["color"] = min(s["color"], 20)
        # As bright as portraits. Before 0.4.0-22 only photos with a face were lifted this much
        # (caps 35 / 30 otherwise), so selfies came out brighter than back-camera photos.
        exp_cap = 50
        shadow_cap = 45
        if has_face and skin_mean < 0.35:            # a dark face: a little more
            exp_cap = max(exp_cap, min(55, 35 + int(_ramp(0.40 - skin_mean, 0.05, 0.20, 5, 20))))
            shadow_cap = 50
        s["shadows"] = min(s["shadows"], shadow_cap)
        s["exposure"] = min(s["exposure"], exp_cap)
        s["contrast"] = min(s["contrast"], 35)
        s["wb"] = min(s["wb"], 30)
    elif scene == "dim":
        # a dim kitchen (2026-11-11) was as grainy as a night street: same treatment, a bit milder.
        # Cap at 65 like night: higher values blurred the details out.
        s["denoise"] = min(max(s["denoise"], _ramp(iso or 800, 640, 1600, 50, 65)), 65)
        s["sharpen"] = min(s["sharpen"], 25)
        s["local"] = min(s["local"], 30)
        s["color"] = min(s["color"], 25)
        exp_cap = 55                                 # as for portraits (before 0.4.0-22: 45 / 40)
        shadow_cap = 50
        s["shadows"] = min(max(s["shadows"], 25), shadow_cap)
        s["exposure"] = min(s["exposure"], exp_cap)
        s["contrast"] = min(s["contrast"], 42)
        # lamp light in dim rooms: correct the orange (stronger than before)
        s["wb"] = max(s["wb"], _ramp(a["warmth"], 0.05, 0.25, 10, 60))
    if scene in ("night", "dim") and a["dark"] > 0.6:
        # Mostly black frame lit by one lamp (2026-11-20): grey-world has nothing grey to balance
        # on and turned the blacks purple. Keep the lamp's colour.
        # shortcut: 0.6 is a guess from one photo, tune with more dark-room shots
        s["wb"] = min(s["wb"], 10)
    if scene == "indoor":
        # Lamp light makes everything orange; the camera's white balance leaves some of it.
        # Stronger auto WB: start correcting at a lower warmth threshold.
        s["wb"] = max(s["wb"], _ramp(a["warmth"], 0.05, 0.20, 10, 75))
        s["denoise"] = max(s["denoise"], 20)
    elif scene == "daylight":
        s["denoise"] = min(s["denoise"], 25)     # low ISO: "noise" in leaves and grass is detail
        s["sharpen"] = max(s["sharpen"], 40)
    elif scene == "sun":
        s["denoise"] = min(s["denoise"], 15)
        s["sharpen"] = max(s["sharpen"], 40)
        s["highlights"] = max(s["highlights"], 30)   # bright skies and white walls
        s["contrast"] = min(s["contrast"], 55)       # sunlight is contrasty already
        s["wb"] = min(s["wb"], 30)                   # keep warm evening and golden light
        s["color"] = min(s["color"], 45)
    if backlit:
        s["shadows"] = max(s["shadows"], 55)         # the subject in front of the bright part
        s["highlights"] = max(s["highlights"], 45)
        s["local"] = max(s["local"], 35)
    if info.get("flash"):
        s["wb"] = min(s["wb"], 20)                   # flash light is neutral
        s["shadows"] = min(s["shadows"], 30)         # lifting the dark background shows noise
    return s


def resolve(img, settings, info=None):
    """The real settings: computed from the photo when the 'auto' flag is set."""
    return auto_settings(img, info) if settings.get("auto") else settings


# --------------------------------------------------------------------------- files

def _open_oriented(path, max_side=None):
    """Open an image, upright according to EXIF. Returns (image, exif bytes or None, icc or None,
    raw EXIF tags dict). The tags dict is suitable for capture_info(im=...)."""
    with Image.open(path) as im:
        if max_side and im.format == "JPEG":
            im.draft("RGB", (max_side * 2, max_side * 2))  # decode at 1/2, 1/4 or 1/8 size: much faster
        icc = im.info.get("icc_profile")
        tags = _exif_tags(im)
        try:
            upright = ImageOps.exif_transpose(im)  # must run before the EXIF block is edited
        except Exception:
            upright = im
        exif = None
        try:
            ex = im.getexif()  # the same object exif_transpose just read
            if ex:
                ex[EXIF_ORIENTATION] = 1  # the pixels are upright now: do not rotate twice
                exif = ex.tobytes()
        except Exception:
            exif = None
        return upright.convert("RGB"), exif, icc, tags  # convert() loads the pixels before the file closes


_name_lock = threading.Lock()


def _reserve(directory, name):
    """Create an empty, not yet used output file and return its path. Safe across threads:
    two photos with the same name (from different folders) never get the same output."""
    base, ext = os.path.splitext(name)
    candidate = os.path.join(directory, name)
    n = 2
    with _name_lock:
        while True:
            try:
                os.close(os.open(candidate, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644))
                return candidate
            except FileExistsError:
                candidate = os.path.join(directory, "%s_%d%s" % (base, n, ext))
                n += 1


def read_metadata(path):
    """EXIF (orientation set to upright) and ICC profile of a photo, without decoding it."""
    exif = icc = None
    with Image.open(path) as im:
        icc = im.info.get("icc_profile")
        try:
            ex = im.getexif()
            if ex:
                ex[EXIF_ORIENTATION] = 1
                exif = ex.tobytes()
        except Exception:
            exif = None
    return exif, icc


def process_file(src, out_dir, settings, quality=JPEG_QUALITY, lux=None):
    """Enhance one photo at full size and save it as JPEG. Returns the new path.
    `lux`: the light sensor at the moment of the shot, if known (smart auto only)."""
    src = to_path(src)
    img, exif, icc, tags = _open_oriented(src)
    info = _capture_info_from_tags(tags, lux) if settings.get("auto") else None
    out = enhance(img, resolve(img, settings, info))
    del img
    return save_result(out, src, out_dir, exif, icc, quality)


def save_result(out, src, out_dir, exif, icc, quality=JPEG_QUALITY):
    """Save an enhanced (upright) image next to the name of `src` as <name>_enhanced.jpg in
    `out_dir`, with the original's EXIF and ICC, atomically. Returns the new path."""
    os.makedirs(out_dir, exist_ok=True)
    stem = os.path.splitext(os.path.basename(src))[0]
    dst = _reserve(out_dir, stem + SUFFIX + ".jpg")
    kwargs = {"quality": quality}
    if exif:
        kwargs["exif"] = exif
    if icc:
        kwargs["icc_profile"] = icc
    try:
        out.save(dst + ".part", "JPEG", **kwargs)
        os.replace(dst + ".part", dst)  # never leave a half-written photo behind
    except Exception:
        for leftover in (dst + ".part", dst):
            try:
                os.remove(leftover)
            except OSError:
                pass
        raise
    try:  # keep the shooting time for galleries that sort by file date
        st = os.stat(src)
        os.utime(dst, (st.st_atime, st.st_mtime))
    except OSError:
        pass
    return dst


# --------------------------------------------------------------------------- batch (PyOtherSide)

_cancel = threading.Event()
_worker = None

MAX_WORKERS = 3
BYTES_PER_PHOTO = 400 * 1024 * 1024   # peak memory of one 12 MP photo in the pipeline (generous)


def _mem_available():
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) * 1024
    except (OSError, ValueError, IndexError):
        pass
    return None


def workers_for(total):
    """How many photos to process at once: Pillow does its heavy work outside the GIL, so
    threads use several CPU cores. Limited by cores and by free memory."""
    n = min(MAX_WORKERS, os.cpu_count() or 1, max(1, total))
    avail = _mem_available()
    if avail is not None:
        n = min(n, int(avail * 0.6) // BYTES_PER_PHOTO)
    return max(1, n)


def _run(paths, settings, out_dir, workers):
    from concurrent.futures import ThreadPoolExecutor

    lock = threading.Lock()
    state = {"finished": 0, "saved": 0}
    errors = []
    total = len(paths)

    def one(path):
        if _cancel.is_set():
            return
        name = os.path.basename(to_path(path))
        with lock:
            _send("progress", state["finished"], total, name)
        try:
            process_file(path, out_dir, settings)
            ok = True
        except Exception as exc:  # one broken file must not stop the batch
            ok = False
            error = "%s: %s" % (name, exc)
        with lock:
            state["finished"] += 1
            if ok:
                state["saved"] += 1
            else:
                errors.append(error)
            _send("progress", state["finished"], total, name)

    with ThreadPoolExecutor(max_workers=workers) as pool:
        list(pool.map(one, paths))
    cancelled = _cancel.is_set() and state["finished"] < total
    _send("finished", state["saved"], errors, cancelled, out_dir)


def start_batch(paths, settings, out_dir, workers=None):
    """Process in background threads; progress/finished arrive as PyOtherSide signals.
    Returns how many photos are processed at once (0 if a batch is already running)."""
    global _worker
    if _worker is not None and _worker.is_alive():
        return 0
    _cancel.clear()
    paths = list(paths)
    out_dir = to_path(out_dir) if out_dir else default_out_dir()
    workers = workers or workers_for(len(paths))
    _worker = threading.Thread(target=_run, args=(paths, dict(settings), out_dir, workers), daemon=True)
    _worker.start()
    return workers


def cancel():
    _cancel.set()


# --------------------------------------------------------------------------- live preview

_preview_src = {"path": None, "img": None, "before": None, "auto": None}


def make_preview(src, settings, cache_dir, token):
    """Render a small before/after pair. Returns [before_path, after_path, settings_used]."""
    src = to_path(src)
    cache_dir = to_path(cache_dir) if cache_dir else default_cache_dir()
    os.makedirs(cache_dir, exist_ok=True)
    if _preview_src["path"] != src:
        img, _, _, _ = _open_oriented(src, PREVIEW_SIZE)
        img.thumbnail((PREVIEW_SIZE, PREVIEW_SIZE), LANCZOS)
        _preview_src.update(path=src, img=img, before=None, auto=None)
    img = _preview_src["img"]
    if settings.get("auto"):
        if _preview_src["auto"] is None:  # measured once per photo, at full resolution
            full, _, _, tags = _open_oriented(src)
            _preview_src["auto"] = auto_settings(full, _capture_info_from_tags(tags))
            del full
        used = dict(_preview_src["auto"])
    else:
        used = {k: int(settings.get(k, 0) or 0) for k in KEYS}
    after = os.path.join(cache_dir, "preview_after_%s.jpg" % token)
    enhance(img, used).save(after, "JPEG", quality=88)
    before = _preview_src["before"]
    if before is None or not os.path.exists(before):
        before = os.path.join(cache_dir, "preview_before_%s.jpg" % abs(hash(src)))
        img.save(before, "JPEG", quality=88)
        _preview_src["before"] = before
    for name in os.listdir(cache_dir):  # drop the renders of older tokens
        full = os.path.join(cache_dir, name)
        if name.startswith("preview_after_") and full != after:
            try:
                os.remove(full)
            except OSError:
                pass
    return [before, after, used]


# --------------------------------------------------------------------------- command line

if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description="Auto-enhance photos")
    ap.add_argument("files", nargs="+")
    ap.add_argument("-o", "--out", default="enhanced")
    for key in KEYS:
        ap.add_argument("--" + key, type=int, default=0, help="0-100")
    ap.add_argument("--auto", action="store_true", help="smart auto: choose the effects per photo")
    args = ap.parse_args()
    cfg = {k: getattr(args, k) for k in KEYS}
    cfg["auto"] = args.auto
    for f in args.files:
        print(process_file(f, args.out, cfg))
