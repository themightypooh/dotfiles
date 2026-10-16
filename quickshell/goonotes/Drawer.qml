// The drawer: every note in one place. Search, filter by category / desktop / stash,
// re-file notes, stash or bring them back, delete. Click a note to bring it forward on the desktop.
import QtQuick
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: drawer
    required property var app

    visible: app.drawerOpen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "goonotes-drawer"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    // "@all", "@desk", "@stash", "" (unsorted) or a category name
    property string filter: "@all"
    // a drawer of the file cabinet was clicked: show just that category
    Connections { target: drawer.app; function onBrowseRequested(cat) { drawer.query = ""; drawer.filter = cat } }
    property string query: ""
    property string armed: ""      // note or category waiting for a second delete click
    property string pickFor: ""    // note whose category menu is open
    property point pickAt: Qt.point(0, 0)

    onVisibleChanged: if (visible) { search.forceActiveFocus(); search.selectAll() } else pickFor = ""
    Timer { id: disarm; interval: 2500; onTriggered: drawer.armed = "" }
    function arm(key) { armed = key; disarm.restart() }

    function matches(n) {
        if (filter === "@desk" && n.stashed) return false
        if (filter === "@stash" && !n.stashed) return false
        if (filter[0] !== "@" && (n.category || "") !== filter) return false
        if (query && (n.text || "").toLowerCase().indexOf(query.toLowerCase()) < 0
                  && (n.category || "").indexOf(query.toLowerCase()) < 0) return false
        return true
    }
    readonly property var items: {
        app.rev
        return app.ids.map(i => app.store[i]).filter(n => n && matches(n))
                      .sort((a, b) => (b.updated || b.created || 0) - (a.updated || a.created || 0))
    }
    function count(f) {
        app.rev
        let c = 0
        for (const i of app.ids) {
            const n = app.store[i]
            if (!n) continue
            if (f === "@all" || (f === "@desk" && !n.stashed) || (f === "@stash" && n.stashed)
                || (f[0] !== "@" && (n.category || "") === f)) c++
        }
        return c
    }
    function palFor(n) { return app.palette[(n.color || 0) % app.palette.length] }
    function title(n) {
        const line = (n.text || "").split("\n").find(l => l.trim()) || ""
        return line.trim() || "empty note"
    }
    function preview(n) {
        const lines = (n.text || "").split("\n")
        const i = lines.findIndex(l => l.trim())
        return i < 0 ? "" : lines.slice(i + 1).join("\n").trim()
    }

    // dim backdrop; click it to close
    Rectangle {
        anchors.fill: parent
        color: "#cc000000"
        opacity: drawer.visible ? 1 : 0
        MouseArea { anchors.fill: parent; onClicked: drawer.app.drawerOpen = false }
    }

    Rectangle {
        id: panel
        width: Math.min(980, parent.width - 80)
        height: Math.min(660, parent.height - 80)
        anchors.centerIn: parent
        radius: 18
        color: drawer.app.backing
        border.color: drawer.app.rim
        border.width: 1
        MouseArea { anchors.fill: parent; onClicked: drawer.pickFor = "" }

        Canvas {
            anchors.fill: parent
            anchors.margins: 8
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                ctx.fillStyle = drawer.app.dotColor
                for (let y = 4; y < height; y += 9)
                    for (let x = 4; x < width; x += 9) { ctx.beginPath(); ctx.arc(x, y, 1.3, 0, 6.2832); ctx.fill() }
            }
        }

        Keys.onEscapePressed: drawer.app.drawerOpen = false

        // ---- top bar -------------------------------------------------------
        Item {
            id: top
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: 18 }
            height: 36

            Column {
                anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                spacing: 3
                Text {
                    text: "goonotes"
                    font.family: drawer.app.block
                    font.pixelSize: 16
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: 3
                    color: drawer.app.ink
                }
                Text {
                    text: drawer.count("@all") + " notes · " + drawer.count("@desk") + " out · "
                          + drawer.count("@stash") + " stashed"
                    font.family: drawer.app.block
                    font.pixelSize: 9
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: 1.4
                    color: drawer.app.dim
                }
            }

            Row {
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                spacing: 10

                Rectangle {
                    width: 280; height: 32; radius: 16
                    color: Qt.alpha(drawer.app.ink, 0.06)
                    border.color: search.activeFocus ? Qt.alpha(drawer.app.palette[0].a, 0.8) : drawer.app.rim
                    Text {
                        id: searchIcon
                        anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                        text: ""; font.family: drawer.app.mono; font.pixelSize: 12; color: drawer.app.dim
                    }
                    TextInput {
                        id: search
                        anchors { left: searchIcon.right; leftMargin: 8; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                        clip: true
                        color: drawer.app.ink
                        font.family: drawer.app.mono
                        font.pixelSize: 13
                        selectByMouse: true
                        onTextChanged: drawer.query = text
                        Keys.onEscapePressed: { if (text) text = ""; else drawer.app.drawerOpen = false }
                        onAccepted: if (drawer.items.length) drawer.app.reveal(drawer.items[0].id)
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !search.text
                            text: "search notes…"
                            color: drawer.app.dim
                            font: search.font
                        }
                    }
                }

                Rectangle {
                    width: newLabel.implicitWidth + 28; height: 32; radius: 16
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0; color: Qt.alpha(drawer.app.palette[0].a, newArea.containsMouse ? 0.55 : 0.35) }
                        GradientStop { position: 1; color: Qt.alpha(drawer.app.palette[0].b, newArea.containsMouse ? 0.55 : 0.35) }
                    }
                    Text {
                        id: newLabel
                        anchors.centerIn: parent
                        text: "+ new"
                        font.family: drawer.app.block
                        font.pixelSize: 11
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: 1.5
                        color: drawer.app.ink
                    }
                    MouseArea {
                        id: newArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            const cat = drawer.filter[0] === "@" ? "" : drawer.filter
                            drawer.app.reveal(drawer.app.newNote("", cat))
                        }
                    }
                }
            }
        }

        // ---- sidebar: filters + categories ----------------------------------
        Flickable {
            id: side
            anchors { top: top.bottom; topMargin: 18; left: parent.left; leftMargin: 14; bottom: parent.bottom; bottomMargin: 14 }
            width: 190
            contentHeight: sideCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: sideCol
                width: side.width
                spacing: 2

                Repeater {
                    model: [{ key: "@all", label: "all notes", icon: "" },
                            { key: "@desk", label: "on desktop", icon: "" },
                            { key: "@stash", label: "stashed", icon: "" }]
                    FilterRow {
                        required property var modelData
                        key: modelData.key; label: modelData.label; icon: modelData.icon
                    }
                }

                Text {
                    topPadding: 14; bottomPadding: 6; leftPadding: 10
                    text: "categories"
                    font.family: drawer.app.block
                    font.pixelSize: 9
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: 1.6
                    color: drawer.app.dim
                }

                Repeater {
                    model: { drawer.app.rev; return drawer.app.categories }
                    FilterRow {
                        required property string modelData
                        key: modelData; label: modelData; icon: ""; removable: true
                    }
                }
                FilterRow { key: ""; label: "unsorted"; icon: "" }

                Rectangle {
                    width: sideCol.width; height: 28; radius: 8
                    color: Qt.alpha(drawer.app.ink, 0.05)
                    border.color: catInput.activeFocus ? Qt.alpha(drawer.app.ink, 0.3) : "transparent"
                    TextInput {
                        id: catInput
                        anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                        verticalAlignment: TextInput.AlignVCenter
                        clip: true
                        color: drawer.app.ink
                        font.family: drawer.app.mono
                        font.pixelSize: 12
                        onAccepted: { const n = text.trim().toLowerCase(); if (n) { drawer.app.addCategory(n); drawer.filter = n; text = "" } }
                        Keys.onEscapePressed: { text = ""; search.forceActiveFocus() }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !catInput.text && !catInput.activeFocus
                            text: "+ new category"
                            color: drawer.app.dim
                            font: catInput.font
                        }
                    }
                }
            }
        }

        // ---- note grid --------------------------------------------------------
        GridView {
            id: grid
            anchors { top: top.bottom; topMargin: 18; left: side.right; leftMargin: 14; right: parent.right; rightMargin: 14; bottom: parent.bottom; bottomMargin: 14 }
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            readonly property int cols: Math.max(1, Math.floor(width / 230))
            cellWidth: Math.floor(width / cols)
            cellHeight: 168
            model: drawer.items

            delegate: Item {
                id: cell
                required property var modelData
                readonly property var n: modelData
                readonly property var pal: drawer.palFor(n)
                width: grid.cellWidth; height: grid.cellHeight

                Rectangle {
                    id: noteCard
                    anchors { fill: parent; margins: 5 }
                    radius: 12
                    color: cardArea.containsMouse ? "#ff16171d" : "#ff0f1015"
                    border.color: cardArea.containsMouse ? Qt.alpha(cell.pal.a, 0.6) : drawer.app.rim
                    border.width: 1
                    opacity: cell.n.stashed ? 0.72 : 1
                    Behavior on border.color { ColorAnimation { duration: 120 } }

                    // goo strip in the note's colors
                    Rectangle {
                        anchors { top: parent.top; left: parent.left; right: parent.right; margins: 1 }
                        height: 4; radius: 2
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0; color: cell.pal.a }
                            GradientStop { position: 1; color: cell.pal.b }
                        }
                    }

                    MouseArea {
                        id: cardArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: drawer.app.reveal(cell.n.id)
                    }

                    Column {
                        anchors { top: parent.top; topMargin: 14; left: parent.left; leftMargin: 12; right: parent.right; rightMargin: 12 }
                        spacing: 6
                        Text {
                            width: parent.width
                            text: drawer.title(cell.n)
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            font.family: drawer.app.mono
                            font.pixelSize: 13
                            font.bold: true
                            color: cell.n.text ? drawer.app.ink : drawer.app.dim
                        }
                        Text {
                            width: parent.width
                            height: 64
                            text: drawer.preview(cell.n)
                            textFormat: Text.PlainText
                            wrapMode: Text.Wrap
                            elide: Text.ElideRight
                            maximumLineCount: 4
                            clip: true
                            font.family: drawer.app.mono
                            font.pixelSize: 11
                            lineHeight: 1.1
                            color: Qt.alpha(drawer.app.ink, 0.6)
                        }
                    }

                    // bottom row: category tag, age, actions
                    Item {
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 8 }
                        height: 24

                        Rectangle {
                            id: tag
                            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                            width: Math.min(tagText.implicitWidth + 16, parent.width - acts.width - 60)
                            height: 22; radius: 11
                            color: tagArea.containsMouse || drawer.pickFor === cell.n.id ? Qt.alpha(cell.pal.a, 0.25) : Qt.alpha(drawer.app.ink, 0.06)
                            Text {
                                id: tagText
                                anchors { left: parent.left; leftMargin: 8; right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
                                text: cell.n.category || "unsorted"
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                font.family: drawer.app.block
                                font.pixelSize: 9
                                font.capitalization: Font.AllUppercase
                                font.letterSpacing: 1.2
                                color: cell.n.category ? drawer.app.ink : drawer.app.dim
                            }
                            MouseArea {
                                id: tagArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    const p = tag.mapToItem(panel, 0, tag.height + 4)
                                    drawer.pickAt = p
                                    drawer.pickFor = drawer.pickFor === cell.n.id ? "" : cell.n.id
                                }
                            }
                        }
                        Text {
                            anchors { left: tag.right; leftMargin: 8; verticalCenter: parent.verticalCenter }
                            text: drawer.app.ago(cell.n.updated || cell.n.created)
                            font.family: drawer.app.mono
                            font.pixelSize: 10
                            color: drawer.app.dim
                        }
                        Row {
                            id: acts
                            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                            spacing: 0
                            NoteButton {
                                app: drawer.app; tip: cell.pal.b
                                glyph: cell.n.stashed ? "" : ""
                                lit: !cell.n.stashed
                                onClicked: drawer.app.stash(cell.n.id, !cell.n.stashed)
                            }
                            NoteButton {
                                app: drawer.app; tip: drawer.app.danger
                                glyph: drawer.armed === cell.n.id ? "" : ""
                                lit: drawer.armed === cell.n.id
                                onClicked: { if (drawer.armed === cell.n.id) drawer.app.remove(cell.n.id); else drawer.arm(cell.n.id) }
                            }
                        }
                    }
                }
            }

            Text {
                anchors.centerIn: parent
                visible: grid.count === 0
                horizontalAlignment: Text.AlignHCenter
                text: drawer.query ? "nothing matches \"" + drawer.query + "\""
                    : drawer.filter === "@stash" ? "nothing stashed\nhit the box on a note to stash it here"
                    : "no notes here yet\n+ new makes one in this category"
                font.family: drawer.app.mono
                font.pixelSize: 12
                lineHeight: 1.4
                color: drawer.app.dim
            }
        }

        CategoryMenu {
            visible: drawer.pickFor !== ""
            x: Math.min(drawer.pickAt.x, panel.width - width - 10)
            y: Math.min(drawer.pickAt.y, panel.height - height - 10)
            app: drawer.app
            current: { drawer.app.rev; const n = drawer.app.store[drawer.pickFor]; return n ? n.category || "" : "" }
            maxHeight: 300
            onPicked: name => { drawer.app.setCategory(drawer.pickFor, name); drawer.pickFor = "" }
            onDismissed: drawer.pickFor = ""
        }
    }

    // one sidebar row: icon, label, count; categories get a two-click remove button on hover
    component FilterRow: Rectangle {
        id: row
        property string key: ""
        property string label: ""
        property string icon: ""
        property bool removable: false
        readonly property bool active: drawer.filter === key
        width: sideCol.width; height: 30; radius: 8
        color: active ? Qt.alpha(drawer.app.palette[0].a, 0.22)
             : rowArea.containsMouse ? Qt.alpha(drawer.app.ink, 0.06) : "transparent"
        MouseArea { id: rowArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
            onClicked: drawer.filter = row.key }
        Text {
            id: rowIcon
            anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
            width: 16
            text: row.icon
            font.family: drawer.app.mono
            font.pixelSize: 12
            color: row.active ? drawer.app.palette[0].b : drawer.app.dim
        }
        Text {
            anchors { left: rowIcon.right; leftMargin: 6; right: rowCount.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
            text: row.label
            elide: Text.ElideRight
            font.family: drawer.app.mono
            font.pixelSize: 12
            color: row.active ? drawer.app.ink : Qt.alpha(drawer.app.ink, 0.75)
        }
        Text {
            id: rowCount
            anchors { right: rm.visible ? rm.left : parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
            text: drawer.count(row.key)
            font.family: drawer.app.mono
            font.pixelSize: 11
            font.features: { "tnum": 1 }
            color: drawer.app.dim
        }
        NoteButton {
            id: rm
            anchors { right: parent.right; rightMargin: 3; verticalCenter: parent.verticalCenter }
            visible: row.removable && (rowArea.containsMouse || drawer.armed === "cat:" + row.key)
            app: drawer.app; tip: drawer.app.danger
            glyph: drawer.armed === "cat:" + row.key ? "" : ""
            lit: drawer.armed === "cat:" + row.key
            onClicked: {
                if (drawer.armed === "cat:" + row.key) {
                    if (drawer.filter === row.key) drawer.filter = "@all"
                    drawer.app.removeCategory(row.key)
                    drawer.armed = ""
                } else drawer.arm("cat:" + row.key)
            }
        }
    }
}
