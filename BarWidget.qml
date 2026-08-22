import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
    id: root
    moduleName: "tenzin.omauser"

    visible: true
    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight

    readonly property string runtime: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omauser"
    readonly property string setupScript: Qt.resolvedUrl("omauser-setup.sh").toString().replace(/^file:\/\//, "")
    readonly property string bridge: runtime + "/omauser-bridge.sh"
    readonly property string statsFile: runtime + "/stats.json"

    property bool bridgeReady: false
    property bool installing: false
    property string bridgeError: ""
    property bool optedOut: false
    property bool registered: false
    property int total: 0
    property int active30d: 0
    property string myCountry: ""
    property string lastError: ""

    // Opt-in is the default: a fresh install registers automatically once
    // the bridge is up. The user can leave the map from the panel UI.
    readonly property bool shouldAutoRegister: root.bridgeReady && !root.optedOut && !root.registered

    readonly property string countLabel: {
        if (root.total <= 0) return "0";
        if (root.total < 1000) return String(root.total);
        if (root.total < 100000) return (root.total / 1000).toFixed(1) + "k";
        return (root.total / 1000).toFixed(0) + "k";
    }

    function fmt(n) {
        return Number(n || 0).toLocaleString();
    }

    function ensureBridge() {
        if (setupProc.running) return;
        root.installing = true;
        root.bridgeError = "";
        setupProc.setupOutput = "";
        setupProc.command = ["bash", root.setupScript];
        setupProc.running = true;
    }

    function refreshState() {
        if (!root.bridgeReady) return;
        if (!statusProc.running) statusProc.running = true;
    }

    function readStatsCache() {
        if (!root.bridgeReady) return;
        if (!statsCacheProc.running) statsCacheProc.running = true;
    }

    function fetchStats(force) {
        if (!root.bridgeReady) return;
        if (statsProc.running) return;
        statsProc.command = ["bash", root.bridge, force ? "stats-force" : "stats"];
        statsProc.running = true;
    }

    function joinMap() {
        if (!root.bridgeReady) return;
        if (!root.registered) { root.total = root.total + 1; root.active30d = root.active30d + 1 }
        root.optedOut = false;
        root.registered = true
        registerProc.command = ["bash", root.bridge, "join"];
        registerProc.running = true;
    }

    function optOut() {
        if (!root.bridgeReady) return;
        if (root.registered && root.total > 0) root.total = root.total - 1
        if (root.registered && root.active30d > 0) root.active30d = root.active30d - 1
        root.optedOut = true;
        root.registered = false
        registerProc.command = ["bash", root.bridge, "opt-out"];
        registerProc.running = true;
    }

    function togglePanel() {
        if (panelLoader.item && panelLoader.item.openFromHotkey)
            panelLoader.item.openFromHotkey();
    }

    function injectPanel() {
        var target = panelLoader.item;
        if (!target) return;
        if ("bar" in target) target.bar = root.bar;
        if ("settings" in target) target.settings = root.settings;
        if ("anchorItem" in target) target.anchorItem = button;
        if ("hostWidget" in target) target.hostWidget = root;
    }

    function applyStatus(json) {
        if (!json) return;
        root.optedOut = json.optedOut === true;
        root.registered = json.registered === true;
        if (json.lastTotal !== undefined && json.lastTotal !== null) root.total = json.lastTotal;
        if (json.lastActive !== undefined && json.lastActive !== null) root.active30d = json.lastActive;
        root.bridgeReady = true;
        root.installing = false;
        root.readStatsCache();
        if (root.shouldAutoRegister) {
            registerProc.command = ["bash", root.bridge, "register"];
            registerProc.running = true;
        }
    }

    IpcHandler {
        target: "tenzin.omauser"

        function refresh(): void { root.broadcast("refreshState"); }
        function join(): void { root.broadcast("joinMap"); }
        function optOut(): void { root.broadcast("optOut"); }
        function toggle(): void { root.broadcast("togglePanel"); }
        function refreshMap(): void {
            if (panelLoader.item && panelLoader.item.fetchMap) panelLoader.item.fetchMap();
        }
        function status(): string {
            return JSON.stringify({
                bridgeReady: root.bridgeReady,
                optedOut: root.optedOut,
                registered: root.registered,
                total: root.total,
                active30d: root.active30d,
                panelLoaded: panelLoader.item !== null,
                panelOpened: panelLoader.item ? panelLoader.item.opened === true : false,
                mapDots: panelLoader.item && panelLoader.item.dots ? panelLoader.item.dots.length : -1
            });
        }
    }

    Process {
        id: setupProc
        property string setupOutput: ""
        property string errorOutput: ""
        stdout: SplitParser {
            onRead: function(data) { setupProc.setupOutput += data + "\n" }
        }
        stderr: SplitParser {
            onRead: function(data) { setupProc.errorOutput += data + "\n" }
        }
        onExited: function(exitCode) {
            root.installing = false;
            root.bridgeReady = exitCode === 0;
            if (!root.bridgeReady) {
                root.bridgeError = setupProc.errorOutput.trim() || "Bridge installation failed";
                return;
            }
            root.refreshState();
        }
    }

    Process {
        id: statusProc
        command: ["bash", root.bridge, "status"]
        property string out: ""
        stdout: SplitParser {
            onRead: function(data) { statusProc.out += data }
        }
        onExited: function(exitCode) {
            if (exitCode !== 0) return;
            var json = null;
            try { json = JSON.parse(statusProc.out); } catch (e) {}
            root.applyStatus(json);
            statusProc.out = "";
        }
    }

    Process {
        id: statsCacheProc
        command: ["cat", root.statsFile]
        property string out: ""
        stdout: SplitParser {
            onRead: function(data) { statsCacheProc.out += data }
        }
        onExited: function(exitCode) {
            if (exitCode !== 0) return;
            try {
                var json = JSON.parse(statsCacheProc.out);
                root.total = json.total || 0;
                root.active30d = json.active30d || 0;
                if (typeof json.myCountry === "string") root.myCountry = json.myCountry;
            } catch (e) {}
            statsCacheProc.out = "";
        }
    }

    Process {
        id: statsProc
        command: ["bash", root.bridge, "stats"]
        onExited: function(exitCode) {
            root.lastError = exitCode === 0 ? "" : "offline — showing last cached data";
            root.readStatsCache();
        }
    }

    Process {
        id: registerProc
        property string out: ""
        stdout: SplitParser {
            onRead: function(data) { registerProc.out += data }
        }
        onExited: function(exitCode) {
            registerProc.out = "";
            root.refreshState();
            if (!root.optedOut) root.fetchStats();
        }
    }

    Process {
        id: heartbeatProc
        command: ["bash", root.bridge, "heartbeat"]
    }

    Timer {
        id: statsTimer
        // 5min base + jitter ±45s to avoid thundering herd on free tier
        interval: 300000 + Math.floor(Math.random() * 90000 - 45000)
        repeat: true
        triggeredOnStart: true
        running: root.bridgeReady
        onTriggered: {
            root.fetchStats()
            // re-randomize next interval
            statsTimer.interval = 300000 + Math.floor(Math.random() * 90000 - 45000)
        }
    }

    Timer {
        id: heartbeatTimer
        // 23h base + jitter ±1h + initial random delay to spread heartbeats
        interval: 82800000 + Math.floor(Math.random() * 7200000 - 3600000)
        repeat: true
        running: root.bridgeReady && !root.optedOut
        onTriggered: {
            heartbeatProc.command = ["bash", root.bridge, "heartbeat"];
            heartbeatProc.running = true
            heartbeatTimer.interval = 82800000 + Math.floor(Math.random() * 7200000 - 3600000)
        }
    }

    RowLayout {
        id: row
        anchors.fill: parent
        spacing: 6

        BarIconButton {
            id: button
            bar: root.bar
            text: "\uf57d" // globe-americas - more distinctive than \uf0ac
            slotSize: Style.bar.statusSlot
            fontSize: Style.bar.iconFont
            active: root.registered && !root.optedOut
            useActiveColor: true
            activeColor: Color.accent
            tooltipText: root.optedOut
                ? "Omauser \u2022 not on the map \u2022 " + root.fmt(root.total) + " users \u2022 click to join"
                : (root.bridgeReady
                    ? "Omauser \u2022 " + root.fmt(root.total) + " users \u00b7 " + root.fmt(root.active30d) + " active (30d) \u2022 click for the map"
                    : (root.bridgeError || "Omauser \u2022 not installed; click to retry"))
            onPressed: root.togglePanel()
        }

        Rectangle {
            id: countPill
            visible: root.bridgeReady
            Layout.alignment: Qt.AlignVCenter
            implicitWidth: Math.max(28, pillText.implicitWidth + 16)
            implicitHeight: 18
            radius: 9
            color: root.optedOut
                ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.14)
                : (root.registered
                    ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.14)
                    : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08))
            border.width: 1
            border.color: root.optedOut
                ? Color.urgent
                : (root.registered ? Color.accent : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.18))
            opacity: root.bridgeReady ? 1.0 : 0.6

            Behavior on color { ColorAnimation { duration: 180 } }
            Behavior on border.color { ColorAnimation { duration: 180 } }

            Text {
                id: pillText
                anchors.centerIn: parent
                text: root.countLabel
                color: root.optedOut ? Color.urgent : (root.registered ? Color.accent : Color.foreground)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                font.weight: Font.Medium
                verticalAlignment: Text.AlignVCenter
                renderType: Text.NativeRendering
            }

            // Keep id for compatibility
            Text {
                id: countText
                visible: false
                text: root.countLabel
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.togglePanel()
            }
        }

        Text {
            id: activeText
            visible: root.bridgeReady && root.total > 0
            Layout.alignment: Qt.AlignVCenter
            text: "· " + root.fmt(root.active30d) + " active"
            color: Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.15)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.weight: Font.Normal
            opacity: 0.85
            verticalAlignment: Text.AlignVCenter
            renderType: Text.NativeRendering

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.togglePanel()
            }
        }
    }

    Loader {
        id: panelLoader
        active: true
        source: Qt.resolvedUrl("Panel.qml")
        visible: false
        onLoaded: {
            root.injectPanel();
            Qt.callLater(root.injectPanel);
        }
    }

    Component.onCompleted: {
        root.ensureBridge();
    }
}