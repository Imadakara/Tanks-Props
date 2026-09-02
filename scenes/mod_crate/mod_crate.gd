extends Area3D
## ModCrate — подбираемый КРАСНЫЙ ящик модификации (см. Tank_Prop_Hunt_Modifications.md).
## Аналог AmmoCrate (scenes/ammo_crate/ammo_crate.gd), но:
## - слой `mod_crates` (7, бит 64), не `ammo_crates` (32) — зона сброса и AI-сканы различают
##   красные и жёлтые ящики;
## - при контакте выдаёт МОДИФИКАЦИЮ в слот танка (ModificationController.install), и только если
##   слот пуст — иначе ящик остаётся лежать (подбор строго в пустой слот, для обеих команд);
## - MVP: содержит всегда «мортиру» (scenes/modifications/mortar.tres).
##
## Спавнится зоной сброса `scenes/ammo_crate/ammo_drop_zone.gd` (та же зона-лидер, что роняет
## патронные ящики) раз в GameConfig.mortar_drop_interval_sec ОДНОВРЕМЕННО в каждой зоне —
## только на картах режима TARGET_OBJECTIVE.
##
## Падение КИНЕМАТИЧЕСКОЕ (прямо вниз с фикс. скоростью) — тот же приём, что у AmmoCrate/Projectile:
## детерминированно и легко проверяется `run_script`.

## Модификация в этом ящике. preload, НЕ class_name — headless run_project не подхватывает свежий
## class_name без пересканирования редактором (грабля проекта).
const MortarMod := preload("res://scenes/modifications/mortar.tres")

## Полувысота коллизии/меша (BoxShape3D 0.6³) — центр встаёт на эту высоту над точкой земли.
const _REST_OFFSET: float = 0.3

var _falling: bool = false
var _rest_y: float = 0.0
var _fall_speed: float = 18.0

func _ready() -> void:
	add_to_group("mod_crates")
	body_entered.connect(_on_body_entered)
	set_physics_process(false)  # включается только на время падения из fall_to()

## Зовётся зоной сразу после add_child() — та же сигнатура, что AmmoCrate.fall_to().
func fall_to(ground_point: Vector3, start_y: float, speed: float) -> void:
	_rest_y = ground_point.y + _REST_OFFSET
	_fall_speed = speed
	global_position = Vector3(ground_point.x, start_y, ground_point.z)
	_falling = true
	set_physics_process(true)

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
	var mod_slot: Node = body.get_node_or_null("ModificationController")
	if mod_slot == null:
		return
	if not mod_slot.can_pick_up():
		return  # слот занят — ящик остаётся другим
	if mod_slot.install(MortarMod):
		queue_free()
