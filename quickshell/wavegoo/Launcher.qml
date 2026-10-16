// Start menu: an arc fan that unfolds out of the start orb.
//
//   hub      (r < 150)  what you're pointing at, your search, or the current category
//   rings 1, 2, 3       the current category's apps as one carousel running ring 1 -> 2 -> 3
//                       (or search results)
//   power cluster       lock / sleep / log out / restart / shut down, always there, loosely scattered
//                       in the corner by the orb (hub text sits above them)
//                       (pinned apps live in the bar's drawer, so they're not repeated here)
//   band                categories, curved along the rim; "all" is the first one
//
// Rings are sized from how many icons they hold, so nothing overlaps.
// Mouse: point at a ring to pick by angle, point at the band to switch category, wheel spins the carousel.
// Keys: type to search, ←/→ along a ring, ↑/↓ between rings, Tab category, PgUp/PgDn spin a ring's worth,
//       Enter open, Esc close. Restart / shut down / log out need a second press.
// Toggle with:  qs -c wavegoo ipc call launcher toggle   (Super is bound to this)
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets

PanelWindow {
    id: menu
    required property var root

    // ---- open / close -------------------------------------------------------------
    readonly property bool open: root.launcherOpen
    readonly property bool peek: root.launcherPeek      // open for a look only: no keyboard grab
    property bool shown: false
    property real reveal: 0
    onOpenChanged: {
        if (open) {
            if (!shown) waveClock = root.waveTime      // (the clock stood still while hidden)
            shown = true; query = ""; spin = 0; armed = ""; selRing = -1; selIndex = -1
            closeAnim.stop(); openAnim.restart()
            keys.forceActiveFocus()
        } else { openAnim.stop(); closeAnim.restart() }
    }
    NumberAnimation { id: openAnim; target: menu; property: "reveal"; to: 1; duration: 1350; easing.type: Easing.InOutSine }
    NumberAnimation { id: closeAnim; target: menu; property: "reveal"; to: 0; duration: 450; easing.type: Easing.InQuad; onFinished: menu.shown = false }
    // rings unfold one after another
    function freezeReveal(v) { openAnim.stop(); closeAnim.stop(); reveal = v }
    // it rises out of the bar: a liquid surface `level` px above the orb climbs past the rim
    // it grows out of the bar from the orb: a blob whose radius swells out (growR) while its
    // sloshing surface climbs (level), a little ahead so the top fills as it spreads
    readonly property real level: -30 + (band[1] + 106) * Math.min(1, reveal * 1.15)
    // grows past its full size and springs back (ease-out-back), so it opens with a bit of bounce
    readonly property real growR: {
        const x = reveal - 1, c1 = 2.2
        return 30 + (band[1] + 16 - 30) * (1 + (c1 + 1) * x * x * x + c1 * x * x)
    }
    // 0..1: how far the blob has reached something at height h / radius r (things float up into view)
    function riseVis(h, r) {
        const byLevel = (level - h + 6) / 40
        const byGrow = r === undefined ? 1 : (growR - r + 6) / 40
        return Math.max(0, Math.min(1, byLevel, byGrow))
    }
    // offset for something floating up: starts 22px low, bobs ~6px past its spot, settles
    function bob(v) { return (1 - v) * 22 - Math.sin(v * Math.PI) * 8 }
    // scale for something popping into view: small, then a bubbly overshoot, then normal
    function popScale(v) { return 0.45 + 0.55 * v + Math.sin(v * Math.PI) * 0.35 }

    visible: shown
    anchors { left: true; right: true; top: true; bottom: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.namespace: "wavegoo-launcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: open && !peek ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    // in a preview, clicks and hovers go straight through to whatever is underneath
    mask: peek ? noInput : null
    Region { id: noInput }

    // block letters after Churchward Roundsquare (the Bugonia title font), built by fonts/roundsquare.py
    FontLoader { id: blockFont; source: "fonts/WavegooRoundsquare.ttf" }
    readonly property string font: blockFont.name
    // menu text: block caps; big text also gets scanlines (on small text they eat the cut-outs)
    component MenuText: Text {
        font.family: menu.font
        textFormat: Text.PlainText
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.5
        layer.enabled: font.pixelSize >= 16
        layer.effect: Scan {}
    }
    component Scan: ShaderEffect {
        fragmentShader: "shaders/scan.frag.qsb"
        property real h: height
    }
    // soft dark halo behind text, so it reads over the grains
    component Halo: MultiEffect {
        shadowEnabled: true; shadowColor: "black"; shadowOpacity: 1
        shadowBlur: 0.45; blurMax: 10
        shadowHorizontalOffset: 0; shadowVerticalOffset: 0
    }

    // ---- geometry: polar around the start orb --------------------------------------
    readonly property real ox: 31
    readonly property real oy: height - 23
    readonly property real hubR: 150
    // the power cluster: hand-placed, zig-zagging, slightly different sizes. x on screen, h above the orb
    readonly property var powerSpots: [
        { x: 24, h: 92, size: 22 }, { x: 58, h: 70, size: 24 }, { x: 92, h: 98, size: 20 },
        { x: 122, h: 66, size: 22 }, { x: 152, h: 94, size: 25 }
    ]
    function powerAt(x, y) {        // which power icon is under (x, y), or -1
        for (let i = 0; i < powerActions.length; i++)
            if (Math.hypot(x - powerSpots[i].x, y - (oy - powerSpots[i].h)) <= 16) return i
        return -1
    }
    // capacity = arc length / icon pitch, so icons never crowd
    readonly property var rings: [
        { r0: 186, r1: 276, cap: 7, size: 34 },
        { r0: 282, r1: 366, cap: 9, size: 34 },
        { r0: 372, r1: 456, cap: 12, size: 32 }
    ]
    readonly property var band: [464, 506]
    readonly property real a0: 0.07                 // near the bar
    readonly property real a1: Math.PI / 2 + 0.02   // near the screen edge
    function px(r, a) { return ox + Math.cos(a) * r }
    function py(r, a) { return oy - Math.sin(a) * r }
    function mid(k) { return (rings[k].r0 + rings[k].r1) / 2 }
    // slot 0 sits at the top and the ring reads clockwise toward the bar
    // each ring stops this far above the orb, so its lowest icon stays clear of the bar
    readonly property real ringFloor: 62
    function ringA0(k) { return Math.asin(Math.min(1, ringFloor / mid(k))) }
    // ...and starts so its first icon sits straight above the orb, flush with the screen edge
    function ringA1(k) { const n = 2 * rings[k].cap; return (Math.PI / 2 - ringA0(k) / n) / (1 - 1 / n) }
    function slotAngle(k, i) { return ringA1(k) - (i + 0.5) / rings[k].cap * (ringA1(k) - ringA0(k)) }
    function slotSpan(k) { return (ringA1(k) - ringA0(k)) / rings[k].cap }
    function deg(a) { return a * 180 / Math.PI }

    // ---- apps, categories, power -------------------------------------------------------
    readonly property var apps: DesktopEntries.applications.values
        .filter(e => !e.noDisplay && e.name)
        .sort((a, b) => a.name.localeCompare(b.name))
    readonly property var catDefs: [
        { name: "games", keys: ["Game"] },
        { name: "internet", keys: ["Network", "WebBrowser", "Email", "Chat"] },
        { name: "media", keys: ["AudioVideo", "Audio", "Video", "Graphics"] },
        { name: "dev", keys: ["Development"] },
        { name: "office", keys: ["Office", "Education", "Science"] },
        { name: "system", keys: ["System", "Settings", "Utility"] }
    ]
    function catOf(e) {
        const c = e.categories || []
        for (let i = 0; i < catDefs.length; i++) if (catDefs[i].keys.some(k => c.indexOf(k) >= 0)) return i
        return catDefs.length - 1
    }
    // empty categories are left out; "all" is always first
    readonly property var cats: {
        const list = catDefs.map((c, i) => ({ name: c.name, apps: apps.filter(e => catOf(e) === i) }))
            .filter(c => c.apps.length > 0)
        list.unshift({ name: "all", apps: apps })
        return list
    }
    readonly property var powerActions: [
        { name: "Lock", desc: "Lock the screen", icon: "system-lock-screen", cmd: ["loginctl", "lock-session"], confirm: false },
        { name: "Sleep", desc: "Suspend to RAM", icon: "system-suspend", cmd: ["systemctl", "suspend"], confirm: false },
        { name: "Log out", desc: "End this session", icon: "system-log-out", cmd: ["qdbus6", "org.kde.Shutdown", "/Shutdown", "org.kde.Shutdown.logout"], confirm: true },
        { name: "Restart", desc: "Reboot the computer", icon: "system-reboot", cmd: ["systemctl", "reboot"], confirm: true },
        { name: "Shut down", desc: "Power off", icon: "system-shutdown", cmd: ["systemctl", "poweroff"], confirm: true }
    ]

    property int cat: 0
    property string query: ""
    // carousel: how far the category's apps have been turned along the rings (unbounded; wraps by mod)
    property int spin: 0
    property real spinS: spin
    Behavior on spinS { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
    property int selRing: -1
    property int selIndex: -1
    property string armed: ""       // name of the power action waiting for its second press

    function score(e, q) {
        const n = e.name.toLowerCase()
        if (n.startsWith(q)) return 0
        if (n.split(/[\s\-_.]/).some(w => w.startsWith(q))) return 1
        if (n.indexOf(q) >= 0) return 2
        if ((e.genericName || "").toLowerCase().indexOf(q) >= 0) return 3
        if ((e.keywords || []).some(k => k.toLowerCase().indexOf(q) >= 0)) return 4
        return 9
    }
    readonly property var results: {
        const q = query.trim().toLowerCase()
        if (!q) return null
        return apps.map(e => [score(e, q), e]).filter(x => x[0] < 9)
            .sort((a, b) => a[0] - b[0] || a[1].name.localeCompare(b[1].name)).map(x => x[1])
    }

    function appItem(e) { return { key: "app:" + e.id, name: e.name, desc: e.genericName || e.comment || "", icon: e.icon, entry: e } }
    function powerItem(p) { return { key: "power:" + p.name, name: p.name, desc: p.desc, icon: p.icon, action: p } }

    readonly property var curCat: cats[Math.min(cat, cats.length - 1)]
    // everything that can show, in order; it fills ring 1, then 2, then 3 (28 slots)
    readonly property int slots: 28
    readonly property var ringStart: [0, 7, 16]
    readonly property var flat: results ? results.map(appItem)
        : (curCat ? curCat.apps : []).map(appItem)
    // categories turn (search results stay put); the loop is as long as the list
    readonly property bool spins: !results && !!curCat && flat.length > 1
    function wrap(i, n) { return ((i % n) + n) % n }
    // what sits on each ring right now (after turning)
    readonly property var ringData: {
        const n = flat.length, rot = []
        for (let i = 0; i < Math.min(n, slots); i++) rot.push(flat[spins ? wrap(spin + i, n) : i])
        return [rot.slice(0, 7), rot.slice(7, 16), rot.slice(16, 28), powerActions.map(powerItem)]   // [3] = power row
    }
    readonly property var selItem: selRing >= 0 && ringData[selRing] ? (ringData[selRing][selIndex] || null) : null

    // ---- actions ------------------------------------------------------------------------
    Process { id: runner }
    Timer { id: disarm; interval: 3000; onTriggered: menu.armed = "" }
    function activate(it) {
        if (!it) return
        if (it.entry) { it.entry.execute(); root.launcherOpen = false; return }
        const a = it.action
        if (a.confirm && armed !== a.name) { armed = a.name; disarm.restart(); return }
        armed = ""
        runner.command = a.cmd
        runner.running = true
        root.launcherOpen = false
    }
    function setCategory(i) {
        i = Math.max(0, Math.min(cats.length - 1, i))
        if (i === cat) return
        cat = i; spin = 0; armed = ""
        selRing = -1; selIndex = -1
    }
    function select(k, i) {
        if (k < 0 || !ringData[k] || i < 0 || i >= ringData[k].length) { selRing = -1; selIndex = -1; return }
        if (selRing !== k || selIndex !== i) armed = ""
        selRing = k; selIndex = i
    }
    function selectAt(k, i) { select(k, i) }
    function selectFirst() {
        for (let k = 0; k < 3; k++) if (ringData[k].length) { select(k, 0); return }
        select(-1, -1)
    }
    // the slot on ring k whose angle is closest to angle a
    function nearestOnRing(k, a) {
        const n = ringData[k].length
        if (!n) return -1
        const i = Math.round((ringA1(k) - a) / (ringA1(k) - ringA0(k)) * rings[k].cap - 0.5)
        return Math.max(0, Math.min(n - 1, i))
    }
    function turn(d) { if (spins) spin += d }

    // ---- sand-grain backdrop: the bar's wave, bent around the orb --------------------------
    property real time: 0
    property bool hovered: false     // pointer over the fan
    property real pointerA: 0        // pointer angle around the orb
    property real mouseA: 0          // smoothed, drives the swell on the rim
    property real hov: 0
    // every frame while opening / closing or the rim is swelling under the pointer; a plain 30fps
    // timer once settled (a FrameAnimation keeps the render loop spinning at full rate)
    readonly property bool busy: openAnim.running || closeAnim.running || hovered || hov > 0.01
    // The shader runs on the bar's wave clock so its grains line up with the bar's. But the bar only
    // ticks that clock at 30fps unless the pointer is on it, so mid-open the slosh would move every
    // other frame while the rise moves every frame, and the open stutters. So while busy the menu
    // keeps its own clock: it steps by the frame time every frame and is pulled gently toward the
    // bar's (extrapolated past its last tick), so it never stalls and never drifts off the bar's.
    property real waveClock: 0
    property real seenWave: -1
    property real waveAhead: 0
    function advance(dt, smooth) {
        const raw = dt
        dt = Math.min(dt, 0.05)
        menu.time += dt
        menu.hov += ((menu.hovered ? 1 : 0) - menu.hov) * Math.min(1, dt * 6)
        if (menu.hovered) menu.mouseA += (menu.pointerA - menu.mouseA) * Math.min(1, dt * 12)
        const w = menu.root.waveTime
        if (w !== menu.seenWave) { menu.seenWave = w; menu.waveAhead = 0 } else menu.waveAhead += raw
        const target = w + Math.min(menu.waveAhead, 0.05)
        const next = menu.waveClock + raw
        menu.waveClock = !smooth || Math.abs(target - next) > 0.1 ? target
            : Math.max(menu.waveClock, next + (target - next) * 0.25)
    }
    FrameAnimation { running: menu.shown && menu.busy; onTriggered: menu.advance(frameTime, true) }
    Timer { interval: 33; repeat: true; running: menu.shown && !menu.busy; onTriggered: menu.advance(0.033, false) }
    // The wallpaper, laid out like Plasma's "scaled and cropped". Where the menu grows out over
    // windows it shows this behind its grains, so it looks exactly like the bar (which has the real
    // wallpaper behind it) instead of a band of bar in front of a lump over your windows.
    FileView {
        id: plasmaCfg
        path: Quickshell.env("HOME") + "/.config/plasma-org.kde.plasma.desktop-appletsrc"
        watchChanges: true
        onFileChanged: reload()
        printErrors: false
    }
    readonly property string wallpaper: {
        const m = plasmaCfg.text().match(/^Image=(.*)$/gm)          // last one wins (the newest desktop)
        if (!m) return ""
        const v = m[m.length - 1].slice(6).trim()
        return v.startsWith("file://") || v.startsWith("/") ? (v.startsWith("/") ? "file://" + v : v) : ""
    }
    Image {
        id: wallImg
        anchors.fill: parent
        source: menu.wallpaper
        fillMode: Image.PreserveAspectCrop
        sourceSize: Qt.size(menu.width, menu.height)    // decode at screen size, not the file's
        asynchronous: true
    }
    ShaderEffectSource { id: wallTex; sourceItem: wallImg; hideSource: true; live: false; recursive: false
                         onSourceItemChanged: scheduleUpdate() }
    Connections { target: wallImg; function onStatusChanged() { wallTex.scheduleUpdate() } }
    // the menu (and its mound, lumps, swell and fillet) never reach past this box in the bottom-left,
    // so the shader and text glow only cover it instead of the whole screen
    readonly property real boxW: ox + band[1] + 16 + 220
    readonly property real boxH: band[1] + 16 + 220 + (height - oy)
    ShaderEffect {
        x: 0; y: menu.height - menu.boxH
        width: menu.boxW; height: menu.boxH
        fragmentShader: "shaders/fan.frag.qsb"
        property vector2d size: Qt.vector2d(width, height)
        property vector2d offset: Qt.vector2d(x, y)
        property vector2d screen: Qt.vector2d(menu.width, menu.height)
        property vector2d origin: Qt.vector2d(menu.ox, menu.oy)
        property vector4d seams: Qt.vector4d(menu.hubR + 4, (menu.rings[0].r1 + menu.rings[1].r0) / 2,
                                             (menu.rings[1].r1 + menu.rings[2].r0) / 2, menu.band[0] - 3)
        property real rOut: menu.band[1] + 16
        property real reveal: menu.reveal
        property real level: menu.level
        property real growR: menu.growR
        // it draws the bar's own grain field, so these match DotSurface / Bar.qml exactly
        property real time: menu.waveClock
        property real cell: 2.6
        property real dotSize: 1.6
        property real flow: 1.8
        property real wave: 1
        property real rimWave: 1.4
        property real mouseA: menu.mouseA
        property real hover: menu.hov
        property real barTop: menu.height - 46       // Bar.qml's barH
        property real barWinTop: menu.height - 130   // Bar.qml's headroom + barH
        property real zoneTop: menu.height - 60      // Bar.qml's exclusive zone: windows stop here
        property var wall: wallTex
        property real hasWall: wallImg.status === Image.Ready ? 1 : 0
        property color gradA: menu.root.gooA
        property color gradB: menu.root.gooB
        property color grainM: menu.root.grainM
        property color grainC: menu.root.grainC
        property color grainY: menu.root.grainY
        property color backing: "#ee080910"     // dark body so icons and text stay readable
    }

    // ---- building blocks -------------------------------------------------------------------
    // a filled ring slice between radii r0..r1 and angles b0..b1
    component Slice: Shape {
        id: sl
        property real r0
        property real r1
        property real b0
        property real b1
        property color fill
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeWidth: -1
            fillColor: sl.fill
            startX: menu.px(sl.r1, sl.b0); startY: menu.py(sl.r1, sl.b0)
            PathArc { x: menu.px(sl.r1, sl.b1); y: menu.py(sl.r1, sl.b1); radiusX: sl.r1; radiusY: sl.r1; direction: PathArc.Counterclockwise }
            PathLine { x: menu.px(sl.r0, sl.b1); y: menu.py(sl.r0, sl.b1) }
            PathArc { x: menu.px(sl.r0, sl.b0); y: menu.py(sl.r0, sl.b0); radiusX: sl.r0; radiusY: sl.r0 }
            PathLine { x: menu.px(sl.r1, sl.b0); y: menu.py(sl.r1, sl.b0) }
        }
    }
    // a stroked arc at radius r from angle b0 to b1
    component Arc: Shape {
        id: ar
        property real r
        property real b0
        property real b1
        property color stroke
        property real lineWidth: 2
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            fillColor: "transparent"
            strokeColor: ar.stroke
            strokeWidth: ar.lineWidth
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: menu.ox; centerY: menu.oy
                radiusX: ar.r; radiusY: ar.r
                startAngle: -menu.deg(ar.b1)
                sweepAngle: menu.deg(ar.b1 - ar.b0)
            }
        }
    }
    // text laid letter by letter along an arc, reading clockwise, centred on angle `at`
    component ArcText: Item {
        id: atx
        property string text
        property real r
        property real at
        property color color: "white"
        property real tracking: 1.2         // extra px between letters
        property int pixelSize: 14
        anchors.fill: parent
        FontMetrics { id: fm; font.family: menu.font; font.pixelSize: atx.pixelSize; font.capitalization: Font.AllUppercase }
        // where each letter's centre sits along the arc, from each letter's real width
        readonly property var centres: {
            const out = []
            let x = 0
            for (let i = 0; i < text.length; i++) {
                const w = fm.advanceWidth(text[i])
                out.push(x + w / 2); x += w + tracking
            }
            out.push(x - tracking)           // total length last
            return out
        }
        Repeater {
            model: atx.text.length
            MenuText {
                required property int index
                readonly property real a: atx.at + (atx.centres[atx.text.length] / 2 - atx.centres[index]) / atx.r
                readonly property real rise: menu.riseVis(atx.r * Math.sin(a), atx.r)
                x: menu.px(atx.r, a) - width / 2
                y: menu.py(atx.r, a) - height / 2 + menu.bob(rise) * 0.7
                opacity: rise
                rotation: 90 - menu.deg(a)
                text: atx.text[index]
                color: atx.color
                font.pixelSize: atx.pixelSize
                Behavior on color { ColorAnimation { duration: 160 } }
            }
        }
    }

    // ---- category band -----------------------------------------------------------------------
    Item {
        id: bandLayer
        anchors.fill: parent
        opacity: menu.results ? 0.25 : 1
        Behavior on opacity { NumberAnimation { duration: 160 } }
        readonly property real segW: (menu.a1 - menu.a0) / menu.cats.length
        function segB1(j) { return menu.a1 - j * segW }
        function segB0(j) { return menu.a1 - (j + 1) * segW }

        // the current category: a soft slice plus an accent line along the rim that glides over
        // (shows once the surface has risen past it)
        Item {
            anchors.fill: parent
            opacity: menu.riseVis(menu.band[1] * Math.sin((bandLayer.segB0(menu.cat) + bandLayer.segB1(menu.cat)) / 2), menu.band[1])
        Slice {
            r0: menu.band[0]; r1: menu.band[1]
            b0: bandLayer.segB0(menu.cat) + 0.004; b1: bandLayer.segB1(menu.cat) - 0.004
            fill: "#1fffffff"
            Behavior on b0 { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            Behavior on b1 { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        }
        Arc {
            r: menu.band[1] - 1.5; lineWidth: 3
            b0: bandLayer.segB0(menu.cat) + 0.012; b1: bandLayer.segB1(menu.cat) - 0.012
            stroke: "#c9c2ff"
            Behavior on b0 { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            Behavior on b1 { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        }
        }
        Item {
            id: bandHalo
            x: 0; y: menu.height - menu.boxH; width: menu.boxW; height: menu.boxH   // glow buffer only as big as the menu
            layer.enabled: true
            layer.effect: Halo {}
        Item {
            y: -bandHalo.y; width: menu.width; height: menu.height
        Repeater {
            model: menu.cats.length
            ArcText {
                required property int index
                r: (menu.band[0] + menu.band[1]) / 2
                at: (bandLayer.segB0(index) + bandLayer.segB1(index)) / 2
                text: menu.cats[index].name
                color: index === menu.cat ? "white" : "#c8ffffff"
            }
        }
        }
        }
    }

    // ---- selection highlight: glides from slot to slot ---------------------------------------
    Item {
        id: hl
        anchors.fill: parent
        visible: menu.selItem !== null && menu.selRing < 3
        readonly property int k: Math.min(2, Math.max(0, menu.selRing))
        readonly property real c: menu.slotAngle(k, Math.max(0, menu.selIndex))
        readonly property real h: menu.slotSpan(k) / 2
        property real r0: menu.rings[k].r0
        property real r1: menu.rings[k].r1
        property real b0: c - h
        property real b1: c + h
        Behavior on r0 { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Behavior on r1 { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Behavior on b0 { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Behavior on b1 { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Slice { r0: hl.r0 + 3; r1: hl.r1 - 3; b0: hl.b0 + 0.006; b1: hl.b1 - 0.006
                fill: menu.armed ? "#40e24b4a" : "#1affffff" }
        Arc { r: hl.r1 - 3; lineWidth: 2; b0: hl.b0 + 0.02; b1: hl.b1 - 0.02
              stroke: menu.armed ? "#f09595" : "#c9c2ff" }
    }

    // ---- the rings of icons: one carousel through all three rings ------------------------------------
    // Each item has a place g along the path (0..27 visible). Moving past the end of a ring it fades
    // out and fades back in at the start of the next, and the loop wraps out of sight.
    Repeater {
        model: menu.flat
        delegate: Item {
            id: slot
            required property var modelData
            required property int index
            readonly property int n: menu.flat.length
            readonly property real g: {
                if (!menu.spins) return index
                const x = menu.wrap(index - menu.spinS, n)
                return x > n - 0.5 ? x - n : x
            }
            readonly property int k: g < 6.5 ? 0 : g < 15.5 ? 1 : 2
            readonly property real u: g - menu.ringStart[k]                 // place along ring k
            readonly property int at: Math.round(u)
            // 1 on the ring, fading to 0 half a slot past either end (or past the end of a short list)
            readonly property real edge: Math.max(0, Math.min(1, 2 * Math.min(u + 0.5, menu.rings[k].cap - 0.5 - u, n - 0.5 - g)))
            visible: edge > 0
            readonly property bool sel: menu.selRing === k && menu.selIndex === at && edge > 0.5
            readonly property bool near: menu.selRing === k && Math.abs(menu.selIndex - at) === 1
            readonly property real a: menu.slotAngle(k, u)
            readonly property real r: menu.mid(k)
            // floats up into place as the surface rises past it, each a little early or late
            readonly property real jitter: (Math.sin(index * 12.9898) * 43758.5453 % 1) * 36
            readonly property real rv: menu.riseVis(r * Math.sin(a) + jitter, r + jitter)
            width: menu.rings[k].size; height: width
            x: menu.px(r, a) - width / 2
            y: menu.py(r, a) - height / 2 + menu.bob(rv)
            property real pop: 0
            opacity: rv * pop * edge
            scale: (0.7 + 0.3 * pop) * menu.popScale(rv) * (sel ? 1.32 : near ? 1.1 : 1)
            Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
            // new content (category / search changes) pops in along the arc
            NumberAnimation { id: popAnim; target: slot; property: "pop"; from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic }
            Timer { interval: 12 + Math.min(slot.index, 28) * 16; running: true; onTriggered: popAnim.start() }

            IconImage {
                anchors.fill: parent
                source: Quickshell.iconPath(slot.modelData.icon, "application-x-executable")
            }
        }
    }

    // ---- power cluster: always there, bobbing gently like the bar's icons ------------------------------
    Repeater {
        model: menu.powerActions.length
        delegate: Item {
            id: pw
            required property int index
            readonly property var act: menu.powerActions[index]
            readonly property bool sel: menu.selRing === 3 && menu.selIndex === index
            readonly property bool armedHere: menu.armed === act.name
            readonly property var spot: menu.powerSpots[index]
            readonly property real rv: menu.riseVis(spot.h, Math.hypot(spot.x - menu.ox, spot.h))
            width: spot.size; height: spot.size
            x: spot.x - width / 2 + Math.sin(menu.time * 0.9 + index * 2.3) * 1.2
            y: menu.oy - spot.h - height / 2 + Math.sin(menu.time * 1.3 + index * 1.7) * 2 + menu.bob(rv)
            rotation: Math.sin(menu.time * 1.1 + index * 1.3) * 4
            opacity: rv
            scale: menu.popScale(rv) * (sel ? 1.3 : 1)
            Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
            Rectangle {
                anchors.centerIn: parent
                width: pw.width + 8; height: width; radius: width / 2
                color: pw.armedHere ? "#55e24b4a" : "#22ffffff"
                opacity: pw.sel || pw.armedHere ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 140 } }
            }
            IconImage {
                anchors.fill: parent
                source: Quickshell.iconPath(pw.act.icon, "application-x-executable")
            }
        }
    }

    // ---- hub: what's selected / the search / where you are ------------------------------------------
    Column {
        x: menu.ox + 8
        y: menu.oy - 170
        width: 104
        spacing: 3
        opacity: menu.riseVis(140, 150)
        layer.enabled: true
        layer.effect: Halo {}

        // selected item
        Row {
            visible: menu.selItem !== null
            spacing: 6
            IconImage { implicitSize: 18; source: menu.selItem ? Quickshell.iconPath(menu.selItem.icon, "application-x-executable") : ""; anchors.verticalCenter: parent.verticalCenter }
            MenuText {
                width: 80
                text: menu.selItem ? menu.selItem.name : ""
                color: "white"; font.pixelSize: 14
                elide: Text.ElideRight
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        MenuText {
            visible: menu.selItem !== null
            width: parent.width
            text: menu.selItem ? menu.selItem.desc : ""
            color: "#c8ffffff"; font.pixelSize: 12
            elide: Text.ElideRight
        }
        MenuText {
            visible: menu.selItem !== null
            text: menu.armed ? "press again" : "↵ open"
            color: menu.armed ? "#f09595" : "#aaffffff"; font.pixelSize: 12
        }

        // nothing selected: search, or the category you're in
        MenuText {
            visible: menu.selItem === null
            width: parent.width
            text: menu.query ? "⌕ " + menu.query : (menu.curCat ? menu.curCat.name : "")
            color: "white"; font.pixelSize: menu.query ? 15 : 17
            elide: Text.ElideLeft
        }
        MenuText {
            visible: menu.selItem === null
            width: parent.width
            text: menu.results ? (menu.results.length ? menu.results.length + (menu.results.length === 1 ? " match" : " matches") : "nothing found")
                : menu.spins ? menu.flat.length + " apps · scroll" 
                : "type to search"
            color: "#c0ffffff"; font.pixelSize: 12
            wrapMode: Text.WordWrap
        }
    }

    // ---- input -------------------------------------------------------------------------------------------
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        z: -1
        function polar(x, y) {
            const dx = x - menu.ox, dy = menu.oy - y
            return { d: Math.sqrt(dx * dx + dy * dy), a: Math.atan2(dy, dx) }
        }
        onExited: menu.hovered = false
        onPositionChanged: m => {
            const p = polar(m.x, m.y)
            menu.hovered = p.d <= menu.band[1] + 60 && p.a >= -0.05 && p.a <= Math.PI / 2 + 0.05
            if (menu.hovered) menu.pointerA = p.a
            const pi = menu.powerAt(m.x, m.y)
            if (pi >= 0) { menu.select(3, pi); return }
            if (p.a < -0.05 || p.a > Math.PI / 2 + 0.3) return
            if (p.d >= menu.band[0] - 2 && p.d <= menu.band[1] + 6) {
                if (!menu.results) menu.setCategory(Math.floor((menu.a1 - p.a) / (menu.a1 - menu.a0) * menu.cats.length))
                return
            }
            for (let k = 0; k < 3; k++) {
                const R = menu.rings[k]
                if (p.d >= R.r0 - 3 && p.d <= R.r1 + 3) {
                    const i = Math.floor((menu.ringA1(k) - p.a) / (menu.ringA1(k) - menu.ringA0(k)) * R.cap)
                    if (i >= 0 && i < menu.ringData[k].length) menu.select(k, i)
                    else menu.select(-1, -1)
                    return
                }
            }
            if (p.d < menu.hubR) return            // keep the selection while reading the hub
            menu.select(-1, -1)
        }
        onClicked: m => {
            const p = polar(m.x, m.y)
            const insideFan = p.d <= menu.band[1] + 32 && p.a >= -0.1 && p.a <= Math.PI / 2 + 0.4
            if (!insideFan) { menu.root.launcherOpen = false; return }
            const onPower = menu.selRing === 3 && menu.powerAt(m.x, m.y) === menu.selIndex
            if (menu.selItem && (p.d > menu.hubR || onPower)) menu.activate(menu.selItem)
        }
        onWheel: w => menu.turn(w.angleDelta.y < 0 ? 2 : -2)
    }

    Item {
        id: keys
        focus: true
        Keys.onPressed: e => {
            const k = menu.selRing
            if (e.key === Qt.Key_Escape) {
                if (menu.query) { menu.query = ""; menu.select(-1, -1) } else menu.root.launcherOpen = false
            } else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                if (!menu.selItem) menu.selectFirst()
                menu.activate(menu.selItem)
            } else if (e.key === Qt.Key_Backspace) {
                menu.query = menu.query.slice(0, -1)
                if (menu.query) menu.selectFirst(); else menu.select(-1, -1)
            } else if (e.key === Qt.Key_Tab || e.key === Qt.Key_Backtab) {
                if (!menu.results) {
                    const n = menu.cats.length
                    menu.setCategory(((menu.cat + (e.key === Qt.Key_Backtab ? -1 : 1)) % n + n) % n)
                }
            } else if (e.key === Qt.Key_PageDown) { menu.turn(7) }
            else if (e.key === Qt.Key_PageUp) { menu.turn(-7) }
            else if (e.key === Qt.Key_Left || e.key === Qt.Key_Right) {
                if (k < 0) { menu.selectFirst() }
                else {
                    const n = menu.ringData[k].length
                    menu.select(k, Math.max(0, Math.min(n - 1, menu.selIndex + (e.key === Qt.Key_Right ? 1 : -1))))
                }
            } else if (e.key === Qt.Key_Up || e.key === Qt.Key_Down) {
                if (k < 0) { menu.selectFirst() }
                else if (k === 3) { if (e.key === Qt.Key_Up) menu.selectFirst() }      // power row sits below ring 1
                else {
                    const a = menu.slotAngle(k, menu.selIndex)
                    let t = k + (e.key === Qt.Key_Up ? 1 : -1)
                    while (t >= 0 && t < 3 && !menu.ringData[t].length) t += (e.key === Qt.Key_Up ? 1 : -1)
                    if (t >= 0 && t < 3) menu.select(t, menu.nearestOnRing(t, a))
                    else if (t < 0) menu.select(3, 0)
                }
            } else if (e.text && e.text.length === 1 && e.text >= " ") {
                menu.query += e.text
                menu.selectFirst()
            } else return
            e.accepted = true
        }
    }
}
