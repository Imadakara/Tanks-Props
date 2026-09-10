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
## уходит под пол. То же число и та же причина, что у Pickup/ModCrate.
const _REST_OFFSET: float = 0.3

## Базовая (сырая) ценность. Ставится создателем: случайная из диапазона своего яруса
## (`raw_min..raw_max` в config/extraction_*.json) для свежевыбитого, накопленная — для
## выброшенного из трюма или украденного.
var base_value: int = 0
## Ярус редкости 0..3 (обычный … легендарный). Задаёт диапазон сырой ценности, скорость и потолок
## дозревания, цвет. Ставится создателем вместе с `base_value`, едет вместе с лотом через трюм.
var rarity: int = 0
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
## Смысл яруса (диапазон/дозревание/цвет) живёт в config/extraction_*.json, который грузит
## ExtractionManager — свой доступ к JSON у ящика заводить незачем. LootCrate есть только в
## режиме EXTRACTION, где менеджер гарантированно существует; кэшируем ссылку.
var _mgr_cache: Node = null

func _ready() -> void:
	add_to_group("loot_crates")
	body_entered.connect(_on_body_entered)
	_label = $ValueLabel
	set_physics_process(false)  # часы идут только на складе, см. set_stored()
	_refresh_visual()

func _mgr() -> Node:
	if _mgr_cache == null or not is_instance_valid(_mgr_cache):
		_mgr_cache = get_tree().get_first_node_in_group("extraction_manager")
	return _mgr_cache

## Индекс яруса, зажатый по числу ярусов из конфига — защита от битого значения.
func _rar() -> int:
	var m: Node = _mgr()
	var n: int = m.rarity_count() if m != null else 4
	return clampi(rarity, 0, maxi(n - 1, 0))

func _ripen_cap() -> int:
	var m: Node = _mgr()
	return m.rarity_ripen_cap(_rar()) if m != null else base_value

## Текущая ценность: сырое значение ПЛЮС линейный прирост за время на складе (`ripen_per_sec`
## очков/сек своего яруса из JSON), зажатый потолком яруса (`ripen_cap`). Не множитель — поэтому
## «обработка» дешёвого обычного ящика и дорогого легендарного растут по-разному и в абсолюте, и
## по скорости. Не на складе / украденное — сырое.
func current_value() -> int:
	if state != State.STORED or frozen:
		return base_value
	var m: Node = _mgr()
	if m == null:
		return base_value
	var rate: int = m.rarity_ripen_per_sec(_rar())
	return mini(base_value + int(round(float(rate) * stored_elapsed)), m.rarity_ripen_cap(_rar()))

## Доля дозревания 0..1 (визуал + решение бота «самый спелый») — насколько ценность прошла путь от
## сырой к потолку своего яруса.
func ripeness() -> float:
	if state != State.STORED or frozen:
		return 0.0
	var span: int = _ripen_cap() - base_value
	if span <= 0:
		return 1.0
	return clampf(float(current_value() - base_value) / float(span), 0.0, 1.0)

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
	if current_value() >= _ripen_cap():
		set_physics_process(false)  # дозрел до потолка яруса — дальше считать нечего
		_refresh_visual()
		return
	stored_elapsed += delta
	_refresh_visual()

## Подбор — тем же контактом для ЛЮБОГО состояния и любой команды. Решение «влезет ли» целиком
## принимает трюм (`CargoHold.try_take` — вместимость).
##
## `frozen` в лоте (дальше не дозревает) — ТОЛЬКО для РЕЙДА: ящик взят с ЧУЖОГО склада
## (`STORED` и `owner_team != team подобравшего`). Свой ящик, поднятый со своего же склада (передвинуть,
## перепрятать, довезти до выхода и передумать), дозревать ПРОДОЛЖАЕТ — иначе «поправил раскладку на
## складе» = «заморозил лут навсегда». Уже `frozen` ящик (был украден, потом выпал и снова поднят)
## остаётся `frozen`.
func _on_body_entered(body: Node) -> void:
	var hold: Node = body.get_node_or_null("CargoHold")
	if hold == null:
		return
	var raided: bool = state == State.STORED and "team" in body and int(owner_team) != int(body.team)
	if not hold.try_take(current_value(), frozen or raided, _rar()):
		return
	picked_up.emit(self, body)
	queue_free()

## Цвет = ЯРУС РЕДКОСТИ (виден издалека, задаёт масштаб ценности), яркость += СПЕЛОСТЬ, число над
## ящиком = текущая ценность. Всё это игровая информация, доступная всем, кто доехал и посмотрел, —
## без неё решения «стрелять / не стрелять» и «вывезти сейчас или дороже потом» были бы вслепую.
func _refresh_visual() -> void:
	if _label == null:
		return
	_label.text = str(current_value())
	var m: Node = _mgr()
	var col: Color = m.rarity_color(_rar()) if m != null else Color(1, 1, 1)
	_label.modulate = col.lerp(Color.WHITE, 0.4)
	var mesh: MeshInstance3D = $CrateMesh
	var mat: StandardMaterial3D = mesh.material_override as StandardMaterial3D
	if mat == null:
		return
	# сырой ящик — приглушённый цвет яруса, дозревший — цвет в полную силу; украденный всегда
	# выглядит сырым (не растёт).
	mat.albedo_color = col.darkened(0.4).lerp(col, ripeness())
