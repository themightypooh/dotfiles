// The AGA palette as a texture strip (one texel per colour) for Dither.qml. A texture only works in
// the window it was made in, so every window that dithers keeps one of these.
import QtQuick

Item {
    id: root
    required property var colors
    readonly property alias tex: src
    readonly property int count: colors.length
    width: 1; height: 1

    Row {
        id: strip
        Repeater { model: root.colors; Rectangle { required property string modelData; width: 1; height: 1; color: modelData } }
    }
    ShaderEffectSource {
        id: src
        sourceItem: strip
        hideSource: true
        smooth: false
        textureSize: Qt.size(root.colors.length, 1)
        width: 1; height: 1
        visible: false
    }
}
