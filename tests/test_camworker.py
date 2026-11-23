"""Run with:  python -m unittest discover tests   (needs Pillow and numpy)"""
import os
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "python"))

import numpy as np
from PIL import Image, ImageStat

import camworker
import enhance


def dark_photo(path, w=600, h=400):
    rng = np.random.default_rng(2)
    x = np.linspace(0, 1, w)[None, :, None]
    base = (0.05 + 0.25 * x) * np.array([1.2, 1.0, 0.8]) + rng.normal(0, 0.02, (h, w, 3))
    Image.fromarray((np.clip(base, 0, 1) * 255).astype("uint8"), "RGB").save(path, "JPEG")


def lum(path):
    with Image.open(path) as im:
        return ImageStat.Stat(im.convert("L")).mean[0]


class CamWorkerTest(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.renderer = None            # fake QML GPU renderer: called for "gpu_job"

        def send(*a):
            self.events.append(a)
            if a[0] == "gpu_job" and self.renderer:
                self.renderer(*a[1:])

        camworker.pyotherside = type("P", (), {"send": staticmethod(send)})
        self.qdir = tempfile.mkdtemp()
        camworker.QUEUE_DIR = self.qdir         # never write into the real ~/Pictures/Camera
        camworker.set_options({"gpu": False, "gpu_available": False, "charging_only": False})
        camworker._state["gpu_broken"] = False

    def tearDown(self):
        camworker.pyotherside = None
        camworker.set_options({"gpu": False, "gpu_available": False, "charging_only": False})
        import shutil
        shutil.rmtree(self.qdir, ignore_errors=True)

    # what QML does for a GPU job, done here with the CPU engine and the numbers it was sent
    def cpu_renderer(self, job_id, src, params, out):
        img, _, _, _ = enhance._open_oriented(src)
        enhance.enhance(img, params["settings"]).save(out, "BMP")
        camworker.gpu_done(job_id, out)

    def black_renderer(self, job_id, src, params, out):
        Image.new("RGB", (64, 48)).save(out, "BMP")
        camworker.gpu_done(job_id, out)

    def test_gpu_path(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "G.jpg")
            dark_photo(src)
            self.renderer = self.cpu_renderer
            camworker.set_options({"gpu": True, "gpu_available": True})
            camworker.queue_photo(src, "auto")
            self.wait_idle()
            job = [e for e in self.events if e[0] == "gpu_job"][0]
            params = job[3]
            for key in ("gains", "lo", "hi", "gamma", "shadows", "highlights", "local", "color",
                        "denoise", "sharpen"):
                self.assertIn(key, params)
            self.assertTrue(any(e[0] == "gpu_used" for e in self.events))
            out = os.path.join(d, "G_enhanced.jpg")
            self.assertGreater(lum(out), lum(src) + 10)
            self.assertEqual(sorted(os.listdir(d)), ["G.jpg", "G_enhanced.jpg"])

    def test_gpu_black_falls_back_and_stops(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "B.jpg")
            dark_photo(src)
            self.renderer = self.black_renderer
            camworker.set_options({"gpu": True, "gpu_available": True})
            camworker.queue_photo(src, "vivid")
            self.wait_idle()
            self.assertTrue(any(e[0] == "gpu_broken" for e in self.events))
            self.assertGreater(lum(os.path.join(d, "B_enhanced.jpg")), 20)   # the CPU did it
            self.assertTrue(camworker.set_options({})["gpu_broken"])

    def test_gpu_in_background_uses_cpu(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "C.jpg")
            dark_photo(src)
            self.renderer = lambda job_id, *a: camworker.gpu_done(job_id, "", "inactive")
            camworker.set_options({"gpu": True, "gpu_available": True})
            camworker.queue_photo(src, "subtle")
            self.wait_idle()
            self.assertTrue(os.path.exists(os.path.join(d, "C_enhanced.jpg")))
            self.assertFalse(camworker.set_options({})["gpu_broken"])         # not given up

    def test_saved_queue_resumes(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "Q.jpg")
            dark_photo(src)
            camworker.hold(30)                       # keep it waiting, as if the app was closed
            camworker.queue_photo(src, "subtle")
            with open(os.path.join(self.qdir, camworker.QUEUE_FILE)) as f:
                self.assertIn("Q.jpg", f.read())
            # a new app start: the module state is gone, the file is not
            with camworker._lock:
                camworker._saved[:] = []
            self.assertEqual(camworker.resume_saved(), 1)
            camworker.hold(0)
            self.wait_idle()
            self.assertTrue(os.path.exists(os.path.join(d, "Q_enhanced.jpg")))
            self.assertFalse(os.path.exists(os.path.join(self.qdir, camworker.QUEUE_FILE)))

    def test_noisy_night_photo_goes_to_processor(self):
        from PIL.TiffImagePlugin import IFDRational
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "N.jpg")
            dark_photo(src)
            with Image.open(src) as im:
                img = im.copy()
            ex = Image.Exif()
            sub = ex.get_ifd(enhance.EXIF_IFD)
            sub[enhance.TAG_ISO] = 3200                      # night: strong noise reduction
            sub[enhance.TAG_EXPOSURE_TIME] = IFDRational(1, 15)
            img.save(src, "JPEG", exif=ex.tobytes())
            self.renderer = self.cpu_renderer
            camworker.set_options({"gpu": True, "gpu_available": True})
            camworker.queue_photo(src, "auto")
            self.wait_idle()
            self.assertFalse(any(e[0] == "gpu_job" for e in self.events))
            self.assertTrue(any(e[0] == "noisy_on_cpu" for e in self.events))
            self.assertTrue(os.path.exists(os.path.join(d, "N_enhanced.jpg")))
            self.assertFalse(camworker.set_options({})["gpu_broken"])     # the GPU stays usable

    def test_smart_auto_uses_light_sensor(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "L.jpg")
            dark_photo(src)                          # no exposure EXIF: the lux reading decides
            camworker.queue_photo(src, "auto", True, 150)
            self.wait_idle()
            light = [e for e in self.events if e[0] == "light"]
            self.assertEqual(light[0][1:3], ("L.jpg", "indoor"))
            self.assertEqual(light[0][5], "sensor")
            self.assertTrue(os.path.exists(os.path.join(d, "L_enhanced.jpg")))

    def test_saved_queue_keeps_lux_and_reads_old_files(self):
        import json
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "S.jpg")
            dark_photo(src)
            camworker.hold(30)
            camworker.queue_photo(src, "auto", True, -1)       # QML sends -1 without a reading
            camworker.queue_photo(src, "auto", True, 42.5)
            with open(os.path.join(self.qdir, camworker.QUEUE_FILE)) as f:
                saved = json.load(f)
            self.assertEqual([e[3] for e in saved], [None, 42.5])
            # a queue file written before 0.4.0: [path, mode, keep]
            with open(os.path.join(self.qdir, camworker.QUEUE_FILE), "w") as f:
                json.dump([[src, "subtle", True]], f)
            with camworker._lock:
                camworker._saved[:] = []
            self.assertEqual(camworker.resume_saved(), 1)
            camworker.hold(0)
            self.wait_idle()

    def test_charging_only_waits(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "W.jpg")
            dark_photo(src)
            camworker.CHARGING_POLL = 0.05
            plugged = {"on": False}
            real = camworker.charging
            camworker.charging = lambda: plugged["on"]
            try:
                camworker.set_options({"charging_only": True})
                camworker.queue_photo(src, "subtle")
                time.sleep(0.4)
                self.assertFalse(os.path.exists(os.path.join(d, "W_enhanced.jpg")))
                self.assertIn(("waiting_for_charger", True), self.events)
                plugged["on"] = True
                self.wait_idle()
                self.assertTrue(os.path.exists(os.path.join(d, "W_enhanced.jpg")))
            finally:
                camworker.charging = real
                camworker.CHARGING_POLL = 15.0

    def test_best_of_and_publish(self):
        with tempfile.TemporaryDirectory() as d:
            hidden = os.path.join(d, camworker.BURST_DIR)
            os.makedirs(hidden)
            sharp = os.path.join(hidden, "s.jpg")
            blurry = os.path.join(hidden, "b.jpg")
            rng = np.random.default_rng(5)
            detail = (rng.random((300, 400)) * 255).astype("uint8")
            Image.fromarray(detail).convert("RGB").save(sharp, "JPEG", quality=95)
            from PIL import ImageFilter
            Image.fromarray(detail).convert("RGB").filter(ImageFilter.GaussianBlur(4)).save(blurry, "JPEG")
            kept, scores = camworker.best_of([blurry, sharp], d)
            self.assertEqual(kept, os.path.join(d, "s.jpg"))
            self.assertEqual(len(scores), 2)
            self.assertEqual(os.listdir(hidden), [])                      # the blurry one is gone
            # publish moves burst photos without overwriting
            p1 = os.path.join(hidden, "s.jpg")
            Image.new("RGB", (8, 8)).save(p1, "JPEG")
            moved = camworker.publish([p1], d)
            self.assertEqual(moved, [os.path.join(d, "s_2.jpg")])

    def wait_idle(self):
        for _ in range(200):
            if camworker.pending() == 0:
                return
            time.sleep(0.05)
        self.fail("queue did not drain")

    def test_keep_original(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "IMG_1.jpg")
            dark_photo(src)
            before = lum(src)
            camworker.queue_photo("file://" + src, "auto", True)
            self.wait_idle()
            out = os.path.join(d, "IMG_1_enhanced.jpg")
            self.assertTrue(os.path.exists(out))
            self.assertEqual(lum(src), before)                   # original untouched
            self.assertGreater(lum(out), before + 10)
            self.assertIn(("enhanced", src, out), self.events)
            self.assertEqual(self.events[-1], ("queue", 0))

    def test_replace_original(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "IMG_2.jpg")
            dark_photo(src)
            before, mtime = lum(src), os.stat(src).st_mtime
            camworker.queue_photo(src, "lowlight", False)
            self.wait_idle()
            self.assertEqual(sorted(os.listdir(d)), ["IMG_2.jpg"])  # no copy, no temp folder left
            self.assertGreater(lum(src), before + 10)
            self.assertAlmostEqual(os.stat(src).st_mtime, mtime + 1, delta=0.01)

    def test_off_and_failures(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(camworker.queue_photo(os.path.join(d, "x.jpg"), "off"), 0)
            bad = os.path.join(d, "bad.jpg")
            with open(bad, "wb") as f:
                f.write(b"no image")
            good = os.path.join(d, "good.jpg")
            dark_photo(good)
            camworker.queue_photo(bad, "vivid")
            camworker.queue_photo(good, "subtle")
            self.wait_idle()
            self.assertTrue(any(e[0] == "failed" and e[1] == "bad.jpg" for e in self.events))
            self.assertTrue(os.path.exists(os.path.join(d, "good_enhanced.jpg")))

    def test_image_size(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "s.jpg")
            dark_photo(p, 640, 480)
            self.assertEqual(camworker.image_size("file://" + p), [640, 480])

    def test_focus_distance(self):
        from PIL.TiffImagePlugin import IFDRational

        def photo(d, name, tags):
            p = os.path.join(d, name)
            dark_photo(p, 64, 48)
            with Image.open(p) as im:
                img = im.copy()
            ex = Image.Exif()
            ex.get_ifd(enhance.EXIF_IFD).update(tags)
            img.save(p, "JPEG", exif=ex.tobytes())
            return p

        with tempfile.TemporaryDirectory() as d:
            plain = os.path.join(d, "plain.jpg")
            dark_photo(plain, 64, 48)
            self.assertEqual(camworker.focus_distance(plain), [-1, 0])          # no EXIF at all
            near = photo(d, "near.jpg", {camworker.TAG_SUBJECT_DISTANCE: IFDRational(123, 100),
                                         camworker.TAG_SUBJECT_DISTANCE_RANGE: 2})
            self.assertEqual(camworker.focus_distance("file://" + near), [1.23, 2])
            far = photo(d, "far.jpg", {camworker.TAG_SUBJECT_DISTANCE: IFDRational(0xFFFFFFFF, 1)})
            self.assertEqual(camworker.focus_distance(far), [camworker.FAR, 0])  # infinity
            unknown = photo(d, "unknown.jpg", {camworker.TAG_SUBJECT_DISTANCE: IFDRational(0, 1),
                                               camworker.TAG_SUBJECT_DISTANCE_RANGE: 3})
            self.assertEqual(camworker.focus_distance(unknown), [-1, 3])        # 0 = unknown
            self.assertEqual(camworker.focus_distance(os.path.join(d, "missing.jpg")), [-1, 0])

    def test_hold_delays_enhancing(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "h.jpg")
            dark_photo(src)
            out = os.path.join(d, "h_enhanced.jpg")
            camworker.hold(1.0)
            camworker.queue_photo(src, "subtle")
            time.sleep(0.5)
            self.assertFalse(os.path.exists(out))          # still holding
            camworker.hold(0)                               # e.g. the app went to the background
            self.wait_idle()
            self.assertTrue(os.path.exists(out))

    def test_start_does_not_load_pillow(self):
        import subprocess
        code = ("import sys; sys.path.insert(0, %r); import camworker; camworker.camera_dir; "
                "print('PIL' in sys.modules)" % os.path.join(HERE, "..", "python"))
        out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True).stdout.strip()
        self.assertEqual(out, "False")

    def test_engine_copy_in_sync(self):
        original = os.path.join(HERE, "..", "..", "harbour-photoenhance", "python", "enhance.py")
        if not os.path.exists(original):
            self.skipTest("harbour-photoenhance not next to this project")
        with open(original, "rb") as a, open(enhance.__file__, "rb") as b:
            self.assertEqual(a.read(), b.read(), "run tools/sync-engine.py")


if __name__ == "__main__":
    unittest.main()


class DeletePhotoTest(unittest.TestCase):
    def test_delete_returns_newest_left(self):
        d = tempfile.mkdtemp()
        old, new = os.path.join(d, "a.jpg"), os.path.join(d, "b.jpg")
        for p in (old, new):
            open(p, "w").close()
        os.utime(old, (1, 1))
        self.assertEqual(camworker.delete_photo("file://" + new), [True, old])
        self.assertEqual(camworker.delete_photo(old), [True, ""])
        self.assertEqual(camworker.delete_photo(old), [False, ""])