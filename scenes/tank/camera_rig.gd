extends SpringArm3D
## CameraRig — камера 3-го лица со свободной ПО МИРУ орбитой мышью.
## Поворот корпуса (turn_left/right) НЕ должен доворачивать камеру: локальный rotation.y
## пересчитывается каждый физ.кадр как (желаемый мировой yaw − текущий yaw корпуса), а не
## копится напрямую от мыши — поэтому вращение корпуса само по себе не меняет то, куда
## смотрит камера в мировых координатах.
## Активна (захват мыши + Camera3D.current) только на танке игрока (is_active=true).
## Мышь НЕ захватывается при headless/background-запуске через godot-runtime MCP (иначе
## агентские рантайм-тесты перехватывают физический курсор пользователя на рабочем столе —
## get_window().has_focus() этого не отличает, даже у offscreen-окна возвращает true, поэтому
## детектируем по наличию инжектированного автозагрузчика McpBridge). В обычном запуске —
## захват при фокусе окна, снятие по Escape, повторный захват по клику во вьюпорте.

@export var is_active: bool = true
@export var mouse_sensitivity: float = 0.005
@export var pitch_min_deg: float = -60.0
@export var pitch_max_deg: float = 35.0  # с запасом выше диапазона дула (+30°) — иначе барабан физически не достигнет верхнего предела
@export var reverse_camera_follow: bool = false  # GTA-style доворот камеры на заднем ходу — мешает прицеливанию, выключено
@export var reverse_follow_speed: float = 2.0  # рад/сек — скорость довода, если reverse_camera_follow=true

@onready var _camera: Camera3D = $Camera3D
@onready var _body: Node3D = get_parent()
@onready var _movement: Node = get_parent().get_node_or_null("TankMovement")

var _world_yaw: float = 0.0
var _pitch: float = 0.0
var _is_mcp_test_session: bool = false

func _ready() -> void:
	_camera.current = is_active
	_world_yaw = _body.rotation.y  # старт — смотрим туда же, куда корпус
	_is_mcp_test_session = get_tree().root.has_node("McpBridge")
	if not is_active:
		return
	var window := get_window()
	window.focus_entered.connect(_on_window_focus_entered)
	window.focus_exited.connect(_on_window_focus_exited)
	if window.has_focus():
		_try_capture_mouse()

func _try_capture_mouse() -> void:
	if _is_mcp_test_session:
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## Публичный переключатель для внешнего спектатор-режима (см. map_scene.gd — камеры 1/2/3) —
## делает то же, что произошло бы естественно при фокусе окна/потере фокуса, но по явной команде,
## а не по событию окна.
func activate() -> void:
	is_active = true
	_camera.current = true
	if get_window().has_focus():
		_try_capture_mouse()

func deactivate() -> void:
	is_active = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _on_window_focus_entered() -> void:
	_try_capture_mouse()

func _on_window_focus_exited() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _unhandled_input(event: InputEvent) -> void:
	if not is_active:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	if event is InputEventMouseButton and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		_try_capture_mouse()
		return
	if event is InputEventMouseMotion:
		_world_yaw -= event.relative.x * mouse_sensitivity
		_pitch = clamp(_pitch - event.relative.y * mouse_sensitivity, deg_to_rad(pitch_min_deg), deg_to_rad(pitch_max_deg))

func _physics_process(delta: float) -> void:
	if reverse_camera_follow and is_active and _movement != null and _movement.last_move_input < -0.1:
		var behind_yaw: float = _body.rotation.y + PI
		_world_yaw = lerp_angle(_world_yaw, behind_yaw, reverse_follow_speed * delta)
	rotation.y = wrapf(_world_yaw - _body.rotation.y, -PI, PI)
	rotation.x = _pitch
