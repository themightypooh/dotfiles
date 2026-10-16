// hourglass — a desktop sand timer in wavegoo colours, with the bar's magenta/cyan/yellow grains.
// Run with:  qs -c hourglass -d
// IPC:       qs -c hourglass ipc call hourglass start 25m | toggle | pause | resume | reset | add 5m | nudge 1 | status | peek | quit
//
// Set a time (scroll the glass, click the readout and type, or pick a preset), start it, and the
// glass flips over: the top bulb is full and drains through the neck at exactly the rate of the
// time left. Click the glass to pause, ↺ to pour the rest out. Drag the glass to move it.
//
// No grain is simulated. The sand's shape (top level + crater, bottom level + heap) is solved from
// the time left so the volume is conserved, and shaders/glass.frag draws grains wherever there's
// sand, plus a falling stream that only needs a clock. The only timer runs while sand is moving:
// a paused, finished or unset glass costs nothing.
// State (position, duration, a running timer's end time) is in
// ~/.local/state/quickshell/by-shell/<id>/hourglass.json, so a running timer survives a restart.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: hg

    // ---- tweak me -------------------------------------------------------
    // colors are #AARRGGBB (same as the wavegoo bar)
    readonly property color gooA: "#f07f77dd"     // liquid gradient: top of the frame
    readonly property color gooB: "#f01d9e75"     // liquid gradient: bottom of the frame
    readonly property color grainM: "#ffff4fd8"   // sand: magenta
    readonly property color grainC: "#ff35e6ff"   // sand: cyan
    readonly property color grainY: "#ffffe04a"   // sand: yellow
    readonly property color rim: "#bfdfe4ec"      // glass outline dots
    readonly property color ink: "#ffdfe4ec"      // readout
    readonly property color dimInk: "#80dfe4ec"   // labels
    readonly property var presets: [1, 5, 10, 25, 60]   // minutes
    readonly property string sound: "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga"
    // ---------------------------------------------------------------------

    FontLoader { id: blockFont; source: "fonts/WavegooRoundsquare.ttf" }
    readonly property string block: blockFont.name

    // ---- timer state --------------------------------------------------------------------------
    // empty: all the sand is in the bottom, waiting for a start
    // running / paused: draining; done: ran out (flashes, then behaves like empty)
    // flipping / pouring: animations between those
    property string mode: "empty"
    property real duration: 300          // seconds
    property real endAt: 0               // ms, while running
    property real left: 0                // seconds, while paused
    property real frac: 0                // sand left in the top, 0..1 (what's drawn)
    property real clock: 0               // stream clock: only moves while sand moves
    property real flowFrom: 0
    property real flowTo: 1e9
    property real lastTick: 0
    property bool tailing: false         // the last grains are still falling
    property real flash: 0
    property string pending: ""          // a start that waits for the sand to pour out first
    property int px: -1
    property int py: -1
    property string screenName: ""
    property bool ready: false
    property bool peek: false            // lifted above windows (IPC: peek)

    readonly property bool moving: mode === "running" || mode === "pouring" || tailing
    readonly property real shownLeft: mode === "running" || mode === "paused" ? left : duration

    function fmt(s) {
        s = Math.max(0, Math.ceil(s - 0.001))
        const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, x = s % 60
        const p = n => (n < 10 ? "0" : "") + n
        return h > 0 ? h + ":" + p(m) + ":" + p(x) : p(m) + ":" + p(x)
    }
    // "25" = 25 min, "1:30" = 1 min 30 s, "1:00:00", "1h20m", "90s", "2.5m"
    function parseDur(str) {
        str = String(str || "").trim().toLowerCase()
        if (!str) return 0
        if (/^\d+(\.\d+)?$/.test(str)) return parseFloat(str) * 60
        if (/^[\d:]+$/.test(str)) return str.split(":").map(n => parseInt(n || "0")).reduce((a, b) => a * 60 + b, 0)
        let t = 0, any = false
        const re = /(\d+(?:\.\d+)?)\s*(h|m|s)/g
        let m
        while ((m = re.exec(str)) !== null) { any = true; t += parseFloat(m[1]) * (m[2] === "h" ? 3600 : m[2] === "m" ? 60 : 1) }
        return any ? t : 0
    }
    function clampDur(s) { return Math.max(1, Math.min(s, 99 * 3600 + 59 * 60 + 59)) }

    // start a timer of `secs` (or the current duration): pour out what's left, flip, run
    function start(secs) {
        if (secs > 0) duration = clampDur(secs)
        if (mode === "flipping") return
        if (frac > 0.001) { pending = "start"; pour(); return }
        flip()
    }
    function toggle() {
        if (mode === "running") pause()
        else if (mode === "paused") resume()
        else start(0)
    }
    function pause() {
        if (mode !== "running") return
        left = Math.max(0, (endAt - Date.now()) / 1000)
        mode = "paused"
        save()
    }
    function resume() {
        if (mode !== "paused") return
        endAt = Date.now() + left * 1000
        lastTick = Date.now()
        mode = "running"
        save()
    }
    // pour the rest of the sand through, fast (reset)
    property real pourFrom: 0
    property real pourStart: 0
    function pour() {
        if (frac <= 0.001) { frac = 0; mode = "empty"; save(); return }
        pourFrom = frac
        pourStart = Date.now()
        lastTick = Date.now()
        if (flowTo < clock) { flowFrom = clock; flowTo = 1e9 }
        mode = "pouring"
        save()
    }
    function reset() { pending = ""; if (mode !== "empty" && mode !== "done") pour() }
    function add(secs) {
        if (mode === "running") { endAt += secs * 1000; duration += secs }
        else if (mode === "paused") { left += secs; duration += secs }
        else duration = clampDur(duration + secs)
        if (duration < 1) duration = 1
        save()
    }
    function flip() {
        mode = "flipping"
        flipAnim.restart()
    }
    // flip, halfway (edge on): the sand is now all in the top
    function flipped() {
        frac = 1; tailing = false; flowTo = 1e9; flash = 0
        solve()
    }
    function run() {
        left = duration
        endAt = Date.now() + duration * 1000
        lastTick = Date.now()
        flowFrom = clock
        flowTo = 1e9
        mode = "running"
        save()
    }
    function finish(quiet) {
        frac = 0; left = 0
        flowTo = clock; tailing = true
        mode = "done"
        save()
        if (!quiet) {
            doneAnim.restart()
            notify.command = ["notify-send", "-a", "Hourglass", "-i", "alarm-symbolic", "Time's up", hg.fmt(hg.duration) + " timer finished"]
            notify.running = true
            ding.running = true
        }
    }

    function tick() {
        const now = Date.now()
        const dt = Math.min(0.1, Math.max(0, (now - lastTick) / 1000))
        lastTick = now
        clock += dt
        if (mode === "running") {
            left = Math.max(0, (endAt - now) / 1000)
            frac = duration > 0 ? left / duration : 0
            if (left <= 0) finish(false)
        } else if (mode === "pouring") {
            const t = Math.min(1, (now - pourStart) / 900)
            frac = pourFrom * (1 - t) * (1 - t)
            if (t >= 1) {
                frac = 0; flowTo = clock; tailing = true; mode = "empty"
                if (pending === "start") { pending = ""; flip() }
                save()
            }
        }
        if (tailing && mode !== "running" && mode !== "pouring" && clock - flowTo > 0.6) tailing = false
        solve()
    }
    Timer { interval: 33; repeat: true; running: hg.moving; onTriggered: hg.tick() }

    // ---- sand geometry (same profile as glass.frag) ------------------------------------------
    readonly property real gw: 200          // shader item size
    readonly property real gh: 310
    readonly property real neckY: 155
    readonly property real neckLen: 4
    readonly property real neckW: 3.2
    readonly property real bulbH: 128
    readonly property real bulbR: 66
    readonly property real glassTop: neckY - neckLen - bulbH
    readonly property real glassBot: neckY + neckLen + bulbH
    readonly property real fullLevel: glassTop + bulbH * 0.2     // a full top bulb fills this high

    function halfWidth(y) {
        let u = Math.max(0, Math.min(1, (Math.abs(y - neckY) - neckLen) / bulbH))
        const a = 0.62
        const s = u < a ? 1 - (1 - u / a) * (1 - u / a) : Math.sqrt(Math.max(0, 1 - Math.pow((u - a) / 0.63, 2)))
        return neckW + (bulbR - neckW) * s
    }
    // volume (as sum of r^2 per 1px row) of top sand with level L and a crater
    function crater(L, ramp) { return { dip: ramp * Math.min(neckY - neckLen - L, bulbH * 0.2), r: halfWidth(L) * 0.92 } }
    function topVol(L, ramp) {
        const c = crater(L, ramp)
        let v = 0
        for (let y = glassTop; y < neckY - neckLen; y += 1) {
            const yc = y + 0.5, w = Math.max(0, Math.min(1, yc + 0.5 - L))
            if (w <= 0) continue
            const hw = halfWidth(yc)
            let rin = 0
            if (c.dip > 0 && yc - L < c.dip) rin = c.r * (1 - Math.pow(Math.max(0, yc - L) / c.dip, 1 / 1.25))
            rin = Math.max(0, Math.min(rin, hw))
            v += w * (hw * hw - rin * rin)
        }
        return v
    }
    function heapOf(g) { return bulbH * 0.42 * Math.min(1, Math.sqrt(g * 3)) }
    function botVol(B, H) {
        const R = halfWidth(B)
        let v = 0
        for (let y = neckY + neckLen; y < glassBot; y += 1) {
            const yc = y + 0.5, hw = halfWidth(yc)
            const w = Math.max(0, Math.min(1, yc + 0.5 - B))
            let r = H > 0 && yc < B ? R * (1 - (B - yc) / H) : 0
            r = Math.max(0, Math.min(r, hw))
            v += w * hw * hw + (1 - w) * r * r
        }
        return v
    }
    readonly property real fullVol: topVol(fullLevel, 0)

    property real topY: neckY
    property real dip: 0
    property real craterR: 1
    property real botY: glassBot
    property real heap: 0
    property real heapR: 1
    // [topY, dip, craterR, botY, heap, heapR] for f = sand left in the top
    function shapeAt(f) {
        const g = 1 - f
        const ramp = Math.min(1, g * 25)
        // top: the level whose volume is what's left (volume shrinks as the level drops)
        let lo = fullLevel - 4, hi = neckY - neckLen
        if (f <= 0) lo = hi
        else for (let i = 0; i < 22; i++) {
            const mid = (lo + hi) / 2
            if (topVol(mid, ramp) > f * fullVol) lo = mid; else hi = mid
        }
        const c = crater(lo, ramp)
        // bottom: the base level whose volume (with the heap) is what's fallen
        const H = heapOf(g)
        let b0 = neckY + neckLen, b1 = glassBot
        if (g <= 0) b0 = b1
        else for (let i = 0; i < 22; i++) {
            const mid = (b0 + b1) / 2
            if (botVol(mid, H) > g * fullVol) b0 = mid; else b1 = mid
        }
        return [f <= 0 ? neckY : lo, c.dip, c.r, g <= 0 ? glassBot + 20 : b1, g <= 0 ? 0 : H, halfWidth(b1)]
    }
    // solved once at startup; each frame just interpolates (the solve is far too slow per frame)
    readonly property int steps: 200
    property var table: null
    function solve() {
        if (!table) {
            const t = []
            for (let i = 0; i <= steps; i++) t.push(shapeAt(i / steps))
            table = t
        }
        const x = Math.max(0, Math.min(1, frac)) * steps
        const i = Math.min(steps - 1, Math.floor(x)), w = x - i
        const a = table[i], b = table[i + 1]
        const v = k => a[k] + (b[k] - a[k]) * w
        topY = v(0); dip = v(1); craterR = v(2); botY = v(3); heap = v(4); heapR = v(5)
    }

    // ---- notification + sound -----------------------------------------------------------------
    Process { id: notify }
    Process { id: ding; command: ["pw-play", hg.sound] }

    // ---- persistence --------------------------------------------------------------------------
    FileView {
        id: file
        path: Quickshell.statePath("hourglass.json")
        printErrors: false
        blockLoading: true
        onLoaded: hg.load(text())
        onLoadFailed: hg.load("")
    }
    function load(raw) {
        let o = {}
        try { o = JSON.parse(raw) || {} } catch (e) {}
        if (o.duration > 0) duration = o.duration
        if (typeof o.x === "number") px = o.x
        if (typeof o.y === "number") py = o.y
        screenName = o.screen || ""
        lastTick = Date.now()
        if (o.mode === "running" && o.endAt) {
            endAt = o.endAt; mode = "running"; flowFrom = clock
            left = Math.max(0, (endAt - Date.now()) / 1000)
            frac = left / duration
            if (left <= 0) finish(false)   // ran out while we weren't running
        } else if (o.mode === "paused" && o.left > 0) {
            left = o.left; frac = left / duration; mode = "paused"; flowTo = -1
        } else { mode = "empty"; frac = 0 }
        solve()
        ready = true
    }
    function save() {
        if (!ready) return
        file.setText(JSON.stringify({
            x: px, y: py, screen: screenName, duration: duration,
            mode: mode === "flipping" ? "empty" : mode === "pouring" || mode === "done" ? "empty" : mode,
            endAt: endAt, left: left
        }, null, 1))
    }

    // ---- the widget ---------------------------------------------------------------------------
    PanelWindow {
        id: win
        screen: {
            const ss = Quickshell.screens
            for (let i = 0; i < ss.length; i++) if (ss[i].name === hg.screenName) return ss[i]
            return ss.length ? ss[0] : null
        }
        visible: hg.ready
        color: "transparent"
        anchors { top: true; left: true }
        margins {
            top: hg.py >= 0 ? hg.py : 140
            left: hg.px >= 0 ? hg.px : Math.max(0, (win.screen ? win.screen.width : 1920) - implicitWidth - 60)
        }
        implicitWidth: 220
        implicitHeight: 430
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "hourglass"
        WlrLayershell.layer: hg.peek ? WlrLayer.Top : WlrLayer.Bottom
        WlrLayershell.keyboardFocus: entry.visible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        Item {
            id: root
            anchors.fill: parent
            HoverHandler { id: hover; onHoveredChanged: if (!hovered && hg.peek) sink.restart() }
            // lifted over your windows (bar button): sinks back once you leave it, or if you never come
            Timer { id: sink; interval: hover.hovered ? 1200 : 6000; onTriggered: if (!hover.hovered && !entry.visible) hg.peek = false }
            Connections { target: hg; function onPeekChanged() { if (hg.peek) sink.restart() } }
            property real hov: hover.hovered ? 1 : 0
            Behavior on hov { NumberAnimation { duration: 220 } }

            // ---- the glass ----
            Item {
                id: glassBox
                width: hg.gw; height: hg.gh
                anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 8 }
                property real flipAngle: 0
                property real wobble: 0
                transform: [
                    Rotation { origin.x: hg.gw / 2; origin.y: hg.gh / 2; axis { x: 1; y: 0; z: 0 } angle: glassBox.flipAngle },
                    Rotation { origin.x: hg.gw / 2; origin.y: hg.gh / 2; angle: glassBox.wobble }
                ]

                ShaderEffect {
                    anchors.fill: parent
                    fragmentShader: "shaders/glass.frag.qsb"
                    property vector2d size: Qt.vector2d(width, height)
                    property real neckY: hg.neckY
                    property real neckLen: hg.neckLen
                    property real neckW: hg.neckW
                    property real bulbH: hg.bulbH
                    property real bulbR: hg.bulbR
                    property real cell: 2.8
                    property real pitch: 3.0
                    property real time: hg.clock
                    property real topY: hg.topY
                    property real dip: hg.dip
                    property real crater: hg.craterR
                    property real topShift: hg.topY < hg.neckY ? hg.topY - hg.fullLevel : 0
                    property real botY: hg.botY
                    property real heap: hg.heap
                    property real heapR: hg.heapR
                    property real stream: hg.mode === "running" || hg.mode === "pouring" || hg.tailing || hg.mode === "paused" ? 1 : 0
                    property real flowFrom: hg.flowFrom
                    property real flowTo: hg.flowTo
                    property real flash: hg.flash
                    property real dim: hg.mode === "paused" ? 1 : 0
                    property real hover: root.hov
                    property color gradA: hg.gooA
                    property color gradB: hg.gooB
                    property color grainM: hg.grainM
                    property color grainC: hg.grainC
                    property color grainY: hg.grainY
                    property color rim: hg.rim
                }

                // click: start / pause; drag: move the widget; scroll: set the time
                MouseArea {
                    id: glassArea
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                    cursorShape: dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                    property real sx: 0
                    property real sy: 0
                    property real lx: 0
                    property real ly: 0
                    property bool dragging: false
                    property bool dirty: false
                    onPressed: m => { sx = m.x; sy = m.y; lx = m.x; ly = m.y; dragging = false; entry.visible = false }
                    onPositionChanged: m => {
                        lx = m.x; ly = m.y
                        if (!dragging && Math.hypot(lx - sx, ly - sy) > 5) {
                            dragging = true
                            if (hg.px < 0) { hg.px = win.margins.left; hg.py = win.margins.top }
                        }
                        if (dragging) dirty = true
                    }
                    onReleased: m => {
                        if (dragging) { dragging = false; hg.screenName = win.screen ? win.screen.name : ""; hg.save() }
                        else if (m.button === Qt.MiddleButton) hg.reset()
                        else hg.toggle()
                    }
                    onWheel: w => hg.nudge(w.angleDelta.y > 0 ? 1 : -1)
                    Timer {
                        interval: 16; repeat: true; running: glassArea.dragging
                        onTriggered: {
                            if (!glassArea.dirty) return
                            glassArea.dirty = false
                            hg.px = Math.max(0, hg.px + Math.round(glassArea.lx - glassArea.sx))
                            hg.py = Math.max(0, hg.py + Math.round(glassArea.ly - glassArea.sy))
                        }
                    }
                }
            }

            // ---- readout ----
            Item {
                id: readout
                anchors { top: glassBox.bottom; topMargin: 4; horizontalCenter: parent.horizontalCenter }
                width: parent.width; height: 40
                Text {
                    id: digits
                    anchors.centerIn: parent
                    visible: !entry.visible
                    text: hg.fmt(hg.shownLeft)
                    font.family: hg.block
                    font.pixelSize: 30
                    color: hg.flash > 0 ? Qt.tint(hg.ink, Qt.rgba(1, 0.31, 0.85, hg.flash)) : hg.ink
                    opacity: hg.mode === "empty" || hg.mode === "done" ? 0.75 : hg.mode === "paused" ? 0.6 : 1
                }
                TextInput {
                    id: entry
                    anchors.centerIn: parent
                    visible: false
                    width: parent.width - 20
                    horizontalAlignment: TextInput.AlignHCenter
                    font.family: hg.block
                    font.pixelSize: 30
                    color: hg.ink
                    selectionColor: "#80ff4fd8"
                    selectByMouse: true
                    onAccepted: { const s = hg.parseDur(text); visible = false; if (s > 0) hg.start(s) }
                    Keys.onEscapePressed: visible = false
                    onActiveFocusChanged: if (!activeFocus) visible = false
                }
                MouseArea {
                    anchors.fill: parent
                    visible: !entry.visible
                    cursorShape: Qt.IBeamCursor
                    onClicked: { entry.text = hg.fmt(hg.duration); entry.visible = true; entry.forceActiveFocus(); entry.selectAll() }
                    onWheel: w => hg.nudge(w.angleDelta.y > 0 ? 1 : -1)
                }
            }
            Text {
                id: hint
                anchors { top: readout.bottom; horizontalCenter: parent.horizontalCenter }
                text: entry.visible ? "TYPE 25 · 1:30 · 1H20M · ENTER"
                    : hg.mode === "running" ? "CLICK TO PAUSE"
                    : hg.mode === "paused" ? "PAUSED · CLICK TO GO ON"
                    : hg.mode === "done" ? "TIME'S UP"
                    : root.hov > 0.5 ? "SCROLL TO SET · CLICK TO START" : ""
                font.family: hg.block
                font.pixelSize: 9
                font.letterSpacing: 1
                color: hg.mode === "done" ? hg.grainM : hg.dimInk
            }

            // ---- presets + reset (on hover) ----
            Row {
                anchors { top: hint.bottom; topMargin: 8; horizontalCenter: parent.horizontalCenter }
                spacing: 5
                opacity: root.hov
                visible: opacity > 0.01
                Repeater {
                    model: hg.presets
                    delegate: Chip {
                        required property int modelData
                        required property int index
                        label: modelData + "M"
                        tint: [hg.grainM, hg.grainC, hg.grainY][index % 3]
                        onClicked: hg.start(modelData * 60)
                    }
                }
                Chip {
                    label: "↺"
                    tint: hg.ink
                    enabled: hg.mode === "running" || hg.mode === "paused"
                    onClicked: hg.reset()
                }
            }
        }
    }

    // scroll: change the time while it's not running (fine steps under 2 minutes)
    function nudge(dir) {
        if (mode === "running" || mode === "paused" || mode === "flipping") return
        const step = duration + dir * 60 < 120 || (dir < 0 && duration <= 120) ? 10 : 60
        duration = clampDur(Math.round((duration + dir * step) / step) * step)
        save()
    }

    // ---- animations (they only run while they play) -------------------------------------------
    SequentialAnimation {
        id: flipAnim
        NumberAnimation { target: glassBox; property: "flipAngle"; from: 0; to: 90; duration: 230; easing.type: Easing.InCubic }
        ScriptAction { script: hg.flipped() }
        PropertyAction { target: glassBox; property: "flipAngle"; value: -90 }
        NumberAnimation { target: glassBox; property: "flipAngle"; to: 0; duration: 420; easing.type: Easing.OutBack }
        ScriptAction { script: hg.run() }
    }
    SequentialAnimation {
        id: doneAnim
        ParallelAnimation {
            SequentialAnimation {
                loops: 3
                NumberAnimation { target: hg; property: "flash"; from: 0; to: 1; duration: 140 }
                NumberAnimation { target: hg; property: "flash"; to: 0; duration: 520; easing.type: Easing.InQuad }
            }
            SequentialAnimation {
                NumberAnimation { target: glassBox; property: "wobble"; to: -6; duration: 90 }
                NumberAnimation { target: glassBox; property: "wobble"; to: 5; duration: 140 }
                NumberAnimation { target: glassBox; property: "wobble"; to: -3; duration: 140 }
                NumberAnimation { target: glassBox; property: "wobble"; to: 1.5; duration: 140 }
                NumberAnimation { target: glassBox; property: "wobble"; to: 0; duration: 200; easing.type: Easing.OutCubic }
            }
        }
    }

    component Chip: Rectangle {
        id: chip
        property string label
        property color tint
        signal clicked()
        width: Math.max(28, chipText.implicitWidth + 12); height: 20
        radius: 3
        color: chipArea.containsMouse && chip.enabled ? Qt.rgba(tint.r, tint.g, tint.b, 0.25) : "#cc090a0d"
        border.width: 1
        border.color: Qt.rgba(tint.r, tint.g, tint.b, chip.enabled ? 0.6 : 0.2)
        Text {
            id: chipText
            anchors.centerIn: parent
            text: chip.label
            font.family: chip.label === "↺" ? "sans-serif" : hg.block
            font.pixelSize: chip.label === "↺" ? 13 : 10
            color: chip.enabled ? chip.tint : Qt.rgba(chip.tint.r, chip.tint.g, chip.tint.b, 0.3)
        }
        MouseArea {
            id: chipArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (chip.enabled) chip.clicked()
        }
    }

    IpcHandler {
        target: "hourglass"
        // start "25m" / "1:30" / "90s" / "25" (minutes); empty = the last duration
        function start(dur: string): void { hg.start(hg.parseDur(dur)) }
        function toggle(): void { hg.toggle() }
        function pause(): void { hg.pause() }
        function resume(): void { hg.resume() }
        function reset(): void { hg.reset() }
        function add(dur: string): void { hg.add(hg.parseDur(dur)) }
        function status(): string { return hg.mode + " " + hg.fmt(hg.shownLeft) + " / " + hg.fmt(hg.duration) }
        function peek(): void { hg.peek = !hg.peek }
        // scroll on the bar button: +1 / -1 step
        function nudge(dir: int): void { hg.nudge(dir) }
        // save a PNG of the widget (for screenshots)
        function snap(path: string): void { root.grabToImage(r => r.saveToFile(path)) }
        function quit(): void { Qt.quit() }
    }
}
