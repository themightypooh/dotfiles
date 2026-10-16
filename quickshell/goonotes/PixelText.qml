// Crisp, unsmoothed bold monospace, standing in for the Amiga's Topaz font (used by Cabinet.qml).
import QtQuick

Text {
    font.family: "monospace"
    textFormat: Text.PlainText
    font.bold: true
    font.hintingPreference: Font.PreferFullHinting
    renderType: Text.NativeRendering
    antialiasing: false
}
