extends SpringArm3D
## CameraRig — камера 3-го лица со свободной орбитой 360° мышью (ТЗ §4).
## Вращается независимо от корпуса и башни — не читает и не пишет их rotation.
## Активна (захват мыши + Camera3D.current) только на танке игрока (is_active=true).

@export var is_active: bool = true
@export var mouse_sensitivity: float = 0.005
@export var pitch_min_deg: float = -60.0
@export var pitch_max_deg: float = 10.0

@onready var _camera: Camera3D = $Camera3D

var _yaw: float = 0.0
var _pitch: float = 0.0

func _ready() -> void:
	_camera.current = is_active
	if is_active:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _unhandled_input(event: InputEvent) -> void:
	if not is_active:
		return
	if event is InputEventMouseMotion:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch = clamp(_pitch - event.relative.y * mouse_sensitivity, deg_to_rad(pitch_min_deg), deg_to_rad(pitch_max_deg))
		rotation.y = _yaw
		rotation.x = _pitch
