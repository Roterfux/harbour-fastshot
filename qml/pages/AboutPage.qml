// FastShot - SPDX-License-Identifier: GPL-3.0-or-later
import QtQuick 2.6
import Sailfish.Silica 1.0

Page {
    id: page

    // The RPM build replaces this with the exact package version, e.g. "0.1.0-4"
    readonly property string appVersion: "0.1.0-dev"

    allowedOrientations: Orientation.Portrait

    SilicaFlickable {
        anchors.fill: parent
        contentHeight: column.height + Theme.paddingLarge

        Column {
            id: column
            width: parent.width
            spacing: Theme.paddingLarge

            PageHeader { title: qsTr("About") }

            Image {
                anchors.horizontalCenter: parent.horizontalCenter
                source: "/usr/share/icons/hicolor/172x172/apps/harbour-fastshot.png"
                width: Theme.iconSizeExtraLarge; height: width
            }
            Label {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "FastShot " + page.appVersion
                font.pixelSize: Theme.fontSizeLarge
                color: Theme.highlightColor
            }
            Label {
                x: Theme.horizontalPageMargin
                width: parent.width - 2 * x
                wrapMode: Text.Wrap
                color: Theme.secondaryHighlightColor
                text: qsTr("A fast camera for Sailfish OS: it takes the photo the moment you press, shoots bursts "
                           + "and can enhance every photo automatically in the background.")
            }
            Label {
                x: Theme.horizontalPageMargin
                width: parent.width - 2 * x
                wrapMode: Text.Wrap
                textFormat: Text.StyledText
                linkColor: Theme.highlightColor
                onLinkActivated: Qt.openUrlExternally(link)
                font.pixelSize: Theme.fontSizeSmall
                text: qsTr("The image enhancement is the engine of Photo Enhance. Built with "
                           + "<a href=\"https://python-pillow.org\">Pillow</a>, "
                           + "<a href=\"https://thp.io/2011/pyotherside/\">PyOtherSide</a>, Qt Multimedia and Sailfish Silica. "
                           + "Thank you!")
            }
            Label {
                x: Theme.horizontalPageMargin
                width: parent.width - 2 * x
                wrapMode: Text.Wrap
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.secondaryColor
                text: qsTr("Licensed under the GNU General Public License v3 or later. "
                           + "FastShot is an independent project, not affiliated with Jolla.")
            }
        }

        VerticalScrollDecorator {}
    }
}
