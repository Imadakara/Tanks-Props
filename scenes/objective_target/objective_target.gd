@tool
extends Node3D
## ObjectiveTarget — objective-цель NPC-стороны: отдельный префаб (`ObjectiveTarget.tscn`), ставится
## инстансом в `.tscn` любой карты (сейчас — KitchenMap, режим EXTRACTION), без спавнера и без
## правок кода карты. Origin узла кладётся РОВНО на поверхность-опору (пол, плита, стол).
##
## Состав префаба:
##   Core          — сама цель: `StaticBody3D` (слой 1 — навмеш вырезает её след) с HealthComponent-
##                   пулом HP; снаряды NPC-стороны её не ранят (`immune_team`).
##   Turret        — инстанс `Turret.tscn` на крыше Core, сторона NPC: стреляет по танкам ОБЕИХ команд.
##   NpcAlertZone  — круг тревоги (spawn_zone.gd): враг внутри или недавнее попадание по Core ⇒
##                   охранник в ALERT прочёсывает круг. Логика та же, что у защитников в
##                   TARGET_OBJECTIVE (ObjectiveAlertState), только «враг» — любая команда.
##   NpcPatrol1..4 — 4 точки патруля охранника вокруг цели (ромб на `patrol_radius`); они же — круги
##                   его респавна (случайная точка из четырёх).
## Охранник — NPC-танк (`guard_scene`, по умолчанию NpcTank.tscn — копия среднего) спавнится кодом:
## `map_scene.gd._spawn_objective_guards()` → `spawn_guard()` → `TeamSpawner.spawn_npc_guard()`, затем
## `TankAIController.bind_npc_guard()` отдаёт ему маршрут/круг/цель. Возрождается у своей цели, пока
## она жива; после разрушения цели не возрождается, а выживший остаётся на карте обычным врагом.
##
## Разрушение Core ⇒ дроп через `ExtractionManager.spawn_node_drop()` (тот же путь, что у куба-узла:
## опора лучом вниз, проекция на ближайший навмеш), но БЕЗ ролла — что выпадет, задано здесь
## (`drop_kind` / `loot_rarity` / `loot_value`). Затем префаб удаляется целиком (турель вместе с ним).
##
## Внутренние узлы НАМЕРЕННО не называются "Objective" / "ObjectiveAlertZone" и Core не входит в
## группу "objective_health": это имена/группа командной objective (TARGET_OBJECTIVE) — боты команд и
## map_scene.gd искали бы их глобально и приняли бы NPC-цель за свою. Боты команд с NPC-целью не
## воюют специально — только встречный бой с охранником/турелью.
##
## @tool — габариты куба, позиция турели, круги и ромб патруля видны и правятся в редакторе.

const ObjectiveAlertStateScript := preload("res://scenes/main/objective_alert_state.gd")
## tank.gd / turret.gd Team.NPC.
const NPC_TEAM := 2

@export_group("Цель")
## Габариты куба цели. Низ куба — на origin префаба, турель — на его крыше.
@export var core_size: Vector3 = Vector3(2.0, 2.0, 2.0):
	set(value):
		core_size = value
		_apply_layout()
@export var core_color: Color = Color(0.25, 0.28, 0.35):
	set(value):
		core_color = value
		_apply_layout()
## HP цели. 0 — общий баланс `GameConfig.objective_hits_required`.
@export var core_max_hits: int = 0

@export_group("Турель")
@export var turret_enabled: bool = true
@export_enum("EASY", "MEDIUM", "HARD") var turret_difficulty: int = 1

@export_group("Охранник")
@export var guard_enabled: bool = true
## Сцена танка-охранника. Должна быть танком NPC-стороны (team = 2) — по умолчанию NpcTank.tscn.
@export var guard_scene: PackedScene = preload("res://scenes/tank/NpcTank.tscn")
@export_enum("EASY", "MEDIUM", "HARD") var guard_difficulty: int = 1
## Проверка обрыва по курсу у бота (свойство карты: на многоуровневой нужна, на плоской — лишняя).
@export var guard_ledge_check_enabled: bool = true
## Панель BOT BRAIN охранника в debug-режиме. Выкл по умолчанию: панели ботов стоят в слотах экрана
## (`debug_ui_slot`), и охранник занял бы слот командного бота поверх его панели.
@export var guard_show_brain_debug: bool = false

@export_group("Зона")
## Радиус круга тревоги вокруг цели.
@export var alert_radius: float = 11.0:
	set(value):
		alert_radius = value
		_apply_layout()
## Расстояние от центра цели до каждой из 4 точек патруля (ромб по осям X/Z префаба).
@export var patrol_radius: float = 7.0:
	set(value):
		patrol_radius = value
		_apply_layout()
## Радиус каждой точки патруля (в нём бот выбирает случайную точку, в нём же возрождается).
@export var patrol_point_radius: float = 3.0:
	set(value):
		patrol_point_radius = value
		_apply_layout()
## Допуск по высоте для «врага в круге»: на многоуровневой карте танк на ярусе прямо над/под кругом
## (стол над целью под столом) в круге не считается.
@export var alert_height_tolerance: float = 4.0

@export_group("Лут")
## Что выпадет при разрушении — индекс `ExtractionManager.FarmDrop`, тот же набор, что у куба-узла.
@export_enum("Лут", "Ничего", "Патроны", "Мортира", "Аптечка", "Щит") var drop_kind: int = 0
## Ярус лута (при drop_kind = Лут): 0..3 по `rarity_tiers` конфига карты; 2 — эпический.
@export_range(0, 3) var loot_rarity: int = 2
## Ценность ящика. 0 — верх диапазона выбранного яруса (`rarity_tiers[i].raw_max`).
@export var loot_value: int = 0

## Высота debug-лейбла "Цель HP N/M" над крышей куба (лейбл турели — выше, на её собственной высоте).
const _HP_LABEL_ABOVE := 1.0

var _alert: RefCounted = ObjectiveAlertStateScript.new()
var _guard: Node = null
var _destroyed: bool = false
var _hp_label: Label3D

@onready var _core: StaticBody3D = get_node_or_null("Core")
@onready var _core_health: Node = get_node_or_null("Core/HealthComponent")
@onready var _turret: Node3D = get_node_or_null("Turret")
@onready var _alert_zone: Node3D = get_node_or_null("NpcAlertZone")

func _ready() -> void:
	_apply_layout()
	if Engine.is_editor_hint():
		return
	add_to_group("objective_targets")
	if _core_health != null:
		_core_health.max_hits = core_max_hits if core_max_hits > 0 else GameConfig.objective_hits_required
		_core_health.attackers_only = false
		_core_health.free_on_destroy = false  # префаб удаляем сами — после дропа и отвязки охранника
		_core_health.immune_team = NPC_TEAM
		_core_health.damaged.connect(_on_core_damaged)
		_core_health.destroyed.connect(_on_core_destroyed)
	if _turret != null:
		_turret.team = NPC_TEAM
		var th: Node = _turret.get_node_or_null("HealthComponent")
		if th != null:
			th.immune_team = NPC_TEAM
		var tai: Node = _turret.get_node_or_null("TurretAI")
		if tai != null:
			tai.enabled = turret_enabled
			tai.difficulty = turret_difficulty
	if MatchState.debug_enabled:
		_setup_hp_label()

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_alert.tick(delta)

# --- Контракт «арены» для охранника (TankAIController._arena) ------------------------------------

func time_since_objective_hit() -> float:
	return _alert.time_since_hit()

func enemy_in_alert_zone() -> bool:
	return _alert.enemy_in_zone(_alert_zone, get_tree(), NPC_TEAM, alert_height_tolerance)

# --- Охранник -------------------------------------------------------------------------------------

## Зовёт map_scene.gd из корневого _ready() после TeamSpawner.spawn_team() (add_child на
## current_scene из _ready() самой цели упал бы — дерево ещё строится).
func spawn_guard(spawner: Node) -> void:
	if not guard_enabled or guard_scene == null or spawner == null or _destroyed:
		return
	var points: Array = _patrol_points()
	if points.is_empty():
		push_warning("ObjectiveTarget %s: нет точек патруля — охранник не заспавнен" % name)
		return
	var squad := {
		"role": "ACHIEVER",
		"difficulty": ["EASY", "MEDIUM", "HARD"][clampi(guard_difficulty, 0, 2)],
		"ledge_check_enabled": guard_ledge_check_enabled,
		"show_brain_debug": guard_show_brain_debug,
	}
	_guard = spawner.spawn_npc_guard(guard_scene, NPC_TEAM, "NpcGuard_%s" % name, points.pick_random(), squad)
	if _guard == null:
		return
	var brain: Node = _guard.get_node_or_null("TankAIController")
	if brain != null:
		brain.bind_npc_guard(self, points, _alert_zone, _core, _core_health)
	var rc: Node = _guard.get_node_or_null("RespawnController")
	if rc != null:
		rc.spawn_zone_override = points.pick_random()
	var gh: Node = _guard.get_node_or_null("HealthComponent")
	if gh != null:
		gh.destroyed.connect(_on_guard_destroyed)

## Охранник погиб — возродится у случайной из точек патруля (пока цель жива; иначе респавн уже снят).
func _on_guard_destroyed(_killer: Node) -> void:
	if _destroyed or not is_instance_valid(_guard):
		return
	var rc: Node = _guard.get_node_or_null("RespawnController")
	var points: Array = _patrol_points()
	if rc != null and not points.is_empty():
		rc.spawn_zone_override = points.pick_random()

func _patrol_points() -> Array:
	var points: Array = []
	for i in range(1, 5):
		var p: Node = get_node_or_null("NpcPatrol%d" % i)
		if p != null:
			points.append(p)
	return points

# --- Урон / разрушение ----------------------------------------------------------------------------

func _on_core_damaged(_current_hits: int, _max_hits: int, _killer: Node) -> void:
	_alert.reset()
	_refresh_hp_label()

func _on_core_destroyed(_killer: Node) -> void:
	if _destroyed:
		return
	_destroyed = true
	var mgr: Node = get_tree().get_first_node_in_group("extraction_manager")
	if mgr != null:
		if drop_kind == 0 and loot_value <= 0:
			loot_value = int(mgr.rarity_raw_max(loot_rarity))
		# Корень префаба — точка опоры; тело цели и турель на её крыше ещё живы — луч опоры их минует.
		mgr.spawn_node_drop(self, [_core, _turret])
	if is_instance_valid(_guard):
		var rc: Node = _guard.get_node_or_null("RespawnController")
		if rc != null:
			rc.disable_respawn()
		var brain: Node = _guard.get_node_or_null("TankAIController")
		if brain != null:
			brain.unbind_npc_guard()
	queue_free()

# --- Раскладка (редактор + рантайм) ---------------------------------------------------------------

func _apply_layout() -> void:
	if not is_inside_tree():
		return
	var shape: CollisionShape3D = get_node_or_null("Core/CollisionShape3D")
	if shape != null and shape.shape is BoxShape3D:
		shape.shape.size = core_size
	var mesh: MeshInstance3D = get_node_or_null("Core/Mesh")
	if mesh != null:
		if mesh.mesh is BoxMesh:
			mesh.mesh.size = core_size
		if mesh.material_override is StandardMaterial3D:
			mesh.material_override.albedo_color = core_color
	var core: Node3D = get_node_or_null("Core")
	if core != null:
		core.position = Vector3(0.0, core_size.y * 0.5, 0.0)
	var turret: Node3D = get_node_or_null("Turret")
	if turret != null:
		turret.position = Vector3(0.0, core_size.y, 0.0)
	var zone: Node3D = get_node_or_null("NpcAlertZone")
	if zone != null:
		zone.position = Vector3.ZERO
		zone.set("radius", alert_radius)
	var offsets := [Vector3(patrol_radius, 0, 0), Vector3(0, 0, patrol_radius),
			Vector3(-patrol_radius, 0, 0), Vector3(0, 0, -patrol_radius)]
	for i in range(4):
		var p: Node3D = get_node_or_null("NpcPatrol%d" % (i + 1))
		if p != null:
			p.position = offsets[i]
			p.set("radius", patrol_point_radius)

func _setup_hp_label() -> void:
	_hp_label = Label3D.new()
	_hp_label.name = "HpDebugLabel"
	_hp_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_hp_label.no_depth_test = true
	_hp_label.fixed_size = true
	_hp_label.pixel_size = 0.0007
	_hp_label.outline_size = 12
	_hp_label.modulate = Color(1, 1, 1)
	_hp_label.outline_modulate = Color(0, 0, 0)
	_hp_label.position = Vector3(0.0, core_size.y + _HP_LABEL_ABOVE, 0.0)
	add_child(_hp_label)
	_refresh_hp_label.call_deferred()

func _refresh_hp_label() -> void:
	if _hp_label == null or _core_health == null:
		return
	_hp_label.text = "Цель HP %d/%d" % [max(0, _core_health.max_hits - _core_health.current_hits), _core_health.max_hits]
