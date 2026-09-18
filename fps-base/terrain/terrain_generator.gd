class_name TerrainGenerator
extends RefCounted

enum Biome { PLAINS, PINE_FOREST, PARAMO, MOUNTAIN }

# OPTIMIZACIÓN: antes esto era un Dictionary de Dictionaries (BIOME_PARAMS
# {"base":.., "amp":.., "freq":..}). Un Dictionary por vértice, por bioma,
# es memoria/hash extra que no hace falta: con solo 4 biomas alcanza con
# arrays indexados por el enum (acceso directo, sin hashing).
const BIOME_COLOR := [
	Color(0.45, 0.65, 0.25),  # PLAINS
	Color(0.15, 0.35, 0.18),  # PINE_FOREST
	Color(0.55, 0.5, 0.3),    # PARAMO
	Color(0.5, 0.48, 0.46),   # MOUNTAIN
]
const BIOME_BASE := [2.0, 4.0, 12.0, 20.0]
const BIOME_AMP := [2.5, 5.0, 7.0, 10.0]
const BIOME_FREQ := [3.0, 2.3, 0.8, 1.6]

const BIOME_COUNT := 4

## Deforma las coordenadas reales antes de leer los biomas y alturas.
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

## Devuelve los pesos de cada bioma como PackedFloat32Array indexada por el
## enum Biome (más liviano que el Dictionary anterior: sin hashing, sin
## allocs de claves, y se puede indexar directo con el enum).
static func get_biome_weights(elevation: float, moisture: float) -> PackedFloat32Array:
	var w := PackedFloat32Array()
	w.resize(BIOME_COUNT)

	# Umbrales de elevación -> banda baja/media/alta. Se solapan a propósito
	# (las tres bandas se pisan un poco) para que la transición entre
	# biomas sea gradual y no un salto de altura brusco en el borde.
	var low_mid := 1.0 - smoothstep(-0.35, 0.05, elevation)
	var mid := smoothstep(-0.15, 0.05, elevation) * (1.0 - smoothstep(0.1, 0.4, elevation))
	# MEJORADO: la banda de montaña ahora arranca un poco antes (0.1 en vez
	# de 0.15) y con un rango más ancho, así el pie de monte se extiende
	# más y la cresta no "aparece de golpe" al cruzar el umbral.
	var high := smoothstep(0.1, 0.42, elevation)

	var forest_w := smoothstep(-0.1, 0.25, moisture)
	w[Biome.PINE_FOREST] = low_mid * forest_w
	w[Biome.PLAINS] = low_mid * (1.0 - forest_w)
	w[Biome.PARAMO] = mid
	w[Biome.MOUNTAIN] = high
	return w

## Núcleo del generador: un único pase que calcula altura + color + bioma
## dominante para un punto. OPTIMIZACIÓN clave: antes terrain_chunk.gd
## llamaba get_height(wx,wz) Y LUEGO get_color(wx,wz) para el mismo vértice,
## y cada una recalculaba por su cuenta get_warped_coords + el ruido de
## elevación/humedad + los pesos de bioma desde cero -> el trabajo de ruido
## más caro se hacía DOS VECES por vértice. Ahora se hace una sola vez.
static func sample_terrain(wx: float, wz: float) -> Dictionary:
	var w_pos := get_warped_coords(wx, wz)
	var elevation := WorldSeed.elevation_noise.get_noise_2d(w_pos.x, w_pos.y)
	var moisture := WorldSeed.moisture_noise.get_noise_2d(w_pos.x, w_pos.y)
	var weights := get_biome_weights(elevation, moisture)

	var height := 0.0
	var color := Color(0, 0, 0)
	for b in range(BIOME_COUNT):
		var w: float = weights[b]
		if w <= 0.001:
			continue
		var detail := WorldSeed.detail_noise.get_noise_2d(w_pos.x * BIOME_FREQ[b], w_pos.y * BIOME_FREQ[b])
		height += (BIOME_BASE[b] + detail * BIOME_AMP[b]) * w
		color += BIOME_COLOR[b] * w

	# NUEVO: erosión. Talla valles de baja frecuencia en la zona de
	# páramo/pre-montaña para que no se vea como una meseta pareja: sin
	# esto, todo lo que caía en la banda "mid" tenía prácticamente la misma
	# altura salvo por el detalle de alta frecuencia.
	var mid_mask: float = weights[Biome.PARAMO] + weights[Biome.MOUNTAIN] * 0.4
	if mid_mask > 0.001:
		var erosion := WorldSeed.erosion_noise.get_noise_2d(w_pos.x, w_pos.y)
		var erosion01 = clamp((erosion + 1.0) * 0.5, 0.0, 1.0)
		height -= (1.0 - erosion01) * 6.0 * mid_mask

	# Montaña: cresta afilada (ridged noise) que ahora crece de forma más
	# gradual (pow(mountain_w, 1.3) en vez de multiplicar directo por el
	# peso) y con un poco de detalle de alta frecuencia encima para que los
	# picos no se vean perfectamente lisos.
	var mountain_w: float = weights[Biome.MOUNTAIN]
	if mountain_w > 0.001:
		var ridge := WorldSeed.mountain_noise.get_noise_2d(w_pos.x, w_pos.y)
		ridge = clamp((ridge + 1.0) * 0.5, 0.0, 1.0)
		var sharp_ridge := pow(ridge, 2.5)
		var crag := WorldSeed.detail_noise.get_noise_2d(w_pos.x * 4.0, w_pos.y * 4.0)
		var mountain_mask := pow(mountain_w, 1.3)
		height += (sharp_ridge * 120.0 + crag * 4.0 * sharp_ridge) * mountain_mask

	return {
		"height": height,
		"color": color,
		"biome": _dominant_from_weights(weights),
	}

## Versión liviana solo-altura (sin color), para los casos que no necesitan
## pintar nada: el heightmap de colisión y las comprobaciones de pendiente
## de la vegetación. Evita el trabajo extra de mezclar color por nada.
static func get_height(wx: float, wz: float) -> float:
	var w_pos := get_warped_coords(wx, wz)
	var elevation := WorldSeed.elevation_noise.get_noise_2d(w_pos.x, w_pos.y)
	var moisture := WorldSeed.moisture_noise.get_noise_2d(w_pos.x, w_pos.y)
	var weights := get_biome_weights(elevation, moisture)

	var height := 0.0
	for b in range(BIOME_COUNT):
		var w: float = weights[b]
		if w <= 0.001:
			continue
		var detail := WorldSeed.detail_noise.get_noise_2d(w_pos.x * BIOME_FREQ[b], w_pos.y * BIOME_FREQ[b])
		height += (BIOME_BASE[b] + detail * BIOME_AMP[b]) * w

	var mid_mask: float = weights[Biome.PARAMO] + weights[Biome.MOUNTAIN] * 0.4
	if mid_mask > 0.001:
		var erosion := WorldSeed.erosion_noise.get_noise_2d(w_pos.x, w_pos.y)
		var erosion01 = clamp((erosion + 1.0) * 0.5, 0.0, 1.0)
		height -= (1.0 - erosion01) * 6.0 * mid_mask

	var mountain_w: float = weights[Biome.MOUNTAIN]
	if mountain_w > 0.001:
		var ridge := WorldSeed.mountain_noise.get_noise_2d(w_pos.x, w_pos.y)
		ridge = clamp((ridge + 1.0) * 0.5, 0.0, 1.0)
		var sharp_ridge := pow(ridge, 2.5)
		var crag := WorldSeed.detail_noise.get_noise_2d(w_pos.x * 4.0, w_pos.y * 4.0)
		var mountain_mask := pow(mountain_w, 1.3)
		height += (sharp_ridge * 120.0 + crag * 4.0 * sharp_ridge) * mountain_mask

	return height

static func get_color(wx: float, wz: float) -> Color:
	var w_pos := get_warped_coords(wx, wz)
	var weights := get_biome_weights(get_elevation(w_pos.x, w_pos.y), get_moisture(w_pos.x, w_pos.y))
	var c := Color(0, 0, 0)
	for b in range(BIOME_COUNT):
		c += BIOME_COLOR[b] * weights[b]
	return c

static func get_dominant_biome(wx: float, wz: float) -> int:
	var w_pos := get_warped_coords(wx, wz)
	var weights := get_biome_weights(get_elevation(w_pos.x, w_pos.y), get_moisture(w_pos.x, w_pos.y))
	return _dominant_from_weights(weights)

static func _dominant_from_weights(weights: PackedFloat32Array) -> int:
	var best_b := 0
	var best_w := -1.0
	for b in range(BIOME_COUNT):
		if weights[b] > best_w:
			best_w = weights[b]
			best_b = b
	return best_b
