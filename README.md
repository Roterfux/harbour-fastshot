# FastShot (harbour-fastshot)

A Sailfish OS camera built for speed, with optional automatic photo enhancement using the
Photo Enhance engine.

## Fast capture

- The camera stays loaded while the app is in front, and is released when it is not.
- Continuous autofocus; a shot does **not** wait for a focus lock (tap the viewfinder to focus on a point).
- A press is taken as soon as the camera is ready. Presses made while it is still saving are remembered
  (up to 3), so no press is lost.
- Hold the shutter for a burst; the counter shows how many were taken.
- Vol+ / Vol- (and a hardware camera key, if the phone has one) work as the shutter, including burst
  when held. Can be switched off in the settings.
- A press while the previous photo is still being saved is taken at once if the camera allows it;
  otherwise it is queued (up to 10) and taken the moment the camera is ready.
- Instant feedback: the screen blinks and a small snapshot of the viewfinder (kept on the GPU) appears in the corner at the press; the saved photo replaces it once written.

## Enhancement (optional)

Settings → *Enhance photos*: Off, Smart auto, Low light, Vivid or Subtle. After each shot the photo is
queued and enhanced in a background thread with low priority (`nice 10`), so it never slows the camera.
*Keep the original* saves `<name>_enhanced.jpg` next to it; off replaces the original.
Photos still in the queue when the app is closed are enhanced after the next start
(`Pictures/Camera/.fastshot-queue.json`).

- **On the graphics chip** (default): Python measures the photo (`enhance.gpu_params`), the shader
  `qml/components/EnhanceEffect.qml` applies the effects at full size off-screen, `grabToImage` writes
  a BMP to /tmp, Python saves the JPEG with the original's EXIF. Only while the app is in front; the
  processor takes over in the background, and for good if the GPU result is unusable (e.g. black).
- Optional: live enhanced viewfinder, enhance only while charging.

## Optional camera features (Settings)

- **Best of 3:** three photos per press, the sharpest is kept (`camworker.best_of`).
- **Steady shot:** waits until the gyroscope reads under 6 °/s for 60 ms (at most 0.7 s).
- **Focus when raised:** focuses once when the phone goes from lying flat to a shooting position.
- **Stay ready after leaving:** 30 s, 2 or 5 minutes in the camera's Loaded state.
- **Bursts in a hidden folder first** (default): `Pictures/Camera/.fastshot-burst`, moved when the burst ends.

## Files

- `qml/pages/CameraPage.qml` - viewfinder, shutter, burst, focus, flash, camera switch
- `qml/pages/SettingsPage.qml` - enhancement settings
- `python/camworker.py` - the background queue
- `python/enhance.py` - **copy** of `harbour-photoenhance/python/enhance.py`; update with
  `python tools/sync-engine.py` (a test fails when they differ)

## Build and install

```sh
tools/build-rpm.sh
scp RPMS/noarch/harbour-fastshot-0.4.0-10.noarch.rpm defaultuser@<phone>:
ssh defaultuser@<phone> devel-su pkcon install-local harbour-fastshot-0.4.0-10.noarch.rpm
```

## Tested on an Xperia 10 III (Sailfish OS)

Confirmed working (0.1.0-8): viewfinder upright, volume keys as shutter, full 12 MP photos
(4000x3000). Photo rotation (0.2.0-9): upright in Gallery in all four positions with both cameras.
Qt counts the sensor angle the other way round from Android (back 270, front 90), so the phone's
turn is subtracted for the back camera and added for the front one; the Android formula turned
sideways photos upside down. Selfie camera (0.1.0-18): viewfinder works. Selfie bursts work with a
400 ms pause between shots (0.1.0-19; without it the selfie camera froze). Pinch-to-zoom
(digital) and tap-to-focus inside the PinchArea both work (0.2.0-4). `camera.digitalZoom` is a
zoom step (1-100), not a factor; mapped linearly to 1-8x the shown factor matches (0.2.0-5).
GPU enhancement works: the photo was enhanced on the graphics chip and looks similar to the
processor's result (0.2.0-5; speed not measured yet).

Measured (Settings > Camera info): app start to camera running 1686 ms (2328 ms before the
1440x1080 viewfinder was remembered), back to the app within 30 s 268 ms.

What this phone's camera does differently, and how FastShot handles it:

- **Only two cameras** are offered to apps (main back, front): the ultra-wide and tele lenses
  cannot be chosen, so the lens buttons stay hidden.
- **The backend rotates the viewfinder itself** (sensor orientation 270 must not be added).
- **No Sailfish.Media:** volume keys arrive as normal key events once the ScaleButton resource is held.
- **No "photo taken" (imageCaptured) event:** feedback, focus release and timings do not depend on it.
- **Saved JPEGs are sideways with an EXIF rotation tag:** images shown in the app need `autoTransform`.
- **No photo while the last one is saving:** the camera refuses; FastShot remembers that and queues
  such presses (taken the moment the camera is ready).
- **`VideoOutput.PreserveAspectCrop` does not fill the screen:** for the full-screen viewfinder the
  VideoOutput is sized from `Screen` (1080x2520) larger than the screen in the picture's shape,
  with PreserveAspectFit, inside a clipping item (works, 0.1.0-15).
- **Front and back camera support different sizes:** an unsupported viewfinder or photo size
  leaves the camera black ("failed to negotiate caps"). Sizes are remembered per camera and
  format, and a failed start drops them and retries with the defaults (works, 0.1.0-16).
- **Stopping and restarting the camera while Python starts can crash the app** (black, or back to
  lipstick, after changing the enhance mode in the settings). The camera keeps running under the
  settings page and Python starts only after the camera has run undisturbed for 1 s (fixed, 0.1.0-17).
- **`grabToImage` of the viewfinder is black** (frames cannot be read back to the CPU); a
  `ShaderEffectSource` snapshot that stays on the GPU works and shows at once (0.1.0-11).

Rotation can still be corrected without a rebuild, if another phone needs it:
`dconf write /apps/harbour-fastshot/viewfinderFix 90` (or 180, 270), and likewise `photoFix`.

- **Video recording does not work** (0.3.0, removed in 0.4.0): the camera driver answers the recording start with `Invalid argument` (Android `CameraSource`) and then crashes (`provider@2.4` SIGSEGV); the Sailfish camera started from a terminal failed the same way. The hardware H.264 encoder itself starts fine.
