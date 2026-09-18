extends Node

var seed_value: int = 65384

# 1. Instanciamos los objetos de ruido de entrada
var elevation_noise: FastNoiseLite = FastNoiseLite.new()
var moisture_noise: FastNoiseLite = FastNoiseLite.new()
var detail_noise: FastNoiseLite = FastNoiseLite.new()
var warp_noise: FastNoiseLite = FastNoiseLite.new()
var mountain_noise: FastNoiseLite = FastNoiseLite.new()
var erosion_noise: FastNoiseLite = FastNoiseLite.new()  # NUEVO: talla valles/mesetas

func _ready() -> void:
	# 2. Configuramos las propiedades de los ruidos (frecuencia, tipo) UNA SOLA VEZ
	_setup_noise_parameters()
	# 3. Aplicamos la seed inicial
	set_world_seed(seed_value)

func set_world_seed(new_seed: int) -> void:
	seed_value = new_seed

	# CORREGIDO: FastNoiseLite.seed es un int de 32 bits por dentro. Si
	# new_seed viene de un hash grande (ej. hash de un nombre de mundo)
	# "new_seed + 4000" podía desbordar el rango de 32 bits y, en el peor
	# caso, hacer que dos seeds distintas terminaran generando el mismo
	# ruido en algún canal. _fold_seed() lo mantiene siempre en un rango
	# seguro sin perder la dependencia de la seed original.
	elevation_noise.seed = _fold_seed(new_seed)
	moisture_noise.seed = _fold_seed(new_seed + 1000)
	detail_noise.seed = _fold_seed(new_seed + 2000)
	warp_noise.seed = _fold_seed(new_seed + 3000)
	mountain_noise.seed = _fold_seed(new_seed + 4000)
	erosion_noise.seed = _fold_seed(new_seed + 5000)

func _fold_seed(s: int) -> int:
	return int(posmod(s, 2147483647))

func _setup_noise_parameters() -> void:
	elevation_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	elevation_noise.frequency = 0.003
	elevation_noise.fractal_octaves = 4
	elevation_noise.fractal_lacunarity = 2.0
	elevation_noise.fractal_gain = 0.5

	moisture_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	moisture_noise.frequency = 0.0035
	moisture_noise.fractal_octaves = 3

	detail_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	detail_noise.frequency = 0.05
	detail_noise.fractal_octaves = 3
	detail_noise.fractal_gain = 0.45

	warp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	warp_noise.frequency = 0.002
	warp_noise.fractal_octaves = 3

	mountain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	mountain_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	mountain_noise.frequency = 0.004
	mountain_noise.fractal_octaves = 5
	mountain_noise.fractal_gain = 0.5

	# NUEVO: ruido de erosión, baja frecuencia, para cortar valles suaves
	# dentro de las zonas de páramo/pre-montaña y romper el aspecto de
	# "meseta pareja" que tenía el terreno antes.
	erosion_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	erosion_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	erosion_noise.frequency = 0.0015
	erosion_noise.fractal_octaves = 3
	erosion_noise.fractal_gain = 0.55

func hash01(x: int, z: int, salt: int = 0) -> float:
	# CORREGIDO (bug de seed): antes esta función no mezclaba seed_value
	# para nada, así que la vegetación (posición, escala, rotación, y qué
	# celdas tienen árbol) quedaba IDÉNTICA sin importar el world_seed que
	# pusieras. Solo el terreno cambiaba. Ahora el seed entra en la mezcla
	# igual que x/z/salt, así cada seed da un mundo realmente distinto.
	var h := int(x) * 374761393 + int(z) * 668265263 + salt * 2246822519 \
		+ seed_value * 3266489917
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0x7fffffff) / float(0x7fffffff)
