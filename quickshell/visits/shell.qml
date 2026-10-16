// visits: a desktop widget showing how many people have visited the portfolio site.
// The site (~/Projects/themightypooh.github.io) bumps a free counter at abacus.jasoncameron.dev once
// per browser per day; this reads it every minute, flashes and sends a notification when it goes up.
// Run with:  qs -c visits        Drag it to move; click to check right now.
// IPC:       qs -c visits ipc call visits refresh
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: app

    // ---- tweak me -------------------------------------------------------
    readonly property string counterUrl: "https://abacus.jasoncameron.dev/get/themightypooh-portfolio/visitors"
    readonly property int pollSeconds: 60
    readonly property bool notify: true
    readonly property var grainCols: ["#ff4fd8", "#35e6ff", "#ffe04a"]
    // ---------------------------------------------------------------------

    FontLoader { id: blockFont; source: Quickshell.env("HOME") + "/.config/quickshell/wavegoo/fonts/WavegooRoundsquare.ttf" }

    property int count: -1            // -1 = not read yet
    property bool waiting: false      // counter doesn't exist yet: nobody has visited
    property bool offline: false
    property double lastVisit: 0      // when we last saw the number go up
    property double checkedAt: 0
    property bool peeking: false

    // remembered: position, today's starting count, last visit time
    property var st: ({ x: -1, y: 120, day: "", dayStart: 0, last: 0 })
    FileView {
        id: stateFile
        path: Quickshell.statePath("state.json")
        printErrors: false
        blockLoading: true
        onLoaded: { try { const o = JSON.parse(text()); app.st = Object.assign(app.st, o); app.lastVisit = app.st.last || 0 } catch (e) {} }
    }
    function save() { stateFile.setText(JSON.stringify(st)) }
    function today() { return new Date().toISOString().slice(0, 10) }
    readonly property int todayCount: count < 0 ? 0 : Math.max(0, count - (st.day === today() ? st.dayStart : count))

    Process {
        id: fetcher
        command: ["curl", "-s", "-m", "10", app.counterUrl]
        stdout: StdioCollector {
            onStreamFinished: {
                app.checkedAt = Date.now()
                let v = null
                try { const o = JSON.parse(text); if (typeof o.value === "number") v = o.value; else if (/not found/i.test(o.error || o.message || "")) v = 0 } catch (e) {}
                if (v === null) { app.offline = true; return }
                app.offline = false
                app.waiting = v === 0
                app.got(v)
            }
        }
    }
    function refresh() { if (!fetcher.running) fetcher.running = true }
    Timer { interval: app.pollSeconds * 1000; running: true; repeat: true; triggeredOnStart: true; onTriggered: app.refresh() }

    function got(v) {
        const d = today()
        if (st.day !== d) { st.day = d; st.dayStart = count >= 0 ? Math.min(count, v) : v; save() }
        if (count >= 0 && v > count) {
            lastVisit = Date.now(); st.last = lastVisit; save()
            widget.celebrate(v - count)
            if (notify) Quickshell.execDetached(["notify-send", "-a", "Portfolio", "New portfolio visit", v - count === 1 ? "That's visit #" + v + "." : (v - count) + " new visits: " + v + " total."])
        }
        count = v
    }

    function ago(ms) {
        if (!ms) return "NONE YET"
        const s = (Date.now() - ms) / 1000
        if (s < 60) return "JUST NOW"
        if (s < 3600) return Math.floor(s / 60) + "M AGO"
        if (s < 86400) return Math.floor(s / 3600) + "H AGO"
        return Math.floor(s / 86400) + "D AGO"
    }
    // re-render the "ago" text now and then
    property int tick: 0
    Timer { interval: 30000; running: true; repeat: true; onTriggered: app.tick++ }

    IpcHandler {
        target: "visits"
        function refresh(): void { app.refresh() }
        function count(): int { return app.count }
        // preview the new-visit flash without a real visit
        function peekFlash(): void { widget.celebrate(1) }
        // lift it above windows for a look (false puts it back on the desktop)
        function peek(on: bool): void { app.peeking = on }
    }

    PanelWindow {
        id: widget
        screen: Quickshell.screens[0]
        color: "transparent"
        anchors { top: true; left: true }
        readonly property int w: 230
        readonly property int h: 118
        property int px: app.st.x >= 0 ? app.st.x : (screen ? screen.width - w - 40 : 1600)
        property int py: app.st.y
        margins { top: widget.py; left: widget.px }
        implicitWidth: w + 8
        implicitHeight: h + 8
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "visits"
        WlrLayershell.layer: app.peeking ? WlrLayer.Top : WlrLayer.Bottom

        property real flash: 0
        property int gained: 0
        function celebrate(n) { gained = n; burst.restart(); grains.spawn(); grains.requestPaint() }
        SequentialAnimation {
            id: burst
            NumberAnimation { target: widget; property: "flash"; from: 0; to: 1; duration: 120 }
            NumberAnimation { target: widget; property: "flash"; to: 0; duration: 1600; easing.type: Easing.InQuad }
        }

        // hard pixel shadow + card
        Rectangle { x: 8; y: 8; width: widget.w; height: widget.h; color: "#000000"; opacity: 0.45 }
        Rectangle {
            id: card
            width: widget.w; height: widget.h
            color: Qt.tint("#0b0c10", Qt.rgba(0.21, 0.9, 1, widget.flash * 0.25))
            border.color: widget.flash > 0.05 ? "#35e6ff" : "#2a2d38"
            border.width: 2

            // a strip of the bar's grains along the bottom
            Canvas {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 2 }
                height: 14
                onPaint: {
                    const c = getContext("2d"); c.reset()
                    for (let i = 0; i < 260; i++) {
                        const x = Math.random() * width, y = Math.random() * height
                        if (y < height * (0.4 + 0.3 * Math.sin(x / 18))) continue
                        c.globalAlpha = 0.5 + Math.random() * 0.5
                        c.fillStyle = app.grainCols[i % 3]; c.fillRect(x, y, 2, 2)
                    }
                }
                Component.onCompleted: requestPaint()
            }

            Text {
                x: 14; y: 10
                text: "PORTFOLIO VISITS"
                font.family: blockFont.name; font.pixelSize: 11; font.letterSpacing: 1.5
                color: "#7d8496"
            }
            Text {
                id: big
                x: 12; y: 26
                text: app.count < 0 ? "..." : app.count
                font.family: blockFont.name; font.pixelSize: 44
                color: "#dfe4ec"
                scale: 1 + widget.flash * 0.12
                transformOrigin: Item.Left
            }
            Text {
                visible: widget.flash > 0.02
                anchors { left: big.right; leftMargin: 10; verticalCenter: big.verticalCenter }
                text: "+" + widget.gained
                font.family: blockFont.name; font.pixelSize: 18
                color: "#35e6ff"; opacity: widget.flash
            }
            Text {
                x: 14; y: 80
                text: { app.tick; return app.offline ? "CAN'T REACH COUNTER" : app.waiting ? "WAITING FOR THE FIRST VISIT"
                       : "+" + app.todayCount + " TODAY  ·  LAST " + app.ago(app.lastVisit) }
                font.family: blockFont.name; font.pixelSize: 10; font.letterSpacing: 1
                color: app.offline ? "#f09595" : "#9aa1b2"
            }
        }

        // grains that pop out of the number on a new visit
        Canvas {
            id: grains
            anchors.fill: parent
            property var parts: []
            function spawn() {
                const p = []
                for (let i = 0; i < 70; i++) {
                    const a = Math.random() * Math.PI * 2, sp = 40 + Math.random() * 110
                    p.push({ x: 60, y: 52, vx: Math.cos(a) * sp, vy: Math.sin(a) * sp - 40, c: app.grainCols[i % 3] })
                }
                parts = p; t0 = Date.now()
            }
            property double t0: 0
            Timer { interval: 16; repeat: true; running: grains.parts.length > 0; onTriggered: grains.requestPaint() }
            onPaint: {
                const c = getContext("2d"); c.reset()
                const t = (Date.now() - t0) / 1000
                if (t > 1.4) { parts = []; return }
                for (const q of parts) {
                    c.globalAlpha = Math.max(0, 1 - t / 1.4)
                    c.fillStyle = q.c
                    c.fillRect(q.x + q.vx * t, q.y + q.vy * t + 120 * t * t, 2.5, 2.5)
                }
            }
        }

        // drag to move (applied once a frame so the window can't run away from the pointer); click to check now
        MouseArea {
            id: drag
            width: widget.w; height: widget.h
            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            property real sx: 0
            property real sy: 0
            property real lx: 0
            property real ly: 0
            property bool dirty: false
            property bool moved: false
            onPressed: m => { sx = lx = m.x; sy = ly = m.y; moved = false }
            onPositionChanged: m => { lx = m.x; ly = m.y; dirty = true; if (Math.abs(m.x - sx) + Math.abs(m.y - sy) > 4) moved = true }
            onReleased: { if (moved) { app.st.x = widget.px; app.st.y = widget.py; app.save() } else app.refresh() }
            Timer {
                interval: 16; repeat: true; running: drag.pressed
                onTriggered: {
                    if (!drag.dirty || !drag.moved) return
                    drag.dirty = false
                    const sw = widget.screen ? widget.screen.width : 1920, sh = widget.screen ? widget.screen.height : 1080
                    widget.px = Math.max(0, Math.min(sw - widget.w, widget.px + Math.round(drag.lx - drag.sx)))
                    widget.py = Math.max(0, Math.min(sh - widget.h, widget.py + Math.round(drag.ly - drag.sy)))
                }
            }
        }
    }
}
