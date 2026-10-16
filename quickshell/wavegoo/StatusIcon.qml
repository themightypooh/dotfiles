// One status icon on the right side of the bar (volume, network, bluetooth, notifications).
// Floats on the wave like everything else; emits clicked(button) and wheel(up).
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Widgets

Item {
    id: si
    required property var bar          // the Bar window (for ride / sway / rock / magnify)
    required property Item row         // the Row this sits in, for its screen position
    property string icon: ""
    property string badge: ""          // small text in the corner, e.g. a notification count
    property bool dim: false
    property real level: -1            // 0..1 draws a thin bar under the icon (volume); -1 hides it
    property color tint: "transparent" // recolors the icon when set (e.g. the sticky-notes button)
    signal clicked(int button)
    signal wheel(bool up)

    width: 22; height: 22
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    readonly property real gx: row.x + x + width / 2
    readonly property bool hot: mouse.containsMouse

    transform: Translate {
        x: si.bar.sway(si.gx)
        y: si.bar.ride(si.gx) + si.bar.bob(si.gx)
        // springs only while the pointer's on the bar (see Bar.springy): chasing the idle wave they
        // never settle, and that kept the whole bar redrawing at the screen's full rate
        Behavior on y { enabled: si.bar.springy; SpringAnimation { spring: 3; damping: 0.22 } }
    }
    rotation: si.bar.rock(si.gx)
    Behavior on rotation { enabled: si.bar.springy; SpringAnimation { spring: 2.5; damping: 0.2 } }
    scale: si.bar.magnify(si.gx) * (hot ? 1.1 : 1)

    IconImage {
        anchors.centerIn: parent
        implicitSize: 18
        opacity: si.dim ? 0.45 : 1
        source: si.icon ? Quickshell.iconPath(si.icon, "dialog-question") : ""
        layer.enabled: si.tint.a > 0
        layer.effect: MultiEffect { brightness: 1.0; colorization: 1.0; colorizationColor: si.tint }
    }
    Rectangle {
        visible: si.level >= 0
        x: 2; y: parent.height + 1; width: parent.width - 4; height: 2; radius: 1
        color: "#33ffffff"
        Rectangle { width: parent.width * Math.max(0, Math.min(1, si.level)); height: 2; radius: 1; color: "white"; opacity: 0.8 }
    }
    Rectangle {
        visible: si.badge !== ""
        x: parent.width - 8; y: -4
        height: 13; width: Math.max(13, badgeText.implicitWidth + 6); radius: 6.5
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: si.bar.root.gooA }
            GradientStop { position: 1; color: si.bar.root.gooB }
        }
        Text {
            id: badgeText
            anchors.centerIn: parent
            text: si.badge; color: "white"; font.pixelSize: 9; font.weight: Font.Bold
        }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent; anchors.margins: -5
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onClicked: m => si.clicked(m.button)
        onWheel: w => si.wheel(w.angleDelta.y > 0)
    }
}
