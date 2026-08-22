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
    property int total: 0
    property int active30d: 0
    property int updatedAt: 0
    property bool loading: false
    property bool loaded: false
    property bool offline: false
    property string errorText: ""

    readonly property bool onMap: root.hostWidget ? root.hostWidget.registered === true : false
    readonly property var countryCoords: {
        "AD": [42.55, 1.6],
        "AE": [23.42, 53.85],
        "AF": [33.94, 67.71],
        "AG": [17.06, -61.8],
        "AI": [18.22, -63.07],
        "AL": [41.15, 20.17],
        "AM": [40.07, 45.04],
        "AO": [-11.2, 17.87],
        "AQ": [-75.0, 0.0],
        "AR": [-38.42, -63.62],
        "AS": [-14.27, -170.13],
        "AT": [47.52, 14.55],
        "AU": [-25.27, 133.78],
        "AW": [12.52, -69.97],
        "AX": [60.18, 20.01],
        "AZ": [40.14, 47.58],
        "BA": [43.92, 17.68],
        "BB": [13.19, -59.54],
        "BD": [23.68, 90.36],
        "BE": [50.5, 4.47],
        "BF": [12.24, -1.56],
        "BG": [42.73, 25.49],
        "BH": [26.07, 50.55],
        "BI": [-3.37, 29.92],
        "BJ": [9.31, 2.32],
        "BL": [17.9, -62.83],
        "BM": [32.31, -64.75],
        "BN": [4.54, 114.73],
        "BO": [-16.29, -63.59],
        "BQ": [12.18, -68.26],
        "BR": [-14.24, -51.93],
        "BS": [25.03, -77.4],
        "BT": [27.51, 90.43],
        "BV": [-54.42, 3.41],
        "BW": [-24.66, 21.86],
        "BY": [53.71, 27.95],
        "BZ": [17.19, -88.5],
        "CA": [56.13, -106.35],
        "CC": [-12.16, 96.87],
        "CD": [-4.04, 21.76],
        "CF": [6.61, 20.94],
        "CG": [-0.23, 15.83],
        "CH": [46.82, 8.23],
        "CI": [7.54, -5.55],
        "CK": [-21.24, -159.78],
        "CL": [-35.68, -71.54],
        "CM": [7.37, 12.35],
        "CN": [35.86, 104.2],
        "CO": [4.57, -74.3],
        "CR": [9.75, -83.75],
        "CU": [21.52, -77.78],
        "CV": [16.0, -24.01],
        "CW": [12.17, -68.99],
        "CX": [-10.45, 105.69],
        "CY": [35.13, 33.43],
        "CZ": [49.82, 15.47],
        "DE": [51.17, 10.45],
        "DJ": [11.83, 42.59],
        "DK": [56.26, 9.5],
        "DM": [15.41, -61.37],
        "DO": [18.74, -70.16],
        "DZ": [28.03, 1.66],
        "EC": [-1.83, -78.18],
        "EE": [58.6, 25.01],
        "EG": [26.82, 30.8],
        "EH": [24.22, -12.94],
        "ER": [15.18, 39.78],
        "ES": [40.46, -3.75],
        "ET": [9.15, 40.49],
        "FI": [64.5, 26.07],
        "FJ": [-16.58, 179.41],
        "FK": [-51.8, -59.52],
        "FM": [7.43, 150.55],
        "FO": [61.89, -6.91],
        "FR": [46.23, 2.21],
        "GA": [-0.8, 11.61],
        "GB": [55.38, -3.44],
        "GD": [12.26, -61.6],
        "GE": [42.32, 43.36],
        "GF": [3.93, -53.13],
        "GG": [49.47, -2.59],
        "GH": [7.95, -1.02],
        "GI": [36.14, -5.35],
        "GL": [71.71, -42.6],
        "GM": [13.44, -15.31],
        "GN": [9.95, -9.7],
        "GP": [16.27, -61.55],
        "GQ": [1.65, 10.27],
        "GR": [39.07, 21.82],
        "GS": [-54.43, -36.59],
        "GT": [15.78, -90.23],
        "GU": [13.44, 144.79],
        "GW": [11.8, -15.18],
        "GY": [4.86, -58.93],
        "HK": [22.32, 114.17],
        "HM": [-53.1, 73.5],
        "HN": [15.2, -86.24],
        "HR": [45.1, 15.2],
        "HT": [18.97, -72.29],
        "HU": [47.16, 19.5],
        "ID": [-0.79, 113.92],
        "IE": [53.41, -8.24],
        "IL": [31.05, 34.85],
        "IM": [54.24, -4.55],
        "IN": [20.59, 78.96],
        "IO": [-6.34, 71.88],
        "IQ": [33.22, 43.68],
        "IR": [32.43, 53.69],
        "IS": [64.96, -19.02],
        "IT": [41.87, 12.57],
        "JE": [49.21, -2.13],
        "JM": [18.11, -77.3],
        "JO": [31.24, 36.51],
        "JP": [36.2, 138.25],
        "KE": [-0.02, 37.91],
        "KG": [41.2, 74.77],
        "KH": [12.57, 104.99],
        "KI": [-1.88, -157.36],
        "KM": [-11.88, 43.87],
        "KN": [17.36, -62.78],
        "KP": [40.34, 127.51],
        "KR": [35.91, 127.77],
        "KW": [29.31, 47.48],
        "KY": [19.31, -81.25],
        "KZ": [48.02, 66.92],
        "LA": [18.2, 104.0],
        "LB": [33.85, 35.86],
        "LC": [13.91, -60.98],
        "LI": [47.17, 9.56],
        "LK": [7.87, 80.77],
        "LR": [6.43, -9.43],
        "LS": [-29.61, 28.23],
        "LT": [55.17, 23.88],
        "LU": [49.82, 6.13],
        "LV": [56.88, 24.6],
        "LY": [26.34, 17.23],
        "MA": [31.79, -7.09],
        "MC": [43.74, 7.42],
        "MD": [47.41, 28.37],
        "ME": [42.71, 19.37],
        "MF": [18.09, -63.05],
        "MG": [-18.77, 46.87],
        "MH": [7.13, 171.18],
        "MK": [41.61, 21.75],
        "ML": [17.57, -3.99],
        "MM": [21.92, 95.96],
        "MN": [46.86, 103.85],
        "MO": [22.2, 113.54],
        "MP": [15.1, 145.67],
        "MQ": [14.64, -61.02],
        "MR": [21.01, -10.94],
        "MS": [16.74, -62.19],
        "MT": [35.94, 14.38],
        "MU": [-20.35, 57.55],
        "MV": [3.2, 73.22],
        "MW": [-13.25, 34.3],
        "MX": [23.63, -102.55],
        "MY": [4.21, 101.98],
        "MZ": [-18.67, 35.53],
        "NA": [-22.96, 18.49],
        "NC": [-20.9, 165.62],
        "NE": [17.61, 8.08],
        "NF": [-29.04, 167.95],
        "NG": [9.08, 8.68],
        "NI": [12.87, -85.21],
        "NL": [52.13, 5.29],
        "NO": [60.47, 8.47],
        "NP": [28.39, 84.12],
        "NR": [-0.52, 166.93],
        "NU": [-19.05, -169.87],
        "NZ": [-40.9, 174.89],
        "OM": [21.51, 55.92],
        "PA": [8.54, -80.78],
        "PE": [-9.19, -75.02],
        "PF": [-17.68, -149.41],
        "PG": [-6.31, 143.96],
        "PH": [12.88, 121.77],
        "PK": [30.38, 69.35],
        "PL": [51.92, 19.15],
        "PM": [46.89, -56.32],
        "PN": [-24.7, -127.44],
        "PR": [18.22, -66.59],
        "PS": [31.95, 35.23],
        "PT": [39.4, -8.22],
        "PW": [7.51, 134.58],
        "PY": [-23.44, -58.44],
        "QA": [25.35, 51.18],
        "RE": [-21.12, 55.54],
        "RO": [45.94, 24.97],
        "RS": [44.21, 20.92],
        "RU": [61.52, 105.32],
        "RW": [-1.94, 29.87],
        "SA": [23.89, 45.08],
        "SB": [-9.65, 160.16],
        "SC": [-4.68, 55.49],
        "SD": [12.86, 30.22],
        "SE": [60.13, 18.64],
        "SG": [1.35, 103.82],
        "SH": [-24.14, -10.03],
        "SI": [46.15, 14.99],
        "SJ": [77.89, 18.0],
        "SK": [48.67, 19.7],
        "SL": [8.46, -11.78],
        "SM": [43.94, 12.46],
        "SN": [14.5, -14.45],
        "SO": [5.15, 46.2],
        "SR": [3.92, -56.03],
        "SS": [6.88, 31.31],
        "ST": [0.19, 6.61],
        "SV": [13.79, -88.9],
        "SX": [18.04, -63.07],
        "SY": [34.8, 38.99],
        "SZ": [-26.52, 31.47],
        "TC": [21.69, -71.8],
        "TD": [15.45, 18.73],
        "TF": [-49.28, 69.35],
        "TG": [8.62, 0.82],
        "TH": [15.87, 100.99],
        "TJ": [38.86, 71.28],
        "TK": [-9.0, -171.99],
        "TL": [-8.87, 125.73],
        "TM": [38.97, 59.56],
        "TN": [33.89, 9.56],
        "TO": [-21.18, -175.2],
        "TR": [38.96, 35.24],
        "TT": [10.69, -61.22],
        "TV": [-7.48, 178.01],
        "TW": [23.7, 120.96],
        "TZ": [-6.37, 34.89],
        "UA": [48.38, 31.17],
        "UG": [1.37, 32.29],
        "UM": [19.28, 166.65],
        "US": [39.83, -98.58],
        "UY": [-32.52, -55.77],
        "UZ": [41.38, 64.59],
        "VA": [41.9, 12.45],
        "VC": [13.25, -61.2],
        "VE": [6.42, -66.59],
        "VG": [18.42, -64.64],
        "VI": [18.34, -64.9],
        "VN": [14.06, 108.28],
        "VU": [-15.38, 166.96],
        "WF": [-13.77, -177.16],
        "WS": [-13.76, -172.1],
        "XK": [42.6, 20.9],
        "YE": [15.55, 48.52],
        "YT": [-12.83, 45.17],
        "ZA": [-30.56, 22.94],
        "ZM": [-13.13, 27.85],
        "ZW": [-19.02, 29.15]
    }

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
        loaded = true
        errorText = ""
    }

    function joinMap() {
        // Optimistic: update counts and dot instantly with correct lat/lon
        if (!onMap) {
            total = total + 1
            active30d = active30d + 1
            var code = hostWidget && hostWidget.myCountry ? String(hostWidget.myCountry).toUpperCase() : ""
            if (code) {
                var found = false
                for (var i = 0; i < dots.length; i++) {
                    if (String(dots[i].code).toUpperCase() === code) {
                        var nd = dots.slice(); nd[i] = Object.assign({}, nd[i], {count: (Number(nd[i].count)||0)+1}); dots = nd; found = true; break
                    }
                }
                if (!found) {
                    var coord = countryCoords[code]
                    if (coord) {
                        dots = dots.concat([{code: code, name: code, count: 1, lat: coord[0], lon: coord[1]}])
                    } else {
                        dots = dots.concat([{code: code, name: code, count: 1, lat: 0, lon: 0}])
                    }
                }
            }
        }
        if (hostWidget && hostWidget.joinMap) hostWidget.joinMap()
        fetchMap(true)
    }

    function optOut() {
        // Optimistic: decrement instantly if on map
        if (onMap) {
            if (total > 0) total = total - 1
            if (active30d > 0) active30d = active30d - 1
            var code2 = hostWidget && hostWidget.myCountry ? String(hostWidget.myCountry).toUpperCase() : ""
            if (code2) {
                for (var j = 0; j < dots.length; j++) {
                    if (String(dots[j].code).toUpperCase() === code2) {
                        if ((Number(dots[j].count)||0) <= 1) { var nd2 = dots.slice(); nd2.splice(j,1); dots = nd2 }
                        else { var nd3 = dots.slice(); nd3[j] = Object.assign({}, nd3[j], {count: nd3[j].count-1}); dots = nd3 }
                        break
                    }
                }
            }
        }
        if (hostWidget && hostWidget.optOut) hostWidget.optOut()
        fetchMap(true)
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
                    Button {
                        text: root.onMap ? "leave" : "join"
                        fontSize: Style.font.caption
                        foreground: Color.foreground
                        accent: Color.accent
                        bordered: true
                        onClicked: root.onMap ? root.optOut() : root.joinMap()
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
