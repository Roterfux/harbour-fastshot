// FastShot - SPDX-License-Identifier: GPL-3.0-or-later
// What the camera reports about itself: lenses, viewfinder and photo resolutions, focus and
// exposure. Copy it to tune FastShot for a phone.
import QtQuick 2.6
import Sailfish.Silica 1.0

Page {
    id: page

    property string info

    allowedOrientations: Orientation.Portrait

    SilicaFlickable {
        anchors.fill: parent
        contentHeight: column.height + Theme.paddingLarge

        PullDownMenu {
            MenuItem {
                text: qsTr("Copy to clipboard")
                onClicked: Clipboard.text = page.info
            }
        }

        Column {
            id: column
            width: parent.width
            spacing: Theme.paddingMedium

            PageHeader { title: qsTr("Camera info") }

            Label {
                x: Theme.horizontalPageMargin
                width: parent.width - 2 * x
                wrapMode: Text.WrapAnywhere
                font.family: "monospace"
                font.pixelSize: Theme.fontSizeExtraSmall
                color: Theme.highlightColor
                text: page.info !== "" ? page.info : qsTr("Open the settings from the camera screen to read this.")
            }
        }

        VerticalScrollDecorator {}
    }
}
