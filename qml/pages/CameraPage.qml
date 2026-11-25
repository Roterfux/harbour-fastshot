// FastShot - SPDX-License-Identifier: GPL-3.0-or-later
// Viewfinder and controls. Fast capture: the camera stays loaded, focus is continuous (no
// focus lock before a shot unless chosen in the settings), the viewfinder uses the photos' 4:3
// format so the camera does not switch modes per photo, a press is taken the moment the camera
// is ready (presses made while it is busy are remembered), holding the shutter shoots a burst,
// and enhancement runs later in a low-priority background thread.
import QtQuick 2.6
import QtMultimedia 5.6
import QtQuick.Window 2.2
import Sailfish.Silica 1.0
import Nemo.Configuration 1.0
import io.thp.pyotherside 1.3
import "../components"

Page {
    id: page

    property var win
    property int deviceRotation: 0      // 0, 90, 180, 270: how the phone is held (clockwise)
    property var py: null               // the Python element, created a moment after start-up
    property bool pyReady: false
    property var waiting: []            // photos taken before Python was ready
    property int queued: 0
    property int pendingShots: 0        // presses made while the camera was busy
    property bool holding: false        // shutter held: burst
    property int burstCount: 0
    property string lastShot: cfg.lastPhotoPath
    onLastShotChanged: if (lastShot !== "") cfg.lastPhotoPath = lastShot
    property string message: ""
    property var sensor: null

    // Motion detection for the live preview: the enhancement shader pauses while the phone
    // is moving so the raw viewfinder has the lowest possible latency.
    property bool phoneMoving: false
    property real _prevAx: 0/0   // NaN = first reading
    property real _prevAy: 0/0
    property real _prevAz: 0/0
    property real _stillAt: 0

    readonly property bool front: cfg.front

    // Every lens is its own camera device (the Xperia 10 III has a main, an ultra-wide and a
    // tele camera at the back). Pick one by its device id instead of only "back" or "front".
    readonly property var backCameras: camerasAt(Camera.BackFace)
    readonly property var frontCameras: camerasAt(Camera.FrontFace)
    readonly property var lenses: front ? frontCameras : backCameras
    readonly property int lensIndex: lenses.length > 0 ? Math.min(Math.max(cfg.lens, 0), lenses.length - 1) : 0
    readonly property string selectedId: lenses.length > 0 ? lenses[lensIndex].deviceId : ""

    function camerasAt(position) {
        var all = QtMultimedia.availableCameras
        var out = []
        for (var i = 0; i < all.length; ++i) {
            // devices that do not say where they are count as back cameras
            var pos = all[i].position
            if (pos === position || (position === Camera.BackFace && pos === Camera.UnspecifiedPosition))
                out.push(all[i])
        }
        return out
    }

    function lensLabel(info, index) {
        var name = String(info.displayName || "").toLowerCase()
        if (name.indexOf("wide") >= 0) return qsTr("Wide")
        if (name.indexOf("tele") >= 0 || name.indexOf("zoom") >= 0) return qsTr("Tele")
        return index === 0 ? qsTr("Main") : qsTr("Cam %1").arg(index + 1)
    }
    // Start the camera as soon as the app is in front (not only after the page animation ended);
    // release it when the app goes to the background or the settings are open
    // The camera keeps running while the settings are open: stopping it there and restarting it
    // on the way back (together with starting Python after a change of the enhance mode)
    // sometimes left the camera black or crashed the app (0.1.0-16 and earlier).
    readonly property bool cameraWanted: Qt.application.state === Qt.ApplicationActive
    readonly property bool onTop: pageStack.depth <= 1     // no settings page over the camera
    // Python (and Pillow) is only needed to enhance photos, or once to find the photo folder
    readonly property bool needPython: cfg.enhanceMode !== "off" || cfg.saveDir === "" || cfg.queueLeft > 0
                                       || (cfg.burstHidden && cfg.burstDir === "")
    readonly property var flashModes: [Camera.FlashAuto, Camera.FlashOn, Camera.FlashOff]
    readonly property var flashNames: [qsTr("Auto"), qsTr("On"), qsTr("Off")]
    readonly property var modeNames: ({ off: qsTr("Off"), auto: qsTr("Smart auto"), lowlight: qsTr("Low light"),
                                        vivid: qsTr("Vivid"), subtle: qsTr("Subtle") })

    allowedOrientations: Orientation.Portrait
    backNavigation: false

    ConfigurationGroup {
        id: cfg
        path: "/apps/harbour-fastshot"
        property bool front: false
        property int flash: 0               // index into flashModes
        property string enhanceMode: "off"  // off, auto, lowlight, vivid, subtle
        property bool keepOriginal: true
        // Rotation corrections in degrees for devices whose camera reports its mounting
        // wrongly; set with e.g.  dconf write /apps/harbour-fastshot/viewfinderFix 90
        property int viewfinderFix: 0
        property int photoFix: 0
        // ~/Pictures/Camera, asked from Python once and remembered, so later starts need no Python
        property string saveDir: ""
        property string lastPhotoPath: ""  // newest photo shown in the corner on startup
        property bool volumeKeys: true      // Vol+ / Vol- (and a camera key, if any) take photos
        property int lens: 0                // index into the back (or front) cameras
        property bool focusBeforeShot: false // sharper in poor light, but each shot waits for focus
        property bool thumbFromViewfinder: true  // thumbnail grabbed in memory, not read from the file
        property bool fullScreen: true      // viewfinder fills the screen (no black bars)
        property int frontBurstGap: 400     // ms between burst shots on the selfie camera
        property bool eagerRefused: false   // the camera refused a photo while saving the last one
        property string aspect: "4:3"       // photo format: "4:3" (full sensor) or "16:9"
        // remembered viewfinder sizes, JSON {"<camera id>:<format>": "WxH"} (see matchViewfinder)
        property string vfSizes: "{}"
        // measured 4:3 photo sizes, JSON {"<camera id>": "WxH"} (see readPhotoSize)
        property string photoSizes: "{}"
        // 0.2.0
        property bool gpuEnhance: true          // enhance on the graphics chip (CPU as fallback)
        property bool livePreview: false        // the viewfinder shows the enhanced look
        property bool enhanceWhenCharging: false
        property int queueLeft: 0               // photos still to enhance (resumed at the next start)
        property string lastParams: ""          // smart-auto numbers of the last photo (live preview)
        property string burstMode: "single"    // "single", "best" or "stack"
        property string captureMode: "photo"   // photo or video (0.4.0-34)
        property string videoRes: "1080"       // 720, 1080 or 2160 (lines)
        property int burstN: 3                  // 2..5: how many frames per press
        property bool steadyShot: false
        property real steadyLimit: 6            // degrees per second that count as "steady"
        property bool raiseFocus: false
        property int keepLoadedSec: 30          // camera stays loaded this long after leaving the app
        property bool switchUnload: false       // release the camera before switching (test option)
        property bool burstHidden: true         // bursts go to a hidden folder first
        property string burstDir: ""
        property real zoomMaxFactor: 8          // real magnification at the camera's last zoom step
        // learned accelerometer axis layout (see chooseLayout), -1 = not learned yet;
        // reset with  dconf write /apps/harbour-fastshot/gravityMap -1
        property int gravityMap: -1
        // 0.2.0-10: low light and focus
        property real evCompensation: 0         // brightness correction in EV
        property bool focusOnTouch: true        // with focus before shot: focus while touching
        property int focusWait: 1200            // longest wait for focus, ms
        // Video (0.3.0-1 to -6) was removed in 0.4.0: on the Xperia 10 III the camera driver refuses
        // to start recording ("Invalid argument" in CameraSource) and then crashes, with the
        // Sailfish camera too (logcat of 2026-11-11).
    }

    // Rotation stored in the photo: the sensor's mounting and how the phone is held.
    // Qt on Sailfish counts both angles the other way round from Android (back sensor 270, not 90),
    // so the turn of the phone is SUBTRACTED for the back camera and ADDED for the front one.
    // Up to 0.2.0-8 it was the Android formula: upright and upside down were right (there + and -
    // give the same), but both sideways positions came out upside down (log of 2026-11-10).
    function captureRotation() {
        var s = camera.orientation
        var r = front ? (s + deviceRotation) % 360 : (s - deviceRotation + 360) % 360
        return (r + cfg.photoFix) % 360
    }

    function capture() {
        message = ""
        camera.metaData.orientation = captureRotation()
        console.log("FastShot capture: phone turned " + deviceRotation + " (" + rotationSource()
                    + "; orientation sensor " + osRotation + ", accelerometer " + accelRotation + "), "
                    + (front ? "front" : "back") + " sensor " + camera.orientation
                    + ", photo rotation " + captureRotation())
        var name = "IMG_" + Qt.formatDateTime(new Date(), "yyyyMMdd_hhmmss_zzz") + ".jpg"
        // a burst shot has no press of its own: it counts from the moment it was started
        var press = presses.length > 0 ? presses.shift() : Date.now()
        lastPressUsed = press
        var now = Date.now()
        remember(lagStart, now - press)
        if (lastCaptureStart > 0 && now - lastCaptureStart < 3000)
            remember(burstGaps, now - lastCaptureStart)
        lastCaptureStart = now
        shutterFlash.restart()             // feedback the moment the photo is being taken
        // A single shot gets its snapshot at once. During fast presses or a burst the corner
        // keeps the first one and is only updated when all photos are saved (saves the work).
        var fast = shootingFast()
        if (!fast) grabThumbnail()
        else thumbPending = true
        inFlight += 1
        // Burst and best-of-3 photos go to a hidden folder first, so the media indexer does not
        // read every photo while the camera is still shooting; they are moved afterwards.
        // group -2: a panorama frame, joined with the others once the shutter is let go
        var group = groupSlots > 0 ? currentGroup : cfg.burstMode === "panorama" ? -2 : -1
        if (group >= 0) groupSlots -= 1
        var dir = ((fast || group !== -1) && cfg.burstHidden && cfg.burstDir !== "") ? cfg.burstDir : cfg.saveDir
        var id = camera.imageCapture.captureToLocation(dir !== "" ? dir + "/" + name : "")
        shots[id] = { press: press, captured: 0, group: group }
        if (lockedForShot) shotLockTimer.restart()
        captureWatchdog.restart()
        // (before 0.1.0-19 this came after the return and never ran: no burst counter)
        if (holding) {
            burstCount += 1
            holdEnhancing(5)
        }
        return id
    }

    // ------------------------------------------------------------------ timings (Camera info)
    property var presses: []            // times of presses not yet turned into a capture
    property var shots: ({})            // capture request id -> { press, captured }
    property var lagStart: []           // press -> capture started (focus and busy waits), last 10
    property var lagTaken: []           // press -> photo taken (ms), when the backend says so
    property int previewEvents: 0
    property real lastCaptureStart: 0
    property var lagSaved: []           // press -> file saved
    property var burstGaps: []          // between shots less than 3 s apart
    property real resumeStart: 0
    property string resumeFrom: ""
    property int startMs: -1            // app start -> camera running
    property real loadedAt: 0           // first time the camera was loaded
    property real pageBuiltAt: 0
    Component.onCompleted: {
        pageBuiltAt = Date.now()
        if (lastShot !== "") showLastPhoto()
    }
    property int resumeMs: -1           // back to the app -> camera running
    property var lagSwitch: []          // tap on the switch button -> other camera running

    // ---- switching between the back and the front camera
    // The tap freezes the last picture (a GPU copy of the viewfinder, switchSnap) and shows it
    // until the other camera delivers its first frames, instead of a black screen. The time to
    // the new picture is measured for Camera info.
    property bool switching: false
    property real switchStart: 0

    property var lagSwitchU: []         // same, with the camera released first
    property bool switchedUnloaded: false

    function beginSwitch() {
        if (switching) return                   // one switch at a time
        switchSnap.scheduleUpdate()
        switchStart = Date.now()
        switching = true
        switchGuard.restart()
        switchedUnloaded = cfg.switchUnload
        if (switchedUnloaded) {
            // Release the camera first, then change the device while nothing is open, then start
            // again. 150 ms steps instead of the 500 ms of restartCamera(): the release of the
            // old camera does not have to be complete for the new one to be asked for.
            restarting = true
            switchStage = 1
            switchStep.restart()
        } else {
            cfg.front = !cfg.front              // the camera changes its device while running
        }
    }

    property int switchStage: 0
    Timer {
        id: switchStep
        interval: 150
        onTriggered: {
            if (page.switchStage === 1) {
                cfg.front = !cfg.front
                page.switchStage = 2
                switchStep.restart()
            } else {
                page.switchStage = 0
                page.restarting = false
            }
        }
    }

    function endSwitch() {
        if (!switching || switchStage !== 0) return
        var list = switchedUnloaded ? lagSwitchU : lagSwitch
        remember(list, Date.now() - switchStart)
        console.log("FastShot timing: camera switch (" + (switchedUnloaded ? "released first" : "direct")
                    + ") -> running " + list[list.length - 1] + " ms (" + formatKey + ")")
        switchCoverTimer.restart()
    }

    // the new picture needs a moment after "active" before real frames arrive
    Timer { id: switchCoverTimer; interval: 150; onTriggered: { page.switching = false; switchGuard.stop() } }
    // never keep the old picture on screen if the camera does not report "active" (e.g. an error)
    Timer { id: switchGuard; interval: 5000; onTriggered: page.switching = false }

    function remember(list, value) {
        list.push(Math.round(value))
        if (list.length > 10) list.shift()
    }

    function stat(list) {
        if (list.length === 0) return qsTr("no data yet")
        var sum = 0
        for (var i = 0; i < list.length; ++i) sum += list[i]
        return list[list.length - 1] + " / " + Math.round(sum / list.length)
    }

    // ------------------------------------------------------------------ enhancement pause
    // Enhancement waits while photos are being taken and resumes 5 s after the last one
    // (or at once when the app goes to the background), so a burst gets all the CPU.
    function holdEnhancing(seconds) {
        if (pyReady) py.call("camworker.hold", [seconds], function () {})
    }

    // skipFocus: the photo was already focused while the finger was on the shutter
    function shoot(skipFocus) {
        presses.push(Date.now())
        if (presses.length > maxPending) presses.shift()
        holdEnhancing(5)
        // Best-of / stack: one press takes several photos (single shots only, not during a hold-burst)
        if (cfg.burstMode !== "single" && cfg.burstMode !== "panorama" && !holding && groupSlots === 0)
            startGroup()
        steadySkipFocus = !!skipFocus
        // Steady shot: wait (at most 0.7 s) until the phone stops shaking, then go on
        if (cfg.steadyShot && !holding && !steadying && gyro) {
            startSteady()
            return
        }
        afterSteady()
    }

    property bool steadySkipFocus: false

    function canFocus() {
        return camera.focus.isFocusModeSupported(Camera.FocusAuto)
    }

    // Focus on the middle of the picture (unless a point was tapped) and measure how long it takes
    function startFocus() {
        focusing = true
        lockedForShot = true
        focusStartedAt = Date.now()
        if (!unlockTimer.running && camera.focus.isFocusPointModeSupported(Camera.FocusPointCenter))
            camera.focus.focusPointMode = Camera.FocusPointCenter
        camera.searchAndLock()
    }

    function afterSteady() {
        var skip = steadySkipFocus
        steadySkipFocus = false
        // Focus first: always in the settings, or automatically when the light is low
        var wantFocus = cfg.focusBeforeShot || page.dark
        if (!skip && wantFocus && !holding && !focusing && camera.lockStatus !== Camera.Locked
                && canFocus()) {
            startFocus()
            focusTimeout.restart()
            return
        }
        takeOrQueue()
    }

    // ------------------------------------------------------------------ focus while touching
    // Like half-pressing a camera's button: with "Focus before each shot", focusing starts when the
    // finger touches the shutter and the photo is taken when it is lifted, usually already sharp.
    // Holding the shutter still shoots a burst (without focusing first).
    property bool prefocusing: false    // finger on the shutter, focusing, no photo yet
    property bool shootAfterFocus: false

    function shutterDown() {
        burstCount = 0
        if (videoMode) {                   // video: tap to start, tap again to stop
            toggleRecording()
            return
        }
        if (cfg.focusBeforeShot && cfg.focusOnTouch && canFocus() && !focusing) {
            prefocusing = true
            if (camera.lockStatus !== Camera.Locked) startFocus()   // already sharp: just wait for release
        } else {
            shoot()
        }
    }

    function shutterUp() {
        holding = false
        if (inFlight === 0) flushPanorama()   // the last frame was already saved
        if (!prefocusing) return
        prefocusing = false
        if (focusing) {                    // not sharp yet: shoot as soon as it is (or the wait ends)
            shootAfterFocus = true
            focusTimeout.restart()
        } else {
            shoot(true)
        }
    }

    function shutterHeld() {
        if (videoMode) return              // no burst in video mode
        prefocusing = false                // a burst does not wait for focus
        shootAfterFocus = false
        holding = true
        cameraReady()
    }

    // ------------------------------------------------------------------ steady shot
    // The gyroscope says how fast the phone turns (degrees per second). After the press the
    // photo waits until that stays below cfg.steadyLimit for 3 readings (60 ms), at most 0.7 s.
    property var gyro: null
    property bool steadying: false
    property int steadyCount: 0
    property real steadyStart: 0
    property var steadyWaits: []

    function createGyro() {
        if (gyro) return
        try {
            gyro = Qt.createQmlObject("import QtSensors 5.0; Gyroscope { active: false; dataRate: 100 }",
                                      page, "Gyroscope")
        } catch (e) {
            console.warn("FastShot: no gyroscope: " + e)
        }
    }

    function startSteady() {
        steadying = true
        steadyCount = 0
        steadyStart = Date.now()
        gyro.active = true
        steadyTimer.start()
    }

    function steadyTick() {
        var r = gyro ? gyro.reading : null
        var turn = r ? Math.abs(r.x) + Math.abs(r.y) + Math.abs(r.z) : 0
        steadyCount = (r && turn < cfg.steadyLimit) ? steadyCount + 1 : 0
        if (steadyCount >= 3 || Date.now() - steadyStart > 700 || !r) {
            steadyTimer.stop()
            gyro.active = false
            steadying = false
            remember(steadyWaits, Date.now() - steadyStart)
            afterSteady()
        }
    }

    Timer {
        id: steadyTimer
        interval: 20
        repeat: true
        onTriggered: page.steadyTick()
    }

    // ------------------------------------------------------------------ best of 3
    property int currentGroup: 0
    property int groupSlots: 0          // captures of the current group still to start
    property var groups: ({})           // group id -> { files: [], failed: 0 }
    property int openGroups: 0

    function startGroup() {
        var n = Math.max(2, Math.min(5, cfg.burstN))
        currentGroup += 1
        groupSlots = n
        groups[currentGroup] = { files: [], failed: 0, total: n }
        openGroups += 1
        if (pendingShots + (n - 1) <= maxPending) pendingShots += (n - 1)
    }

    function groupPhoto(group, path) {
        var g = groups[group]
        if (!g) return
        if (path) g.files.push(path)
        else g.failed += 1
        if (g.files.length + g.failed < g.total) return
        delete groups[group]
        var mode = cfg.burstMode
        var fn = mode === "stack" ? "camworker.stack_photos"
               : mode === "superres" ? "camworker.superres_photos"
               : mode === "hdr" ? "camworker.hdr_merge"
               : "camworker.best_of"
        callPython(fn, [g.files, cfg.saveDir], function (result) {
            page.openGroups = Math.max(0, page.openGroups - 1)
            if (result && result[0]) {
                console.log("FastShot " + mode + " " + g.total + ": " + result[0] + " (" + result[1] + ")")
                page.lastShot = result[0]
                page.readDistance(result[0])
                if (mode !== "hdr") page.queueEnhance(result[0])
            }
            if (!page.shootingFast()) page.showLastPhoto()
        })
    }

    // ------------------------------------------------------------------ burst folder
    property var burstFiles: []

    function flushBurst() {
        if (burstFiles.length === 0) return false
        var files = burstFiles
        burstFiles = []
        callPython("camworker.publish", [files, cfg.saveDir], function (moved) {
            for (var i = 0; moved && i < moved.length; ++i) page.queueEnhance(moved[i])
            if (moved && moved.length > 0) page.lastShot = moved[moved.length - 1]
            if (!page.shootingFast()) page.showLastPhoto()
        })
        return true
    }

    // ------------------------------------------------------------------ panorama
    property var panoFiles: []

    // Once the shutter is let go and every frame is saved: join them
    function flushPanorama() {
        if (panoFiles.length === 0 || shootingFast()) return false
        var files = panoFiles
        panoFiles = []
        openGroups += 1
        callPython("camworker.panorama", [files, cfg.saveDir], function (result) {
            page.openGroups = Math.max(0, page.openGroups - 1)
            if (result && result[0]) {
                page.lastShot = result[0]
                page.queueEnhance(result[0])
            } else {
                page.message = qsTr("Panorama: %1").arg(result ? result[1] : "?")
            }
            if (!page.shootingFast()) page.showLastPhoto()
        })
        return true
    }

    // Call Python now, or as soon as it has started
    function callPython(fn, args, callback) {
        if (pyReady) {
            py.call(fn, args, callback)
        } else {
            requestPython()
            pyReadyCallbacks.push(function () { py.call(fn, args, callback) })
        }
    }

    // ------------------------------------------------------------------ thumbnail from memory
    // At the shutter press the viewfinder is copied, small and on the GPU, into the corner
    // (see the ShaderEffectSource there); the saved file replaces it once written.
    // Off with  dconf write /apps/harbour-fastshot/thumbFromViewfinder false
    property bool snapshotTaken: false
    property bool thumbPending: false  // a newer photo than the file shown is on its way

    function grabThumbnail() {
        thumbPending = true
        if (!cfg.thumbFromViewfinder) return
        snapshot.scheduleUpdate()
        snapshotTaken = true
    }

    property int inFlight: 0           // photos started but not yet saved (or failed)
    property string thumbSource: ""    // the saved photo shown in the corner

    function shootingFast() {
        return inFlight > 0 || pendingShots > 0 || holding || steadying
    }

    // Called when a photo is saved or failed: once nothing is left, show the newest photo
    // (after moving burst photos out of their hidden folder, if there are any)
    function photoDone() {
        inFlight = Math.max(0, inFlight - 1)
        captureWatchdog.restart()      // the camera must be ready again soon
        if (!shootingFast() && !flushPanorama() && !flushBurst() && openGroups === 0) showLastPhoto()
    }

    function showLastPhoto() {
        if (lastShot !== "") thumbSource = "file://" + lastShot
        thumbPending = false
    }

    onHoldingChanged: if (!holding && !shootingFast() && !flushBurst() && openGroups === 0) showLastPhoto()

    // ------------------------------------------------------------------ capture while saving
    // The camera says "not ready" until the previous photo is saved (about a second for 12 MP).
    // Many camera backends can already take the next photo while the last one is written, so
    // a press during saving is tried at once. If the camera refuses, FastShot remembers that
    // for this session and queues presses until it is ready again; no press is lost either way.
    readonly property int maxPending: 10
    // untested, works, refused; a refusal is remembered (the Xperia 10 III refuses), so later
    // starts do not spend a failed capture on finding it out again
    property string eagerState: cfg.eagerRefused ? "refused" : "untested"
    property int eagerRequest: -1
    property real eagerTime: 0
    property real lastPressUsed: 0

    function takeOrQueue() {
        if (camera.imageCapture.ready) {
            capture()
        } else if (eagerState !== "refused" && camera.cameraStatus === Camera.ActiveStatus) {
            // the camera may refuse synchronously, inside capture(): mark the attempt first
            eagerTime = Date.now()
            eagerRequest = -2
            var id = capture()
            eagerRequest = eagerState === "refused" ? -1 : id
        } else if (pendingShots < maxPending) {
            pendingShots += 1
            if (!captureWatchdog.running) captureWatchdog.restart()
        }
    }

    // Called from captureFailed: true when the failure was an early capture being refused
    function eagerRefused(requestId) {
        if (eagerRequest === -1) return false
        if (requestId !== eagerRequest && Date.now() - eagerTime > 500) return false
        var shot = shots[eagerRequest]
        if (shot) delete shots[eagerRequest]
        presses.unshift(lastPressUsed)        // the retry keeps the original press time
        eagerRequest = -1
        eagerState = "refused"
        cfg.eagerRefused = true
        inFlight = Math.max(0, inFlight - 1)  // that attempt did not start a photo
        console.log("FastShot: the camera does not take a photo while saving; queueing instead")
        if (pendingShots < maxPending) pendingShots += 1
        cameraReady()
        return true
    }

    // ------------------------------------------------------------------ focus before shot
    property bool focusing: false
    property bool lockedForShot: false

    // Back to continuous focus after a focused shot. Before 0.1.0-8 this only happened on
    // imageCaptured, which the Xperia 10 III never sends: focus stayed locked at the first
    // shot's distance. Now: whichever comes first of preview, saved, failed or 3 s.
    function releaseShotLock() {
        shotLockTimer.stop()
        if (!lockedForShot) return
        lockedForShot = false
        camera.unlock()
    }

    Timer {
        id: shotLockTimer
        interval: 3000
        onTriggered: page.releaseShotLock()
    }

    // Focus timing for Camera info: how long until sharp, and how often the wait ran out
    property real focusStartedAt: 0
    property var focusTimes: []
    property int focusTimeouts: 0

    function focusDone(timedOut) {
        if (!focusing) return
        focusing = false
        focusTimeout.stop()
        if (timedOut) focusTimeouts += 1
        else if (focusStartedAt > 0) remember(focusTimes, Date.now() - focusStartedAt)
        if (prefocusing) return                        // finger still down: shoot on release
        if (shootAfterFocus) {
            shootAfterFocus = false
            shoot(true)
            return
        }
        takeOrQueue()                                 // focused or not: never lose the shot
    }

    Timer {
        id: focusTimeout
        // In the dark (light sensor < 10 lux) the camera needs more time to focus: double the
        // configured wait, up to 2.4 s. Daylight keeps the settings value as before.
        interval: Math.max(200, page.dark ? Math.min(cfg.focusWait * 2, 2400) : cfg.focusWait)
        onTriggered: page.focusDone(true)
    }

    // ------------------------------------------------------------------ focus distance
    // Qt's camera has no lens position, so there is no live distance. The camera driver may write
    // the distance it focused at into each photo (EXIF SubjectDistance, or the coarser
    // SubjectDistanceRange); that is shown for a few seconds after the shot. Whether this phone
    // writes it shows in Camera info.
    property real focusMetres: -1       // -1 = not written; 1000 and more = infinity
    property int focusZone: 0           // 1 macro, 2 close, 3 distant, 0 = not written
    property bool distanceRead: false   // a photo was checked this session
    readonly property string distanceText: {
        var m = focusMetres
        if (m >= 1000) return qsTr("Focus ≈ %1").arg("∞")
        if (m >= 10) return qsTr("Focus ≈ %1").arg(qsTr("%1 m").arg(Math.round(m)))
        if (m >= 1) return qsTr("Focus ≈ %1").arg(qsTr("%1 m").arg(m.toFixed(1)))
        if (m > 0) return qsTr("Focus ≈ %1").arg(qsTr("%1 cm").arg(Math.round(m * 100)))
        return focusZone === 1 ? qsTr("Focus: close-up") : focusZone === 2 ? qsTr("Focus: near")
             : focusZone === 3 ? qsTr("Focus: far") : ""
    }

    function readDistance(path) {
        callPython("camworker.focus_distance", [path], function (r) {
            page.distanceRead = true
            page.focusMetres = r ? r[0] : -1
            page.focusZone = r ? r[1] : 0
            if (page.distanceText !== "") distanceTimer.restart()
        })
    }

    Timer {
        id: distanceTimer
        interval: 5000
    }

    // ------------------------------------------------------------------ QR code scanner
    // "QR" in the top bar. Twice a second the square in the middle of the viewfinder is copied
    // on the GPU (like the corner thumbnail), saved small and read by qrscan.py (pure Python).
    // If those copies come out black on this phone, small photos are read instead.
    property bool qrMode: false
    property string qrText: ""
    property bool qrBusy: false
    property bool qrCopied: false
    property string qrMethod: "viewfinder"      // "photo" once viewfinder copies came out black
    property int qrBlack: 0                     // black copies in a row
    property bool qrSawPicture: false           // a copy had a real picture: never switch
    property int qrScans: 0
    property int qrMs: -1
    property real qrStarted: 0
    property int qrRequest: -1                  // capture id of a photo taken for the scanner
    property string qrFramePath: ""
    property string qrPhotoDir: ""
    readonly property real qrSide: Math.round(screenW * 0.75)
    readonly property bool qrIsLink: /^(https?:\/\/|mailto:|tel:|sms:|geo:)/i.test(qrText)

    onQrModeChanged: {
        qrText = ""
        if (qrMode && qrFramePath === "") {
            callPython("camworker.qr_frame_path", [], function (p) { page.qrFramePath = p })
            callPython("camworker.qr_photo_dir", [], function (d) { page.qrPhotoDir = d })
        }
    }
    onQrTextChanged: qrCopied = false

    function qrScan() {
        if (qrBusy || !pyReady || qrFramePath === "") return
        qrStarted = Date.now()
        if (qrMethod === "viewfinder") {
            qrBusy = true
            var asked = qrGrab.grabToImage(function (result) {
                if (!page.qrMode || !result.saveToFile(page.qrFramePath)) {
                    page.qrBusy = false
                    return
                }
                page.callPython("camworker.scan_qr", [page.qrFramePath, true], page.qrResult)
            }, Qt.size(qrGrab.width, qrGrab.height))
            if (!asked) qrBusy = false
        } else if (camera.imageCapture.ready && inFlight === 0 && qrPhotoDir !== "") {
            qrBusy = true
            qrRequest = camera.imageCapture.captureToLocation(
                        qrPhotoDir + "/fastshot-qr-" + Date.now() + ".jpg")
        }
    }

    function qrResult(r) {
        qrBusy = false
        qrScans += 1
        qrMs = Date.now() - qrStarted
        var text = r ? r[0] : ""
        var mean = r ? r[1] : -1
        if (qrMethod === "viewfinder") {
            if (mean >= 10) {
                qrSawPicture = true
                qrBlack = 0
            } else if (mean >= 0 && mean < 3 && !qrSawPicture) {
                qrBlack += 1
                if (qrBlack >= 3) {
                    qrMethod = "photo"
                    console.warn("FastShot QR: viewfinder copies are black, reading photos instead")
                }
            }
        }
        if (qrMode && text !== "") {
            qrText = text
            console.log("FastShot QR: read " + text.length + " characters in " + qrMs + " ms")
        }
    }

    Timer {
        id: qrTimer
        interval: 500
        repeat: true
        running: page.qrMode && page.qrText === "" && page.status === PageStatus.Active
                 && Qt.application.state === Qt.ApplicationActive
                 && camera.cameraStatus === Camera.ActiveStatus
        onTriggered: page.qrScan()
    }

    // ------------------------------------------------------------------ photo format (4:3 / 16:9)
    // 4:3 uses the whole sensor (12 MP on the Xperia 10 III, the camera's default). 16:9 is a
    // crop of it. The 16:9 photo size comes from the Sailfish camera's own per-device settings
    // (dconf), as Qt 5.6 cannot list photo sizes; 3840x2160 if the phone has none.
    readonly property bool wide: cfg.aspect === "16:9"
    // the shape of the picture: 16:9 or 4:3
    readonly property bool wideFrame: videoMode || wide
    readonly property string sensorKey: front ? "secondary" : "primary"

    ConfigurationValue {
        id: jollaWide
        key: "/apps/jolla-camera/" + page.sensorKey + "/image/imageResolution_16_9"
        defaultValue: ""
    }

    function parseSize(text) {
        var m = /^\s*(\d+)\s*x\s*(\d+)\s*$/.exec(String(text || ""))
        return m ? Qt.size(parseInt(m[1], 10), parseInt(m[2], 10)) : null
    }

    // Without a Sailfish camera setting, every camera (since 0.4.0-21 the back camera too, before
    // only the selfie camera) first tries the full sensor width at 16:9, from its measured 4:3
    // photo size (e.g. 4000x3000 -> 4000x2250, 3264x2448 -> 3264x1836). The back camera then
    // falls back to 3840x2160, the size it used before. A size the camera refuses is dropped by
    // recover() and the next one is tried, so a wrong guess cannot leave the camera black; after
    // the last one the camera's default (4:3) is used.
    readonly property var measured43: parseSize(parseJson(cfg.photoSizes)[selectedId])
    readonly property var wideSizes: {
        var fromJolla = parseSize(jollaWide.value)
        if (fromJolla) return [fromJolla]
        var list = []
        if (measured43) {
            var w = Math.max(measured43.width, measured43.height)
            list.push(Qt.size(w, Math.round(w * 9 / 16 / 2) * 2))
        }
        if (!front && !(list.length && list[0].width === 3840 && list[0].height === 2160))
            list.push(Qt.size(3840, 2160))
        return list
    }
    property var wideBroken: ({})       // camera id -> 16:9 sizes it refused (this session)
    readonly property int wideTry: wideBroken[selectedId] || 0
    readonly property var wideSize: wideTry < wideSizes.length ? wideSizes[wideTry] : null
    readonly property var photoResolution: (wide && wideSize) ? wideSize : Qt.size(-1, -1)   // -1 = camera default

    onWideChanged: {
        photoSize = ""                                  // measure the new format's first photo
        if (camera.cameraStatus === Camera.ActiveStatus || camera.cameraStatus === Camera.LoadedStatus)
            matchViewfinder()
    }

    // ------------------------------------------------------------------ viewfinder format
    // A viewfinder in another format than the photo makes the camera switch modes for every
    // photo, which costs time; the same format also shows exactly what will be in the photo.
    // The smallest size that still covers the screen is enough (1440x1080 for 4:3, 1920x1080
    // for 16:9 on a 1080 px wide screen): a bigger one only costs time and power. The choice is
    // remembered per format, so the next start opens the camera with it right away.
    // Remembered per camera AND format: in 0.1.0-15 one size was shared, so the front camera got
    // the back camera's size, which it does not support: black, "failed to negotiate caps".
    readonly property var vfMap: parseJson(cfg.vfSizes)
    readonly property string formatKey: (selectedId || (front ? "front" : "back")) + ":"
                                        + cfg.aspect
    readonly property var viewfinderSize: videoMode ? videoViewfinder
                                          : parseSize(vfMap[formatKey]) || Qt.size(-1, -1)

    function parseJson(text) {
        try { return JSON.parse(text || "{}") } catch (e) { return {} }
    }

    function rememberViewfinder(w, h) {
        var m = parseJson(cfg.vfSizes)
        m[formatKey] = w + "x" + h
        cfg.vfSizes = JSON.stringify(m)
    }

    function forgetViewfinder() {
        var m = parseJson(cfg.vfSizes)
        delete m[formatKey]
        cfg.vfSizes = JSON.stringify(m)
    }

    function matchViewfinder() {
        var list = camera.supportedViewfinderResolutions()
        var screenShort = page.screenW
        var rw = wideFrame ? 16 : 4, rh = wideFrame ? 9 : 3
        var best = null, biggest = null
        for (var i = 0; list && i < list.length; ++i) {
            var w = Math.max(list[i].width, list[i].height)
            var h = Math.min(list[i].width, list[i].height)
            if (Math.abs(w * rh - h * rw) > w * 0.02 * rh) continue    // other format
            if (!biggest || w * h > biggest.w * biggest.h) biggest = { w: w, h: h }
            if (h >= screenShort && (!best || w * h < best.w * best.h)) best = { w: w, h: h }
        }
        best = best || biggest
        if (!best) return
        if (vfMap[formatKey] !== best.w + "x" + best.h) rememberViewfinder(best.w, best.h)
    }

    // The real size of the first photo of a session (the camera only says "default")
    property string photoSize: ""

    // Measured once per camera and format. The 4:3 size of each camera is remembered: it is the
    // camera's full sensor size, from which the front camera's 16:9 size is worked out.
    function readPhotoSize(path) {
        if (photoSize !== "") return
        photoSize = "…"
        requestPython()
        // taken at the camera's default size (no 16:9 size set): that is its full sensor size
        var camId = selectedId, wasWide = photoResolution.width > 0
        var ask = function () {
            py.call("camworker.image_size", [path], function (size) {
                page.photoSize = size ? size[0] + "x" + size[1] + " ("
                                        + (size[0] * size[1] / 1e6).toFixed(1) + " MP)" : "?"
                console.log("FastShot: photo size " + page.photoSize + " (" + camId + ")")
                if (size && !wasWide) {
                    var m = page.parseJson(cfg.photoSizes)
                    var s = Math.max(size[0], size[1]) + "x" + Math.min(size[0], size[1])
                    if (m[camId] !== s) {
                        m[camId] = s
                        cfg.photoSizes = JSON.stringify(m)
                    }
                }
            })
        }
        if (pyReady) ask()
        else pyReadyCallbacks.push(ask)
    }

    property var pyReadyCallbacks: []

    // ------------------------------------------------------------------ camera info (for tuning)
    function cameraInfo() {
        var t = []
        var all = QtMultimedia.availableCameras
        t.push("Cameras: " + all.length)
        for (var i = 0; i < all.length; ++i)
            t.push("  " + all[i].deviceId + " | " + all[i].displayName + " | position "
                   + all[i].position + " | orientation " + all[i].orientation)
        t.push("Selected: " + (selectedId || "(default)") + ", orientation " + camera.orientation)
        t.push("Phone turned: " + deviceRotation + " (" + rotationSource() + "; orientation sensor "
               + osRotation + ", accelerometer " + accelRotation + "), photo rotation now "
               + captureRotation())
        t.push("Status: " + camera.cameraStatus + ", state " + camera.cameraState)
        t.push("Screen: " + Screen.width + "x" + Screen.height + ", page " + Math.round(page.width) + "x"
               + Math.round(page.height) + ", viewfinder item " + Math.round(viewfinder.width) + "x"
               + Math.round(viewfinder.height) + ", picture " + Math.round(viewfinder.contentRect.width)
               + "x" + Math.round(viewfinder.contentRect.height) + ", full screen " + cfg.fullScreen)
        t.push("Viewfinder: " + camera.viewfinder.resolution.width + "x" + camera.viewfinder.resolution.height)
        var vf = camera.supportedViewfinderResolutions()
        var s = []
        for (var j = 0; vf && j < vf.length; ++j) s.push(vf[j].width + "x" + vf[j].height)
        t.push("Viewfinder options: " + (s.length ? s.join(", ") : "none reported"))
        t.push("Photo resolution: " + camera.imageCapture.resolution.width + "x"
               + camera.imageCapture.resolution.height + " (-1 = camera default)")
        t.push("Last photo: " + (photoSize !== "" ? photoSize : "no photo taken yet"))
        t.push("Format: " + cfg.aspect + ", 16:9 size "
               + (wideSize ? wideSize.width + "x" + wideSize.height : "camera default")
               + (jollaWide.value ? " (from the Sailfish camera settings)" : " (no Sailfish camera setting)")
               + (wideTry > 0 ? ", " + wideTry + " bigger size(s) refused by this camera" : "")
               + (wideSizes.length > 1 ? " (tries " + wideSizes.map(function (s) {
                     return s.width + "x" + s.height }).join(", then ") + ")" : ""))
        t.push("Remembered viewfinders: " + cfg.vfSizes)
        t.push("Measured full-size photos: " + cfg.photoSizes)
        if (wide && !wideSize)
            t.push("16:9 on this camera: take one photo first (it measures the sensor), then 16:9 is used")
        t.push("Focus: continuous " + camera.focus.isFocusModeSupported(Camera.FocusContinuous)
               + ", auto " + camera.focus.isFocusModeSupported(Camera.FocusAuto)
               + ", point " + camera.focus.isFocusPointModeSupported(Camera.FocusPointCustom))
        t.push("Exposure now: ISO " + camera.exposure.iso + ", shutter " + camera.exposure.shutterSpeed
               + " s, aperture " + camera.exposure.aperture)
        var lc = []
        for (var sc in lightCounts) lc.push(sc + " " + lightCounts[sc])
        t.push("Smart auto light: last " + (lastLight || "none yet (needs Enhance: Smart auto)")
               + (lc.length ? "; this session " + lc.join(", ") : "")
               + "; noisy photos done on the processor: " + noisyOnCpu)
        t.push("Light sensor: "
               + (lux >= 0 ? Math.round(lux) + " lux" : (lightSensor ? "no reading yet" : "no sensor"))
               + (dark ? " (dark)" : "")
               + "; brightness asked " + cfg.evCompensation + " EV, camera has "
               + camera.exposure.exposureCompensation + " EV")
        t.push("Focus timing: " + stat(focusTimes) + " ms until sharp, " + focusTimeouts
               + " waits ran out (limit " + cfg.focusWait + " ms), focus on touch " + cfg.focusOnTouch)
        t.push("Focus distance in the last photo: "
               + (!distanceRead ? "no photo checked yet"
                  : distanceText !== "" ? distanceText + " (EXIF distance " + focusMetres + " m, range "
                                          + focusZone + ")"
                  : "not written by this camera"))
        t.push("QR scanner: " + (qrScans > 0 ? qrScans + " pictures read, last took " + qrMs + " ms"
                                             : "not used yet")
               + ", reads " + (qrMethod === "viewfinder" ? "viewfinder copies" : "photos (viewfinder copies were black)")
               + (qrBlack > 0 ? ", black copies in a row: " + qrBlack : ""))
        t.push("Zoom: optical " + camera.maximumOpticalZoom + ", digital steps " + camera.maximumDigitalZoom
               + " (taken as up to " + zoomMaxFactor + "x), now step " + camera.digitalZoom.toFixed(1)
               + " = " + zoomFactor.toFixed(2) + "x")
        t.push("Volume keys: " + (keysStatus || "not set up yet"))
        t.push("")
        t.push("Timings in ms (last / average of up to 10):")
        t.push("  App start -> camera running: " + (startMs >= 0 ? startMs : "no data yet"))
        if (win) {
            var ps = win.processStart > 0 ? Math.round(win.startTime - win.processStart) : -1
            t.push("  Start breakdown: process -> window " + (ps >= 0 ? ps + (ps > 30000 ? " (booster)" : "") : "?")
                   + ", window -> page built " + (pageBuiltAt > 0 ? Math.round(pageBuiltAt - win.startTime) : "?")
                   + ", -> camera loaded " + (loadedAt > 0 ? Math.round(loadedAt - win.startTime) : "?")
                   + ", -> running " + (startMs >= 0 ? startMs : "?"))
        }
        t.push("  Steady-shot waits: " + stat(steadyWaits) + "; raise-to-focus: " + raiseFocusCount)
        t.push("  GPU enhancement: " + (cfg.gpuEnhance ? "on" : "off") + ", " + gpuJobsDone + " photos"
               + (gpuStatus !== "" ? ", " + gpuStatus : "") + (waitingForCharger ? ", waiting for the charger" : ""))
        t.push("  Back to app -> camera running: " + (resumeMs >= 0 ? resumeMs + " (from " + resumeFrom + ")"
                                                                      : "no data yet"))
        t.push("  Back/front switch -> camera running: direct " + stat(lagSwitch)
               + ", released first " + stat(lagSwitchU) + " (now: "
               + (cfg.switchUnload ? "released first" : "direct") + ")")
        t.push("Video: mode " + (videoMode ? "video" : "photo") + ", " + videoSize.width + "x"
               + videoSize.height + ", recorder state " + camera.videoRecorder.recorderState
               + ", last " + (lastVideo || "none") + (videoError !== "" ? ", error: " + videoError : ""))
        t.push("  Press -> capture started: " + stat(lagStart))
        t.push("  Press -> photo taken: " + stat(lagTaken) + " (preview events: " + previewEvents + ")")
        t.push("  Press -> file saved: " + stat(lagSaved))
        t.push("  Between burst shots: " + stat(burstGaps))
        t.push("  Photo while the last one saves: " + eagerState)
        t.push("  Selfie burst pause: " + cfg.frontBurstGap + " ms; stuck camera restarts: " + stuckCount)
        t.push("  Focus before shot: " + (cfg.focusBeforeShot ? "on" : "off") + ", flash: " + cfg.flash)
        return t.join("\n")
    }

    function cameraReady() {
        if (!camera.imageCapture.ready || restarting) return
        // The selfie camera froze in a burst when the next photo followed "ready" at once: it
        // gets a short pause between shots (dconf key frontBurstGap, ms). The back camera does not.
        var gap = front ? cfg.frontBurstGap : 0
        var wait = lastCaptureStart + gap - Date.now()
        if ((pendingShots > 0 || holding) && wait > 0) {
            burstGapTimer.interval = Math.max(10, Math.round(wait))
            burstGapTimer.restart()
            return
        }
        if (pendingShots > 0) {
            pendingShots -= 1
            capture()
        } else if (holding) {
            capture()
        }
    }

    Timer {
        id: burstGapTimer
        onTriggered: page.cameraReady()
    }

    // ------------------------------------------------------------------ watchdog
    // If a photo never finishes, or the camera does not become ready again after one, the
    // camera is stuck (seen with bursts on the selfie camera). Restart it, which is what
    // switching cameras did by hand, instead of leaving a frozen viewfinder.
    Timer {
        id: captureWatchdog
        interval: 6000
        onTriggered: page.checkStuck()
    }

    function checkStuck() {
        // in video mode the photo side is never "ready": a restart would kill a recording
        if (videoMode || camera.cameraStatus !== Camera.ActiveStatus || restarting) return
        if (inFlight === 0 && camera.imageCapture.ready) return        // all fine
        console.warn("FastShot: camera stuck (" + formatKey + ", " + inFlight
                     + " photos unfinished, ready " + camera.imageCapture.ready + "), restarting it")
        inFlight = 0
        pendingShots = 0
        presses = []
        shots = ({})
        holding = false
        focusing = false
        lockedForShot = false
        burstGapTimer.stop()
        showLastPhoto()
        restartCamera()
        message = qsTr("The camera stopped responding and was restarted")
        stuckCount += 1
    }

    property int stuckCount: 0

    function queueEnhance(path) {
        if (cfg.enhanceMode === "off") return
        // the light sensor at the shot: smart auto's fallback when the photo has no exposure EXIF
        var job = [path, cfg.enhanceMode, cfg.keepOriginal, lux >= 0 ? lux : -1]
        if (pyReady) {
            py.call("camworker.queue_photo", job, function () {})
        } else {
            waiting.push(job)
            requestPython()
        }
    }

    // Python is started only while the camera runs undisturbed (on top, active, for 1 s), never
    // while the camera is starting or switching; queued photos wait for it.
    property bool pythonWanted: false

    function requestPython() {
        pythonWanted = true
    }

    function startPython() {
        if (py) return
        console.log("FastShot: starting Python")
        py = pythonComponent.createObject(page)
    }

    Timer {
        interval: 100
        running: page.pythonWanted && !page.py && page.onTop && !page.restarting
                 && camera.cameraStatus === Camera.ActiveStatus
        onTriggered: page.startPython()
    }

    onOnTopChanged: if (!onTop) holdEnhancing(0)   // settings open: the camera is idle

    // Leaving the app keeps the camera loaded (not running) for 30 s, so coming back quickly
    // only has to restart the stream; after that it is released for other apps.
    property bool keepLoaded: false

    Timer {
        id: releaseTimer
        interval: Math.max(5, cfg.keepLoadedSec) * 1000   // settings: 30 s, 2 min or 5 min
        onTriggered: page.keepLoaded = false
    }

    onCameraWantedChanged: {
        // leaving the app finishes a video file before the camera pauses
        if (!cameraWanted && recording) camera.videoRecorder.stop()
        if (orient) orient.active = cameraWanted
        if (lightSensor) lightSensor.active = cameraWanted
        if (accel) accel.active = cameraWanted
        if (cameraWanted) {
            releaseTimer.stop()
            resumeStart = Date.now()
            resumeFrom = camera.cameraStatus === Camera.LoadedStatus ? "loaded" : "unloaded"
        } else {
            keepLoaded = true
            releaseTimer.restart()
            holdEnhancing(0)          // the camera is idle now: enhance at full speed
        }
    }

    // Things the first frame does not need wait until the camera is running (or 1.5 s at most)
    Timer {
        id: deferred
        interval: 1500
        running: true
        onTriggered: page.startDeferred()
    }
    Connections {
        target: camera
        onCameraStatusChanged: {
            console.log("FastShot camera status " + camera.cameraStatus + " (" + page.formatKey + ")")
            if (camera.cameraStatus === Camera.LoadedStatus) {
                if (page.loadedAt === 0) page.loadedAt = Date.now()
                page.matchViewfinder()   // before it starts
            }
            else if (camera.cameraStatus === Camera.ActiveStatus) {
                var now = Date.now()
                if (page.startMs < 0 && page.win) {
                    page.startMs = now - page.win.startTime
                    console.log("FastShot timing: app start -> camera running " + page.startMs + " ms")
                } else if (page.resumeStart > 0) {
                    page.resumeMs = now - page.resumeStart
                    console.log("FastShot timing: back to app -> camera running " + page.resumeMs
                                + " ms (from " + page.resumeFrom + ")")
                }
                page.startDeferred()
                if (page.switching) page.endSwitch()
            }
        }
        onLockStatusChanged: {
            if (camera.lockStatus === Camera.Locked) page.focusDone(false)
            // back to Unlocked while searching: the camera could not focus, do not wait longer
            else if (camera.lockStatus === Camera.Unlocked && page.focusing
                     && Date.now() - page.focusStartedAt > 50) page.focusDone(true)
        }
    }
    onNeedPythonChanged: if (needPython && !deferred.running) requestPython()
    Connections {
        target: cfg
        onSteadyShotChanged: if (cfg.steadyShot) page.createGyro()
    }

    property bool deferredDone: false
    function startDeferred() {
        if (deferredDone) return
        deferredDone = true
        deferred.stop()
        createSensor()
        createLightSensor()
        createHardwareKeys()
        if (cfg.steadyShot) createGyro()
        if (needPython) requestPython()
    }

    // ------------------------------------------------------------------ hardware keys
    // Sailfish gives the volume keys to the system volume. A camera app takes them over by
    // acquiring the "ScaleButton" resource (Nemo policy) and listening with MediaKey
    // (Sailfish.Media). Both are created at run time, so a missing plugin only disables the keys.
    readonly property bool keysWanted: cfg.volumeKeys && cameraWanted && onTop
    property var keyPolicy: null
    property var mediaKeys: []
    property string keysStatus: ""      // shown in the settings: "ok" or what is missing
    property bool keyHeld: false

    function createHardwareKeys() {
        var imports = ["Nemo.Policy 1.0", "org.nemomobile.policy 1.0"]
        for (var i = 0; i < imports.length && !keyPolicy; ++i) {
            try {
                keyPolicy = Qt.createQmlObject(
                    "import QtQuick 2.6\nimport " + imports[i] + "\n"
                    + "Permissions { enabled: false; autoRelease: true; applicationClass: \"camera\"\n"
                    + "  property bool acquired: scaleButton.acquired\n"
                    + "  Resource { id: scaleButton; type: Resource.ScaleButton; optional: true } }",
                    page, "KeyPolicy")
            } catch (e) {
                console.warn("FastShot: " + imports[i] + ": " + e)
            }
        }
        if (keyPolicy)
            keyPolicy.enabled = Qt.binding(function () { return page.keysWanted })

        var keys = [Qt.Key_VolumeUp, Qt.Key_VolumeDown, Qt.Key_Camera]
        var made = []
        for (var k = 0; k < keys.length; ++k) {
            try {
                var mk = Qt.createQmlObject("import QtQuick 2.6\nimport Sailfish.Media 1.0\n"
                                            + "MediaKey { key: " + keys[k] + "; enabled: false }",
                                            page, "MediaKey")
                mk.enabled = Qt.binding(function () {
                    return page.keysWanted && (!page.keyPolicy || page.keyPolicy.acquired)
                })
                mk.pressed.connect(page.hardwarePressed)
                mk.released.connect(page.hardwareReleased)
                made.push(mk)
            } catch (e2) {
                console.warn("FastShot: Sailfish.Media MediaKey: " + e2)
                break
            }
        }
        mediaKeys = made
        // Without Sailfish.Media (as on the Xperia 10 III) the keys arrive as normal key
        // events once the ScaleButton resource is ours: handled by Keys.onPressed below.
        keysViaMediaKey = made.length > 0
        var notes = []
        if (!keyPolicy) notes.push(qsTr("Nemo.Policy missing, the keys may also change the volume"))
        if (!keysViaMediaKey) notes.push(qsTr("using key events"))
        keysStatus = notes.length > 0 ? notes.join("; ") : "ok"
    }

    property bool keysViaMediaKey: false

    function isShutterKey(key) {
        return key === Qt.Key_VolumeUp || key === Qt.Key_VolumeDown || key === Qt.Key_Camera
    }

    focus: true
    onStatusChanged: if (status === PageStatus.Active) forceActiveFocus()

    Keys.onPressed: {
        if (!page.keysWanted || page.keysViaMediaKey || !page.isShutterKey(event.key)) return
        event.accepted = true
        if (!event.isAutoRepeat) page.hardwarePressed()
    }
    Keys.onReleased: {
        if (!page.keysWanted || page.keysViaMediaKey || !page.isShutterKey(event.key)) return
        event.accepted = true
        if (!event.isAutoRepeat) page.hardwareReleased()
    }

    // A press takes a photo at once; holding the key for 0.6 s shoots a burst
    function hardwarePressed() {
        if (keyHeld) return            // key repeat, or both volume keys at once
        keyHeld = true
        burstCount = 0
        if (videoMode) {
            toggleRecording()
            return
        }
        shoot()
        keyHoldTimer.restart()
    }

    function hardwareReleased() {
        keyHeld = false
        keyHoldTimer.stop()
        holding = false
        if (inFlight === 0) flushPanorama()
    }

    Timer {
        id: keyHoldTimer
        interval: 600
        onTriggered: { page.holding = true; page.cameraReady() }
    }

    // How the phone is held. Two sensors:
    //  - OrientationSensor: right on this phone (photos upright, verified), but it reports a turn
    //    only after a delay, so a photo taken right after turning (Best of 3) got the old rotation.
    //  - Accelerometer: immediate, but which way its axes point differs between phones; two
    //    guesses (0.2.0-6/-7) were wrong. So FastShot learns it: for each of the 8 possible axis
    //    layouts it counts how often the accelerometer agrees with the orientation sensor once that
    //    has settled. When one layout agrees in two different positions (e.g. upright and
    //    sideways) and the others do not, it is remembered (cfg.gravityMap) and used from then on.
    //    Until then the orientation sensor decides, as in 0.2.0-5.
    property string sensorKind: ""
    property var orient: null
    property var accel: null
    property int osRotation: -1         // from OrientationSensor (0/90/180/270), -1 = unknown
    property real osChangedAt: 0
    property int accelRotation: -1      // from the accelerometer with the learned layout
    property var mapAgree: []           // per layout: { rotation: number of agreeing readings }
    property var mapDisagree: []        // per layout: number of disagreeing readings
    readonly property bool accelCalibrated: cfg.gravityMap >= 0 && cfg.gravityMap < 8

    // Angle of "up" for layout m (0..7): bit 0 swaps x/y, bit 1 flips x, bit 2 flips y.
    // 0 = top up, 90 = left side up, 180 = upside down, 270 = right side up. -1 = lying flat.
    function gravityAngle(m, rx, ry, rz) {
        var u = (m & 1) ? ry : rx
        var v = (m & 1) ? rx : ry
        var x = (m & 2) ? -u : u
        var y = (m & 4) ? -v : v
        var g = Math.sqrt(rx * rx + ry * ry + rz * rz)
        if (Math.sqrt(x * x + y * y) < 0.5 * g) return -1
        var a = Math.atan2(-x, y) * 180 / Math.PI
        return a < 0 ? a + 360 : a
    }

    function snap(a) {
        return (Math.round(a / 90) % 4) * 90
    }

    function applyAccel(rx, ry, rz) {
        // motion detection: large change between consecutive readings = the phone is being moved
        if (isNaN(_prevAx)) { _prevAx = rx; _prevAy = ry; _prevAz = rz }
        else {
            var jerk = Math.abs(rx - _prevAx) + Math.abs(ry - _prevAy) + Math.abs(rz - _prevAz)
            _prevAx = rx; _prevAy = ry; _prevAz = rz
            if (jerk > 1.5) { phoneMoving = true; _stillAt = Date.now() + 250 }
            else if (phoneMoving && Date.now() >= _stillAt) phoneMoving = false
        }
        if (accelCalibrated) {
            var a = gravityAngle(cfg.gravityMap, rx, ry, rz)
            if (a < 0) return                              // flat: keep the last side
            var current = accelRotation >= 0 ? accelRotation : deviceRotation
            var diff = Math.abs(((a - current) % 360 + 540) % 360 - 180)
            if (diff > 55 || accelRotation < 0) {          // no flicker around 45 degrees
                accelRotation = snap(a)
                deviceRotation = accelRotation
            }
            return
        }
        // learning: only when the orientation sensor has settled (no turn for 0.8 s)
        if (osRotation < 0 || Date.now() - osChangedAt < 800) return
        if (mapAgree.length === 0) {
            for (var i = 0; i < 8; ++i) { mapAgree.push({}); mapDisagree.push(0) }
        }
        for (var m = 0; m < 8; ++m) {
            var am = gravityAngle(m, rx, ry, rz)
            if (am < 0) return                             // flat: says nothing
            if (snap(am) === osRotation) mapAgree[m][osRotation] = (mapAgree[m][osRotation] || 0) + 1
            else mapDisagree[m] += 1
        }
        chooseLayout()
    }

    function chooseLayout() {
        var winner = -1
        // Disagreements happen while the phone is being turned (the orientation sensor is slow),
        // so a layout fits when at least 90 % of its readings agree, not when it never disagrees
        // (0.2.0-8 required at most 3 and never finished learning).
        for (var m = 0; m < 8; ++m) {
            var sides = 0, agreed = 0
            for (var r in mapAgree[m]) {
                agreed += mapAgree[m][r]
                if (mapAgree[m][r] >= 10) sides += 1
            }
            var ok = sides >= 2 && mapDisagree[m] <= 0.1 * agreed
            if (!ok) continue
            if (winner >= 0) return                        // two layouts still fit: keep learning
            winner = m
        }
        if (winner < 0) return
        // the positions seen must include two that are 90 degrees apart (upright alone cannot
        // tell a flipped x axis apart)
        var seen = []
        for (var s in mapAgree[winner]) if (mapAgree[winner][s] >= 10) seen.push(parseInt(s, 10))
        var quarter = false
        for (var i = 0; i < seen.length; ++i)
            for (var j = 0; j < seen.length; ++j)
                if ((seen[i] - seen[j] + 360) % 180 === 90) quarter = true
        if (!quarter) return
        cfg.gravityMap = winner
        console.log("FastShot: accelerometer layout learned: " + winner + " (positions " + seen.join(", ") + ")")
    }

    function applyOrientation(o) {
        var r = o === 1 ? 0 : o === 3 ? 90 : o === 2 ? 180 : o === 4 ? 270 : -1
        if (r >= 0 && r !== osRotation) {
            osRotation = r
            osChangedAt = Date.now()
            if (!accelCalibrated) deviceRotation = r      // until the accelerometer is learned
        }
        raised(lastOrientation, o)                        // face up/down: keep the last side
        lastOrientation = o
    }

    function createSensor() {
        // QtSensors is optional: without it photos are stored as taken in portrait
        try {
            orient = Qt.createQmlObject("import QtSensors 5.0; OrientationSensor { active: true }",
                                        page, "OrientationSensor")
            orient.readingChanged.connect(function () {
                if (orient.reading) page.applyOrientation(orient.reading.orientation)
            })
        } catch (e) {
            console.warn("FastShot: no orientation sensor: " + e)
        }
        try {
            accel = Qt.createQmlObject("import QtSensors 5.0; Accelerometer { active: true; dataRate: 20 }",
                                       page, "Accelerometer")
            accel.readingChanged.connect(function () {
                var r = accel.reading
                if (r) page.applyAccel(r.x, r.y, r.z)
            })
        } catch (e2) {
            console.warn("FastShot: no accelerometer: " + e2)
        }
        sensor = orient || accel
        sensorKind = !orient && !accel ? "none" : ""
    }

    function rotationSource() {
        if (accelCalibrated && accel) return "accelerometer, layout " + cfg.gravityMap
        if (orient) return "orientation sensor (accelerometer still learning)"
        return sensorKind || "none"
    }

    // ------------------------------------------------------------------ focus when raised
    // Lying flat (face up/down) -> held up to shoot: focus once right away, so it is already
    // sharp when the shutter is pressed; continuous focus takes over again after 1.5 s.
    property int lastOrientation: 0
    property int raiseFocusCount: 0

    function raised(before, now) {
        if (!cfg.raiseFocus || !onTop || focusing || lockedForShot || raiseUnlock.running) return
        if ((before === 5 || before === 6) && now >= 1 && now <= 4
                && camera.cameraStatus === Camera.ActiveStatus
                && camera.focus.isFocusModeSupported(Camera.FocusAuto)) {
            raiseFocusCount += 1
            camera.searchAndLock()
            raiseUnlock.restart()
        }
    }

    Timer {
        id: raiseUnlock
        interval: 1500
        onTriggered: if (!page.lockedForShot && !page.focusing) camera.unlock()
    }

    // ------------------------------------------------------------------ GPU enhancement
    // Python measures the photo and sends the numbers ("gpu_job"); here the photo is loaded as a
    // texture, the EnhanceEffect shader is applied at full size off-screen, and the result is
    // written to a file that Python turns into the final JPEG (with the original's EXIF).
    // Only while the app is in front (no rendering in the background): otherwise Python uses
    // the CPU. If the result is unusable (e.g. black), Python stops using the GPU for good.
    property int gpuJobsDone: 0
    property string gpuStatus: ""
    property bool waitingForCharger: false
    property var gpuJob: null

    function workerOptions() {
        return { gpu: cfg.gpuEnhance, gpu_available: Qt.application.state === Qt.ApplicationActive,
                 charging_only: cfg.enhanceWhenCharging }
    }

    function sendWorkerOptions() {
        if (pyReady) py.call("camworker.set_options", [workerOptions()], function () {})
    }

    readonly property string workerOptionsKey: cfg.gpuEnhance + "/" + cfg.enhanceWhenCharging + "/"
                                                + (Qt.application.state === Qt.ApplicationActive)
    onWorkerOptionsKeyChanged: {
        sendWorkerOptions()
        if (Qt.application.state !== Qt.ApplicationActive && gpuJob) finishGpuJob("", "inactive")
    }

    function runGpuJob(jobId, src, params, out) {
        if (gpuJob) finishGpuJob("", "superseded")            // a stale job (should not happen)
        if (Qt.application.state !== Qt.ApplicationActive) {
            py.call("camworker.gpu_done", [jobId, "", "inactive"], function () {})
            return
        }
        if (params && params.mode === "auto") cfg.lastParams = JSON.stringify(params)  // live preview
        gpuJob = { id: jobId, out: out, params: params, started: Date.now() }
        gpuSource.source = "file://" + src
    }

    function gpuImageStatus() {
        if (!gpuJob) return
        if (gpuSource.status === Image.Error) {
            finishGpuJob("", "the photo could not be loaded")
        } else if (gpuSource.status === Image.Ready) {
            gpuArea.width = gpuSource.implicitWidth
            gpuArea.height = gpuSource.implicitHeight
            gpuGrabTimer.restart()                            // let the new size reach the scene first
        }
    }

    function grabGpu() {
        if (!gpuJob) return
        var job = gpuJob
        var started = gpuEffect.grabToImage(function (result) {
            if (page.gpuJob !== job) return
            var ok = result.saveToFile(job.out)
            console.log("FastShot GPU: " + gpuArea.width + "x" + gpuArea.height + " in "
                        + (Date.now() - job.started) + " ms, saved " + ok)
            page.finishGpuJob(ok ? job.out : "", ok ? "" : "the result could not be saved")
        }, Qt.size(gpuArea.width, gpuArea.height))
        if (!started) finishGpuJob("", "grabToImage failed")
    }

    function finishGpuJob(file, reason) {
        if (!gpuJob) return
        var id = gpuJob.id
        gpuJob = null
        gpuSource.source = ""
        gpuArea.width = 1
        gpuArea.height = 1
        if (pyReady) py.call("camworker.gpu_done", [id, file, reason], function () {})
    }

    Timer {
        id: gpuGrabTimer
        interval: 50
        onTriggered: page.grabGpu()
    }

    Item {
        id: gpuArea
        x: -width - 100                // off-screen: rendered only for grabToImage
        y: 0
        width: 1
        height: 1
        visible: page.gpuJob !== null

        Image {
            id: gpuSource
            visible: false             // only a texture for the shader
            asynchronous: true
            cache: false
            autoTransform: true        // upright, like the saved JPEG with its EXIF rotation
            mipmap: true               // the large blur for local contrast
            smooth: true
            onStatusChanged: page.gpuImageStatus()
        }

        EnhanceEffect {
            id: gpuEffect
            anchors.fill: parent
            src: gpuSource
            params: page.gpuJob ? page.gpuJob.params : ({})
        }
    }

    Component {
        id: pythonComponent
        Python {
            id: python
            Component.onCompleted: {
                addImportPath(Qt.resolvedUrl("../../python"))
                setHandler("queue", function (n) {
                    page.queued = n
                    if (page.win) page.win.queued = n
                    cfg.queueLeft = n                    // so the next start resumes the queue
                })
                setHandler("failed", function (name, error) {
                    page.message = qsTr("Enhancing %1 failed: %2").arg(name).arg(error)
                })
                setHandler("gpu_job", function (jobId, src, params, out) {
                    page.runGpuJob(jobId, src, params, out)
                })
                setHandler("gpu_used", function (name) { page.gpuJobsDone += 1 })
                setHandler("noisy_on_cpu", function (name) { page.noisyOnCpu += 1 })
                setHandler("gpu_broken", function (reason) {
                    page.gpuStatus = qsTr("not usable on this phone: %1").arg(reason)
                    console.warn("FastShot: GPU enhancement off: " + reason)
                })
                setHandler("waiting_for_charger", function (waiting) { page.waitingForCharger = waiting })
                // smart auto: the light the last photo was taken in (Camera info)
                setHandler("light", function (name, scene, backlit, ev, source) {
                    page.lastLight = (scene || qsTr("unknown")) + (backlit ? ", " + qsTr("backlit") : "")
                                     + " (EV " + (ev > -99 ? ev : "?") + " from " + source + ", " + name + ")"
                    var n = page.lightCounts
                    var key = (scene || "unknown") + (backlit ? "+backlit" : "")
                    n[key] = (n[key] || 0) + 1
                    page.lightCounts = n
                })
                importModule("camworker", function () {
                    python.call("camworker.warm_up", [], function () {})
                    python.call("camworker.camera_dir", [], function (dir) { cfg.saveDir = dir })
                    python.call("camworker.burst_dir", [], function (dir) { cfg.burstDir = dir })
                    python.call("camworker.set_options", [page.workerOptions()], function () {})
                    python.call("camworker.resume_saved", [], function (n) {
                        if (n > 0) console.log("FastShot: resumed " + n + " photo(s) to enhance")
                    })
                    page.pyReady = true
                    var jobs = page.waiting
                    page.waiting = []
                    for (var i = 0; i < jobs.length; ++i)
                        python.call("camworker.queue_photo", jobs[i], function () {})
                    var later = page.pyReadyCallbacks
                    page.pyReadyCallbacks = []
                    for (var j = 0; j < later.length; ++j) later[j]()
                })
            }
            onError: {
                console.warn("FastShot python: " + traceback)
                var lines = String(traceback).split("\n")
                page.message = lines[lines.length - 1] || lines[lines.length - 2]
            }
        }
    }

    // ------------------------------------------------------------------ night mode
    // Off / On / Auto. Auto switches to night exposure when the ambient light sensor reads under
    // 10 lux and back above 25 (no flicker in between). Without a light sensor Auto stays off.
    property var lightSensor: null
    property real lux: -1
    property string lastLight: ""       // light scene smart auto chose for the last photo
    property var lightCounts: ({})      // how often each scene was chosen this session
    property int noisyOnCpu: 0          // noisy photos the processor did although the GPU is on
    property bool dark: false

    function createLightSensor() {
        if (lightSensor) return
        try {
            lightSensor = Qt.createQmlObject("import QtSensors 5.0; LightSensor { active: true }",
                                             page, "LightSensor")
            lightSensor.readingChanged.connect(function () {
                if (!lightSensor.reading) return
                page.lux = lightSensor.reading.illuminance
                if (page.lux < 10) page.dark = true       // kept for Camera info
                else if (page.lux > 25) page.dark = false
            })
        } catch (e) {
            console.warn("FastShot: no light sensor: " + e)
        }
    }

    // ------------------------------------------------------------------ video
    // Brought back from 0.3.0-6 without its fallback steps (all failed the same way). On the
    // Xperia 10 III with Sailfish 5.2 the phone's recorder refuses to start (CameraSource -22, in
    // every app): this shows the error until Jolla fixes it. Switching goes through a full camera
    // restart, the safe way on this phone. H.264 + AAC in MP4, saved to Pictures/Camera.
    readonly property bool videoMode: cfg.captureMode === "video"
    readonly property bool recording: camera.videoRecorder.recorderState === CameraRecorder.RecordingState
    property string lastVideo: ""
    property string videoError: ""
    readonly property var videoSize: cfg.videoRes === "2160" ? Qt.size(3840, 2160)
                                   : cfg.videoRes === "720" ? Qt.size(1280, 720) : Qt.size(1920, 1080)
    // both are in this phone's viewfinder list (Camera info)
    readonly property var videoViewfinder: videoSize.height <= 720 ? Qt.size(1280, 720) : Qt.size(1920, 1080)

    function switchMode() {
        if (recording) return
        qrMode = false
        cfg.captureMode = videoMode ? "photo" : "video"
        restartCamera()                     // captureMode changes while the camera is unloaded
    }

    function toggleRecording() {
        if (recording) {
            camera.videoRecorder.stop()
            return
        }
        if (camera.cameraStatus !== Camera.ActiveStatus || restarting || recordDelay.running) return
        message = ""
        videoError = ""
        camera.metaData.orientation = captureRotation()
        var name = "VID_" + Qt.formatDateTime(new Date(), "yyyyMMdd_hhmmss") + ".mp4"
        if (cfg.saveDir !== "") camera.videoRecorder.outputLocation = cfg.saveDir + "/" + name
        grabThumbnail()
        recordDelay.restart()
    }

    Timer {
        id: recordDelay
        interval: 300
        onTriggered: {
            camera.unlock()                 // no focus lock left from a photo
            camera.videoRecorder.record()
        }
    }

    // The camera is left alone for 2 s before it starts again: an immediate restart after a
    // recorder error crashed the app in 0.3.0-2.
    function videoFailed(error) {
        recordDelay.stop()
        videoError = error
        console.warn("FastShot video failed: " + error)
        restarting = true
        videoRestartTimer.restart()
        message = qsTr("Video could not record: %1").arg(error)
    }

    Timer {
        id: videoRestartTimer
        interval: 2000
        onTriggered: page.restarting = false
    }

    function formatDuration(ms) {
        var s = Math.floor(ms / 1000)
        var m = Math.floor(s / 60)
        s = s % 60
        return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s
    }

    Connections {
        target: camera.videoRecorder
        onRecorderStateChanged: {
            if (camera.videoRecorder.recorderState !== CameraRecorder.StoppedState || page.videoError !== "")
                return
            var loc = String(camera.videoRecorder.actualLocation).replace(/^file:\/\//, "")
            if (loc !== "") {
                page.lastVideo = loc
                page.lastShot = loc               // tap the corner to play it
            }
        }
        onErrorStringChanged: {
            if (camera.videoRecorder.errorString === "") return
            if (page.videoError === "") page.videoFailed(camera.videoRecorder.errorString)
        }
    }

    Camera {
        id: camera
        deviceId: page.selectedId
        captureMode: page.videoMode ? Camera.CaptureVideo : Camera.CaptureStillImage
        // As Sailfish's own camera: MP4, H.264, AAC, average bit rate (Qt's default constant
        // quality is not supported by the phone's encoder)
        videoRecorder {
            resolution: page.videoSize
            frameRate: 0
            mediaContainer: "video/quicktime, variant=(string)iso"
            videoCodec: "video/x-h264"
            audioCodec: "audio/mpeg, mpegversion=(int)4"
            audioSampleRate: 48000
            audioChannels: 1
            videoEncodingMode: CameraRecorder.AverageBitRateEncoding
            videoBitRate: cfg.videoRes === "2160" ? 40000000 : cfg.videoRes === "720" ? 6000000 : 12000000
        }
        // -1x-1 = the camera's default until matchViewfinder() has chosen one
        viewfinder.resolution: page.viewfinderSize
        imageCapture.resolution: page.videoMode ? page.videoSize : page.photoResolution
        cameraState: page.restarting ? Camera.UnloadedState
                     : page.cameraWanted ? Camera.ActiveState
                     : (page.keepLoaded ? Camera.LoadedState : Camera.UnloadedState)
        // no flash while scanning QR codes (the scanner may take photos twice a second)
        flash.mode: page.qrMode || page.videoMode ? Camera.FlashOff
                    : page.flashModes[cfg.flash] !== undefined ? page.flashModes[cfg.flash] : Camera.FlashAuto
        focus.focusMode: Camera.FocusContinuous
        focus.focusPointMode: Camera.FocusPointAuto
        // Brightness correction in EV. Whether the camera driver supports it shows in Camera info.
        exposure.exposureCompensation: cfg.evCompensation

        imageCapture {
            onReadyChanged: page.cameraReady()
            // Not every camera backend sends this (the Xperia 10 III did not in 0.1.0-7), so
            // nothing important may depend on it: feedback and focus release happen elsewhere.
            onImageCaptured: {
                page.previewEvents += 1
                var shot = page.shots[requestId]
                if (shot) {
                    shot.captured = Date.now()
                    page.remember(page.lagTaken, shot.captured - shot.press)
                }
                page.releaseShotLock()
            }
            onImageSaved: {
                if (requestId === page.qrRequest) {           // taken only for the QR scanner
                    page.qrRequest = -1
                    page.callPython("camworker.scan_qr", [path, true], page.qrResult)
                    return
                }
                page.releaseShotLock()
                if (requestId === page.eagerRequest) {        // taken while the last one was saving
                    page.eagerRequest = -1
                    page.eagerState = "works"
                }
                var shot = page.shots[requestId]
                var group = shot ? shot.group : -1
                if (shot) {
                    page.remember(page.lagSaved, Date.now() - shot.press)
                    console.log("FastShot timing: press -> taken " + (shot.captured ? shot.captured - shot.press : "?")
                                + " ms, -> saved " + (Date.now() - shot.press) + " ms")
                    delete page.shots[requestId]
                }
                var hidden = cfg.burstDir !== "" && String(path).indexOf(cfg.burstDir + "/") === 0
                if (group >= 0) {
                    page.groupPhoto(group, path)             // best of 3 decides, then enhances
                } else if (group === -2) {
                    page.panoFiles.push(path)
                } else if (hidden) {
                    page.burstFiles.push(path)               // moved and enhanced after the burst
                } else {
                    page.lastShot = path
                    page.readPhotoSize(path)
                    page.readDistance(path)
                    page.queueEnhance(path)
                }
                page.photoDone()
            }
            onCaptureFailed: {
                if (requestId === page.qrRequest) {
                    page.qrRequest = -1
                    page.qrBusy = false
                    return
                }
                page.releaseShotLock()
                if (page.eagerRefused(requestId)) return    // retried when ready, not an error
                var failedShot = page.shots[requestId]
                if (failedShot && failedShot.group >= 0) page.groupPhoto(failedShot.group, "")
                page.photoDone()                             // show the last saved photo again
                page.message = qsTr("Capture failed: %1").arg(message)
            }
        }
        onError: page.recover(errorString)
    }

    // ------------------------------------------------------------------ recovery
    // If the camera fails to start with a remembered viewfinder size or the 16:9 photo size,
    // drop that size and start again with the camera's defaults, instead of staying black.
    property bool restarting: false
    property int recoverStep: 0

    function recover(error) {
        console.warn("FastShot camera error (" + formatKey + "): " + error)
        if (videoMode && (recording || /record/i.test(error))) {
            videoFailed(error)
            return
        }
        if (recoverStep < 1 && vfMap[formatKey]) {
            recoverStep = 1
            forgetViewfinder()
            restartCamera()
            return
        }
        // a refused 16:9 size: try the next one (the list is short, so this ends)
        if (photoResolution.width > 0) {
            recoverStep = 2
            console.warn("FastShot: 16:9 size " + wideSize.width + "x" + wideSize.height + " refused")
            var b = {}                                 // a new object, so the bindings update
            for (var k in wideBroken) b[k] = wideBroken[k]
            b[selectedId] = wideTry + 1
            wideBroken = b
            restartCamera()
            return
        }
        message = error
    }

    function restartCamera() {
        message = ""
        restarting = true
        restartTimer.restart()
    }

    Timer {
        id: restartTimer
        interval: 500                  // long enough for the camera to be fully released
        onTriggered: page.restarting = false
    }

    onSelectedIdChanged: {
        recoverStep = 0
        photoSize = ""                 // measure the other camera's first photo too
        camera.digitalZoom = 1         // each camera starts unzoomed
    }
    onFormatKeyChanged: recoverStep = 0

    Rectangle { anchors.fill: parent; color: "black" }

    // ------------------------------------------------------------------ viewfinder
    // The real screen (Screen, in pixels: 1080x2520 = 21:9 on the Xperia 10 III). For full screen
    // the viewfinder item is made bigger than the screen, with the picture's own shape, so the
    // picture covers every pixel; the screen cuts off the rest. This does not rely on the
    // backend supporting PreserveAspectCrop (it did not fill the screen on the Xperia 10 III).
    readonly property real screenW: Math.min(Screen.width, Screen.height)    // portrait
    readonly property real screenH: Math.max(Screen.width, Screen.height)
    // picture shape in portrait (width / height): from the viewfinder size, else from the format
    readonly property real frameAspect: {
        var s = viewfinderSize
        if (s.width > 0 && s.height > 0) return Math.min(s.width, s.height) / Math.max(s.width, s.height)
        return wideFrame ? 9 / 16 : 3 / 4
    }

    Item {
        id: viewArea
        anchors.centerIn: parent
        width: page.screenW
        height: page.screenH
        clip: true

        VideoOutput {
            id: viewfinder
            anchors.centerIn: parent
            // cover: at least the screen in both directions, keeping the picture's shape
            width: cfg.fullScreen ? Math.max(parent.width, parent.height * page.frameAspect) : parent.width
            height: cfg.fullScreen ? Math.max(parent.height, parent.width / page.frameAspect) : parent.height
            source: camera
            fillMode: VideoOutput.PreserveAspectFit
            // The Sailfish camera backend already turns the frames upright; adding the sensor's
            // mounting angle (camera.orientation) on top turned the picture by 90 degrees.
            orientation: ((cfg.viewfinderFix % 360) + 360) % 360
        }

        // Live preview of the enhancement: the viewfinder through the same shader as the photos,
        // with the numbers of the last smart-auto photo (or the chosen preset).
        Loader {
            anchors.fill: viewfinder
            active: page.livePreviewOn
            sourceComponent: Item {
                ShaderEffectSource {
                    id: liveSource
                    anchors.fill: parent
                    sourceItem: viewfinder
                    hideSource: !page.phoneMoving      // moving: show the raw viewfinder
                    live: !page.phoneMoving             // moving: stop updating the texture
                    mipmap: true
                    visible: false
                }
                EnhanceEffect {
                    anchors.fill: parent
                    src: liveSource
                    params: page.livePreviewParams
                    fullDenoise: 0
                    visible: !page.phoneMoving          // moving: hide the shader output
                }
            }
        }
    }

    // The last picture, frozen while the camera switches (see beginSwitch). A copy of the whole
    // view on the GPU; it fades out when the other camera runs. A black copy is not a risk:
    // it only shows for a moment and the guard timer removes it.
    ShaderEffectSource {
        id: switchSnap
        anchors.centerIn: parent
        width: viewArea.width
        height: viewArea.height
        sourceItem: viewArea
        live: false
        hideSource: false
        visible: opacity > 0
        opacity: page.switching ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 180 } }
    }

    // ------------------------------------------------------------------ live preview numbers
    readonly property bool livePreviewOn: cfg.livePreview && cfg.enhanceMode !== "off"
    // Preset numbers without a photo to measure: no black/white point or white-balance change;
    // exposure becomes a mild gamma. Smart auto uses the last photo's measured numbers.
    readonly property var presetValues: ({
        lowlight: { exposure: 80, shadows: 55, highlights: 20, local: 25, color: 25, denoise: 60, sharpen: 25 },
        vivid: { exposure: 40, shadows: 25, highlights: 30, local: 50, color: 70, denoise: 15, sharpen: 45 },
        subtle: { exposure: 30, shadows: 15, highlights: 12, local: 15, color: 15, denoise: 10, sharpen: 20 },
        auto: { exposure: 50, shadows: 30, highlights: 25, local: 30, color: 30, denoise: 20, sharpen: 35 }
    })
    readonly property var livePreviewParams: {
        if (cfg.enhanceMode === "auto" && cfg.lastParams !== "") {
            var last = parseJson(cfg.lastParams)
            if (last.gains) return last
        }
        var v = presetValues[cfg.enhanceMode] || presetValues.subtle
        return { gains: [1, 1, 1], lo: 0, hi: 255, gamma: 1 - 0.25 * v.exposure / 100,
                 shadows: v.shadows / 100, highlights: v.highlights / 100, local: v.local / 100,
                 color: v.color / 100, denoise: v.denoise / 100, sharpen: v.sharpen / 100 }
    }

    // ------------------------------------------------------------------ zoom
    // Pinch to zoom. Digital only: the phone offers apps no tele lens (Xperia 10 III: "optical 1"),
    // so this is a crop of the main camera's picture; up to about 2x it still looks good.
    // camera.digitalZoom is NOT a magnification on this phone: the camera reports "100", which are
    // the Android camera's zoom steps (1 = none, 100 = the most it can do). In 0.2.0-4 "8x" was
    // step 8, about 1.6x in reality. The steps are taken as evenly spaced up to cfg.zoomMaxFactor
    // (8x, typical for these cameras; correct it with dconf if the phone's top zoom differs).
    readonly property real zoomSteps: Math.max(1, camera.maximumDigitalZoom)
    readonly property real zoomMaxFactor: zoomSteps > 1 ? Math.max(1.1, cfg.zoomMaxFactor) : 1
    readonly property real zoomFactor: factorOf(camera.digitalZoom)
    property real zoomAtPinchStart: 1

    function factorOf(step) {
        if (zoomSteps <= 1) return 1
        return 1 + (Math.max(1, step) - 1) * (zoomMaxFactor - 1) / (zoomSteps - 1)
    }

    function stepOf(factor) {
        if (zoomSteps <= 1) return 1
        return 1 + (factor - 1) * (zoomSteps - 1) / (zoomMaxFactor - 1)
    }

    function setZoom(factor) {
        var f = Math.max(1, Math.min(zoomMaxFactor, factor))
        camera.digitalZoom = Math.max(1, Math.min(zoomSteps, stepOf(f)))
    }

    // Tap to focus on a point (continuous focus returns after 3 s); pinch with two fingers to zoom
    PinchArea {
        anchors.fill: viewArea
        onPinchStarted: page.zoomAtPinchStart = page.zoomFactor
        onPinchUpdated: page.setZoom(page.zoomAtPinchStart * pinch.scale)

        MouseArea {
            anchors.fill: parent
            onClicked: {
                var v = mapToItem(viewfinder, mouse.x, mouse.y)
                var p = viewfinder.mapPointToSourceNormalized(Qt.point(v.x, v.y))
                if (camera.focus.isFocusPointModeSupported(Camera.FocusPointCustom)) {
                    camera.focus.focusPointMode = Camera.FocusPointCustom
                    camera.focus.customFocusPoint = p
                }
                camera.searchAndLock()
                var r = mapToItem(page, mouse.x, mouse.y)
                focusRing.x = r.x - focusRing.width / 2
                focusRing.y = r.y - focusRing.height / 2
                focusRing.visible = true
                unlockTimer.restart()
            }
        }
    }

    // Zoom level; tap it to go back to 1x
    Rectangle {
        anchors { horizontalCenter: parent.horizontalCenter; bottom: lensRow.top
                  bottomMargin: Theme.paddingLarge * 3 }
        visible: page.zoomFactor > 1.02
        width: zoomText.width + 2 * Theme.paddingMedium
        height: Theme.itemSizeSmall
        radius: height / 2
        color: Qt.rgba(0, 0, 0, 0.45)
        border { width: 1; color: "white" }
        Label {
            id: zoomText
            anchors.centerIn: parent
            text: page.zoomFactor.toFixed(1) + "×"
            color: page.zoomFactor > 2.05 ? "#ffcc66" : "white"      // past 2x: visibly softer
            font.pixelSize: Theme.fontSizeMedium
            font.bold: true
            rotation: -page.deviceRotation
            Behavior on rotation { RotationAnimation { duration: 200; direction: RotationAnimation.Shortest } }
        }
        MouseArea { anchors.fill: parent; onClicked: page.setZoom(1) }
    }

    Rectangle {
        id: focusRing
        visible: false
        width: Theme.itemSizeLarge
        height: width
        radius: width / 2
        color: "transparent"
        border { width: 3; color: camera.lockStatus === Camera.Locked ? "#7CFC00" : "white" }
        SequentialAnimation on opacity {
            id: focusPulse
            running: focusRing.visible && camera.lockStatus !== Camera.Locked
            loops: Animation.Infinite
            NumberAnimation { to: 0.4; duration: 400 }
            NumberAnimation { to: 1.0; duration: 400 }
        }
        onVisibleChanged: if (visible) opacity = 1
    }

    Timer {
        id: unlockTimer
        interval: 3000
        onTriggered: {
            camera.unlock()
            camera.focus.focusPointMode = Camera.FocusPointAuto
            focusRing.visible = false
        }
    }

    // ------------------------------------------------------------------ panorama guide
    // While a panorama is shot: a level line to follow and how fast the phone turns.
    // shortcut: 40 deg/s limit is a guess for this phone's burst rate; tune after real panoramas
    readonly property bool panoGuide: holding && cfg.burstMode === "panorama"
    readonly property real panoSpeedLimit: 40
    property real panoSpeed: 0            // smoothed turn rate, degrees per second
    readonly property bool panoTooFast: panoSpeed > panoSpeedLimit

    onPanoGuideChanged: {
        if (panoGuide) {
            createGyro()
            panoSpeed = 0
        } else if (gyro && !steadying) {
            gyro.active = false
        }
    }

    Timer {
        interval: 50
        repeat: true
        running: page.panoGuide && page.gyro !== null
        onTriggered: {
            page.gyro.active = true          // steady shot may have switched it off
            var r = page.gyro.reading
            if (!r) return
            var turn = Math.abs(r.x) + Math.abs(r.y) + Math.abs(r.z)
            page.panoSpeed = page.panoSpeed * 0.7 + turn * 0.3
        }
    }

    Item {
        anchors.centerIn: parent
        width: page.deviceRotation % 180 ? parent.height : parent.width
        height: page.deviceRotation % 180 ? parent.width : parent.height
        rotation: -page.deviceRotation
        visible: page.panoGuide

        Rectangle {                          // keep the horizon on this line while turning
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 3
            color: page.panoTooFast ? "#ff5050" : "white"
            opacity: 0.8
        }
        Column {
            anchors { horizontalCenter: parent.horizontalCenter; verticalCenter: parent.verticalCenter
                      verticalCenterOffset: -Theme.itemSizeLarge }
            spacing: Theme.paddingMedium
            Label {
                anchors.horizontalCenter: parent.horizontalCenter
                text: page.panoTooFast ? qsTr("Slower") : qsTr("Turn slowly, keep the line level")
                color: page.panoTooFast ? "#ff5050" : "white"
                font.pixelSize: Theme.fontSizeMedium
                font.bold: true
                style: Text.Outline
                styleColor: Qt.rgba(0, 0, 0, 0.6)
            }
            Rectangle {                      // turn speed: a full bar is too fast
                anchors.horizontalCenter: parent.horizontalCenter
                visible: page.gyro !== null
                width: Theme.itemSizeHuge * 2
                height: Theme.paddingMedium
                radius: height / 2
                color: Qt.rgba(0, 0, 0, 0.4)
                Rectangle {
                    height: parent.height
                    radius: parent.radius
                    width: parent.width * Math.min(1, page.panoSpeed / page.panoSpeedLimit)
                    color: page.panoTooFast ? "#ff5050" : "#50e070"
                }
            }
        }
    }

    // White blink when a photo is taken
    Rectangle {
        id: blink
        anchors.fill: parent
        color: "white"
        opacity: 0
        NumberAnimation on opacity { id: shutterFlash; running: false; from: 0.6; to: 0; duration: 180 }
    }

    // ------------------------------------------------------------------ top bar
    // Big chips (0.4.0-34): they wrap onto a second line when they don't fit
    Flow {
        id: topBar
        anchors { top: parent.top; topMargin: Theme.paddingLarge; left: parent.left; right: parent.right
                  leftMargin: Theme.horizontalPageMargin; rightMargin: Theme.horizontalPageMargin }
        spacing: Theme.paddingMedium

        Repeater {
            model: [
                { text: page.videoMode ? qsTr("● Video") : qsTr("Photo"), action: "mode", show: !page.recording },
                { text: qsTr("Flash: %1").arg(page.flashNames[cfg.flash] || ""), action: "flash",
                  show: !page.front && !page.videoMode },
                { text: (page.modeNames[cfg.enhanceMode] || cfg.enhanceMode) + " ▾", action: "enhance",
                  show: !page.recording },
                { text: qsTr("QR"), action: "qr", show: !page.videoMode }
            ]
            delegate: Rectangle {
                visible: modelData.show
                width: chip.width + 2 * Theme.paddingLarge
                height: Theme.itemSizeSmall
                radius: height / 2
                color: (modelData.action === "qr" && page.qrMode) || (modelData.action === "mode" && page.videoMode)
                       ? Theme.highlightBackgroundColor : Qt.rgba(0, 0, 0, 0.5)
                border { width: 1; color: Qt.rgba(1, 1, 1, 0.6) }
                Label {
                    id: chip
                    anchors.centerIn: parent
                    text: modelData.text
                    color: "white"
                    font.pixelSize: Theme.fontSizeMedium
                    font.bold: true
                    rotation: -page.deviceRotation
                    Behavior on rotation { RotationAnimation { duration: 200; direction: RotationAnimation.Shortest } }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        if (modelData.action !== "enhance") page.enhancePicker = false
                        if (modelData.action === "enhance") page.enhancePicker = !page.enhancePicker
                        else if (modelData.action === "mode") page.switchMode()
                        else if (modelData.action === "flash") cfg.flash = (cfg.flash + 1) % 3
                        else if (modelData.action === "qr") page.qrMode = !page.qrMode
                    }
                }
            }
        }

        // Settings: a gear symbol
        Rectangle {
            visible: !page.recording
            width: Theme.itemSizeSmall
            height: width
            radius: width / 2
            color: Qt.rgba(0, 0, 0, 0.5)
            border { width: 1; color: Qt.rgba(1, 1, 1, 0.6) }
            Image {
                anchors.centerIn: parent
                source: "image://theme/icon-m-setting?white"
                rotation: -page.deviceRotation
                Behavior on rotation { RotationAnimation { duration: 200; direction: RotationAnimation.Shortest } }
            }
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    page.enhancePicker = false
                    pageStack.push(Qt.resolvedUrl("SettingsPage.qml"),
                                   { cfg: cfg, keysStatus: page.keysStatus, gpuStatus: page.gpuStatus,
                                     cameraInfo: page.cameraInfo() })   // while the camera still runs
                }
            }
        }
    }

    // Enhancement picker: opens from the enhance chip, one tap picks a mode
    property bool enhancePicker: false

    Column {
        anchors { top: topBar.bottom; topMargin: Theme.paddingMedium; horizontalCenter: parent.horizontalCenter }
        visible: page.enhancePicker && !page.recording
        spacing: Theme.paddingSmall
        z: 10

        Repeater {
            model: ["off", "auto", "lowlight", "vivid", "subtle"]
            delegate: Rectangle {
                readonly property bool current: cfg.enhanceMode === modelData
                width: Theme.itemSizeHuge * 2
                height: Theme.itemSizeSmall
                radius: height / 2
                color: current ? Theme.highlightBackgroundColor : Qt.rgba(0, 0, 0, 0.7)
                border { width: 1; color: Qt.rgba(1, 1, 1, 0.6) }
                Label {
                    anchors.centerIn: parent
                    text: page.modeNames[modelData]
                    color: "white"
                    font.pixelSize: Theme.fontSizeMedium
                    font.bold: parent.current
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        cfg.enhanceMode = modelData
                        page.enhancePicker = false
                    }
                }
            }
        }
    }

    // Recording: red dot and running time
    Rectangle {
        anchors { top: parent.top; topMargin: Theme.paddingLarge; horizontalCenter: parent.horizontalCenter }
        visible: page.recording
        width: recRow.width + 2 * Theme.paddingLarge
        height: Theme.itemSizeSmall
        radius: height / 2
        color: Qt.rgba(0, 0, 0, 0.5)
        Row {
            id: recRow
            anchors.centerIn: parent
            spacing: Theme.paddingMedium
            rotation: -page.deviceRotation
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.paddingLarge
                height: width
                radius: width / 2
                color: "#e53935"
                SequentialAnimation on opacity {
                    running: page.recording
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.2; duration: 500 }
                    NumberAnimation { to: 1.0; duration: 500 }
                }
            }
            Label {
                text: page.formatDuration(camera.videoRecorder.duration)
                color: "white"
                font.pixelSize: Theme.fontSizeLarge
                font.bold: true
            }
        }
    }

    // The distance the camera focused at for the photo just taken (if the camera wrote it)
    Rectangle {
        id: distancePill
        anchors { top: topBar.bottom; topMargin: Theme.paddingMedium; horizontalCenter: parent.horizontalCenter }
        visible: distanceTimer.running && page.distanceText !== ""
        width: distanceLabel.width + 2 * Theme.paddingMedium
        height: Theme.itemSizeSmall
        radius: height / 2
        color: Qt.rgba(0, 0, 0, 0.45)
        Label {
            id: distanceLabel
            anchors.centerIn: parent
            text: page.distanceText
            color: "white"
            font.pixelSize: Theme.fontSizeMedium
            rotation: -page.deviceRotation
            Behavior on rotation { RotationAnimation { duration: 200; direction: RotationAnimation.Shortest } }
        }
    }

    Label {
        anchors { top: distancePill.visible ? distancePill.bottom : topBar.bottom
                  topMargin: Theme.paddingMedium; left: parent.left; right: parent.right
                  margins: Theme.horizontalPageMargin }
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        visible: text !== ""
        color: "#ff8080"
        font.pixelSize: Theme.fontSizeExtraSmall
        text: page.message
    }

    // ------------------------------------------------------------------ bottom bar
    Item {
        id: bottomBar
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: Theme.paddingLarge * 2 }
        height: Theme.itemSizeHuge * 1.2

        // Last photo; tap to open it in the gallery
        Rectangle {
            anchors { left: parent.left; leftMargin: Theme.horizontalPageMargin * 2; verticalCenter: parent.verticalCenter }
            width: Theme.itemSizeLarge
            height: width
            radius: Theme.paddingSmall
            color: Qt.rgba(1, 1, 1, 0.15)
            border { width: 2; color: "white" }
            visible: page.snapshotTaken || page.lastShot !== ""
            clip: true
            rotation: -page.deviceRotation
            Behavior on rotation { RotationAnimation { duration: 200; direction: RotationAnimation.Shortest } }

            // 1. At the shutter press: a small snapshot of the viewfinder that stays on the GPU
            //    (no copy to the CPU, unlike grabToImage, which gave black images on the
            //    Xperia 10 III). The square from the middle of the picture, 160 px.
            ShaderEffectSource {
                id: snapshot
                anchors { fill: parent; margins: 2 }
                visible: page.snapshotTaken
                sourceItem: viewfinder
                live: false
                hideSource: false
                textureSize: Qt.size(160, 160)
                sourceRect: {
                    // the visible part of the picture: inside the screen and inside the frame
                    var c = viewfinder.contentRect
                    var ox = (viewfinder.width - viewArea.width) / 2
                    var oy = (viewfinder.height - viewArea.height) / 2
                    var x0 = Math.max(0, ox, c.x), y0 = Math.max(0, oy, c.y)
                    var x1 = Math.min(viewfinder.width - ox, c.x + c.width)
                    var y1 = Math.min(viewfinder.height - oy, c.y + c.height)
                    var w = Math.max(1, x1 - x0), h = Math.max(1, y1 - y0)
                    var side = Math.min(w, h)
                    return Qt.rect(x0 + (w - side) / 2, y0 + (h - side) / 2, side, side)
                }
                // the snapshot is in screen coordinates: undo the container's turn with the phone
                rotation: page.deviceRotation
            }

            // 2. Once saved: the photo itself, decoded small (JPEG scaled decoding). It covers the
            //    snapshot, so the corner is right even where a snapshot comes out black.
            Image {
                id: fileThumb
                anchors { fill: parent; margins: 2 }
                visible: status === Image.Ready && !page.thumbPending
                source: page.thumbSource      // set only when all photos are saved: one decode
                fillMode: Image.PreserveAspectCrop
                sourceSize { width: 200; height: 200 }
                asynchronous: true
                // The saved JPEG is stored sideways with an EXIF rotation tag (Gallery applies it)
                autoTransform: true
            }
            MouseArea {
                anchors.fill: parent
                enabled: page.lastShot !== ""
                onClicked: /\.mp4$/i.test(page.lastShot)
                    ? Qt.openUrlExternally("file://" + page.lastShot)      // videos play in the system player
                    : pageStack.push(Qt.resolvedUrl("GalleryPage.qml"),
                    { folder: cfg.saveDir, startPhoto: page.lastShot, py: page.py,
                      afterDelete: function (path, newest) {
                          if (path !== page.lastShot) return
                          page.lastShot = newest
                          page.thumbSource = newest !== "" ? "file://" + newest : ""
                          if (newest === "") page.snapshotTaken = false
                      } })
            }
        }

        // Shutter: tap = one photo, hold = burst
        Rectangle {
            id: shutter
            anchors.centerIn: parent
            width: Theme.itemSizeHuge * 1.1
            height: width
            radius: width / 2
            color: "transparent"
            border { width: 8; color: "white" }
            opacity: camera.cameraStatus === Camera.ActiveStatus ? 1.0 : 0.4

            // photo: white disc; video: red disc, a red square while recording (= stop)
            Rectangle {
                anchors.centerIn: parent
                width: page.recording ? parent.width * 0.42 : parent.width - 26
                height: width
                radius: page.recording ? Theme.paddingSmall : width / 2
                color: shutterArea.pressed ? Theme.highlightColor
                       : page.videoMode ? "#e53935"
                       : (camera.imageCapture.ready ? "white" : Qt.rgba(1, 1, 1, 0.5))
            }
            Label {
                anchors.centerIn: parent
                visible: (page.holding && page.burstCount > 0) || page.groupSlots > 0
                text: page.groupSlots > 0
                      ? (cfg.burstN - page.groupSlots) + "/" + cfg.burstN
                      : page.burstCount
                color: "black"
                font.pixelSize: page.groupSlots > 0 ? Theme.fontSizeMedium : Theme.fontSizeLarge
                font.bold: true
            }
            Label {
                anchors { bottom: parent.bottom; bottomMargin: 2; horizontalCenter: parent.horizontalCenter }
                visible: cfg.burstMode !== "single" && !page.videoMode && !page.holding && page.groupSlots === 0
                text: cfg.burstMode === "panorama" ? "PANO"
                      : (cfg.burstMode === "best" ? "B" : cfg.burstMode === "superres" ? "SR"
                         : cfg.burstMode === "hdr" ? "HD" : "S") + cfg.burstN
                color: Qt.rgba(0, 0, 0, 0.6)
                font.pixelSize: Theme.fontSizeExtraSmall
                font.bold: true
            }
            MouseArea {
                id: shutterArea
                anchors.fill: parent
                onPressed: page.shutterDown()
                onPressAndHold: page.shutterHeld()
                onReleased: page.shutterUp()
                onCanceled: {                       // finger slid away: no photo
                    page.holding = false
                    page.prefocusing = false
                }
            }
        }

        // Switch between the back and front camera
        Rectangle {
            anchors { right: parent.right; rightMargin: Theme.horizontalPageMargin * 2; verticalCenter: parent.verticalCenter }
            width: Theme.itemSizeLarge
            height: width
            radius: width / 2
            color: Qt.rgba(0, 0, 0, 0.5)
            border { width: 3; color: "white" }
            visible: (page.frontCameras.length > 0 && page.backCameras.length > 0) && !page.recording
            Label {
                anchors.centerIn: parent
                text: "⇄"
                color: "white"
                font.pixelSize: Theme.fontSizeExtraLarge
                rotation: -page.deviceRotation
                Behavior on rotation { RotationAnimation { duration: 200; direction: RotationAnimation.Shortest } }
            }
            MouseArea { anchors.fill: parent; onClicked: page.beginSwitch() }
        }
    }

    // Lens choice (main, ultra-wide, tele) when the phone has more than one camera on this side
    Row {
        id: lensRow
        anchors { bottom: bottomBar.top; bottomMargin: Theme.paddingMedium; horizontalCenter: parent.horizontalCenter }
        spacing: Theme.paddingMedium
        height: page.lenses.length > 1 ? Theme.itemSizeSmall : 0
        visible: page.lenses.length > 1

        Repeater {
            model: page.lenses.length > 1 ? page.lenses : []
            delegate: Rectangle {
                readonly property bool current: index === page.lensIndex
                width: Math.max(height, lensText.width + 2 * Theme.paddingMedium)
                height: lensRow.height
                radius: height / 2
                color: current ? Theme.highlightBackgroundColor : Qt.rgba(0, 0, 0, 0.45)
                border { width: current ? 0 : 1; color: "white" }
                Label {
                    id: lensText
                    anchors.centerIn: parent
                    text: page.lensLabel(modelData, index)
                    color: "white"
                    font.pixelSize: Theme.fontSizeMedium
                    font.bold: parent.current
                    rotation: -page.deviceRotation
                    Behavior on rotation { RotationAnimation { duration: 200; direction: RotationAnimation.Shortest } }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        cfg.lens = index
                        page.message = ""
                    }
                }
            }
        }
    }

    // Enhancement queue
    Row {
        anchors { bottom: lensRow.top; bottomMargin: Theme.paddingMedium; horizontalCenter: parent.horizontalCenter }
        spacing: Theme.paddingSmall
        visible: page.queued > 0
        BusyIndicator { size: BusyIndicatorSize.ExtraSmall; running: parent.visible; anchors.verticalCenter: parent.verticalCenter }
        Label {
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("Enhancing: %n left", "", page.queued)
            color: "white"
            font.pixelSize: Theme.fontSizeExtraSmall
        }
    }

    // ------------------------------------------------------------------ QR scanner views
    // What the scanner reads: the middle square of the viewfinder, copied on the GPU.
    // Off-screen, rendered only for grabToImage.
    Item {
        id: qrGrab
        x: -width - 100
        y: 0
        width: 720
        height: 720
        visible: page.qrMode && page.qrMethod === "viewfinder"
        ShaderEffectSource {
            anchors.fill: parent
            sourceItem: qrGrab.visible ? viewfinder : null
            live: true
            hideSource: false
            sourceRect: Qt.rect((viewfinder.width - page.qrSide) / 2, (viewfinder.height - page.qrSide) / 2,
                                page.qrSide, page.qrSide)
        }
    }

    // The square to hold the code in
    Rectangle {
        id: qrFrame
        anchors.centerIn: viewArea
        width: page.qrSide
        height: width
        visible: page.qrMode
        color: "transparent"
        radius: Theme.paddingMedium
        border { width: 3; color: page.qrText !== "" ? "#7CFC00" : "white" }
    }

    Label {
        anchors { top: qrFrame.bottom; topMargin: Theme.paddingMedium; horizontalCenter: qrFrame.horizontalCenter }
        visible: page.qrMode && page.qrText === ""
        text: page.qrMethod === "viewfinder" ? qsTr("Hold a QR code inside the square")
                                              : qsTr("Hold a QR code inside the square (reading photos)")
        color: "white"
        font.pixelSize: Theme.fontSizeSmall
        style: Text.Outline
        styleColor: Qt.rgba(0, 0, 0, 0.6)
    }

    // What the code says
    Rectangle {
        id: qrPanel
        visible: page.qrMode && page.qrText !== ""
        anchors { left: parent.left; right: parent.right; bottom: bottomBar.top
                  leftMargin: Theme.horizontalPageMargin; rightMargin: Theme.horizontalPageMargin
                  bottomMargin: Theme.paddingLarge }
        height: qrColumn.height + 2 * Theme.paddingLarge
        radius: Theme.paddingMedium
        color: Qt.rgba(0, 0, 0, 0.8)

        MouseArea { anchors.fill: parent }          // taps here do not focus the camera

        Column {
            id: qrColumn
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                      margins: Theme.paddingLarge }
            spacing: Theme.paddingMedium

            Label {
                text: qsTr("QR code")
                color: Theme.highlightColor
                font.pixelSize: Theme.fontSizeSmall
            }
            Label {
                width: parent.width
                text: page.qrText
                textFormat: Text.PlainText          // the code's text is shown, never interpreted
                color: "white"
                wrapMode: Text.WrapAnywhere
                maximumLineCount: 8
                elide: Text.ElideRight
                font.pixelSize: Theme.fontSizeSmall
            }
            // The buttons share the panel's width equally (Silica's default button width made
            // three of them wider than the panel, cut off at both sides)
            Row {
                id: qrButtons
                width: parent.width
                spacing: Theme.paddingSmall
                readonly property int count: page.qrIsLink ? 3 : 2
                readonly property real buttonWidth: (width - (count - 1) * spacing) / count
                Button {
                    width: qrButtons.buttonWidth
                    preferredWidth: qrButtons.buttonWidth
                    text: page.qrCopied ? qsTr("Copied") : qsTr("Copy")
                    onClicked: {
                        Clipboard.text = page.qrText
                        page.qrCopied = true
                    }
                }
                Button {
                    visible: page.qrIsLink
                    width: qrButtons.buttonWidth
                    preferredWidth: qrButtons.buttonWidth
                    text: qsTr("Open")
                    onClicked: Qt.openUrlExternally(page.qrText)
                }
                Button {
                    width: qrButtons.buttonWidth
                    preferredWidth: qrButtons.buttonWidth
                    text: qsTr("Scan again")
                    onClicked: page.qrText = ""
                }
            }
        }
    }
}
