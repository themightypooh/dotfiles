// Pop-up menu for a note, on the note's paper style; it can hang past the note's edges.
//   menu.show(x, y, [ { text, key, act, checked, danger, confirm, enabled }, { sep: true },
//                     { swatch: i, text, act, checked }, { swatches: true, current, pick: i => ... }, ... ])
// x, y are in the note window's coordinates; the menu opens down and to the right of them.
// confirm: true items need a second click. Click outside or press Esc to dismiss.
import QtQuick
import Quickshell

PopupWindow {
    id: menu
    required property var app
    required property var note           // the note window it belongs to

    property var items: []
    property int armed: -1
    property int hot: -1                  // row under the pointer or picked with the arrow keys
    property bool grab: true              // off only for test peeks (a grab needs a real click first)
    Timer { id: disarm; interval: 3000; onTriggered: menu.armed = -1 }

    readonly property color paper: "#efeee6"
    readonly property color ink: "#141418"
    readonly property color dim: "#8f949a"
    readonly property int rowH: 24

    function show(x, y, items) {
        visible = false
        menu.items = items
        let w = 90
        for (const it of items) if (!it.sep) { tm.text = (it.confirm ? "click again: " : "") + (it.text || ""); w = Math.max(w, tm.advanceWidth) }
        labelW = Math.ceil(w)
        armed = -1; hot = -1
        anchor.rect.x = Math.round(x)
        anchor.rect.y = Math.round(y)
        visible = true
        card.forceActiveFocus()
    }
    function hide() { visible = false }
    function usable(it) { return !!it && !it.sep && !it.swatches && it.enabled !== false }
    function pick(i) {
        const it = items[i]
        if (!usable(it)) return
        if (it.confirm && armed !== i) { armed = i; disarm.restart(); return }
        hide()
        if (it.act) it.act()
    }
    function step(d) {
        for (let k = 1; k <= items.length; k++) {
            const i = ((hot < 0 ? (d > 0 ? -1 : 0) : hot) + d * k + items.length * 4) % items.length
            if (usable(items[i])) { hot = i; return }
        }
    }

    anchor.window: note
    anchor.rect.width: 1
    anchor.rect.height: 1
    anchor.edges: Edges.Top | Edges.Left
    anchor.gravity: Edges.Bottom | Edges.Right
    grabFocus: grab
    color: "transparent"
    implicitWidth: card.width + 6
    implicitHeight: card.height + 6

    TextMetrics { id: tm; font.family: "monospace"; font.bold: true; font.pixelSize: 12 }
    property real labelW: 90           // widest label, measured when the menu opens

    // hard pixel shadow, like the notes
    Rectangle { x: 6; y: 6; width: card.width; height: card.height; color: "#141418"; opacity: 0.45 }

    Rectangle {
        id: card
        width: menu.labelW + 104
        height: col.height + 8
        color: menu.paper
        border.color: menu.ink
        border.width: 2
        focus: true
        Keys.onPressed: e => {
            if (e.key === Qt.Key_Escape) menu.hide()
            else if (e.key === Qt.Key_Down) menu.step(1)
            else if (e.key === Qt.Key_Up) menu.step(-1)
            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) menu.pick(menu.hot)
            else return
            e.accepted = true
        }

        Column {
            id: col
            x: 4; y: 4
            width: card.width - 8
            Repeater {
                model: menu.items
                delegate: Item {
                    id: row
                    required property var modelData
                    required property int index
                    readonly property var it: modelData
                    readonly property bool on: menu.hot === index && menu.usable(it)
                    width: col.width
                    height: it.sep ? 8 : menu.rowH

                    Rectangle { visible: !!row.it.sep; x: 4; width: parent.width - 8; y: 3; height: 2; color: "#c5c8cc" }

                    // a row of colour chips: click one to recolour the note
                    Row {
                        visible: !!row.it.swatches
                        x: 10; anchors.verticalCenter: parent.verticalCenter
                        spacing: 6
                        Repeater {
                            model: row.it.swatches ? menu.app.palette.length : 0
                            Rectangle {
                                id: sw
                                required property int index
                                readonly property var p: menu.app.palette[index]
                                width: 26; height: 16
                                border.color: menu.ink
                                border.width: index === row.it.current || swArea.containsMouse ? 3 : 1
                                gradient: Gradient {
                                    orientation: Gradient.Horizontal
                                    GradientStop { position: 0; color: sw.p.a }
                                    GradientStop { position: 1; color: sw.p.b }
                                }
                                MouseArea { id: swArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { menu.hide(); row.it.pick(sw.index) } }
                            }
                        }
                    }
                    Rectangle {
                        visible: !row.it.sep && !row.it.swatches
                        anchors.fill: parent
                        color: row.on ? (row.it.danger ? "#e24b4a" : "#c5c8cc") : "transparent"
                    }
                    // colour rows: a chip of the note's two colours
                    Rectangle {
                        id: chip
                        visible: row.it.swatch !== undefined
                        x: 8; anchors.verticalCenter: parent.verticalCenter
                        width: 26; height: 14
                        border.color: menu.ink; border.width: 2
                        readonly property var p: row.it.swatch !== undefined ? menu.app.palette[row.it.swatch] : null
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0; color: chip.p ? chip.p.a : "#000" }
                            GradientStop { position: 1; color: chip.p ? chip.p.b : "#000" }
                        }
                    }
                    Text {
                        visible: !row.it.sep && !row.it.swatches
                        x: row.it.swatch !== undefined ? 42 : 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: (row.it.checked ? "• " : "") + (menu.armed === row.index ? "click again: " : "") + (row.it.text || "")
                        font.family: "monospace"; font.bold: true; font.pixelSize: 12
                        renderType: Text.NativeRendering
                        color: row.it.enabled === false ? menu.dim
                             : row.it.danger && !row.on ? "#b02a29" : menu.ink
                    }
                    Text {
                        visible: !!row.it.key
                        anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                        text: row.it.key || ""
                        font.family: "monospace"; font.pixelSize: 11
                        renderType: Text.NativeRendering
                        color: menu.dim
                    }
                    MouseArea {
                        visible: !row.it.sep && !row.it.swatches
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: menu.usable(row.it) ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onContainsMouseChanged: if (containsMouse) menu.hot = row.index
                        onClicked: menu.pick(row.index)
                    }
                }
            }
        }
    }
}
