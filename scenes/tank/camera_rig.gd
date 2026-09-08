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
@export var pitch_max_deg: float = 25.0  # с запасом выше предела возвышения дула (+20°, barrel_controller.gd) — иначе дуло физически не достаёт до верхней границы

## ПОДЪЁМ КАМЕРЫ НА ЗАДРАННОМ ПРИЦЕЛЕ. Пивот стоит на корне танка и поворачивается по питчу целиком,
## поэтому камера, висящая на конце штанги, при взгляде ВВЕРХ уезжает вниз-назад (Basis(X,θ) уводит
## точку (0,0,L) в y = −L·sinθ) — и собственный корпус закрывает весь верх кадра, ровно там, куда
## целишься. Лечится не «отодвинуть камеру», а связкой двух величин с текущим питчем: пивот
## поднимается, штанга укорачивается. На верхней границе прицела камера выходит чуть выше макушки
## башни и близко к ней; при взгляде вперёд/вниз всё возвращается к обычному виду от третьего лица.
## Интерполяция по smoothstep, а не линейная — иначе подъём чувствуется рывком в начале хода мыши.
@export var pivot_height: float = 2.0  # высота пивота над танком при взгляде вперёд
@export var pivot_height_top: float = 3.0  # ...и на верхней границе питча
@export var spring_length_base: float = 6.0  # длина штанги при взгляде вперёд
@export var spring_length_top: float = 3.2  # ...и на верхней границе питча
@export var reverse_camera_follow: bool = false  # GTA-style доворот камеры на заднем ходу — мешает прицеливанию, выключено
@export var reverse_follow_speed: float = 2.0  # рад/сек — скорость довода, если reverse_camera_follow=true

@onready var _camera: Camera3D = $Camera3D
@onready var _body: Node3D = get_parent()
@onready var _movement: Node = get_parent().get_node_or_null("TankMovement")

var _world_yaw: float = 0.0
var _pitch: float = 0.0
var _is_mcp_test_session: bool = false
## Кувырок (TumbleController.set_tumble_follow): корень танка кувыркается, его rotation.y — мусор.
## Камера НЕ меняет поведение — это та же свободная орбита мышью (_world_yaw/_pitch), просто
## построенная в ВИРТУАЛЬНОМ ВЕРТИКАЛЬНОМ кадре в позиции танка, а не от кренящегося корня.
## Танк при этом свободно кувыркается по всем осям, камера остаётся ровной и управляемой.
var _tumble_follow: bool = false

func set_tumble_follow(on: bool) -> void:
	_tumble_follow = on

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
	# Во время кувырка корень кувыркается (его rotation.y — мусор). Камера — GTA-стиль: свободная
	# орбита мышью (_world_yaw/_pitch) вокруг ПОЗИЦИИ танка в вертикальном кадре; сам танк
	# вращается свободно по всем осям, камера этого не повторяет.
	if _tumble_follow:
		var t: float = smoothstep(0.0, 1.0, clampf(_pitch / maxf(deg_to_rad(pitch_max_deg), 0.001), 0.0, 1.0))
		var pivot: Vector3 = _body.global_position + Vector3(0.0, lerpf(pivot_height, pivot_height_top, t), 0.0)
		var basis: Basis = Basis(Vector3.UP, _world_yaw) * Basis(Vector3.RIGHT, _pitch)
		global_transform = Transform3D(basis, pivot)
		spring_length = lerpf(spring_length_base, spring_length_top, t)
		return
	if reverse_camera_follow and is_active and _movement != null and _movement.last_move_input < -0.1:
		var behind_yaw: float = _body.rotation.y + PI
		_world_yaw = lerp_angle(_world_yaw, behind_yaw, reverse_follow_speed * delta)
	rotation.y = wrapf(_world_yaw - _body.rotation.y, -PI, PI)
	rotation.x = _pitch
	_apply_pitch_framing()

## Доля хода прицела вверх: 0 — смотрим вперёд или вниз, 1 — упёрлись в верхнюю границу.
## Отрицательный питч (взгляд вниз) камеру не трогает: там корпус обзор и не закрывает.
func _apply_pitch_framing() -> void:
	var top: float = deg_to_rad(pitch_max_deg)
	if top <= 0.0:
		return
	var t: float = smoothstep(0.0, 1.0, clampf(_pitch / top, 0.0, 1.0))
	position.y = lerpf(pivot_height, pivot_height_top, t)
	spring_length = lerpf(spring_length_base, spring_length_top, t)
