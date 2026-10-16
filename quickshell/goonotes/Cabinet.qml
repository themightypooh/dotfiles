// The file cabinet: a steel cabinet on the desktop, seen in a steep 3/4 view (from above and to the
// right: the fronts stay flat so their text is crisp, the top and the right side show its depth),
// drawn like Amiga AGA pixel art: a small fixed palette (a steel ramp, oranges, paper, the note
// colours), chunky pixels, ordered dithering for shading and a dithered drop shadow (Dither.qml,
// shaders/aga.frag). One drawer per category (the first three).
// While a note is being dragged every drawer cracks open a little, and the one under the pointer
// slides further out; let go over it to file the note there and put it away.
// Hover a drawer and it slides out toward you (down and to the left) with the notes filed in it
// standing up like file folders, one title per tab; the wheel riffles through a full drawer, click a
// tab to take that note out. Click a drawer front to browse it in the notes drawer; right-click it
// to rename the drawer. Drag the top of the cabinet to move it.
// The mouse is hit-tested by hand against where things are going to be, not where an animation has
// them right now, so a drawer sliding under a still pointer never flickers open and shut.
import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: cab
    required property var app

    // ---- AGA-style palette: everything drawn below is dithered into these (max 32) -------------
    readonly property color pWhite: "#f4f5f6"
    readonly property color pBlack: "#141418"
    readonly property color pOrange: "#ff8800"
    readonly property var aga: app.aga
    // the palette as a texture strip, one texel per colour, for the dither shader
    Row {
        id: palStrip
        Repeater { model: cab.aga; Rectangle { required property string modelData; width: 1; height: 1; color: modelData } }
    }
    ShaderEffectSource {
        id: palTex
        sourceItem: palStrip
        hideSource: true
        smooth: false
        textureSize: Qt.size(cab.aga.length, 1)
        width: 1; height: 1; visible: false
    }
    readonly property real chunk: 2              // size of one chunky pixel
    readonly property string pixelFont: "monospace"

    // ---- shape -----------------------------------------------------------------------
    // Oblique projection: one unit of depth (away from you) is kx right and ky up on screen.
    readonly property real kx: 0.28
    readonly property real ky: 0.72
    readonly property real fw: 180               // front face
    readonly property real fh: 300
    readonly property real depth: 90
    readonly property real sideW: Math.round(depth * kx)   // the right side, seen past the front
    readonly property real topH: Math.round(depth * ky)    // the top, seen from above
    readonly property real pad: 10               // inset of the drawers inside the front
    readonly property real gap: 12
    readonly property int count: 3
    readonly property real dh: Math.round((fh - pad * 2 - gap * (count - 1)) / count)
    // how far a drawer comes out, in depth units
    readonly property real dragOut: 50           // under a dragged note
    readonly property real crackOut: 10          // a note is being dragged nearby / hovering an empty drawer
    readonly property real hoverOut: 120         // showing its files
    // file folders standing in an open drawer: each one further back sits up and to the right
    readonly property int maxFiles: 6
    readonly property real fileStep: (hoverOut - 16) / (maxFiles - 1)
    readonly property real tabH: 14
    readonly property real stagger: 30           // every other tab sits this far right
    readonly property real shadow: 8             // drop shadow offset
    // where the front face's top-left sits inside the window: room on the left and below for a
    // drawer pulled out, above for the top
    readonly property real ox: Math.round(hoverOut * kx) + 12
    readonly property real oy: topH + 6

    // ---- place on the desktop: same coordinates as the notes (top-left of the screen) ------
    readonly property int maxX: (screen ? screen.width : 1920) - implicitWidth
    readonly property int maxY: (screen ? screen.height : 1080) - implicitHeight
    function clampX(x) { return Math.max(0, Math.min(maxX, x)) }
    function clampY(y) { return Math.max(0, Math.min(maxY, y)) }
    property int px: clampX((app.cabinet && app.cabinet.x !== undefined) ? app.cabinet.x : maxX - 60)
    property int py: clampY((app.cabinet && app.cabinet.y !== undefined) ? app.cabinet.y : 140)
    screen: app.screenFor("")
    visible: app.shown
    color: "transparent"
    anchors { top: true; left: true }
    margins { top: cab.py; left: cab.px }
    implicitWidth: ox + fw + sideW + shadow + 6
    implicitHeight: oy + fh + Math.round(hoverOut * ky) + shadow + 8
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "goonotes-cabinet"
    WlrLayershell.layer: app.cabinetPeek ? WlrLayer.Top : WlrLayer.Bottom
    // takes the keyboard when clicked, so a right-click can go straight into renaming a drawer
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    // ---- geometry, in window coords, for a drawer pulled `out` depth units ------------------
    function snap(v) { return Math.round(v / chunk) * chunk }
    function slotX() { return ox + pad }
    function slotY(i) { return oy + pad + i * (dh + gap) }
    readonly property real slotW: fw - pad * 2
    function frontX(out) { return slotX() - snap(out * kx) }
    function frontY(i, out) { return slotY(i) + snap(out * ky) }
    // folder k (0 = the front one) of a drawer whose front is at (fx, fy)
    function folderAt(fx, fy, k) {
        const t = 10 + k * fileStep
        const bx = fx + 6 + snap(t * kx), by = fy - snap(t * ky)
        return { t: t, bx: bx, by: by, w: slotW - 12, tx: bx + (k % 2) * stagger, tw: slotW - 12 - stagger }
    }
    // everything an open drawer covers: its front, its open top and side, the folders in it
    function openBox(i) {
        const fx = frontX(hoverOut), fy = frontY(i, hoverOut)
        return { x: fx, y: slotY(i) - 24, w: slotX() + slotW - fx, h: fy + dh - (slotY(i) - 24) }
    }
    function inside(x, y, r) { return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h }

    // only the cabinet itself (and an open drawer) catch the mouse; the empty corners of the
    // window are click-through to the desktop
    mask: Region {
        item: bodyHit
        Region { item: openHit }
    }
    Item { id: bodyHit; x: cab.ox; y: cab.oy - cab.topH; width: cab.fw + cab.sideW; height: cab.topH + cab.fh + 6 }
    Item {
        id: openHit
        readonly property var r: cab.hoverIdx >= 0 && drawers.itemAt(cab.hoverIdx) && drawers.itemAt(cab.hoverIdx).showing ? cab.openBox(cab.hoverIdx) : ({ x: 0, y: 0, w: 0, h: 0 })
        x: r.x; y: r.y; width: r.w; height: r.h
    }

    // brought up from the bar: sinks back to the desktop after 15 s without the pointer on it
    Item { anchors.fill: parent; HoverHandler { id: cabHover } }
    Timer {
        interval: 15000
        running: cab.app.cabinetPeek && !cabHover.hovered && !cab.app.drawerOpen && !cab.dragging && cab.renameIdx < 0
        onTriggered: cab.app.cabinetPeek = false
    }

    // which drawer the dragged note is over (-1 = none), from the pointer in screen coords
    function drawerAt(sx, sy) {
        const x = sx - px - ox, y = sy - py - oy
        if (x < -50 || x > fw + sideW + 30 || y < -topH - 10 || y > fh + 30) return -1
        for (let i = 0; i < count; i++) {
            const t = pad + i * (dh + gap)
            if (y >= t - gap / 2 && y <= t + dh + gap / 2) return i
        }
        return y < pad ? 0 : count - 1
    }
    readonly property bool dragging: app.dragNote !== ""
    readonly property bool near: dragging && Math.hypot(app.dragX - (px + ox + fw / 2), app.dragY - (py + oy + fh / 2)) < 420
    readonly property int target: dragging ? drawerAt(app.dragX, app.dragY) : -1
    function catFor(i) { return i < app.categories.length ? app.categories[i] : "" }
    // what a folder tab says: the note's title (note-fixes adds app.titleOf), else its first line
    function titleOf(n) {
        if (app.titleOf) return app.titleOf(n)
        const t = (n.title || "").trim()
        if (t) return t
        return ((n.text || "").split("\n").find(l => l.trim()) || "untitled").trim()
    }

    // let go of a note over a drawer: file it and put it away
    Connections {
        target: cab.app
        function onNoteDropped(id, sx, sy) {
            const i = cab.drawerAt(sx, sy)
            if (i < 0 || !cab.catFor(i)) return
            cab.app.setCategory(id, cab.catFor(i))
            cab.app.stash(id, true)
            cab.thunk = i; thunkAnim.restart()
        }
        // put away from the note's close button: bump the drawer for its category, if it has one here
        function onPutAway(id) {
            const c = (cab.app.store[id] || {}).category || ""
            const i = c ? cab.app.categories.indexOf(c) : -1
            if (i >= 0) { cab.thunk = i; thunkAnim.restart() }
        }
    }
    property int thunk: -1          // the drawer that just took a note: it shuts with a little bump
    property real bump: 0
    SequentialAnimation {
        id: thunkAnim
        NumberAnimation { target: cab; property: "bump"; from: 0; to: 1; duration: 90 }
        NumberAnimation { target: cab; property: "bump"; to: 0; duration: 380; easing.type: Easing.OutBack }
    }

    // ---- renaming: right-click a drawer front ---------------------------------------------
    property int renameIdx: -1
    function finishRename(text) {
        const i = renameIdx
        renameIdx = -1
        if (i < 0) return
        const old = catFor(i)
        if (old) app.renameCategory(old, text)
        else app.addCategory(text)   // an empty drawer: becomes a new category
    }

    // ---- the carcass: shadow, top, right side, front ------------------------------------
    Item {
        anchors.fill: parent
        layer.enabled: true
        layer.smooth: false
        layer.effect: Dither { px: cab.chunk; pal: palTex; count: cab.aga.length }

        Shape {
            anchors.fill: parent
            // dithered drop shadow: the cabinet's outline, pushed down and right
            ShapePath {
                strokeWidth: -1
                fillColor: Qt.rgba(0, 0, 0, 0.5)
                startX: cab.ox + cab.shadow; startY: cab.oy + cab.fh + cab.shadow
                PathLine { x: cab.ox + cab.shadow; y: cab.oy + cab.shadow }
                PathLine { x: cab.ox + cab.sideW + cab.shadow; y: cab.oy - cab.topH + cab.shadow }
                PathLine { x: cab.ox + cab.fw + cab.sideW + cab.shadow; y: cab.oy - cab.topH + cab.shadow }
                PathLine { x: cab.ox + cab.fw + cab.sideW + cab.shadow; y: cab.oy + cab.fh - cab.topH + cab.shadow }
                PathLine { x: cab.ox + cab.fw + cab.shadow; y: cab.oy + cab.fh + cab.shadow }
            }
            // right side: in shade
            ShapePath {
                strokeColor: cab.pBlack; strokeWidth: 2; joinStyle: ShapePath.MiterJoin
                fillGradient: LinearGradient {
                    x1: 0; y1: cab.oy - cab.topH; x2: 0; y2: cab.oy + cab.fh
                    GradientStop { position: 0; color: "#8f949a" }
                    GradientStop { position: 1; color: "#42454b" }
                }
                startX: cab.ox + cab.fw; startY: cab.oy
                PathLine { x: cab.ox + cab.fw + cab.sideW; y: cab.oy - cab.topH }
                PathLine { x: cab.ox + cab.fw + cab.sideW; y: cab.oy + cab.fh - cab.topH }
                PathLine { x: cab.ox + cab.fw; y: cab.oy + cab.fh }
                PathLine { x: cab.ox + cab.fw; y: cab.oy }
            }
            // top, lit from above: brightest at the front edge
            ShapePath {
                strokeColor: cab.pBlack; strokeWidth: 2; joinStyle: ShapePath.MiterJoin
                fillGradient: LinearGradient {
                    x1: 0; y1: cab.oy - cab.topH; x2: 0; y2: cab.oy
                    GradientStop { position: 0; color: "#c5c8cc" }
                    GradientStop { position: 1; color: "#eceef0" }
                }
                startX: cab.ox; startY: cab.oy
                PathLine { x: cab.ox + cab.sideW; y: cab.oy - cab.topH }
                PathLine { x: cab.ox + cab.fw + cab.sideW; y: cab.oy - cab.topH }
                PathLine { x: cab.ox + cab.fw; y: cab.oy }
                PathLine { x: cab.ox; y: cab.oy }
            }
        }
        // front: steel, darkening toward the floor
        Rectangle {
            x: cab.ox; y: cab.oy; width: cab.fw; height: cab.fh
            border.color: cab.pBlack; border.width: 2
            gradient: Gradient {
                GradientStop { position: 0; color: "#b6babe" }
                GradientStop { position: 0.7; color: "#8c9096" }
                GradientStop { position: 1; color: "#5d6166" }
            }
        }
        // bevel: white on the top-left edges, black on the bottom-right
        Rectangle { x: cab.ox + 2; y: cab.oy + 2; width: cab.fw - 4; height: 2; color: cab.pWhite }
        Rectangle { x: cab.ox + 2; y: cab.oy + 2; width: 2; height: cab.fh - 4; color: cab.pWhite }
        Rectangle { x: cab.ox + 2; y: cab.oy + cab.fh - 4; width: cab.fw - 4; height: 2; color: cab.pBlack }
        Rectangle { x: cab.ox + cab.fw - 4; y: cab.oy + 2; width: 2; height: cab.fh - 4; color: cab.pBlack }
        // sheen on the steel: soft highlights that dither out to sparse white
        Rectangle { x: cab.ox + 22; y: cab.oy + 4; width: 14; height: cab.fh - 8; color: Qt.rgba(1, 1, 1, 0.22) }
        Rectangle { x: cab.ox + 40; y: cab.oy + 4; width: 5; height: cab.fh - 8; color: Qt.rgba(1, 1, 1, 0.15) }
        Rectangle { x: cab.ox + cab.fw - 30; y: cab.oy + 4; width: 10; height: cab.fh - 8; color: Qt.rgba(0, 0, 0, 0.12) }
        // feet
        Rectangle { x: cab.ox + 8; y: cab.oy + cab.fh; width: 18; height: 6; color: cab.pBlack }
        Rectangle { x: cab.ox + cab.fw - 26; y: cab.oy + cab.fh; width: 18; height: 6; color: cab.pBlack }
    }

    // ---- the pointer ---------------------------------------------------------------------
    // One MouseArea over the whole cabinet works out what's under the pointer from the geometry
    // (pick()). The drawer you point at opens after a moment; one that's open owns everything it
    // covers, and closes a little after the pointer leaves it.
    property int hoverIdx: -1       // the drawer showing its files
    property int hoverFolder: -1    // the folder under the pointer in it (0 = front)
    property int pending: -1
    property real mx: -1e4
    property real my: -1e4
    function pick(x, y) {
        const o = hoverIdx
        if (o >= 0 && renameIdx < 0) {
            const d = drawers.itemAt(o)
            const fx = frontX(hoverOut), fy = frontY(o, hoverOut)
            if (d && d.showing) {
                for (let k = 0; k < d.n; k++) {
                    const g = folderAt(fx, fy, k)
                    if (inside(x, y, { x: g.bx, y: g.by - 22, w: g.w, h: 16 })) return { d: o, part: "folder", k: k }
                }
                if (inside(x, y, { x: fx, y: fy, w: slotW, h: dh })) return { d: o, part: "front", k: -1 }
                if (inside(x, y, openBox(o))) return { d: o, part: "inside", k: -1 }
            }
        }
        for (let i = 0; i < count; i++) {
            const d = drawers.itemAt(i)
            const out = d ? d.want : 0
            const r = { x: frontX(out) - pad, y: frontY(i, out) - gap / 2, w: slotW + pad * 2, h: dh + gap }
            if (inside(x, y, r)) return { d: i, part: "front", k: -1 }
        }
        if (inside(x, y, { x: ox, y: oy - topH, w: fw + sideW, h: topH })) return { d: -1, part: "top", k: -1 }
        return { d: -1, part: "none", k: -1 }
    }
    property var under: ({ d: -1, part: "none", k: -1 })
    function track() {
        under = pick(mx, my)
        hoverFolder = under.d === hoverIdx && under.part === "folder" ? under.k : -1
        if (dragging || renameIdx >= 0) { switchTimer.stop(); return }
        const want = under.d
        if (want === hoverIdx) { switchTimer.stop(); pending = want; return }
        if (want === pending && switchTimer.running) return
        pending = want
        // opening is quick, closing waits a little so a pointer slipping off an edge doesn't shut it
        switchTimer.interval = want < 0 ? 320 : hoverIdx < 0 ? 60 : 140
        switchTimer.restart()
    }
    Timer {
        id: switchTimer
        onTriggered: { cab.hoverIdx = cab.pending; cab.track() }
    }
    onRenameIdxChanged: if (renameIdx >= 0) hoverIdx = -1
    onDraggingChanged: if (dragging) hoverIdx = -1

    // ---- the drawers ---------------------------------------------------------------------
    Repeater {
        id: drawers
        model: cab.count
        delegate: Item {
            id: dw
            required property int index
            anchors.fill: parent
            readonly property string cat: { cab.app.rev; return cab.catFor(index) }
            readonly property int notes: { cab.app.rev; return cab.app.ids.filter(i => (cab.app.store[i] || {}).category === dw.cat && dw.cat).length }
            // notes filed (put away) in this drawer, newest first
            readonly property var files: {
                cab.app.rev
                if (!dw.cat) return []
                return cab.app.ids.map(i => cab.app.store[i])
                    .filter(n => n && n.stashed && n.category === dw.cat)
                    .sort((a, b) => (b.updated || b.created || 0) - (a.updated || a.created || 0))
            }
            // the wheel riffles through a full drawer: folders shown start this far in
            property int scroll: 0
            readonly property int maxScroll: Math.max(0, files.length - cab.maxFiles)
            onMaxScrollChanged: scroll = Math.min(scroll, maxScroll)
            onShowingChanged: if (!showing) scroll = 0
            readonly property int n: Math.min(files.length - scroll, cab.maxFiles)
            // the last (backmost) folder says how many more there are, when there are
            readonly property int more: files.length - scroll - cab.maxFiles + 1
            readonly property bool hot: cab.target === index && !!cat
            readonly property bool renaming: cab.renameIdx === index
            readonly property bool pointed: cab.under.d === index && cab.renameIdx < 0 && !cab.dragging
            readonly property bool showing: cab.hoverIdx === index && !cab.dragging && files.length > 0 && !renaming
            // how far out it should be, in depth units
            readonly property real want: hot ? cab.dragOut
                : showing ? cab.hoverOut
                : (cab.near && cat) || (cab.hoverIdx === index && !cab.dragging && !renaming) ? cab.crackOut : 0
            property real slide: want
            Behavior on slide { SpringAnimation { spring: 4; damping: 0.45; epsilon: 0.2 } }
            readonly property real out: Math.max(0, slide - (cab.thunk === index ? cab.bump * 8 : 0))
            readonly property real sx: cab.slotX()
            readonly property real sy: cab.slotY(index)
            readonly property real fx: cab.frontX(out)
            readonly property real fy: cab.frontY(index, out)
            z: out > 0.5 || renaming ? 2 + out / 1000 : 1

            // ---- art, dithered ----
            Item {
                anchors.fill: parent
                layer.enabled: true
                layer.smooth: false
                layer.effect: Dither { px: cab.chunk; pal: palTex; count: cab.aga.length }

                // the black slot it slides out of
                Rectangle { x: dw.sx; y: dw.sy; width: cab.slotW; height: cab.dh; color: cab.pBlack }
                Shape {
                    anchors.fill: parent
                    visible: dw.out > 0.5
                    // looking down into it: dark, lighter toward you
                    ShapePath {
                        strokeColor: cab.pBlack; strokeWidth: 2; joinStyle: ShapePath.MiterJoin
                        fillGradient: LinearGradient {
                            x1: 0; y1: dw.sy; x2: 0; y2: dw.fy
                            GradientStop { position: 0; color: "#141418" }
                            GradientStop { position: 1; color: "#42454b" }
                        }
                        startX: dw.fx; startY: dw.fy
                        PathLine { x: dw.sx; y: dw.sy }
                        PathLine { x: dw.sx + cab.slotW; y: dw.sy }
                        PathLine { x: dw.fx + cab.slotW; y: dw.fy }
                        PathLine { x: dw.fx; y: dw.fy }
                    }
                    // its right side
                    ShapePath {
                        strokeColor: cab.pBlack; strokeWidth: 2; joinStyle: ShapePath.MiterJoin
                        fillGradient: LinearGradient {
                            x1: 0; y1: dw.fy; x2: 0; y2: dw.fy + cab.dh
                            GradientStop { position: 0; color: "#8f949a" }
                            GradientStop { position: 1; color: "#5b5f65" }
                        }
                        startX: dw.fx + cab.slotW; startY: dw.fy
                        PathLine { x: dw.sx + cab.slotW; y: dw.sy }
                        PathLine { x: dw.sx + cab.slotW; y: dw.sy + cab.dh }
                        PathLine { x: dw.fx + cab.slotW; y: dw.fy + cab.dh }
                        PathLine { x: dw.fx + cab.slotW; y: dw.fy }
                    }
                }
                // the folders, back ones first; each comes into view as the drawer pulls it out
                Repeater {
                    model: dw.showing || dw.out > 1 ? dw.n : 0
                    Item {
                        id: fold
                        required property int index
                        readonly property int k: dw.n - 1 - index
                        readonly property var g: cab.folderAt(dw.fx, dw.fy, k)
                        readonly property bool lit: cab.hoverIdx === dw.index && cab.hoverFolder === k
                        readonly property var note: dw.files[dw.scroll + k] || ({})
                        anchors.fill: parent
                        visible: g.t <= dw.out - 4
                        // body: paper
                        Rectangle {
                            x: fold.g.bx; y: fold.g.by - 10; width: fold.g.w; height: 14
                            color: "#efeee6"; border.color: cab.pBlack; border.width: 2
                        }
                        // tab: the note's colour, white when pointed at
                        Rectangle {
                            x: fold.g.tx; y: fold.g.by - 22
                            width: fold.g.tw; height: cab.tabH
                            color: fold.lit ? cab.pWhite
                                : fold.k === dw.n - 1 && dw.more > 1 ? "#c5c8cc"
                                : cab.app.palette[(fold.note.color || 0) % cab.app.palette.length].a
                            border.color: cab.pBlack; border.width: 2
                        }
                    }
                }
                // the drawer front: bevelled steel panel
                Rectangle {
                    x: dw.fx; y: dw.fy; width: cab.slotW; height: cab.dh
                    border.color: dw.hot ? cab.pOrange : cab.pBlack; border.width: dw.hot ? 4 : 2
                    gradient: Gradient {
                        GradientStop { position: 0; color: dw.pointed || dw.hot ? "#ccd0d4" : "#adb1b6" }
                        GradientStop { position: 1; color: "#6b6f74" }
                    }
                }
                Rectangle { x: dw.fx + 2; y: dw.fy + 2; width: cab.slotW - 4; height: 2; color: cab.pWhite }
                Rectangle { x: dw.fx + 2; y: dw.fy + 2; width: 2; height: cab.dh - 4; color: cab.pWhite }
                Rectangle { x: dw.fx + 2; y: dw.fy + cab.dh - 4; width: cab.slotW - 4; height: 2; color: cab.pBlack }
                Rectangle { x: dw.fx + cab.slotW - 4; y: dw.fy + 2; width: 2; height: cab.dh - 4; color: cab.pBlack }
                // label holder: inset (black top-left, white bottom-right)
                Rectangle {
                    id: plate
                    width: Math.min(cab.slotW - 28, 120); height: 24
                    x: Math.round(dw.fx + (cab.slotW - width) / 2); y: dw.fy + 12
                    color: dw.renaming ? cab.pWhite : "#e4e3dc"
                }
                Rectangle { x: plate.x; y: plate.y; width: plate.width; height: 2; color: cab.pBlack }
                Rectangle { x: plate.x; y: plate.y; width: 2; height: plate.height; color: cab.pBlack }
                Rectangle { x: plate.x; y: plate.y + plate.height - 2; width: plate.width; height: 2; color: cab.pWhite }
                Rectangle { x: plate.x + plate.width - 2; y: plate.y; width: 2; height: plate.height; color: cab.pWhite }
                // pull handle
                Rectangle {
                    x: Math.round(dw.fx + cab.slotW / 2 - 20); y: dw.fy + cab.dh - 18; width: 40; height: 8
                    border.color: cab.pBlack; border.width: 2
                    gradient: Gradient {
                        GradientStop { position: 0; color: "#f4f5f6" }
                        GradientStop { position: 1; color: "#757980" }
                    }
                }
            }

            // ---- text, crisp ----
            Repeater {
                model: dw.showing || dw.out > 1 ? dw.n : 0
                PixelText {
                    id: tabText
                    required property int index
                    readonly property int k: dw.n - 1 - index
                    readonly property var g: cab.folderAt(dw.fx, dw.fy, k)
                    readonly property bool lit: cab.hoverIdx === dw.index && cab.hoverFolder === k
                    readonly property var note: dw.files[dw.scroll + k] || ({})
                    visible: g.t <= dw.out - 4
                    x: g.tx + 5; y: g.by - 22
                    width: g.tw - 9; height: cab.tabH
                    verticalAlignment: Text.AlignVCenter
                    text: k === dw.n - 1 && dw.more > 1 ? "+" + dw.more + " MORE" : cab.titleOf(note)
                    elide: Text.ElideRight
                    font.pixelSize: 10
                    color: cab.pBlack
                }
            }
            PixelText {
                visible: !dw.renaming
                x: dw.fx; width: cab.slotW; y: dw.fy + 12; height: 24
                horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                leftPadding: 18; rightPadding: 18
                text: (dw.cat || "empty").toUpperCase()
                elide: Text.ElideRight
                font.pixelSize: 12
                color: dw.cat ? cab.pBlack : "#7a7e84"
            }
            PixelText {
                x: dw.fx; width: cab.slotW; y: dw.fy + 42
                horizontalAlignment: Text.AlignHCenter
                text: dw.renaming ? "ENTER = OK  ESC = CANCEL"
                    : dw.cat ? (dw.files.length + " FILED" + (dw.notes > dw.files.length ? " / " + (dw.notes - dw.files.length) + " OUT" : ""))
                    : "RIGHT-CLICK TO NAME"
                font.pixelSize: 9
                color: cab.pBlack
            }
            // the name field, over the label holder while renaming
            TextInput {
                id: nameField
                visible: dw.renaming
                x: Math.round(dw.fx + (cab.slotW - width) / 2); y: dw.fy + 12
                width: Math.min(cab.slotW - 28, 120) - 12; height: 24
                verticalAlignment: TextInput.AlignVCenter
                horizontalAlignment: TextInput.AlignHCenter
                clip: true
                maximumLength: 24
                font.family: cab.pixelFont; font.bold: true; font.pixelSize: 12
                font.capitalization: Font.AllUppercase
                renderType: Text.NativeRendering
                color: cab.pBlack
                selectionColor: cab.pOrange
                selectedTextColor: cab.pBlack
                cursorDelegate: Rectangle { width: 7; color: cab.pOrange; visible: nameField.cursorVisible }
                onVisibleChanged: if (visible) { text = dw.cat; selectAll(); forceActiveFocus() }
                onAccepted: cab.finishRename(text)
                Keys.onEscapePressed: cab.renameIdx = -1
                onActiveFocusChanged: if (!activeFocus && dw.renaming) cab.renameIdx = -1
            }
        }
    }

    // Over everything; while renaming it lets clicks through to the name field and any other click
    // cancels. Dragging the top moves
    // the cabinet: the window moves under the pointer, so like dragging a note, apply the move at
    // most once a frame (after the compositor has caught up), or each move feeds into the next.
    MouseArea {
        id: hit
        anchors.fill: parent
        z: 10
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: moving ? Qt.ClosedHandCursor
            : cab.under.part === "top" ? Qt.OpenHandCursor
            : cab.under.part === "folder" || (cab.under.part === "front" && cab.catFor(cab.under.d)) ? Qt.PointingHandCursor
            : Qt.ArrowCursor
        property bool moving: false
        property real sx: 0
        property real sy: 0
        property bool dirty: false
        onPositionChanged: m => {
            if (moving) { dirty = true; return }
            cab.mx = m.x; cab.my = m.y; cab.track()
        }
        onExited: if (!moving) { cab.mx = -1e4; cab.my = -1e4; cab.track() }
        onPressed: m => {
            if (cab.renameIdx >= 0) {
                const i = cab.renameIdx
                if (cab.inside(m.x, m.y, { x: cab.frontX(0), y: cab.slotY(i), w: cab.slotW, h: cab.dh })) m.accepted = false
                else { cab.renameIdx = -1; m.accepted = false }
                return
            }
            if (m.button === Qt.LeftButton && cab.under.part === "top") { moving = true; sx = m.x; sy = m.y }
        }
        onReleased: m => {
            if (!moving) return
            moving = false
            cab.app.setCabinet(cab.px, cab.py)
        }
        onClicked: m => {
            const u = cab.under
            if (u.d < 0) return
            const d = drawers.itemAt(u.d)
            if (m.button === Qt.RightButton) {
                if (u.part !== "folder") cab.renameIdx = u.d
                return
            }
            if (u.part === "folder") {
                // take it out of the drawer and onto the desktop ("+N more" opens the browser)
                if (u.k === d.n - 1 && d.more > 1) cab.app.browse(d.cat)
                else cab.app.reveal(d.files[d.scroll + u.k].id)
                cab.hoverIdx = -1
            } else if (d.cat) cab.app.browse(d.cat)
        }
        onWheel: w => {
            const d = cab.hoverIdx >= 0 ? drawers.itemAt(cab.hoverIdx) : null
            if (!d || !d.showing) return
            const s = Math.max(0, Math.min(d.maxScroll, d.scroll + (w.angleDelta.y < 0 ? 1 : w.angleDelta.y > 0 ? -1 : 0)))
            if (s !== d.scroll) d.scroll = s
        }
        Timer {
            interval: 16; repeat: true; running: hit.moving
            onTriggered: {
                if (!hit.dirty) return
                hit.dirty = false
                cab.px = cab.clampX(cab.px + Math.round(hit.mouseX - hit.sx))
                cab.py = cab.clampY(cab.py + Math.round(hit.mouseY - hit.sy))
            }
        }
    }
}
