"""FastShot background processing: enhance photos after they were taken, one at a time,
at low priority, so the camera never waits for the image processing.

Enhancement runs on the graphics chip when the app allows it (set_options gpu=True): Python
measures the photo and sends the numbers to QML (signal "gpu_job"), the GPU applies the effects
and writes the result to a file, and Python saves it as JPEG with the original's EXIF. If the
app is in the background, or the GPU result is unusable, the CPU path (enhance.py) is used.

Also here: the saved queue (survives closing the app), "only while charging", best-of-N,
stack-N (noise reduction by averaging aligned frames) and moving burst photos.

enhance.py is a copy of harbour-photoenhance/python/enhance.py (tools/sync-engine.py keeps it in sync).
"""

import json
import os
import queue
import tempfile
import threading
import time

try:  # present when running inside PyOtherSide
    import pyotherside
except ImportError:  # tests
    pyotherside = None

# The same presets as in Photo Enhance
PRESETS = {
    "auto": {"auto": True},
    "lowlight": dict(exposure=80, contrast=40, shadows=55, highlights=20, local=25, wb=40, color=25,
                     denoise=60, sharpen=25),
    "vivid": dict(exposure=40, contrast=60, shadows=25, highlights=30, local=50, wb=30, color=70,
                  denoise=15, sharpen=45),
    "subtle": dict(exposure=30, contrast=25, shadows=15, highlights=12, local=15, wb=20, color=15,
                   denoise=10, sharpen=20),
}
TMP_DIR = ".fastshot-tmp"       # hidden, so the media index ignores half-done files
BURST_DIR = ".fastshot-burst"   # bursts are saved here and moved to the camera folder afterwards
QUEUE_FILE = ".fastshot-queue.json"
GPU_TIMEOUT = 30.0
CHARGING_POLL = 15.0

_jobs = queue.Queue()
_lock = threading.Lock()
_state = {"pending": 0, "resume_at": 0.0, "gpu_broken": False, "next_gpu_id": 1}
_options = {"gpu": False, "gpu_available": False, "charging_only": False}
_saved = []                     # [path, mode, keep, lux] of every unfinished job, in order
_gpu_waits = {}                 # gpu job id -> {"event": Event, "file": str, "reason": str}
_threads = []
_NUM_WORKERS = 2


class GpuUnavailable(Exception):
    """The GPU could not do this job now (app in the background): use the CPU, try again later."""


class GpuFailed(Exception):
    """The GPU result is unusable on this phone: stop using the GPU."""


# --------------------------------------------------------------------------- helpers

def _engine():
    """The image engine, imported on first use: Pillow is slow to load and the camera
    does not need it to start."""
    import enhance
    return enhance


def _send(*args):
    if pyotherside is not None:
        pyotherside.send(*args)


def warm_up():
    """Import the image engine (Pillow) in the background so the first photo doesn't wait."""
    threading.Thread(target=_engine, daemon=True).start()


def _plain(path):
    path = str(path)
    if path.startswith("file://"):
        from urllib.parse import unquote
        path = unquote(path[7:])
    return path


def camera_dir():
    """Where photos are saved: ~/Pictures/Camera, like the Sailfish camera."""
    path = os.path.join(os.path.expanduser("~"), "Pictures", "Camera")
    os.makedirs(path, exist_ok=True)
    return path


def burst_dir():
    """Hidden folder for burst photos (the media index skips hidden folders)."""
    path = os.path.join(camera_dir(), BURST_DIR)
    os.makedirs(path, exist_ok=True)
    return path


def image_size(path):
    """Width and height of a saved photo (reads only the file header)."""
    from PIL import Image
    with Image.open(_plain(path)) as im:
        return [im.width, im.height]


TAG_SUBJECT_DISTANCE = 0x9206           # metres; 0 = unknown, 0xFFFFFFFF = infinity
TAG_SUBJECT_DISTANCE_RANGE = 0xA40C     # 1 macro, 2 close view, 3 distant view
FAR = 100000.0                          # stands for "infinity" (QML shows it as such)


def focus_distance(path):
    """What the camera wrote into a photo about the distance it focused at:
    [metres (-1 = not written, FAR = infinity), range (0 = not written, 1 macro, 2 close, 3 distant)].
    Never raises."""
    try:
        from PIL import Image
        eng = _engine()
        with Image.open(_plain(path)) as im:
            tags = eng._exif_tags(im)
        metres = eng._num(tags.get(TAG_SUBJECT_DISTANCE))
        metres = -1 if metres is None else round(min(metres, FAR), 2)
        zone = tags.get(TAG_SUBJECT_DISTANCE_RANGE)
        zone = zone if isinstance(zone, int) and 1 <= zone <= 3 else 0
        return [metres, zone]
    except Exception:
        return [-1, 0]


def qr_frame_path():
    """Where QML saves viewfinder frames for the QR scanner (like the GPU job files)."""
    return os.path.join(tempfile.gettempdir(), "fastshot-qr.bmp")


def qr_photo_dir():
    """Where photos taken only for the QR scanner go (deleted after reading)."""
    return tempfile.gettempdir()


def scan_qr(path, remove=True):
    """Read a QR code in a picture: [text ('' = none found), mean brightness 0..255 (-1 =
    unreadable file; about 0 = the frame came out black)]. Never raises."""
    path = _plain(path)
    try:
        from PIL import Image, ImageStat
        import qrscan
        with Image.open(path) as im:
            if im.format == "JPEG":
                im.draft("L", (qrscan.MAX_SIDE, qrscan.MAX_SIDE))
            gray = im.convert("L")
        mean = ImageStat.Stat(gray).mean[0]
        text = qrscan.decode_image(gray) if mean >= 3 else None
        return [text or "", round(mean, 1)]
    except Exception:
        return ["", -1]
    finally:
        if remove:
            try:
                os.remove(path)
            except OSError:
                pass


def delete_photo(path):
    """Delete a photo from the gallery. Returns [deleted, newest photo left in its folder ('' =
    none)], so the camera's corner thumbnail can move on to a photo that still exists."""
    path = _plain(path)
    try:
        os.remove(path)
        ok = True
    except OSError:
        ok = False
    folder = os.path.dirname(path)
    newest, newest_time = "", -1.0
    try:
        for name in os.listdir(folder):
            if not name.lower().endswith((".jpg", ".jpeg")):
                continue
            full = os.path.join(folder, name)
            t = os.path.getmtime(full)
            if t > newest_time:
                newest, newest_time = full, t
    except OSError:
        pass
    return [ok, newest]


def pending():
    with _lock:
        return _state["pending"]


def set_options(options):
    """gpu: enhance on the GPU; gpu_available: the app is in front (QML can render);
    charging_only: enhance only while the phone is charging."""
    with _lock:
        for key in ("gpu", "gpu_available", "charging_only"):
            if key in options:
                _options[key] = bool(options[key])
        return dict(_options, gpu_broken=_state["gpu_broken"])


def hold(seconds):
    """Do not start enhancing the next photo for `seconds` (0 = go on now). The camera calls
    this on every shot, so enhancement does not take CPU time away from a burst. A photo that
    is already being enhanced is finished."""
    with _lock:
        _state["resume_at"] = time.monotonic() + max(0.0, float(seconds))


def _wait_for_resume():
    while True:
        with _lock:
            left = _state["resume_at"] - time.monotonic()
        if left <= 0:
            return
        time.sleep(min(left, 0.25))


def charging():
    """True when the phone is on a charger (or full while plugged in)."""
    base = "/sys/class/power_supply"
    try:
        names = os.listdir(base)
    except OSError:
        return False
    for name in names:
        folder = os.path.join(base, name)
        try:
            with open(os.path.join(folder, "type")) as f:
                kind = f.read().strip()
        except OSError:
            kind = ""
        if kind == "Battery":
            try:
                with open(os.path.join(folder, "status")) as f:
                    if f.read().strip() in ("Charging", "Full"):
                        return True
            except OSError:
                pass
        elif kind in ("USB", "Mains", "Wireless", "USB_PD", "USB_DCP", "USB_CDP"):
            try:
                with open(os.path.join(folder, "online")) as f:
                    if f.read().strip() == "1":
                        return True
            except OSError:
                pass
    return False


def _wait_for_charging():
    announced = False
    while True:
        with _lock:
            only = _options["charging_only"]
        if not only or charging():
            if announced:
                _send("waiting_for_charger", False)
            return
        if not announced:
            _send("waiting_for_charger", True)
            announced = True
        time.sleep(CHARGING_POLL)


def _unique(directory, name):
    base, ext = os.path.splitext(name)
    candidate = os.path.join(directory, name)
    n = 2
    while os.path.exists(candidate):
        candidate = os.path.join(directory, "%s_%d%s" % (base, n, ext))
        n += 1
    return candidate


# --------------------------------------------------------------------------- saved queue

QUEUE_DIR = None    # where the saved queue lives; None = the camera folder (tests set a temp dir)


def _queue_file():
    return os.path.join(QUEUE_DIR or camera_dir(), QUEUE_FILE)


def _write_saved():
    """Called with _lock held."""
    path = _queue_file()
    try:
        if _saved:
            with open(path + ".part", "w") as f:
                json.dump(_saved, f)
            os.replace(path + ".part", path)
        elif os.path.exists(path):
            os.remove(path)
    except OSError:
        pass


def resume_saved():
    """Queue again the photos that were still waiting when the app was closed. Returns how many."""
    try:
        with open(_queue_file()) as f:
            entries = json.load(f)
    except (OSError, ValueError):
        return 0
    with _lock:
        known = set(e[0] for e in _saved)
    count = 0
    for entry in entries:
        try:
            path, mode, keep = entry[0], entry[1], bool(entry[2])
        except (IndexError, TypeError):
            continue
        lux = entry[3] if len(entry) > 3 else None    # queues saved before 0.4.0 have no lux
        if path in known or not os.path.exists(path):
            continue
        queue_photo(path, mode, keep, lux)
        count += 1
    if count == 0:
        with _lock:
            _write_saved()       # drop entries of photos that are gone
    return count


# --------------------------------------------------------------------------- enhancement

def gpu_done(job_id, file, reason=""):
    """QML reports a GPU job: the file it wrote, or "" and why not."""
    with _lock:
        wait = _gpu_waits.get(int(job_id))
    if wait is None:
        return False
    wait["file"] = str(file or "")
    wait["reason"] = str(reason or "")
    wait["event"].set()
    return True


def _auto(enh, full, path, lux, tags=None):
    """Smart auto for one photo, adapted to the light it was taken in; logs the choice."""
    info = enh._capture_info_from_tags(tags, lux) if tags else enh.capture_info(path, lux)
    resolved, scene, backlit = enh.auto_with_scene(full, info)
    ev = info["ev"]
    print("FastShot light: %s -> %s%s (ISO %s, %s s, EV %s from %s, sensor %s lux)" % (
        os.path.basename(path), scene or "unknown", ", backlit" if backlit else "",
        info["iso"], info["exposure"], "%.1f" % ev if ev is not None else "?", info["source"],
        info["lux"]))
    _send("light", os.path.basename(path), scene or "", bool(backlit),
          round(ev, 1) if ev is not None else -99, info["source"])
    return resolved


# From this much noise reduction on, the processor does the photo even when the graphics chip is
# on: the shader only approximates the noise filter, and on the phone it left a dim kitchen as
# grainy as the original while the processor's filter cleaned it (photos of 2026-11-11).
NOISY_DENOISE = 45


def _produce_gpu(enh, path, mode, out_dir, resolved, full=None):
    if full is not None:
        params = enh.gpu_params(full, resolved)       # measured at full resolution
    else:
        small, _, _, _ = enh._open_oriented(path, 512)
        params = enh.gpu_params(small, resolved)
    params["mode"] = mode
    params["settings"] = {k: int(v) for k, v in resolved.items() if k in enh.KEYS}

    with _lock:
        job_id = _state["next_gpu_id"]
        _state["next_gpu_id"] += 1
        wait = {"event": threading.Event(), "file": "", "reason": ""}
        _gpu_waits[job_id] = wait
    tmp = os.path.join(tempfile.gettempdir(), "fastshot-gpu-%d.bmp" % job_id)
    try:
        _send("gpu_job", job_id, path, params, tmp)
        if not wait["event"].wait(GPU_TIMEOUT):
            raise GpuUnavailable("no answer from the GPU renderer")
        if not wait["file"]:
            if wait["reason"] == "inactive":
                raise GpuUnavailable("app in the background")
            raise GpuFailed(wait["reason"] or "the GPU renderer failed")
        from PIL import Image
        with Image.open(wait["file"]) as im:
            out = im.convert("RGB")
        if max(hi for _, hi in out.getextrema()) < 8:
            raise GpuFailed("the GPU result is black")
        exif, icc = enh.read_metadata(path)
        return enh.save_result(out, path, out_dir, exif, icc)
    finally:
        with _lock:
            _gpu_waits.pop(job_id, None)
        for leftover in (tmp, wait.get("file")):
            if leftover:
                try:
                    os.remove(leftover)
                except OSError:
                    pass


def _produce(path, mode, out_dir, lux=None):
    """Enhance `path` into out_dir/<name>_enhanced.jpg, on the GPU when possible."""
    enh = _engine()
    with _lock:
        use_gpu = _options["gpu"] and _options["gpu_available"] and not _state["gpu_broken"]
    settings = PRESETS[mode]
    full = exif = icc = tags = None
    if settings.get("auto"):
        full, exif, icc, tags = enh._open_oriented(path)   # noise is measured at full resolution
        resolved = _auto(enh, full, path, lux, tags)
    else:
        resolved = settings
    if use_gpu and resolved.get("denoise", 0) >= NOISY_DENOISE:
        print("FastShot: %s is noisy (denoise %s): enhanced on the processor" % (
            os.path.basename(path), resolved.get("denoise")))
        _send("noisy_on_cpu", os.path.basename(path))
        use_gpu = False
    if use_gpu:
        try:
            out = _produce_gpu(enh, path, mode, out_dir, resolved, full)
            _send("gpu_used", os.path.basename(path))
            return out
        except GpuUnavailable:
            pass                                 # the CPU does this one
        except GpuFailed as exc:
            with _lock:
                _state["gpu_broken"] = True
            _send("gpu_broken", str(exc))
        except Exception as exc:  # unexpected: do not lose the photo
            _send("gpu_broken", "unexpected: %s" % exc)
            with _lock:
                _state["gpu_broken"] = True
    if full is None:
        full, exif, icc, _ = enh._open_oriented(path)
    out = enh.enhance(full, resolved)
    del full
    return enh.save_result(out, path, out_dir, exif, icc)


def enhance_photo(path, mode, keep_original=True, lux=None):
    """Enhance one saved photo. Keeps the original and writes <name>_enhanced.jpg next to it,
    or replaces the original. Returns the path of the enhanced photo.
    `lux`: the light sensor at the moment of the shot (smart auto falls back on it without EXIF)."""
    folder = os.path.dirname(path)
    if keep_original:
        return _produce(path, mode, folder, lux)
    tmp = os.path.join(folder, TMP_DIR)
    os.makedirs(tmp, exist_ok=True)
    try:
        st = os.stat(path)
        out = _produce(path, mode, tmp, lux)
        os.replace(out, path)
        # one second newer than the original: the gallery keeps its order but redraws the thumbnail
        os.utime(path, (time.time(), st.st_mtime + 1))
        return path
    finally:
        try:
            os.rmdir(tmp)
        except OSError:
            pass


def _loop():
    try:
        os.nice(10)  # on Linux this lowers only this thread: the camera and the UI stay fast
    except (AttributeError, OSError):
        pass
    while True:
        path, mode, keep, lux = _jobs.get()
        _wait_for_charging()
        _wait_for_resume()
        try:
            if not os.path.exists(path):  # deleted in the gallery while it waited
                continue
            _send("enhanced", path, enhance_photo(path, mode, keep, lux))
        except Exception as exc:  # a failed photo must not stop the queue
            _send("failed", os.path.basename(path), str(exc))
        finally:
            with _lock:
                _state["pending"] -= 1
                left = _state["pending"]
                for i, entry in enumerate(_saved):
                    if entry[0] == path:
                        del _saved[i]
                        break
                _write_saved()
            _send("queue", left)


def queue_photo(path, mode, keep_original=True, lux=None):
    """Queue a photo that was just saved. Returns how many photos are waiting.
    `lux`: the light sensor reading at the shot (None or negative: no reading)."""
    if mode not in PRESETS:
        return pending()
    path = _plain(path)
    try:
        lux = float(lux) if lux is not None and float(lux) >= 0 else None
    except (TypeError, ValueError):
        lux = None
    with _lock:
        _state["pending"] += 1
        left = _state["pending"]
        _saved.append([path, mode, bool(keep_original), lux])
        _write_saved()
        _ensure_workers()
    _jobs.put((path, mode, bool(keep_original), lux))
    _send("queue", left)
    return left


def _ensure_workers():
    """Start worker threads up to _NUM_WORKERS.  Called with _lock held."""
    global _threads
    _threads = [t for t in _threads if t.is_alive()]
    while len(_threads) < _NUM_WORKERS:
        t = threading.Thread(target=_loop, daemon=True)
        t.start()
        _threads.append(t)


# --------------------------------------------------------------------------- burst and best-of-3

def sharpness(path):
    """How sharp a photo is: variance of the edges in the middle of a reduced copy."""
    from PIL import Image, ImageFilter, ImageStat
    with Image.open(_plain(path)) as im:
        im.draft("L", (1200, 1200))
        gray = im.convert("L")
    w, h = gray.size
    centre = gray.crop((w // 4, h // 4, w - w // 4, h - h // 4))
    return ImageStat.Stat(centre.filter(ImageFilter.FIND_EDGES)).var[0]


def _move(path, dest_dir):
    if os.path.dirname(os.path.abspath(path)) == os.path.abspath(dest_dir):
        return path
    target = _unique(dest_dir, os.path.basename(path))
    os.replace(path, target)
    return target


def publish(paths, dest_dir=None):
    """Move burst photos from the hidden folder to the camera folder. Returns the new paths."""
    dest_dir = _plain(dest_dir) if dest_dir else camera_dir()
    out = []
    for p in paths:
        p = _plain(p)
        if os.path.exists(p):
            out.append(_move(p, dest_dir))
    return out


def best_of(paths, dest_dir=None):
    """Keep the sharpest of a few photos of the same moment, delete the others, and put the kept
    one in the camera folder. Returns [kept path, [sharpness of each]]."""
    dest_dir = _plain(dest_dir) if dest_dir else camera_dir()
    existing = [_plain(p) for p in paths if os.path.exists(_plain(p))]
    if not existing:
        return ["", []]
    scores = []
    for p in existing:
        try:
            scores.append(sharpness(p))
        except Exception:
            scores.append(-1.0)
    best = existing[scores.index(max(scores))]
    for p in existing:
        if p != best:
            try:
                os.remove(p)
            except OSError:
                pass
    return [_move(best, dest_dir), [round(s, 1) for s in scores]]


def _find_offset(ref_small, img_small, search=8):
    """Find (dx, dy) that best aligns img_small to ref_small (both grayscale, ~250 px wide)."""
    from PIL import ImageChops, ImageStat
    sw, sh = ref_small.size
    cx, cy = sw // 4, sh // 4
    ref_patch = ref_small.crop((cx, cy, sw - cx, sh - cy))
    best_dx, best_dy, best_score = 0, 0, float("inf")
    for dy in range(-search, search + 1):
        for dx in range(-search, search + 1):
            shifted = ImageChops.offset(img_small, dx, dy)
            patch = shifted.crop((cx, cy, sw - cx, sh - cy))
            score = ImageStat.Stat(ImageChops.difference(ref_patch, patch)).mean[0]
            if score < best_score:
                best_score = score
                best_dx, best_dy = dx, dy
    return best_dx, best_dy


def _align_and_open(existing):
    """Load frames, align to first frame. Returns (frames list, exif_bytes, ref_size, scale)."""
    from PIL import Image, ImageChops
    ref = Image.open(existing[0])
    exif_bytes = ref.info.get("exif")
    ref_rgb = ref.convert("RGB")
    ref.close()
    w, h = ref_rgb.size
    scale = max(1, min(w, h) // 200)
    ref_small = ref_rgb.resize((w // scale, h // scale), Image.BOX).convert("L")
    frames = [ref_rgb]
    for path in existing[1:]:
        im = Image.open(path)
        img = im.convert("RGB")
        im.close()
        if img.size != (w, h):
            img = img.resize((w, h), Image.LANCZOS)
        img_small = img.resize(ref_small.size, Image.BOX).convert("L")
        dx, dy = _find_offset(ref_small, img_small)
        fdx, fdy = dx * scale, dy * scale
        if fdx or fdy:
            aligned = ImageChops.offset(img, fdx, fdy)
            img.close()
            img = aligned
        frames.append(img)
    return frames, exif_bytes, (w, h), scale


def _blend_frames(frames):
    """Running-average blend of a list of RGB images (same size)."""
    from PIL import Image
    result = frames[0]
    for i in range(1, len(frames)):
        new = Image.blend(result, frames[i], 1.0 / (i + 1))
        if i > 0:
            result.close()
        result = new
        frames[i].close()
    return result


def stack_photos(paths, dest_dir=None):
    """Average-stack photos with alignment to reduce noise. Deletes the originals, saves the
    result to dest_dir.  Returns [result_path, frame_count]."""
    dest_dir = _plain(dest_dir) if dest_dir else camera_dir()
    existing = [_plain(p) for p in paths if os.path.exists(_plain(p))]
    if not existing:
        return ["", 0]
    if len(existing) == 1:
        return [_move(existing[0], dest_dir), 1]

    frames, exif_bytes, _, _ = _align_and_open(existing)
    result = _blend_frames(frames)

    out_path = _unique(dest_dir, os.path.basename(existing[0]))
    save_kw = {"quality": 92}
    if exif_bytes:
        save_kw["exif"] = exif_bytes
    result.save(out_path, "JPEG", **save_kw)
    result.close()

    for p in existing:
        try:
            os.remove(p)
        except OSError:
            pass
    return [out_path, len(existing)]


def superres_photos(paths, dest_dir=None):
    """Stack frames at 2x resolution for super-resolution. Returns [result_path, frame_count]."""
    from PIL import Image
    dest_dir = _plain(dest_dir) if dest_dir else camera_dir()
    existing = [_plain(p) for p in paths if os.path.exists(_plain(p))]
    if not existing:
        return ["", 0]

    frames, exif_bytes, (w, h), _ = _align_and_open(existing)
    w2, h2 = w * 2, h * 2
    upscaled = []
    for f in frames:
        upscaled.append(f.resize((w2, h2), Image.LANCZOS))
        f.close()
    result = _blend_frames(upscaled)

    out_path = _unique(dest_dir, os.path.basename(existing[0]))
    save_kw = {"quality": 92}
    if exif_bytes:
        save_kw["exif"] = exif_bytes
    result.save(out_path, "JPEG", **save_kw)
    result.close()

    for p in existing:
        try:
            os.remove(p)
        except OSError:
            pass
    return [out_path, len(existing)]


def hdr_merge(paths, dest_dir=None):
    """Stack + enhance with local tone mapping for HDR-like output. Returns [path, count]."""
    from PIL import Image, ImageFilter
    dest_dir = _plain(dest_dir) if dest_dir else camera_dir()
    existing = [_plain(p) for p in paths if os.path.exists(_plain(p))]
    if not existing:
        return ["", 0]
    if len(existing) == 1:
        return [_move(existing[0], dest_dir), 1]

    frames, exif_bytes, _, _ = _align_and_open(existing)
    result = _blend_frames(frames)

    eng = _engine()
    info = eng.capture_info(existing[0])
    settings = eng.auto_settings(result, info)
    settings["tonemap"] = max(settings.get("tonemap", 0), 45)
    settings["_lens_correct"] = 1
    result = eng.enhance(result, settings)

    out_path = _unique(dest_dir, os.path.basename(existing[0]))
    save_kw = {"quality": 92}
    if exif_bytes:
        save_kw["exif"] = exif_bytes
    result.save(out_path, "JPEG", **save_kw)
    result.close()

    for p in existing:
        try:
            os.remove(p)
        except OSError:
            pass
    return [out_path, len(existing)]
