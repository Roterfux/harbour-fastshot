Name:       harbour-fastshot
Summary:    Fast camera with optional automatic photo enhancement
Version:    0.4.0
Release:    31
License:    GPLv3+
BuildArch:  noarch
Source0:    %{name}-%{version}.tar.bz2

# UI (QtMultimedia, the camera backend and Nemo.Configuration ship with Sailfish OS itself)
Requires:   sailfishsilica-qt5 >= 1.1.0
Requires:   mapplauncherd-booster-silica-qt5
# Enhancement engine: Python + Pillow through PyOtherSide
Requires:   pyotherside-qml-plugin-python3-qt5
Requires:   python3-base
Requires:   python3-imaging

%description
FastShot is a camera that takes the photo the moment you press: the camera stays
ready, focus is continuous, presses made while it is busy are remembered and holding
the shutter shoots a burst. Optionally every photo is enhanced afterwards in the
background (smart auto or a preset), keeping or replacing the original.

%prep
%setup -q -n %{name}-%{version}
# Sources may come from a filesystem without Unix modes (e.g. a Windows drive)
find . -type f -exec chmod 0644 {} +

%build
# Nothing to build: QML UI + Python engine

%install
rm -rf %{buildroot}
install -d %{buildroot}%{_datadir}/%{name}
cp -r qml python %{buildroot}%{_datadir}/%{name}/
find %{buildroot}%{_datadir}/%{name} -name __pycache__ -prune -exec rm -rf {} \;
# Stamp the exact package version into the About page (fail if the marker moved)
sed -i 's/appVersion: "[^"]*"/appVersion: "%{version}-%{release}"/' \
    %{buildroot}%{_datadir}/%{name}/qml/pages/AboutPage.qml
grep -q 'appVersion: "%{version}-%{release}"' %{buildroot}%{_datadir}/%{name}/qml/pages/AboutPage.qml
install -D -m 0644 harbour-fastshot.desktop %{buildroot}%{_datadir}/applications/%{name}.desktop
for size in 86x86 108x108 128x128 172x172; do
    install -D -m 0644 icons/$size/%{name}.png %{buildroot}%{_datadir}/icons/hicolor/$size/apps/%{name}.png
done

%files
%defattr(-,root,root,-)
%{_datadir}/%{name}
%{_datadir}/applications/%{name}.desktop
%{_datadir}/icons/hicolor/*/apps/%{name}.png

%changelog
* Fri Nov 20 2026 FastShot contributors - 0.4.0-31
- Smart auto: no colour correction on mostly black night/dim photos lit by one lamp (blacks
  turned purple).

* Fri Nov 20 2026 FastShot contributors - 0.4.0-30
- Gallery: delete button (bottom right) with a few seconds to undo.
  A photo deleted while it waits to be enhanced is skipped; the camera's corner thumbnail moves
  on to the newest photo left.

* Fri Nov 20 2026 FastShot contributors - 0.4.0-29
- QR scanner: the Copy / Open / Scan again buttons share the panel width instead of being cut off
  at both sides.

* Fri Nov 20 2026 FastShot contributors - 0.4.0-28
- Back to the camera code of 0.4.0-25: Keep both cameras open (0.4.0-26 and -27) is removed because
  both cameras were black with it.

* Fri Nov 20 2026 FastShot contributors - 0.4.0-27
- Fix: the front camera was black in 0.4.0-26. In the normal mode the camera is again the single
  camera object of before (it changes its device and sizes the old way); the second camera object
  only exists with Keep both cameras open.

* Fri Nov 20 2026 FastShot contributors - 0.4.0-26
- New test option in the settings: Keep both cameras open (after an app restart). Each camera has
  its own device; the selected one streams and the other waits in the Loaded state, so switching
  only has to start the stream. If the phone refuses, or the app crashed trying, it switches itself
  off. Camera info shows its state.

* Fri Nov 20 2026 FastShot contributors - 0.4.0-25
- Settings: "Release camera when switching" (test option, off by default) closes the camera before
  the other one is opened. Camera info shows the switch times for both methods side by side.
- A second tap on the switch button during a switch is ignored.

* Fri Nov 20 2026 FastShot contributors - 0.4.0-24
- Switching between the back and front camera keeps the last picture on screen (instead of
  black) until the other camera runs. The switch time is measured and shown in Camera info
  ("Back/front switch -> camera running").

* Thu Nov 19 2026 FastShot contributors - 0.4.0-23
- Smart auto white balance measures only near-grey parts of the photo (sky, walls, road):
  a big red jacket or a face no longer counts as a colour cast. Selfies in a red jacket came
  out teal and grey-faced. Real casts (the selfie camera's teal, lamp light) are corrected
  more firmly. Faces are now found after white balance, so a tinted face still gets the
  face brightening.
* Thu Nov 19 2026 FastShot contributors - 0.4.0-22
- Smart auto: night and dim photos are lifted as much as selfies (exposure up to 50 / 55,
  shadows up to 45 / 50, local tone mapping 35). Before, only photos with a face got this,
  so back-camera photos came out darker than selfies in the same light.
* Thu Nov 19 2026 FastShot contributors - 0.4.0-21
- 16:9 photos on the back camera now use the full sensor width like the selfie camera
  (4000x2250 instead of 3840x2160 on the Xperia 10 III, once one 4:3 photo was taken).
  If the camera refuses that size it goes back to 3840x2160, then to 4:3.
* Thu Nov 19 2026 FastShot contributors - 0.4.0-20
- QR code scanner: "QR" in the top bar. Hold a code inside the square; the text shows with
  Copy, Open (web, mail, phone and map links) and Scan again. The reader is written in Python
  (Pillow only) and reads codes turned any way, mirrored and somewhat tilted. If copies of the
  viewfinder come out black on this phone it reads small photos instead (Camera info says
  which). The flash stays off while scanning.
* Sun Nov 15 2026 FastShot contributors - 0.4.0-19
- Photo viewer: pinch zoom now zooms around the point between the fingers (it used to
  grow from the top left corner), and follows the fingers when they move. Double tap
  zooms in on the tapped spot.
* Sun Nov 15 2026 FastShot contributors - 0.4.0-18
- Focus distance: after a photo the viewfinder shows for 5 s how far away the camera
  focused ("Focus ≈ 1.2 m"), read from what the camera writes into the photo. Camera info
  says whether this phone writes it. A live distance is not possible: the camera gives
  apps no lens position.
* Sat Nov 14 2026 FastShot contributors - 0.4.0-17
- Night portrait mode: when a face is detected in night/dim scenes, exposure and shadow
  caps are raised (night exp 35->50, shadows 30->45) and local tone mapping (35%%) is
  forced on, lifting the subject from the dark background. Works for all faces, not just
  ones darker than the scene.
- Focus in low light: auto-focuses before each shot when the light sensor reads dark,
  even without the "Focus before each shot" setting. Default focus wait raised to 1.2 s.
- Focus ring pulses while the camera is searching for focus.
- Shutter badge shows SR/HD labels for super-res and HDR multi-shot modes.
* Sat Nov 14 2026 FastShot contributors - 0.4.0-16
- Face-aware exposure: skin detection biases exposure when faces are darker than the scene.
  Night caps relax when a dark face is detected.
- Local tone mapping (dodge-and-burn): lifts dark regions and compresses bright ones using
  local average brightness, triggered automatically on high-contrast and backlit scenes.
- Lens corrections: vignette correction (r-squared model, 15%% strength) and chromatic
  aberration correction (R/B channel scaling) applied automatically in smart auto.
- Super-res multi-shot mode: aligns frames, upscales to 2x, and averages for more detail.
- HDR multi-shot mode: aligns and merges frames with forced tone mapping for dynamic range.
* Thu Nov 13 2026 FastShot contributors - 0.4.0-15
- Night/dim brightness pulled back: the previous caps over-brightened dark scenes.
  Night exposure 50->35, shadows 45->30, contrast 45->35; dim exposure 55->45,
  shadows 50->40, contrast 50->42. Results are noticeably brighter than the
  original conservative settings while avoiding the washed-out look.
* Thu Nov 13 2026 FastShot contributors - 0.4.0-14
- Multi-shot modes: "Best of" (2-5 photos, keeps the sharpest) replaces the old "Best of 3"
  toggle with a configurable frame count. New "Stack" mode (2-5 photos) averages aligned frames
  for less noise in low light, like computational night mode. Both modes are in Settings.
* Thu Nov 13 2026 FastShot contributors - 0.4.0-13
- Night and dim photos are much brighter: exposure, shadows, contrast and local contrast
  caps raised substantially (night exposure 25->50, shadows 20->45) so dark scenes show the
  detail other camera apps show instead of staying nearly black.
* Thu Nov 12 2026 FastShot contributors - 0.4.0-12
- Two photos now enhance at the same time (two background threads instead of one): bursts and
  fast presses drain the queue roughly twice as fast. The second thread also overlaps disk I/O
  with the first thread's CPU work.
- Pillow (the image library) is imported in the background right after Python starts, so the
  first photo taken doesn't wait for the ~0.3 s import.
- Python starts 400 ms earlier (100 ms after the camera is running, was 500 ms).
- The corner thumbnail now shows the last photo from the previous session at once.
* Thu Nov 12 2026 FastShot contributors - 0.4.0-11
- Engine speed-up: colour-noise removal rewired (the 1/4 BOX downsample already kills individual
  colour dots, so the full-resolution median filter step is eliminated entirely), JPEG save drops
  the expensive optimize pass and 4:4:4 chroma (the sensor is 4:2:0 anyway: 14 %% smaller files),
  wasteful image copies replaced by direct resize, and EXIF is read once instead of twice.
  Estimated 7-20 s faster per photo on the phone depending on denoise amount.
- Live preview shader: sharpen and local contrast are computed before the tone curve, eliminating
  5 redundant pow+gain evaluations per pixel. Saved photos keep the full-quality path.
* Thu Nov 12 2026 FastShot contributors - 0.4.0-10
- Live preview pauses while the phone is moving: the accelerometer detects motion and
  disables the enhancement shader so the raw viewfinder shows with minimum latency.
  When the phone is held still again the enhanced preview returns after 250 ms.
* Wed Nov 11 2026 FastShot contributors - 0.4.0-9
- Enhancement nearly 3x faster for night and dim photos (measured on 12 MP: 1.7 s instead of
  4.6 s): the colour-dot removal step is skipped when the stronger colour-blotch smoothing
  replaces the colour planes entirely (denoise 40+), and the brightness median is replaced by
  a fast box blur since the edge-preserving flat-area smoother does the real work.
- Gallery: tap the thumbnail to swipe through recent photos (newest first), pinch to zoom,
  double-tap for 2.5x. Pull down to open in the system gallery.
- Live viewfinder denoise improved: colour dot removal, stronger colour smoothing from the mipmap,
  shadow desaturation and coarse-grain brightness smoothing now run in the live preview too
  (was only on saved photos). The viewfinder should look noticeably cleaner in dim and night scenes.
- Python starts 0.5 s earlier after the camera is ready (was 1 s).
* Wed Nov 11 2026 FastShot contributors - 0.4.0-7
- Night photos stay darker: exposure 25 (was 35), contrast 30 (was 40), shadows 20 (was 30).
  Dim: exposure 40 (was 55), contrast 40 (was 55).
- Stronger auto white balance for indoor lamp light: indoor up to 75 (was 65), dim 60 (was 50),
  both start correcting at a lower warmth threshold.
- Better autofocus in the dark: focus wait doubled when the light sensor reads under 10 lux
  (up to 2.4 s), giving the camera more time to lock in poor light.
* Wed Nov 11 2026 FastShot contributors - 0.4.0-6
- Night and dim denoise capped at 65 (was 85): the higher value cleaned the grain but blurred
  the details out. Sharpen raised to 25 to compensate. Picture-analysis max denoise 70 (was 85).
* Wed Nov 11 2026 FastShot contributors - 0.4.0-5
- Noisy photos (denoise 45 or more from smart auto) are now always enhanced on the processor even
  with the graphics chip on, since the GPU shader cannot clean the coarse grain. The GPU stays
  available for quieter photos. Camera info shows the count.
- Stronger dim profile (ISO 640-1600): denoise 60-75, exposure up to 55, contrast up to 55.
- Night exposure setting removed (it made no difference on the Xperia 10 III).
* Wed Nov 11 2026 FastShot contributors - 0.4.0-4
- Night photos (from the user's test shots): the phone leaves brightness blotches of 8-15 px,
  which a pixel-sized filter misses; they are now smoothed on a 1/4 size copy where the picture
  is flat (edges kept), on the graphics chip and the processor. Smart auto brightens and
  stretches night scenes much less (exposure 35, contrast 40 at most), which had doubled the grain.
* Wed Nov 11 2026 FastShot contributors - 0.4.0-3
- Much stronger colour-noise removal in low light (red and green dots), on the graphics chip and
  the processor: single colour dots are removed, colour blotches are smoothed at reduced size,
  deep shadows lose their noisy colour. Night scenes get less saturation.
* Wed Nov 11 2026 FastShot contributors - 0.4.0-2
- Light-aware smart auto (engine from Photo Enhance 0.3.0): the light of each photo is worked out
  from its EXIF exposure (light sensor at the shot as fallback) and the settings follow it:
  night, dim, indoor (lamp light), daylight, sun, backlit, flash. Camera info shows the last
  choice and how often each scene was chosen.
* Wed Nov 11 2026 FastShot contributors - 0.4.0-1
- Video removed again (photo app only; no Audio/Microphone permissions). On the Xperia 10 III the
  camera driver refuses to start recording ("Invalid argument" in Android's CameraSource) and then
  crashes; the Sailfish camera started the same way failed identically.
* Wed Nov 11 2026 FastShot contributors - 0.3.0-6
- Video: flash off and no fixed frame rate, as the Sailfish camera (matching sizes alone did not
  help: the recorder still refused). Fallback steps start again at 0.
* Wed Nov 11 2026 FastShot contributors - 0.3.0-5
- Video: fixed 16:9 viewfinder (1920x1080, 1280x720 for 720p) and a photo size equal to the video
  size while in video mode. The debug log showed the phone's video recorder refusing to start;
  the preview ran at the camera's default 4:3 size. Fallback steps start again at 0.
* Wed Nov 11 2026 FastShot contributors - 0.3.0-4
- Video recorder set up like Sailfish's own camera and Advanced Camera: average bit rate
  encoding (was Qt's default, constant quality), 12 Mbit/s at 1080p, mono sound; focus unlocked
  before recording. The fallback steps start again at 0.
* Wed Nov 11 2026 FastShot contributors - 0.3.0-3
- Log of 0.3.0-2: the recorder refused to start ("error starting video recorder") and the
  immediate camera restart of the photo recovery crashed the app. Recorder errors now have their
  own handling: the camera rests 2 s before starting again, and the next try uses the next
  safer step. Night exposure is never used for videos (it was on in the failed start).
- The corner no longer tries to show a video file as an image.
* Wed Nov 11 2026 FastShot contributors - 0.3.0-2
- Video crashed the app right after the start: the photo watchdog no longer runs in video mode
  (it could restart the camera during a recording); a crash at the start of a recording is
  noticed at the next start and the next try uses safer settings (3 steps), shown in Camera info.
* Wed Nov 11 2026 FastShot contributors - 0.3.0-1
- Video: Photo/Video button on the camera screen (switching restarts the camera fully, the safe
  way on the Xperia 10 III); tap the red shutter (or a volume key) to start and stop; running time
  at the top; MP4 (H.264 + AAC) in Pictures/Camera; 720p / 1080p / 4K in the settings; the video
  gets the same rotation value as photos; leaving the app stops the recording
- New permissions: Audio and Microphone (for the sound)
- Camera info: video mode, recorder state, last video and recording errors

* Sun Nov 10 2026 FastShot contributors - 0.2.0-10
- Low light: night exposure (off / auto when the light sensor reads under 10 lux / on) and a
  brightness correction (-0.7 to +1.3 EV); Camera info shows whether the camera takes them
- GPU enhancement: edge-preserving noise reduction (5x5 bilateral filter) for saved photos;
  the live preview keeps the cheap version
- Focus: with "Focus before each shot", focusing starts when the shutter is touched and the photo
  is taken on release; focus on the middle of the picture; the longest wait is 0.4/0.8/1.2 s;
  a failed focus no longer waits for the full time; Camera info shows the focus times

* Sun Nov 10 2026 FastShot contributors - 0.2.0-9
- Photos taken sideways (turned left or right) were upside down: Qt on Sailfish counts the
  camera angle the other way round from Android, so the phone's turn is now subtracted for the
  back camera (and added for the front camera). Upright and upside down were already right
- The accelerometer now finishes learning its layout: 90 % agreement is enough (readings taken
  while the phone is being turned disagree with the slow orientation sensor)

* Sun Nov 10 2026 FastShot contributors - 0.2.0-8
- Photo rotation: the orientation sensor (right, but slow) decides again, and the fast
  accelerometer learns its axis layout by comparing with it; once one layout fits in two
  positions 90 degrees apart, the accelerometer takes over (remembered in dconf gravityMap).
  0.2.0-6 and -7 guessed the layout and got it wrong
- Capture log and Camera info show both sensors and which one decided

* Sun Nov 10 2026 FastShot contributors - 0.2.0-7
- 0.2.0-6 saved every photo upside down: Sailfish's accelerometer reports the direction of
  gravity, the opposite of the Qt convention. The signs are flipped (dconf key gravitySign, -1)

* Sun Nov 10 2026 FastShot contributors - 0.2.0-6
- Photos taken right after turning the phone (e.g. Best of 3 held sideways) came out turned by
  90 degrees: the orientation sensor reports a turn only after a delay. The phone's position is
  now read from the accelerometer, 20 times a second (orientation sensor only as a fallback)
- Every capture logs how the phone was held and the photo rotation; Camera info shows both

* Sun Nov 08 2026 FastShot contributors - 0.2.0-5
- Zoom showed "8x" for about 2x: the camera's zoom value is a step (1-100), not a magnification.
  The steps are now converted to an (estimated) real factor, the whole range is usable, and the
  label shows the real factor. dconf key zoomMaxFactor (default 8) sets the factor at the top step

* Sun Nov 08 2026 FastShot contributors - 0.2.0-4
- Pinch to zoom (digital, up to 8x; the phone offers apps no tele lens). The zoom level is shown
  above the shutter, in yellow past 2x where the picture gets visibly softer; tap it for 1x.
  Switching cameras starts unzoomed. Tap to focus still works

* Sun Nov 08 2026 FastShot contributors - 0.2.0-3
- Back to the single camera-screen file of 0.2.0-1: splitting it up (0.2.0-2) did not make the
  start faster on the Xperia 10 III (window -> page built 688 ms vs 617 ms, within the normal spread)

* Sun Nov 08 2026 FastShot contributors - 0.2.0-2
- Faster start: building the camera screen took 617 ms on the Xperia 10 III. The Python plugin
  (Worker.qml), the GPU renderer and its shader (GpuEnhancer.qml, LivePreview.qml) and the
  Camera info text (js/CameraInfo.js) are now separate files, compiled only when first needed
- Camera info: "Refresh" in the pull-down menu, and when Python was started

* Sun Nov 08 2026 FastShot contributors - 0.2.0-1
- Enhancement on the graphics chip: Python measures the photo, a shader applies the effects at
  full size, Python saves the JPEG with the original's EXIF. Falls back to the processor in the
  background or if the result is unusable (then the GPU is not used again)
- Optional live preview: the viewfinder shows the enhanced look
- Photos still waiting for enhancement survive closing the app and are done at the next start
- Optional: enhance only while charging; best of 3 (keeps the sharpest of three photos);
  steady shot (waits until the phone stops shaking, at most 0.7 s); focus when raised
- Bursts go to a hidden folder and are moved to Pictures/Camera when the burst ends
- "Stay ready after leaving": 30 s, 2 or 5 minutes
- Camera info: start-up breakdown, steady-shot waits, GPU status

* Sun Nov 08 2026 FastShot contributors - 0.1.0-19
- A burst with the selfie camera froze the camera until the camera was switched. The selfie
  camera now gets a 400 ms pause between burst shots (dconf key frontBurstGap)
- Watchdog: if a photo does not finish, or the camera is not ready again within 6 s, the
  camera is restarted automatically (as switching cameras did) and a note is shown
- The burst counter on the shutter counts again (its code was never reached)

* Sun Nov 08 2026 FastShot contributors - 0.1.0-18
- Selfie camera: 16:9 photos too. Its 16:9 size is the full sensor width at 16:9, worked out
  from its measured full-size photo (e.g. 3264x2448 -> 3264x1836); a size the camera refuses is
  dropped automatically
- The photo size is measured per camera (the first photo after switching), and the full-size
  photo of each camera is remembered; both are shown in Camera info

* Sun Nov 08 2026 FastShot contributors - 0.1.0-17
- Coming back from the settings sometimes left the camera black or crashed the app, mostly
  after changing the enhance mode. The camera now keeps running while the settings are open
  (no stop and restart), and Python is only started once the camera has run undisturbed for
  a second, never while it is starting
- Camera status changes are logged to the console

* Sun Nov 08 2026 FastShot contributors - 0.1.0-16
- Front camera black with "failed to negotiate caps": it got the back camera's remembered
  viewfinder size. Viewfinder sizes are now remembered per camera and format
- No guessed 16:9 photo size for the front camera (only the Sailfish camera's own setting)
- If the camera fails to start, FastShot drops the remembered viewfinder size, then the 16:9
  photo size, and starts again with the camera's defaults instead of staying black

* Sun Nov 08 2026 FastShot contributors - 0.1.0-15
- Full-screen viewfinder really fills the screen: the viewfinder is sized from the phone's
  screen resolution (Screen, 1080x2520 on the Xperia 10 III) and made larger than the screen
  in the picture's shape, instead of relying on PreserveAspectCrop, which did not fill it
- Tap to focus and the instant thumbnail follow the larger viewfinder
- Camera info shows the screen, page, viewfinder and picture sizes

* Sun Nov 08 2026 FastShot contributors - 0.1.0-14
- Full-screen viewfinder (on by default, switch in the settings): the camera picture fills the
  whole screen without black bars; the instant thumbnail uses the visible part

* Sun Nov 08 2026 FastShot contributors - 0.1.0-13
- Photo format 4:3 (whole sensor) or 16:9 (wide): a format button on the camera screen and a
  choice in the settings. The 16:9 size is taken from the Sailfish camera's own settings for
  the phone (3840x2160 if there are none); the viewfinder follows the format (1920x1080 for
  16:9) and is remembered per format. Camera info shows the format and the real photo size

* Sun Nov 08 2026 FastShot contributors - 0.1.0-12
- Fast presses and bursts no longer update the corner thumbnail for every photo: it keeps the
  first snapshot and shows the newest photo once all photos are saved (one decode instead of
  one per photo)
- The camera's refusal to take a photo while saving the last one (Xperia 10 III) is remembered,
  so later starts queue such presses directly instead of trying first

* Sun Nov 08 2026 FastShot contributors - 0.1.0-11
- The in-memory thumbnail was black on the Xperia 10 III (grabToImage cannot read the camera
  frames). Now a small snapshot of the viewfinder that stays on the GPU is shown at the press,
  and the saved photo, decoded small, replaces it as soon as it is written, so the corner is
  right even if the snapshot is black on a phone

* Sun Nov 08 2026 FastShot contributors - 0.1.0-10
- The thumbnail of the last photo is a small (160 px), low-quality copy of the viewfinder grabbed
  in memory at the shutter press: it appears at once and the 12 MP file is not read or decoded.
  dconf key thumbFromViewfinder=false goes back to the saved file

* Sun Nov 08 2026 FastShot contributors - 0.1.0-9
- The thumbnail of the last photo is upright: it ignored the photo's EXIF rotation (-90 degrees)
- A press while the previous photo is still being saved is taken at once if the camera accepts
  it; if it refuses, FastShot remembers that for the session and queues the press (now up to 10)
  until the camera is ready. Camera info shows which of the two this phone does

* Sun Nov 08 2026 FastShot contributors - 0.1.0-8
- With "Focus before each shot" the focus stayed locked at the first photo's distance on the
  Xperia 10 III, which never reports "photo taken" (imageCaptured). Focus is now released when
  the photo is saved, fails, or after 3 s at the latest
- The white blink appears the moment the photo is being taken (it waited for that same event)
- Camera info: "press -> capture started" (focus and busy waits) and burst intervals measured
  when each shot starts; the number of "photo taken" events is shown

* Sun Nov 08 2026 FastShot contributors - 0.1.0-7
- Volume keys on phones without Sailfish.Media (Xperia 10 III): handled as normal key events
  once the ScaleButton resource is acquired
- Viewfinder: the smallest 4:3 size that covers the screen (1440x1080 on the Xperia 10 III,
  was 1920x1440), remembered so the next start opens the camera with it directly
- Camera info shows the real size of the first photo of a session

* Sun Nov 08 2026 FastShot contributors - 0.1.0-6
- Faster return to the app: the camera stays loaded for 30 s after leaving the app (or opening
  the settings), so coming back only restarts the stream; then it is released for other apps
- Enhancement pauses while photos are taken and resumes 5 s after the last shot (at once when
  the app goes to the background), so bursts get all the CPU
- Camera info shows timings: app start and return to camera running, press to photo taken,
  press to file saved, time between burst shots (also logged to the console)

* Sun Nov 08 2026 FastShot contributors - 0.1.0-5
- Lens choice: on phones with several back cameras (Xperia 10 III: main, ultra-wide, tele)
  buttons above the shutter pick the camera; the choice is remembered
- The viewfinder uses the photos' 4:3 format (largest offered up to 1920 px wide), so the
  camera does not switch modes for every photo and the viewfinder shows exactly the photo
- Optional "Focus before each shot" (Settings): waits at most 0.8 s for focus on single shots;
  bursts never wait
- Settings > Camera info: what the camera reports (lenses, resolutions, focus, exposure), with
  copy to clipboard, to tune FastShot for a phone

* Sun Nov 08 2026 FastShot contributors - 0.1.0-4
- About page (Settings, pull-down menu) with the exact version, credits and licence

* Sun Nov 08 2026 FastShot contributors - 0.1.0-3
- Vol+ and Vol- take a photo (and a hardware camera key, on phones that have one); holding a
  key shoots a burst. The keys are taken over from the system volume while the camera is in
  front (Nemo policy "ScaleButton" resource + Sailfish.Media MediaKey)
- Settings: "Volume keys take photos" switch, which also says when the phone lacks a needed part

* Sun Nov 08 2026 FastShot contributors - 0.1.0-2
- Viewfinder no longer turned by 90 degrees: the camera backend already turns the frames
  upright, the extra sensor-angle rotation is gone
- Faster start: the camera starts when the app comes to the front instead of after the page
  animation; the orientation sensor and Python start once the camera runs; Python is not
  started at all when enhancement is off (the photo folder is remembered), and Pillow is
  only loaded for the first photo to enhance

* Sun Nov 08 2026 FastShot contributors - 0.1.0-1
- Initial release: instant capture, remembered presses, burst, tap to focus, flash, front and
  back camera; optional background enhancement (smart auto, low light, vivid, subtle) that
  keeps or replaces the original
