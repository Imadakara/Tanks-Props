extends Area3D
## AmmoCrate — подбираемый ящик патронов (ТЗ §8.4). Доступен любому танку любой команды;
## при подборе выдаёт `ammo_amount` патронов (0 → GameConfig.ammo_per_crate) и исчезает.
## Спавнится зоной сброса `scenes/ammo_crate/ammo_drop_zone.gd` (префаб AmmoDropZone.tscn в
## углах карт) — та ставит `ammo_amount` и сразу зовёт `fall_to()`.
##
## Падение КИНЕМАТИЧЕСКОЕ (прямо вниз с фикс. скоростью), а не через RigidBody/гравитацию —
## тот же приём, что у Projectile в проекте: детерминированно и легко проверяется живым
## `run_script`. Свободную точку без наложения на другой ящик выбирает зона ДО спавна, здесь
## только вертикальный спуск до земли.
##
## Группа "ammo_crates" нужна зоне: по ней она считает свои ещё не подобранные ящики и по
## слою 32 (ammo_crates) делает sphere-проверку «не уронить поверх чужого ящика».

## Полувысота коллизии/меша ящика (BoxShape3D 0.6³) — центр ящика встаёт на эту высоту над
## точкой земли, иначе половина ящика уходит под пол.
const _REST_OFFSET: float = 0.3

## 0 → взять GameConfig.ammo_per_crate. Зона сброса передаёт сюда своё `ammo_per_crate`,
## поэтому содержимое настраивается на каждой зоне отдельно, не только глобально.
@export var ammo_amount: int = 0

var _falling: bool = false
var _rest_y: float = 0.0
var _fall_speed: float = 18.0

func _ready() -> void:
	add_to_group("ammo_crates")
	body_entered.connect(_on_body_entered)
	set_physics_process(false)  # включается только на время падения из fall_to()

## Зовётся зоной сразу после add_child(). `ground_point` — точка на РЕАЛЬНОЙ земле (из
## SpawnZone.pick_spawn_position(), уже с raycast вниз); `start_y` — мировая высота пустышки
## DropOrigin, с которой ящик «падает с неба».
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
	var ammo: Node = body.get_node_or_null("AmmoComponent")
	if ammo == null:
		return
	var amount: int = ammo_amount if ammo_amount > 0 else GameConfig.ammo_per_crate
	ammo.add_ammo(amount)
	queue_free()
