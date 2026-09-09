@tool
extends StaticBody3D
## Obstacle — универсальный префаб СПЛОШНОГО препятствия (коробка / ящик / стенка / укрытие) для
## ЛЮБОЙ карты. Одна техническая сцена `scenes/obstacles/Obstacle.tscn`, каждый экземпляр
## настраивается через `@export` (`size` / `color`) — скрипт `@tool`, поэтому коллайдер, меш и
## материал синхронизируются прямо в редакторе, без ручной правки двух мест (см.
## `Tank_Prop_Hunt_Obstacles_Navmesh_Guide.md`).
##
## Заменяет прежние разложенные по `.tscn` карт руками связки
## `StaticBody3D + CollisionShape3D + MeshInstance3D`. Ставится ребёнком `NavigationRegion3D` —
## запекатель навмеша берёт его геометрию по слою 1 (`environment`), как и раньше. Никакой код не
## ищет препятствия по имени, имя нужно только для порядка в сцене.
##
## `collision_layer = 1` / `collision_mask = 0` заданы в самой сцене (`Obstacle.tscn`): тело
## ничего не «замечает», но его форму видит запекатель (`geometry/collision_mask = 5`).
##
## НЕ масштабировать узел через `Transform → Scale` — ненулевой scale на физ.теле в Jolt ведёт
## себя неочевидно и путает запекатель (гайд §6.2). Размер — только `size` здесь.

## Габариты коробки. Применяются к дочернему `CollisionShape3D` (`BoxShape3D`) и `Mesh`
## (`BoxMesh`) синхронно. Дефолт совпадает с прежними `Obstacle*` в `TargetObjectiveMap.tscn`
## (и с `GameConfig.disguise_prop_size` — объект имитации маскировки).
@export var size: Vector3 = Vector3(2.0, 1.25, 2.0):
	set(value):
		size = value
		_apply()

## Цвет меша (`albedo`). Дефолт — коричневый, как у прежних `Obstacle*`. Серый переопределяют
## инстансы-стенки.
@export var color: Color = Color(0.6, 0.35, 0.15):
	set(value):
		color = value
		_apply()

@onready var _shape: CollisionShape3D = $CollisionShape3D
@onready var _mesh: MeshInstance3D = $Mesh

## Сколько ценности выпадет при разрушении. 0 — куб пустой. НЕ `@export`: раздаётся при старте
## матча детерминированно по зерну (`extraction_manager.gd`), а не проставляется в `.tscn` руками —
## иначе раскладка добычи была бы одинаковой каждый матч и запоминалась игроками. Визуально лутовый
## куб НИЧЕМ не отличается от пустого и от замаскированного танка: в этом весь смысл (концепт §6 —
## выстрел по кубу это ставка с тремя исходами).
var loot_value: int = 0
## Ярус редкости выпадающего ящика 0..3. Осмыслен только при `drop_kind == LOOT`.
var loot_rarity: int = 0
## Что выпадет при разрушении — индекс `ExtractionManager.FarmDrop` (0 LOOT … 5 SHIELD). Раздаётся
## в `_allocate_loot_nodes()` тем же зерном, ПЕРЕД ярусом. Дефолт = NOTHING (куб без роли).
var drop_kind: int = 1  # FarmDrop.NOTHING

func _ready() -> void:
	_apply()
	# Динамический пресет препятствий (см. map_scene.gd._apply_dynamic_obstacles /
	# dynamic_obstacle_placer.gd) находит и убирает статические кубы карты по этой группе.
	if not Engine.is_editor_hint():
		add_to_group("obstacles")
		# Куб разрушаем ВСЕГДА, независимо от режима и от наличия лута: иначе «пробный выстрел»
		# по укрытию мгновенно выдавал бы, что это не ресурсный узел, и вся ставка обесценилась бы.
		# Снаряд уже сам находит HealthComponent на любом теле (projectile.gd) — спец-кода не нужно.
		var health: Node = get_node_or_null("HealthComponent")
		if health != null:
			health.max_hits = GameConfig.loot_node_hits
			health.destroyed.connect(_on_destroyed)

## Sub-ресурсы в `Obstacle.tscn` помечены `resource_local_to_scene = true` — у каждого инстанса
## свои `BoxShape3D` / `BoxMesh` / `StandardMaterial3D`, правка `size`/`color` одного инстанса не
## задевает остальные.
func _apply() -> void:
	if not is_node_ready():
		return
	if _shape != null and _shape.shape is BoxShape3D:
		_shape.shape.size = size
	if _mesh != null:
		if _mesh.mesh is BoxMesh:
			_mesh.mesh.size = size
		if _mesh.material_override is StandardMaterial3D:
			_mesh.material_override.albedo_color = color

## Куб развалился. Есть лут — роняем ящик на опору ПОД кубом (на многоуровневой карте это может быть
## столешница, а не пол, поэтому лучом вниз, а не по y=0). `free_on_destroy` у HealthComponent
## оставлен включённым: узел исчезает сам сразу после этого сигнала, укрытий на карте становится
## меньше — карта истощается за матч намеренно (концепт §12).
##
## Навмеш при этом НЕ перепекается: исчезнувший куб делает запечённую карту проходимости
## КОНСЕРВАТИВНОЙ (боты обходят место, где уже ничего нет) — это безопасно и дёшево, в отличие от
## перепечки на каждый разрушенный куб.
func _on_destroyed(_killer: Node) -> void:
	var mgr: Node = get_tree().get_first_node_in_group("extraction_manager")
	if mgr == null:
		return
	# Менеджер сам читает у нас drop_kind/loot_value/loot_rarity и решает, что уронить (лут / бонус /
	# ничего). Передаём СЕБЯ — чтобы рейкаст опоры не наткнулся на собственный ещё живой коллайдер.
	mgr.spawn_node_drop(self)
