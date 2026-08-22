import QtQuick

// Equirectangular world map with drag-to-pan and wheel-to-zoom.
// Horizontal panning wraps seamlessly; vertical panning is clamped.
Item {
    id: root

    property var countries: []
    property var dots: []
    property string activeCountryCode: ""
    property color backgroundColor: "#0b111b"
    property color landColor: "#3c516b"
    property color borderColor: "#748aa4"
    property color gridColor: "#6e849d"
    property color dotColor: "#ff8a3d"
    property color myColor: "#ff3b30"
    property color otherColor: "#4ea1ff"
    property color outlineColor: borderColor
    property color textColor: "#f3f4f5"
    property string fontFamily: "monospace"
    property var hoveredDot: null
    property real hoverX: 0
    property real hoverY: 0
    property var preparedCountries: []
    property var preparedDots: []
    property string myCountryCode: ""

    property real zoom: 1.0
    property real panX: 0.0
    property real panY: 0.0
    property bool pinching: false
    readonly property real maxZoom: 8.0

    readonly property real mapWidth: Math.max(canvas.width, canvas.height * 2)
    readonly property real mapHeight: mapWidth / 2
    readonly property real mapLeft: (canvas.width - mapWidth) / 2
    readonly property real mapTop: (canvas.height - mapHeight) / 2

    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

    function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

    function flag(code) {
        if (!code || String(code).length !== 2) return ""
        var a = String(code).charCodeAt(0), b = String(code).charCodeAt(1)
        if (a < 65 || a > 90 || b < 65 || b > 90) return ""
        return String.fromCodePoint(0x1f1e6 + a - 65) + String.fromCodePoint(0x1f1e6 + b - 65)
    }

    function baseProject(lon, lat) {
        return { x: root.mapLeft + (Number(lon) + 180) / 360 * root.mapWidth,
                 y: root.mapTop + (90 - Number(lat)) / 180 * root.mapHeight }
    }

    function toScreen(bx, by) {
        var cx = canvas.width / 2, cy = canvas.height / 2
        return { x: cx + root.panX + (bx - cx) * root.zoom,
                 y: cy + root.panY + (by - cy) * root.zoom }
    }

    function project(lon, lat) {
        var b = baseProject(lon, lat)
        return toScreen(b.x, b.y)
    }

    function clampPan() {
        var W = root.mapWidth, H = root.mapHeight
        var maxX = Math.max(0, (W * root.zoom - canvas.width) / 2)
        var maxY = Math.max(0, (H * root.zoom - canvas.height) / 2)
        root.panX = clamp(root.panX, -maxX, maxX)
        root.panY = clamp(root.panY, -maxY, maxY)
    }

    function zoomAt(factor, mx, my) {
        var cx = canvas.width / 2, cy = canvas.height / 2
        if (!isFinite(mx) || !isFinite(my)) { mx = cx; my = cy }
        var newZoom = clamp(root.zoom * factor, 1, root.maxZoom)
        if (newZoom === root.zoom) return
        var k = newZoom / root.zoom
        root.panX = (mx - cx) - k * ((mx - cx) - root.panX)
        root.panY = (my - cy) - k * ((my - cy) - root.panY)
        root.zoom = newZoom
        clampPan()
        canvas.requestPaint()
    }

    function resetView() {
        root.zoom = 1.0
        root.panX = 0.0
        root.panY = 0.0
        canvas.requestPaint()
    }

    function prepare() {
        var nextCountries = []
        for (var i = 0; i < root.countries.length; i++) {
            var feature = root.countries[i]
            if (!feature || !feature.geometry) continue
            var polygons = feature.geometry.type === "Polygon"
                ? [feature.geometry.coordinates]
                : feature.geometry.coordinates
            var rings = []
            for (var p = 0; p < polygons.length; p++) {
                var ring = polygons[p] && polygons[p][0]
                if (!ring) continue
                var points = []
                var minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
                for (var j = 0; j < ring.length; j++) {
                    var pt = baseProject(ring[j][0], ring[j][1])
                    points.push(pt)
                    if (pt.x < minX) minX = pt.x
                    if (pt.x > maxX) maxX = pt.x
                    if (pt.y < minY) minY = pt.y
                    if (pt.y > maxY) maxY = pt.y
                }
                if (points.length > 2) rings.push({ points: points, bbox: { minX: minX, maxX: maxX, minY: minY, maxY: maxY } })
            }
            if (rings.length) nextCountries.push({
                code: String(feature.properties && feature.properties.code || "").toUpperCase(),
                rings: rings
            })
        }
        root.preparedCountries = nextCountries

        var nextDots = []
        for (var d = 0; d < root.dots.length; d++) {
            var dot = root.dots[d]
            var point = baseProject(dot.lon, dot.lat)
            nextDots.push({ dot: dot, x: point.x, y: point.y })
        }
        root.preparedDots = nextDots
        canvas.requestPaint()
    }

    function screenBBox(b, off) {
        var cx = canvas.width / 2, cy = canvas.height / 2
        var x0 = cx + root.panX + ((b.minX + off) - cx) * root.zoom
        var x1 = cx + root.panX + ((b.maxX + off) - cx) * root.zoom
        var y0 = cy + root.panY + (b.minY - cy) * root.zoom
        var y1 = cy + root.panY + (b.maxY - cy) * root.zoom
        return { minX: Math.min(x0, x1), maxX: Math.max(x0, x1),
                 minY: Math.min(y0, y1), maxY: Math.max(y0, y1) }
    }

    function isVisible(b, off) {
        var s = screenBBox(b, off)
        return s.maxX >= -2 && s.minX <= canvas.width + 2 && s.maxY >= -2 && s.minY <= canvas.height + 2
    }

    function drawGrid(ctx) {
        ctx.strokeStyle = alpha(root.gridColor, 0.2)
        ctx.lineWidth = 1 / root.zoom
        var W = root.mapWidth, H = root.mapHeight
        var offsets = [0, -W, W]
        for (var lon = -150; lon <= 180; lon += 30) {
            for (var o = 0; o < offsets.length; o++) {
                var x = root.mapLeft + (lon + 180) / 360 * W + offsets[o]
                ctx.beginPath(); ctx.moveTo(x, root.mapTop); ctx.lineTo(x, root.mapTop + H); ctx.stroke()
            }
        }
        for (var lat = -60; lat <= 60; lat += 30) {
            var y = root.mapTop + (90 - lat) / 180 * H
            ctx.beginPath(); ctx.moveTo(root.mapLeft, y); ctx.lineTo(root.mapLeft + W, y); ctx.stroke()
        }
    }

    function drawCountries(ctx) {
        var W = root.mapWidth
        var offsets = [0, -W, W]
        // No country highlight - all land same color, dots show users
        ctx.fillStyle = alpha(root.landColor, 0.9)
        ctx.strokeStyle = alpha(root.borderColor, 0.55)
        ctx.lineWidth = 0.7 / root.zoom
        for (var i = 0; i < preparedCountries.length; i++) {
            var country = preparedCountries[i]
            for (var r = 0; r < country.rings.length; r++) {
                var ring = country.rings[r]
                for (var o = 0; o < offsets.length; o++) {
                    var off = offsets[o]
                    if (!isVisible(ring.bbox, off)) continue
                    ctx.beginPath()
                    var pts = ring.points
                    for (var p = 0; p < pts.length; p++) {
                        var px = pts[p].x + off, py = pts[p].y
                        if (p === 0) ctx.moveTo(px, py)
                        else ctx.lineTo(px, py)
                    }
                    ctx.closePath(); ctx.fill(); ctx.stroke()
                }
            }
        }
    }

    function drawDots(ctx) {
        var maxCount = 1
        for (var i = 0; i < preparedDots.length; i++) maxCount = Math.max(maxCount, Number(preparedDots[i].dot.count) || 0)
        var W = root.mapWidth
        var offsets = [0, -W, W]
        for (var d = 0; d < preparedDots.length; d++) {
            var row = preparedDots[d]
            var share = Math.sqrt((Number(row.dot.count) || 0) / maxCount)
            var mine = String(row.dot.code).toUpperCase() === String(root.myCountryCode).toUpperCase()
            var base = mine ? root.myColor : root.otherColor
            var radius = 1.6 + share * 1.8
            if (mine) radius += 1.2
            var isHover = root.hoveredDot && root.hoveredDot.code === row.dot.code
            for (var o = 0; o < offsets.length; o++) {
                var s = toScreen(row.x + offsets[o], row.y)
                if (s.x < -20 || s.x > canvas.width + 20 || s.y < -20 || s.y > canvas.height + 20) continue
                // Strong glow for all dots - visible even at low zoom
                ctx.shadowColor = base
                ctx.shadowBlur = 14
                ctx.beginPath(); ctx.arc(s.x, s.y, radius, 0, Math.PI * 2)
                ctx.fillStyle = base; ctx.fill()
                ctx.shadowBlur = 0
                // Outer halo - twice the radius, high alpha for visibility
                ctx.beginPath(); ctx.arc(s.x, s.y, radius + 8, 0, Math.PI * 2)
                ctx.fillStyle = alpha(base, 0.18); ctx.fill()
                ctx.beginPath(); ctx.arc(s.x, s.y, radius + 4.5, 0, Math.PI * 2)
                ctx.fillStyle = alpha(base, 0.32); ctx.fill()
                ctx.beginPath(); ctx.arc(s.x, s.y, radius, 0, Math.PI * 2)
                ctx.fillStyle = base; ctx.fill()
                // Ring - always visible, stronger on hover/mine
                if (isHover || mine) {
                    ctx.beginPath(); ctx.arc(s.x, s.y, radius + 3.5, 0, Math.PI * 2)
                    ctx.strokeStyle = alpha(base, 1.0); ctx.lineWidth = 1.6; ctx.stroke()
                } else {
                    ctx.beginPath(); ctx.arc(s.x, s.y, radius + 2.5, 0, Math.PI * 2)
                    ctx.strokeStyle = alpha(base, 0.55); ctx.lineWidth = 1.0; ctx.stroke()
                }
            }
        }
    }

    function drawMap(ctx) {
        ctx.reset()
        ctx.fillStyle = root.backgroundColor
        ctx.fillRect(0, 0, canvas.width, canvas.height)
        ctx.save()
        var cx = canvas.width / 2, cy = canvas.height / 2
        ctx.translate(cx + root.panX, cy + root.panY)
        ctx.scale(root.zoom, root.zoom)
        ctx.translate(-cx, -cy)
        drawGrid(ctx)
        drawCountries(ctx)
        ctx.restore()
        drawDots(ctx)
    }

    function dotAt(x, y) {
        var nearest = null, distance = 28 * 28
        var W = root.mapWidth
        var offsets = [0, -W, W]
        for (var i = 0; i < preparedDots.length; i++) {
            var row = preparedDots[i]
            for (var o = 0; o < offsets.length; o++) {
                var s = toScreen(row.x + offsets[o], row.y)
                var dx = s.x - x, dy = s.y - y, current = dx * dx + dy * dy
                if (current < distance) { distance = current; nearest = row.dot }
            }
        }
        return nearest
    }

    onCountriesChanged: root.prepare()
    onDotsChanged: root.prepare()
    onWidthChanged: root.prepare()
    onHeightChanged: root.prepare()
    onZoomChanged: clampPan()
    onHoveredDotChanged: canvas.requestPaint()
    // Recolor without waiting for any other repaint trigger
    onMyCountryCodeChanged: canvas.requestPaint()

    Canvas {
        id: canvas
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative
        onPaint: { var ctx = getContext("2d"); if (ctx) root.drawMap(ctx) }
    }

    PinchArea {
        id: pinchArea
        anchors.fill: parent
        property real lastScale: 1.0
        property real lastCx: 0
        property real lastCy: 0

        onPinchStarted: function(event) {
            root.pinching = true
            if (ma) ma.dragging = false
            lastScale = pinch.scale
            lastCx = pinch.center.x
            lastCy = pinch.center.y
        }
        onPinchUpdated: function(event) {
            var factor = pinch.scale / lastScale
            root.zoomAt(factor, pinch.center.x, pinch.center.y)
            lastScale = pinch.scale
            lastCx = pinch.center.x; lastCy = pinch.center.y
            root.hoveredDot = root.dotAt(pinch.center.x, pinch.center.y)
        }
        onPinchFinished: function(event) { root.pinching = false }

        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton
            property real lastX: 0
            property real lastY: 0
            property bool dragging: false
            property real moved: 0

            onPressed: function(event) {
                if (root.pinching) return
                lastX = event.x; lastY = event.y; dragging = true; moved = 0
            }
            onPositionChanged: function(event) {
                if (dragging && !root.pinching) {
                    var dx = event.x - lastX, dy = event.y - lastY
                    lastX = event.x; lastY = event.y
                    moved += Math.abs(dx) + Math.abs(dy)
                    root.panX += dx; root.panY += dy
                    clampPan()
                    canvas.requestPaint()
                }
                root.hoverX = event.x
                root.hoverY = event.y
                root.hoveredDot = root.dotAt(event.x, event.y)
            }
            onReleased: dragging = false
            onCanceled: dragging = false
            onExited: { root.hoveredDot = null; dragging = false }
            onWheel: function(event) {
                // Use the actual cursor position (ma tracks hover). event.x/position
                // can be stale or reported as canvas center in some Qt builds,
                // which caused zoom to always anchor at Africa (0,0).
                var mx = ma.mouseX
                var my = ma.mouseY
                // Also fallback to event position if ma not yet updated
                if (!isFinite(mx) || !isFinite(my)) {
                    mx = event.position !== undefined && event.position.x !== undefined ? event.position.x : event.x
                    my = event.position !== undefined && event.position.y !== undefined ? event.position.y : event.y
                }
                if (!isFinite(mx) || !isFinite(my)) { mx = canvas.width/2; my = canvas.height/2 }
                var dy = event.pixelDelta && event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y
                var factor = dy > 0 ? 1.08 : 1 / 1.08
                zoomAt(factor, mx, my)
                root.hoveredDot = root.dotAt(mx, my)
                event.accepted = true
            }
            onDoubleClicked: root.resetView()
        }
    }

    Rectangle {
        visible: !!root.hoveredDot
        x: Math.min(root.width - width - 10, Math.max(10, root.hoverX + 14))
        y: Math.min(root.height - height - 10, Math.max(10, root.hoverY + 14))
        width: tooltipText.implicitWidth + 18
        height: tooltipText.implicitHeight + 12
        color: alpha(root.backgroundColor, 0.96)
        border.color: alpha(root.borderColor, 0.8)
        border.width: 1
        radius: 4
        Text {
            id: tooltipText
            anchors.centerIn: parent
            text: root.hoveredDot ? root.flag(root.hoveredDot.code) + "  " + root.hoveredDot.name + " - " + root.hoveredDot.count + " user" + (root.hoveredDot.count === 1 ? "" : "s") : ""
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: 12
        }
    }

    Component.onCompleted: root.prepare()
}
