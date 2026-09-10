extends Area3D
## Pickup — УНИВЕРСАЛЬНЫЙ мгновенный бонус-ящик: цветной куб, подбирается контактом любого танка
## любой команды, применяет эффект своего типа и исчезает. Основа системы подбираемых бонусов:
## боеприпасы / аптечка / щит — один узел, разные типы.
##
## Тип задаётся строковым `kind_id` (&"ammo" / &"medkit" / &"shield"), а цвет и числа эффекта —
## из `config/pickups.json` (грузит `GameConfig`). .tres-ресурсов у типов больше нет: весь баланс
## drop-системы в JSON.
##
## Появляется двумя путями, оба зовут либо `fall_to()` (падение с неба из зоны сброса), либо
## `place_at()` (сразу на опоре — выпадение из разрушенного лут-узла в EXTRACTION).
##
## Красный ящик модификации — НЕ этот узел (`scenes/mod_crate/`): там подбор условный (пустой слот).
##
## Падение КИНЕМАТИЧЕСКОЕ (прямо вниз с фикс. скоростью) — тот же приём, что у ModCrate/Projectile.

## Полувысота коллизии/меша (BoxShape3D 0.6³) — центр встаёт на эту высоту над точкой земли.
const _REST_OFFSET: float = 0.3

## Тип бонуса: &"ammo" / &"medkit" / &"shield". Ставит создатель (зона сброса / ExtractionManager)
## сразу после instantiate(), до add_child.
@export var kind_id: StringName = &""

## Только для БОЕПРИПАСОВ из зоны сброса: перебивает `ammo_amount` из pickups.json значением зоны
## (`ammo_drop_zone.ammo_per_crate`). 0 — брать число из конфига. Аптечка / щит это поле игнорируют.
@export var amount_override: int = 0

var _cfg: Dictionary = {}
var _falling: bool = false
var _rest_y: float = 0.0
var _fall_speed: float = 18.0

func _ready() -> void:
	_cfg = GameConfig.pickup_kind(kind_id)
	# Все бонус-ящики — в общей группе "pickups". Патронный — ДОПОЛНИТЕЛЬНО в "ammo_crates":
	# бот-ИИ (AMMO_SEEK/RETRIEVE) ищет патроны по этой группе и про Pickup ничего знать не должен.
	add_to_group("pickups")
	if int(_cfg.get("ammo_amount", 0)) > 0:
		add_to_group("ammo_crates")
	body_entered.connect(_on_body_entered)
	_apply_visual()
	set_physics_process(false)  # включается только на время падения из fall_to()

## Цвет куба = цвет типа из конфига. Материал в Pickup.tscn помечен resource_local_to_scene —
## у каждого инстанса свой, перекраска одного не задевает остальные (как у LootCrate).
func _apply_visual() -> void:
	var mesh: MeshInstance3D = get_node_or_null("CrateMesh")
	if mesh == null:
		return
	var mat: StandardMaterial3D = mesh.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = _cfg.get("color", Color(1, 1, 1))

## Падение с неба (зона сброса). `ground_point` — точка на РЕАЛЬНОЙ земле; `start_y` — высота старта.
func fall_to(ground_point: Vector3, start_y: float, speed: float) -> void:
	_rest_y = ground_point.y + _REST_OFFSET
	_fall_speed = speed
	global_position = Vector3(ground_point.x, start_y, ground_point.z)
	_falling = start_y > _rest_y
	set_physics_process(_falling)

## Поставить сразу на опору без падения (выпадение из разрушенного куба — как LootCrate.set_loose).
func place_at(ground_point: Vector3) -> void:
	global_position = ground_point + Vector3(0.0, _REST_OFFSET, 0.0)

func _physics_process(delta: float) -> void:
	if not _falling:
		return
	var next_y: float = global_position.y - _fall_speed * delta
	if next_y <= _rest_y:
		next_y = _rest_y
		_falling = false
		set_physics_process(false)
	global_position.y = next_y

func _on_body_entered(body: Node) -> void:
	var applied: bool = false

	var ammo_amt: int = int(_cfg.get("ammo_amount", 0))
	if ammo_amt > 0:
		var ammo: Node = body.get_node_or_null("AmmoComponent")
		if ammo != null:
			ammo.add_ammo(amount_override if amount_override > 0 else ammo_amt)
			applied = true

	# Ящик боеприпасов заодно возвращает заряды маскировки (маскировка — расходуемый ресурс, как
	# снаряды; см. disguise_controller.gd). Считается «применённым» только если хоть один заряд
	# реально вернулся — но ящик боеприпасов и так уже применён снарядами выше, так что это важно
	# лишь для будущих бонусов, несущих одни заряды.
	var charges: int = int(_cfg.get("disguise_charges", 0))
	if charges > 0:
		var disguise: Node = body.get_node_or_null("DisguiseController")
		if disguise != null and disguise.has_method("add_charges"):
			if disguise.add_charges(charges) > 0:
				applied = true

	var heal: int = int(_cfg.get("heal_hits", 0))
	if heal > 0:
		var hp: Node = body.get_node_or_null("HealthComponent")
		if hp != null and hp.has_method("heal"):
			if hp.heal(heal):
				applied = true  # аптечка при полном HP не тратится — ящик остаётся лежать

	var shield: float = float(_cfg.get("shield_sec", 0.0))
	if shield > 0.0:
		var hp2: Node = body.get_node_or_null("HealthComponent")
		if hp2 != null and hp2.has_method("grant_shield"):
			hp2.grant_shield(shield)
			applied = true

	if applied:
		queue_free()
