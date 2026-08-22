import QtQuick

Item {
    id: root

    property var countries: []
    property var dots: []
    property string activeCountryCode: ""
    property real centreLatitude: 18
    property real centreLongitude: -20
    property real globeScale: 1
    property real minimumScale: 0.72
    property real maximumScale: 4
    property color backgroundColor: "#090c12"
    property color sphereColor: "#111a27"
    property color landColor: "#35475d"
    property color gridColor: "#8291a5"
    property color outlineColor: "#b7c4d4"
    property color dotColor: "#ff8a3d"
    property color textColor: "#f3f4f5"
    property string fontFamily: "monospace"
    property var hoveredDot: null
    property real hoverX: 0
    property real hoverY: 0
    property var preparedCountries: []
    property var preparedDots: []

    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
    function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
    function wrap(v) { while (v > 180) v -= 360; while (v < -180) v += 360; return v }
    function radius() { return Math.min(width, height) * 0.43 * globeScale }
    function flag(code) {
        if (!code || String(code).length !== 2) return ""
        var a = String(code).charCodeAt(0), b = String(code).charCodeAt(1)
        if (a < 65 || a > 90 || b < 65 || b > 90) return ""
        return String.fromCodePoint(0x1f1e6 + a - 65) + String.fromCodePoint(0x1f1e6 + b - 65)
    }
    function focusCoordinate(lat, lon) {
        centreLatitude = clamp(Number(lat) || 0, -78, 78)
        centreLongitude = wrap(Number(lon) || 0)
    }
    function point(lat, lon) {
        var la = Number(lat) * Math.PI / 180
        var lo = Number(lon) * Math.PI / 180
        var c = Math.cos(la)
        return { x: c * Math.cos(lo), y: c * Math.sin(lo), z: Math.sin(la) }
    }
    function prepare() {
        var result = []
        for (var i = 0; i < root.countries.length; i++) {
            var f = root.countries[i]
            if (!f || !f.geometry) continue
            var polygons = f.geometry.type === "Polygon" ? [f.geometry.coordinates] : f.geometry.coordinates
            var rings = []
            for (var p = 0; p < polygons.length; p++) {
                var ring = polygons[p] && polygons[p][0]
                if (!ring) continue
                var out = []
                for (var j = 0; j < ring.length; j++) out.push(point(ring[j][1], ring[j][0]))
                if (out.length > 2) rings.push(out)
            }
            if (rings.length) result.push({ code: String(f.properties && f.properties.code || "").toUpperCase(), rings: rings })
        }
        root.preparedCountries = result
        var dotsOut = []
        for (var d = 0; d < root.dots.length; d++) {
            var dot = root.dots[d]
            var xyz = point(dot.lat, dot.lon)
            dotsOut.push({ dot: dot, x: xyz.x, y: xyz.y, z: xyz.z, visible: false, sx: 0, sy: 0, depth: 0 })
        }
        root.preparedDots = dotsOut
        globe.requestPaint()
    }
    function project(v, cx, cy, r, sinLa, cosLa, sinLo, cosLo) {
        var horizontal = v.x * cosLo + v.y * sinLo
        return { x: cx + (v.y * cosLo - v.x * sinLo) * r,
                 y: cy - (cosLa * v.z - sinLa * horizontal) * r,
                 depth: sinLa * v.z + cosLa * horizontal }
    }
    function paintGrid(ctx, cx, cy, r, sinLa, cosLa, sinLo, cosLo) {
        ctx.strokeStyle = alpha(gridColor, 0.2)
        ctx.lineWidth = Math.max(0.6, Math.min(1.4, r / 450))
        for (var lat = -60; lat <= 60; lat += 30) {
            ctx.beginPath()
            var drawing = false
            for (var lon = -180; lon <= 180; lon += 4) {
                var q = project(point(lat, lon), cx, cy, r, sinLa, cosLa, sinLo, cosLo)
                if (q.depth < 0) { drawing = false; continue }
                if (!drawing) ctx.moveTo(q.x, q.y); else ctx.lineTo(q.x, q.y)
                drawing = true
            }
            ctx.stroke()
        }
        for (var mer = -150; mer <= 180; mer += 30) {
            ctx.beginPath(); var draw = false
            for (var la = -90; la <= 90; la += 4) {
                var m = project(point(la, mer), cx, cy, r, sinLa, cosLa, sinLo, cosLo)
                if (m.depth < 0) { draw = false; continue }
                if (!draw) ctx.moveTo(m.x, m.y); else ctx.lineTo(m.x, m.y)
                draw = true
            }
            ctx.stroke()
        }
    }
    function paintCountries(ctx, cx, cy, r, sinLa, cosLa, sinLo, cosLo) {
        for (var i = 0; i < preparedCountries.length; i++) {
            var country = preparedCountries[i]
            var active = country.code === String(activeCountryCode).toUpperCase()
            ctx.fillStyle = active ? alpha(dotColor, 0.32) : alpha(landColor, 0.92)
            ctx.strokeStyle = active ? alpha(dotColor, 0.9) : alpha(outlineColor, 0.28)
            ctx.lineWidth = active ? 1.3 : 0.55
            for (var j = 0; j < country.rings.length; j++) {
                var ring = country.rings[j]
                ctx.beginPath(); var drawing = false
                for (var k = 0; k < ring.length; k++) {
                    var q = project(ring[k], cx, cy, r, sinLa, cosLa, sinLo, cosLo)
                    if (q.depth < -0.08) { drawing = false; continue }
                    if (!drawing) ctx.moveTo(q.x, q.y); else ctx.lineTo(q.x, q.y)
                    drawing = true
                }
                ctx.closePath(); ctx.fill(); ctx.stroke()
            }
        }
    }
    function paintDots(ctx, cx, cy, r, sinLa, cosLa, sinLo, cosLo) {
        var max = 1
        for (var i = 0; i < preparedDots.length; i++) max = Math.max(max, Number(preparedDots[i].dot.count) || 0)
        for (var d = 0; d < preparedDots.length; d++) {
            var row = preparedDots[d]
            var q = project(row, cx, cy, r, sinLa, cosLa, sinLo, cosLo)
            row.visible = q.depth >= 0
            if (!row.visible) continue
            row.sx = q.x; row.sy = q.y; row.depth = q.depth
            var share = Math.sqrt((Number(row.dot.count) || 0) / max)
            var rr = 3 + share * 7
            ctx.beginPath(); ctx.arc(q.x, q.y, rr + 5, 0, Math.PI * 2)
            ctx.fillStyle = alpha(dotColor, 0.12 + share * 0.12); ctx.fill()
            ctx.beginPath(); ctx.arc(q.x, q.y, rr, 0, Math.PI * 2)
            ctx.fillStyle = alpha(dotColor, 0.66 + q.depth * 0.32); ctx.fill()
            if (hoveredDot && hoveredDot.code === row.dot.code) {
                ctx.beginPath(); ctx.arc(q.x, q.y, rr + 4, 0, Math.PI * 2)
                ctx.strokeStyle = alpha(dotColor, 0.95); ctx.lineWidth = 1.5; ctx.stroke()
            }
        }
    }
    function paintGlobe(ctx) {
        var cx = globe.width / 2, cy = globe.height / 2, r = radius()
        if (r <= 0) return
        ctx.reset(); ctx.fillStyle = backgroundColor; ctx.fillRect(0, 0, globe.width, globe.height)
        var gradient = ctx.createRadialGradient(cx - r * 0.28, cy - r * 0.34, r * 0.05, cx, cy, r)
        gradient.addColorStop(0, Qt.lighter(sphereColor, 1.45)); gradient.addColorStop(0.62, sphereColor); gradient.addColorStop(1, Qt.darker(sphereColor, 1.7))
        ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.fillStyle = gradient; ctx.fill()
        var la = centreLatitude * Math.PI / 180, lo = centreLongitude * Math.PI / 180
        var sinLa = Math.sin(la), cosLa = Math.cos(la), sinLo = Math.sin(lo), cosLo = Math.cos(lo)
        ctx.save(); ctx.beginPath(); ctx.arc(cx, cy, r - 0.5, 0, Math.PI * 2); ctx.clip()
        paintGrid(ctx, cx, cy, r, sinLa, cosLa, sinLo, cosLo)
        paintCountries(ctx, cx, cy, r, sinLa, cosLa, sinLo, cosLo)
        paintDots(ctx, cx, cy, r, sinLa, cosLa, sinLo, cosLo)
        ctx.restore()
        ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.strokeStyle = alpha(outlineColor, 0.6); ctx.lineWidth = 1.2; ctx.stroke()
    }
    function dotAt(x, y) {
        var nearest = null, distance = 22 * 22
        for (var i = 0; i < preparedDots.length; i++) {
            var row = preparedDots[i]
            if (!row.visible) continue
            var dx = row.sx - x, dy = row.sy - y, ds = dx * dx + dy * dy
            if (ds < distance) { distance = ds; nearest = row.dot }
        }
        return nearest
    }
    onCountriesChanged: prepare()
    onDotsChanged: prepare()
    onCentreLatitudeChanged: globe.requestPaint()
    onCentreLongitudeChanged: globe.requestPaint()
    onGlobeScaleChanged: globe.requestPaint()
    onWidthChanged: globe.requestPaint()
    onHeightChanged: globe.requestPaint()
    onHoveredDotChanged: globe.requestPaint()

    Canvas {
        id: globe
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative
        onPaint: { var ctx = getContext("2d"); if (ctx) root.paintGlobe(ctx) }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        property real lastX: 0
        property real lastY: 0
        property real moved: 0
        cursorShape: pressed ? Qt.ClosedHandCursor : (root.hoveredDot ? Qt.PointingHandCursor : Qt.OpenHandCursor)
        onPressed: function(e) { lastX = e.x; lastY = e.y; moved = 0; root.hoveredDot = null }
        onPositionChanged: function(e) {
            root.hoverX = e.x; root.hoverY = e.y
            if (pressed) {
                var dx = e.x - lastX, dy = e.y - lastY
                root.centreLongitude = root.wrap(root.centreLongitude - dx * 0.28 / root.globeScale)
                root.centreLatitude = root.clamp(root.centreLatitude + dy * 0.22 / root.globeScale, -78, 78)
                moved += Math.abs(dx) + Math.abs(dy); lastX = e.x; lastY = e.y
            } else root.hoveredDot = root.dotAt(e.x, e.y)
        }
        onExited: if (!pressed) root.hoveredDot = null
        onWheel: function(e) { root.globeScale = root.clamp(root.globeScale * Math.exp(e.angleDelta.y / 720), root.minimumScale, root.maximumScale); e.accepted = true }
    }

    Rectangle {
        visible: !!root.hoveredDot && !mouse.pressed
        x: Math.min(width - implicitWidth - 12, Math.max(12, root.hoverX + 14))
        y: Math.min(height - implicitHeight - 12, Math.max(12, root.hoverY + 14))
        width: tooltipText.implicitWidth + 20
        height: tooltipText.implicitHeight + 14
        color: alpha(root.backgroundColor, 0.94)
        border.color: alpha(root.outlineColor, 0.55)
        border.width: 1
        radius: 4
        Text {
            id: tooltipText
            anchors.centerIn: parent
            text: root.hoveredDot ? root.flag(root.hoveredDot.code) + "  " + root.hoveredDot.name + " \u2014 " + root.hoveredDot.count + " user" + (root.hoveredDot.count === 1 ? "" : "s") : ""
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: 12
        }
    }

    Component.onCompleted: prepare()
}
