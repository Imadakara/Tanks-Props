extends CharacterBody3D
## Tank — корневой узел танка: команда + визуал команды/HP. Остальная логика — в дочерних
## компонентах (TankStateMachine, TankMovement, ...), это НЕ god-object.
##
## - «Подкраска танка цветом команды» (apply_team_visuals()): меши корпуса/башни/ствола красятся
##   в GameConfig.team_attack_color / team_defense_color по tank.team. Вызывается team_spawner.gd
##   сразу после присвоения team и respawn_controller.gd на возврате в игру. Обход — рекурсивный
##   по поддереву `Hull` (башня со стволом теперь тоже его потомки), а не по списку путей: броня
##   корпуса и ходовая строятся КОДОМ в hull_rig.gd, фиксированного списка узлов там нет. Ходовая
##   (гусеницы/катки) из покраски исключена по префиксу имени, см. _DARK_PART_PREFIXES.
## - Индикация HP — Label3D над танком, ТОЛЬКО в debug-режиме (MatchState.debug_enabled). Раньше
##   при нефинальном попадании корпус+башня перекрашивались в красный — заменено на цифры HP,
##   чтобы не конфликтовать с цветом команды.
## Уничтожение танка не удаляет узел — HealthComponent.free_on_destroy=false, респаун ведёт
## RespawnController (см. respawn_controller.gd).

## NPC — третья сторона, враждебная обеим командам: танк-охранник objective-цели
## (scenes/objective_target/, NpcTank.tscn). Все проверки «свой/чужой» в проекте — сравнение
## `team` на равенство, поэтому NPC чужой для обеих команд без спец-кода; а `is_attacker()` у него
## false — в логике «атака/оборона» он ведёт себя как ЗАЩИТНИК своей цели (ALERT/патруль).
enum Team { ATTACK, DEFENSE, NPC }

@export var team: Team = Team.ATTACK

## Высота Label3D с HP над центром корпуса (корпус ~0.6, башня ~0.9 — 2.3 гарантированно сверху).
const _HP_LABEL_Y := 2.3

var _team_material: StandardMaterial3D
var _hp_label: Label3D

@onready var _health: Node = get_node_or_null("HealthComponent")
## Игровой класс танка (chassis.gd). Узел есть в базовом Tank.tscn, значит и у каждого наследника.
@onready var _chassis: Node = get_node_or_null("Chassis")

func _ready() -> void:
	add_to_group("tanks")
	# Класс применяется ЗДЕСЬ, а не в _ready() самого Chassis: корень готов последним, когда каждый
	# компонент уже прочитал свои дефолты из GameConfig, — класс их перезаписывает. До покраски и
	# HP-метки: их высота/цвет не зависят от класса, но пусть корпус уже будет нужного размера.
	if _chassis != null:
		_chassis.apply()
	if _health != null:
		_health.damaged.connect(_on_damaged)
		_health.destroyed.connect(_on_destroyed)
		_health.healed.connect(_on_healed)
	apply_team_visuals()
	if MatchState.debug_enabled:
		_setup_hp_label()

func is_attacker() -> bool:
	return team == Team.ATTACK

func is_npc() -> bool:
	return team == Team.NPC

## Идентификатор и имя класса (для HUD, лобби, отладки). Без Chassis — средний.
func chassis_id() -> StringName:
	return _chassis.chassis_id if _chassis != null else &"medium"

func chassis_name() -> String:
	return _chassis.display_name if _chassis != null else "Средний"

func chassis_scale() -> float:
	return _chassis.size_scale if _chassis != null else 1.0

## Что НЕ красится в цвет команды, а остаётся своим «железным» цветом из hull_rig.gd: ходовая
## (гусеницы `Track*`, катки `Wheel*`) — она должна читаться как механика на танке любой команды.
## `Mortar*` — навесная модификация на стволе (mortar_behavior.gd), её красный цвет несёт смысл
## «в слоте мортира»; без исключения респавн/перекраска затирали бы его цветом команды.
const _DARK_PART_PREFIXES := ["Track", "Wheel", "Mortar"]

## Единственная точка «подкраски танка цветом команды». Ставит material_override на все визуальные
## узлы поддеревьев `Hull` и `Turret`, кроме ходовой (см. _DARK_PART_PREFIXES). Идемпотентна —
## переиспользует один StandardMaterial3D, только меняет albedo. team_spawner.gd зовёт её после
## team = ... (и для игрока, и для ботов), respawn — на возврате в игру (на случай, если что-то
## оставило свой override за прошлую жизнь).
func apply_team_visuals() -> void:
	if _team_material == null:
		_team_material = StandardMaterial3D.new()
	_team_material.albedo_color = GameConfig.team_color(team)
	# Одного обхода `Hull` хватает на весь танк: башня со стволом — тоже его потомки
	# (`Hull/Turret`, она кренится вместе с корпусом, см. hull_rig.gd).
	var hull: Node = get_node_or_null("Hull")
	if hull != null:
		_tint_subtree(hull)

## GeometryInstance3D, а не MeshInstance3D: гусеница — MultiMeshInstance3D (она в исключениях, но
## проверка типа должна её видеть, иначе фильтр по имени просто не сработает).
func _tint_subtree(node: Node) -> void:
	for child in node.get_children():
		if child is GeometryInstance3D and not _is_dark_part(child.name):
			(child as GeometryInstance3D).material_override = _team_material
		_tint_subtree(child)

func _is_dark_part(node_name: String) -> bool:
	for prefix in _DARK_PART_PREFIXES:
		if node_name.begins_with(prefix):
			return true
	return false

## Вызывается RespawnController при возврате танка в игру — сбрасывает индикатор HP на полный и
## заново применяет цвет команды.
func on_respawned() -> void:
	apply_team_visuals()
	_refresh_hp_label()

func _on_damaged(_current_hits: int, _max_hits: int, _killer: Node) -> void:
	_refresh_hp_label()

func _on_healed(_current_hits: int, _max_hits: int) -> void:
	_refresh_hp_label()

func _on_destroyed(_killer: Node) -> void:
	if _hp_label != null:
		_hp_label.text = "DEAD"

## Label3D — billboard, всегда лицом к камере; дочерний узел корня танка, скрывается/показывается
## вместе с ним на смерти/респавне (RespawnController прячет весь танк).
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
	_hp_label.position = Vector3(0.0, _HP_LABEL_Y * chassis_scale(), 0.0)
	add_child(_hp_label)
	# call_deferred — страховка: max_hits выставляет класс (chassis.gd) в этом же _ready() выше, но
	# любой, кто поправит здоровье сразу после add_child(), будет учтён — читаем на кадр позже.
	_refresh_hp_label.call_deferred()

func _refresh_hp_label() -> void:
	if _hp_label == null or _health == null:
		return
	_hp_label.text = "HP %d/%d" % [max(0, _health.max_hits - _health.current_hits), _health.max_hits]
