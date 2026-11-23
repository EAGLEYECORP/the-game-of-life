// Facades for the city's buildings, drawn procedurally (no textures).
//
// Walls get windows, shopfronts and, depending on style, architectural detail:
//   style 0  Medina: whitewash, few small windows, painted shutters
//   style 1  modern Casablanca: regular window grid, shopfronts at street level
//   style 2  Art Deco (downtown): pilasters between window bays, floor bands
//            and a stepped cornice under the roof line
// At night a random share of windows glow warm, driven by the global
// `night_factor` that DayNightCycle publishes.
//
// Inputs, from scripts/world/osm/chunk_builder.gd:
//   COLOR  facade colour (sRGB)
//   UV     walls: (metres along the outline, metres above ground); other
//          surfaces (roofs, roads, ground) have UV.y < 0 and are left plain
//   UV2    (style, building height)
// The placeholder city has no UVs; it sets use_world_coords and derives the
// wall coordinates from world position on its axis-aligned boxes instead.
shader_type spatial;

global uniform float night_factor;

uniform bool use_world_coords = false;
uniform vec4 base_color : source_color = vec4(1.0);
uniform float world_style = 1.0;
instance uniform float building_top = 20.0;

varying vec2 wall_uv;
varying float style;
varying float top;
varying float is_wall;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}

void vertex() {
	vec3 wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	if (use_world_coords) {
		wall_uv = vec2(abs(wn.x) > 0.5 ? wpos.z : wpos.x, wpos.y);
		style = world_style;
		top = building_top;
		is_wall = abs(wn.y) < 0.5 ? 1.0 : 0.0;
	} else {
		wall_uv = UV;
		style = UV2.x;
		top = UV2.y;
		is_wall = (UV.y >= 0.0 && abs(wn.y) < 0.5) ? 1.0 : 0.0;
	}
}

void fragment() {
	vec3 col = use_world_coords ? base_color.rgb : srgb_to_linear(COLOR.rgb);
	float rough = 0.85;
	float metal = 0.0;
	vec3 emit = vec3(0.0);

	if (is_wall > 0.5 && style >= 0.0) {
		float h = wall_uv.y;
		float u = wall_uv.x;
		float deco = step(1.5, style);
		float medina = 1.0 - step(0.5, style);

		float floor_h = mix(3.1, 3.4, deco);
		float bay_w = medina > 0.5 ? 3.8 : mix(2.8, 2.3, deco);
		float fid = floor(h / floor_h);
		float fv = fract(h / floor_h);
		float cid = floor(u / bay_w);
		float fu = fract(u / bay_w);
		float seed = hash(vec2(cid, fid) + top * 0.37);

		// Upper-floor windows (none in the parapet just under the roof).
		float ww = medina > 0.5 ? 0.22 : 0.5;
		float wh = medina > 0.5 ? 0.32 : 0.55;
		float win = step(abs(fu - 0.5), ww * 0.5) * step(abs(fv - 0.55), wh * 0.5);
		win *= step(h, top - 1.0);
		if (medina > 0.5 && seed < 0.5) {
			win = 0.0;              // Medina walls are mostly blank.
		}
		// Street level: shopfronts on most bays.
		if (h < 3.4) {
			win = step(abs(fu - 0.5), 0.38) * step(abs(h - 1.55), 1.05) * step(0.3, seed);
		}

		// Art Deco detailing: lighter pilasters between bays, a band at each
		// floor and a stepped cornice under the roof.
		if (deco > 0.5) {
			float pilaster = step(fu, 0.07) + step(0.93, fu);
			float band = step(fv, 0.06) * step(3.4, h);
			float cornice = step(top - 1.3, h) * (0.6 + 0.4 * step(0.5, fract((top - h) * 2.2)));
			col = mix(col, col * 1.08 + 0.03, clamp(pilaster + band, 0.0, 1.0) * (1.0 - win));
			col = mix(col, col * 0.86, cornice);
		}

		// Glass, with painted shutters on some Medina and residential windows.
		vec3 glass = mix(vec3(0.07, 0.1, 0.13), vec3(0.2, 0.26, 0.32), seed);
		if (h >= 3.4 && seed > 0.78 && deco < 0.5) {
			glass = seed > 0.89 ? vec3(0.05, 0.25, 0.45) : vec3(0.08, 0.35, 0.22);   // Majorelle-ish blue / green.
			rough = mix(rough, 0.7, win);
		} else {
			rough = mix(rough, 0.12, win);
			metal = 0.25 * win;
		}
		col = mix(col, glass, win);

		// Lights on at night in a share of the windows.
		float lit = step(0.5, hash(vec2(cid * 1.7, fid * 3.1) + top)) * night_factor;
		if (h < 3.4) {
			lit = night_factor * step(0.3, seed);    // Shops stay lit late.
		}
		emit = win * lit * vec3(1.0, 0.76, 0.42) * 1.8;

		// Darker, dirtier base where the wall meets the pavement.
		col *= mix(0.8, 1.0, clamp(h / 1.2, 0.0, 1.0));
	}

	ALBEDO = col;
	ROUGHNESS = rough;
	METALLIC = metal;
	EMISSION = emit;
}
