import QtQuick 2.6
import Sailfish.Silica 1.0
import Qt.labs.folderlistmodel 2.1

Page {
    id: galleryPage
    allowedOrientations: Orientation.All
    backNavigation: !zoomed

    property string folder: ""
    property string startPhoto: ""        // full path of the photo to show first
    property bool zoomed: false
    property bool _scrolled: false
    property var py: null                 // the camera page's Python element (deletes files)
    property var afterDelete: null        // function (path, newest photo left) for the camera page

    readonly property string currentPath:
        photoView.currentIndex >= 0 && photoView.currentIndex < photoModel.count
        ? String(photoModel.get(photoView.currentIndex, "filePath")) : ""

    // Delete the shown photo after the usual few seconds to undo
    function deleteCurrent() {
        var path = currentPath
        if (path === "" || !py) return
        remorse.execute(qsTr("Deleting"), function () {
            py.call("camworker.delete_photo", [path], function (result) {
                if (galleryPage.afterDelete) galleryPage.afterDelete(path, result[1])
                if (result[1] === "") pageStack.pop()     // nothing left to show
            })
        })
    }

    RemorsePopup { id: remorse }

    FolderListModel {
        id: photoModel
        folder: galleryPage.folder !== "" ? "file://" + galleryPage.folder : ""
        nameFilters: ["*.jpg", "*.jpeg", "*.JPG", "*.JPEG"]
        sortField: FolderListModel.Time
        sortReversed: true                // newest first
        showDirs: false

        onCountChanged: {
            if (galleryPage._scrolled || galleryPage.startPhoto === "" || count === 0) return
            scrollToStart()
        }
    }

    function scrollToStart() {
        for (var i = 0; i < photoModel.count; ++i) {
            if (String(photoModel.get(i, "filePath")) === galleryPage.startPhoto) {
                photoView.positionViewAtIndex(i, ListView.Center)
                photoView.currentIndex = i
                galleryPage._scrolled = true
                return
            }
        }
    }

    // ------------------------------------------------------------------ photo list
    SilicaListView {
        id: photoView
        anchors.fill: parent
        orientation: ListView.Horizontal
        snapMode: ListView.SnapOneItem
        highlightRangeMode: ListView.StrictlyEnforceRange
        cacheBuffer: galleryPage.width
        interactive: !galleryPage.zoomed
        model: photoModel
        currentIndex: 0

        delegate: Item {
            id: cell
            width: photoView.width
            height: photoView.height

            SilicaFlickable {
                id: flick
                anchors.fill: parent
                // Zooming resizes the content (resizeContent keeps these bindings, so turning
                // the phone puts the photo back to full view).
                contentWidth: width
                contentHeight: height
                clip: true

                readonly property real maxZoom: 4.0
                readonly property real zoom: width > 0 ? contentWidth / width : 1.0

                // Zoom to z so that the photo point (fx, fy: 0..1 of the content) lies under
                // the screen point (vx, vy) of this flickable.
                function zoomAbout(z, fx, fy, vx, vy) {
                    z = Math.max(1.0, Math.min(maxZoom, z))
                    var w = width * z
                    var h = height * z
                    resizeContent(w, h, Qt.point(0, 0))
                    contentX = Math.max(0, Math.min(w - width, fx * w - vx))
                    contentY = Math.max(0, Math.min(h - height, fy * h - vy))
                }
                function settle() {
                    if (zoom < 1.05) zoomAbout(1.0, 0, 0, 0, 0)
                    galleryPage.zoomed = zoom >= 1.05
                }
                function fullView() {
                    contentX = 0
                    contentY = 0
                    if (cell.ListView.isCurrentItem) galleryPage.zoomed = false
                }
                onWidthChanged: fullView()
                onHeightChanged: fullView()

                PullDownMenu {
                    visible: !galleryPage.zoomed
                    MenuItem {
                        text: qsTr("Open in Gallery")
                        onClicked: Qt.openUrlExternally(fileURL)
                    }
                }

                Image {
                    id: photo
                    source: fileURL
                    fillMode: Image.PreserveAspectFit
                    width: flick.contentWidth
                    height: flick.contentHeight
                    sourceSize { width: Screen.width * 2; height: Screen.height * 2 }
                    autoTransform: true
                    asynchronous: true

                    BusyIndicator {
                        anchors.centerIn: parent
                        running: photo.status === Image.Loading
                        size: BusyIndicatorSize.Large
                    }
                }

                PinchArea {
                    id: pincher
                    width: flick.contentWidth
                    height: flick.contentHeight

                    property real startZoom: 1.0
                    property real fx: 0.5       // photo point between the fingers at the start
                    property real fy: 0.5

                    onPinchStarted: {
                        startZoom = flick.zoom
                        fx = pinch.center.x / width
                        fy = pinch.center.y / height
                    }
                    // Keep that photo point between the fingers, also while they move
                    onPinchUpdated: {
                        var v = pincher.mapToItem(flick, pinch.center.x, pinch.center.y)
                        flick.zoomAbout(startZoom * pinch.scale, fx, fy, v.x, v.y)
                    }
                    onPinchFinished: flick.settle()

                    MouseArea {
                        anchors.fill: parent
                        onDoubleClicked: {
                            if (flick.zoom > 1.05) {
                                flick.zoomAbout(1.0, 0, 0, 0, 0)
                            } else {
                                // zoom in on the tapped spot
                                var v = pincher.mapToItem(flick, mouse.x, mouse.y)
                                flick.zoomAbout(2.5, mouse.x / pincher.width,
                                                mouse.y / pincher.height, v.x, v.y)
                            }
                            flick.settle()
                        }
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------------ overlay
    // Photo counter and filename, faded so the photo is the focus
    Rectangle {
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: counterLabel.height + Theme.paddingLarge * 2
        gradient: Gradient {
            GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0.5) }
            GradientStop { position: 1; color: "transparent" }
        }

        Label {
            id: counterLabel
            anchors { top: parent.top; topMargin: Theme.paddingLarge; horizontalCenter: parent.horizontalCenter }
            text: photoModel.count > 0
                  ? (photoView.currentIndex + 1) + " / " + photoModel.count
                  : ""
            color: Theme.lightPrimaryColor
            font.pixelSize: Theme.fontSizeSmall
        }
    }

    Rectangle {
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        height: deleteButton.height + Theme.paddingLarge * 2
        gradient: Gradient {
            GradientStop { position: 0; color: "transparent" }
            GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.5) }
        }

        Label {
            id: nameLabel
            anchors { verticalCenter: deleteButton.verticalCenter; horizontalCenter: parent.horizontalCenter }
            text: photoView.currentIndex >= 0 && photoView.currentIndex < photoModel.count
                  ? photoModel.get(photoView.currentIndex, "fileName")
                  : ""
            color: Theme.lightPrimaryColor
            font.pixelSize: Theme.fontSizeSmall
        }

        IconButton {
            id: deleteButton
            anchors { right: parent.right; rightMargin: Theme.horizontalPageMargin
                      bottom: parent.bottom; bottomMargin: Theme.paddingLarge }
            icon.source: "image://theme/icon-m-delete?" + Theme.lightPrimaryColor
            visible: galleryPage.py !== null && galleryPage.currentPath !== ""
            onClicked: galleryPage.deleteCurrent()
        }
    }
}
