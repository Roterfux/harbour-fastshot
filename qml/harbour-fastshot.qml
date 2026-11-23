// FastShot - SPDX-License-Identifier: GPL-3.0-or-later
import QtQuick 2.6
import Sailfish.Silica 1.0
import "pages"

ApplicationWindow {
    id: app

    property int queued: 0   // photos waiting for enhancement (shown on the cover)
    readonly property real startTime: Date.now()   // for the start-up timing in Camera info
    // When the process started (from /proc), to see the part of the start before QML runs.
    // With the launcher's booster the process may have been waiting long before the tap.
    readonly property real processStart: readProcessStart()

    function readFile(path) {
        var x = new XMLHttpRequest()
        x.open("GET", "file://" + path, false)        // local, synchronous, tiny
        x.send(null)
        return x.responseText
    }

    function readProcessStart() {
        try {
            var stat = readFile("/proc/self/stat")
            var uptime = parseFloat(readFile("/proc/uptime"))
            var fields = stat.substring(stat.lastIndexOf(")") + 2).split(" ")
            var startTicks = parseInt(fields[19], 10)     // field 22, "starttime", in 1/100 s
            if (isNaN(uptime) || isNaN(startTicks)) return 0
            return Date.now() - (uptime - startTicks / 100) * 1000
        } catch (e) {
            return 0
        }
    }

    allowedOrientations: Orientation.Portrait
    initialPage: Component { CameraPage { win: app } }

    cover: Component {
        CoverBackground {
            Label {
                anchors { left: parent.left; right: parent.right; margins: Theme.paddingLarge
                          verticalCenter: parent.verticalCenter }
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                color: Theme.highlightColor
                text: app.queued > 0 ? qsTr("FastShot\nEnhancing %n photo(s)", "", app.queued)
                                     : qsTr("FastShot")
            }
        }
    }
}
