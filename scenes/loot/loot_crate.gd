extends Area3D
## LootCrate — ЕДИНСТВЕННОЕ физическое воплощение ценности в режиме EXTRACTION.
##
## Концепция (`Tank_Prop_Hunt_Extraction_Loop_Concept.md` §3) описывает четыре состояния ценности.
## Три из них — это ЭТОТ узел, четвёртое — его отсутствие:
##   «найдено»  → узел на земле, `state = LOOSE`, часы стоят;
##   «в трюме»  → узла нет, лот лежит данными в `CargoHold` носителя;
##   «на складе»→ узел припаркован в круге базы, `state = STORED`, часы идут, ценность растёт;
##   «вывезено» → узла нет, ценность записана в счёт команды.
##
## Почему склад — это именно припаркованные узлы, а не список в менеджере: тогда грабёж склада
## (§7) и разведка чужого богатства глазами не требуют НИ ОДНОЙ отдельной механики. Вражеский танк
## подбирает ящик со склада тем же контактом, что и любой другой, а «богата ли база» видно потому,
## что ящики физически лежат — никакого раскрытия через UI.
##
## Слой 128 (`loot_crates`) — тот же бит, что занимал контейнер прежнего CTF-режима, поэтому зоны
## сброса боеприпасов уже умеют не ронять ящики поверх него (`ammo_drop_zone._PROBE_MASK`).

## Состояния, влияющие на ПОВЕДЕНИЕ узла. «В трюме»/«вывезено» сюда не входят — там узла нет.
enum State { LOOSE, STORED }

signal picked_up(crate: Node, by_tank: Node)

## Полувысота коллизии/меша (0.6³) — центр встаёт на эту высоту над точкой опоры, иначе половина
## уходит под пол. То же число и та же причина, что у AmmoCrate/ModCrate.
const _REST_OFFSET: float = 0.3

## Базовая (сырая) ценность. Ставится создателем: случайная `loot_raw_value_min..max` (свой ролл на
## каждый ящик) для свежевыбитого, накопленная — для выброшенного из трюма или украденного.
var base_value: int = 0
var state: int = State.LOOSE
## Украденное со склада не дозревает дальше (§7: грабёж выгоден, но не выгоднее честной добычи).
## Флаг едет вместе с лотом через трюм и возвращается на ящик при выгрузке.
var frozen: bool = false
## Сколько секунд ящик пролежал на складе. Растёт только в STORED и только пока не `frozen`.
var stored_elapsed: float = 0.0
## Чей склад, пока ящик на нём (0/1). -1 — ящик не на складе. Нужен и для счёта «накоплено», и
## чтобы отличить рейд (враг увозит с ЧУЖОГО склада) от обычной выемки.
var owner_team: int = -1

var _label: Label3D

func _ready() -> void:
	add_to_group("loot_crates")
	body_entered.connect(_on_body_entered)
	_label = $ValueLabel
	set_physics_process(false)  # часы идут только на складе, см. set_stored()
	_refresh_visual()

## Текущая ценность с учётом дозревания. Множитель растёт линейно от 1 до
## `GameConfig.loot_ripe_multiplier` за `GameConfig.loot_ripen_sec` и упирается в потолок — без
## потолка не было бы причины вывозить раньше последнего окна (концепт §4).
func current_value() -> int:
	return int(round(float(base_value) * ripeness_multiplier()))

func ripeness_multiplier() -> float:
	if state != State.STORED or frozen:
		return 1.0
	var t: float = clampf(stored_elapsed / maxf(GameConfig.loot_ripen_sec, 0.001), 0.0, 1.0)
	return lerpf(1.0, GameConfig.loot_ripe_multiplier, t)

## Доля дозревания 0..1 — для визуала и для решений бота («самый спелый»).
func ripeness() -> float:
	if state != State.STORED or frozen:
		return 0.0
	return clampf(stored_elapsed / maxf(GameConfig.loot_ripen_sec, 0.001), 0.0, 1.0)

## Положить на землю: свободная добыча, часы стоят. `ground_point` — точка на РЕАЛЬНОЙ поверхности
## (рейкаст делает вызывающий: только он знает, откуда падает ящик).
func set_loose(ground_point: Vector3) -> void:
	state = State.LOOSE
	owner_team = -1
	stored_elapsed = 0.0
	global_position = ground_point + Vector3(0.0, _REST_OFFSET, 0.0)
	set_physics_process(false)
	_refresh_visual()

## Припарковать на складе: часы пошли. Ценность с этого момента растёт (если ящик не украден).
func set_stored(ground_point: Vector3, team: int, elapsed: float = 0.0) -> void:
	state = State.STORED
	owner_team = team
	stored_elapsed = elapsed
	global_position = ground_point + Vector3(0.0, _REST_OFFSET, 0.0)
	set_physics_process(not frozen)  # замороженному тикать незачем
	_refresh_visual()

func _physics_process(delta: float) -> void:
	if state != State.STORED or frozen:
		set_physics_process(false)
		return
	if stored_elapsed >= GameConfig.loot_ripen_sec:
		set_physics_process(false)  # дозрел до потолка — дальше считать нечего
		_refresh_visual()
		return
	stored_elapsed += delta
	_refresh_visual()

## Подбор — тем же контактом для ЛЮБОГО состояния и любой команды. Решение «можно ли взять» целиком
## принимает трюм (`CargoHold.try_take`): правило «со склада — только один и только в пустой трюм»
## живёт там, а не размазано по местам подбора.
func _on_body_entered(body: Node) -> void:
	var hold: Node = body.get_node_or_null("CargoHold")
	if hold == null:
		return
	if not hold.try_take(current_value(), frozen or state == State.STORED, state == State.STORED):
		return
	picked_up.emit(self, body)
	queue_free()

## Цвет и подпись отражают СПЕЛОСТЬ — без этого главное решение концепции («вывезти сейчас дешевле
## или подождать дороже», §9) было бы принципиально невидимым для игрока. Это не отладочный
## визуал: спелость — игровая информация, доступная всем, кто доехал и посмотрел.
func _refresh_visual() -> void:
	if _label == null:
		return
	_label.text = str(current_value())
	var mesh: MeshInstance3D = $CrateMesh
	var mat: StandardMaterial3D = mesh.material_override as StandardMaterial3D
	if mat == null:
		return
	# сырой — тусклый серо-зелёный, спелый — золотой; украденный всегда выглядит сырым (не растёт)
	mat.albedo_color = Color(0.45, 0.5, 0.42).lerp(Color(0.95, 0.78, 0.15), ripeness())
