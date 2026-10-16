// The corkboard: notes you want kept in sight, pinned on a cork board on the desktop next to the
// file cabinet, drawn in the same Amiga AGA pixel style (Dither.qml). A note on the board keeps its
// drawer; the board just shows it as a card: title, a few lines, a pushpin in its drawer's colour.
// Cards stay up until you take them down. Drop a loose note on the board (or hit its board button)
// to pin it; drag a card around to place it, or off the board to take it down (onto the cabinet
// files it). Click a card to take the note out; right-click it to take it down.
// Drag the top of the frame to move the board, the bottom-right corner to resize it, X to close it
// (reopen: pin something, or  qs -c goonotes ipc call notes board).
import QtQuick
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: bd
    required property var app

    readonly property color pBlack: "#141418"
    readonly property color pWhite: "#f4f5f6"
    readonly property color pOrange: "#ff8800"
    AgaPalette { id: aga; colors: bd.app.aga }
    readonly property real chunk: 2
    function snap(v) { return Math.round(v / chunk) * chunk }

    // ---- shape -----------------------------------------------------------------------
    readonly property int frame: 10          // the wooden frame
    readonly property int topF: 26           // ...thicker on top, where the name plate is (drag to move)
    readonly property int shadow: 6
    readonly property int cw: 120            // a card
    readonly property int ch: 80
    property int bw: Math.max(280, (app.board && app.board.w) || 440)
    property int bh: Math.max(260, (app.board && app.board.h) || 400)
    // the cork, inside the frame
    readonly property rect cork: Qt.rect(frame, topF, bw - frame * 2, bh - topF - frame)

    // ---- place on the desktop: same coordinates as the notes and the cabinet ---------------
    readonly property int maxX: (screen ? screen.width : 1920) - implicitWidth
    readonly property int maxY: (screen ? screen.height : 1080) - implicitHeight
    function clampX(x) { return Math.max(0, Math.min(maxX, x)) }
    function clampY(y) { return Math.max(0, Math.min(maxY, y)) }
    property int px: clampX((app.board && app.board.x !== undefined) ? app.board.x : maxX - 300)
    property int py: clampY((app.board && app.board.y !== undefined) ? app.board.y : 140)
    screen: app.screenFor("")
    visible: app.shown && !(app.board && app.board.hidden)
    color: "transparent"
    anchors { top: true; left: true }
    margins { top: bd.py; left: bd.px }
    implicitWidth: bw + shadow
    implicitHeight: bh + shadow
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "goonotes-corkboard"
    WlrLayershell.layer: app.peek || app.cabinetPeek || menu.visible ? WlrLayer.Top : WlrLayer.Bottom
    mask: Region { item: hit }
    Item { id: hit; width: bd.bw; height: bd.bh }

    // ---- the cards ------------------------------------------------------------------------
    readonly property var pinCols: ["#ff8800", "#8a84b8", "#6f9a8a", "#c4a06c", "#b38a96", "#a3aec0"]
    function pinFor(n) {
        const i = app.categories.indexOf(n.category || "")
        return i < 0 ? "#aaaeb3" : pinCols[i % pinCols.length]
    }
    // where each card goes: where you put it, or else the next free slot
    readonly property var cards: {
        app.rev
        const mine = app.ids.map(i => app.store[i]).filter(n => n && n.board)
            .sort((a, b) => (a.boardAt || 0) - (b.boardAt || 0))
        const cols = Math.max(1, Math.floor((cork.width - 12) / (cw + 10)))
        const fit = (x, y) => ({ x: snap(Math.max(cork.x + 2, Math.min(cork.x + cork.width - cw - 2, x))),
                                 y: snap(Math.max(cork.y + 6, Math.min(cork.y + cork.height - ch - 4, y))) })
        // cards you placed first, then the rest into grid slots nobody is sitting on
        const placed = mine.filter(n => n.bx !== undefined).map(n => Object.assign({ n: n }, fit(n.bx, n.by)))
        const taken = placed.slice()
        let k = 0
        for (const n of mine.filter(n => n.bx === undefined)) {
            let p
            do { p = fit(cork.x + 10 + (k % cols) * (cw + 10), cork.y + 14 + Math.floor(k / cols) * (ch + 14)); k++ }
            while (k < 200 && taken.some(t => Math.abs(t.x - p.x) < cw && Math.abs(t.y - p.y) < ch))
            taken.push(Object.assign({ n: n }, p))
        }
        return taken
    }
    function bodyOf(n) {
        const lines = (n.text || "").split("\n")
        // without a title the first line is the title, so don't repeat it
        if (!(n.title || "").trim()) { const f = lines.findIndex(l => l.trim()); if (f >= 0) lines.splice(0, f + 1) }
        return lines.filter(l => l.trim()).join("\n")
    }
    // take a card's note out, next to the board
    function open(n, cy) {
        const right = px + bw + 16 + (n.w || 300) <= (screen ? screen.width : 1920)
        app.openFromBoard(n.id, right ? px + bw + 16 : Math.max(0, px - (n.w || 300) - 16), py + Math.max(0, cy - 20))
    }

    // a loose note dropped on the cork gets pinned where it was let go
    function inCork(sx, sy) {
        const x = sx - px, y = sy - py
        return x >= cork.x && x <= cork.x + cork.width && y >= cork.y && y <= cork.y + cork.height
    }
    readonly property bool hot: app.dragNote !== "" && app.dragNote !== dragId && inCork(app.dragX, app.dragY)
    Connections {
        target: bd.app
        function onNoteDropped(id, sx, sy) {
            if (id === bd.dragId || !bd.inCork(sx, sy) || !bd.app.store[id]) return
            bd.app.pinToBoard(id, Math.min(sx - bd.px - bd.cw / 2, bd.cork.x + bd.cork.width - bd.cw - 2), Math.min(sy - bd.py - 10, bd.cork.y + bd.cork.height - bd.ch - 4))
        }
    }
    property string dragId: ""   // the card being dragged

    // ---- the board, dithered ----------------------------------------------------------------
    Item {
        anchors.fill: parent
        layer.enabled: true
        layer.smooth: false
        layer.effect: Dither { px: bd.chunk; pal: aga.tex; count: aga.count }

        Rectangle { x: bd.shadow; y: bd.shadow; width: bd.bw; height: bd.bh; color: Qt.rgba(0, 0, 0, 0.5) }
        // frame: dark wood, lit from the top-left
        Rectangle {
            width: bd.bw; height: bd.bh
            border.color: bd.hot ? bd.pOrange : bd.pBlack; border.width: bd.hot ? 4 : 2
            gradient: Gradient {
                GradientStop { position: 0; color: "#9a4c0c" }
                GradientStop { position: 1; color: "#5a2c06" }
            }
        }
        Rectangle { x: 2; y: 2; width: bd.bw - 4; height: 2; color: "#c25e00" }
        Rectangle { x: 2; y: 2; width: 2; height: bd.bh - 4; color: "#c25e00" }
        // close button, top right of the frame
        Rectangle {
            x: bd.bw - 26; y: 5; width: 16; height: 16
            color: closeArea.containsMouse ? bd.pOrange : "#e4e3dc"
            border.color: bd.pBlack; border.width: 2
        }
        // name plate
        Rectangle { id: plate; x: 10; y: 5; width: 104; height: 16; color: "#e4e3dc"; border.color: bd.pBlack; border.width: 2 }
        // the cork
        Rectangle {
            x: bd.cork.x; y: bd.cork.y; width: bd.cork.width; height: bd.cork.height
            gradient: Gradient {
                GradientStop { position: 0; color: "#c8661a" }
                GradientStop { position: 1; color: "#a24c06" }
            }
        }
        Canvas {
            id: speckle
            x: bd.cork.x; y: bd.cork.y; width: bd.cork.width; height: bd.cork.height
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
                const c = getContext("2d")
                c.clearRect(0, 0, width, height)
                let s = 7
                const r = () => (s = (s * 16807) % 2147483647) / 2147483647
                const cols = ["#7a3a00", "#7a3a00", "#ffb85c", "#e8a060"]
                for (let i = 0; i < width * height / 40; i++) {
                    c.fillStyle = cols[Math.floor(r() * cols.length)]
                    c.fillRect(Math.floor(r() * width / 2) * 2, Math.floor(r() * height / 2) * 2, 2, 2)
                }
            }
        }
        // inner shadow where the cork meets the frame
        Rectangle { x: bd.cork.x; y: bd.cork.y; width: bd.cork.width; height: 2; color: bd.pBlack }
        Rectangle { x: bd.cork.x; y: bd.cork.y; width: 2; height: bd.cork.height; color: bd.pBlack }
        // resize grip: three little ridges in the corner of the frame
        Repeater {
            model: 3
            Rectangle { required property int index; x: bd.bw - 8 - index * 4; y: bd.bh - 8; width: 2; height: 4; color: "#c25e00" }
        }
    }
    PixelText {
        x: plate.x; y: plate.y; width: plate.width; height: plate.height
        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
        text: "CORKBOARD"
        font.pixelSize: 10
        color: bd.pBlack
    }
    PixelText {
        visible: bd.cards.length === 0
        anchors.horizontalCenter: hit.horizontalCenter
        y: bd.cork.y + bd.cork.height / 2 - 14
        horizontalAlignment: Text.AlignHCenter
        text: "DROP A NOTE HERE\nTO KEEP IT IN SIGHT"
        font.pixelSize: 11
        color: "#ffb85c"
    }

    PixelText {
        x: bd.bw - 26; y: 5; width: 16; height: 16
        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
        text: "X"
        font.pixelSize: 10
        color: bd.pBlack
    }

    // ---- move: drag the top of the frame (applied once a frame, like the cabinet) --------------
    MouseArea {
        id: moveArea
        x: 0; y: 0; width: bd.bw; height: bd.topF - 2
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        property real sx: 0
        property real sy: 0
        property real lx: 0
        property real ly: 0
        property bool dirty: false
        onPressed: m => { sx = m.x; sy = m.y; lx = m.x; ly = m.y; menu.visible = false }
        onPositionChanged: m => { lx = m.x; ly = m.y; dirty = true }
        onReleased: bd.app.setBoard({ x: bd.px, y: bd.py })
        // close the board (the cards stay pinned; it comes back with them)
        MouseArea {
            id: closeArea
            x: bd.bw - 28; y: 3; width: 20; height: 20
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { menu.visible = false; bd.app.setBoard({ hidden: true }) }
        }
        Timer {
            interval: 16; repeat: true; running: moveArea.pressed
            onTriggered: {
                if (!moveArea.dirty) return
                moveArea.dirty = false
                bd.px = bd.clampX(bd.px + Math.round(moveArea.lx - moveArea.sx))
                bd.py = bd.clampY(bd.py + Math.round(moveArea.ly - moveArea.sy))
            }
        }
    }
    // ---- resize: the bottom-right corner -------------------------------------------------------
    MouseArea {
        x: bd.bw - 16; y: bd.bh - 16; width: 16; height: 16
        cursorShape: Qt.SizeFDiagCursor
        property real sx: 0
        property real sy: 0
        property int w0: 0
        property int h0: 0
        onPressed: m => { const p = mapToItem(null, m.x, m.y); sx = p.x; sy = p.y; w0 = bd.bw; h0 = bd.bh }
        onPositionChanged: m => {
            const p = mapToItem(null, m.x, m.y)
            bd.bw = bd.snap(Math.max(280, w0 + p.x - sx))
            bd.bh = bd.snap(Math.max(260, h0 + p.y - sy))
        }
        onReleased: bd.app.setBoard({ w: bd.bw, h: bd.bh })
    }

    // ---- cards -------------------------------------------------------------------------------
    Repeater {
        model: bd.cards
        delegate: Item {
            id: card
            required property var modelData
            readonly property var n: modelData.n
            readonly property var pal: bd.app.palette[(n.color || 0) % bd.app.palette.length]
            property real dx: 0          // offset while dragged
            property real dy: 0
            x: modelData.x + dx; y: modelData.y + dy
            width: bd.cw; height: bd.ch
            z: bd.dragId === n.id ? 10 : 1
            // dragged off the board: shrink a little and go faint, so it reads as "coming off"
            readonly property bool off: bd.dragId === n.id && !bd.inCork(bd.px + x + dragArea.mx, bd.py + y + dragArea.my)
            opacity: off ? 0.6 : 1

            // a layer only draws inside its own box, so leave room for the pin and the shadow
            Item {
                x: -6; y: -6; width: card.width + 12; height: card.height + 12
                layer.enabled: true
                layer.smooth: false
                layer.effect: Dither { px: bd.chunk; pal: aga.tex; count: aga.count }
                Item {
                x: 6; y: 6; width: card.width; height: card.height
                Rectangle { x: 4; y: 4; width: card.width; height: card.height; color: Qt.rgba(0, 0, 0, 0.45) }
                Rectangle {
                    width: card.width; height: card.height
                    border.color: bd.pBlack; border.width: 2
                    gradient: Gradient {
                        GradientStop { position: 0; color: "#f4f3ec" }
                        GradientStop { position: 1; color: "#d9d7cb" }
                    }
                }
                Rectangle { x: 2; y: 2; width: card.width - 4; height: 14; color: card.pal.a }
                Rectangle { x: 2; y: 16; width: card.width - 4; height: 2; color: bd.pBlack }
                // the pushpin
                Rectangle { x: card.width / 2 - 2; y: 4; width: 4; height: 4; color: Qt.rgba(0, 0, 0, 0.5) }
                Rectangle { x: card.width / 2 - 6; y: -6; width: 12; height: 12; color: bd.pinFor(card.n); border.color: bd.pBlack; border.width: 2 }
                Rectangle { x: card.width / 2 - 4; y: -4; width: 4; height: 2; color: bd.pWhite }
                Rectangle { x: card.width / 2 - 4; y: -4; width: 2; height: 4; color: bd.pWhite }
                }
            }
            PixelText {
                x: 6; y: 3; width: card.width - 12 - (out.visible ? out.width + 2 : 0); height: 12
                verticalAlignment: Text.AlignVCenter
                text: bd.app.titleOf(card.n).toUpperCase()
                elide: Text.ElideRight
                font.pixelSize: 9
                color: bd.pBlack
            }
            // the note is out on the desktop right now
            PixelText {
                id: out
                visible: !card.n.stashed
                anchors { right: parent.right; rightMargin: 5 }
                y: 3; height: 12
                verticalAlignment: Text.AlignVCenter
                text: "OUT"
                font.pixelSize: 8
                color: bd.pWhite
            }
            PixelText {
                x: 6; y: 21; width: card.width - 12
                height: card.height - 25
                text: bd.bodyOf(card.n)
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                elide: Text.ElideRight
                maximumLineCount: 4
                lineHeight: 1.05
                font.pixelSize: 9
                font.bold: false
                color: "#42454b"
                clip: true
            }

            // pick it up / move it / click it
            MouseArea {
                id: dragArea
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: bd.dragId === card.n.id ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                property real sx: 0
                property real sy: 0
                property real mx: 0      // pointer inside the card
                property real my: 0
                property bool moved: false
                onPressed: m => {
                    menu.visible = false
                    if (m.button === Qt.RightButton) return
                    const p = mapToItem(null, m.x, m.y)
                    sx = p.x; sy = p.y; mx = m.x; my = m.y; moved = false
                }
                onPositionChanged: m => {
                    if (!(m.buttons & Qt.LeftButton)) return
                    const p = mapToItem(null, m.x, m.y)
                    if (!moved && Math.hypot(p.x - sx, p.y - sy) < 5) return
                    if (!moved) { moved = true; bd.dragId = card.n.id; bd.app.dragNote = card.n.id }
                    card.dx = bd.snap(p.x - sx); card.dy = bd.snap(p.y - sy)
                    // tell the cabinet where the pointer is, so its drawers open under it
                    bd.app.dragX = bd.px + p.x; bd.app.dragY = bd.py + p.y
                }
                onReleased: m => {
                    if (m.button === Qt.RightButton) { menu.show(card.n, card.x + m.x, card.y + m.y); return }
                    const id = card.n.id
                    if (!moved) { bd.open(card.n, card.y); return }
                    const p = mapToItem(null, m.x, m.y)
                    const nx = card.x, ny = card.y
                    card.dx = 0; card.dy = 0
                    bd.dragId = ""; bd.app.dragNote = ""
                    if (bd.inCork(bd.px + p.x, bd.py + p.y)) {
                        bd.app.setCardPos(id, nx, ny)
                    } else {
                        // off the board: take it down, and let the cabinet file it if it went there
                        bd.app.unpinFromBoard(id)
                        bd.app.noteDropped(id, bd.px + p.x, bd.py + p.y)
                    }
                }
                onCanceled: { card.dx = 0; card.dy = 0; bd.dragId = ""; bd.app.dragNote = "" }
            }
        }
    }

    // ---- right-click menu on a card --------------------------------------------------------------
    MouseArea { anchors.fill: parent; visible: menu.visible; z: 19; onPressed: menu.visible = false }
    Rectangle {
        id: menu
        visible: false
        z: 20
        property var n: ({})
        readonly property var items: [
            { t: "OPEN", go: () => bd.open(menu.n, menu.y) },
            { t: "TAKE OFF BOARD", go: () => bd.app.unpinFromBoard(menu.n.id) }
        ]
        function show(n, x, y) {
            menu.n = n
            menu.x = Math.max(4, Math.min(bd.bw - width - 4, x))
            menu.y = Math.max(4, Math.min(bd.bh - height - 4, y))
            menu.visible = true
        }
        width: 124; height: col.implicitHeight + 8
        color: "#dfe1e3"
        border.color: bd.pBlack; border.width: 2
        Column {
            id: col
            x: 4; y: 4; width: parent.width - 8
            Repeater {
                model: menu.items
                Rectangle {
                    required property var modelData
                    width: col.width; height: 16
                    color: item.containsMouse ? bd.pOrange : "transparent"
                    PixelText { x: 4; anchors.verticalCenter: parent.verticalCenter; text: parent.modelData.t; font.pixelSize: 9; color: bd.pBlack }
                    MouseArea {
                        id: item
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { menu.visible = false; parent.modelData.go() }
                    }
                }
            }
        }
    }
}
