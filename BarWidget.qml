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
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    readonly property string runtime: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omauser"
    readonly property string setupScript: Qt.resolvedUrl("omauser-setup.sh").toString().replace(/^file:\/\//, "")
    readonly property string bridge: runtime + "/omauser-bridge.sh"
    readonly property string statsFile: runtime + "/stats.json"

    property bool bridgeReady: false
    property bool installing: false
    property string bridgeError: ""
    property bool registered: false
    property int total: 0
    property int active30d: 0
    property string myCountry: ""
    property string lastError: ""
    property bool _ignoreNextStatusTotal: false

    // Opt-in is the default: a fresh install registers automatically once
    // the bridge is up. The user can leave the map from the panel UI.
    readonly property bool shouldAutoRegister: root.bridgeReady && !root.registered

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

    // Serialized join/leave: Quickshell ignores running=true while a Process
    // is already executing, which silently dropped clicks. Queue instead.
    property string _pendingOp: ""

    function _startRegister(op) {
        if (registerProc.running) { root._pendingOp = op; return }
        root._pendingOp = ""
        registerProc.command = ["bash", root.bridge, op];
        registerProc.running = true;
    }

    function joinMap() {
        if (!root.bridgeReady) return;
        if (root.registered) return
        root.registered = true
        _startRegister("join");
    }

    function togglePanel() {
        if (panelLoader.item && panelLoader.item.toggle)
            panelLoader.item.toggle();
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
        // While a register is in flight, the optimistic registered value is
        // authoritative - state.json may be stale and must not flip it back.
        const inflight = registerProc.running;
        if (!inflight) {
            root.registered = json.registered === true;
        }
        if (!root._ignoreNextStatusTotal) {
            if (json.lastTotal !== undefined && json.lastTotal !== null) root.total = json.lastTotal;
            if (json.lastActive !== undefined && json.lastActive !== null) root.active30d = json.lastActive;
        } else {
            root._ignoreNextStatusTotal = false
        }
        root.bridgeReady = true;
        root.installing = false;
        root.readStatsCache();
        if (!inflight && root.shouldAutoRegister) {
            registerProc.command = ["bash", root.bridge, "register"];
            registerProc.running = true;
        }
    }

    IpcHandler {
        target: "tenzin.omauser"

        function refresh(): void { root.broadcast("refreshState"); }
        function join(): void { root.broadcast("joinMap"); }
        function toggle(): void { root.broadcast("togglePanel"); }
        function refreshMap(): void {
            if (panelLoader.item && panelLoader.item.fetchMap) panelLoader.item.fetchMap();
        }
        function status(): string {
            return JSON.stringify({
                bridgeReady: root.bridgeReady,
                registered: root.registered,
                total: root.total,
                myCountry: root.myCountry,
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
            // Backoff bookkeeping: success resets to normal 5-min cadence.
            if (exitCode === 0) root.statsFails = 0;
            else root.statsFails = Math.min(root.statsFails + 1, 6);
            statsTimer.interval = root.nextStatsInterval()
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
            // Force-refresh after join/leave so the bar count comes from a
            // full scan (truth) instead of the 5m cache, which may briefly
            // predate the registration write.
            root.fetchStats(true);
            // Run a click that arrived while this operation was executing.
            if (root._pendingOp !== "") {
                const op = root._pendingOp
                root._pendingOp = ""
                registerProc.command = ["bash", root.bridge, op];
                registerProc.running = true;
            }
        }
    }

    Process {
        id: heartbeatProc
        command: ["bash", root.bridge, "heartbeat"]
    }

    // Offline backoff: after consecutive failed polls, double the interval up
    // to a ~5h cap so an offline laptop settles into ~6 requests/day. Any
    // success resets instantly to the normal 5-min freshness.
    property int statsFails: 0
    readonly property int statsBaseInterval: 300000

    function nextStatsInterval() {
        const backoff = Math.min(1 << Math.min(root.statsFails, 6), 64)
        const base = root.statsBaseInterval * backoff
        return base + Math.floor(Math.random() * base * 0.15 - base * 0.075)
    }

    Timer {
        id: statsTimer
        interval: root.statsBaseInterval
        repeat: true
        triggeredOnStart: true
        running: root.bridgeReady
        onTriggered: {
            root.fetchStats()
            statsTimer.interval = root.nextStatsInterval()
        }
    }

    Timer {
        id: heartbeatTimer
        // 23h base + jitter ±1h + initial random delay to spread heartbeats
        interval: 82800000 + Math.floor(Math.random() * 7200000 - 3600000)
        repeat: true
        running: root.bridgeReady && root.registered
        onTriggered: {
            heartbeatProc.command = ["bash", root.bridge, "heartbeat"];
            heartbeatProc.running = true
            heartbeatTimer.interval = 82800000 + Math.floor(Math.random() * 7200000 - 3600000)
        }
    }

    // Canon bar layout - icon only, matches SystemUpdate/Microphone/omamovie
    // OpticalGlyph inside BarIconButton handles optical centering and theme
    // via bar.barForeground / bar.urgent automatically.
    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: "人"
        slotSize: Style.bar.statusSlot
        tooltipText: root.bridgeReady
            ? "Omauser \u2022 " + root.fmt(root.total) + " users \u00b7 " + root.fmt(root.active30d) + " active (30d) \u2022 click for the map"
            : (root.bridgeError || "Omauser \u2022 not installed; click to retry")
        onPressed: root.togglePanel()
    }

    // Keep ids for compatibility with older Panel injectPanel fallbacks
    Item { id: row; visible: false }
    Text { id: countPill; visible: false; text: root.countLabel }
    Text { id: pillText; visible: false; text: root.countLabel }
    Text { id: countText; visible: false; text: root.countLabel }
    Text { id: activeText; visible: false }

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