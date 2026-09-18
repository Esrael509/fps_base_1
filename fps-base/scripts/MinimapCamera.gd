extends Camera3D

@export var _target: Node3D
var _offset: Vector3

func _ready():
	if _target == null:
		printerr("No target for the minimap camera!")
		return
	
	_offset = global_position - _target.global_position

func _process(delta):
	if _target == null:
		return
		
	global_position = _target.global_position + _offset
