#version 440
// The hourglass. Everything is drawn here, nothing is simulated per grain:
//  - the frame (end plates + posts) and the glass outline are square dots, in the bar's liquid gradient
//  - the sand is the bar's grains (gaussian splats, magenta / cyan / yellow) on a jittered grid;
//    which grains exist is decided by the sand's shape, which shell.qml solves from the time left
//    (top level + crater, bottom level + heap) so the volume is conserved
//  - the falling stream is a line of grains in "age" space: grain j was let through the neck at
//    time j * spacing and has fallen 0.5 g age^2 since, so it only needs the clock
// Nothing animates unless shell.qml changes a uniform, so a paused or finished glass costs nothing.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;        // item size in px
    float neckY;      // centre of the neck
    float neckLen;    // half length of the straight neck
    float neckW;      // neck half width (inside)
    float bulbH;      // height of one bulb, neck to end plate
    float bulbR;      // widest half width of a bulb (inside)
    float cell;       // grain pitch
    float pitch;      // frame dot pitch
    float time;       // stream clock, seconds (only advances while running)
    float topY;       // top sand level at the walls (>= neck top = empty)
    float dip;        // crater depth below topY
    float crater;     // crater radius
    float topShift;   // how far the top sand has sunk since it was full (grains ride down with it)
    float botY;       // bottom sand base level (>= bottom of glass = empty)
    float heap;       // height of the heap's peak above botY
    float heapR;      // heap radius
    float stream;     // 0..1 sand falling through the neck
    float flowFrom;   // clock time the neck opened (grains let through before this don't exist)
    float flowTo;     // clock time the top ran out (huge while it's still flowing)
    float flash;      // 0..1 time's-up flash
    float dim;        // 0..1 paused
    float hover;      // 0..1 pointer on the widget
    vec4 gradA;       // liquid colour, top of the frame
    vec4 gradB;       // liquid colour, bottom of the frame
    vec4 grainM;      // sand colours
    vec4 grainC;
    vec4 grainY;
    vec4 rim;         // glass outline dots
};

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float hash1(float n) { return fract(sin(n * 91.345 + 7.13) * 43758.5453); }
vec2 hash2(vec2 p) { return vec2(hash(p + 17.3), hash(p * 1.91 + 41.7)); }

vec3 grainColor(float h) { return h < 0.34 ? grainM.rgb : h < 0.67 ? grainC.rgb : grainY.rgb; }

// inside half width of the glass at height y (same profile as halfWidth() in shell.qml)
float profile(float u) {
    u = clamp(u, 0.0, 1.0);
    const float a = 0.62;
    float s = u < a ? 1.0 - (1.0 - u / a) * (1.0 - u / a)
                    : sqrt(max(0.0, 1.0 - pow((u - a) / 0.63, 2.0)));
    return neckW + (bulbR - neckW) * s;
}
float halfWidth(float y) { return profile((abs(y - neckY) - neckLen) / bulbH); }
float glassTop() { return neckY - neckLen - bulbH; }
float glassBot() { return neckY + neckLen + bulbH; }

// signed distance to the glass wall (< 0 inside), corrected for the wall's slope
float glassSdf(vec2 p) {
    float dx = abs(p.x - size.x * 0.5);
    float hw = halfWidth(p.y);
    float sl = (halfWidth(p.y + 1.0) - halfWidth(p.y - 1.0)) * 0.5;
    float d = (dx - hw) / sqrt(1.0 + sl * sl);
    return max(d, abs(p.y - neckY) - (neckLen + bulbH));
}

float sdBox(vec2 p, vec2 c, vec2 h, float r) {
    vec2 q = abs(p - c) - h + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// the frame: two end plates and two posts
float frameSdf(vec2 p) {
    float cx = size.x * 0.5;
    float pw = bulbR + 18.0;
    float plate = 7.0;
    float t = sdBox(p, vec2(cx, glassTop() - plate), vec2(pw, plate), 4.0);
    float b = sdBox(p, vec2(cx, glassBot() + plate), vec2(pw, plate), 4.0);
    float postX = bulbR + 9.0;
    float posts = sdBox(vec2(abs(p.x - cx), p.y), vec2(postX, neckY), vec2(2.0, bulbH + neckLen), 2.0);
    return min(min(t, b), posts);
}

// sand surfaces
float topSurface(float dx) {
    float c = max(0.0, 1.0 - abs(dx) / max(crater, 1.0));
    return topY + dip * pow(c, 1.25);
}
float botSurface(float dx) {
    float d = sqrt(dx * dx + 9.0);   // soft tip
    return botY - heap * max(0.0, 1.0 - d / max(heapR, 1.0));
}
// how far the point h is inside the sand (> 0 inside), top or bottom bulb
float sandDepth(vec2 h) {
    float dx = h.x - size.x * 0.5;
    float wall = halfWidth(h.y) - abs(dx) - 0.6;
    if (wall < 0.0 || abs(h.y - neckY) > neckLen + bulbH - 1.0) return -1e3;
    if (h.y < neckY) {
        if (topY >= neckY - neckLen - 0.5) return -1e3;
        if (h.y > neckY - neckLen) return stream > 0.5 ? 1.0 : -1e3;   // the neck is full while it flows
        return h.y - topSurface(dx);
    }
    if (h.y < neckY + neckLen) return -1e3;
    return h.y - botSurface(dx);
}

// a grain splat; keeps steady brightness while it slides between pixels (no twinkle)
float splat(vec2 d, float sg) { return exp(-dot(d, d) / (2.0 * sg * sg)); }

void main() {
    vec2 p = qt_TexCoord0 * size;
    float cx = size.x * 0.5;
    float gy = clamp((p.y - glassTop() + 14.0) / (glassBot() - glassTop() + 28.0), 0.0, 1.0);
    vec3 liquid = mix(gradA.rgb, gradB.rgb, gy);
    vec4 col = vec4(0.0);

    // ---- frame + glass outline as square dots ---------------------------------------------
    {
        vec2 c = (floor(p / pitch) + 0.5) * pitch;
        vec2 o = abs(p - c);
        float dot = (1.0 - smoothstep(0.55, 1.05, max(o.x, o.y)));
        float fr = frameSdf(c);
        float g = abs(glassSdf(c));
        // frame: solid dots in the gradient, with a lit edge
        float fa = fr < 0.0 ? 0.9 : 0.0;
        vec3 fc = mix(liquid, vec3(1.0), fr > -pitch * 1.2 && fr < 0.0 ? 0.25 : 0.0);
        // glass: a thin row of dots, brighter with hover and on the flash
        float ga = g < pitch * 0.5 ? rim.a * (1.0 + 0.6 * hover) + flash * 0.6 : 0.0;
        vec3 gc = mix(rim.rgb, liquid, 0.35);
        // a glint down the left of each bulb
        float dx = p.x - cx;
        float hw = halfWidth(c.y);
        float side = -dx / max(hw, 1.0);
        float glint = (side > 0.6 && side < 0.68 && abs(c.y - neckY) > neckLen + bulbH * 0.25 && abs(c.y - neckY) < neckLen + bulbH * 0.8) ? 0.10 : 0.0;
        float a = max(fa, max(ga, glint)) * dot;
        vec3 cc = fa > 0.0 ? fc : (ga > 0.0 ? gc : vec3(1.0));
        col = vec4(cc * a, a);
    }

    // ---- sand at rest (top bulb sinks as it drains, bottom bulb is settled) ---------------
    {
        bool top = p.y < neckY;
        float shift = top ? topShift : 0.0;
        vec2 q = p - vec2(0.0, shift);
        vec2 c0 = floor(q / cell);
        float best = 0.0, glint = 0.0;
        vec3 gcol = vec3(1.0);
        for (int j = -2; j <= 2; j++) for (int i = -2; i <= 2; i++) {
            vec2 id = c0 + vec2(float(i), float(j)) + 500.0;
            vec2 home = (id - 500.0 + 0.5 + (hash2(id) - 0.5) * 0.9) * cell + vec2(0.0, shift);
            if ((home.y < neckY) != top) continue;
            float d = sandDepth(home);
            float prob = d > 0.0 ? 0.93 : (d > -4.0 ? exp(d / 1.4) * 0.45 : 0.0);   // ragged surface
            if (hash(id * 1.37 + 3.1) >= prob) continue;
            float sg = 0.55 + 0.35 * hash(id + 5.1);
            float fade = (d > 0.0 ? 1.0 : exp(d / 3.0)) * (0.55 + 0.45 * hash(id + 8.8));
            float m = splat(p - home, sg) * fade;
            if (m > best) { best = m; glint = hash(id + 2.2); gcol = grainColor(hash(id + 11.1)); }
        }
        vec3 pc = mix(gcol, vec3(1.0), 0.04 + glint * 0.22 + flash * 0.7);
        float a = best * (1.0 - 0.3 * dim);
        col = vec4(pc * a, a) + col * (1.0 - a);
    }

    // ---- the stream ----------------------------------------------------------------------
    if (stream > 0.01) {
        const float k = 1300.0;          // 0.5 * g, px/s^2
        const float sp = 1.0 / 70.0;     // a grain every 14 ms per lane
        float y0 = neckY - neckLen;
        float land = botSurface(0.0);
        if (abs(p.x - cx) < 8.0 && p.y > y0 - 2.0 && p.y < land + 3.0) {
            float age = sqrt(max(0.0, p.y - y0) / k);
            float best = 0.0;
            vec3 gcol = vec3(1.0);
            for (int lane = 0; lane < 2; lane++) {
                float off = float(lane) * 0.5;
                float jc = floor((time - age) / sp - off);
                for (int n = -3; n <= 3; n++) {
                    float j = jc + float(n);
                    float a = time - (j + off) * sp;
                    if (a < 0.0) continue;
                    float born = time - a;
                    if (born < flowFrom || born > flowTo) continue;
                    float y = y0 + k * a * a;
                    if (y > land + 1.0) continue;
                    float jid = j * 2.0 + float(lane);
                    float x = cx + (hash1(jid) - 0.5) * (1.6 + a * 9.0);
                    float m = splat(p - vec2(x, y), 0.55 + 0.3 * hash1(jid + 3.0));
                    if (m > best) { best = m; gcol = grainColor(hash1(jid + 9.0)); }
                }
            }
            vec3 pc = mix(gcol, vec3(1.0), 0.15 + flash * 0.7);
            float a = best * stream * (1.0 - 0.3 * dim);
            col = vec4(pc * a, a) + col * (1.0 - a);
        }
    }

    fragColor = col * qt_Opacity;
}
