// Shading for everything inside the device's room.
// Unshaded on purpose: lighting is computed here from one hanging lamp so the
// result is the same on every GPU, then crushed to a 6-step amber ramp with
// 4x4 ordered dithering. FRAGCOORD is in the low-res SubViewport's pixels, so
// the dither pattern is chunky screen pixels, not texels.
shader_type spatial;
render_mode unshaded, cull_back;

uniform float tone = 0.5;      // base brightness of the material
uniform int pattern = 0;       // 0 plain, 1 floor planks, 2 wallpaper, 3 rug, 4 ceiling boards
uniform float glow = 0.0;      // self-light (bulb, window panes)
uniform vec3 lamp_pos = vec3(0.0, 0.7, -1.7);
uniform vec3 rug_half = vec3(0.8, 0.01, 0.65);

varying vec3 wpos;
varying vec3 wnrm;
varying vec3 lpos;

const vec3 PAL[6] = vec3[6](
	vec3(0.055, 0.024, 0.0),
	vec3(0.20, 0.085, 0.0),
	vec3(0.42, 0.19, 0.01),
	vec3(0.68, 0.34, 0.03),
	vec3(0.93, 0.56, 0.12),
	vec3(1.0, 0.84, 0.45)
);

const float BAYER[16] = float[16](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0,
		3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize(mat3(MODEL_MATRIX) * NORMAL);
	lpos = VERTEX;
}

void fragment() {
	vec3 n = normalize(wnrm);
	float t = tone;

	if (pattern == 1) {
		// planks run front-to-back so they read as perspective lines
		float px = wpos.x / 0.27;
		float row = floor(px);
		float seam = step(fract(px), 0.07);
		float joint = step(fract((wpos.z + row * 0.53) / 1.15), 0.025);
		t *= 1.0 - 0.45 * max(seam, joint);
		t *= 0.92 + 0.08 * fract(sin(row * 12.9898) * 43758.5);
	} else if (pattern == 2) {
		vec3 tang = normalize(cross(n, vec3(0.0, 1.0, 0.0)) + vec3(1e-4));
		float u = dot(wpos, tang);
		if (wpos.y < -0.85) {
			// wainscot: vertical boards plus a cap rail
			t *= 0.78 * (1.0 - 0.4 * step(fract(u / 0.22), 0.1));
			t *= 1.0 - 0.5 * step(-0.92, wpos.y);
		} else {
			t *= 1.0 - 0.1 * step(0.5, fract(u / 0.42));
		}
	} else if (pattern == 3) {
		vec2 q = abs(lpos.xz) / rug_half.xz;
		float r = max(q.x, q.y);
		t *= r > 0.86 ? 0.55 : (r > 0.74 ? 1.15 : (r > 0.5 && r < 0.6 ? 0.7 : 1.0));
	} else if (pattern == 4) {
		t *= 1.0 - 0.35 * step(fract(wpos.x / 0.3), 0.08);
	}

	vec3 L = lamp_pos - wpos;
	float d = length(L);
	L /= d;
	float lam = max(dot(n, L), 0.0);
	float att = 1.0 / (1.0 + 0.32 * d * d);
	float face = 0.9 + 0.12 * n.y - 0.12 * abs(n.x);
	float fill = max(dot(n, normalize(vec3(0.3, 0.2, 1.0))), 0.0) * 0.12;
	float lit = t * (0.28 + 1.6 * lam * att + fill) * face;
	lit *= mix(1.0, 0.7, clamp(-wpos.z / 3.4, 0.0, 1.0));
	lit += glow;

	vec2 p = mod(floor(FRAGCOORD.xy), 4.0);
	float thr = (BAYER[int(p.x) + int(p.y) * 4] + 0.5) / 16.0;
	float v = clamp(lit, 0.0, 1.0) * 5.0;
	float b = floor(v);
	// dither only near the boundary between two steps; flat areas stay flat
	float f = clamp((v - b - 0.38) / 0.24, 0.0, 1.0);
	int idx = int(min(b + step(thr, f) * step(0.001, f), 5.0));
	ALBEDO = PAL[idx];
}
