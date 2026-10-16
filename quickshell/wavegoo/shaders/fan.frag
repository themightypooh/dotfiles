#version 440
// The start menu is the bar's wave growing upward. This draws the *same* grain field as the
// bar (shaders/dots.frag): same grid, same hashes, same colours, same drift and wave, on the
// bar's clock. So where they overlap the grains line up exactly, and the menu reads as the
// bar's liquid rising up.
//
// The shape is the bar's surface smoothly merged with a quarter disc around the start orb.
// The disc's rim rolls and swells under the cursor; while opening, a sloshing surface (`level`)
// climbs up through it. Grains are packed like the bar near the bar and along the rim and
// surface, and thinner deeper in, over a dark body that only fades in once clear of the bar.
//
// Coordinates: p is screen px. Polar math uses d = (x - ox, oy - y), so +y is up.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;        // item size in px (a box in the bottom-left that the menu fits in)
    vec2 offset;      // where that box sits on screen
    vec2 screen;      // screen size in px (for sampling the wallpaper)
    vec2 origin;      // fan centre (the start orb) in px
    vec4 seams;       // x: hub edge, w: inner edge of the category band
    float rOut;       // resting rim radius
    float reveal;     // 0..1 open amount: the rising surface sloshes hardest mid-rise
    float time;       // the bar's wave clock (shared, so both fields agree)
    float cell;       // grain spacing, same as the bar's
    float dotSize;
    float flow;       // idle drift in px, same as the bar's
    float wave;       // how wavy the bar's top edge is, same as the bar's
    float rimWave;    // how wavy the menu's rim is
    float mouseA;     // smoothed pointer angle, for the rim swell
    float hover;      // 0..1 how much the pointer is on the menu
    float barTop;     // y of the bar's top in px
    float barWinTop;  // y where the bar's window starts: the bar's grain grid is anchored there
    float level;      // height of the rising surface above the orb, in px
    float growR;      // radius the disc has grown to so far (it swells out of the bar from the orb)
    float zoneTop;    // y where windows stop (the bar's exclusive zone); below it the real wallpaper shows
    float hasWall;    // 1 once the wallpaper texture is loaded
    vec4 gradA;
    vec4 gradB;
    vec4 grainM;
    vec4 grainC;
    vec4 grainY;
    vec4 backing;
};
layout(binding = 1) uniform sampler2D wall;   // the desktop wallpaper, laid out like Plasma's

const float QUARTER = 1.5707963;

// ---- shared with dots.frag (keep in step) -------------------------------------------------------
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
vec2 hash2(vec2 p) { return vec2(hash(p + 17.3), hash(p * 1.91 + 41.7)); }
float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
vec3 grainColor(vec2 id) {
    float h = hash(id + 11.1);
    return h < 0.34 ? grainM.rgb : h < 0.67 ? grainC.rgb : grainY.rgb;
}
vec2 drift(vec2 home) {
    float t = time * 0.5;
    vec2 q = home * 0.01 + vec2(t * 0.5, 0.0);
    vec2 cur = vec2(noise(q + vec2(0.0, t * 0.35)), noise(q + vec2(31.7, -t * 0.3))) - 0.5;
    return cur * 2.4 * flow;
}
// (these take bar-window coordinates: b = p - (0, barWinTop))
float barTopB() { return barTop - barWinTop; }
float barRest(float layer) { return barTopB() - 6.0 - layer * 10.0; }
float barLift(float x, float layer) {
    float t = time;
    float roll = sin(x / 130.0 + t * 0.6 + layer * 1.7) * 5.5 + sin(x / 61.0 - t * 0.9 + layer) * 2.4;
    return -wave * roll;          // the bar's swell needs its own pointer; it's idle while the menu is open
}
float barLiftWeight(float y) { return smoothstep(barRest(0.0) - 24.0, barRest(0.0), y); }

// ---- the menu's disc, in polar space around the orb ---------------------------------------------
vec2 toD(vec2 b) { return vec2(b.x - origin.x, origin.y - barWinTop - b.y); }   // bar coords -> polar d
float rimLift(float a) {
    float x = (QUARTER - a) * rOut;
    float t = time;
    float roll = sin(x / 130.0 + t * 0.6) * 5.5 + sin(x / 61.0 - t * 0.9) * 2.4;
    float swell = exp(-pow((a - mouseA) * rOut / 95.0, 2.0)) * 15.0 * hover;
    return rimWave * (roll + swell);
}
// 0 when shut or open, 1 mid-way: how bubbly the opening is right now
float bubbly() { return sin(3.14159 * clamp(reveal, 0.0, 1.0)); }
// The edge boils while it forms: round bubbles swell out of it, merge and sink back.
// `s` is a position along the edge in px; returns how far the edge bulges out there.
float boil(float s, float span, float seed) {
    float k = bubbly();
    if (k < 0.02) return 0.0;
    float bulge = 0.0;
    for (int i = 0; i < 8; i++) {
        float fi = float(i) + seed;
        float life = fract(time * (0.7 + 0.5 * hash(vec2(fi, 3.0))) + hash(vec2(fi, 7.0)));
        float gen = floor(time * (0.7 + 0.5 * hash(vec2(fi, 3.0))) + hash(vec2(fi, 7.0)));
        float at = span * hash(vec2(fi, gen + 1.0));                   // each bubble pops up somewhere new
        float rad = (16.0 + 30.0 * hash(vec2(fi, gen + 5.0))) * sin(3.14159 * life) * k;
        float dx = s - at;
        bulge = max(bulge, sqrt(max(rad * rad - dx * dx, 0.0)));          // a round bulge, half out of the edge
    }
    return bulge;
}
// the rising surface boils too (x is screen px)
float boilSurface(float x) { return boil(x - origin.x, growR, 20.0); }
// the rising surface: everything under it is filled; it sloshes while it climbs
float surface(float x) {
    if (reveal >= 0.999) return 1e4;                  // fully open: the surface is far above everything
    float t = time;
    float roll = sin(x / 130.0 + t * 0.6) * 5.5 + sin(x / 61.0 - t * 0.9) * 2.4;
    float slosh = sin(3.14159 * clamp(reveal, 0.0, 1.0));
    float chop = sin(x / 38.0 - t * 4.0) * 3.0 + sin(x / 97.0 + t * 2.6) * 6.0;
    // different stretches surge up at different speeds, shifting as it goes, so it never rises flat
    float surge = (noise(vec2(x / 105.0, time * 0.9)) - 0.5) * 180.0 + (noise(vec2(x / 41.0, time * 1.7 + 9.0)) - 0.5) * 50.0;
    return level + roll * (1.6 + 2.5 * slosh) + (chop + surge) * slosh + boilSurface(x);
}
// < 0 inside the disc (flat: no rim wave). While opening its radius is still growing.
// while opening, the rim grows lumpy and bubbling instead of as a clean circle
float growAt(float a) {
    float k = bubbly();
    if (k < 0.001) return growR;                      // settled: no lumps or bubbles to work out
    float lumps = (noise(vec2(a * 3.0, time * 1.4)) - 0.5) * 90.0 * k;
    return growR + lumps + boil((QUARTER - a) * growR, QUARTER * growR, 0.0);
}
float discFlat(vec2 b, float layer) {
    vec2 d = toD(b);
    float r = length(d);
    return max(max(r - growAt(atan(d.y, d.x)) + layer * 10.0, d.y - surface(b.x)), -d.x - 60.0);
}
// how far the bar's flat surface is above b (< 0 inside the bar)
float barFlat(vec2 b, float layer) { return barRest(layer) - b.y; }
float smin(float a, float b, float k) {
    if (k <= 0.001) return min(a, b);
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}
// one shape: bar + disc, merged with a soft fillet so the bar flows up into the menu.
// The fillet starts wide (a mound pulling up out of the bar) and tightens as it opens. Right at
// the start (and end of closing) it shrinks to nothing, so the bar settles back flat instead of
// keeping a lump that pops away when the menu finishes closing.
float fillet() {
    float v = clamp(reveal, 0.0, 1.0);
    return (46.0 + 90.0 * (1.0 - v)) * smoothstep(0.0, 0.25, v);
}
float shapeFlat(vec2 b, float layer) { return smin(barFlat(b, layer), discFlat(b, layer), fillet()); }

// 0..1: how close to the bar (1 = in it, 0 = well clear). Near the bar everything looks like the bar.
float nearBar(float y) { return 1.0 - smoothstep(0.0, 70.0, barRest(0.0) - y); }
// ~1 under the category names, fading out gently on both sides
float lane(float r) {
    float mid = (seams.w + 3.0 + rOut - 16.0) * 0.5;
    return 0.95 * (1.0 - smoothstep(8.0, 30.0, abs(r - mid)));
}
// grains near the rim ride its wave outward (but not near the bar, where they ride the bar's)
float rimWeight(vec2 b) {
    vec2 d = toD(b);
    return smoothstep(rOut - 34.0, rOut - 6.0, length(d)) * (1.0 - nearBar(b.y));
}
// 0..1: where the menu covers windows near the bar it shows the wallpaper behind its grains, so it
// looks just like the bar (which has the real wallpaper behind it). Only where the menu's shape
// reaches beyond the bar's own, above the line where windows stop, and in the lower part.
float wallMask(vec2 b) {
    float sd = shapeFlat(b, 0.0);
    float excess = barFlat(b, 0.0) - sd;                    // how far the menu pokes out past the bar
    float zone = 1.0 - smoothstep(zoneTop - barWinTop - 1.0, zoneTop - barWinTop + 1.0, b.y);
    return hasWall * smoothstep(2.0, -2.0, sd) * smoothstep(1.0, 10.0, excess) * zone * nearBar(b.y - 30.0);
}

// where a grain living at flat spot `home` actually sits
vec2 place(vec2 home, float layer, bool front) {
    vec2 d = toD(home);
    float r = max(length(d), 0.001);
    vec2 u = vec2(d.x, -d.y) / r;                      // radial direction, in screen axes
    float bw = front ? barLiftWeight(home.y) : 1.0;
    vec2 c = home + vec2(0.0, barLift(home.x, layer) * bw * nearBar(home.y));
    c += u * rimLift(atan(d.y, d.x)) * rimWeight(home);
    return c;
}

void main() {
    vec2 p = qt_TexCoord0 * size + offset;
    vec2 b = p - vec2(0.0, barWinTop);                  // the bar's grain grid lives in these coords
    // well outside the shape (grains ride and drift at most ~50px from home): nothing to draw here,
    // so skip the grain search entirely. Most of the box is this.
    if (shapeFlat(b, 0.0) > 55.0) { fragColor = vec4(0.0); return; }
    vec2 d = toD(b);
    float r = max(length(d), 0.001);
    float a = atan(d.y, d.x);
    vec2 u = vec2(d.x, -d.y) / r;

    // dark body: inside the disc, fading in only once clear of the bar
    float discReal = max(max(r - growAt(a) - rimLift(a), d.y - surface(b.x)), -d.x - 60.0);
    float inside = smoothstep(4.0, -22.0, discReal) * (1.0 - nearBar(b.y + 10.0));
    float wm = wallMask(b);
    vec4 col = wm > 0.0 ? vec4(texture(wall, p / screen).rgb, 1.0) * wm : vec4(0.0);
    col = backing * inside + col * (1.0 - backing.a * inside);

    // Only draw grains the bar doesn't already draw: the bar keeps a grain when its dice roll is
    // under the bar's own chance, so we skip exactly those and add only the menu's extra ones.
    // Nothing is drawn twice, so the bar doesn't brighten while the menu is open.

    // back wave: the bar's dim back layer, carried up the rim
    {
        vec2 q = b - vec2(0.0, barLift(b.x, 1.0) * nearBar(b.y)) - u * rimLift(a) * rimWeight(b) - drift(b + 50.0);
        vec2 c0 = floor(q / cell);
        float best = 0.0;
        vec3 bcol = vec3(1.0);
        for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
            vec2 id = c0 + vec2(float(i), float(j)) + 1000.0;
            vec2 home = (id - 1000.0 + 0.5 + (hash2(id) - 0.5) * 0.9) * cell;
            float sd = shapeFlat(home, 1.0);
            // inside: like the bar near the bar; up in the menu only a band along the edge
            float edge = -discFlat(home, 1.0);
            float menuP = 0.7 * exp(-max(edge - 14.0, 0.0) / 8.0) * (1.0 - lane(length(toD(home))));
            float prob = sd < 0.0 ? mix(menuP, 0.7, nearBar(home.y)) : (sd < 3.0 ? exp(-sd / 1.5) * 0.3 : 0.0);
            float bf = barFlat(home, 1.0);
            float barP = bf < 0.0 ? 0.7 : (bf < 3.0 ? exp(-bf / 1.5) * 0.3 : 0.0);
            float roll = hash(id * 2.11 + 9.7);
            // (under the drawn wallpaper the bar's own grains are hidden, so draw them all there)
            if (prob < 0.005 || roll >= prob || (roll < barP && wallMask(home) < 0.5)) continue;
            vec2 c = place(home, 1.0, false) + drift(home + 50.0);
            float sg = 0.45 + 0.25 * hash(id + 3.3);
            vec2 dv = b - c;
            float bm = exp(-dot(dv, dv) / (2.0 * sg * sg));
            if (bm > best) { best = bm; bcol = grainColor(id); }
        }
        vec3 bc = mix(bcol, vec3(1.0), 0.1);
        float al = best * 0.5;
        col = vec4(bc * al, al) + col * (1.0 - al);
    }

    // front wave: the bar's grains, carried up into the menu
    {
        vec2 q = b - vec2(0.0, barLift(b.x, 0.0) * barLiftWeight(b.y) * nearBar(b.y)) - u * rimLift(a) * rimWeight(b);
        q -= drift(q);
        vec2 c0 = floor(q / cell);
        float best = 0.0, glint = 0.0;
        vec3 gcol = vec3(1.0);
        for (int j = -2; j <= 2; j++) for (int i = -2; i <= 2; i++) {
            vec2 id = c0 + vec2(float(i), float(j));
            vec2 home = (id + 0.5 + (hash2(id) - 0.5) * 0.9) * cell;
            float sd = shapeFlat(home, 0.0);              // < 0 inside, > 0 above the edge
            if (sd > 4.0) continue;
            float hr = length(toD(home));
            float prob;
            if (sd < 0.0) {
                // up in the menu: a thick crest along the rim and the rising surface, thinner inside
                float edge = -discFlat(home, 0.0);
                float menuP = edge < 0.0 ? 0.92 : (0.22 + 0.7 * exp(-max(edge - 14.0, 0.0) / 14.0)) * (1.0 - lane(hr));
                prob = mix(menuP, 0.92, nearBar(home.y));     // near the bar: packed, exactly like the bar
            } else prob = exp(-sd / 1.5) * 0.45;          // thin fringe at the crest
            float bf = barFlat(home, 0.0);
            float barP = bf < 0.0 ? 0.92 : (bf < 4.0 ? exp(-bf / 1.5) * 0.45 : 0.0);
            float roll = hash(id * 1.37 + 3.1);
            if (prob < 0.005 || roll >= prob || (roll < barP && wallMask(home) < 0.5)) continue;
            float spray = 1.0 + 1.5 * clamp(sd / 8.0, 0.0, 1.0);
            vec2 c = place(home, 0.0, true) + drift(home) * spray;
            float sz = hash(id + 5.1);
            float sg = (0.5 + 0.35 * sz) * (1.0 - 0.3 * clamp(sd / 12.0, 0.0, 1.0));
            float fade = (sd > 0.0 ? exp(-sd / 14.0) : 1.0) * (0.5 + 0.5 * hash(id + 8.8));
            vec2 dv = b - c;
            float m = exp(-dot(dv, dv) / (2.0 * sg * sg)) * fade;
            if (m > best) { best = m; glint = hash(id + 2.2); gcol = grainColor(id); }
        }
        vec3 pc = mix(gcol, vec3(1.0), 0.04 + glint * 0.22);
        float al = best;
        col = vec4(pc * al, al) + col * (1.0 - al);
    }

    fragColor = col * qt_Opacity;
}
