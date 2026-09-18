class_name TerrainChunk
extends Node3D
## Un chunk cuadrado de terreno. Se genera en un WorkerThreadPool task y
## solo aplica los resultados al árbol de escena en el hilo principal
## (vía call_deferred). Diseñado para reciclarse: reset_for() reutiliza
## el mismo nodo para una coordenada nueva en vez de crear uno.

const CHUNK_SIZE := 16.0   # metros por lado
const BASE_RES := 32       # subdivisiones en LOD 0 (máximo detalle)
# Muestras del heightmap de colisión por lado. HeightMapShape3D asume 1
# unidad entre muestras, así que esto DEBE ser CHUNK_SIZE + 1 para que la
# colisión cubra exactamente el chunk sin escalar nada.
const COLLISION_SAMPLES := int(CHUNK_SIZE) + 1

var chunk_x: int
var chunk_z: int
var lod: int = 0

var mesh_instance: MeshInstance3D
var static_body: StaticBody3D
var collision_shape: CollisionShape3D
var veg_multimeshes: Array[MultiMeshInstance3D] = []

var _generation_id: int = 0  # evita aplicar datos de una generación obsoleta

# Un único ShaderMaterial compartido por TODOS los chunks (barato: no se
# crea uno nuevo por chunk, y cambiar un uniform afecta a todo el terreno).
static var _shared_material: ShaderMaterial


func _ready() -> void:
	mesh_instance = MeshInstance3D.new()
	add_child(mesh_instance)
	mesh_instance.material_override = _get_shared_material()

	static_body = StaticBody3D.new()
	add_child(static_body)
	collision_shape = CollisionShape3D.new()
	static_body.add_child(collision_shape)


## Reinicia este chunk (posiblemente reciclado del pool) para una nueva coordenada.
func reset_for(cx: int, cz: int, new_lod: int, with_collision: bool, high_priority: bool = false) -> void:
	chunk_x = cx
	chunk_z = cz
	lod = new_lod
	_generation_id += 1
	var my_gen := _generation_id

	position = Vector3(cx * CHUNK_SIZE, 0.0, cz * CHUNK_SIZE)
	visible = true
	# La colisión vieja queda desactivada hasta que el hilo entregue la nueva,
	# si no el jugador chocaría con el terreno del chunk anterior.
	collision_shape.disabled = true
	for mm in veg_multimeshes:
		mm.queue_free()
	veg_multimeshes.clear()

	var res: int = max(4, BASE_RES >> lod)
	# high_priority=true salta adelante en la cola del WorkerThreadPool.
	# CRÍTICO para chunks con colisión: el piso bajo el jugador no puede
	# quedar esperando detrás de un montón de LOD lejano en cola.
	WorkerThreadPool.add_task(
		_generate_threaded.bind(cx, cz, res, with_collision, my_gen),
		high_priority
	)


func despawn() -> void:
	visible = false
	# OJO: visible = false NO desactiva la física. Hay que deshabilitar el
	# CollisionShape3D explícitamente o el chunk reciclado sigue colisionando
	# (el clásico "suelo invisible" / colisiones fantasma).
	collision_shape.disabled = true
	collision_shape.shape = null
	for mm in veg_multimeshes:
		mm.queue_free()
	veg_multimeshes.clear()


# ============================================================
# TODO lo de aquí abajo (_generate_threaded y helpers) corre en
# un hilo de fondo: PROHIBIDO tocar el árbol de nodos ahí dentro.
# ============================================================

func _generate_threaded(cx: int, cz: int, res: int, with_collision: bool, gen_id: int) -> void:
	var step := CHUNK_SIZE / res
	var count := (res + 1) * (res + 1)
	var heights := PackedFloat32Array()
	heights.resize(count)
	var colors := PackedColorArray()
	colors.resize(count)

	# OPTIMIZACIÓN: antes se llamaba get_height() y get_color() por
	# separado para el mismo vértice, y cada una repetía desde cero el
	# domain warp + el ruido de elevación/humedad + el cálculo de pesos
	# de bioma. sample_terrain() hace todo ese trabajo una sola vez por
	# vértice (altura y color salen del mismo pase de ruido).
	for zi in range(res + 1):
		for xi in range(res + 1):
			var wx := cx * CHUNK_SIZE + xi * step
			var wz := cz * CHUNK_SIZE + zi * step
			var idx := zi * (res + 1) + xi
			var s := TerrainGenerator.sample_terrain(wx, wz)
			heights[idx] = s.height
			colors[idx] = s.color

	var arrays := _build_surface_arrays(heights, colors, res, step)

	# IMPORTANTE: NO se puede construir ArrayMesh/SurfaceTool acá. Ambos
	# disparan llamadas al RenderingServer, y crear recursos de render
	# fuera del hilo principal puede colgar el motor (deadlock silencioso,
	# sin ningún error en consola) según el renderer/driver usado. Por eso
	# esta función solo prepara los "arrays" en bruto (PackedArrays) y la
	# malla final se arma en _apply_generated_data(), ya en el hilo principal.

	var coll_heights := PackedFloat32Array()
	if with_collision:
		var n := COLLISION_SAMPLES
		coll_heights.resize(n * n)
		for zi in range(n):
			for xi in range(n):
				var wx := cx * CHUNK_SIZE + float(xi)
				var wz := cz * CHUNK_SIZE + float(zi)
				coll_heights[zi * n + xi] = TerrainGenerator.get_height(wx, wz)

	var veg_data := {}
	if lod == 0:
		veg_data = _scatter_vegetation(cx, cz)

	# Enviamos los arrays en bruto (nada de RenderingServer) al hilo principal
	call_deferred("_apply_generated_data", arrays, coll_heights, with_collision, veg_data, gen_id)

func _build_surface_arrays(heights: PackedFloat32Array, colors: PackedColorArray, res: int, step: float) -> Array:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var indices := PackedInt32Array()
	var count := (res + 1) * (res + 1)
	verts.resize(count)
	uvs.resize(count)
	cols.resize(count)

	for zi in range(res + 1):
		for xi in range(res + 1):
			var idx := zi * (res + 1) + xi
			verts[idx] = Vector3(xi * step, heights[idx], zi * step)
			uvs[idx] = Vector2(float(xi) / res, float(zi) / res)
			cols[idx] = colors[idx]

	for zi in range(res):
		for xi in range(res):
			var i0 := zi * (res + 1) + xi
			var i1 := i0 + 1
			var i2 := i0 + (res + 1)
			var i3 := i2 + 1
			# Godot usa winding HORARIO para caras frontales (al revés del
			# default de OpenGL). Con el orden invertido las normales salían
			# apuntando hacia abajo y el terreno solo se veía desde abajo.
			indices.append(i0); indices.append(i1); indices.append(i2)
			indices.append(i1); indices.append(i3); indices.append(i2)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays


## Distribución de vegetación tipo "grid + jitter" (blue-noise barato),
## 100% determinista por semilla -> mismo mundo, mismos árboles, siempre.
func _scatter_vegetation(cx: int, cz: int) -> Dictionary:
	var cell_size := 3.0
	var per_axis := int(CHUNK_SIZE / cell_size)
	var result := {}  # biome_id -> Array[Transform3D]

	for gz in range(per_axis):
		for gx in range(per_axis):
			var jx := WorldSeed.hash01(cx * per_axis + gx, cz * per_axis + gz, 11)
			var jz := WorldSeed.hash01(cx * per_axis + gx, cz * per_axis + gz, 22)
			var lx := (gx + jx) * cell_size
			var lz := (gz + jz) * cell_size
			var wx := cx * CHUNK_SIZE + lx
			var wz := cz * CHUNK_SIZE + lz

			# OPTIMIZACIÓN: un solo sample_terrain() para bioma + altura del
			# punto candidato, en vez de get_dominant_biome() + get_height()
			# por separado (cada una repetía el warp/ruido de elevación).
			var sample := TerrainGenerator.sample_terrain(wx, wz)
			var biome: int = sample.biome
			var density := _vegetation_density(biome)
			if density <= 0.0:
				continue
			if WorldSeed.hash01(int(wx * 10.0), int(wz * 10.0), 33) > density:
				continue

			var h: float = sample.height
			# no poner vegetación en pendientes muy pronunciadas
			# (get_height liviano: no hace falta el color para esto)
			var slope_x := TerrainGenerator.get_height(wx + 1.0, wz) - h
			var slope_z := TerrainGenerator.get_height(wx, wz + 1.0) - h
			if abs(slope_x) > 1.5 or abs(slope_z) > 1.5:
				continue

			var s := 0.8 + WorldSeed.hash01(int(wx * 5.0), int(wz * 5.0), 44) * 0.5
			var rot := WorldSeed.hash01(int(wx * 7.0), int(wz * 7.0), 55) * TAU
			var t := Transform3D()
			t = t.scaled(Vector3.ONE * s)
			t = t.rotated(Vector3.UP, rot)
			t.origin = Vector3(lx, h, lz)

			if not result.has(biome):
				result[biome] = []
			result[biome].append(t)

	return result


func _vegetation_density(biome: int) -> float:
	match biome:
		TerrainGenerator.Biome.PINE_FOREST: return 0.55
		TerrainGenerator.Biome.PLAINS: return 0.05
		TerrainGenerator.Biome.PARAMO: return 0.08
		TerrainGenerator.Biome.MOUNTAIN: return 0.0
	return 0.0


# ============================================================
# De vuelta en el hilo principal: aquí SÍ se puede tocar la escena.
# ============================================================
func _apply_generated_data(arrays: Array, coll_heights: PackedFloat32Array,
		with_collision: bool, veg_data: Dictionary, gen_id: int) -> void:

	if gen_id != _generation_id:
		return

	# La malla y las normales SÍ se arman acá: estamos en el hilo principal,
	# así que tocar el RenderingServer (ArrayMesh, SurfaceTool) es seguro.
	var temp_mesh := ArrayMesh.new()
	temp_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var st := SurfaceTool.new()
	st.create_from(temp_mesh, 0)
	st.generate_normals()
	var final_mesh: ArrayMesh = st.commit()

	mesh_instance.mesh = final_mesh

	if with_collision:
		var shape := HeightMapShape3D.new()
		shape.map_width = COLLISION_SAMPLES
		shape.map_depth = COLLISION_SAMPLES
		shape.map_data = coll_heights
		collision_shape.shape = shape
		var half := float(COLLISION_SAMPLES - 1) * 0.5
		collision_shape.position = Vector3(half, 0.0, half)
		static_body.scale = Vector3.ONE 
		collision_shape.disabled = false
	else:
		collision_shape.shape = null
		collision_shape.disabled = true

## Ruta del shader toon. Si lo guardaste en otra carpeta, cambiá esto.
const TOON_SHADER_PATH := "res://terrain/terrain_toon.gdshader"

## Carga (una sola vez) el ShaderMaterial toon compartido por todos los chunks.
static func _get_shared_material() -> ShaderMaterial:
	if _shared_material == null:
		_shared_material = ShaderMaterial.new()
		if ResourceLoader.exists(TOON_SHADER_PATH):
			_shared_material.shader = load(TOON_SHADER_PATH) as Shader
		else:
			push_error("TerrainChunk: no se encontró el shader en '%s'. "
				% TOON_SHADER_PATH
				+ "Corregí TOON_SHADER_PATH o mové el .gdshader ahí.")
	return _shared_material


## Colores planos de la vegetación por bioma (los MultiMesh de mallas
## primitivas no traen vertex color, por eso usamos use_flat_color).
const VEG_COLOR := {
	TerrainGenerator.Biome.PINE_FOREST: Color(0.12, 0.32, 0.18),
	TerrainGenerator.Biome.PLAINS: Color(0.35, 0.5, 0.22),
	TerrainGenerator.Biome.PARAMO: Color(0.45, 0.45, 0.3),
}

static var _veg_material_cache: Dictionary = {}

## Material toon (color plano) por bioma, cacheado -> un material por bioma
## para todo el mundo, no uno por chunk.
static func _get_vegetation_material(biome: int) -> ShaderMaterial:
	if _veg_material_cache.has(biome):
		return _veg_material_cache[biome]
	var mat := ShaderMaterial.new()
	mat.shader = _get_shared_material().shader
	mat.set_shader_parameter("use_flat_color", true)
	mat.set_shader_parameter("flat_color", VEG_COLOR.get(biome, Color(0.3, 0.4, 0.2)))
	mat.set_shader_parameter("grain_strength", 0.0)
	_veg_material_cache[biome] = mat
	return mat


## Mallas placeholder muy baratas (sin assets externos). Reemplázalas por
## tus modelos reales (PackedScene -> mesh) cuando tengas arte.
## NOTA: 'static var' de caché requiere Godot 4.2+; en versiones previas
## mueve este diccionario a una variable de instancia en ChunkManager.
static var _veg_mesh_cache: Dictionary = {}

static func _get_vegetation_mesh(biome: int) -> Mesh:
	if _veg_mesh_cache.has(biome):
		return _veg_mesh_cache[biome]
	var mesh: Mesh
	match biome:
		TerrainGenerator.Biome.PINE_FOREST:
			var m := CylinderMesh.new()
			m.top_radius = 0.0
			m.bottom_radius = 1.2
			m.height = 5.0
			mesh = m
		TerrainGenerator.Biome.PARAMO:
			var m2 := SphereMesh.new()
			m2.radius = 0.4
			m2.height = 0.6
			mesh = m2
		_:
			var m3 := BoxMesh.new()
			m3.size = Vector3(0.5, 1.0, 0.5)
			mesh = m3
	_veg_mesh_cache[biome] = mesh
	return mesh
