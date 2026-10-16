// One sticky note: a layer-shell surface on the desktop (below windows, or above them when pinned).
// Drawn as Amiga AGA pixel art like the file cabinet: dithered paper with a folded corner and a
// coloured header, an editable title under it, and a lazy band of goo along the bottom (decoration).
// Dragging: while you hold the header the window covers the whole screen (click-through outside the
// note) and the note moves inside it, so it follows the pointer 1:1 instead of chasing window moves.
import QtQuick
import Quickshell
import QtQuick.Shapes
import Quickshell.Io
import Quickshell.Wayland
import "fmt.js" as Fmt

PanelWindow {
    id: win
    required property string modelData
    required property var app
    readonly property string nid: modelData
    readonly property var d: app.store[nid] || ({})

    // live state, seeded once from the store
    property int px: d.x ?? 120
    property int py: d.y ?? 120
    property int pw: d.w ?? 300
    property int ph: d.h ?? 280
    property int ox: 0              // where the note was when a drag started
    property int oy: 0
    property int ci: d.color ?? 0
    property bool pinned: !!d.pinned
    readonly property var pal: app.palette[ci % app.palette.length]

    property real t: 0
    property bool armed: false   // trash clicked once
    property bool raised: false  // lifted above windows for a moment after picking it in the drawer
    property bool picking: false // category menu open
    readonly property string cat: { app.rev; return (app.store[nid] || {}).category || "" }

    // ---- dragging -----------------------------------------------------------------------------
    // Moving a layer-shell window means the pointer positions we get are relative to wherever the
    // compositor last put the window, which lags behind where we asked it to be: the note chases
    // itself and jitters. So while dragging, the window is stretched over the whole screen and the
    // note moves as an item inside it (same coordinates for pointer and note: exact, every frame).
    property bool dragging: false
    property bool settling: false   // let go: waiting for the window to shrink back to the note
    // the note sits at (px, py) inside the window only while the window is actually full screen
    readonly property bool big: settling || (dragging && (width > pw + 2 || height > ph + 2))
    onWidthChanged: if (settling && width <= pw + 1) settling = false
    Timer { interval: 600; running: win.settling; onTriggered: win.settling = false }

    screen: app.screenFor(d.screen || "")
    visible: app.shown
    color: "transparent"
    anchors { top: true; left: true; right: win.dragging; bottom: win.dragging }
    margins { top: win.dragging ? 0 : win.py; left: win.dragging ? 0 : win.px }
    implicitWidth: win.pw
    implicitHeight: win.ph
    mask: Region { item: sheet }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "goonotes"
    WlrLayershell.layer: win.pinned || win.raised || app.peek ? WlrLayer.Top : WlrLayer.Bottom
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    Connections {
        target: win.app
        function onPinEverything(on) { win.pinned = on; win.app.update(win.nid, { pinned: on }) }
        function onFlash(id) { if (id === win.nid) win.lift() }
        // edited on the phone: show it (never while you're typing here; the sync waits for that)
        function onRemoteEdit(id) {
            if (id !== win.nid) return
            if (!edit.activeFocus) edit.text = win.d.text || ""
            if (!titleEdit.activeFocus) titleEdit.text = win.d.title || ""
            win.ci = win.d.color || 0
        }
    }
    Component.onCompleted: {
        edit.text = d.text || ""
        titleEdit.text = d.title || ""
        if (app.pendingFlash === nid) { app.pendingFlash = ""; lift() }
    }
    // Switching layers on a window that hasn't finished appearing makes it vanish, so a brand-new
    // note waits a moment before it's lifted
    readonly property real born: Date.now()
    function lift() {
        if (Date.now() - born < 400) { liftSoon.restart(); return }
        raised = true; raiseTimer.interval = 20000; raiseTimer.restart(); pulse.restart()
    }
    Timer { id: liftSoon; interval: 400; onTriggered: win.lift() }
    readonly property bool editing: edit.activeFocus || titleEdit.activeFocus
    // clicked away after typing: sink back to the desktop shortly after
    onEditingChanged: {
        if (!editing && raised) { raiseTimer.interval = 1500; raiseTimer.restart() }
        if (editing) app.typing = nid
        else if (app.typing === nid) app.typing = ""
    }
    // stays up while you're typing in it or pointing at it, then sinks back to the desktop
    Timer { id: raiseTimer; interval: 20000; onTriggered: if (win.editing || hover.hovered) restart(); else win.raised = false }
    property real glow: 0
    SequentialAnimation {
        id: pulse
        NumberAnimation { target: win; property: "glow"; from: 0; to: 1; duration: 180 }
        NumberAnimation { target: win; property: "glow"; to: 0; duration: 1400; easing.type: Easing.InQuad }
    }

    readonly property int headerH: 34
    readonly property int pitch: 9

    readonly property int titleH: 28

    // the goo drifts only while you're on the note; otherwise it sits still and costs nothing
    Timer {
        interval: 50; repeat: true
        running: win.visible && (hover.hovered || win.editing)
        onTriggered: { win.t += 0.05; dots.requestPaint() }
    }

    // ---- formatting (fmt.js; same markers as the phone app) ----------------------------
    readonly property bool styled: !edit.activeFocus && edit.length > 0 && Fmt.hasFormatting(edit.text)
    // ctrl+b / ctrl+i: wrap the selection in a marker, or unwrap it if it already is
    function wrapSel(mk) {
        const s = edit.selectionStart, e = edit.selectionEnd, t = edit.text, n = mk.length
        if (s >= n && t.slice(s - n, s) === mk && t.slice(e, e + n) === mk) {
            edit.remove(e, e + n); edit.remove(s - n, s); edit.select(s - n, e - n)
        } else {
            edit.insert(e, mk); edit.insert(s, mk); edit.select(s + n, e + n)
        }
    }
    // ctrl+t: tick the task on this line, or make the line a task
    function taskLine() {
        const t = edit.text, c = edit.cursorPosition, ls = t.lastIndexOf("\n", c - 1) + 1
        let le = t.indexOf("\n", c); if (le < 0) le = t.length
        const line = t.slice(ls, le)
        if (/^\s*[-*] \[[ xX]\]/.test(line)) {
            const b = ls + line.indexOf("[") + 1
            const on = t[b] === " "
            edit.remove(b, b + 1); edit.insert(b, on ? "x" : " ")
        } else {
            const m = /^(\s*)([-*] )?/.exec(line)
            edit.remove(ls, ls + m[0].length); edit.insert(ls, m[1] + "- [ ] ")
        }
    }

    // ---- menus (NoteMenu): right-click the header for the note, the text for editing ----------
    readonly property bool menuOpen: win.picking || menu.visible
    function closeMenus() { win.picking = false; menu.hide() }
    // pointer wandered off the note with a menu open (and the note never got focus): close it
    Timer { id: menuAway; interval: 700; onTriggered: if (!hover.hovered && !menu.visible) win.closeMenus() }
    Connections { target: hover; function onHoveredChanged() { if (!hover.hovered && win.picking) menuAway.restart() } }

    NoteMenu { id: menu; app: win.app; note: win }
    Connections {
        target: win.app
        function onPeekMenu(id, kind) {
            if (id !== win.nid) return
            menu.grab = false
            if (kind === "colour") win.colourMenu(win.pw - 150, win.headerH)
            else if (kind === "note") menu.show(40, 10, win.noteItems())
            else { win.keepSel(edit); menu.show(60, 80, win.textItems()) }
        }
    }
    function setColour(i) { win.ci = i; win.app.update(win.nid, { color: i }) }
    function colourItems() {
        return win.app.palette.map((p, i) => ({ swatch: i, text: p.name, checked: i === win.ci % win.app.palette.length, act: () => win.setColour(i) }))
    }
    function colourMenu(x, y) { menu.show(x, y, colourItems()) }
    // the text field and selection when the menu opened: the field loses focus to the menu, which clears it
    property var menuTarget: edit
    property int selS: 0
    property int selE: 0
    function keepSel(target) { menuTarget = target; selS = target.selectionStart; selE = target.selectionEnd }
    function withSel(f) {
        const t = menuTarget
        t.forceActiveFocus()
        if (selE > selS) t.select(selS, selE); else t.cursorPosition = selE
        f(t)
        if (t === edit) win.app.update(win.nid, { text: edit.text })
    }
    function noteItems() {
        return [
            { swatches: true, current: win.ci % win.app.palette.length, pick: i => win.setColour(i) },
            { text: "Category...", act: () => win.picking = true },
            { text: win.pinned ? "Unpin" : "Pin above windows", act: () => { win.pinned = !win.pinned; win.app.update(win.nid, { pinned: win.pinned }) } },
            { text: "Pin to corkboard", act: () => win.app.pinToBoard(win.nid) },
            { sep: true },
            { text: "New note", key: "Ctrl+N", act: () => win.app.newNote("", win.cat) },
            { text: win.cat ? "Put away in " + win.cat : "Put away", key: "Ctrl+W", act: () => win.app.putAwayNote(win.nid) },
            { text: "Delete note", danger: true, confirm: true, act: () => win.app.remove(win.nid) }
        ]
    }
    function textItems() {
        const has = selE > selS, body = menuTarget === edit, flat = body && win.styled
        const items = [
            { text: "Cut", key: "Ctrl+X", enabled: has && !flat, act: () => win.withSel(t => t.cut()) },
            { text: "Copy", key: "Ctrl+C", enabled: has && !flat, act: () => { menuTarget.select(selS, selE); menuTarget.copy() } },
            { text: "Paste", key: "Ctrl+V", act: () => win.withSel(t => t.paste()) }
        ]
        if (body && win.app.hasWlPaste) items.push({ text: "Paste image", act: () => win.withSel(() => win.pasteImage(true)) })
        items.push({ text: "Select all", key: "Ctrl+A", act: () => { menuTarget.forceActiveFocus(); menuTarget.selectAll() } })
        if (!body) return items.concat([{ sep: true }]).concat(noteItems())
        return items.concat([
            { text: "Copy whole note", act: () => { const c = edit.cursorPosition; edit.selectAll(); edit.copy(); edit.deselect(); edit.cursorPosition = c } },
            { sep: true },
            { text: "Bold", key: "Ctrl+B", enabled: has, act: () => win.withSel(() => win.wrapSel("**")) },
            { text: "Italic", key: "Ctrl+I", enabled: has, act: () => win.withSel(() => win.wrapSel("*")) },
            { text: "Checkbox line", key: "Ctrl+T", act: () => win.withSel(() => win.taskLine()) },
            { sep: true }
        ]).concat(noteItems())
    }
    function openTextMenu(target, p) {
        win.picking = false
        menu.grab = true
        keepSel(target)
        menu.show(p.x, p.y, textItems())
    }

    // ---- pasted images (desktop only, files in app.imageDir) -----------------------------------
    property var imgs: d.images || []
    function setImages(list) { imgs = list; app.update(nid, { images: list }) }
    function removeImage(i) {
        const im = imgs[i]
        setImages(imgs.filter((_, k) => k !== i))
        if (im) app.deleteImageFile(im.file)
    }
    // Ctrl+V: an image on the clipboard (and no text) goes in as a picture, anything else pastes as usual.
    // fromMenu: "paste image" was picked, so take the image even if there's text alongside it.
    function pasteImage(fromMenu) {
        if (!app.hasWlPaste) { if (!fromMenu) edit.paste(); return }
        clipProbe.fromMenu = fromMenu
        clipProbe.running = true
    }
    Process {
        id: clipProbe
        property bool fromMenu: false
        command: ["wl-paste", "--list-types"]
        stdout: StdioCollector {
            onStreamFinished: {
                const types = text.split("\n").map(s => s.trim())
                const img = Object.keys(win.app.imageTypes).find(t => types.indexOf(t) >= 0)
                const hasText = types.some(t => t.startsWith("text/plain") || t === "UTF8_STRING" || t === "STRING" || t === "TEXT")
                if (img && (clipProbe.fromMenu || !hasText)) win.saveImage(img)
                else if (!clipProbe.fromMenu) edit.paste()
            }
        }
    }
    function saveImage(type) {
        if (saver.running) return
        const file = nid + "-" + Date.now().toString(36) + "." + app.imageTypes[type]
        if (!app.safeImageName(file)) { console.warn("goonotes: odd note id, not saving image", nid); return }
        saver.file = file
        saver.command = ["sh", "-c", saver.script, "sh", app.imageDir, type, app.imageDir + "/" + file, String(app.imageMaxBytes)]
        saver.running = true
    }
    // scroll a freshly pasted picture into view once it has loaded and has a size
    property bool showNewImage: false
    function scrollToEnd() { flick.contentY = Math.max(0, flick.contentHeight - flick.height) }
    Process {
        id: saver
        property string file: ""
        // $1 dir, $2 mime type, $3 target file, $4 max bytes. Writes to a .part file, checks size and
        // the file's magic bytes against the type, and only then moves it into place.
        readonly property string script: [
            'umask 077; mkdir -p -- "$1" || exit 1; tmp="$3.part"',
            'wl-paste --no-newline --type "$2" | head -c "$(( $4 + 1 ))" > "$tmp"',
            'size=$(stat -c %s -- "$tmp" 2>/dev/null || echo 0)',
            'if [ "$size" -eq 0 ] || [ "$size" -gt "$4" ]; then rm -f -- "$tmp"; exit 2; fi',
            'magic=$(head -c 12 -- "$tmp" | od -An -tx1 | tr -d " \\n")',
            'case "$2:$magic" in',
            '  image/png:89504e470d0a1a0a*|image/jpeg:ffd8ff*|image/gif:47494638*|image/bmp:424d*|image/webp:52494646????????57454250) ;;',
            '  *) rm -f -- "$tmp"; exit 3 ;;',
            'esac',
            'mv -f -- "$tmp" "$3"'
        ].join("\n")
        onExited: code => {
            if (code === 0) {
                win.setImages(win.imgs.concat([{ file: saver.file, w: Math.min(260, Math.max(80, flick.width)) }]))
                win.showNewImage = true
            }
            else console.warn("goonotes: image paste refused (" + code + ")")
        }
    }

    // ---- the paper, drawn as Amiga AGA pixel art like the cabinet (dithered, chunky pixels) ----
    readonly property int sh: 6       // drop shadow offset (the paper is this much smaller than the window)
    readonly property int fold: 18    // the folded-over bottom-right corner, which is also the resize grip
    readonly property color black: "#141418"
    // the note itself: at the window's corner, or at (px, py) while the window covers the screen for a drag
    Item {
        id: sheet
        x: win.big ? win.px : 0
        y: win.big ? win.py : 0
        width: win.pw
        height: win.ph
        HoverHandler { id: hover }
        // the note lost keyboard focus (clicked somewhere else): close any menu
        readonly property bool winActive: Window.active
        onWinActiveChanged: if (!winActive) win.closeMenus()

        AgaPalette { id: aga; colors: win.app.aga }
        Item {
            id: art
            anchors.fill: parent
            layer.enabled: true
            layer.smooth: false
            layer.effect: Dither { pal: aga.tex; count: aga.count }
            readonly property real w: card.width
            readonly property real h: card.height

            Shape {
                anchors.fill: parent
                // dithered drop shadow
                ShapePath {
                    strokeWidth: -1; fillColor: Qt.rgba(0, 0, 0, 0.45)
                    startX: win.sh; startY: win.sh
                    PathLine { x: art.w + win.sh; y: win.sh }
                    PathLine { x: art.w + win.sh; y: art.h + win.sh - win.fold }
                    PathLine { x: art.w + win.sh - win.fold; y: art.h + win.sh }
                    PathLine { x: win.sh; y: art.h + win.sh }
                    PathLine { x: win.sh; y: win.sh }
                }
                // the sheet, with its corner folded away
                ShapePath {
                    strokeColor: win.black; strokeWidth: 2; joinStyle: ShapePath.MiterJoin
                    fillGradient: LinearGradient {
                        x1: 0; y1: 0; x2: 0; y2: art.h
                        GradientStop { position: 0; color: "#f4f3ec" }
                        GradientStop { position: 1; color: "#d9d7cb" }
                    }
                    startX: 1; startY: 1
                    PathLine { x: art.w - 1; y: 1 }
                    PathLine { x: art.w - 1; y: art.h - win.fold }
                    PathLine { x: art.w - win.fold; y: art.h - 1 }
                    PathLine { x: 1; y: art.h - 1 }
                    PathLine { x: 1; y: 1 }
                }
            }

            // goo: a low band of the note's second colour along the bottom of the paper. Just decoration:
            // it never rises, and only drifts while you're on the note
            Canvas {
                id: dots
                readonly property int band: 34
                x: 2; y: art.h - band - 1
                width: art.w - 4; height: band
                renderStrategy: Canvas.Cooperative
                onWidthChanged: requestPaint()
                Component.onCompleted: requestPaint()
                Connections { target: win; function onCiChanged() { dots.requestPaint() } }
                onPaint: {
                    const ctx = getContext("2d")
                    ctx.reset()
                    const top = 14
                    const wave = x => top + Math.sin(x * 0.035 + win.t * 1.1) * 3 + Math.sin(x * 0.09 - win.t * 0.7) * 1.5
                    ctx.beginPath(); ctx.moveTo(0, height)
                    for (let x = 0; x <= width; x += 4) ctx.lineTo(x, wave(x))
                    ctx.lineTo(width, height); ctx.closePath()
                    ctx.globalAlpha = 0.28; ctx.fillStyle = win.pal.b; ctx.fill()
                    ctx.beginPath(); ctx.moveTo(0, wave(0))
                    for (let x = 4; x <= width; x += 4) ctx.lineTo(x, wave(x))
                    ctx.globalAlpha = 0.7; ctx.strokeStyle = win.pal.b; ctx.lineWidth = 2; ctx.stroke()
                    // keep it off the folded corner
                    ctx.globalCompositeOperation = "destination-out"; ctx.globalAlpha = 1
                    ctx.beginPath(); ctx.moveTo(width - win.fold + 3, height + 1); ctx.lineTo(width + 1, height + 1); ctx.lineTo(width + 1, height - win.fold + 3); ctx.closePath(); ctx.fill()
                }
            }

            // header band in the note's colour, bevelled
            Rectangle {
                x: 2; y: 2; width: art.w - 4; height: win.headerH - 2
                gradient: Gradient {
                    GradientStop { position: 0; color: Qt.lighter(win.pal.a, 1.35) }
                    GradientStop { position: 1; color: win.pal.a }
                }
            }
            Rectangle { x: 2; y: 2; width: art.w - 4; height: 2; color: "#f4f5f6" }
            Rectangle { x: 2; y: win.headerH; width: art.w - 4; height: 2; color: win.black }
            // rule under the title
            Rectangle { x: 14; y: win.headerH + win.titleH; width: art.w - 28; height: 2; color: "#c5c8cc" }
            // category label card, pressed into the header
            Rectangle {
                x: catChip.x; y: catChip.y; width: catChip.width; height: catChip.height
                color: catArea.containsMouse || win.picking ? "#ffffff" : "#efeee6"
            }
            Rectangle { x: catChip.x; y: catChip.y; width: catChip.width; height: 2; color: win.black }
            Rectangle { x: catChip.x; y: catChip.y; width: 2; height: catChip.height; color: win.black }
            Rectangle { x: catChip.x; y: catChip.y + catChip.height - 2; width: catChip.width; height: 2; color: "#f4f5f6" }
            Rectangle { x: catChip.x + catChip.width - 2; y: catChip.y; width: 2; height: catChip.height; color: "#f4f5f6" }

            // the folded corner: the back of the sheet, turned over
            Shape {
                anchors.fill: parent
                ShapePath {
                    strokeColor: win.black; strokeWidth: 2; joinStyle: ShapePath.MiterJoin
                    fillGradient: LinearGradient {
                        x1: art.w - win.fold; y1: art.h - win.fold; x2: art.w; y2: art.h
                        GradientStop { position: 0; color: gripArea.containsMouse || gripArea.pressed ? Qt.lighter(win.pal.a, 1.3) : "#c5c8cc" }
                        GradientStop { position: 1; color: gripArea.containsMouse || gripArea.pressed ? win.pal.a : "#f4f5f6" }
                    }
                    startX: art.w - 1; startY: art.h - win.fold
                    PathLine { x: art.w - win.fold; y: art.h - 1 }
                    PathLine { x: art.w - win.fold; y: art.h - win.fold }
                    PathLine { x: art.w - 1; y: art.h - win.fold }
                }
            }

            // typing in it, or just found: a frame in the note's colour
            Rectangle {
                x: 0; y: 0; width: art.w; height: art.h
                visible: win.editing || win.glow > 0
                color: "transparent"
                border.color: win.pal.a; border.width: 2 + Math.round(win.glow * 2) * 2
            }
        }

        Item {
            id: card
            anchors { fill: parent; rightMargin: win.sh; bottomMargin: win.sh }

            // ---- header: drag strip + buttons --------------------------------
            Item {
                id: header
                anchors { top: parent.top; left: parent.left; right: parent.right }
                height: win.headerH

                MouseArea {
                    id: dragArea
                    anchors.fill: parent
                    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                    property real gx0: 0     // pointer at press, screen coords
                    property real gy0: 0
                    property real lx: 0      // last pointer position, screen coords
                    property real ly: 0
                    // Pointer in screen coords. Until the compositor has stretched the window, positions
                    // are relative to the small window (still at ox, oy); after, to the screen. Right at
                    // the switch we can't know which one an event used, so take the reading that carries
                    // on from the last one.
                    function screenPos(m) {
                        const p = mapToItem(null, m.x, m.y)
                        let x = p.x + win.ox, y = p.y + win.oy
                        if (win.big && Math.hypot(p.x - lx, p.y - ly) < Math.hypot(x - lx, y - ly)) { x = p.x; y = p.y }
                        return Qt.point(x, y)
                    }
                    onPressed: m => {
                        win.closeMenus()
                        edit.focus = false; titleEdit.focus = false
                        win.ox = win.px; win.oy = win.py
                        const p = mapToItem(null, m.x, m.y)
                        gx0 = lx = p.x + win.px; gy0 = ly = p.y + win.py
                        win.app.dragX = gx0; win.app.dragY = gy0
                        win.app.dragNote = win.nid
                        win.dragging = true
                    }
                    onPositionChanged: m => {
                        const g = screenPos(m)
                        lx = g.x; ly = g.y
                        win.px = Math.max(0, Math.round(win.ox + g.x - gx0))
                        win.py = Math.max(0, Math.round(win.oy + g.y - gy0))
                        // tell the file cabinet where the pointer is, so its drawers can open under it
                        win.app.dragX = g.x; win.app.dragY = g.y
                    }
                    function finish() {
                        win.settling = win.big     // keep drawing at (px, py) until the window has shrunk back
                        win.dragging = false
                        win.app.dragNote = ""
                        win.app.update(win.nid, { x: win.px, y: win.py })
                    }
                    onReleased: { finish(); win.app.noteDropped(win.nid, lx, ly) }
                    onCanceled: finish()
                }
                // right-click the header: the note's menu
                MouseArea {
                    anchors.fill: parent
                    z: 100
                    acceptedButtons: Qt.RightButton
                    onPressed: m => {
                        win.picking = false
                        menu.grab = true
                        const p = mapToItem(null, m.x, m.y)
                        menu.show(p.x, p.y, win.noteItems())
                    }
                }

                // category label: click to file the note somewhere
                Rectangle {
                    id: catChip
                    anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                    width: Math.min(catLabel.implicitWidth + 18, buttons.x - 16)
                    height: 20
                    color: "transparent"   // drawn in the art layer
                    PixelText {
                        id: catLabel
                        anchors { left: parent.left; leftMargin: 8; right: parent.right; rightMargin: 4; verticalCenter: parent.verticalCenter }
                        text: (win.cat || "unsorted").toUpperCase()
                        elide: Text.ElideRight
                        font.pixelSize: 11
                        color: win.cat ? win.black : "#757980"
                    }
                    MouseArea {
                        id: catArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: win.picking = !win.picking
                    }
                }

                Row {
                    id: buttons
                    anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                    spacing: 2
                    opacity: hover.hovered || win.editing || win.armed ? 1 : 0.55
                    Behavior on opacity { NumberAnimation { duration: 180 } }

                    NoteButton { glyph: ""; tip: win.pal.a; app: win.app; ink: win.black; pixel: true
                        id: colourBtn; hint: "COLOUR"
                        onClicked: { const p = colourBtn.mapToItem(null, 0, colourBtn.height + 2); menu.grab = true; win.colourMenu(p.x, p.y) } }
                    NoteButton { glyph: ""; app: win.app; ink: win.black; pixel: true; lit: win.pinned; tip: win.pal.b
                        hint: win.pinned ? "UNPIN" : "PIN ABOVE WINDOWS"
                        rotation: win.pinned ? 0 : 45
                        onClicked: { win.pinned = !win.pinned; win.app.update(win.nid, { pinned: win.pinned }) } }
                    // onto the corkboard: put away, but kept in sight as a card
                    NoteButton { glyph: ""; app: win.app; ink: win.black; pixel: true; tip: win.pal.b
                        hint: "CORKBOARD"
                        onClicked: win.app.pinToBoard(win.nid) }
                    NoteButton { glyph: ""; app: win.app; ink: win.black; pixel: true; hint: "DRAWER"; onClicked: win.app.drawerOpen = true }
                    NoteButton { glyph: ""; app: win.app; ink: win.black; pixel: true; hint: "NEW NOTE"; onClicked: win.app.newNote("", win.cat) }
                    NoteButton { glyph: win.armed ? "" : ""; app: win.app; ink: win.black; pixel: true
                        lit: win.armed; tip: win.app.danger
                        hint: win.armed ? "CLICK AGAIN TO DELETE" : "DELETE"
                        onClicked: { if (win.armed) win.app.remove(win.nid); else { win.armed = true; disarm.restart() } } }
                    // close = put it away (into its category's drawer, or the stash); never deletes
                    NoteButton { glyph: "\uf00d"; app: win.app; ink: win.black; pixel: true; tip: win.pal.b
                        hint: win.cat ? "PUT AWAY IN " + win.cat.toUpperCase() : "PUT AWAY"
                        onClicked: win.app.putAwayNote(win.nid) }
                }
                Timer { id: disarm; interval: 2500; onTriggered: win.armed = false }
            }

            // ---- title: what the note is called (its tab in the drawer) ----------
            Item {
                id: titleRow
                anchors { top: header.bottom; left: parent.left; right: parent.right; leftMargin: 16; rightMargin: 14 }
                height: win.titleH
                TextInput {
                    id: titleEdit
                    anchors.fill: parent
                    verticalAlignment: TextInput.AlignVCenter
                    clip: true
                    maximumLength: 80
                    color: win.black
                    selectionColor: win.pal.a
                    selectedTextColor: win.black
                    font.family: "monospace"
                    font.bold: true
                    font.pixelSize: 15
                    font.hintingPreference: Font.PreferFullHinting
                    renderType: Text.NativeRendering
                    selectByMouse: true
                    onTextEdited: win.app.update(win.nid, { title: text })
                    Keys.onPressed: e => {
                        if (e.key === Qt.Key_Escape) { titleEdit.focus = false; e.accepted = true }
                        else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Down) { edit.forceActiveFocus(); e.accepted = true }
                    }
                }
                // no title yet: show what the drawer will call it instead (its first line), dimmed
                Text {
                    anchors.fill: titleEdit
                    visible: !titleEdit.text && !titleEdit.activeFocus
                    text: { win.app.rev; return ((win.d.text || "").split("\n").find(l => l.trim()) || "title").trim() }
                    elide: Text.ElideRight
                    color: "#8f949a"
                    font: titleEdit.font
                    renderType: Text.NativeRendering
                }
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.RightButton
                    cursorShape: Qt.IBeamCursor
                    onPressed: m => { titleEdit.forceActiveFocus(); win.openTextMenu(titleEdit, mapToItem(null, m.x, m.y)) }
                }
            }

            // ---- body: the text, then any pasted pictures ----------------------
            Flickable {
                id: flick
                anchors { top: titleRow.bottom; left: parent.left; right: parent.right; bottom: footer.top
                          leftMargin: 16; rightMargin: 14; topMargin: 8 }
                contentWidth: width
                contentHeight: content.height
            onContentHeightChanged: if (win.showNewImage) Qt.callLater(win.scrollToEnd)
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                function follow(r) {
                    if (r.y < contentY) contentY = r.y
                    else if (r.y + r.height > contentY + height) contentY = r.y + r.height - height
                }

                Column {
                    id: content
                    width: flick.width
                    spacing: 8

                    // the text, and over it the note as it reads (formatted) while you're not typing in it
                    Item {
                        width: content.width
                        height: win.styled ? rendered.contentHeight : edit.implicitHeight
                    TextEdit {
                        id: edit
                        width: parent.width
                        // a formatted note reads as rich text until you click into it (see `rendered`)
                        opacity: win.styled ? 0 : 1
                        wrapMode: TextEdit.Wrap
                        color: win.black
                        selectionColor: win.pal.a
                        selectedTextColor: win.black
                        font.family: "monospace"
                        font.bold: true
                        font.pixelSize: 13
                        font.hintingPreference: Font.PreferFullHinting
                        renderType: Text.NativeRendering
                        cursorDelegate: Rectangle { width: 8; color: win.pal.a; border.color: win.black; border.width: 1; visible: edit.cursorVisible }
                        selectByMouse: true
                        persistentSelection: false
                        onCursorRectangleChanged: flick.follow(cursorRectangle)
                        onTextChanged: if (activeFocus) win.app.update(win.nid, { text: text })
                        Keys.onPressed: e => {
                            const ctrl = e.modifiers & Qt.ControlModifier
                            if (e.key === Qt.Key_Escape) { edit.focus = false; e.accepted = true }
                            else if (ctrl && e.key === Qt.Key_N) { win.app.newNote("", win.cat); e.accepted = true }
                            else if ((e.key === Qt.Key_V && ctrl && !(e.modifiers & Qt.ShiftModifier))
                                     || (e.key === Qt.Key_Insert && (e.modifiers & Qt.ShiftModifier))) { win.pasteImage(false); e.accepted = true }
                            else if (ctrl && e.key === Qt.Key_W) { win.app.putAwayNote(win.nid); e.accepted = true }   // put away
                            else if (ctrl && e.key === Qt.Key_B) { win.wrapSel("**"); e.accepted = true }
                            else if (ctrl && e.key === Qt.Key_I) { win.wrapSel("*"); e.accepted = true }
                            else if (ctrl && e.key === Qt.Key_T) { win.taskLine(); e.accepted = true }
                            else if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !(e.modifiers & Qt.ShiftModifier)) {
                                // Enter on a list item starts the next one; on an empty item it ends the list
                                const t = edit.text, c = edit.cursorPosition, ls = t.lastIndexOf("\n", c - 1) + 1
                                const p = Fmt.listPrefix(t.slice(ls, c))
                                if (p) {
                                    if (p.empty) edit.remove(ls, c)
                                    else edit.insert(c, "\n" + p.prefix)
                                    e.accepted = true
                                }
                            }
                        }
                    }
                    // headings in the block font, bullets, checkboxes you click to tick. Clicks that miss a
                    // checkbox fall through to the (invisible) editor underneath.
                    Text {
                        id: rendered
                        visible: win.styled
                        width: parent.width
                        wrapMode: Text.Wrap
                        textFormat: Text.RichText
                        text: win.styled ? Fmt.toHtml(edit.text, "#5b5f65", "#8f949a", win.app.block, Qt.lighter(win.pal.a, 1.25).toString()) : ""
                        color: win.black
                        font: edit.font
                        renderType: Text.NativeRendering
                        onLinkActivated: link => {
                            if (!link.startsWith("cb:")) return
                            const t = Fmt.toggle(edit.text, parseInt(link.slice(3)))
                            edit.text = t
                            win.app.update(win.nid, { text: t })
                        }
                        HoverHandler { cursorShape: rendered.hoveredLink ? Qt.PointingHandCursor : Qt.IBeamCursor }
                    }
                    }

                    Repeater {
                        model: win.imgs
                        delegate: Item {
                            id: pic
                            required property var modelData
                            required property int index
                            property real liveW: Math.max(48, Math.min(modelData.w || 200, content.width))
                            width: liveW
                            height: img.status === Image.Ready && img.implicitWidth > 0 ? Math.round(liveW * img.implicitHeight / img.implicitWidth) : 40
                            Image {
                                id: img
                                anchors.fill: parent
                                source: win.app.imageUrl(pic.modelData.file)
                                sourceSize.width: 1600      // never decode a huge picture at full size
                                fillMode: Image.PreserveAspectFit
                                asynchronous: true
                                smooth: true
                                mipmap: true
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: img.status === Image.Error
                                text: "image missing"
                                color: "#8f949a"; font.family: "monospace"; font.bold: true; font.pixelSize: 11
                            }
                            Rectangle { anchors.fill: parent; color: "transparent"; border.color: win.black; border.width: 2 }
                            HoverHandler { id: picHover }
                            // remove
                            Rectangle {
                                anchors { top: parent.top; right: parent.right; margins: 4 }
                                width: 20; height: 20
                                visible: picHover.hovered
                                color: delArea.containsMouse ? win.app.danger : "#efeee6"
                                border.color: win.black; border.width: 2
                                Text { anchors.centerIn: parent; text: "x"; color: win.black; font.family: "monospace"; font.bold: true; font.pixelSize: 12 }
                                MouseArea { id: delArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: win.removeImage(pic.index) }
                            }
                            // resize: drag the corner, the picture keeps its shape
                            Rectangle {
                                id: picGrip
                                anchors { right: parent.right; bottom: parent.bottom }
                                width: 14; height: 14
                                opacity: picHover.hovered || picGripArea.pressed ? 1 : 0
                                color: win.pal.a
                                border.color: win.black; border.width: 2
                                MouseArea {
                                    id: picGripArea
                                    anchors.fill: parent
                                    anchors.margins: -4
                                    cursorShape: Qt.SizeFDiagCursor
                                    preventStealing: true
                                    onPositionChanged: m => {
                                        if (!pressed) return
                                        const p = mapToItem(pic, m.x, m.y)
                                        pic.liveW = Math.max(48, Math.min(content.width, Math.round(p.x + 4)))
                                    }
                                    onReleased: {
                                        const list = win.imgs.slice()
                                        list[pic.index] = Object.assign({}, list[pic.index], { w: Math.round(pic.liveW) })
                                        win.setImages(list)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // right-click the text for cut / copy / paste / paste image
            MouseArea {
                anchors.fill: flick
                acceptedButtons: Qt.RightButton
                onPressed: m => {
                    win.openTextMenu(edit, mapToItem(null, m.x, m.y))
                }
            }
            // click anywhere under the text to start typing at the end
            MouseArea {
                anchors { top: flick.top; topMargin: Math.max(0, Math.min(flick.height, content.height - flick.contentY)); left: flick.left; right: flick.right; bottom: flick.bottom }
                cursorShape: Qt.IBeamCursor
                onClicked: { edit.forceActiveFocus(); edit.cursorPosition = edit.length }
            }
            Text {
                anchors { top: flick.top; left: flick.left }
                visible: edit.length === 0 && !edit.activeFocus && !win.imgs.length
                text: "write something..."
                color: "#8f949a"
                font.family: "monospace"
                font.bold: true
                font.pixelSize: 13
                renderType: Text.NativeRendering
            }

            // ---- footer: counters + resize grip --------------------------------
            Item {
                id: footer
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 26
                PixelText {
                    anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                    text: edit.length + " CH / " + (edit.text.length ? edit.text.split("\n").length : 0) + " LN"
                          + (win.imgs.length ? " / " + win.imgs.length + " IMG" : "")
                    font.pixelSize: 9
                    color: "#42454b"
                    opacity: hover.hovered || win.editing ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 180 } }
                }
            }

            // the folded corner is the resize grip; the window's top-left never moves while resizing, so window coords are exact
            Item {
                id: grip
                width: win.fold + 2; height: win.fold + 2
                anchors { right: parent.right; bottom: parent.bottom }
                MouseArea {
                    id: gripArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.SizeFDiagCursor
                    onPositionChanged: m => {
                        if (!pressed) return
                        const p = mapToItem(card, m.x, m.y)
                        win.pw = Math.max(260, Math.round(p.x + 6 + win.sh))
                        win.ph = Math.max(180, Math.round(p.y + 6 + win.sh))
                    }
                    onReleased: win.app.update(win.nid, { w: win.pw, h: win.ph })
                }
            }
        }

        // category menu over the note; closes on a click outside it, Esc, or the note losing focus
        FocusScope {
            id: pickLayer
            anchors.fill: parent
            visible: win.picking
            onVisibleChanged: if (visible) forceActiveFocus()
            onActiveFocusChanged: if (!activeFocus) win.picking = false
            Keys.onEscapePressed: win.picking = false
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onPressed: win.picking = false
            }
            CategoryMenu {
                x: 10; y: win.headerH - 4
                app: win.app
                current: win.cat
                maxHeight: win.ph - win.headerH - 8
                onPicked: name => { win.app.setCategory(win.nid, name); win.picking = false }
                onDismissed: win.picking = false
            }
        }

    }

    readonly property alias body: edit
}
