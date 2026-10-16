// Right-click menu for the bar: a dark rounded card that pops up out of the bar.
//   menu.show(x, y, "title", [ { text, icon, act, checked, danger, confirm, enabled }, { sep: true }, ... ])
// A slider row: { slider: true, icon, get: () => 0..1, set: v => ..., act } (act = click on its icon)
// x, y are in the bar window's coordinates; the card grows upward from there.
// confirm: true items need a second click. Click outside or press Esc to dismiss.
import QtQuick
import Quickshell
import Quickshell.Widgets

PopupWindow {
    id: menu
    required property var root
    required property var bar

    property string title: ""
    property var items: []
    property int armed: -1
    property real textW: 0
    TextMetrics { id: metrics; font.pixelSize: 12 }
    Timer { id: disarm; interval: 3000; onTriggered: menu.armed = -1 }

    function show(x, y, title, items) {
        visible = false
        menu.title = title || ""
        menu.items = items
        // size the card to the widest label (+ room for "again to …" on confirm items)
        let w = 0
        for (const it of items) {
            if (it.sep) continue
            if (it.slider) { w = Math.max(w, 190); continue }
            metrics.text = (it.confirm ? "again to " : "") + (it.text || "")
            w = Math.max(w, metrics.advanceWidth)
        }
        textW = Math.ceil(w)
        armed = -1
        anchor.rect.x = Math.round(x)
        anchor.rect.y = Math.round(y)
        visible = true
        card.forceActiveFocus()
    }
    function hide() { visible = false; grabFocus = true }
    function pick(i) {
        const it = items[i]
        if (!it || it.sep || it.enabled === false) return
        if (it.confirm && armed !== i) { armed = i; disarm.restart(); return }
        hide()
        if (it.act) it.act()
    }

    anchor.window: bar
    anchor.rect.width: 1
    anchor.rect.height: 1
    anchor.edges: Edges.Top
    anchor.gravity: Edges.Top
    grabFocus: true
    color: "transparent"
    implicitWidth: card.width + 16
    implicitHeight: card.height + 16

    // pop in from the bar: grow from the bottom edge
    property real pop: 0
    onVisibleChanged: if (visible) { pop = 0; popIn.restart() }
    NumberAnimation { id: popIn; target: menu; property: "pop"; to: 1; duration: 220; easing.type: Easing.OutBack; easing.overshoot: 1.6 }

    Rectangle {
        id: card
        x: 8; y: 8
        width: Math.min(340, Math.max(170, menu.textW + 34 + 28 + 12))
        height: list.implicitHeight + 12
        radius: 14
        color: menu.root.backing
        border.color: menu.root.rim; border.width: 1
        opacity: Math.min(1, menu.pop * 1.5)
        scale: 0.85 + 0.15 * menu.pop
        transformOrigin: Item.Bottom
        focus: true
        Keys.onEscapePressed: menu.hide()

        // a strip of the bar's goo along the top
        Rectangle {
            x: 14; y: 0; width: parent.width - 28; height: 2; radius: 1
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: menu.root.gooA }
                GradientStop { position: 1; color: menu.root.gooB }
            }
        }

        Column {
            id: list
            x: 6; y: 6
            width: card.width - 12

            Text {
                visible: menu.title !== ""
                width: parent.width
                leftPadding: 10; rightPadding: 10; topPadding: 4; bottomPadding: 6
                text: menu.title
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: "#77ffffff"; font.pixelSize: 10; font.family: "monospace"
            }

            Repeater {
                model: menu.items
                delegate: Item {
                    id: row
                    required property var modelData
                    required property int index
                    readonly property bool sep: modelData.sep === true
                    readonly property bool slider: modelData.slider === true
                    readonly property bool on: modelData.enabled !== false
                    readonly property bool isArmed: menu.armed === index
                    width: list.width
                    height: sep ? 9 : slider ? 34 : 30

                    Rectangle {
                        visible: row.sep
                        x: 10; width: parent.width - 20; height: 1
                        anchors.verticalCenter: parent.verticalCenter
                        color: "#22ffffff"
                    }
                    Rectangle {
                        visible: !row.sep && !row.slider
                        anchors.fill: parent; radius: 9
                        color: row.isArmed || row.modelData.danger ? "#f09595" : "#ffffff"
                        opacity: row.isArmed ? 0.22 : rowMouse.containsMouse && row.on ? 0.14 : 0
                        Behavior on opacity { NumberAnimation { duration: 110 } }
                    }
                    IconImage {
                        visible: !row.sep && !!row.modelData.icon
                        x: 10; anchors.verticalCenter: parent.verticalCenter
                        implicitSize: 16
                        opacity: row.on ? 1 : 0.35
                        // icon may be a function so it can follow live state (e.g. muted)
                        readonly property string name: typeof row.modelData.icon === "function" ? row.modelData.icon() : (row.modelData.icon || "")
                        source: name ? Quickshell.iconPath(name, true) : ""
                    }
                    Text {
                        id: rowText
                        visible: !row.sep && !row.slider
                        x: 34; anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 34 - 28
                        elide: Text.ElideRight
                        text: row.isArmed ? "again to " + (row.modelData.text || "").toLowerCase() : (row.modelData.text || "")
                        textFormat: Text.PlainText
                        color: row.isArmed || (row.modelData.danger && rowMouse.containsMouse) ? "#ffb4b4" : "white"
                        opacity: row.on ? 1 : 0.35
                        font.pixelSize: 12
                    }
                    // checkmark for toggles
                    Rectangle {
                        visible: !row.sep && row.modelData.checked !== undefined
                        anchors.right: parent.right; anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        width: 8; height: 8; radius: 4
                        color: row.modelData.checked ? "#9fe1cb" : "transparent"
                        border.color: row.modelData.checked ? "#9fe1cb" : "#55ffffff"; border.width: 1
                    }
                    // slider: drag or click along the track, wheel nudges
                    Item {
                        id: slide
                        visible: row.slider
                        readonly property real value: row.slider && row.modelData.get ? Math.max(0, Math.min(1, row.modelData.get())) : 0
                        x: 34; width: parent.width - 34 - 46; height: parent.height
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width; height: 4; radius: 2; color: "#33ffffff"
                        }
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width * slide.value; height: 4; radius: 2
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0; color: menu.root.gooA }
                                GradientStop { position: 1; color: menu.root.gooB }
                            }
                        }
                        Rectangle {
                            x: parent.width * slide.value - 6; anchors.verticalCenter: parent.verticalCenter
                            width: 12; height: 12; radius: 6; color: "white"
                            scale: slideMouse.pressed ? 1.25 : slideMouse.containsMouse ? 1.1 : 1
                            Behavior on scale { NumberAnimation { duration: 100 } }
                        }
                        MouseArea {
                            id: slideMouse
                            anchors.fill: parent; anchors.margins: -4
                            enabled: row.slider
                            hoverEnabled: true
                            function setAt(px) { row.modelData.set(Math.max(0, Math.min(1, (px - 4) / slide.width))) }
                            onPressed: m => setAt(m.x)
                            onPositionChanged: m => { if (pressed) setAt(m.x) }
                            onWheel: w => row.modelData.set(Math.max(0, Math.min(1, slide.value + (w.angleDelta.y > 0 ? 0.05 : -0.05))))
                        }
                    }
                    Text {
                        visible: row.slider
                        anchors.right: parent.right; anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: Math.round(slide.value * 100) + "%"
                        color: "#ccffffff"; font.pixelSize: 11; font.family: "monospace"
                    }
                    MouseArea {
                        // the slider's icon: e.g. mute
                        visible: row.slider
                        x: 4; width: 28; height: parent.height
                        onClicked: if (row.modelData.act) row.modelData.act()
                    }
                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        visible: !row.slider
                        enabled: !row.sep
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: menu.pick(row.index)
                    }
                }
            }
        }
    }
}
