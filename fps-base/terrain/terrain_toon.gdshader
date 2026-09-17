shader_type spatial;
// ambient_light_disabled = LA LÍNEA CLAVE. Sin esto, la luz ambiental del
// WorldEnvironment se suma encima del cel-shading y lava todo a blanco.
render_mode blend_mix, cull_back, specular_disabled, ambient_light_disabled;

uniform int light_bands : hint_range(2, 6) = 3;
uniform float rim_amount : hint_range(0.0, 1.0) = 0.25;
uniform vec4 rim_color : source_color = vec4(1.0, 1.0, 0.95, 1.0);
uniform float grain_strength : hint_range(0.0, 0.2) = 0.04;

// Color de la "sombra" (zona no iluminada). En estilo anime la sombra NO es
// negra: es una versión fría y oscura del propio color base.
uniform vec4 shadow_tint : source_color = vec4(0.35, 0.42, 0.6, 1.0);
uniform float shadow_strength : hint_range(0.0, 1.0) = 0.55;

// Si tu vegetación no trae vertex color (MultiMesh con mallas primitivas),
// activá use_flat_color y definí flat_color.
uniform bool use_flat_color = false;
uniform vec4 flat_color : source_color = vec4(0.2, 0.45, 0.22, 1.0);

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float cheap_noise(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec3 base = use_flat_color ? flat_color.rgb : COLOR.rgb;
	float n = cheap_noise(floor(world_pos.xz * 2.0));
	ALBEDO = base + (n - 0.5) * grain_strength;
}

void light() {
	float ndotl = dot(normalize(NORMAL), normalize(LIGHT));
	// bandas duras de luz -> look "anime" (en vez de degradado suave)
	float lit = clamp(ndotl, 0.0, 1.0);
	float banded = ceil(lit * float(light_bands)) / float(light_bands);
	banded *= ATTENUATION;

	// mezclamos entre color-en-sombra y color-iluminado
	vec3 shaded = mix(ALBEDO * shadow_tint.rgb * shadow_strength, ALBEDO, banded);

	DIFFUSE_LIGHT += shaded * LIGHT_COLOR.rgb;

	// rim light sutil, típico del estilo anime a contraluz
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 4.0);
	DIFFUSE_LIGHT += rim * rim_amount * rim_color.rgb * banded;
}
