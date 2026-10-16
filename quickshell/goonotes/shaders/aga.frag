#version 440
// Amiga AGA look: chunky pixels, squashed into a small palette (up to 32 colours, read from the
// `pal` texture: one texel per colour) with 4x4 ordered (Bayer) dithering. Each pixel finds its two
// nearest palette colours and dithers between them by how far along it sits; alpha is dithered too,
// so soft shadows and highlights come out as sparse pixel patterns.
// Float maths only (no int bit ops) so it also compiles for GLSL 100 es / 120.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 srcSize;    // item size in px
    float px;        // size of one chunky pixel
    float count;     // colours in pal
};
layout(binding = 1) uniform sampler2D source;
layout(binding = 2) uniform sampler2D pal;

float bayer2(vec2 a) { a = floor(a); return fract(a.x / 2.0 + a.y * a.y * 0.75); }
float bayer4(vec2 a) { return bayer2(0.5 * a) * 0.25 + bayer2(a); }

void main() {
    vec2 cell = floor(qt_TexCoord0 * srcSize / px);
    vec4 s = texture(source, (cell + 0.5) * px / srcSize);
    float t = bayer4(cell) + 1.0 / 32.0;
    if (s.a < t) { fragColor = vec4(0.0); return; }
    vec3 col = s.rgb / max(s.a, 1e-4);
    vec3 a = vec3(0.0), b = vec3(0.0);
    float da = 1e9, db = 1e9;
    for (int i = 0; i < 32; i++) {
        if (float(i) >= count) break;
        vec3 p = texture(pal, vec2((float(i) + 0.5) / count, 0.5)).rgb;
        vec3 d = col - p;
        float dd = dot(d, d);
        if (dd < da) { b = a; db = da; a = p; da = dd; }
        else if (dd < db) { b = p; db = dd; }
    }
    vec3 ab = b - a;
    float f = clamp(dot(col - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
    fragColor = vec4(f > t ? b : a, 1.0) * qt_Opacity;
}
