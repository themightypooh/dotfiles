// Month calendar that pops up from the clock, like Plasma's digital clock.
//   cal.toggle(x, y)   x, y in the bar window's coordinates; grows upward from there.
// Wheel or the arrows change month, clicking the title goes back to today.
import QtQuick
import Quickshell

PopupWindow {
    id: cal
    required property var root
    required property var bar

    property int year: 0
    property int month: 0      // 0-11
    readonly property date today: root.now

    function toggle(x, y) {
        if (visible) { visible = false; return }
        year = today.getFullYear(); month = today.getMonth()
        anchor.rect.x = Math.round(x)
        anchor.rect.y = Math.round(y)
        visible = true
        card.forceActiveFocus()
    }
    function shift(d) {
        let m = month + d, y = year
        while (m < 0) { m += 12; y-- }
        while (m > 11) { m -= 12; y++ }
        month = m; year = y
    }

    // 42 cells starting on the Monday on or before the 1st
    readonly property var cells: {
        const first = new Date(year, month, 1)
        const lead = (first.getDay() + 6) % 7
        const out = []
        for (let i = 0; i < 42; i++) out.push(new Date(year, month, 1 - lead + i))
        return out
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

    property real pop: 0
    onVisibleChanged: if (visible) { pop = 0; popIn.restart() }
    NumberAnimation { id: popIn; target: cal; property: "pop"; to: 1; duration: 240; easing.type: Easing.OutBack; easing.overshoot: 1.4 }

    Rectangle {
        id: card
        x: 8; y: 8
        width: 7 * 34 + 24
        height: col.implicitHeight + 24
        radius: 16
        color: cal.root.backing
        border.color: cal.root.rim; border.width: 1
        opacity: Math.min(1, cal.pop * 1.5)
        scale: 0.85 + 0.15 * cal.pop
        transformOrigin: Item.BottomLeft
        focus: true
        Keys.onEscapePressed: cal.visible = false
        Keys.onLeftPressed: cal.shift(-1)
        Keys.onRightPressed: cal.shift(1)

        Rectangle {
            x: 16; y: 0; width: parent.width - 32; height: 2; radius: 1
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: cal.root.gooA }
                GradientStop { position: 1; color: cal.root.gooB }
            }
        }

        WheelHandler { onWheel: e => cal.shift(e.angleDelta.y > 0 ? -1 : 1) }

        Column {
            id: col
            x: 12; y: 12
            spacing: 6

            Text {
                text: Qt.formatDateTime(cal.today, "dddd")
                color: "#99ffffff"; font.pixelSize: 11
            }
            Text {
                text: Qt.formatDateTime(cal.today, "MMMM d, yyyy")
                color: "white"; font.pixelSize: 18; font.weight: Font.Medium
            }
            Item { width: 1; height: 4 }

            // month header with arrows
            Item {
                width: 7 * 34; height: 26
                Text {
                    id: arrowL
                    text: "‹"; color: lMouse.containsMouse ? "white" : "#99ffffff"; font.pixelSize: 20
                    anchors.left: parent.left; anchors.leftMargin: 6; anchors.verticalCenter: parent.verticalCenter
                    MouseArea { id: lMouse; anchors.fill: parent; anchors.margins: -8; hoverEnabled: true; onClicked: cal.shift(-1) }
                }
                Text {
                    anchors.centerIn: parent
                    text: Qt.formatDateTime(new Date(cal.year, cal.month, 1), "MMMM yyyy").toLowerCase()
                    color: titleMouse.containsMouse ? "white" : "#ddffffff"; font.pixelSize: 13; font.family: "monospace"
                    MouseArea {
                        id: titleMouse; anchors.fill: parent; hoverEnabled: true
                        onClicked: { cal.year = cal.today.getFullYear(); cal.month = cal.today.getMonth() }
                    }
                }
                Text {
                    text: "›"; color: rMouse.containsMouse ? "white" : "#99ffffff"; font.pixelSize: 20
                    anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter
                    MouseArea { id: rMouse; anchors.fill: parent; anchors.margins: -8; hoverEnabled: true; onClicked: cal.shift(1) }
                }
            }

            Grid {
                columns: 7
                Repeater {
                    model: ["mo", "tu", "we", "th", "fr", "sa", "su"]
                    Text {
                        required property string modelData
                        width: 34; height: 22
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                        text: modelData; color: "#77ffffff"; font.pixelSize: 10; font.family: "monospace"
                    }
                }
                Repeater {
                    model: cal.cells
                    Item {
                        id: day
                        required property var modelData
                        readonly property bool inMonth: modelData.getMonth() === cal.month
                        readonly property bool isToday: modelData.toDateString() === cal.today.toDateString()
                        width: 34; height: 30
                        Rectangle {
                            anchors.centerIn: parent
                            width: 28; height: 28; radius: 14
                            gradient: day.isToday ? todayFill : null
                            color: "transparent"
                            Gradient {
                                id: todayFill
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0; color: cal.root.gooA }
                                GradientStop { position: 1; color: cal.root.gooB }
                            }
                        }
                        Text {
                            anchors.centerIn: parent
                            text: day.modelData.getDate()
                            color: day.isToday ? "white" : day.inMonth ? "#e6ffffff" : "#44ffffff"
                            font.pixelSize: 12; font.weight: day.isToday ? Font.Bold : Font.Normal
                        }
                    }
                }
            }
        }
    }
}
