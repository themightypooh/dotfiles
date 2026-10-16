// A surface made of square dots with real physics: every dot is a mass on a spring
// back to its home spot, coupled to its four neighbours like a membrane, so pushes
// travel outward as ripples and settle. The pointer plows through the dots (and drags
// them along in its wake); shock() knocks a ring of them outward.
//
// The simulation runs on a coarse grid in JS, writes each dot's offset into a tiny
// texture, and shaders/dots.frag draws the dots on the GPU. It sleeps when everything
// is still, so an idle bar costs nothing.
import QtQuick

Item {
    id: s

    // shape: the bar strip (everything below barTop) smoothly merged with a box
    property real barTop: 1e5
    property vector4d box: Qt.vector4d(0, 0, 0, 0)    // left, top, right, bottom
    property real corner: 0
    property real fillet: 0

    property point pointer
    property bool hovered: false

    property color dotColor
    property color litColor
    property color backing
    property color gradA: "#f07f77dd"
    property color gradB: "#f01d9e75"
    property color grainM: "#ffff4fd8"
    property color grainC: "#ff35e6ff"
    property color grainY: "#ffffe04a"

    property real flow: 1.8            // idle drift in px (0 = still)
    property real loose: 9             // ragged edge width in px (0 = hard edge)
    property real wave: 1              // how wavy the top edge is (0 = flat)
    property real mouseX: width / 2
    property real mouseY: height
    property real hov: 0
    property real time: 0
    // The idle flow is pure GPU work; this just advances the clock. Idle, a plain timer does it at
    // idleFps (each tick redraws the bar and re-floats every icon; the drift moves well under a pixel
    // per tick, so 20fps looks the same as 60). A FrameAnimation would keep the whole render loop
    // spinning at the screen's rate even when nothing else changed, so that's only used while the
    // pointer is on the bar and the swell needs to be smooth.
    // paused (nobody's looking: you're away, or a fullscreen window covers this screen) stops the
    // clock altogether, so the bar costs nothing until it's visible again.
    property bool paused: false
    property real idleFps: 20
    readonly property bool animating: s.visible && !s.paused && (s.flow > 0 || s.wave > 0)
    readonly property bool fast: s.hovered || s.hov > 0.01 || s.gooLive > 0
    function advance(dt) {
        dt = Math.min(dt, 0.05)
        s.time += dt
        s.hov += ((s.hovered ? 1 : 0) - s.hov) * Math.min(1, dt * 6)
        const lastX = s.mouseX
        if (s.hovered) { s.mouseX += (s.pointer.x - s.mouseX) * Math.min(1, dt * 12); s.mouseY += (s.pointer.y - s.mouseY) * Math.min(1, dt * 12) }
        // no pointer and no blobs left: nothing to do (rebuilding the blob uniforms every idle tick
        // was half of the bar's idle CPU)
        if (s.hovered || s.gooLive > 0) s.stepGoo(dt, Math.abs(s.mouseX - lastX) / dt)
        else s.gooAcc = 0.95
    }

    // ---- goo blobs: born where the pointer is, then on their own ----------------------------
    // While the pointer is on the bar, blobs of goo swell up out of the surface above it, pinch off and
    // float away. Each is born at the pointer's spot at that moment and stays there, so they react to
    // you instead of following you; moving makes them come faster and bigger, leaving a trail.
    readonly property real gooLife: 4.5          // seconds from swelling up to gone
    property var gooBlobs: []                    // {x, t, size, seed}
    property real gooAcc: 0
    property vector4d blob0: Qt.vector4d(0, -1, 0, 0)   // x, birth time (-1 = none), size, seed
    property vector4d blob1: Qt.vector4d(0, -1, 0, 0)
    property vector4d blob2: Qt.vector4d(0, -1, 0, 0)
    property vector4d blob3: Qt.vector4d(0, -1, 0, 0)
    property real gooLive: 0
    function stepGoo(dt, speed) {
        let list = s.gooBlobs.filter(b => s.time - b.t < s.gooLife)
        if (s.hovered) {
            // a slow steady trickle while resting; much quicker while moving
            s.gooAcc += dt * (0.5 + Math.min(speed / 250, 2.5))
            if (s.gooAcc >= 1) {
                s.gooAcc = 0
                const r = Math.random()
                list.push({ x: s.pointer.x, t: s.time,
                            size: 0.75 + 0.25 * Math.random() + Math.min(speed / 900, 0.3), seed: r * 100 })
                if (list.length > 4) list.shift()
            }
        } else s.gooAcc = 0.95                 // the first one comes right away when you arrive
        s.gooBlobs = list
        const v = i => list[i] ? Qt.vector4d(list[i].x, list[i].t, list[i].size, list[i].seed) : Qt.vector4d(0, -1, 0, 0)
        s.blob0 = v(0); s.blob1 = v(1); s.blob2 = v(2); s.blob3 = v(3)
        s.gooLive = list.length ? 1 : 0
    }
    FrameAnimation { running: s.animating && s.fast; onTriggered: s.advance(frameTime) }
    Timer { interval: 1000 / s.idleFps; repeat: true; running: s.animating && !s.fast; onTriggered: s.advance(interval / 1000) }

    property real cell: 2.6            // grain spacing (render)
    property real simCell: 6           // physics grid spacing
    property real dotSize: 1.6

    // feel
    property real homeSpring: 110     // pull back to rest
    property real neighbourSpring: 240 // membrane coupling (makes ripples travel)
    property real damping: 6.5
    property real pushRadius: 46
    property real pushStrength: 2600
    property real wake: 0.55           // how much the pointer drags dots along

    readonly property int cols: Math.max(1, Math.ceil(width / simCell))
    readonly property int rows: Math.max(1, Math.ceil(height / simCell))
    readonly property real maxOffset: simCell * 1.9

    property var ox: new Float32Array(1)
    property var oy: new Float32Array(1)
    property var vx: new Float32Array(1)
    property var vy: new Float32Array(1)
    property bool awake: false
    property real lastPx: 0
    property real lastPy: 0
    property bool hadPointer: false

    function alloc() {
        const n = cols * rows
        ox = new Float32Array(n); oy = new Float32Array(n)
        vx = new Float32Array(n); vy = new Float32Array(n)
        disp.requestPaint()
    }
    onColsChanged: alloc()
    onRowsChanged: alloc()
    Component.onCompleted: alloc()

    function debugCanvas() { return JSON.stringify({ available: disp.available, w: disp.width, h: disp.height, painted: disp.paints }) }

    // same as waveTop() - rest in dots.frag (front layer): how far the wave lifts things at x
    function waveLift(x) {
        if (wave <= 0) return 0
        const t = time
        const roll = Math.sin(x / 130 + t * 0.6) * 5.5 + Math.sin(x / 61 - t * 0.9) * 2.4
        return -wave * roll
    }

    // knock dots outward from (x, y)
    function shock(x, y, strength) {
        const R = 170
        const c0 = Math.max(0, Math.floor((x - R) / simCell)), c1 = Math.min(cols - 1, Math.ceil((x + R) / simCell))
        const r0 = Math.max(0, Math.floor((y - R) / simCell)), r1 = Math.min(rows - 1, Math.ceil((y + R) / simCell))
        for (let r = r0; r <= r1; r++) for (let c = c0; c <= c1; c++) {
            const hx = (c + 0.5) * simCell - x, hy = (r + 0.5) * simCell - y
            const d = Math.sqrt(hx * hx + hy * hy) + 0.001
            if (d > R) continue
            const f = strength * (1 - d / R)
            const i = r * cols + c
            vx[i] += hx / d * f; vy[i] += hy / d * f
        }
        awake = true
    }

    function step(dt) {
        const C = cols, Rn = rows, n = C * Rn
        const X = ox, Y = oy, VX = vx, VY = vy
        const kh = homeSpring, kn = neighbourSpring, damp = damping

        // pointer: shove dots out of the way and drag them along with the motion
        // (particles ride the wave, so map the pointer back into their flat grid)
        if (hovered) {
            const px = pointer.x, py = pointer.y - waveLift(pointer.x)
            const pvx = hadPointer ? (px - lastPx) / dt : 0, pvy = hadPointer ? (py - lastPy) / dt : 0
            lastPx = px; lastPy = py; hadPointer = true
            const R = pushRadius
            const c0 = Math.max(0, Math.floor((px - R) / simCell) - 1), c1 = Math.min(C - 1, Math.ceil((px + R) / simCell) + 1)
            const r0 = Math.max(0, Math.floor((py - R) / simCell) - 1), r1 = Math.min(Rn - 1, Math.ceil((py + R) / simCell) + 1)
            for (let r = r0; r <= r1; r++) for (let c = c0; c <= c1; c++) {
                const i = r * C + c
                const dx = (c + 0.5) * simCell + X[i] - px, dy = (r + 0.5) * simCell + Y[i] - py
                const d = Math.sqrt(dx * dx + dy * dy) + 0.001
                if (d > R) continue
                const fall = 1 - d / R
                const f = pushStrength * fall * fall * dt
                VX[i] += dx / d * f + pvx * wake * fall * dt * 6
                VY[i] += dy / d * f + pvy * wake * fall * dt * 6
            }
        } else hadPointer = false

        // springs: home + 4-neighbour membrane, then damping (semi-implicit Euler)
        let energy = 0
        for (let r = 0; r < Rn; r++) {
            const row = r * C
            for (let c = 0; c < C; c++) {
                const i = row + c
                const xl = c > 0 ? X[i - 1] : X[i], xr = c < C - 1 ? X[i + 1] : X[i]
                const xu = r > 0 ? X[i - C] : X[i], xd = r < Rn - 1 ? X[i + C] : X[i]
                const yl = c > 0 ? Y[i - 1] : Y[i], yr = c < C - 1 ? Y[i + 1] : Y[i]
                const yu = r > 0 ? Y[i - C] : Y[i], yd = r < Rn - 1 ? Y[i + C] : Y[i]
                const ax = -kh * X[i] + kn * ((xl + xr + xu + xd) * 0.25 - X[i]) - damp * VX[i]
                const ay = -kh * Y[i] + kn * ((yl + yr + yu + yd) * 0.25 - Y[i]) - damp * VY[i]
                VX[i] += ax * dt; VY[i] += ay * dt
                energy += Math.abs(VX[i]) + Math.abs(VY[i])
            }
        }
        const m = maxOffset
        for (let i = 0; i < n; i++) {
            let x = X[i] + VX[i] * dt, y = Y[i] + VY[i] * dt
            if (x > m) { x = m; VX[i] *= -0.3 } else if (x < -m) { x = -m; VX[i] *= -0.3 }
            if (y > m) { y = m; VY[i] *= -0.3 } else if (y < -m) { y = -m; VY[i] *= -0.3 }
            X[i] = x; Y[i] = y
            energy += Math.abs(x) + Math.abs(y)
        }

        // go to sleep once everything has settled
        if (!hovered && energy / n < 0.004) {
            X.fill(0); Y.fill(0); VX.fill(0); VY.fill(0)
            awake = false
        } else awake = true
        disp.requestPaint()
    }

    // full rate while the pointer is on it, 30fps for ripples settling on their own
    property real acc: 0
    FrameAnimation {
        running: s.awake || s.hovered
        onTriggered: {
            s.acc += frameTime
            if (!s.hovered && s.acc < 1 / 31) return
            s.step(Math.min(s.acc, 1 / 25))
            s.acc = 0
        }
    }

    // offsets -> texture: R = x, G = y (128 = rest, 8 per px), B = speed
    Canvas {
        id: disp
        width: s.cols; height: s.rows
        renderTarget: Canvas.Image
        renderStrategy: Canvas.Immediate
        property var img: null
        onAvailableChanged: if (available) requestPaint()
        onWidthChanged: requestPaint()
        property int paints: 0
        onPaint: {
            paints++
            const ctx = getContext("2d")
            if (!img || img.width !== s.cols || img.height !== s.rows) img = ctx.createImageData(s.cols, s.rows)
            const d = img.data, X = s.ox, Y = s.oy, VX = s.vx, VY = s.vy
            for (let i = 0, j = 0; i < X.length; i++, j += 4) {
                d[j] = Math.max(0, Math.min(255, 128 + X[i] * 8))
                d[j + 1] = Math.max(0, Math.min(255, 128 + Y[i] * 8))
                d[j + 2] = Math.min(255, (Math.abs(VX[i]) + Math.abs(VY[i])) * 0.9)
                d[j + 3] = 255
            }
            ctx.putImageData(img, 0, 0)
        }
    }
    ShaderEffectSource {
        id: dispTex
        sourceItem: disp
        hideSource: true
        smooth: true   // grains sample the physics between sim points
        textureSize: Qt.size(s.cols, s.rows)
    }

    ShaderEffect {
        anchors.fill: parent
        fragmentShader: "shaders/dots.frag.qsb"
        property var disp: dispTex
        property vector2d size: Qt.vector2d(width, height)
        property vector2d grid: Qt.vector2d(s.cols, s.rows)
        property vector4d box: s.box
        property color dotColor: s.dotColor
        property color litColor: s.litColor
        property color backing: s.backing
        property real barTop: s.barTop
        property real corner: s.corner
        property real fillet: s.fillet
        property real cell: s.cell
        property real dotSize: s.dotSize
        property real simCell: s.simCell
        property real time: s.time
        property real flow: s.flow
        property real loose: s.loose
        property real mouseX: s.mouseX
        property real mouseY: s.mouseY
        property vector4d blob0: s.blob0
        property vector4d blob1: s.blob1
        property vector4d blob2: s.blob2
        property vector4d blob3: s.blob3
        property real gooLive: s.gooLive
        property real gooLife: s.gooLife
        property real hover: s.hov
        property real wave: s.wave
        property color gradA: s.gradA
        property color gradB: s.gradB
        property color grainM: s.grainM
        property color grainC: s.grainC
        property color grainY: s.grainY
    }
}
