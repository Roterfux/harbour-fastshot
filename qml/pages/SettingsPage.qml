// FastShot - SPDX-License-Identifier: GPL-3.0-or-later
import QtQuick 2.6
import Sailfish.Silica 1.0

Page {
    id: page

    property var cfg    // ConfigurationGroup from CameraPage
    property string keysStatus: ""
    property string cameraInfo: ""
    property string gpuStatus: ""
    readonly property var modes: ["off", "auto", "lowlight", "vivid", "subtle"]
    readonly property var burstModes: ["single", "best", "stack", "superres", "hdr", "panorama"]
    readonly property var burstLabels: [qsTr("Single"), qsTr("Best of"), qsTr("Stack"),
                                        qsTr("Super-res"), qsTr("HDR"), qsTr("Panorama")]

    allowedOrientations: Orientation.Portrait

    SilicaFlickable {
        anchors.fill: parent
        contentHeight: column.height + Theme.paddingLarge

        PullDownMenu {
            MenuItem {
                text: qsTr("About")
                onClicked: pageStack.push(Qt.resolvedUrl("AboutPage.qml"))
            }
            MenuItem {
                text: qsTr("Camera info")
                onClicked: pageStack.push(Qt.resolvedUrl("CameraInfoPage.qml"), { info: page.cameraInfo })
            }
        }

        Column {
            id: column
            width: parent.width

            PageHeader { title: qsTr("Settings") }

            SectionHeader { text: qsTr("Image processing") }

            ComboBox {
                label: qsTr("Enhance photos")
                currentIndex: Math.max(0, page.modes.indexOf(page.cfg.enhanceMode))
                description: page.cfg.enhanceMode === "auto"
                             ? qsTr("Every photo is measured and gets the effects it needs")
                             : ""
                menu: ContextMenu {
                    MenuItem { text: qsTr("Off"); onClicked: page.cfg.enhanceMode = "off" }
                    MenuItem { text: qsTr("Smart auto"); onClicked: page.cfg.enhanceMode = "auto" }
                    MenuItem { text: qsTr("Low light"); onClicked: page.cfg.enhanceMode = "lowlight" }
                    MenuItem { text: qsTr("Vivid"); onClicked: page.cfg.enhanceMode = "vivid" }
                    MenuItem { text: qsTr("Subtle"); onClicked: page.cfg.enhanceMode = "subtle" }
                }
            }

            TextSwitch {
                text: qsTr("Keep the original")
                enabled: page.cfg.enhanceMode !== "off"
                checked: page.cfg.keepOriginal
                description: checked ? qsTr("The enhanced copy is saved next to it as …_enhanced.jpg")
                                     : qsTr("The original is replaced by the enhanced photo")
                onCheckedChanged: page.cfg.keepOriginal = checked
            }

            TextSwitch {
                text: qsTr("Enhance on the graphics chip")
                enabled: page.cfg.enhanceMode !== "off"
                checked: page.cfg.gpuEnhance
                description: {
                    var d = qsTr("Much faster (seconds instead of 10-30 s per photo) while FastShot is in front. "
                                 + "In the background, or if the graphics chip cannot do it, the processor does it.")
                    if (page.gpuStatus !== "") d += " " + qsTr("On this phone: %1.").arg(page.gpuStatus)
                    return d
                }
                onCheckedChanged: page.cfg.gpuEnhance = checked
            }

            TextSwitch {
                text: qsTr("Show the enhanced look in the viewfinder")
                enabled: page.cfg.enhanceMode !== "off"
                checked: page.cfg.livePreview
                description: qsTr("A preview with the values of the last photo (smart auto) or of the preset. "
                                  + "Uses more battery.")
                onCheckedChanged: page.cfg.livePreview = checked
            }

            TextSwitch {
                text: qsTr("Enhance only while charging")
                enabled: page.cfg.enhanceMode !== "off"
                checked: page.cfg.enhanceWhenCharging
                description: qsTr("Photos wait until the phone is on the charger (with FastShot open).")
                onCheckedChanged: page.cfg.enhanceWhenCharging = checked
            }

            Label {
                x: Theme.horizontalPageMargin
                width: parent.width - 2 * x
                wrapMode: Text.Wrap
                color: Theme.secondaryHighlightColor
                font.pixelSize: Theme.fontSizeExtraSmall
                text: qsTr("Enhancing runs after each shot in the background, at low priority, so the camera "
                           + "stays fast. Photos still waiting when the app is closed are enhanced after the "
                           + "next start.")
            }

            SectionHeader { text: qsTr("Camera") }

            ComboBox {
                label: qsTr("Photo format")
                currentIndex: page.cfg.aspect === "16:9" ? 1 : 0
                description: qsTr("Also switchable with the format button on the camera screen")
                menu: ContextMenu {
                    MenuItem { text: qsTr("4:3 (whole sensor, 12 MP)"); onClicked: page.cfg.aspect = "4:3" }
                    MenuItem { text: qsTr("16:9 (wide, cropped)"); onClicked: page.cfg.aspect = "16:9" }
                }
            }

            TextSwitch {
                text: qsTr("Full-screen viewfinder")
                checked: page.cfg.fullScreen
                description: checked
                    ? qsTr("The camera picture fills the whole screen. The photo shows a little more at the "
                           + "sides than you see (less with 16:9).")
                    : qsTr("The whole photo is shown, with black bars above and below.")
                onCheckedChanged: page.cfg.fullScreen = checked
            }

            TextSwitch {
                text: qsTr("Focus before each shot")
                checked: page.cfg.focusBeforeShot
                description: qsTr("Sharper close-ups and photos in poor light, but a single shot waits for "
                                  + "focus. Off: the photo is taken at once with continuous focus. "
                                  + "Bursts never wait.")
                onCheckedChanged: page.cfg.focusBeforeShot = checked
            }

            TextSwitch {
                text: qsTr("Focus while touching the shutter")
                enabled: page.cfg.focusBeforeShot
                checked: page.cfg.focusOnTouch
                description: qsTr("Like half-pressing a camera button: focusing starts when you touch the "
                                  + "shutter, the photo is taken when you let go, usually already sharp. "
                                  + "The volume keys still shoot at the press.")
                onCheckedChanged: page.cfg.focusOnTouch = checked
            }

            ComboBox {
                label: qsTr("Longest focus wait")
                enabled: page.cfg.focusBeforeShot
                currentIndex: page.cfg.focusWait <= 400 ? 0 : page.cfg.focusWait <= 800 ? 1 : 2
                description: qsTr("After this the photo is taken even if the camera is not sure it is sharp. "
                                  + "Camera info shows how long focusing really takes.")
                menu: ContextMenu {
                    MenuItem { text: qsTr("0.4 s"); onClicked: page.cfg.focusWait = 400 }
                    MenuItem { text: qsTr("0.8 s"); onClicked: page.cfg.focusWait = 800 }
                    MenuItem { text: qsTr("1.2 s"); onClicked: page.cfg.focusWait = 1200 }
                }
            }

            SectionHeader { text: qsTr("Low light") }

            ComboBox {
                label: qsTr("Brightness")
                currentIndex: page.cfg.evCompensation < -0.3 ? 0 : page.cfg.evCompensation > 1 ? 3
                              : page.cfg.evCompensation > 0.3 ? 2 : 1
                description: qsTr("Exposure correction. Brighter keeps more detail in dark scenes but "
                                  + "lets bright areas burn out sooner.")
                menu: ContextMenu {
                    MenuItem { text: qsTr("Darker (-0.7 EV)"); onClicked: page.cfg.evCompensation = -0.7 }
                    MenuItem { text: qsTr("Normal"); onClicked: page.cfg.evCompensation = 0 }
                    MenuItem { text: qsTr("Brighter (+0.7 EV)"); onClicked: page.cfg.evCompensation = 0.7 }
                    MenuItem { text: qsTr("Much brighter (+1.3 EV)"); onClicked: page.cfg.evCompensation = 1.3 }
                }
            }

            SectionHeader { text: qsTr("More") }

            TextSwitch {
                text: qsTr("Volume keys take photos")
                checked: page.cfg.volumeKeys
                description: {
                    var d = qsTr("Vol+ and Vol- (and a camera key, if the phone has one) work as the shutter; "
                                 + "hold for a burst.")
                    if (page.keysStatus !== "" && page.keysStatus !== "ok")
                        d += " " + qsTr("On this phone: %1.").arg(page.keysStatus)
                    return d
                }
                onCheckedChanged: page.cfg.volumeKeys = checked
            }

            ComboBox {
                id: burstModeBox
                label: qsTr("Multi-shot")
                currentIndex: Math.max(0, burstModes.indexOf(page.cfg.burstMode))
                description: currentIndex === 0 ? ""
                    : currentIndex === 1 ? qsTr("Takes %1 photos per press and keeps the sharpest.").arg(page.cfg.burstN)
                    : currentIndex === 2 ? qsTr("Takes %1 photos and averages them for less noise.").arg(page.cfg.burstN)
                    : currentIndex === 3 ? qsTr("Takes %1 photos, upscales to 2x and averages for more detail.").arg(page.cfg.burstN)
                    : currentIndex === 4 ? qsTr("Takes %1 photos and merges them with tone mapping for high dynamic range.").arg(page.cfg.burstN)
                    : qsTr("Hold the shutter and turn slowly to the left or right. The photos are joined when you let go.")
                menu: ContextMenu {
                    Repeater {
                        model: burstLabels
                        MenuItem { text: modelData }
                    }
                }
                onCurrentIndexChanged: page.cfg.burstMode = burstModes[currentIndex]
            }
            Slider {
                visible: burstModeBox.currentIndex > 0 && burstModeBox.currentIndex < 5
                width: parent.width
                minimumValue: 2
                maximumValue: 5
                stepSize: 1
                value: page.cfg.burstN
                label: qsTr("Frames")
                valueText: value
                onValueChanged: page.cfg.burstN = value
            }

            TextSwitch {
                text: qsTr("Steady shot")
                checked: page.cfg.steadyShot
                description: qsTr("After the press the photo is taken the moment the phone stops shaking "
                                  + "(at most 0.7 s later). Sharper, especially in poor light.")
                onCheckedChanged: page.cfg.steadyShot = checked
            }

            TextSwitch {
                text: qsTr("Focus when raised")
                checked: page.cfg.raiseFocus
                description: qsTr("Lifting the phone from lying flat into a shooting position focuses at once.")
                onCheckedChanged: page.cfg.raiseFocus = checked
            }

            ComboBox {
                label: qsTr("Stay ready after leaving")
                currentIndex: page.cfg.keepLoadedSec >= 300 ? 2 : page.cfg.keepLoadedSec >= 120 ? 1 : 0
                description: qsTr("Coming back within this time is almost instant. Meanwhile other apps "
                                  + "cannot use the camera.")
                menu: ContextMenu {
                    MenuItem { text: qsTr("30 seconds"); onClicked: page.cfg.keepLoadedSec = 30 }
                    MenuItem { text: qsTr("2 minutes"); onClicked: page.cfg.keepLoadedSec = 120 }
                    MenuItem { text: qsTr("5 minutes"); onClicked: page.cfg.keepLoadedSec = 300 }
                }
            }

            TextSwitch {
                text: qsTr("Release camera when switching")
                checked: page.cfg.switchUnload
                description: qsTr("Test option: the camera is closed before the other one is opened. "
                                  + "Compare the times in Camera info with this off and on.")
                onCheckedChanged: page.cfg.switchUnload = checked
            }

            TextSwitch {
                text: qsTr("Bursts in a hidden folder first")
                checked: page.cfg.burstHidden
                description: qsTr("Burst photos are moved to Pictures/Camera when the burst ends, so the "
                                  + "phone's media indexer does not slow the burst down.")
                onCheckedChanged: page.cfg.burstHidden = checked
            }

            Label {
                x: Theme.horizontalPageMargin
                width: parent.width - 2 * x
                wrapMode: Text.Wrap
                color: Theme.secondaryHighlightColor
                font.pixelSize: Theme.fontSizeExtraSmall
                text: qsTr("Photos are saved to Pictures/Camera. Tap the viewfinder to focus on a point, "
                           + "hold the shutter for a burst.")
            }
        }

        VerticalScrollDecorator {}
    }
}
