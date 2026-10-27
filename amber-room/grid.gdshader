// Floor of the viewing space: dark grid that fades out with distance.
shader_type spatial;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 g = abs(fract(wpos.xz) - 0.5);
	vec2 w = fwidth(wpos.xz) * 1.2;
	float line = max(smoothstep(0.5 - w.x, 0.5, g.x), smoothstep(0.5 - w.y, 0.5, g.y));
	float fade = clamp(1.0 - length(wpos.xz) / 18.0, 0.0, 1.0);
	ALBEDO = mix(vec3(0.05, 0.055, 0.065), vec3(0.22, 0.24, 0.28), line * fade);
	ROUGHNESS = 0.9;
}
