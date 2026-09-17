extends Node
## AUTOLOAD - registrar en Project Settings > AutoLoad con el nombre "WorldSeed"

var seed_value: int = 1337

var elevation_noise: FastNoiseLite
var moisture_noise: FastNoiseLite
var detail_noise: FastNoiseLite
var warp_noise: FastNoiseLite
var mountain_noise: FastNoiseLite # NUEVO: Para picos realistas

func _ready() -> void:
	set_world_seed(seed_value)

func set_world_seed(new_seed: int) -> void:
	seed_value = new_seed

	elevation_noise = FastNoiseLite.new()
	elevation_noise.seed = new_seed
	elevation_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH # Simplex es más orgánico que Perlin
	elevation_noise.frequency = 0.003 # Frecuencia ligeramente menor para masas de tierra más grandes
	elevation_noise.fractal_octaves = 4
	elevation_noise.fractal_lacunarity = 2.0
	elevation_noise.fractal_gain = 0.5

	moisture_noise = FastNoiseLite.new()
	moisture_noise.seed = new_seed + 1000
	moisture_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	moisture_noise.frequency = 0.0035
	moisture_noise.fractal_octaves = 3

	detail_noise = FastNoiseLite.new()
	detail_noise.seed = new_seed + 2000
	detail_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	detail_noise.frequency = 0.05
	detail_noise.fractal_octaves = 3
	detail_noise.fractal_gain = 0.45

	# NUEVO WARP: Usado para distorsionar/doblar las coordenadas (Domain Warping)
	warp_noise = FastNoiseLite.new()
	warp_noise.seed = new_seed + 3000
	warp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	warp_noise.frequency = 0.002
	warp_noise.fractal_octaves = 3

	# NUEVO MONTAIN: Ruido Ridged genera cordilleras y picos afilados naturalmente
	mountain_noise = FastNoiseLite.new()
	mountain_noise.seed = new_seed + 4000
	mountain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	mountain_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	mountain_noise.frequency = 0.004
	mountain_noise.fractal_octaves = 5
	mountain_noise.fractal_gain = 0.5

func hash01(x: int, z: int, salt: int = 0) -> float:
	var h := int(x) * 374761393 + int(z) * 668265263 + salt * 2246822519
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0x7fffffff) / float(0x7fffffff)
