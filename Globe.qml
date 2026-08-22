import QtQuick

// Fixed equirectangular world map. It intentionally has no pan or zoom:
// every continent and every country dot remains visible at once.
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
    property color outlineColor: borderColor
    property color textColor: "#f3f4f5"
    property string fontFamily: "monospace"
    property var hoveredDot: null
    property real hoverX: 0
    property real hoverY: 0
    property var preparedCountries: []
    property var preparedDots: []

    readonly property real mapWidth: Math.min(canvas.width, canvas.height * 2)
    readonly property real mapHeight: mapWidth / 2
    readonly property real mapLeft: (canvas.width - mapWidth) / 2
    readonly property real mapTop: (canvas.height - mapHeight) / 2

    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

    function flag(code) {
        if (!code || String(code).length !== 2) return ""
        var a = String(code).charCodeAt(0), b = String(code).charCodeAt(1)
        if (a < 65 || a > 90 || b < 65 || b > 90) return ""
        return String.fromCodePoint(0x1f1e6 + a - 65) + String.fromCodePoint(0x1f1e6 + b - 65)
    }

    function project(lon, lat) {
        return { x: root.mapLeft + (Number(lon) + 180) / 360 * root.mapWidth,
                 y: root.mapTop + (90 - Number(lat)) / 180 * root.mapHeight }
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
                for (var j = 0; j < ring.length; j++) points.push(project(ring[j][0], ring[j][1]))
                if (points.length > 2) rings.push(points)
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
            var point = project(dot.lon, dot.lat)
            nextDots.push({ dot: dot, x: point.x, y: point.y })
        }
        root.preparedDots = nextDots
        canvas.requestPaint()
    }

    function drawGrid(ctx) {
        ctx.strokeStyle = alpha(root.gridColor, 0.2)
        ctx.lineWidth = 1
        for (var lon = -150; lon <= 180; lon += 30) {
            var x = project(lon, 0).x
            ctx.beginPath(); ctx.moveTo(x, root.mapTop); ctx.lineTo(x, root.mapTop + root.mapHeight); ctx.stroke()
        }
        for (var lat = -60; lat <= 60; lat += 30) {
            var y = project(0, lat).y
            ctx.beginPath(); ctx.moveTo(root.mapLeft, y); ctx.lineTo(root.mapLeft + root.mapWidth, y); ctx.stroke()
        }
    }

    function drawCountries(ctx) {
        for (var i = 0; i < preparedCountries.length; i++) {
            var country = preparedCountries[i]
            var active = country.code === String(root.activeCountryCode).toUpperCase()
            ctx.fillStyle = active ? alpha(root.dotColor, 0.3) : alpha(root.landColor, 0.9)
            ctx.strokeStyle = active ? alpha(root.dotColor, 0.95) : alpha(root.borderColor, 0.55)
            ctx.lineWidth = active ? 1.5 : 0.7
            for (var r = 0; r < country.rings.length; r++) {
                var ring = country.rings[r]
                ctx.beginPath()
                for (var p = 0; p < ring.length; p++) {
                    if (p === 0) ctx.moveTo(ring[p].x, ring[p].y)
                    else ctx.lineTo(ring[p].x, ring[p].y)
                }
                ctx.closePath(); ctx.fill(); ctx.stroke()
            }
        }
    }

    function drawDots(ctx) {
        var maxCount = 1
        for (var i = 0; i < preparedDots.length; i++) maxCount = Math.max(maxCount, Number(preparedDots[i].dot.count) || 0)
        for (var d = 0; d < preparedDots.length; d++) {
            var row = preparedDots[d]
            var share = Math.sqrt((Number(row.dot.count) || 0) / maxCount)
            var radius = 1.6 + share * 1.8
            ctx.beginPath(); ctx.arc(row.x, row.y, radius + 2.5, 0, Math.PI * 2)
            ctx.fillStyle = alpha(root.dotColor, 0.14); ctx.fill()
            ctx.beginPath(); ctx.arc(row.x, row.y, radius, 0, Math.PI * 2)
            ctx.fillStyle = root.dotColor; ctx.fill()
            if (root.hoveredDot && root.hoveredDot.code === row.dot.code) {
                ctx.beginPath(); ctx.arc(row.x, row.y, radius + 3, 0, Math.PI * 2)
                ctx.strokeStyle = root.dotColor; ctx.lineWidth = 1.4; ctx.stroke()
            }
        }
    }

    function drawMap(ctx) {
        ctx.reset()
        ctx.fillStyle = root.backgroundColor
        ctx.fillRect(0, 0, canvas.width, canvas.height)
        drawGrid(ctx)
        drawCountries(ctx)
        drawDots(ctx)
    }

    function dotAt(x, y) {
        var nearest = null, distance = 28 * 28
        for (var i = 0; i < preparedDots.length; i++) {
            var row = preparedDots[i]
            var dx = row.x - x, dy = row.y - y, current = dx * dx + dy * dy
            if (current < distance) { distance = current; nearest = row.dot }
        }
        return nearest
    }

    onCountriesChanged: root.prepare()
    onDotsChanged: root.prepare()
    onWidthChanged: canvas.requestPaint()
    onHeightChanged: canvas.requestPaint()
    onHoveredDotChanged: canvas.requestPaint()

    Canvas {
        id: canvas
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative
        onPaint: { var ctx = getContext("2d"); if (ctx) root.drawMap(ctx) }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onPositionChanged: function(event) {
            root.hoverX = event.x
            root.hoverY = event.y
            root.hoveredDot = root.dotAt(event.x, event.y)
        }
        onExited: root.hoveredDot = null
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
