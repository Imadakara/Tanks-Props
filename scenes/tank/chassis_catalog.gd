extends RefCounted
## ChassisCatalog — справочник игровых классов танка: id ↔ сцена-префаб, порядок в лобби и
## подмена танка игрока на выбранный класс. Статический API, без `class_name` (свежий class_name
## headless-запуск не видит без пересканирования редактором — берём через preload, см. CLAUDE.md,
## инвариант 7).

## Порядок = порядок карточек в лобби.
const ORDER: Array[StringName] = [&"light", &"medium", &"heavy", &"cargo"]
const DEFAULT_ID: StringName = &"medium"

const SCENES := {
	&"light": "res://scenes/tank/LightTank.tscn",
	&"medium": "res://scenes/tank/Tank.tscn",
	&"heavy": "res://scenes/tank/HeavyTank.tscn",
	&"cargo": "res://scenes/tank/CargoTank.tscn",
}

static func is_known(id: StringName) -> bool:
	return SCENES.has(id)

static func scene_path(id: StringName) -> String:
	return SCENES.get(id, SCENES[DEFAULT_ID])

static func load_scene(id: StringName) -> PackedScene:
	return load(scene_path(id)) as PackedScene

## Характеристики класса для лобби. Инстанс вне дерева: `_ready()` ни у кого не срабатывает,
## геометрия не строится — читаем только экспорты узла Chassis и сразу освобождаем.
static func read_profile(id: StringName) -> Dictionary:
	var scene: PackedScene = load_scene(id)
	if scene == null:
		return {}
	var tank: Node = scene.instantiate()
	var chassis: Node = tank.get_node_or_null("Chassis")
	var out: Dictionary = chassis.profile() if chassis != null else {}
	tank.free()
	return out

## Подменить стоящий в сцене карты `PlayerTank` (статический инстанс базового Tank.tscn) танком
## выбранного класса. Зовётся из `_enter_tree()` корня карты — это ЕДИНСТВЕННАЯ точка, где подмена
## безопасна:
##  - `_enter_tree()` корня срабатывает ДО того, как дети войдут в дерево, а `_ready()` детей идёт
##    ещё позже — поэтому HUD (он берёт `PlayerTank` в собственном `_ready()`), `@onready`-ссылки
##    `map_scene.gd` и спавнер видят уже танк нужного класса, а не базовый;
##  - во время колбэка `_enter_tree()` самого корня добавлять/удалять его детей можно (движок
##    блокирует это только пока идёт обход детей, а он начинается после колбэка);
##  - срабатывает и на `change_scene_to_file()`, и на `reload_current_scene()` (рестарт раунда) —
##    класс держится весь матч, как и требуется («менять класс в бою нельзя»).
## Класс среднего совпадает с базовой сценой — подмена не нужна, выходим без операций.
static func swap_player_tank(map_root: Node, chassis_id: StringName) -> void:
	var old: Node3D = map_root.get_node_or_null("PlayerTank") as Node3D
	if old == null:
		return
	if not is_known(chassis_id):
		push_warning("ChassisCatalog: неизвестный класс '%s' — оставлен средний" % chassis_id)
		return
	if scene_path(chassis_id) == old.scene_file_path:
		return
	var scene: PackedScene = load_scene(chassis_id)
	if scene == null:
		push_error("ChassisCatalog: не загрузилась сцена класса '%s'" % chassis_id)
		return
	var fresh: Node3D = scene.instantiate() as Node3D
	var index: int = old.get_index()
	fresh.transform = old.transform
	map_root.remove_child(old)
	old.free()
	fresh.name = "PlayerTank"
	map_root.add_child(fresh)
	map_root.move_child(fresh, index)
