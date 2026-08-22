import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
    id: root
    moduleName: "tenzin.omauser"

    property var anchorItem: null
    property var hostWidget: null
    readonly property var barIdentity: hostWidget || root

    readonly property string runtime: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omauser"
    readonly property string bridge: runtime + "/omauser-bridge.sh"
    readonly property string mapFile: runtime + "/map.json"

    property var dots: []
    property var countries: []
    property int total: 0
    property int active30d: 0
    property int updatedAt: 0
    property int maxCount: 1
    property bool loading: false
    property bool loaded: false
    property bool offline: false
    property string errorText: ""

    readonly property bool onMap: hostWidget ? hostWidget.registered === true : false
    readonly property bool optedOut: hostWidget ? hostWidget.optedOut === true : false
    readonly property bool notJoined: !root.onMap

    function fmt(n) {
        return Number(n || 0).toLocaleString();
    }

    function formatUpdated(ms) {
        if (!ms) return "";
        var d = new Date(ms);
        var hh = d.getHours();
        var mm = d.getMinutes();
        return (hh < 10 ? "0" : "") + hh + ":" + (mm < 10 ? "0" : "") + mm;
    }

    function pct(count) {
        return root.total > 0 ? Math.round(count / root.total * 100) : 0;
    }

    function fetchMap() {
        if (mapProc.running) return;
        root.loading = true;
        root.offline = false;
        mapProc.running = true;
    }

    function readMapCache() {
        if (mapCacheProc.running) return;
        mapCacheProc.out = "";
        mapCacheProc.running = true;
    }

    function applyMap(text) {
        var json = null;
        try { json = JSON.parse(text); } catch (e) {}
        root.loading = false;
        if (!json || !json.dots) {
            root.loaded = root.dots.length > 0;
            if (!root.loaded) root.errorText = "No data yet \u2014 be the first user on the map!";
            return;
        }
        root.dots = json.dots;
        root.countries = json.countries || [];
        root.total = json.total || 0;
        root.active30d = json.active30d || 0;
        root.updatedAt = json.updatedAt || 0;
        root.maxCount = 1;
        for (var i = 0; i < root.dots.length; i++) {
            if (root.dots[i].count > root.maxCount) root.maxCount = root.dots[i].count;
        }
        root.loaded = true;
        root.errorText = "";
    }

    function joinMap() {
        if (hostWidget && hostWidget.joinMap) hostWidget.joinMap();
        Qt.callLater(root.fetchMap);
    }

    function optOut() {
        if (hostWidget && hostWidget.optOut) hostWidget.optOut();
        Qt.callLater(root.fetchMap);
    }

    Process {
        id: mapProc
        command: ["bash", root.bridge, "map"]
        onExited: function(exitCode) {
            if (exitCode === 0) {
                root.offline = false;
                root.readMapCache();
            } else {
                root.offline = true;
                root.loading = false;
                if (root.loaded) root.errorText = "offline \u2014 showing last cached map";
                else root.errorText = "could not reach the Omauser API";
            }
        }
    }

    Process {
        id: mapCacheProc
        command: ["cat", root.mapFile]
        property string out: ""
        stdout: SplitParser {
            onRead: function(data) { mapCacheProc.out += data }
        }
        onExited: function(exitCode) {
            if (exitCode === 0) {
                root.applyMap(mapCacheProc.out);
                root.offline = false;
            } else {
                root.loading = false;
                if (!root.loaded) root.errorText = "could not reach the Omauser API";
            }
            mapCacheProc.out = "";
        }
    }

    Timer {
        id: refreshTimer
        interval: 300000
        repeat: true
        running: root.opened
        onTriggered: root.fetchMap()
    }

    // ---------------- open/close wiring ----------------
    function openFromHotkey() {
        root.controller.show();
        if (!root.loaded && !root.loading) root.fetchMap();
    }
    function close() { root.controller.hide() }
    function toggle() { if (root.opened) root.close(); else root.openFromHotkey() }
    function closeForPopoutSwitch() { root.close() }

    onOpenedChanged: {
        if (root.opened && !root.loaded && !root.loading) root.fetchMap();
    }

    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.barIdentity
        bar: root.bar
        open: root.opened
        centerOnBar: true
        margin: Style.gapsOut
        gap: Style.gapsOut
        contentWidth: panel.fittedContentWidth(panel.screenW * 0.66)
        contentHeight: panel.fittedContentHeight(Math.min(panel.screenH * 0.72, 620))

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 14
            spacing: Style.spacing.sm

            // ---------------- header ----------------
            RowLayout {
                Layout.fillWidth: true
                spacing: Style.spacing.md

                Text {
                    text: "\uf0ac"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.title
                    color: Color.accent
                }
                Text {
                    text: "Omauser"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.title
                    font.bold: true
                    color: Color.foreground
                }
                Text {
                    text: "OMARCHY USER MAP"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: Qt.darker(Color.foreground, 1.3)
                    font.capitalization: Font.AllUppercase
                    Layout.topMargin: 2
                }
                Item { Layout.fillWidth: true }
                Text {
                    visible: root.offline
                    text: "offline"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: Color.urgent
                }
                Text {
                    text: "updated " + root.formatUpdated(root.updatedAt)
                    visible: root.updatedAt > 0
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: Qt.darker(Color.foreground, 1.3)
                }
                Button {
                    text: "\uf021"
                    fontSize: Style.font.caption
                    foreground: Color.foreground
                    tooltipText: "Refresh"
                    onClicked: root.fetchMap()
                }
            }

            // ---------------- totals ----------------
            RowLayout {
                Layout.fillWidth: true
                spacing: Style.spacing.lg

                Text {
                    text: root.fmt(root.total)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.heading
                    font.bold: true
                    color: Color.accent
                }
                Text {
                    text: "total users"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: Qt.darker(Color.foreground, 1.3)
                    Layout.alignment: Qt.AlignVCenter
                }
                Text {
                    text: "\u00b7"
                    color: Qt.darker(Color.foreground, 1.3)
                    font.pixelSize: Style.font.body
                }
                Text {
                    text: root.fmt(root.active30d)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.heading
                    font.bold: true
                    color: Color.foreground
                }
                Text {
                    text: "active (30d)"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: Qt.darker(Color.foreground, 1.3)
                    Layout.alignment: Qt.AlignVCenter
                }
                Item { Layout.fillWidth: true }
            }

            PanelSeparator { Layout.fillWidth: true; opacity: 0.5 }

            // ---------------- map + side list ----------------
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Style.spacing.md

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true

                    Image {
                        id: mapImage
                        anchors.fill: parent
                        fillMode: Image.PreserveAspectFit
                        source: Qt.resolvedUrl("assets/world.svg")
                        smooth: true
                    }

                    // Dots: equirectangular projection on a 2:1 map. The map
                    // is fit inside its area, so the dot layer tracks the
                    // drawn image rect (centered, at most 2:1).
                    Item {
                        id: dotLayer
                        anchors.centerIn: parent
                        width: Math.min(mapImage.paintedWidth > 0 ? mapImage.paintedWidth : parent.width,
                                        parent.width)
                        height: width / 2

                        Repeater {
                            model: root.dots
                            delegate: Item {
                                required property var modelData
                                readonly property real px: (modelData.lon + 180) / 360 * dotLayer.width
                                readonly property real py: (90 - modelData.lat) / 180 * dotLayer.height
                                readonly property real dotR: Math.max(3, Math.min(13,
                                    2 + 9 * Math.sqrt(modelData.count / Math.max(1, root.maxCount))))

                                x: px - dotR
                                y: py - dotR
                                width: dotR * 2
                                height: dotR * 2

                                Rectangle {
                                    anchors.fill: parent
                                    radius: width / 2
                                    color: root.onMap ? Color.accent : Color.urgent
                                    opacity: 0.9
                                    border.width: 1
                                    border.color: Color.popups.background
                                }
                                Rectangle {
                                    visible: dotMouse.containsMouse
                                    anchors.centerIn: parent
                                    width: parent.width + 6
                                    height: parent.height + 6
                                    radius: width / 2
                                    color: "transparent"
                                    border.width: 1.5
                                    border.color: Color.accent
                                }

                                MouseArea {
                                    id: dotMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                }

                                ToolTip {
                                    visible: dotMouse.containsMouse
                                    delay: 200
                                    text: modelData.name + " \u2014 " + root.fmt(modelData.count)
                                        + " user" + (modelData.count === 1 ? "" : "s")
                                        + " (" + root.pct(modelData.count) + "%)"
                                    background: Rectangle {
                                        color: Color.popups.background
                                        radius: Style.cornerRadius
                                        border.width: 1
                                        border.color: Color.popups.border
                                    }
                                    contentItem: Text {
                                        text: ToolTip.text
                                        color: Color.foreground
                                        font.family: Style.font.family
                                        font.pixelSize: Style.font.caption
                                    }
                                }
                            }
                        }

                        // status overlays
                        Text {
                            anchors.centerIn: parent
                            visible: root.loading
                            text: "Loading the map \u2026"
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            color: Color.foreground
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: !root.loading && !root.loaded
                            text: root.errorText
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            color: Qt.darker(Color.foreground, 1.25)
                            horizontalAlignment: Text.AlignHCenter
                            width: parent.width * 0.7
                            wrapMode: Text.WordWrap
                        }
                    }
                }

                // ---------------- top countries ----------------
                ColumnLayout {
                    Layout.preferredWidth: Style.space(190)
                    Layout.fillHeight: true
                    spacing: Style.spacing.xs
                    visible: root.countries.length > 0

                    Text {
                        text: "TOP COUNTRIES"
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        color: Qt.darker(Color.foreground, 1.3)
                        font.capitalization: Font.AllUppercase
                    }

                    Item { Layout.fillHeight: true }

                    Repeater {
                        model: {
                            var top = [];
                            var n = Math.min(10, root.countries.length);
                            for (var i = 0; i < n; i++) top.push(root.countries[i]);
                            return top;
                        }
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: Style.spacing.sm

                            Rectangle {
                                Layout.preferredWidth: 8
                                Layout.preferredHeight: 8
                                radius: 4
                                color: root.onMap ? Color.accent : Color.urgent
                                opacity: 0.85
                                Layout.alignment: Qt.AlignVCenter
                            }
                            Text {
                                Layout.fillWidth: true
                                text: modelData.code
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                font.bold: true
                                color: Color.foreground
                                elide: Text.ElideRight
                            }
                            Text {
                                text: root.fmt(modelData.count)
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                color: Qt.darker(Color.foreground, 1.25)
                            }
                        }
                    }
                }

                // ---------------- right rail: join / privacy ----------------
                ColumnLayout {
                    Layout.preferredWidth: Style.space(190)
                    Layout.fillHeight: true
                    spacing: Style.spacing.sm

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Style.space(96)
                        color: Color.popups.background
                        radius: Style.cornerRadius
                        border.width: 1
                        border.color: Color.popups.border

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: Style.spacing.sm
                            spacing: Style.spacing.xs

                            Text {
                                Layout.fillWidth: true
                                text: root.onMap
                                    ? "\uf058  You are on the map"
                                    : (root.optedOut
                                        ? "\uf070  You left the map"
                                        : "\uf0ac  Joining the map \u2026")
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                font.bold: true
                                color: root.onMap ? Color.accent : (root.optedOut ? Color.urgent : Qt.darker(Color.foreground, 1.2))
                            }
                            Text {
                                Layout.fillWidth: true
                                text: "Opt-in by default. Only your country is shown (derived from your IP "
                                    + "server-side) \u2014 no IP, no precise location, no name. Leave anytime."
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                color: Qt.darker(Color.foreground, 1.3)
                                wrapMode: Text.WordWrap
                            }
                            Item { Layout.fillHeight: true }
                            Button {
                                Layout.fillWidth: true
                                visible: root.onMap
                                text: "Remove my device"
                                fontSize: Style.font.caption
                                foreground: Color.foreground
                                onClicked: root.optOut()
                            }
                            Button {
                                Layout.fillWidth: true
                                visible: !root.onMap
                                text: "Join the map"
                                fontSize: Style.font.caption
                                foreground: Color.foreground
                                accent: Color.accent
                                bordered: true
                                onClicked: root.joinMap()
                            }
                        }
                    }
                }
            }

            PanelSeparator { Layout.fillWidth: true; opacity: 0.5 }

            // ---------------- footer ----------------
            RowLayout {
                Layout.fillWidth: true
                spacing: Style.spacing.sm

                Text {
                    Layout.fillWidth: true
                    text: "device hash (sha256 of machine-id) \u00b7 country from IP \u00b7 "
                        + "records expire after 12 months \u00b7 rates limited"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: Qt.darker(Color.foreground, 1.35)
                    elide: Text.ElideRight
                }
                Text {
                    text: root.dots.length + " countries"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: Qt.darker(Color.foreground, 1.35)
                }
            }
        }
    }
}
