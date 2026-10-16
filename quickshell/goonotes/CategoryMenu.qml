// Category picker: existing categories, "unsorted", and a field to make a new one.
import QtQuick

Rectangle {
    id: menu
    required property var app
    property string current: ""
    property real maxHeight: 400
    signal picked(string name)
    signal dismissed()

    readonly property var entries: { app.rev; return [""].concat(app.categories) }
    readonly property int rowH: 24

    width: 180
    height: Math.min(maxHeight, list.contentHeight + newRow.height + 18)
    // paper, like the pixel-art notes
    color: "#efeee6"
    border.color: "#141418"
    border.width: 2

    MouseArea { anchors.fill: parent }   // keep clicks on the menu from closing it

    ListView {
        id: list
        anchors { top: parent.top; left: parent.left; right: parent.right; bottom: newRow.top; margins: 6 }
        clip: true
        model: menu.entries
        boundsBehavior: Flickable.StopAtBounds
        delegate: Rectangle {
            required property string modelData
            width: list.width; height: menu.rowH
            color: rowArea.containsMouse ? "#c5c8cc" : "transparent"
            Text {
                anchors { left: parent.left; leftMargin: 8; right: parent.right; verticalCenter: parent.verticalCenter }
                text: (modelData === menu.current ? "  " : "  ") + (modelData || "unsorted")
                textFormat: Text.PlainText
                elide: Text.ElideRight
                font.family: menu.app.mono
                font.pixelSize: 12
                font.bold: true
                renderType: Text.NativeRendering
                color: modelData ? "#141418" : "#757980"
            }
            MouseArea { id: rowArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: menu.picked(modelData) }
        }
    }

    Rectangle {
        id: newRow
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 6 }
        height: 26
        color: "#ffffff"
        border.color: "#141418"
        border.width: input.activeFocus ? 2 : 1
        TextInput {
            id: input
            anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
            verticalAlignment: TextInput.AlignVCenter
            clip: true
            color: "#141418"
            font.family: menu.app.mono
            font.bold: true
            font.pixelSize: 12
            selectByMouse: true
            onAccepted: {
                const n = text.trim().toLowerCase()
                if (!n) return
                menu.app.addCategory(n)
                text = ""
                menu.picked(n)
            }
            Keys.onEscapePressed: menu.dismissed()
            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: !input.text && !input.activeFocus
                text: "+ new category"
                color: "#757980"
                font: input.font
            }
        }
    }
}
