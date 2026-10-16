// The Amiga AGA look as a layer effect: chunky pixels squashed into a small palette with ordered
// dithering (shaders/aga.frag). The palette is a texture with one texel per colour; Cabinet.qml
// builds it from a list of colours. Use as  layer.enabled: true; layer.effect: Dither { pal: ...; count: ... }
import QtQuick

ShaderEffect {
    property vector2d srcSize: Qt.vector2d(width, height)
    property real px: 2              // size of one chunky pixel
    property var pal                 // ShaderEffectSource of the palette strip
    property real count: 1           // colours in it (max 32)
    fragmentShader: Qt.resolvedUrl("shaders/aga.frag.qsb")
}
