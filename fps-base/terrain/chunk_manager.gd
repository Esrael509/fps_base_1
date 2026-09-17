class_name ChunkManager
extends Node3D
## Colgar este script de un Node3D en tu escena principal, junto al Player.
## Se encarga de crear/reciclar chunks de TerrainChunk alrededor del jugador.
##
## IMPORTANTE sobre orden de generación: "qué hace falta" (_recalculate_needed)
## y "cuándo se genera de verdad" (_process_pending_spawns) están separados
## a propósito. Si se generaran todos los chunks del anillo en el mismo
## frame sin orden, al caminar hacia territorio nuevo el piso bajo el
## jugador podía terminar esperando en la cola del WorkerThreadPool detrás
## de un montón de LOD lejano -> el jugador caía al vacío momentáneamente.

@export var player_path: NodePath
@export var render_distance: int = 1     # radio (en chunks) con malla de máximo detalle
@export var far_distance: int = 5       # radio con LOD reducido (sin colisión)
@export var collision_distance: int = 2  # radio con collider físico activo
@export var world_seed: int = 987651
@export var max_far_chunks_per_frame: int = 8  # throttle SOLO para lo no-crítico

@export_group("Rango visual (opcional, recomendado)")
@export var camera_path: NodePath            # tu Camera3D -> ajusta el far clip automáticamente
@export var world_environment_path: NodePath # tu WorldEnvironment -> niebla automática
@export var fog_buffer_chunks: int = 4       # cuántos chunks antes del borde empieza la niebla

var player: Node3D
var _active_chunks: Dictionary = {}   # Vector2i -> TerrainChunk
var _pool: Array[TerrainChunk] = []
var _last_center := Vector2i(999999, 999999)
var _pending: Array = []  # [{coord: Vector2i, dist: int}, ...] ordenado por distancia ascendente

# --- DEBUG TEMPORAL: borrar cuando ya no lo necesites ---
var _debug_timer: float = 0.0


func _ready() -> void:
	if collision_distance > far_distance or render_distance > far_distance:
		push_warning("ChunkManager: collision_distance (%d) y render_distance (%d) deberían ser <= far_distance (%d). "
			% [collision_distance, render_distance, far_distance]
			+ "far_distance es el radio máximo cargado alrededor del jugador; "
			+ "pedir colisión/LOD alto más allá de eso no tiene ningún chunk sobre el que aplicarse.")

	WorldSeed.set_world_seed(world_seed)
	player = get_node(player_path)

	var start := player.global_position
	start.y = TerrainGenerator.get_height(start.x, start.z) + 2.0
	#player.global_position = start

	#_apply_visual_range()
	_recalculate_needed(_world_to_chunk(player.global_position))


## Oculta el borde real del mundo (fin de far_distance) detrás de niebla,
## y recorta el far-clip de la cámara para no gastar fillrate dibujando
## hacia donde no hay geometría. Se recalcula solo, así que si cambiás
## far_distance en el inspector no hace falta tocar nada más a mano.
#func _apply_visual_range() -> void:
	#var far_world := float(far_distance) * TerrainChunk.CHUNK_SIZE
#
	#if camera_path != NodePath():
		#var cam := get_node_or_null(camera_path) as Camera3D
		#if cam:
			#cam.far = far_world + TerrainChunk.CHUNK_SIZE  # +1 chunk de margen
#
	#if world_environment_path != NodePath():
		#var world_env := get_node_or_null(world_environment_path) as WorldEnvironment
		#if world_env and world_env.environment:
			#var env := world_env.environment
			#env.fog_enabled = true
			#var begin_chunks: int = maxi(0, far_distance - fog_buffer_chunks)
			#env.fog_depth_begin = float(begin_chunks) * TerrainChunk.CHUNK_SIZE
			#env.fog_depth_end = far_world


func _process(_delta: float) -> void:
	var center := _world_to_chunk(player.global_position)
	if center != _last_center:
		_last_center = center
		_recalculate_needed(center)
	_process_pending_spawns()

	# --- DEBUG TEMPORAL ---
	_debug_timer += _delta
	if _debug_timer >= 1.0:
		_debug_timer = 0.0
		print("center=", center, " active=", _active_chunks.size(),
			" pending=", _pending.size(), " pool=", _pool.size())


func _world_to_chunk(pos: Vector3) -> Vector2i:
	return Vector2i(
		int(floor(pos.x / TerrainChunk.CHUNK_SIZE)),
		int(floor(pos.z / TerrainChunk.CHUNK_SIZE))
	)


## Decide QUÉ coordenadas hacen falta y libera las que sobran.
## No genera nada todavía: solo llena la cola _pending, ordenada por
## distancia (lo cercano/crítico siempre primero).
func _recalculate_needed(center: Vector2i) -> void:
	var needed := {}  # Vector2i -> distancia (chebyshev)
	for dz in range(-far_distance, far_distance + 1):
		for dx in range(-far_distance, far_distance + 1):
			var dist := maxi(absi(dx), absi(dz))
			if dist > far_distance:
				continue
			needed[Vector2i(center.x + dx, center.y + dz)] = dist

	# liberar (al pool) los chunks que quedaron fuera de rango
	for coord in _active_chunks.keys():
		if not needed.has(coord):
			var chunk: TerrainChunk = _active_chunks[coord]
			chunk.despawn()
			_pool.append(chunk)
			_active_chunks.erase(coord)

	_pending.clear()
	for coord in needed.keys():
		if not _active_chunks.has(coord):
			_pending.append({"coord": coord, "dist": needed[coord]})
	_pending.sort_custom(func(a, b): return a.dist < b.dist)


## Genera de a poco desde _pending, cada frame. Los chunks con colisión
## (dist <= collision_distance) NUNCA se throttlean: se generan todos,
## siempre, sin límite por frame. Solo el LOD lejano (sin colisión) se
## limita a max_far_chunks_per_frame para no saturar el WorkerThreadPool
## cuando el jugador entra de golpe a territorio nuevo.
func _process_pending_spawns() -> void:
	var far_spawned := 0
	var i := 0
	while i < _pending.size():
		var entry: Dictionary = _pending[i]
		var dist: int = entry.dist
		var is_critical := dist <= collision_distance

		if not is_critical and far_spawned >= max_far_chunks_per_frame:
			i += 1
			continue

		_pending.remove_at(i)
		var coord: Vector2i = entry.coord
		if _active_chunks.has(coord):
			continue

		var lod := 0 if dist <= render_distance else 1
		var chunk := _get_from_pool_or_create()
		chunk.reset_for(coord.x, coord.y, lod, is_critical, is_critical)
		_active_chunks[coord] = chunk

		if not is_critical:
			far_spawned += 1
		# no incrementamos i: removimos el elemento actual, el siguiente
		# ya está en este índice


func _get_from_pool_or_create() -> TerrainChunk:
	if not _pool.is_empty():
		return _pool.pop_back()
	var chunk := TerrainChunk.new()
	add_child(chunk)
	return chunk
