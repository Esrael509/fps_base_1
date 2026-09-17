class_name TerrainGenerator
extends RefCounted

enum Biome { PLAINS, PINE_FOREST, PARAMO, MOUNTAIN }

const BIOME_COLOR := {
	Biome.PLAINS: Color(0.45, 0.65, 0.25),
	Biome.PINE_FOREST: Color(0.15, 0.35, 0.18),
	Biome.PARAMO: Color(0.55, 0.5, 0.3),
	Biome.MOUNTAIN: Color(0.5, 0.48, 0.46),
}

# La montaña ahora usará un multiplicador de cresta exponencial en lugar de solo amplitud
const BIOME_PARAMS := {
	Biome.PLAINS:      {"base": 2.0,  "amp": 2.5,  "freq": 3.0},
	Biome.PINE_FOREST: {"base": 4.0,  "amp": 5.0,  "freq": 2.3},
	Biome.PARAMO:      {"base": 12.0, "amp": 7.0,  "freq": 0.8},
	Biome.MOUNTAIN:    {"base": 20.0, "amp": 10.0, "freq": 1.6},
}

## NUEVO: Deforma las coordenadas reales antes de leer los biomas y alturas.
## Esto le da al terreno ese aspecto "barrido" y orgánico.
static func get_warped_coords(wx: float, wz: float) -> Vector2:
	var warp_strength := 60.0
	var dx := WorldSeed.warp_noise.get_noise_2d(wx, wz) * warp_strength
	var dz := WorldSeed.warp_noise.get_noise_2d(wx + 1000.0, wz + 1000.0) * warp_strength
	return Vector2(wx + dx, wz + dz)

static func get_elevation(wx: float, wz: float) -> float:
	return WorldSeed.elevation_noise.get_noise_2d(wx, wz)

static func get_moisture(wx: float, wz: float) -> float:
	return WorldSeed.moisture_noise.get_noise_2d(wx, wz)

static func get_biome_weights(elevation: float, moisture: float) -> Dictionary:
	var w := {
		Biome.PLAINS: 0.0, Biome.PINE_FOREST: 0.0,
		Biome.PARAMO: 0.0, Biome.MOUNTAIN: 0.0,
	}

	# MODIFICADO: Bajamos los umbrales para que haya MÁS montañas.
	# Antes pedía > 0.35 para ser montaña. Ahora pide > 0.15.
	var low_mid := 1.0 - smoothstep(-0.35, 0.05, elevation)
	var mid := smoothstep(-0.15, 0.05, elevation) * (1.0 - smoothstep(0.15, 0.4, elevation))
	var high := smoothstep(0.15, 0.4, elevation) 

	var forest_w := smoothstep(-0.1, 0.25, moisture)
	w[Biome.PINE_FOREST] = low_mid * forest_w
	w[Biome.PLAINS] = low_mid * (1.0 - forest_w)
	w[Biome.PARAMO] = mid
	w[Biome.MOUNTAIN] = high
	return w

static func get_height(wx: float, wz: float) -> float:
	# 1. Pasamos las coordenadas por la distorsión
	var w_pos := get_warped_coords(wx, wz)
	
	var elevation := get_elevation(w_pos.x, w_pos.y)
	var moisture := get_moisture(w_pos.x, w_pos.y)
	var weights := get_biome_weights(elevation, moisture)

	var height := 0.0
	for biome in weights.keys():
		var w: float = weights[biome]
		if w <= 0.001:
			continue
		var p: Dictionary = BIOME_PARAMS[biome]
		var detail := WorldSeed.detail_noise.get_noise_2d(w_pos.x * p.freq, w_pos.y * p.freq)
		height += (p.base + detail * p.amp) * w

	# 2. Generación realista de Montañas
	var mountain_w: float = weights[Biome.MOUNTAIN]
	if mountain_w > 0.001:
		# Extraemos el ruido Ridged (va de aprox -1 a 1 en Godot)
		var ridge := WorldSeed.mountain_noise.get_noise_2d(w_pos.x, w_pos.y)
		# Lo normalizamos de 0 a 1
		ridge = clamp((ridge + 1.0) * 0.5, 0.0, 1.0)
		# Lo elevamos a una potencia (2.5) para que los valles sean anchos y los picos agresivos
		var sharp_ridge = pow(ridge, 2.5)
		
		# Le damos una altura masiva (ej. 120 metros de pico) y lo multiplicamos por el peso del bioma
		height += (sharp_ridge * 120.0) * mountain_w

	return height

static func get_color(wx: float, wz: float) -> Color:
	var w_pos := get_warped_coords(wx, wz)
	var weights := get_biome_weights(get_elevation(w_pos.x, w_pos.y), get_moisture(w_pos.x, w_pos.y))
	var c := Color(0, 0, 0)
	for biome in weights.keys():
		c += BIOME_COLOR[biome] * float(weights[biome])
	return c
	
static func get_dominant_biome(wx: float, wz: float) -> int:
	var w_pos := get_warped_coords(wx, wz)
	var weights := get_biome_weights(get_elevation(w_pos.x, w_pos.y), get_moisture(w_pos.x, w_pos.y))
	var best_b: int = Biome.PLAINS
	var best_w := -1.0
	for biome in weights.keys():
		if weights[biome] > best_w:
			best_w = weights[biome]
			best_b = biome
	return best_b
