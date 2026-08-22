import QtQuick
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
    property real myCellLat: -999
    property real myCellLon: -999
    property int total: 0
    property int active30d: 0
    property int updatedAt: 0
    property bool loading: false
    property bool loaded: false
    property bool offline: false
    property string errorText: ""


    function fmt(value) { return Number(value || 0).toLocaleString() }

    function fetchMap(force) {
        if (mapProc.running) return
        // Fast read: show cached map instantly for normal refresh;
        // for join/leave (force) keep optimistic data and skip stale cache
        if (!force && !loading) readMapCache()
        loading = true
        offline = false
        mapProc.command = ["bash", root.bridge, force ? "map-force" : "map"]
        mapProc.running = true
        // Also refresh bar counts in parallel for fast UI - force bypasses cache
        if (hostWidget && hostWidget.fetchStats) hostWidget.fetchStats(force ? true : false)
    }

    function readMapCache() {
        if (mapCacheProc.running) return
        mapCacheProc.out = ""
        mapCacheProc.running = true
    }

    function applyMap(text) {
        var data = null
        try { data = JSON.parse(text) } catch (e) {}
        loading = false
        if (!data || !Array.isArray(data.dots)) {
            if (!loaded) errorText = "No user locations available yet"
            return
        }
        dots = data.dots
        total = Number(data.total || 0)
        active30d = Number(data.active30d || 0)
        updatedAt = Number(data.updatedAt || 0)
        myCellLat = (data.myCell === null || data.myCell === undefined) ? -999 : Number(data.myCell.lat)
        myCellLon = (data.myCell === null || data.myCell === undefined) ? -999 : Number(data.myCell.lon)
        loaded = true
        errorText = ""
    }

    Process {
        id: mapProc
        command: ["bash", root.bridge, "map"]
        onExited: function(code) {
            if (code === 0) root.readMapCache()
            else {
                root.loading = false
                root.offline = true
                root.errorText = root.loaded ? "offline - showing last map" : "could not reach the Omauser API"
            }
        }
    }

    Process {
        id: mapCacheProc
        command: ["cat", root.mapFile]
        property string out: ""
        stdout: SplitParser { onRead: function(data) { mapCacheProc.out += data } }
        onExited: function(code) {
            if (code === 0) root.applyMap(mapCacheProc.out)
            else {
                root.loading = false
                if (!root.loaded) root.errorText = "could not reach the Omauser API"
            }
            mapCacheProc.out = ""
        }
    }

    Timer {
        interval: 300000
        repeat: true
        running: root.opened
        onTriggered: root.fetchMap()
    }

    function openFromHotkey() {
        root.controller.open = false
        root.controller.open = true
        // Fast open: show cache immediately, then network refresh
        root.readMapCache()
        root.fetchMap()
    }
    function close() { root.controller.hide() }
    function toggle() { root.opened ? root.close() : root.openFromHotkey() }
    function closeForPopoutSwitch() { root.close() }

    FileView {
        path: Qt.resolvedUrl("assets/countries.json").toString().replace(/^file:\/\//, "")
        watchChanges: false
        printErrors: true
        onLoaded: {
            try {
                var data = JSON.parse(text())
                globe.countries = Array.isArray(data.features) ? data.features : []
            } catch (e) { globe.countries = [] }
        }
    }

    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.barIdentity
        bar: root.bar
        open: root.opened
        centerOnBar: true
        padding: 0
        focusTarget: keyCatcher
        // Outside-click dismissal calls close(); route it through the
        // controller so panelController.open resets and the panel can be
        // reopened. A direct `open = false` would break the open:opened
        // binding and leave the panel impossible to reopen.
        function close() { root.controller.hide() }
        // Keep the equirectangular map at its native 2:1 aspect ratio.
        contentWidth: panel.fittedContentWidth(Math.min(panel.screenW * 0.605, panel.screenH * 1.331))
        contentHeight: panel.fittedContentHeight(Math.min(panel.screenW * 0.3872, panel.screenH * 0.7744))

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: root.close()

            Item {
                anchors.fill: parent

                Globe {
                    id: globe
                    anchors.fill: parent
                    dots: root.dots
                    myCountryCode: root.hostWidget && root.hostWidget.myCountry ? root.hostWidget.myCountry : ""
                    myCellLat: root.myCellLat
                    myCellLon: root.myCellLon
                    backgroundColor: Color.popups.background
                    landColor: Qt.darker(Color.foreground, 2.7)
                    gridColor: Color.foreground
                    outlineColor: Color.foreground
                    dotColor: Color.accent
                    textColor: Color.foreground
                }

                RowLayout {
                    id: hud
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.margins: Style.space(14)
                    spacing: Style.spacing.sm

                    Text {
                        text: root.fmt(root.total) + " users  /  " + root.fmt(root.active30d) + " active"
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        color: Color.foreground
                        style: Text.Outline
                        styleColor: Qt.darker(Color.popups.background, 1.5)
                    }
                    Item { Layout.fillWidth: true }
                    Button {
                        text: "refresh"
                        fontSize: Style.font.caption
                        foreground: Color.foreground
                        onClicked: root.fetchMap(true)
                    }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Style.space(12)
                    text: "drag to pan  -  scroll to zoom  -  double-click to reset"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: Qt.darker(Color.foreground, 1.35)
                    style: Text.Outline
                    styleColor: Qt.darker(Color.popups.background, 1.5)
                }

                Text {
                    anchors.centerIn: parent
                    visible: root.loading
                    text: "loading user globe ..."
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    color: Color.foreground
                    style: Text.Outline
                    styleColor: Qt.darker(Color.popups.background, 1.5)
                }
            }
        }
    }
}
