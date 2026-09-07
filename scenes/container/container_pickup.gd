extends Area3D
## Container — белый подбираемый контейнер режима CONTAINER_EXTRACTION (см. vault
## Tank_Prop_Hunt_Container_Extraction.md). Механика захвата флага: лежит на карте, подбирается
## контактом, доставляется в круг спавна своей команды, при гибели носителя падает на месте гибели
## и снова доступен обеим сторонам.
##
## Подбор — через ЕДИНСТВЕННЫЙ слот модификации танка (`ModificationController.install()`), не через
## отдельный «инвентарь контейнера»: слот уже реализует ровно нужные правила («только в пустой»,
## «сбросить нельзя», «теряется вместе с танком»), а занятый контейнером слот автоматически даёт
## требуемое «пока несёшь контейнер, другие модификации недоступны». `container.tres` — пассивная
## модификация (`behavior_scene = null`): логики у неё нет, весь смысл в том, что слот занят, а
## `ModificationController` форвардит весь контракт null-safe. Побочно это же означает, что бот с
## контейнером НЕ считается носителем спец-оружия (`_has_mortar()` == `_mod.ai_usable()` == false).
##
## Спавн/доставку/выброс при гибели ведёт `scenes/main/container_manager.gd`; этот узел знает
## только про свой подбор. Группа "containers" — как её видит менеджер и (в дальнейшем) ИИ.
##
## Слой 128 (containers) — следующий бит после ammo_crates (32) и mod_crates (64), чтобы
## sphere-проверки зон сброса и AI-сканы отличали белый контейнер от жёлтого и красного ящиков.

const ContainerMod := preload("res://scenes/modifications/container.tres")

## Полувысота коллизии/меша (BoxShape3D 0.6³) — центр встаёт на эту высоту над точкой земли,
## иначе половина уходит под пол. То же число и та же причина, что у AmmoCrate/ModCrate.
const _REST_OFFSET: float = 0.3

func _ready() -> void:
	add_to_group("containers")
	body_entered.connect(_on_body_entered)

## Положить контейнер НА поверхность в этой точке (точка уже с реального рейкаста вниз — считает
## вызывающий, `container_manager.gd`). Отдельный метод, а не присваивание global_position снаружи,
## чтобы смещение на полувысоту жило в одном месте — там же, где размер коллизии.
func place_on_ground(ground_point: Vector3) -> void:
	global_position = ground_point + Vector3(0.0, _REST_OFFSET, 0.0)

## Подбирает ЛЮБАЯ команда (в т.ч. чтобы отобрать у противника уже вынесенный контейнер) и только
## в пустой слот. Занятый слот — контейнер остаётся лежать, как и красный ящик модификации.
func _on_body_entered(body: Node) -> void:
	var mod_slot: Node = body.get_node_or_null("ModificationController")
	if mod_slot == null:
		return
	if not mod_slot.can_pick_up():
		return
	if mod_slot.install(ContainerMod):
		queue_free()
