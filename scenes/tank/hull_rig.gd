@tool
extends Node3D
## HullRig — ходовая часть танка: ВИЗУАЛЬНЫЙ корпус (бронекоробка + гусеницы + катки) и его
## наклон по рельефу. Скрипт висит на узле `Hull` — промежуточном пивоте между корнем танка
## (CharacterBody3D) и мешами корпуса.
##
## ЗАЧЕМ ОТДЕЛЬНЫЙ ПИВОТ. Корень танка — CharacterBody3D, он ВСЕГДА остаётся строго вертикальным:
## его basis участвует в расчёте forward/right (tank_movement.gd), в направлении выстрела, в yaw
## башни и во всей математике ботов (tank_ai_controller.gd читает `_body.rotation.y` как
## единственный угол корпуса). Наклонить сам корень — сломать это всё разом. Поэтому кренится
## только визуальный пивот `Hull`; физика, навигация и вся геймплейная геометрия — как были.
##
## ЧТО ПОД ПИВОТОМ, А ЧТО НЕТ:
## - `Turret` — ПОД пивотом (`Hull/Turret`), то есть кренится вместе с корпусом. Так и должно
##   быть физически: погон стоит на корпусе и даёт башне ровно одну степень свободы — вращение
##   вокруг нормали палубы. Следствие, с которым надо считаться: локальный угол башни/дула больше
##   не равен мировому. Направление выстрела берётся из живого basis ствола
##   (weapon_controller.gd), экранный прицел игрока (hud.gd) — оттуда же, поэтому прицел всегда
##   честно показывает, куда полетит снаряд; а заказ угла возвышения (`BarrelController.target_pitch`)
##   остался в МИРОВОЙ системе и пересчитывается в локальную внутри barrel_controller.gd. Оттуда
##   же — `world_pitch()`/`world_pitch_limits()` для проверок сходимости прицела у ботов.
## - `CameraRig` — НА КОРНЕ: камера не должна раскачиваться вместе с корпусом.
##
## ОТКУДА БЕРЁТСЯ КРЕН: четыре луча вниз по углам корпуса (_sample_ground) → тангаж/крен опорной
## плоскости + просадка по высоте (коробчатый коллайдер на склоне опирается на ребро и «висит»
## над поверхностью — визуальный корпус этот зазор выбирает). Сверху накладывается динамика
## подвески: клевок на разгоне/торможении и крен наружу в повороте. Всё сглаживается
## экспоненциальным доводом и ограничивается max_tilt_deg; в воздухе корпус выравнивается.
##
## ХОДОВАЯ: катки, ведущее колесо и ленивец — цилиндры со спицей-маркером (без маркера вращение
## гладкого цилиндра на глаз не читается); гусеница — MultiMesh из траков-коробок, бегущих по
## «стадиону» (два прямых участка + два полукруга) вокруг катков. Скорость КАЖДОЙ гусеницы
## считается отдельно из линейной и угловой скорости корпуса (v = v_forward ± ω·gauge) — поэтому
## разворот на месте гонит гусеницы в разные стороны, как у настоящего танка, а не «обе вперёд».
##
## Вся геометрия СТРОИТСЯ КОДОМ (тот же приём, что границы карты в map_scene.gd и дебаг-круги в
## spawn_zone.gd), а не лежит узлами в Tank.tscn: размеры параметризованы @export'ами, поменять
## число катков или траков правкой одного числа проще, чем перекладывать десяток узлов вручную.
## Созданные узлы НЕ получают `owner` — редактор их не сериализует, поэтому сохранение Tank.tscn
## из GUI не раздувает сцену (штатная ловушка @tool-скриптов, здесь закрыта явно).
##
## Полное описание — `Tank_Prop_Hunt_Tank_Chassis.md` в vault.

@export_group("Габариты")
## Полная длина корпуса и гусеничной ленты по Z.
@export var hull_length: float = 1.8:
	set(value):
		hull_length = maxf(value, 0.2)
		_queue_rebuild()
## Полная ширина корпуса по X (спонсоны нависают над гусеницами).
@export var hull_width: float = 1.2:
	set(value):
		hull_width = maxf(value, 0.2)
		_queue_rebuild()
## Высота корпуса от земли до погона башни.
@export var hull_height: float = 0.6:
	set(value):
		hull_height = maxf(value, 0.1)
		_queue_rebuild()
## Смещение центра гусеницы от оси танка по X.
@export var track_gauge: float = 0.45:
	set(value):
		track_gauge = maxf(value, 0.05)
		_queue_rebuild()
## Радиус гусеничного «стадиона» — он же высота ленты над землёй и радиус катков с траком.
@export var track_radius: float = 0.2:
	set(value):
		track_radius = maxf(value, 0.03)
		_queue_rebuild()
## Ширина трака.
@export var track_width: float = 0.24:
	set(value):
		track_width = maxf(value, 0.02)
		_queue_rebuild()
## Толщина трака: уходит ВНУТРЬ ленты, внешняя грань нижней ветви лежит ровно на y = 0.
@export var cleat_thickness: float = 0.05:
	set(value):
		cleat_thickness = maxf(value, 0.005)
		_queue_rebuild()
## Сколько траков в ленте. Меньше — заметнее «ступеньки», больше — дороже кадр.
@export var cleat_count: int = 18:
	set(value):
		cleat_count = maxi(value, 3)
		_queue_rebuild()
## Опорных катков на борт. Ведущее колесо и ленивец добавляются сверх этого числа всегда.
@export var road_wheel_count: int = 5:
	set(value):
		road_wheel_count = maxi(value, 1)
		_queue_rebuild()
## Ширина катка. Держать БОЛЬШЕ track_width — тогда обод выступает за ленту и его вращение видно
## сбоку; вровень с лентой каток полностью прячется за траками и «колёса не крутятся».
@export var wheel_width: float = 0.3:
	set(value):
		wheel_width = maxf(value, 0.02)
		_queue_rebuild()

@export_group("Цвета")
## Ходовая НЕ красится в цвет команды (tank.gd._DARK_PART_PREFIXES) — эти цвета финальные.
@export var track_color: Color = Color(0.16, 0.16, 0.18):
	set(value):
		track_color = value
		_queue_rebuild()
@export var wheel_color: Color = Color(0.24, 0.24, 0.26):
	set(value):
		wheel_color = value
		_queue_rebuild()
@export var wheel_marker_color: Color = Color(0.55, 0.55, 0.58):
	set(value):
		wheel_marker_color = value
		_queue_rebuild()

@export_group("Подвеска")
## Выключить — корпус останется строго горизонтальным (поведение до появления этой ноды).
## Ходовая при этом продолжит крутиться: это независимые части.
@export var terrain_tilt_enabled: bool = true
## Потолок суммарного наклона (рельеф + динамика). Должен покрывать реальные уклоны карт, иначе
## корпус на крутом пандусе недокренивается — а вместе с ним и башня, и геометрия наводки перестаёт
## соответствовать склону. После фаски коллайдера танк заезжает вплоть до 44° (полигон), так что
## 32° — рабочий запас; всё, что круче, встречается только на заведомо непроезжих поверхностях.
@export var max_tilt_deg: float = 32.0
## Скорость экспоненциального довода к целевому наклону, 1/сек. Больше — жёстче подвеска.
@export var tilt_response: float = 9.0
## Завал корпуса через кромку в фазе teeter. Корень танка никогда не кренится (см. заголовок),
## поэтому «нос в пропасть» рисуется здесь: визуальный корпус доворачивается носом/бортом в
## сторону пустоты на угол `TankMovement.tip_angle()` (тот сам его интегрирует, 0 → точка
## невозврата). Выключить — корпус в фазе teeter останется горизонтальным.
@export var fall_tip_enabled: bool = true
## Клевок на разгоне/торможении: радиан наклона на 1 м/с² продольного ускорения.
@export var accel_pitch_gain: float = 0.012
## Крен наружу в повороте: радиан на (рад/с · м/с).
@export var turn_roll_gain: float = 0.05
## Насколько глубоко визуальный корпус может просесть относительно начала координат танка
## (коллайдер на склоне опирается на ребро — без просадки гусеницы висели бы в воздухе).
@export var max_ground_drop: float = 0.5
## Зазор над найденной поверхностью — страховка от z-fighting гусеницы с полом.
@export var ride_height: float = 0.01
## Пружина просадки на приземлении: жёсткость и затухание.
@export var landing_bob_stiffness: float = 140.0
@export var landing_bob_damping: float = 14.0
## Сила просадки на приземлении, метров на (м/с) вертикальной скорости удара.
@export var landing_bob_gain: float = 0.012

@export_group("Анимация ходовой")
## Выключить — катки и траки замрут (наклон корпуса продолжит работать).
@export var animate_running_gear: bool = true
## Ниже этой скорости борта (м/с) ходовая считается стоящей и не пересчитывается — экономит
## десятки записей трансформов в кадр на каждом стоящем танке.
@export var running_gear_epsilon: float = 0.02

## Масштаб класса танка (chassis.gd, size_scale): лёгкий 1/1.5, тяжёлый и грузовой 1.5. Масштабируется
## САМ ПИВОТ (`scale` узла) — под ним и броня, и ходовая, и башня со стволом, поэтому весь визуал
## растёт одним движением. Габаритные @export'ы выше остаются «в единицах среднего» и геометрию
## строят как раньше. Масштаб узла переживает запись `rotation` ниже (у Node3D поворот и масштаб
## хранятся раздельно). Щупы подвески мерят в СИСТЕМЕ КОРНЯ, поэтому их выносы умножаются на этот
## же множитель вручную (_sample_ground). Выставляется только в рантайме — в редакторе сцена класса
## выглядит как средний: коллайдер тоже масштабируется лишь в рантайме, и так они хотя бы совпадают.
var chassis_scale: float = 1.0:
	set(value):
		chassis_scale = maxf(value, 0.05)
		scale = Vector3.ONE * chassis_scale

## Тангаж/крен ОПОРНОЙ ПЛОСКОСТИ (без динамики подвески), радианы — для отладочных экранов
## (полигон испытаний) и любой будущей логики по уклону. Только чтение.
var ground_pitch: float = 0.0
var ground_roll: float = 0.0
## Нашли ли лучи опору в этом кадре.
var grounded: bool = false

const _PROBE_X := [-1.0, 1.0, -1.0, 1.0]  # FL, FR, RL, RR
const _PROBE_Z := [-1.0, -1.0, 1.0, 1.0]  # -Z = вперёд (общая конвенция проекта)
## Луч стартует выше корпуса и уходит заметно ниже — чтобы поймать и бугор под днищем, и провал.
const _PROBE_UP := 0.7
const _PROBE_DOWN := 1.6

var _body: CharacterBody3D
var _movement: Node  # TankMovement — источник факта свеса (is_falling) и его направления (tip_dir)
var _generated: Array[Node] = []
var _wheels_left: Array[Node3D] = []
var _wheels_right: Array[Node3D] = []
var _track_left: MultiMeshInstance3D
var _track_right: MultiMeshInstance3D

var _pitch: float = 0.0
var _roll: float = 0.0
var _height: float = 0.0
var _phase_left: float = 0.0
var _phase_right: float = 0.0
var _prev_forward_speed: float = 0.0
var _prev_yaw: float = 0.0
## Угловая скорость корпуса за этот кадр — считается один раз в _update_suspension() и
## переиспользуется анимацией ходовой (второй раз разницу углов уже не взять: _prev_yaw обновлён).
var _yaw_rate: float = 0.0
var _was_airborne: bool = false
var _bob: float = 0.0
var _bob_vel: float = 0.0

func _ready() -> void:
	_body = get_parent() as CharacterBody3D
	_rebuild()
	if Engine.is_editor_hint():
		return
	assert(_body != null, "HullRig должен быть прямым ребёнком CharacterBody3D (корня танка)")
	_movement = _body.get_node_or_null("TankMovement")
	_prev_yaw = _body.rotation.y
	# Респавн телепортирует танк — без сброса корпус на кадр приезжает со старым креном/просадкой.
	var respawn: Node = _body.get_node_or_null("RespawnController")
	if respawn != null:
		respawn.respawned.connect(_on_respawned)

func _on_respawned() -> void:
	_pitch = 0.0
	_roll = 0.0
	_height = 0.0
	_bob = 0.0
	_bob_vel = 0.0
	_was_airborne = false
	_prev_forward_speed = 0.0
	_prev_yaw = _body.rotation.y
	rotation = Vector3.ZERO
	position.y = 0.0

## Сброс позы визуального корпуса в нейтраль. Зовёт TumbleController при возврате управления после
## кувырка (эта нода на время кувырка заморожена по process_mode и застыла бы в последнем крене).
func reset_pose() -> void:
	_on_respawned()

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _body == null or delta <= 0.0:
		return
	_update_suspension(delta)
	_update_running_gear(delta)

# ---------------------------------------------------------------------------------------------
# Подвеска: наклон корпуса по рельефу + динамика
# ---------------------------------------------------------------------------------------------

func _update_suspension(delta: float) -> void:
	var forward: Vector3 = -_body.global_transform.basis.z
	var forward_speed: float = _body.velocity.dot(forward)
	var accel: float = (forward_speed - _prev_forward_speed) / delta
	_prev_forward_speed = forward_speed
	_yaw_rate = wrapf(_body.rotation.y - _prev_yaw, -PI, PI) / delta
	_prev_yaw = _body.rotation.y

	var target_pitch: float = 0.0
	var target_roll: float = 0.0
	var target_height: float = 0.0
	if terrain_tilt_enabled:
		var plane: Vector3 = _sample_ground()
		target_pitch = plane.x
		target_roll = plane.y
		target_height = plane.z
	ground_pitch = target_pitch
	ground_roll = target_roll

	# Фаза teeter: корпус ПЛАВНО кренится носом/бортом в сторону пустоты на угол, который
	# интегрирует сам tank_movement.gd (_tip_angle: 0 → deg_to_rad(teeter_ponr_deg)). Это и есть
	# «завал через кромку» — обратимый, пока не дошло до точки невозврата. tip_dir (сист. корня,
	# XZ) — к неопёртым углам: пустота спереди (d.z < 0) → нос вниз (−pitch), справа (d.x > 0) →
	# правый борт вниз (−roll). Экспоненциальный довод ниже сглаживает и это.
	if fall_tip_enabled and _movement != null:
		var ta: float = _movement.tip_angle()
		if ta > 0.0005:
			var tip: Vector3 = _movement.tip_dir
			target_pitch += tip.z * ta
			target_roll -= tip.x * ta

	# Динамика подвески. Клевок: разгон задирает нос, торможение — клюёт. Крен: инерция в
	# повороте прижимает внешний борт (поворот влево — yaw_rate > 0 — проседает правый борт,
	# отсюда минус: положительный roll поднимает правый борт).
	target_pitch += clampf(accel * accel_pitch_gain, -0.15, 0.15)
	target_roll += clampf(-_yaw_rate * forward_speed * turn_roll_gain, -0.15, 0.15)

	var limit: float = deg_to_rad(max_tilt_deg)
	target_pitch = clampf(target_pitch, -limit, limit)
	target_roll = clampf(target_roll, -limit, limit)

	# Экспоненциальный довод — кадронезависимый, в отличие от lerp с коэффициентом (speed * delta).
	var k: float = 1.0 - exp(-tilt_response * delta)
	_pitch = lerp(_pitch, target_pitch, k)
	_roll = lerp(_roll, target_roll, k)
	_height = lerp(_height, target_height, k)

	_update_landing_bob(delta)

	rotation = Vector3(_pitch, 0.0, _roll)
	position.y = _height + _bob

## Пружина просадки на приземлении: удар — импульс вниз в момент касания, дальше обычный
## затухающий осциллятор к нулю. Даёт «ойк» подвески на съезде с трамплина, ради которого всё и
## затевалось: рельеф без него читается плоско даже при верном крене.
func _update_landing_bob(delta: float) -> void:
	var airborne: bool = not _body.is_on_floor()
	if _was_airborne and not airborne:
		_bob_vel -= absf(minf(_body.velocity.y, 0.0)) * landing_bob_gain * landing_bob_stiffness * delta
	_was_airborne = airborne
	_bob_vel += (-_bob * landing_bob_stiffness - _bob_vel * landing_bob_damping) * delta
	_bob = clampf(_bob + _bob_vel * delta, -max_ground_drop, 0.1)

## Четыре луча вниз по углам корпуса. Возвращает (тангаж, крен, просадка) в системе корпуса.
## Луч идёт ТОЛЬКО по слою environment (1) — танки, зоны и снаряды рельефом не считаются.
## Собственное тело исключено явно: без этого луч из точки внутри коллайдера вернул бы его же.
func _sample_ground() -> Vector3:
	var space: PhysicsDirectSpaceState3D = _body.get_world_3d().direct_space_state
	var xf: Transform3D = _body.global_transform
	var base_y: float = _body.global_position.y
	var heights := [0.0, 0.0, 0.0, 0.0]
	var found := [false, false, false, false]
	var sum: float = 0.0
	var hits: int = 0
	for i in 4:
		var local := Vector3(
			_PROBE_X[i] * track_gauge,
			0.0,
			_PROBE_Z[i] * (hull_length * 0.5 - track_radius)
		) * chassis_scale
		var query := PhysicsRayQueryParameters3D.create(
			xf * (local + Vector3(0.0, _PROBE_UP * chassis_scale, 0.0)),
			xf * (local + Vector3(0.0, -_PROBE_DOWN * chassis_scale, 0.0)),
			1
		)
		query.exclude = [_body.get_rid()]
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty():
			continue
		heights[i] = (hit["position"] as Vector3).y - base_y
		found[i] = true
		sum += heights[i]
		hits += 1
	grounded = hits > 0
	if hits == 0:
		return Vector3.ZERO  # в воздухе — выравниваемся
	# Не найденный угол (свес над обрывом) подменяем средним по найденным: иначе он читался бы как
	# «земля ровно на уровне днища» и корпус на краю площадки задирало бы в обратную сторону.
	var average: float = sum / float(hits)
	for i in 4:
		if not found[i]:
			heights[i] = average
	var front: float = (heights[0] + heights[1]) * 0.5
	var rear: float = (heights[2] + heights[3]) * 0.5
	var right: float = (heights[1] + heights[3]) * 0.5
	var left: float = (heights[0] + heights[2]) * 0.5
	var span_z: float = maxf(hull_length - 2.0 * track_radius, 0.01) * chassis_scale
	var span_x: float = maxf(2.0 * track_gauge, 0.01) * chassis_scale
	return Vector3(
		atan2(front - rear, span_z),
		atan2(right - left, span_x),
		clampf(average + ride_height, -max_ground_drop * chassis_scale, 0.05)
	)

# ---------------------------------------------------------------------------------------------
# Ходовая: вращение катков и бег траков
# ---------------------------------------------------------------------------------------------

func _update_running_gear(delta: float) -> void:
	if not animate_running_gear:
		return
	var forward: Vector3 = -_body.global_transform.basis.z
	var forward_speed: float = _body.velocity.dot(forward)
	# Угловая скорость корпуса даёт бортам разные линейные скорости: v = v_forward ± ω·gauge.
	# Разворот на месте (v_forward = 0) → борта крутятся строго встречно, как у настоящего танка.
	var v_left: float = forward_speed - _yaw_rate * track_gauge
	var v_right: float = forward_speed + _yaw_rate * track_gauge
	if absf(v_left) < running_gear_epsilon and absf(v_right) < running_gear_epsilon:
		return
	_spin_wheels(_wheels_left, v_left, delta)
	_spin_wheels(_wheels_right, v_right, delta)
	var perimeter: float = _track_perimeter()
	_phase_left = fposmod(_phase_left - v_left * delta, perimeter)
	_phase_right = fposmod(_phase_right - v_right * delta, perimeter)
	_update_track_mesh(_track_left, _phase_left)
	_update_track_mesh(_track_right, _phase_right)

## Качение без проскальзывания: точка контакта неподвижна относительно земли, отсюда ω = −v/R.
## Знак — из того, что forward у проекта −Z: рост rotation.x гонит НИЗ катка вперёд.
func _spin_wheels(wheels: Array[Node3D], speed: float, delta: float) -> void:
	var radius: float = maxf(_wheel_radius(), 0.001)
	var step: float = -speed / radius * delta
	for wheel in wheels:
		wheel.rotation.x = wrapf(wheel.rotation.x + step, -PI, PI)

func _update_track_mesh(node: MultiMeshInstance3D, phase: float) -> void:
	if node == null:
		return
	var mm: MultiMesh = node.multimesh
	var perimeter: float = _track_perimeter()
	var step: float = perimeter / float(mm.instance_count)
	for i in mm.instance_count:
		mm.set_instance_transform(i, _cleat_transform(fposmod(phase + float(i) * step, perimeter)))

## Профиль гусеницы — «стадион» в плоскости YZ: нижняя ветвь (по земле), полукруг вокруг
## ленивца (нос), верхняя ветвь, полукруг вокруг ведущего колеса (корма). Параметр s идёт вдоль
## периметра от кормы по низу вперёд. Угол θ поворота трака вокруг X подобран так, что его
## локальный +Y всегда смотрит НАРУЖУ ленты и на стыках сегментов непрерывен (π → π → 0 → 0).
func _cleat_transform(s: float) -> Transform3D:
	var zc: float = _straight_half()
	var rp: float = _cleat_path_radius()
	var cy: float = track_radius
	var straight: float = 2.0 * zc
	var arc: float = PI * rp
	var z: float
	var y: float
	var angle: float
	if s < straight:
		z = zc - s
		y = cy - rp
		angle = PI
	elif s < straight + arc:
		var phi: float = (s - straight) / rp
		z = -zc - sin(phi) * rp
		y = cy - cos(phi) * rp
		angle = phi + PI
	elif s < 2.0 * straight + arc:
		z = -zc + (s - straight - arc)
		y = cy + rp
		angle = 0.0
	else:
		var phi_rear: float = (s - 2.0 * straight - arc) / rp
		z = zc + sin(phi_rear) * rp
		y = cy + cos(phi_rear) * rp
		angle = phi_rear
	return Transform3D(Basis(Vector3.RIGHT, angle), Vector3(0.0, y, z))

func _straight_half() -> float:
	return maxf(hull_length * 0.5 - track_radius, 0.01)

func _cleat_path_radius() -> float:
	return maxf(track_radius - cleat_thickness * 0.5, 0.01)

func _track_perimeter() -> float:
	return 4.0 * _straight_half() + 2.0 * PI * _cleat_path_radius()

func _wheel_radius() -> float:
	return maxf(track_radius - cleat_thickness, 0.01)

# ---------------------------------------------------------------------------------------------
# Сборка геометрии
# ---------------------------------------------------------------------------------------------

## Пересборка по правке любого @export-габарита. До _ready() ничего не строим: значения из
## Tank.tscn присваиваются ДО входа узла в дерево, там add_child() ещё нельзя.
func _queue_rebuild() -> void:
	if is_node_ready():
		_rebuild()

func _rebuild() -> void:
	for node in _generated:
		if is_instance_valid(node):
			node.queue_free()
	_generated.clear()
	_wheels_left.clear()
	_wheels_right.clear()
	_track_left = null
	_track_right = null
	_build_armor()
	_build_side(-1.0, "Left", _wheels_left)
	_build_side(1.0, "Right", _wheels_right)

## Узел-потомок БЕЗ owner: редактор такие не сериализует, поэтому @tool-превью не попадает в
## Tank.tscn при сохранении сцены из GUI.
func _adopt(node: Node) -> void:
	add_child(node)
	_generated.append(node)

func _mesh_node(mesh_name: String, mesh: Mesh, color: Color, xform: Transform3D) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = mesh_name
	instance.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	instance.material_override = material
	instance.transform = xform
	return instance

func _box(size: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size
	return mesh

## Бронеплита между двумя точками (наклонная лобовая). Basis собирается КОДОМ по столбцам — в
## GDScript конструктор берёт именно столбцы, в отличие от текстового литерала Transform3D в
## .tscn, который разбирается ПОСТРОЧНО (база знаний §1). Ровно поэтому наклонные плиты живут
## здесь, а не руками в сцене.
func _plate_between(
	plate_name: String, a: Vector3, b: Vector3, width: float, thickness: float, color: Color
) -> MeshInstance3D:
	var delta: Vector3 = b - a
	var length: float = maxf(delta.length(), 0.001)
	var axis_z: Vector3 = delta / length
	var axis_y: Vector3 = axis_z.cross(Vector3.RIGHT).normalized()
	var axis_x: Vector3 = axis_y.cross(axis_z).normalized()
	return _mesh_node(
		plate_name,
		_box(Vector3(width, thickness, length)),
		color,
		Transform3D(Basis(axis_x, axis_y, axis_z), (a + b) * 0.5)
	)

## Бронекорпус: нижняя коробка между гусеницами, спонсоны во всю ширину поверх них, наклонная
## лобовая плита, кормовой лист, моторная палуба и погон башни. Цвет здесь нейтральный — команду
## накладывает tank.gd.apply_team_visuals() поверх (material_override), кроме ходовой.
func _build_armor() -> void:
	var inner_half: float = maxf(track_gauge - track_width * 0.5 - 0.02, 0.05)
	var lower_top: float = hull_height * 0.62
	var nose_z: float = -hull_length * 0.46
	var rear_z: float = hull_length * 0.46
	var upper_front_z: float = -hull_length * 0.305
	var base := Color(0.55, 0.55, 0.55)

	_adopt(_mesh_node(
		"HullMesh",
		_box(Vector3(inner_half * 2.0, lower_top - cleat_thickness, rear_z - nose_z)),
		base,
		Transform3D(Basis(), Vector3(0.0, (lower_top + cleat_thickness) * 0.5, 0.0))
	))
	_adopt(_mesh_node(
		"HullSponsons",
		_box(Vector3(hull_width, hull_height - lower_top, rear_z - upper_front_z)),
		base,
		Transform3D(Basis(), Vector3(0.0, (hull_height + lower_top) * 0.5, (rear_z + upper_front_z) * 0.5))
	))
	# Лобовая плита: от носа нижней коробки вверх-НАЗАД к передней кромке спонсонов (~60°).
	_adopt(_plate_between(
		"HullGlacis",
		Vector3(0.0, cleat_thickness + 0.02, nose_z),
		Vector3(0.0, hull_height - 0.02, upper_front_z),
		inner_half * 2.0,
		0.05,
		base
	))
	_adopt(_mesh_node(
		"HullEngineDeck",
		_box(Vector3(hull_width * 0.72, 0.07, (rear_z - upper_front_z) * 0.32)),
		base,
		Transform3D(Basis(), Vector3(0.0, hull_height + 0.03, rear_z * 0.62))
	))

	# Кольцо погона — просто деталь силуэта: башня кренится вместе с корпусом (она под этим же
	# пивотом), поэтому донце башни всегда лежит на палубе заподлицо и никакого зазора между ними
	# нет. Юбка `TurretSkirt` из Tank.tscn утоплена в кольцо и прикрывает стык по кругу.
	var ring := CylinderMesh.new()
	ring.top_radius = hull_width * 0.25
	ring.bottom_radius = hull_width * 0.27
	ring.height = 0.14
	ring.radial_segments = 16
	_adopt(_mesh_node("TurretRing", ring, base, Transform3D(Basis(), Vector3(0.0, hull_height - 0.03, 0.0))))

func _build_side(sign_x: float, side: String, out_wheels: Array[Node3D]) -> void:
	var x: float = sign_x * track_gauge
	var zc: float = _straight_half()
	var radius: float = _wheel_radius()

	# Ведущее колесо (корма) и ленивец (нос) стоят ровно в центрах дуг ленты; опорные катки
	# распределены между ними.
	var positions: Array[float] = [zc, -zc]
	var span: float = zc * 0.78
	for i in road_wheel_count:
		var t: float = 0.5 if road_wheel_count == 1 else float(i) / float(road_wheel_count - 1)
		positions.append(lerpf(-span, span, t))

	for i in positions.size():
		var wheel := Node3D.new()
		wheel.name = "Wheel%s%d" % [side, i]
		wheel.position = Vector3(x, track_radius, positions[i])
		_adopt(wheel)
		out_wheels.append(wheel)

		var tyre := CylinderMesh.new()
		tyre.top_radius = radius
		tyre.bottom_radius = radius
		tyre.height = wheel_width
		tyre.radial_segments = 8 if i < 2 else 12  # ведущее/ленивец «зубчатые» — отличимы на глаз
		# Ось цилиндра по умолчанию +Y; кладём её вдоль X поворотом на −90° вокруг Z.
		wheel.add_child(_mesh_node(
			"WheelTyre", tyre, wheel_color, Transform3D(Basis(Vector3.BACK, -PI * 0.5), Vector3.ZERO)
		))
		# Спица-маркер: без неё вращение гладкого катка на глаз не читается вообще.
		wheel.add_child(_mesh_node(
			"WheelMarker",
			_box(Vector3(0.012, radius * 1.6, 0.05)),
			wheel_marker_color,
			Transform3D(Basis(), Vector3(sign_x * (wheel_width * 0.5 + 0.006), 0.0, 0.0))
		))

	var track := MultiMeshInstance3D.new()
	track.name = "Track%s" % side
	track.position = Vector3(x, 0.0, 0.0)
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _box(Vector3(track_width, cleat_thickness, _track_perimeter() / float(cleat_count) * 0.78))
	multimesh.instance_count = cleat_count
	track.multimesh = multimesh
	var track_material := StandardMaterial3D.new()
	track_material.albedo_color = track_color
	track.material_override = track_material
	_adopt(track)
	if sign_x < 0.0:
		_track_left = track
	else:
		_track_right = track
	_update_track_mesh(track, 0.0)

## Все визуальные потомки корпуса — GeometryInstance3D, а не только MeshInstance3D: гусеницы это
## MultiMeshInstance3D, и в списке они нужны наравне с остальными (рентген-материал маскировки).
## Потребители: disguise_controller.gd (рентген-силуэт игрока) и tank.gd (покраска по команде,
## она сама отсеивает ходовую по префиксу имени).
func visual_meshes() -> Array:
	var result: Array = []
	_collect_visuals(self, result)
	return result

func _collect_visuals(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is GeometryInstance3D:
			out.append(child)
		_collect_visuals(child, out)
