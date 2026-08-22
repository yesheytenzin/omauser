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

    readonly property color dim: Qt.darker(Color.foreground, 1.3)

    function fmt(n) {
        return Number(n || 0).toLocaleString();
    }

    function formatUpdated(ms) {
        if (!ms) return "never";
        var d = new Date(ms);
        var hh = d.getHours();
        var mm = d.getMinutes();
        return (hh < 10 ? "0" : "") + hh + ":" + (mm < 10 ? "0" : "") + mm;
    }

    function pct(count) {
        return root.total > 0 ? Math.round(count / root.total * 100) : 0;
    }

    function flagEmoji(code) {
        if (!code || code.length !== 2) return "";
        var a = code.charCodeAt(0), b = code.charCodeAt(1);
        if (a < 65 || a > 90 || b < 65 || b > 90) return "";
        return String.fromCodePoint(0x1F1E6 + a - 65) + String.fromCodePoint(0x1F1E6 + b - 65);
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

    // ---------------- shared pieces ----------------

    component StatCard: Rectangle {
        id: card
        property string label: ""
        property string value: ""
        property bool highlight: false
        readonly property color dim: Qt.darker(Color.foreground, 1.3)

        Layout.fillWidth: true
        Layout.preferredHeight: Style.space(62)
        color: Color.popups.background
        radius: Style.cornerRadius
        border.width: 1
        border.color: card.highlight ? Color.accent : Color.popups.border

        ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.spacing.md
            anchors.rightMargin: Style.spacing.md
            spacing: 0

            Text {
                Layout.fillWidth: true
                text: card.value
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
                font.bold: true
                color: card.highlight ? Color.accent : Color.foreground
            }
            Text {
                Layout.fillWidth: true
                text: card.label
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: dim
                font.capitalization: Font.AllUppercase
                font.bold: true
                elide: Text.ElideRight
            }
        }
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
        contentWidth: panel.fittedContentWidth(panel.screenW * 0.70)
        contentHeight: panel.fittedContentHeight(Math.min(panel.screenH * 0.76, 640))

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 14
            spacing: Style.spacing.md

            // ---------------- header ----------------
            PanelHero {
                Layout.fillWidth: true
                iconComponent: Component {
                    Text {
                        text: "\uf0ac"
                        font.family: Style.font.family
                        font.pixelSize: Style.font.display
                        color: Color.accent
                    }
                }
                title: "Omauser"
                meta: "Omarchy user map"
                detail: root.onMap ? "on the map" : (root.optedOut ? "opted out" : "offline")

                trailingControl: Component {
                    RowLayout {
                        spacing: Style.spacing.sm
                        Text {
                            visible: root.offline
                            text: "\uf071 offline"
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            color: Color.urgent
                        }
                        Button {
                            text: "\uf021"
                            fontSize: Style.font.caption
                            foreground: Color.foreground
                            tooltipText: "Refresh"
                            onClicked: root.fetchMap()
                        }
                    }
                }
            }

            // ---------------- stat cards ----------------
            RowLayout {
                Layout.fillWidth: true
                spacing: Style.spacing.sm

                StatCard { label: "total users"; value: root.fmt(root.total); highlight: true }
                StatCard { label: "active 30d"; value: root.fmt(root.active30d) }
                StatCard { label: "countries"; value: String(root.dots.length) }
            }

            PanelSeparator { Layout.fillWidth: true; opacity: 0.5 }

            // ---------------- map + rail ----------------
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Style.spacing.md

                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    color: "transparent"
                    radius: Style.cornerRadius
                    clip: true
                    border.width: 1
                    border.color: Color.popups.border

                    Item {
                        id: mapArea
                        anchors.fill: parent

                        Image {
                            id: mapImage
                            anchors.fill: parent
                            fillMode: Image.PreserveAspectFit
                            source: Qt.resolvedUrl("assets/world.svg")
                            smooth: true
                        }

                        // equirectangular dot layer tracking the drawn image
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
                                    readonly property real dotR: Math.max(3.5, Math.min(14,
                                        2.5 + 9.5 * Math.sqrt(modelData.count / Math.max(1, root.maxCount))))

                                    x: px - dotR
                                    y: py - dotR
                                    width: dotR * 2
                                    height: dotR * 2

                                    Behavior on width { NumberAnimation { duration: 120 } }

                                    Rectangle { // glow
                                        anchors.centerIn: parent
                                        width: parent.width + 10
                                        height: parent.height + 10
                                        radius: width / 2
                                        color: Color.accent
                                        opacity: 0.18
                                    }
                                    Rectangle { // body
                                        anchors.fill: parent
                                        radius: width / 2
                                        color: Color.accent
                                        border.width: 1.5
                                        border.color: Color.popups.background
                                        Behavior on width { NumberAnimation { duration: 120 } }
                                    }
                                    Rectangle { // hover ring
                                        visible: dotMouse.containsMouse
                                        anchors.centerIn: parent
                                        width: parent.width + 8
                                        height: parent.height + 8
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
                                        text: root.flagEmoji(modelData.code) + "  " + modelData.name
                                            + " \u2014 " + root.fmt(modelData.count)
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

                            // legend
                            RowLayout {
                                anchors.left: parent.left
                                anchors.leftMargin: Style.space(10)
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: Style.space(8)
                                spacing: Style.spacing.xs
                                visible: root.loaded && root.dots.length > 0

                                Rectangle {
                                    Layout.preferredWidth: 7
                                    Layout.preferredHeight: 7
                                    radius: 4
                                    color: Color.accent
                                }
                                Text {
                                    text: "dot size = users per country"
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption
                                    color: root.dim
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
                                color: root.dim
                                horizontalAlignment: Text.AlignHCenter
                                width: parent.width * 0.7
                                wrapMode: Text.WordWrap
                            }
                        }
                    }
                }

                // ---------------- right rail ----------------
                ColumnLayout {
                    Layout.preferredWidth: Style.space(220)
                    Layout.fillHeight: true
                    spacing: Style.spacing.md

                    // you card
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Style.space(128)
                        color: Color.popups.background
                        radius: Style.cornerRadius
                        border.width: 1
                        border.color: root.onMap ? Color.accent : Color.popups.border

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: Style.spacing.md
                            spacing: Style.spacing.sm

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Style.spacing.sm

                                Rectangle {
                                    Layout.preferredWidth: 8
                                    Layout.preferredHeight: 8
                                    radius: 4
                                    color: root.onMap ? Color.accent
                                        : (root.optedOut ? Color.urgent : root.dim)
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: root.onMap ? "You are on the map"
                                        : (root.optedOut ? "You left the map" : "Joining \u2026")
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption
                                    font.bold: true
                                    color: root.onMap ? Color.accent
                                        : (root.optedOut ? Color.urgent : root.dim)
                                    elide: Text.ElideRight
                                }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: "Country is derived from your IP server-side \u2014 no IP, "
                                    + "no precise location, no name. Opt-in by default; leave anytime."
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                color: root.dim
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

                    // top countries
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: Style.spacing.xs
                        visible: root.countries.length > 0

                        PanelSectionHeader {
                            Layout.fillWidth: true
                            text: "Top countries"
                        }

                        Item { Layout.fillHeight: true }

                        Repeater {
                            model: {
                                var top = [];
                                var n = Math.min(8, root.countries.length);
                                for (var i = 0; i < n; i++) top.push(root.countries[i]);
                                return top;
                            }
                            delegate: ColumnLayout {
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: Style.spacing.xxs

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Style.spacing.sm

                                    Text {
                                        text: root.flagEmoji(modelData.code)
                                        font.pixelSize: Style.font.body
                                        Layout.preferredWidth: Style.space(20)
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
                                        color: root.dim
                                    }
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 3
                                    radius: 2
                                    color: Qt.darker(Color.popups.background, 1.1)

                                    Rectangle {
                                        width: parent.width * Math.min(1, modelData.count / Math.max(1, root.maxCount))
                                        height: parent.height
                                        radius: 2
                                        color: Color.accent
                                        opacity: 0.85
                                    }
                                }
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
                        + "records expire after 12 months \u00b7 rate limited"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: Qt.darker(Color.foreground, 1.35)
                    elide: Text.ElideRight
                }
                Text {
                    text: "updated " + root.formatUpdated(root.updatedAt)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: Qt.darker(Color.foreground, 1.35)
                }
            }
        }
    }
}
