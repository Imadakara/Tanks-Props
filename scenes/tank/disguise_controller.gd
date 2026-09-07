extends Node3D
## DisguiseController — маскировка танка под объект-препятствие карты (полное описание —
## Tank_Prop_Hunt_Disguise.md в vault).
##
## Активация: клавиша `toggle_disguise` (M, US-раскладка), ТОЛЬКО у игрока (is_player_controlled).
## Боты маскировку не активируют — механизм на них есть, точки входа нет (ТЗ: «активация пока
## доступна только игроку»). Активировать можно В ЛЮБОМ МЕСТЕ — привязки к размеченным на карте
## слотам больше нет (система DisguiseSlot удалена целиком). Переход разрешает
## TankStateMachine.request_disguise() (только из NORMAL).
##
## Объект имитации для MVP фиксирован в GameConfig (disguise_prop_size/_color) — коричневая коробка
## `Obstacle*`. Выбор объекта позже уедет в мета-гейм; этот компонент читает его из GameConfig, а
## не из узлов сцены.
##
## Визуал:
## - объект имитации (BoxMesh, непрозрачный) показывается всем;
## - у ЛОКАЛЬНОГО ИГРОКА (is_player_controlled) корпус/башня/ствол остаются видимыми, но с
##   рентген-материалом (полупрозрачный unshaded, no_depth_test) — «объект имитации с
##   просвечиваемым контуром танка внутри»;
## - у всех остальных (боты, спектатор-камеры) корпус и башня просто скрыты, как раньше.
## Прежний material_override мешей сохраняется и восстанавливается при снятии — покраска «подранка»
## (tank.gd._on_damaged) переживает цикл маскировки.
##
## Коллайдер объекта имитации в ФИЗИКЕ не участвует — движение/снаряды/касания остаются на
## собственном CharacterBody3D-коллайдере танка (маскировка только прячет меши). Но пока маскировка
## активна, на танк вешается Area3D `DisguiseObstacle` размером объекта имитации на слое
## `disguise_obstacle` (слой 4, бит-значение 8), НЕ сталкивающаяся ни с чем (`collision_mask = 0`):
## её видят только лучи объезда препятствий бота (`TankAIController._cast_ray_dist()` кастует по
## environment|tanks|disguise_obstacle + `collide_with_areas`). Итог: gap-scan-обход бота огибает
## ПОЛНЫЙ габарит коробки, а не корпус танка. Аварийный тормоз и физический контакт бота по-прежнему
## завязаны на РЕАЛЬНЫЙ корпус (слой tanks) — поэтому бот, у которого замаскированный танк стоит
## прямо на уже построенном маршруте, доезжает до корпуса, ловит контакт (collision_detector.gd) и
## маскировка спадает → бот агрится. Пересчёта навмеш-A*-маршрута по замаскированному танку нет (как
## и по любому другому танку — навмеш в этом проекте статический).
##
## AABB объекта имитации служит также триггером правила сброса (см. ниже).
##
## Условия досрочного снятия. Реализованы В ДРУГИХ компонентах: поворот башни — turret_controller.gd,
## движение — tank_movement.gd, выстрел — tank_state_machine.gd, касание движущимся танком —
## collision_detector.gd. ЗДЕСЬ:
## - прямое попадание снаряда — подписка на HealthComponent.damaged (прострел «обманки» сбрасывает
##   маскировку, но стоит противнику выстрела; при invincible=true урона нет — нет и сигнала,
##   маскировка держится);
## - два правила относительно ПРОТИВНИКА, режим выбирается один раз при активации по размеру
##   объекта имитации против коллайдера корпуса (HULL_HALF_EXTENTS):
## - объект имитации МЕНЬШЕ танка хотя бы по одной оси → сброс при приближении врага к коллайдеру
##   танка ближе GameConfig.disguise_enemy_proximity_break_dist;
## - объект имитации БОЛЬШЕ танка по всем осям → сброс, когда вражеский танк въезжает в объём
##   объекта имитации.
## Для дефолтного объекта имитации (2×1.25×2 > 1.2×0.6×1.8) активно второе правило, первое спит.

signal disguise_started()
signal disguise_ended()

const TankStateMachineScript := preload("res://scenes/tank/tank_state_machine.gd")

## Полугабариты коллайдера корпуса — из Tank.tscn. Сам коллайдер там ConvexPolygonShape3D (коробка
## 1.2 × 0.6 × 1.8 со срезанными фаской нижними рёбрами носа и кормы, см. Tank_Prop_Hunt_Tank_Chassis.md
## §4.1); здесь нужны именно ГАБАРИТНЫЕ полуразмеры, а фаска на них не влияет — правила сброса
## маскировки считаются по AABB, а не по точной форме. Центр коллайдера смещён на +0.3 по Y
## относительно начала танка (см. Tank.tscn/CollisionShape3D).
const HULL_HALF_EXTENTS := Vector3(0.6, 0.3, 0.9)
const HULL_CENTER_OFFSET := Vector3(0.0, 0.3, 0.0)

@export var is_player_controlled: bool = true

var _prop_mesh: MeshInstance3D
## Area3D размером объекта имитации на слое `disguise_obstacle` (4) — видна только лучам объезда
## бота, ни с чем не сталкивается. Форма выключена (`disabled`), пока маскировка не активна.
var _obstacle_area: Area3D
var _obstacle_shape: CollisionShape3D
var _ghost_material: StandardMaterial3D
## Полугабариты объекта имитации (GameConfig.disguise_prop_size * 0.5), кэш на активацию.
var _prop_half: Vector3 = Vector3.ZERO
## true — активно правило «приближение врага»; false — «враг въехал в объём». Выбирается в
## _compute_break_mode() при каждой активации.
var _proximity_mode: bool = false
## Прежние material_override рентгенленных мешей — восстановить при снятии (сохраняет покраску
## подранка). Ключ — MeshInstance3D, значение — Material или null.
var _saved_overrides: Dictionary = {}

@onready var _body: CharacterBody3D = get_parent()
## Корпус — весь пивот `Hull` целиком (броня + гусеницы + катки, всё строится кодом в hull_rig.gd),
## а не один меш: перечислять узлы поимённо больше нечего, а спрятать надо всю ходовую разом,
## иначе из-под коробки маскировки торчали бы крутящиеся гусеницы.
@onready var _hull: Node3D = get_parent().get_node("Hull")
@onready var _turret: Node3D = get_parent().get_node("Turret")
@onready var _state_machine: Node = get_parent().get_node("TankStateMachine")
@onready var _health: Node = get_parent().get_node("HealthComponent")

func _ready() -> void:
	_state_machine.state_changed.connect(_on_state_changed)
	_health.damaged.connect(_on_health_damaged)

## Прямое попадание снаряда по замаскированному танку — маскировка спадает (прострел «обманки»).
## Сигнатура — ровно 3 параметра, как эмитит HealthComponent.damaged (Godot не отбрасывает лишние).
## Урон, гашённый invincible, сюда не долетает (take_hit() выходит до damaged.emit) — осознанно:
## неуязвимый танк снаряд не замечает вовсе.
func _on_health_damaged(_current_hits: int, _max_hits: int, _killer: Node) -> void:
	if _state_machine.state == TankStateMachineScript.State.DISGUISED:
		_state_machine.break_disguise("projectile_hit")

func _unhandled_input(event: InputEvent) -> void:
	if not is_player_controlled:
		return
	if not GameConfig.disguise_player_enabled:
		return
	if event.is_action_pressed("toggle_disguise"):
		try_enter_disguise()

## Цвет объекта имитации: в debug-режиме — контрастный фиолетовый (отличать замаскированный танк
## от статичного Obstacle), иначе — штатный GameConfig.disguise_prop_color.
func _prop_albedo() -> Color:
	return GameConfig.disguise_debug_prop_color if MatchState.debug_enabled else GameConfig.disguise_prop_color

## Публичный вход. Игрок — из _unhandled_input; тест/будущий код — напрямую. Точки входа для ботов
## сознательно нет.
func try_enter_disguise() -> bool:
	if not _state_machine.request_disguise():
		return false
	_build_prop_if_needed()
	_compute_break_mode()
	_show_disguise()
	disguise_started.emit()
	return true

## Проверка правил сброса относительно противника — только пока маскировка активна. У ботов состояние
## DISGUISED не наступает вовсе (они не активируют маскировку), поэтому для них это ранний выход.
func _physics_process(_delta: float) -> void:
	if _state_machine.state != TankStateMachineScript.State.DISGUISED:
		return
	for other in get_tree().get_nodes_in_group("tanks"):
		if other == _body or not is_instance_valid(other):
			continue
		if other.team == _body.team:
			continue
		if not other.visible:
			continue  # труп на респавне
		var other_health: Node = other.get_node_or_null("HealthComponent")
		if other_health != null and not other_health.is_alive:
			continue
		if _enemy_triggers_break(other):
			_state_machine.break_disguise("enemy_proximity" if _proximity_mode else "enemy_entered_prop")
			return

## Режим правила сброса: «приближение», если объект имитации меньше коллайдера корпуса хотя бы по
## одной оси; иначе «въезд в объём». Считается один раз при активации.
func _compute_break_mode() -> void:
	_prop_half = GameConfig.disguise_prop_size * 0.5
	_proximity_mode = (
		_prop_half.x < HULL_HALF_EXTENTS.x
		or _prop_half.y < HULL_HALF_EXTENTS.y
		or _prop_half.z < HULL_HALF_EXTENTS.z
	)

## true — этот вражеский танк сейчас нарушает активное правило сброса.
func _enemy_triggers_break(other: Node3D) -> bool:
	var enemy_center: Vector3 = other.global_position + HULL_CENTER_OFFSET
	if _proximity_mode:
		# Дистанция от точки-центра врага до AABB коллайдера ЭТОГО танка (см. ТЗ: «для расчётов
		# используем коллайдер замаскированного танка»).
		var my_center: Vector3 = _body.global_position + HULL_CENTER_OFFSET
		var d: Vector3 = (other.global_position - my_center).abs() - HULL_HALF_EXTENTS
		var outside := Vector3(maxf(d.x, 0.0), maxf(d.y, 0.0), maxf(d.z, 0.0))
		return outside.length() <= GameConfig.disguise_enemy_proximity_break_dist
	# «Въезд в объём»: AABB корпуса врага пересекается с AABB объекта имитации (центр объекта имитации
	# приподнят на его полувысоту — стоит на земле, как настоящий Obstacle).
	var prop_center: Vector3 = _body.global_position + Vector3(0.0, _prop_half.y, 0.0)
	var delta: Vector3 = (enemy_center - prop_center).abs()
	var reach: Vector3 = HULL_HALF_EXTENTS + _prop_half
	return delta.x <= reach.x and delta.y <= reach.y and delta.z <= reach.z

func _build_prop_if_needed() -> void:
	var size: Vector3 = GameConfig.disguise_prop_size
	if _prop_mesh != null:
		# Объект имитации может смениться в мета-гейме между активациями — обновляем размер/цвет
		# (цвет ещё и от debug-режима, см. _prop_albedo()).
		(_prop_mesh.mesh as BoxMesh).size = size
		_prop_mesh.position.y = size.y * 0.5
		(_prop_mesh.material_override as StandardMaterial3D).albedo_color = _prop_albedo()
		(_obstacle_shape.shape as BoxShape3D).size = size
		_obstacle_area.position.y = size.y * 0.5
		return
	var box := BoxMesh.new()
	box.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _prop_albedo()
	_prop_mesh = MeshInstance3D.new()
	_prop_mesh.name = "DisguiseProp"
	_prop_mesh.mesh = box
	_prop_mesh.material_override = mat
	_prop_mesh.position.y = size.y * 0.5
	_prop_mesh.visible = false
	add_child(_prop_mesh)

	# Препятствие-габарит для лучей объезда бота (см. заголовок файла). Слой `disguise_obstacle` (4),
	# ни с чем не сталкивается; форма выключена, пока маскировка не активна.
	var shape := BoxShape3D.new()
	shape.size = size
	_obstacle_shape = CollisionShape3D.new()
	_obstacle_shape.name = "Shape"
	_obstacle_shape.shape = shape
	_obstacle_shape.disabled = true
	_obstacle_area = Area3D.new()
	_obstacle_area.name = "DisguiseObstacle"
	_obstacle_area.collision_layer = 1 << 3  # слой 4
	_obstacle_area.collision_mask = 0
	_obstacle_area.monitoring = false
	_obstacle_area.position.y = size.y * 0.5
	_obstacle_area.add_child(_obstacle_shape)
	add_child(_obstacle_area)

func _ghost_mat() -> StandardMaterial3D:
	if _ghost_material == null:
		_ghost_material = StandardMaterial3D.new()
		_ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ghost_material.albedo_color = Color(0.6, 0.85, 1.0, 0.25)
		_ghost_material.no_depth_test = true  # силуэт читается СКВОЗЬ коробку
		_ghost_material.render_priority = 1
	return _ghost_material

func _on_state_changed(old_state, new_state) -> void:
	if old_state == TankStateMachineScript.State.DISGUISED and new_state != TankStateMachineScript.State.DISGUISED:
		_hide_disguise()
		disguise_ended.emit()

func _show_disguise() -> void:
	_prop_mesh.visible = true
	_obstacle_shape.disabled = false
	if is_player_controlled:
		# Рентген-силуэт: меши остаются видимыми, но с полупрозрачным материалом поверх коробки.
		for mesh in _ghost_targets():
			_saved_overrides[mesh] = mesh.material_override
			mesh.material_override = _ghost_mat()
	else:
		_hull.visible = false
		_turret.visible = false

func _hide_disguise() -> void:
	if _prop_mesh != null:
		_prop_mesh.visible = false
	if _obstacle_shape != null:
		_obstacle_shape.disabled = true
	_hull.visible = true
	_turret.visible = true
	for mesh in _saved_overrides:
		if is_instance_valid(mesh):
			mesh.material_override = _saved_overrides[mesh]
	_saved_overrides.clear()

## Всё, что рентгенится у локального игрока: визуал корпуса (его отдаёт сам hull_rig.gd — состав
## поддерева знает только он) плюс поддерево башни со стволом и навесной модификацией.
func _ghost_targets() -> Array:
	var targets: Array = _hull.visual_meshes()
	_collect_visuals(_turret, targets)
	return targets

func _collect_visuals(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is GeometryInstance3D:
			out.append(child)
		_collect_visuals(child, out)
