// Small round icon button for a note's header (Nerd Font glyphs).
import QtQuick

Item {
    id: btn
    required property var app
    property string glyph: ""
    property color tip: app.ink      // color when hovered / lit
    property color ink: app.ink      // glyph color at rest
    property bool pixel: false       // square, outlined hover (the pixel-art notes)
    property bool lit: false
    property string hint: ""         // a small label shown under the button while hovered
    signal clicked()

    width: 24; height: 24

    Rectangle {
        anchors.centerIn: parent
        width: 22; height: 22; radius: btn.pixel ? 0 : 11
        color: area.containsMouse ? Qt.alpha(btn.tip, btn.pixel ? 0.45 : 0.18) : "transparent"
        border.color: btn.pixel && area.containsMouse ? "#141418" : "transparent"
        border.width: btn.pixel ? 2 : 0
        Behavior on color { ColorAnimation { duration: 120 } }
    }
    Text {
        anchors.centerIn: parent
        text: btn.glyph
        font.family: btn.app.mono
        font.pixelSize: 12
        color: btn.lit || (area.containsMouse && !btn.pixel) ? btn.tip : btn.ink
        scale: area.pressed ? 0.85 : 1
        Behavior on scale { NumberAnimation { duration: 90 } }
        Behavior on color { ColorAnimation { duration: 120 } }
    }
    Rectangle {
        visible: btn.hint !== "" && area.containsMouse
        anchors { top: parent.bottom; topMargin: 4; horizontalCenter: parent.horizontalCenter }
        width: hintText.implicitWidth + 10; height: hintText.implicitHeight + 6
        color: "#141418"; z: 10
        Text { id: hintText; anchors.centerIn: parent; text: btn.hint; color: "#ffffff"; font.family: btn.app.mono; font.pixelSize: 10 }
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.clicked()
    }
}
