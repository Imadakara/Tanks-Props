extends Node
## Chassis — ИГРОВОЙ КЛАСС танка: всё, чем один класс отличается от другого, в одном узле.
##
## Класс танка выбирается в лобби перед боем (scenes/lobby/lobby.gd → MatchState.player_chassis) и
## в бою не меняется. Каждый класс — отдельная сцена-префаб, НАСЛЕДУЮЩАЯ базовый `Tank.tscn`:
##   Tank.tscn        — средний (базовая сцена, её Chassis несёт значения среднего)
##   LightTank.tscn   — лёгкий
##   HeavyTank.tscn   — тяжёлый
##   CargoTank.tscn   — грузовой
## Наследник переопределяет ТОЛЬКО этот узел. Все компоненты танка (движение, здоровье, трюм,
## маскировка, оружие, геометрия) общие — класс лишь раздаёт им свои числа и включает черты.
## Каталог id ↔ сцена — chassis_catalog.gd.
##
## ПОЧЕМУ ОДИН УЗЕЛ, А НЕ ПРАВКИ ПО КОМПОНЕНТАМ. Класс — это смысловая единица («лёгкий: мелкий,
## быстрый, 2 HP, ездит в маскировке»), и настраивать его надо в одном инспекторе, а не собирать по
## шести узлам. Заодно лобби читает отсюда же всё, что показывает игроку (chassis_catalog.read_profile).
##
## КОГДА ПРИМЕНЯЕТСЯ. `tank.gd._ready()` зовёт `apply()` — корень готов ПОСЛЕДНИМ, когда каждый
## компонент уже прочитал в своём `_ready()` дефолты из GameConfig. Здесь они перезаписываются
## значениями класса. `team_spawner._apply_tank_config()` (JSON-профили игрок/бот) идёт ПОСЛЕ и
## намеренно НЕ трогает то, чем владеет класс (скорость, HP) — иначе классы сплющились бы в один.
##
## ГЕОМЕТРИЯ. `size_scale` — единый множитель размера. Корень `CharacterBody3D` сам НЕ
## масштабируется (Jolt и масштаб на физтеле — плохая пара, см. правило «не масштабировать через
## Transform → Scale» у префабов препятствий): вместо этого масштабируется КОПИЯ формы коллайдера,
## визуальный пивот `Hull` (он несёт и броню, и башню со стволом), камера, щупы подвески и опоры.
## Габаритная полуразмерность корпуса у среднего — (0.6, 0.3, 0.9).
##
## Полное описание классов — `Tank_Prop_Hunt_Tank_Classes.md` в vault.

## Идентификатор класса: &"light" / &"medium" / &"heavy" / &"cargo". Им же пользуется ростер
## ботов (`"chassis"` в config/roster_*.json) и MatchState.player_chassis.
@export var chassis_id: StringName = &"medium"
@export var display_name: String = "Средний"
## Короткая строка ключевой особенности — лобби показывает её под характеристиками.
@export_multiline var trait_text: String = "С лутом нельзя маскироваться"

@export_group("Габариты и ход")
## Множитель размера относительно среднего (1.0). Лёгкий 1/1.5, тяжёлый и грузовой 1.5.
@export var size_scale: float = 1.0
## Крейсерская скорость, м/с. Средний — 6.0 (как было до классов).
@export var move_speed: float = 6.0

@export_group("Живучесть и груз")
@export var max_hits: int = 3
## Сколько ящиков лута увозит за раз (CargoHold.capacity).
@export var cargo_capacity: int = 3
## Штрафует ли груз скорость. Сам штраф — общее правило, GameConfig.cargo_speed_penalty_per_lot
## (15% за ящик, аддитивно); грузовой класс от него освобождён.
@export var cargo_speed_penalty_enabled: bool = true

@export_group("Вооружение")
## Ёмкость боекомплекта (AmmoComponent.max_ammo). Пополняется ящиками боеприпасов.
@export var ammo_capacity: int = 10

@export_group("Маскировка")
## Сколько длится одна маскировка, сек.
@export var disguise_duration_sec: float = 20.0
## Сколько раз можно замаскироваться (расходуемый ресурс, как снаряды). Восстанавливается на
## респавне до полного и ящиком боеприпасов (pickups.json → ammo.disguise_charges).
@export var disguise_charges: int = 3
## Черта СРЕДНЕГО: гружёный танк маскироваться не может (CargoHold.blocks_disguise()). У остальных
## классов этого ограничения нет — раньше оно было общим правилом режима, теперь это цена за
## универсальность среднего.
@export var cargo_blocks_disguise: bool = true
## Черта ЛЁГКОГО: в маскировке можно ехать (медленно), движение её не сбрасывает, башня замирает
## относительно корпуса и тоже не сбрасывает.
@export var mobile_disguise: bool = false
## Во сколько раз медленнее едет лёгкий в маскировке: скорость × это. 1/2.5 = 0.4.
@export var disguised_speed_mult: float = 0.4

@export_group("Двигатель")
## Черта ТЯЖЁЛОГО: «пружинный двигатель» — столько секунд танк заводится, прежде чем тронуться с
## места по нажатию любой клавиши хода (включая разворот на месте). 0 — черты нет.
@export var spring_engine_delay_sec: float = 0.0

## Габаритные полуразмеры коллайдера среднего и его смещение по Y — точка отсчёта для size_scale.
const BASE_HALF_EXTENTS := Vector3(0.6, 0.3, 0.9)
const BASE_CENTER_Y := 0.3

## Раздать значения класса компонентам танка. Идемпотентно по числам; геометрия масштабируется
## от ИСХОДНЫХ ресурсов сцены (запоминаются на первом вызове), поэтому повторный вызов не
## «перемасштабирует» уже отмасштабированное.
func apply() -> void:
	var tank: Node = get_parent()
	_apply_numbers(tank)
	_apply_geometry(tank)

func _apply_numbers(tank: Node) -> void:
	var movement: Node = tank.get_node_or_null("TankMovement")
	if movement != null:
		movement.move_speed = move_speed
		movement.spring_engine_delay_sec = spring_engine_delay_sec
		movement.set_size_scale(size_scale)

	var health: Node = tank.get_node_or_null("HealthComponent")
	if health != null:
		health.max_hits = max_hits

	var ammo: Node = tank.get_node_or_null("AmmoComponent")
	if ammo != null:
		ammo.set_capacity(ammo_capacity)

	var cargo: Node = tank.get_node_or_null("CargoHold")
	if cargo != null:
		cargo.capacity = cargo_capacity
		cargo.speed_penalty_enabled = cargo_speed_penalty_enabled
		cargo.blocks_disguise_when_loaded = cargo_blocks_disguise

	var fsm: Node = tank.get_node_or_null("TankStateMachine")
	if fsm != null:
		fsm.set_disguise_duration(disguise_duration_sec)

	var disguise: Node = tank.get_node_or_null("DisguiseController")
	if disguise != null:
		disguise.mobile_disguise = mobile_disguise
		disguise.disguised_speed_mult = disguised_speed_mult
		disguise.set_max_charges(disguise_charges)
		disguise.hull_half_extents = BASE_HALF_EXTENTS * size_scale
		disguise.hull_center_offset = Vector3(0.0, BASE_CENTER_Y * size_scale, 0.0)

func _apply_geometry(tank: Node) -> void:
	var s: float = size_scale
	# Визуальный корпус (броня + ходовая + башня со стволом) — одним масштабом пивота.
	var hull: Node = tank.get_node_or_null("Hull")
	if hull != null:
		hull.chassis_scale = s

	_scale_convex_collider(tank.get_node_or_null("CollisionShape3D") as CollisionShape3D, s)
	_scale_box_collider(tank.get_node_or_null("CollisionDetector/CollisionShape3D") as CollisionShape3D, s)

	# Снаряд рождается на `muzzle_forward_offset` впереди узла дула — у крупного ствола дальше.
	var weapon: Node = tank.get_node_or_null("WeaponController")
	if weapon != null:
		if not weapon.has_meta(&"_base_muzzle"):
			weapon.set_meta(&"_base_muzzle", weapon.muzzle_forward_offset)
		weapon.muzzle_forward_offset = float(weapon.get_meta(&"_base_muzzle")) * s

	# Камера: крупный танк иначе заполнял бы кадр, мелкий — терялся бы в нём.
	var rig: Node = tank.get_node_or_null("CameraRig")
	if rig != null:
		for prop in [&"pivot_height", &"pivot_height_top", &"spring_length_base", &"spring_length_top"]:
			var key: StringName = StringName("_base_" + String(prop))
			if not rig.has_meta(key):
				rig.set_meta(key, rig.get(prop))
			rig.set(prop, float(rig.get_meta(key)) * s)

## Масштабная КОПИЯ выпуклой формы корня. Своя копия на танк обязательна: исходный ресурс общий
## для всех инстансов сцены, правка его «на месте» отмасштабировала бы всех разом. Двойник кувырка
## (tumble_controller.gd) берёт форму у этого же узла — масштаб доезжает до него сам.
func _scale_convex_collider(col: CollisionShape3D, s: float) -> void:
	if col == null or col.shape == null:
		return
	if not col.has_meta(&"_base_shape"):
		col.set_meta(&"_base_shape", col.shape)
		col.set_meta(&"_base_y", col.position.y)
	var base: Shape3D = col.get_meta(&"_base_shape")
	col.position.y = float(col.get_meta(&"_base_y")) * s
	if is_equal_approx(s, 1.0):
		col.shape = base
		return
	if base is ConvexPolygonShape3D:
		var scaled := ConvexPolygonShape3D.new()
		var pts: PackedVector3Array = (base as ConvexPolygonShape3D).points
		for i in pts.size():
			pts[i] = pts[i] * s
		scaled.points = pts
		col.shape = scaled

func _scale_box_collider(col: CollisionShape3D, s: float) -> void:
	if col == null or col.shape == null:
		return
	if not col.has_meta(&"_base_shape"):
		col.set_meta(&"_base_shape", col.shape)
		col.set_meta(&"_base_y", col.position.y)
	var base: Shape3D = col.get_meta(&"_base_shape")
	col.position.y = float(col.get_meta(&"_base_y")) * s
	if is_equal_approx(s, 1.0):
		col.shape = base
		return
	if base is BoxShape3D:
		var scaled := BoxShape3D.new()
		scaled.size = (base as BoxShape3D).size * s
		col.shape = scaled

## Характеристики для лобби — без применения к танку. Скорость — и абсолютная, и в процентах от
## среднего, потому что именно так её и формулирует дизайн («на 30% быстрее»).
func profile() -> Dictionary:
	return {
		"id": chassis_id,
		"name": display_name,
		"trait": trait_text,
		"size_scale": size_scale,
		"move_speed": move_speed,
		"max_hits": max_hits,
		"cargo_capacity": cargo_capacity,
		"cargo_speed_penalty_enabled": cargo_speed_penalty_enabled,
		"ammo_capacity": ammo_capacity,
		"disguise_duration_sec": disguise_duration_sec,
		"disguise_charges": disguise_charges,
		"cargo_blocks_disguise": cargo_blocks_disguise,
		"mobile_disguise": mobile_disguise,
		"spring_engine_delay_sec": spring_engine_delay_sec,
	}
