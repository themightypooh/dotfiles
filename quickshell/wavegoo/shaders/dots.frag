#version 440
// The liquid wave bar. The body is a smooth gradient (two layers, like a wave with depth);
// particles live at its surface: thick along the crest, thinning out with depth, and
// spraying loose above it. Each particle's physics offset comes from the `disp` texture
// (simulated in DotSurface.qml) plus a shared slow current, so they move together.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;       // item size in px
    vec2 grid;       // dots across, dots down
    vec4 box;        // left, top, right, bottom of the drawer/card in px
    vec4 dotColor;   // resting dot
    vec4 litColor;   // fast-moving dot
    vec4 backing;    // faint fill behind the dots
    float barTop;    // y where the bar starts (huge = no bar)
    float corner;    // box corner radius
    float fillet;    // how softly the box merges into the bar
    float cell;      // grain grid pitch in px (render)
    float dotSize;   // dot edge in px
    float time;      // seconds, drives the idle flow
    float flow;      // idle drift amount in px
    float loose;     // width in px of the ragged, thinning edge (0 = hard edge)
    float mouseX;    // smoothed pointer x, for the swell
    float hover;     // 0..1 how much the pointer is on the surface
    float wave;      // 0..1 how wavy the top edge is (0 = flat)
    vec4 gradA;      // liquid colour on the left
    vec4 gradB;      // liquid colour on the right
    vec4 grainM;     // sand colours
    vec4 grainC;
    vec4 grainY;
    float simCell;   // physics grid pitch in px (coarser than the grains)
    float mouseY;    // smoothed pointer y
    vec4 blob0;      // goo blobs: x, birth time (< 0 = none), size, seed
    vec4 blob1;
    vec4 blob2;
    vec4 blob3;
    float gooLive;   // 1 while any blob is alive
    float gooLife;   // seconds a blob lives
};
layout(binding = 1) uniform sampler2D disp;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
// one slow shared current, so neighbouring particles move together instead of jittering
vec2 drift(vec2 home) {
    float t = time * 0.5;
    vec2 q = home * 0.01 + vec2(t * 0.5, 0.0);
    vec2 cur = vec2(noise(q + vec2(0.0, t * 0.35)), noise(q + vec2(31.7, -t * 0.3))) - 0.5;
    return cur * 2.4 * flow;
}

float sdBox(vec2 p, vec4 b, float r) {
    vec2 c = vec2(b.x + b.z, b.y + b.w) * 0.5;
    vec2 h = vec2(b.z - b.x, b.w - b.y) * 0.5;
    vec2 q = abs(p - c) - h + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

float smin(float a, float b, float k) {
    if (k <= 0.0) return min(a, b);
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// height of the bar's top edge at x: a slow roll and a swell under the cursor
float waveTop(float x, float layer) {
    float t = time;
    float roll = sin(x / 130.0 + t * 0.6 + layer * 1.7) * 5.5 + sin(x / 61.0 - t * 0.9 + layer) * 2.4;
    return barTop - 6.0 - wave * roll - layer * 10.0;
}

float shapeLayer(vec2 p, float layer) {
    float bar = waveTop(p.x, layer) - p.y;
    float bx = (box.z - box.x > 1.0 && box.w - box.y > 1.0) ? sdBox(p, box, corner) : 1e5;
    return smin(bar, bx, fillet);
}

float shape(vec2 p) {
    float bar = waveTop(p.x, 0.0) - p.y;
    float bx = (box.z - box.x > 1.0 && box.w - box.y > 1.0) ? sdBox(p, box, corner) : 1e5;
    return smin(bar, bx, fillet);
}

// each grain is one of three sand colours, picked by its own dice roll
vec3 grainColor(vec2 id) {
    float h = hash(id + 11.1);
    return h < 0.34 ? grainM.rgb : h < 0.67 ? grainC.rgb : grainY.rgb;
}
vec2 hash2(vec2 p) { return vec2(hash(p + 17.3), hash(p * 1.91 + 41.7)); }

vec3 grad(float x) { return mix(gradA.rgb, gradB.rgb, clamp(x / size.x, 0.0, 1.0)); }

// The particles live on a flat grid and the whole field rides the wave: each one is
// lifted by the wave's height at its x. Which particles exist never changes, so
// nothing pops in or out as the wave moves.
float rest(float layer) { return barTop - 6.0 - layer * 10.0; }
float lift(float x, float layer) { return waveTop(x, layer) - rest(layer); }
// particles high up in the drawer don't bob with the wave
float liftWeight(float y) { return smoothstep(rest(0.0) - 24.0, rest(0.0), y); }

// Goo: blobs born where the pointer was (positions come from DotSurface.qml), each swelling up out
// of the surface at its own spot, pinching off and floating away while it shrinks. Signed distance
// in screen space (< 0 inside).
float blobSdf(vec2 p, vec4 b) {
    if (b.y < 0.0) return 1e5;
    float life = (time - b.y) / gooLife;
    if (life <= 0.0 || life >= 1.0) return 1e5;
    float big = (10.0 + 7.0 * hash(vec2(b.w, 5.0))) * b.z;          // 20-34px across
    float r = big * smoothstep(0.0, 0.08, life) * (1.0 - smoothstep(0.5, 1.0, life));   // forms in ~0.35 s
    if (r < 0.5) return 1e5;
    float climb = smoothstep(0.05, 1.0, life);
    // born exactly at the pointer and goes straight up from that spot: no sideways motion at all
    float base = b.x;
    // any that end up away from the pointer (or once you leave the bar) melt away quickly
    r *= (1.0 - smoothstep(35.0, 80.0, abs(base - mouseX))) * hover;
    if (r < 0.5) return 1e5;
    // Born right at the pointer's tip, it rises straight up out of it through the liquid, breaks the
    // surface and floats off (inside the bar window's 84px of headroom).
    float x = base;
    float surf = waveTop(x, 0.0) + 8.0;
    float from = max(mouseY, surf);                                     // the pointer's tip, or the surface if it's above
    vec2 c = vec2(x, mix(from, surf - 52.0, climb));
    vec2 st = vec2(1.0, 1.0 + 0.35 * sin(3.14159 * climb));            // stretched tall as it travels up
    return (length((p - c) / (st * r)) - 1.0) * r;
}
float goo(vec2 p) {
    if (gooLive < 0.5) return 1e5;
    float d = blobSdf(p, blob0);
    d = smin(d, blobSdf(p, blob1), 10.0);                            // gooey necks where they meet
    d = smin(d, blobSdf(p, blob2), 10.0);
    d = smin(d, blobSdf(p, blob3), 10.0);
    return d;
}

// grains near the pointer's tip lean gently away from it: a soft hollow that follows the pointer
vec2 repel(vec2 c) {
    if (hover < 0.01) return vec2(0.0);
    vec2 v = c - vec2(mouseX, mouseY);
    float l = length(v) + 0.001;
    return v / l * 11.0 * exp(-l * l / (2.0 * 26.0 * 26.0)) * hover;
}

// shape in the flat (un-lifted) space: the flat bar merged with the drawer box (and the goo)
float flatShape(vec2 h, float layer) {
    float bar = rest(layer) - h.y;
    if (layer > 0.0) return bar;
    // the goo lives on screen; check it where this grain actually ends up, and melt it into the bar
    if (gooLive > 0.5) bar = smin(bar, goo(h + vec2(0.0, lift(h.x, 0.0) * liftWeight(h.y))), 8.0);
    float bx = (box.z - box.x > 1.0 && box.w - box.y > 1.0) ? sdBox(h, box, corner) : 1e5;
    return smin(bar, bx, fillet);
}

// physics offset + speed at any point, smoothly interpolated from the coarse sim grid
vec3 phys(vec2 q) {
    vec4 t = texture(disp, q / (grid * simCell));
    return t.a > 0.5 ? vec3((t.rg * 255.0 - 128.0) / 8.0, t.b) : vec3(0.0);
}

void main() {
    vec2 p = qt_TexCoord0 * size;

    // Most of the window is headroom that no grain can reach unless goo is rising. The highest front
    // grain sits a fringe (4) above the bar or drawer, plus the wave's lift (8 * wave), the physics
    // shove (11.4), drift with spray (5.4), the pointer's push (11) and its splat (3.4): 35 + 8 * wave.
    // (Back-layer grains stop ~20 above.) Bail out above that instead of searching 34 cells for nothing.
    if (gooLive < 0.5 && p.y < min(barTop - 6.0, box.y) - 8.0 * wave - 40.0) { fragColor = vec4(0.0); return; }
    vec3 g = grad(p.x);

    // faint liquid behind the grains, so the bar holds together and text stays readable
    float front = smoothstep(0.8, -0.8, shape(p));
    front = max(front, step(barTop, p.y));
    float behind = smoothstep(0.8, -0.8, shapeLayer(p, 1.0));
    vec4 col = vec4(0.0);   // no fill: the wave is grains only

    // back wave: dimmer grains, no physics
    {
        vec2 q = p - vec2(0.0, lift(p.x, 1.0)) - drift(p + 50.0);
        vec2 c0 = floor(q / cell);
        float best = 0.0;
        vec3 bcol = vec3(1.0);
        for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
            vec2 id = c0 + vec2(float(i), float(j)) + 1000.0;
            vec2 home = (id - 1000.0 + 0.5 + (hash2(id) - 0.5) * 0.9) * cell;
            float d = flatShape(home, 1.0);
            float prob = d < 0.0 ? 0.7 : (d < 3.0 ? exp(-d / 1.5) * 0.3 : 0.0);
            if (hash(id * 2.11 + 9.7) >= prob) continue;
            vec2 c = home + vec2(0.0, lift(home.x, 1.0)) + drift(home + 50.0);
            // soft gaussian splat: keeps steady brightness as it slides between pixels (no twinkle)
            float sg = 0.45 + 0.25 * hash(id + 3.3);
            vec2 dv = p - c;
            float bm = exp(-dot(dv, dv) / (2.0 * sg * sg));
            if (bm > best) { best = bm; bcol = grainColor(id); }
        }
        vec3 bc = mix(bcol, vec3(1.0), 0.1);
        float a = best * 0.5;
        col = vec4(bc * a, a) + col * (1.0 - a);
    }

    // front wave: fine grains, riding the wave and the physics field
    {
        float w = liftWeight(p.y);
        vec2 q = p - vec2(0.0, lift(p.x, 0.0) * w);
        // undo the (smooth) displacement, then search nearby grains (inside the goo there's no shove to undo)
        float outGoo = gooLive > 0.5 ? smoothstep(-4.0, 2.0, goo(p)) : 1.0;
        q -= (phys(q).xy + repel(p)) * outGoo + drift(q);
        vec2 c0 = floor(q / cell);
        float best = 0.0, speed = 0.0, glint = 0.0;
        vec3 gcol = vec3(1.0);
        // grains can sit a couple of cells from where the inverse mapping lands, so look 5x5
        for (int j = -2; j <= 2; j++) for (int i = -2; i <= 2; i++) {
            vec2 id = c0 + vec2(float(i), float(j));
            if (id.x < 0.0 || id.y < 0.0) continue;
            vec2 home = (id + 0.5 + (hash2(id) - 0.5) * 0.9) * cell;
            float d = flatShape(home, 0.0);   // < 0 inside, > 0 above
            float prob = d < 0.0 ? 0.92 : (d < 4.0 ? exp(-d / 1.5) * 0.45 : 0.0);   // thin fringe at the crest only
            if (hash(id * 1.37 + 3.1) >= prob) continue;
            vec3 ph = phys(home);
            // goo holds together: the pointer's shove doesn't scatter it
            // goo holds together: neither the pointer's shove nor its push scatters it
            float inGoo = gooLive > 0.5 ? smoothstep(2.0, -4.0, goo(home + vec2(0.0, lift(home.x, 0.0) * liftWeight(home.y)))) : 0.0;
            ph.xy *= 1.0 - inGoo;
            float spray = 1.0 + 1.5 * clamp(d / 8.0, 0.0, 1.0);
            vec2 c = home + vec2(0.0, lift(home.x, 0.0) * liftWeight(home.y)) + ph.xy + drift(home) * spray;
            c += repel(c) * (1.0 - inGoo);
            float sz = hash(id + 5.1);
            // soft gaussian splat: steady brightness while it moves between pixels (no twinkle)
            float sg = (0.5 + 0.35 * sz) * (1.0 - 0.3 * clamp(d / 12.0, 0.0, 1.0));
            float fade = (d > 0.0 ? exp(-d / 14.0) : 1.0) * (0.5 + 0.5 * hash(id + 8.8));
            vec2 dv = p - c;
            float m = exp(-dot(dv, dv) / (2.0 * sg * sg)) * fade;
            // goo grains glow a little, so a blob reads as it moves up through the liquid (lava lamp)
            if (m > best) { best = m; speed = ph.z + inGoo * 0.6; glint = hash(id + 2.2); gcol = grainColor(id); }
        }
        vec3 pc = mix(gcol, vec3(1.0), 0.04 + glint * 0.22 + clamp(speed, 0.0, 1.0) * 0.4);
        float a = best;
        col = vec4(pc * a, a) + col * (1.0 - a);
    }

    fragColor = col * qt_Opacity;
}
