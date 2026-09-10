@tool
extends StaticBody3D
## Turret — стационарная турель: «неподвижный танк» с урезанным функционалом. Отдельный префаб
## (`scenes/turret/Turret.tscn`), ставится инстансом прямо в .tscn любой карты за одну из сторон
## (`@export team`), в любом режиме — своей системной обвязки/спавнера не требует, как `Obstacle`.
##
## Этот корневой скрипт держит только «оболочку»: команду + подкраску цветом команды + проводку
## HealthComponent + заморозку на конце раунда + регистрацию в группе "turrets" (её читает
## `TankAIController._notify_team_of_alert_target()` для шаринга цели по ALERT). Вся боевая логика
## (3 стейта SEARCH/ATTACK/RELOAD, скан цели, баллистика, обойма/перезарядка) — в дочернем
## `TurretAI` (`turret_ai.gd`). Поворот башни/наклон дула переиспользуют те же компоненты, что и
## танк: `turret_controller.gd` на `TurretPivot`, `barrel_controller.gd` на `Barrel`
## (оба с is_player_controlled=false — внешний код пишет target_yaw/target_pitch).
##
## Уничтожается как объект: HealthComponent.free_on_destroy=true (узел исчезает с карты),
## max_hits=10 — 10 обычных снарядов танка (Projectile.damage=1) ИЛИ один выстрел мортиры
## (GameConfig.mortar_objective_damage=20 ≥ 10). Респауна нет.
##
## @tool — куб корпуса/цвет синхронизируются в редакторе (как у `Obstacle`).

## Значения совпадают с tank.gd Team: NPC (2) — третья сторона, враждебная обеим командам
## (турель на крыше objective-цели, scenes/objective_target/).
enum Team { ATTACK, DEFENSE, NPC }

## Сторона турели. Турель стреляет по танкам ЛЮБОЙ чужой стороны (сравнение `team` на равенство,
## turret_ai.gd); иммунитет своей цели к её снарядам — `HealthComponent.immune_team` цели.
@export var team: Team = Team.DEFENSE:
	set(value):
		team = value
		_apply_team_visuals()

## Габариты корпуса-куба (BoxShape3D + BoxMesh синхронно, как `Obstacle.size`).
@export var body_size: Vector3 = Vector3(1.6, 1.4, 1.6):
	set(value):
		body_size = value
		_apply_body_size()

## Высота debug-лейбла "HP N/M" над турелью (только MatchState.debug_enabled).
const _HP_LABEL_Y := 3.0

var _team_material: StandardMaterial3D
var _hp_label: Label3D
var _round_end_hooked := false

@onready var _health: Node = get_node_or_null("HealthComponent")
@onready var _body_shape: CollisionShape3D = get_node_or_null("CollisionShape3D")
@onready var _body_mesh: MeshInstance3D = get_node_or_null("BaseMesh")

func _ready() -> void:
	_apply_body_size()
	_apply_team_visuals()
	if Engine.is_editor_hint():
		return
	add_to_group("turrets")
	if _health != null:
		_health.destroyed.connect(_on_destroyed)
		_health.damaged.connect(_on_damaged)
	if MatchState.debug_enabled:
		_setup_hp_label()
	# MatchManager создаётся кодом в map_scene.gd._setup_match_context() — ПОСЛЕ _ready() детей.
	# call_deferred: к моменту idle-фазы узел "MatchManager" уже в дереве.
	_hook_round_end.call_deferred()

func is_attacker() -> bool:
	return team == Team.ATTACK

func is_npc() -> bool:
	return team == Team.NPC

## Куб корпуса → дочерние BoxShape3D/BoxMesh; локальный центр приподнят на полувысоту, чтобы
## origin узла лежал на нижней грани (инстанс ставится ровно на поверхность-опору).
func _apply_body_size() -> void:
	var shape: CollisionShape3D = _body_shape if _body_shape != null else get_node_or_null("CollisionShape3D")
	var mesh: MeshInstance3D = _body_mesh if _body_mesh != null else get_node_or_null("BaseMesh")
	if shape != null and shape.shape is BoxShape3D:
		shape.shape.size = body_size
		shape.position.y = body_size.y * 0.5
	if mesh != null and mesh.mesh is BoxMesh:
		mesh.mesh.size = body_size
		mesh.position.y = body_size.y * 0.5

## Единственная точка подкраски цветом команды — те же GameConfig-цвета и тот же приём (один
## переиспользуемый StandardMaterial3D как material_override), что tank.gd.apply_team_visuals().
func _apply_team_visuals() -> void:
	if _team_material == null:
		_team_material = StandardMaterial3D.new()
	# Не GameConfig.team_color(): скрипт @tool, а GameConfig — нет; в редакторе у не-tool автолоада
	# доступны только экспорт-поля (плейсхолдер), вызов метода там упал бы.
	match team:
		Team.DEFENSE: _team_material.albedo_color = GameConfig.team_defense_color
		Team.NPC: _team_material.albedo_color = GameConfig.team_npc_color
		_: _team_material.albedo_color = GameConfig.team_attack_color
	for path in ["BaseMesh", "TurretPivot/TurretMesh", "TurretPivot/Barrel/BarrelMesh"]:
		var mesh: MeshInstance3D = get_node_or_null(path)
		if mesh != null:
			mesh.material_override = _team_material

func _hook_round_end() -> void:
	if _round_end_hooked:
		return
	var mm: Node = get_tree().current_scene.get_node_or_null("MatchManager")
	if mm != null and mm.has_signal("round_ended"):
		mm.round_ended.connect(_on_round_ended)
		_round_end_hooked = true

## Конец раунда — «заморозка поля» (MVP, см. map_scene.gd._on_round_ended_teardown): турель
## перестаёт крутиться/стрелять до перезагрузки сцены.
func _on_round_ended(_winner: String) -> void:
	var ai: Node = get_node_or_null("TurretAI")
	if ai != null:
		ai.enabled = false

func _on_damaged(_current_hits: int, _max_hits: int, _killer: Node) -> void:
	_refresh_hp_label()

func _on_destroyed(_killer: Node) -> void:
	if _hp_label != null:
		_hp_label.text = "DEAD"

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
	_hp_label.position = Vector3(0.0, _HP_LABEL_Y, 0.0)
	add_child(_hp_label)
	_refresh_hp_label.call_deferred()

func _refresh_hp_label() -> void:
	if _hp_label == null or _health == null:
		return
	_hp_label.text = "HP %d/%d" % [max(0, _health.max_hits - _health.current_hits), _health.max_hits]
