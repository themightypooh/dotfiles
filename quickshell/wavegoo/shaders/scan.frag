#version 440
// Scanlines through text, like the Workbench font: every third pixel row is dimmed.
// Used as a layer effect on the start menu's text (see Scan in Launcher.qml).
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float h;          // item height in px, so the lines land on whole pixels
};
layout(binding = 1) uniform sampler2D source;

void main() {
    vec4 c = texture(source, qt_TexCoord0);
    float row = floor(qt_TexCoord0.y * h);
    float on = mod(row, 3.0) < 2.0 ? 1.0 : 0.6;   // 2 rows on, 1 dimmed
    fragColor = c * on * qt_Opacity;
}
