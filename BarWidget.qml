import QtQuick
import QtQuick.Controls
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
    property string consent: ""
    property bool registered: false
    property int total: 0
    property int active30d: 0
    property string lastError: ""

    readonly property bool consentPending: root.bridgeReady && root.consent === ""
    readonly property bool optedOut: root.consent === "no"

    // The consent popup only ever appears on the first monitor's bar, so a
    // multi-monitor user is not asked the same question on every screen.
    readonly property bool isPrimaryScreen: {
        try {
            var win = button.QsWindow.window;
            var screens = Quickshell.screens || [];
            return !(screens.length > 1) || !win || win.screen === screens[0];
        } catch (e) { return true; }
    }

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

    function fetchStats() {
        if (!root.bridgeReady) return;
        if (!statsProc.running) statsProc.running = true;
    }

    function joinMap() {
        if (!root.bridgeReady) return;
        consentPopup.open = false;
        registerProc.command = ["bash", root.bridge, "consent", "yes"];
        registerProc.running = true;
    }

    function optOut() {
        if (!root.bridgeReady) return;
        consentPopup.open = false;
        root.consent = "no";
        registerProc.command = ["bash", root.bridge, "consent", "no"];
        registerProc.running = true;
    }

    function forgetDevice() {
        if (!root.bridgeReady) return;
        root.consent = "";
        registerProc.command = ["bash", root.bridge, "forget"];
        registerProc.running = true;
    }

    function togglePanel() {
        if (panelLoader.item && panelLoader.item.toggle)
            panelLoader.item.toggle();
        if (root.consentPending) {
            consentPopup.open = true;
        }
    }

    function closeConsent() { consentPopup.open = false; }

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
        root.consent = json.consent === "yes" ? "yes" : (json.consent === "no" ? "no" : "");
        root.registered = json.registered === true;
        if (json.lastTotal !== undefined && json.lastTotal !== null) root.total = json.lastTotal;
        if (json.lastActive !== undefined && json.lastActive !== null) root.active30d = json.lastActive;
        root.bridgeReady = true;
        root.installing = false;
        root.readStatsCache();
    }

    IpcHandler {
        target: "tenzin.omauser"

        function refresh(): void { root.broadcast("refreshState"); }
        function join(): void { root.broadcast("joinMap"); }
        function optOut(): void { root.broadcast("optOut"); }
        function forget(): void { root.broadcast("forgetDevice"); }
        function toggle(): void { root.broadcast("togglePanel"); }
        function status(): string {
            return JSON.stringify({
                bridgeReady: root.bridgeReady,
                consent: root.consent,
                registered: root.registered,
                total: root.total,
                active30d: root.active30d,
                consentPopup: consentPopup.open,
                panelLoaded: panelLoader.item !== null,
                panelOpened: panelLoader.item ? panelLoader.item.opened === true : false,
                mapDots: panelLoader.item && panelLoader.item.dots ? panelLoader.item.dots.length : -1,
                isPrimary: root.isPrimaryScreen
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
            if (root.consent === "yes") root.fetchStats();
        }
    }

    Process {
        id: heartbeatProc
        command: ["bash", root.bridge, "heartbeat"]
    }

    Timer {
        id: statsTimer
        interval: 300000
        repeat: true
        triggeredOnStart: true
        running: root.bridgeReady
        onTriggered: root.fetchStats()
    }

    Timer {
        id: heartbeatTimer
        interval: 21600000
        repeat: true
        running: root.bridgeReady && root.consent === "yes"
        onTriggered: {
            heartbeatProc.command = ["bash", root.bridge, "heartbeat"];
            heartbeatProc.running = true;
        }
    }

    RowLayout {
        id: row
        anchors.fill: parent
        spacing: 0

        BarIconButton {
            id: button
            bar: root.bar
            text: "\uf0ac"
            slotSize: Style.bar.statusSlot
            fontSize: Style.font.caption
            tooltipText: root.consentPending
                ? "Omauser \u2022 join the user map?"
                : (root.optedOut
                    ? "Omauser \u2022 you are not on the map \u2022 " + root.fmt(root.total) + " users"
                    : (root.bridgeReady
                        ? "Omauser \u2022 " + root.fmt(root.total) + " users \u00b7 " + root.fmt(root.active30d) + " active (30d)"
                        : (root.bridgeError || "Omauser \u2022 not installed; click to retry")))
            onPressed: root.togglePanel()
        }

        Text {
            id: countText
            text: root.countLabel
            color: root.bar ? root.bar.barForeground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            verticalAlignment: Text.AlignVCenter
            renderType: Text.NativeRendering

            MouseArea {
                anchors.fill: parent
                onClicked: root.togglePanel()
            }
        }
    }

    PopupCard {
        id: consentPopup
        anchorItem: button
        bar: root.bar
        owner: root
        contentWidth: Style.space(320)
        contentHeight: Style.space(196)
        open: root.consentPending && root.isPrimaryScreen

        ColumnLayout {
            anchors.fill: parent
            spacing: Style.spacing.sm

            Text {
                Layout.fillWidth: true
                text: "\uf0ac  Join the Omarchy user map?"
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
            }

            Text {
                Layout.fillWidth: true
                text: "Omauser anonymously records your device (hashed machine-id) and your country "
                    + "(derived from your IP \u2014 the IP itself is never stored) so Omarchy users "
                    + "appear on the world map. You can leave the map any time."
                color: Qt.darker(Color.foreground, 1.25)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
            }

            Item { Layout.fillHeight: true }

            RowLayout {
                Layout.fillWidth: true
                spacing: Style.spacing.sm

                Item { Layout.fillWidth: true }

                Button {
                    text: "No thanks"
                    fontSize: Style.font.caption
                    foreground: Color.foreground
                    onClicked: root.optOut()
                }

                Button {
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