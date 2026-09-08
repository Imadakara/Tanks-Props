extends Node
## TankMovement — гусеничное движение танка: вперёд/назад + поворот корпуса.
## Источник ввода зависит от is_player_controlled: игрок — Input Actions, бот —
## ai_move_input/ai_turn_input, которые пишет TankAIController (единственный ИИ проекта, см.
## scenes/tank/tank_ai_controller.gd), не дублируя эту ноду отдельным путём движения.

@export var move_speed: float = 6.0
@export var acceleration: float = 12.0  # м/с² — разгон/торможение линейной скорости (не мгновенное применение)
@export var turn_speed: float = 2.0  # рад/сек
@export var is_player_controlled: bool = true

## Зависимость скорости от уклона: в горку медленнее, под горку быстрее (см.
## _slope_speed_multiplier). Работает и у игрока, и у ботов — это общий путь движения. На плоских
## картах спит целиком (нормаль пола вертикальна → множитель ровно 1.0), смысл имеет только там,
## где есть пандусы/рельеф: кухня и полигон испытаний.
@export var slope_speed_enabled: bool = true
## Насколько сильно уклон влияет: множитель = 1 − sin(уклон) * это. При 0.9 подъём в 24° стоит
## примерно 63% скорости (было 1.1 → ~45%: на крейсерском газу бот полз по межъярусным рампам
## кухни так медленно, что это читалось как «подвисание на кромке»).
@export var slope_speed_penalty: float = 0.9
## Границы множителя. Нижняя — чтобы танк на подъёме не полз (было 0.5 — заметный краул на газу
## бота); верхняя — чтобы спуск не превращался в неуправляемый разгон.
@export var slope_speed_min_mult: float = 0.65
@export var slope_speed_max_mult: float = 1.15

## Свес над обрывом. CharacterBody3D.is_on_floor() — бинарный «есть контакт»: пока ХОТЬ ОДНО ребро
## коробчатого коллайдера лежит на кромке площадки, танк «на земле» и не падает, даже вывесив
## 3/4 корпуса над пропастью (корень танка вдобавок никогда не кренится — см. hull_rig.gd, — так
## что и завалиться через кромку сам он не может). Поэтому опору считаем сами: четыре луча вниз по
## углам опорного прямоугольника; строим из найденных углов опорный многоугольник и проверяем,
## накрывает ли он ВЕРТИКАЛЬНУЮ проекцию центра масс (с поправкой на уклон опоры — см.
## _update_support). Не накрывает — включаем гравитацию, даже когда движок ещё рапортует
## is_on_floor(), и танк съезжает/валится с кромки; ушёл за кромку безвозвратно — TumbleController
## перехватывает и роняет танк по-настоящему (кувырок, вплоть до лёжки на боку/крыше).
## Работает и у игрока, и у ботов (общий путь движения). На плоских картах спит: все лучи находят
## пол, все 4 угла держат → опора стабильна → поведение байт-в-байт как раньше.
@export var ledge_support_enabled: bool = true
## Центр масс в СИСТЕМЕ КОРНЯ (локальный). Ниже геометрического центра и чуть к корме — тяжёлые
## корпус и ходовая. Определяет, когда танк теряет опору на кромке и с какой энергией уходит в
## кувырок (высокий ЦМ — легче опрокидывается). Физическая константа, не баланс-крутилка.
@export var center_of_mass: Vector3 = Vector3(0.0, 0.18, 0.06)
## Поправка на уклон: горизонтальный снос вертикали ЦМ вниз по склону = center_of_mass.y·tan(уклон)
## опоры. На спуске у кромки танк теряет опору раньше — ровно этого и ждут от «учёта наклона».
@export var com_slope_shift_enabled: bool = true
## Угол (град), круче которого провал под углом коллайдера считается ОБРЫВОМ, а не склоном.
## Луч добивает вниз на probe_up + tan(этот угол)·(вынос угла от центра) + ledge_slack; пол ниже
## этого — не опора. Должен быть ЗАМЕТНО круче предельного проходимого пандуса (~44-45°, см.
## Tank_Chassis §10), иначе танк на крутом подъёме примет свой же спуск под кормой за обрыв и
## встанет. Обратная сторона: провал МЕЛЬЧЕ, чем даёт этот угол на выносе луча (порядка метра),
## механика игнорирует — это про пропасти, не про бордюры.
@export var ledge_max_slope_deg: float = 50.0
## Допуск к длине добивания луча (м) — гасит дрожание на стыках пандусов.
@export var ledge_slack: float = 0.15
## Доля полуразмеров коллайдера, на которой стоят лучи (1.0 — ровно углы). < 1 — танк начинает
## валиться чуть РАНЬШЕ геометрической середины свеса, что ощущается честнее.
@export var ledge_probe_inset: float = 0.82
## Разрыв уже этого (м) — это СТЫК (между элементами мебели, рампа лежит на кромке столешницы), а
## не обрыв: щуп края переступает через него и марш продолжается. Иначе стык читался бы как кромка,
## танк на кадр уходил в стадию TEETER и получал рывок вперёд + клевок.
@export var ledge_gap_tolerance: float = 0.5

## АССИСТ «перевалить порожек» — толерантность ходовой к резким перепадам высоты. Коробчатый танк
## (даже с фаской нижних рёбер) носом упирается в вертикальную грань: подошва рампы чуть выше
## подъездной поверхности, стык плит гарнитура, край столешницы под рампой. Если прямо по курсу
## низкая грань, а над ней проходимая поверхность в пределах step_up_max — приподнимаем корпус на
## неё. Особенно важно для ботов, ползущих на крейсерском газу.
@export var step_up_enabled: bool = true
## Максимальная высота порожка, который ассист переваливает (м). Держать МЕНЬШЕ высоты, на которую
## танк не должен «запрыгивать» сам (ящики Obstacle и т.п. заведомо выше).
@export var step_up_max: float = 0.35
## Высота лобового щупа грани (м, «щиколотка» коллайдера) и его вынос вперёд за нос.
@export var step_up_probe_y: float = 0.16
@export var step_up_probe_dist: float = 0.75
## ПЛАВНЫЙ ЗАВАЛ ЧЕРЕЗ КРОМКУ и ТОЧКА НЕВОЗВРАТА — три стадии, без резких переключений.
##
## 1. BRINK (подход к краю). Пока вертикаль ЦМ подходит к границе опоры (в пределах
##    `teeter_brink_margin`, но ещё ВНУТРИ), танк САМ притормаживает (`teeter_brake`) и корпус
##    ПЛАВНО кренится носом до `teeter_prelean_deg` — понятный сигнал «край рядом». РУЛЬ РАБОТАЕТ:
##    можно отвернуть или сдать назад, крен сам уйдёт.
## 2. TEETER (ЦМ уже за опорой). Крен интегрируется дальше от `teeter_prelean_deg` вверх:
##    гравитация валит (момент ∝ `_com_margin`), реверс «от пропасти» — вытягивает, плюс
##    демпфирование. РУЛЬ отключён, есть снос к пустоте. Всё ещё ОБРАТИМО: сдал назад → ЦМ
##    вернулся на опору → крен затух → обычная езда, БЕЗ смены камеры и заморозки.
## 3. `_tip_angle` дорос до `teeter_ponr_deg` → ТОЧКА НЕВОЗВРАТА: управление уходит в
##    TumbleController (кувырок) с той же угловой скоростью `_tip_vel` — без визуального рывка.
@export var teeter_ponr_deg: float = 26.0
## Зона «край рядом»: на сколько метров ДО границы опоры начинается торможение и пред-крен.
@export var teeter_brink_margin: float = 0.85
## Максимальный пред-крен корпуса в стадии BRINK (град), пока ЦМ ещё на опоре.
@export var teeter_prelean_deg: float = 7.0
## Насколько срезать ХОД ВПЕРЁД у самого края (0 — не трогать, 1 — до нуля на границе опоры).
@export var teeter_brake: float = 0.75
## рад/с² на метр выхода ЦМ за опору — насколько быстро гравитация валит корпус в стадии TEETER.
@export var teeter_gravity_gain: float = 10.0
## рад/с² при полном ходе «от пропасти» — насколько быстро игрок вытягивает корпус обратно.
@export var teeter_recover_gain: float = 11.0
## Демпфирование `_tip_vel`, 1/с.
@export var teeter_damping: float = 2.5
## Снос к пустоте в стадии TEETER (м/с), нарастает от 0 пропорционально `_tip_angle`.
@export var teeter_forward_drift: float = 1.6
## Столько секунд «в воздухе без пола под центром» ещё считаются прыжком (крен не растёт). Дольше
## — это не прыжок (сорвался/столкнули/телепорт над пустотой): начинаем валить в кувырок.
@export var jump_grace_sec: float = 0.5
## Потолок закрутки, передаваемой в кувырок (рад/с). Двойнику отдаётся ТОЛЬКО реально накопленная
## в фазе TEETER скорость завала `_tip_vel`, зажатая этим — никакой искусственной «драматизации».
## Дальше — свободное падение: что будет с танком, решают гравитация, инерция и удар о землю.
## Держать небольшим (≈1 рад/с): при падении ~0.8 с это ≈45° доворота, танк успевает встать на
## гусеницы, если траектория позволяет. Больше — почти гарантированное приземление на крышу.
@export var tumble_spin_max: float = 0.8

## Программный ввод для ботов — TankAIController пишет сюда каждый кадр перед тем,
## как эта нода их считает. Не используется, если is_player_controlled=true.
var ai_move_input: float = 0.0
var ai_turn_input: float = 0.0

## Последнее применённое значение move_input — читает CameraRig, чтобы обнаружить задний
## ход и плавно довернуть камеру за корму (GTA-style), не завязываясь на Input напрямую
## (актуально и для ботов, если им когда-нибудь понадобится та же логика).
var last_move_input: float = 0.0

const TankStateMachineScript := preload("res://scenes/tank/tank_state_machine.gd")

@onready var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

var _body: CharacterBody3D
var _state_machine: Node
var _mod: Node
var _health: Node
var _tumble: Node  # TumbleController — перехватывает управление на безвозвратном свесе

## Урон от падения (см. _track_fall_damage). Живёт ЗДЕСЬ, а не отдельным компонентом: только этот
## узел уже владеет вертикальной скоростью/гравитацией танка и знает про is_on_floor() — отдельный
## сиблинг дублировал бы то же самое состояние. Актуально на многоуровневых картах (кухня); на
## плоских танк с высоты не падает вовсе, механика просто спит.
var _fall_peak_y: float = 0.0
var _airborne: bool = false

## Опора под гусеницами в этом кадре (см. _update_support / ledge_support_*). Читается hull_rig.gd
## для визуального завала корпуса через кромку и test_ground.gd для табло. Только чтение снаружи.
var _support_stable: bool = true
## Знаковый зазор вертикали ЦМ до КРАЯ ОПОРЫ (м): < 0 — ЦМ на опоре (столько запаса до
## ближайшего края), > 0 — уже за краем. Считается направленными лучами-«щупами» края
## (_update_support), меняется ПЛАВНО по мере подъезда к кромке. Питает и BRINK, и TEETER.
var _com_margin: float = -1.5
## maxf(0, _com_margin) — для табло/совместимости.
var _com_escape: float = 0.0
## Есть ли пол прямо под центром танка (для проверки «ушёл в воздух»).
var _center_grounded: bool = true
## Текущий угол завала корпуса через кромку (рад) и его угловая скорость. Дорос до
## deg_to_rad(teeter_ponr_deg) — точка невозврата, уходим в кувырок. Вернулся к 0 — обычная езда.
var _tip_angle: float = 0.0
var _tip_vel: float = 0.0
## Время без пола под центром (сброс на _center_grounded). > jump_grace_sec — уже не прыжок.
var _airborne_time: float = 0.0
## Близость ЦМ к границе опоры, 0..1 (0 — далеко, 1 — на границе/за ней). Стадия BRINK: тормоз +
## пред-крен, РУЛЬ РАБОТАЕТ. Считается в _update_support.
var _edge_approach: float = 0.0
## Был ли танк в стадии TEETER (для случая «ушёл в воздух ПОСЛЕ заваливания» — кувырок, не прыжок).
var _was_tipping: bool = false
## Единичный вектор в СИСТЕМЕ КОРНЯ (XZ) к ближайшему краю опоры — куда танк валится/съезжает.
## Zero, если край далеко.
var tip_dir: Vector3 = Vector3.ZERO
## Дефолтная длина «прилипания» к полу — снимаем её на кадры свеса, чтобы тело реально сошло с
## кромки, а не было притянуто обратно.
var _default_snap: float = 0.1

## Направления «щупов» края в системе корня: вперёд/назад/влево/вправо (−Z = вперёд).
const _EDGE_DIRS := [Vector3(0, 0, -1), Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(1, 0, 0)]
const _EDGE_MARCH_STEP := 0.2
const _EDGE_MARCH_MAX := 1.3
## Высота горизонтального луча-детектора стены (сер. корпуса) — над полом, но в габарите стены.
const _WALL_PROBE_Y := 0.3
## Старт вертикального «щупа» поднимается с выносом: тангенс угла, круче которого подъём считаем
## подъездом-в-стену (> предельного проходимого пандуса ~45°), чтобы луч на выносе 1.3 м не
## стартовал ПОД полотном крутого пандуса и не давал ложный край.
const _EDGE_CLIMB_TAN := 1.05  # ~46°
## Глубина луча «есть ли пол под центром». Должна покрывать зазор центра танка над полотном на
## предельном пандусе (~half_length·tan(45°) ≈ 0.9 + фаска), но быть НАМНОГО меньше любого обрыва.
const _CENTER_REACH_DOWN := 1.3
## Старт луча ВЫШЕ опорной плоскости — должен перекрывать подъём точки замера на предельном
## проходимом пандусе (иначе луч стартует под полотном и «повисает», давая ложный обрыв).
const _SUPPORT_PROBE_UP := 1.0

func _ready() -> void:
	_body = get_parent() as CharacterBody3D
	assert(_body != null, "TankMovement must be a direct child of a CharacterBody3D")
	_state_machine = get_parent().get_node_or_null("TankStateMachine")
	_mod = get_parent().get_node_or_null("ModificationController")
	_health = get_parent().get_node_or_null("HealthComponent")
	_tumble = get_parent().get_node_or_null("TumbleController")
	_default_snap = _body.floor_snap_length
	_fall_peak_y = _body.global_position.y
	# Респавн телепортирует танк (возможно, с большой высоты вниз) — без сброса отсчёта приземление
	# на своей базе засчиталось бы как падение с той высоты, где танк погиб.
	var respawn: Node = get_parent().get_node_or_null("RespawnController")
	if respawn != null:
		respawn.respawned.connect(_on_respawned)
	# Возврат управления после кувырка — тот же сброс отсчёта падения, что и на респавне.
	if _tumble != null:
		_tumble.recovered.connect(_on_respawned)

func _on_respawned() -> void:
	_airborne = false
	_fall_peak_y = _body.global_position.y
	_tip_angle = 0.0
	_tip_vel = 0.0
	_airborne_time = 0.0
	_edge_approach = 0.0
	_was_tipping = false

func _physics_process(delta: float) -> void:
	var turn_input: float
	var move_input: float
	if is_player_controlled:
		turn_input = Input.get_axis("turn_left", "turn_right")
		move_input = Input.get_axis("move_backward", "move_forward")
	else:
		turn_input = ai_turn_input
		move_input = ai_move_input
	last_move_input = move_input

	# Кувырок уже идёт (TumbleController ведёт двойника и телепортирует корень) — эта нода молчит.
	# Она к тому же заморожена по process_mode, это лишь страховка на кадр входа/выхода.
	if _tumble != null and _tumble.is_active():
		return

	# Опору считаем КАЖДЫЙ кадр и ДО заморозок корпуса: сорвавшийся с кромки танк должен валиться,
	# даже если он замаскирован или целится мортирой.
	_update_support(delta)
	_integrate_teeter(delta, move_input)
	# TEETER (руль отключён, снос к пустоте) — только когда ЦМ УЖЕ за краем опоры, либо крен ещё
	# не спал после этого. Стадия BRINK (_com_margin < 0, крен = пред-крен ≤ teeter_prelean_deg) —
	# это НЕ teetering: руль работает, только тормоз у края.
	var teetering: bool = _com_margin >= 0.0 or _tip_angle > deg_to_rad(teeter_prelean_deg + 3.0)

	var mod_frozen: bool = _mod != null and _mod.blocks_hull_movement()
	var disguised: bool = _state_machine != null \
		and _state_machine.state == TankStateMachineScript.State.DISGUISED

	if not teetering:
		# Модификация может замораживать корпус (мортира — на время прицеливания). Выход из режима
		# по клавише движения ловит сам mortar_behavior._unhandled_input, здесь только стоп.
		if mod_frozen:
			last_move_input = 0.0
			return
		# Корпус зафиксирован во время маскировки; попытка движения — триггер досрочного снятия.
		if disguised:
			if turn_input != 0.0 or move_input != 0.0:
				_state_machine.break_disguise("movement")
			return
	elif disguised:
		# Кренится через кромку в маскировке — маскировка не спасает, слетает.
		_state_machine.break_disguise("fell")

	# ТОЧКА НЕВОЗВРАТА: крен дорос до предела ЛИБО танк ушёл в воздух уже заваливаясь (не прыжок) и
	# крен успел перевалить площадку пред-крена. Управление уходит в TumbleController — с текущей
	# угловой скоростью крена, без рывка.
	if _tumble != null and (_tip_angle >= deg_to_rad(teeter_ponr_deg) \
			or (not _center_grounded and (_was_tipping or _airborne_time > jump_grace_sec) \
				and _tip_angle > deg_to_rad(teeter_prelean_deg + 4.0))):
		_tumble.start_tumble(_body.velocity, _tumble_spin_seed())
		return

	var forward: Vector3 = -_body.global_transform.basis.z

	if _body.is_on_floor() and not teetering:
		_body.velocity.y = 0.0
	else:
		_body.velocity.y -= _gravity * delta

	if not teetering:
		_body.rotate_y(-turn_input * turn_speed * delta)
		# Стадия BRINK: у самого края СРЕЗАЕМ ход «к пустоте» (не «от неё») пропорционально
		# _edge_approach — танк сам притормаживает, давая время отвернуть/сдать назад.
		var eff_move: float = move_input
		if move_input != 0.0 and _edge_approach > 0.0 and not tip_dir.is_zero_approx():
			var toward_void: float = signf(move_input * (-tip_dir.z))
			if toward_void > 0.0:
				# Тормоз ограничен снизу — упорный игрок всё же переедет край (и уйдёт в кувырок).
				eff_move *= maxf(1.0 - _edge_approach * teeter_brake, 0.4)
		var target_horizontal: Vector3 = forward * eff_move * _effective_move_speed() \
			* _slope_speed_multiplier(forward * signf(eff_move))
		var current_horizontal := Vector3(_body.velocity.x, 0.0, _body.velocity.z)
		var new_horizontal: Vector3 = current_horizontal.move_toward(target_horizontal, acceleration * delta)
		_body.velocity.x = new_horizontal.x
		_body.velocity.z = new_horizontal.z
	else:
		# TEETER: РУЛЬ отключён, но ГАЗ работает — можно сдать назад и вытянуть корпус с кромки.
		# Плюс снос к пустоте, нарастающий с углом крена (нос перевешивает всё сильнее).
		var drift: Vector3 = _body.global_transform.basis * tip_dir
		drift.y = 0.0
		drift = drift.normalized()
		var t_frac: float = clampf(_tip_angle / deg_to_rad(teeter_ponr_deg), 0.0, 1.0)
		var thr: Vector3 = forward * move_input * _effective_move_speed()
		var target_h: Vector3 = thr + drift * (t_frac * teeter_forward_drift)
		var cur_h := Vector3(_body.velocity.x, 0.0, _body.velocity.z)
		var new_h: Vector3 = cur_h.move_toward(target_h, acceleration * delta)
		_body.velocity.x = new_h.x
		_body.velocity.z = new_h.z

	# «Прилипание» к полу тянет тело обратно на кромку — снимаем на время крена.
	_body.floor_snap_length = 0.0 if teetering else _default_snap

	var right: Vector3 = _body.global_transform.basis.x
	var pos_before: Vector3 = _body.global_position
	_body.move_and_slide()

	# Танк гусеничный, боком не ездит (см. CLAUDE.md): гасим боковую составляющую фактического
	# смещения. НЕ во время крена — там горизонтальное смещение легитимно (танк съезжает).
	if not teetering:
		var actual_delta: Vector3 = _body.global_position - pos_before
		var lateral_delta: float = actual_delta.dot(right)
		_body.global_position -= right * lateral_delta
		_body.velocity -= right * right.dot(_body.velocity)
		# Ассист «перевалить порожек»: коробчатый танк упёрся носом в низкую грань (подошва рампы,
		# стык плит гарнитура, край столешницы под рампой) — если продвинулся заметно меньше
		# заказанного, а над гранью есть проходимая поверхность, приподнимаем корпус на неё.
		var wanted: float = absf(move_input) * _effective_move_speed() * delta
		var got: float = absf(actual_delta.dot(forward))
		if step_up_enabled and move_input != 0.0 and wanted > 0.02 and got < wanted * 0.5:
			_try_step_up(forward * signf(move_input))

	_track_fall_damage()

## Приподнять корпус на низкий порожек прямо по курсу (толерантность ходовой к перепадам высоты).
## `tdir` — горизонтальное единичное направление движения (world).
func _try_step_up(tdir: Vector3) -> void:
	var space: PhysicsDirectSpaceState3D = _body.get_world_3d().direct_space_state
	var base_y: float = _body.global_position.y
	# Лобовой щуп на «щиколотке»: есть ли прямо по курсу вертикальная грань?
	var lo_from: Vector3 = _body.global_position + Vector3(0.0, step_up_probe_y, 0.0)
	var lo := PhysicsRayQueryParameters3D.create(lo_from, lo_from + tdir * step_up_probe_dist, 1)
	lo.exclude = [_body.get_rid()]
	var lohit: Dictionary = space.intersect_ray(lo)
	if lohit.is_empty():
		return
	var face_n: Vector3 = lohit.get("normal", Vector3.UP)
	if absf(face_n.y) > 0.6:  # не грань, а пологая поверхность — обычный склон, не трогаем
		return
	# Верх этого порожка — луч вниз чуть за гранью.
	var probe: Vector3 = (lohit["position"] as Vector3) + tdir * 0.08
	var top := PhysicsRayQueryParameters3D.create(
		probe + Vector3(0.0, step_up_max + 0.1, 0.0), probe + Vector3(0.0, -0.1, 0.0), 1)
	top.exclude = [_body.get_rid()]
	var thit: Dictionary = space.intersect_ray(top)
	if thit.is_empty():
		return
	if (thit.get("normal", Vector3.UP) as Vector3).y < 0.6:  # верх непроходимый
		return
	var step_h: float = (thit["position"] as Vector3).y - base_y
	if step_h > 0.03 and step_h <= step_up_max:
		_body.global_position.y = base_y + step_h + 0.02

## Крен корпуса через кромку.
## BRINK (`_com_margin` < 0, ЦМ ещё на опоре): крен = пол `_edge_approach·teeter_prelean_deg` —
##   косметический пред-крен, полностью снимается, если отъехать (`_edge_approach` падает).
## TEETER (`_com_margin` ≥ 0): интегрируем угловую скорость `_tip_vel` — гравитация валит
##   (момент ∝ `_com_margin`, зажат ±: снаружи ≤ 1.1 чтобы нарастало предсказуемо, изнутри ≥ −0.7
##   чтобы при возврате ЦМ на опору крен активно гас), реверс «от пропасти» вычитается, плюс
##   демпфирование. Итоговый угол — максимум из проинтегрированного и пред-крена (плавная стыковка).
func _integrate_teeter(delta: float, move_input: float) -> void:
	if delta <= 0.0:
		return
	_airborne_time = 0.0 if _center_grounded else _airborne_time + delta
	# «Это не прыжок, а заваливание» — либо был BRINK (_was_tipping), либо слишком долго без пола
	# под центром (сорвался/столкнули/телепорт над пустотой). Короткий прыжок с трамплина — нет.
	var committed: bool = _was_tipping or _airborne_time > jump_grace_sec
	var jump_not_tip: bool = not _center_grounded and not committed
	var torque: float = 0.0
	if not jump_not_tip:
		torque = clampf(_com_margin, -0.7, 1.1) * teeter_gravity_gain
		# `tip_dir` (лок.) — к краю; ход «от него» = move_input против проекции tip_dir на forward.
		var away: float = clampf(move_input * tip_dir.z, 0.0, 1.0)  # tip_dir.z<0 (край впереди) + реверс
		torque -= away * teeter_recover_gain
	_tip_vel += torque * delta
	_tip_vel -= _tip_vel * teeter_damping * delta
	var integrated: float = clampf(_tip_angle + _tip_vel * delta, 0.0, deg_to_rad(teeter_ponr_deg) * 1.5)
	var prelean: float = _edge_approach * deg_to_rad(teeter_prelean_deg) \
		if (_com_margin < 0.0 and _center_grounded) else 0.0
	_tip_angle = maxf(integrated, prelean)
	if _tip_angle <= 0.0001:
		_tip_vel = maxf(_tip_vel, 0.0)  # на ровном не копим отрицательную скорость
	# «Идёт заваливание через кромку» (а не прыжок). Ставится, пока центр ещё на опоре, при явном
	# подъезде к краю (BRINK: _edge_approach высок, пред-крен пошёл) ЛИБО когда ЦМ уже за краем.
	# У прыжка с трамплина _edge_approach ≈ 0 (взлёт с ровного) — флаг не встанет.
	# Снимается, как только танк снова уверенно на опоре (сдал назад с кромки).
	if _center_grounded and (_com_margin >= 0.0 \
			or (_edge_approach > 0.5 and _tip_angle > deg_to_rad(4.0))):
		_was_tipping = true
	elif _support_stable and _edge_approach < 0.35:
		_was_tipping = false

## Опора и близость к краю — направленными «щупами» в системе КОРНЯ (корень всегда вертикален).
## В четырёх направлениях (вперёд/назад/влево/вправо) шагаем от центра наружу короткими лучами
## вниз и находим, на каком выносе кончается пол (`edge[d]`). Луч засчитывает пол, только если тот
## не глубже, чем даёт `ledge_max_slope_deg` на этом выносе — спуск это склон, обрыв это край.
## `clearance[d]` = `edge[d]` минус вынос ЦМ в ту сторону; со сносом ЦМ вниз по склону
## (`center_of_mass.y·tan(уклон)`, нормаль — среднее по попаданиям). `_com_margin = −min(clearance)`:
## < 0 — ЦМ на опоре (столько запаса), > 0 — уже за краем. Меняется ПЛАВНО по мере подъезда, а не
## скачком — на этом стоит и BRINK, и TEETER. `_edge_approach` (0..1) — сглаженная близость к краю.
func _update_support(delta: float) -> void:
	if not ledge_support_enabled:
		_support_stable = true
		_center_grounded = true
		_com_margin = -1.5
		_com_escape = 0.0
		_edge_approach = 0.0
		tip_dir = Vector3.ZERO
		return
	var space: PhysicsDirectSpaceState3D = _body.get_world_3d().direct_space_state
	var xf: Transform3D = _body.global_transform
	# Провал круче ledge_max_slope_deg на выносе от центра — край, а не склон.
	var slope_tan: float = tan(deg_to_rad(ledge_max_slope_deg))
	var normal_sum := Vector3.ZERO
	var normal_hits: int = 0

	# Пол под центром + его нормаль. Широкое вертикальное окно: танк, «вздёрнутый» носом на крутом
	# (до 45°) пандусе, висит центром заметно над полотном — узкий луч давал ложное «в воздухе».
	# Обрыв же — это провал НАМНОГО глубже _CENTER_REACH_DOWN.
	var cq := PhysicsRayQueryParameters3D.create(
		xf * Vector3(0.0, _SUPPORT_PROBE_UP, 0.0),
		xf * Vector3(0.0, -_CENTER_REACH_DOWN, 0.0), 1)
	cq.exclude = [_body.get_rid()]
	var chit: Dictionary = space.intersect_ray(cq)
	_center_grounded = not chit.is_empty()
	if _center_grounded:
		normal_sum += chit.get("normal", Vector3.UP)
		normal_hits += 1

	# Вынос ЦМ в каждом из направлений (лок.): F −z, B +z, L −x, R +x.
	var com_off := [-center_of_mass.z, center_of_mass.z, -center_of_mass.x, center_of_mass.x]
	var clearance := [_EDGE_MARCH_MAX, _EDGE_MARCH_MAX, _EDGE_MARCH_MAX, _EDGE_MARCH_MAX]
	var raw_edge := [_EDGE_MARCH_MAX, _EDGE_MARCH_MAX, _EDGE_MARCH_MAX, _EDGE_MARCH_MAX]
	for d in 4:
		var dir: Vector3 = _EDGE_DIRS[d]
		var edge_dist: float = _EDGE_MARCH_MAX
		# Сначала ГОРИЗОНТАЛЬНЫЙ луч: если впереди СТЕНА (а не обрыв), вертикальный «щуп» стартовал
		# бы ВНУТРИ неё и вернул ложный край. Стена — направление считаем безопасным.
		var wall := PhysicsRayQueryParameters3D.create(
			xf * Vector3(0.0, _WALL_PROBE_Y, 0.0),
			xf * (dir * _EDGE_MARCH_MAX + Vector3(0.0, _WALL_PROBE_Y, 0.0)), 1)
		wall.exclude = [_body.get_rid()]
		if space.intersect_ray(wall).is_empty():
			var dist: float = _EDGE_MARCH_STEP
			while dist <= _EDGE_MARCH_MAX + 0.001:
				var base: Vector3 = dir * dist
				var up_start: float = _SUPPORT_PROBE_UP + _EDGE_CLIMB_TAN * dist
				# Нижняя граница добивания — не тоньше 0.6 м даже у самого центра: гасит дрожь на
				# стыках/переломах пандусов (там пол на кадр «проваливается» на пол-метра).
				var down_reach: float = maxf(slope_tan * dist, 0.6) + ledge_slack
				var q := PhysicsRayQueryParameters3D.create(
					xf * (base + Vector3(0.0, up_start, 0.0)),
					xf * (base + Vector3(0.0, -down_reach, 0.0)), 1)
				q.exclude = [_body.get_rid()]
				var h: Dictionary = space.intersect_ray(q)
				if h.is_empty():
					# Пропал пол — но это может быть СТЫК (мебель / рампа на кромке), не обрыв.
					# Пробуем дальше: если в пределах ledge_gap_tolerance пол снова есть — идём дальше.
					var resumed: bool = false
					var gd: float = dist + _EDGE_MARCH_STEP
					while gd <= dist + ledge_gap_tolerance + 0.001 and gd <= _EDGE_MARCH_MAX + 0.001:
						var gb: Vector3 = dir * gd
						var gq := PhysicsRayQueryParameters3D.create(
							xf * (gb + Vector3(0.0, _SUPPORT_PROBE_UP + _EDGE_CLIMB_TAN * gd, 0.0)),
							xf * (gb + Vector3(0.0, -(maxf(slope_tan * gd, 0.6) + ledge_slack), 0.0)), 1)
						gq.exclude = [_body.get_rid()]
						var gh: Dictionary = space.intersect_ray(gq)
						if not gh.is_empty():
							normal_sum += gh.get("normal", Vector3.UP)
							normal_hits += 1
							resumed = true
							break
						gd += _EDGE_MARCH_STEP
					if resumed:
						dist = gd + _EDGE_MARCH_STEP
						continue
					# Настоящий обрыв. Первый шаг без пола → край у центра (или позади).
					edge_dist = 0.0 if dist <= _EDGE_MARCH_STEP + 0.001 else dist - _EDGE_MARCH_STEP * 0.5
					break
				normal_sum += h.get("normal", Vector3.UP)
				normal_hits += 1
				dist += _EDGE_MARCH_STEP
		raw_edge[d] = edge_dist
		clearance[d] = edge_dist - com_off[d]

	# Снос ЦМ вниз по склону — уменьшает зазор в сторону спуска, добавляет к подъёму.
	if com_slope_shift_enabled and normal_hits > 0:
		var n: Vector3 = (normal_sum / float(normal_hits)).normalized()
		var tilt: float = acos(clampf(n.y, -1.0, 1.0))
		if tilt > 0.01:
			var dh_world := Vector3(-n.x, 0.0, -n.z)
			if dh_world.length() > 0.001:
				var dh_local: Vector3 = (xf.basis.inverse() * dh_world.normalized())
				var shift: float = center_of_mass.y * tan(tilt)
				for d in 4:
					clearance[d] -= _EDGE_DIRS[d].dot(dh_local) * shift

	var min_c: float = clearance[0]
	var grounded_dirs: int = 0
	for d in 4:
		if clearance[d] > 0.1:
			grounded_dirs += 1
		min_c = minf(min_c, clearance[d])
	if not _center_grounded:
		# Центр танка уже за краем — ЦМ ТОЧНО вне опоры. Насколько глубоко — грубо по тому,
		# сколько направлений ещё нащупали близкий пол (все мимо → почти в воздухе).
		_com_margin = 0.7 if grounded_dirs == 0 else 0.3
	else:
		_com_margin = -min_c
	_com_escape = maxf(0.0, _com_margin)
	_support_stable = _center_grounded and _com_margin < 0.0

	# Направление к ближайшему краю — по СЫРОМУ выносу пола (без ЦМ-смещения, иначе у самого края
	# шум `com_off` уводит вбок/назад). Если край близко со всех сторон (ушли за него) —
	# валимся туда, КУДА ЕДЕМ; стоим — куда смотрим.
	var min_e: float = minf(minf(raw_edge[0], raw_edge[1]), minf(raw_edge[2], raw_edge[3]))
	var near_cnt: int = 0
	var min_ei: int = 0
	for d in 4:
		if raw_edge[d] < min_e + 0.15:
			near_cnt += 1
		if raw_edge[d] < raw_edge[min_ei]:
			min_ei = d
	if min_e >= teeter_brink_margin and _center_grounded:
		tip_dir = Vector3.ZERO
	elif _tip_angle > 0.02:
		pass  # уже кренимся — держим ПРЕЖНЕЕ направление к пропасти (иначе реверс его развернёт)
	elif near_cnt >= 3 or not _center_grounded:
		var v := Vector3(_body.velocity.x, 0.0, _body.velocity.z)
		var vd: Vector3 = (xf.basis.inverse() * v) if v.length() > 0.4 else Vector3(0.0, 0.0, -1.0)
		tip_dir = _nearest_cardinal(vd)
	else:
		tip_dir = _EDGE_DIRS[min_ei]

	var approach_target: float = clampf(
		inverse_lerp(-teeter_brink_margin, 0.0, _com_margin), 0.0, 1.0)
	_edge_approach = lerpf(_edge_approach, approach_target, 1.0 - exp(-12.0 * delta))

## Ближайший из четырёх кардинальных векторов (_EDGE_DIRS) к горизонтальному вектору v (лок.).
func _nearest_cardinal(v: Vector3) -> Vector3:
	if absf(v.z) >= absf(v.x):
		return Vector3(0.0, 0.0, -1.0) if v.z < 0.0 else Vector3(0.0, 0.0, 1.0)
	return Vector3(-1.0, 0.0, 0.0) if v.x < 0.0 else Vector3(1.0, 0.0, 0.0)

## Закрутка «через кромку», передаваемая двойнику: ось — горизонталь поперёк направления падения,
## модуль — РЕАЛЬНО накопленная в фазе TEETER скорость завала `_tip_vel` (непрерывность: кувырок
## продолжает то же вращение, без рывка), зажатая `tumble_spin_max`. Ничего искусственного сверху
## не добавляем: дальше свободное падение, и приземлится танк на гусеницы или на крышу — решает
## физика (траектория, инерция, низкий центр масс двойника, удар о землю), а не этот сид.
func _tumble_spin_seed() -> Vector3:
	var d: Vector3 = _body.global_transform.basis * tip_dir
	d.y = 0.0
	if d.length() < 0.05:
		d = -_body.global_transform.basis.z
		d.y = 0.0
	d = d.normalized()
	var axis: Vector3 = Vector3.UP.cross(d)
	if axis.length() < 0.01:
		axis = _body.global_transform.basis.x
	return axis.normalized() * clampf(_tip_vel, 0.0, tumble_spin_max)

## Кренится ли танк через кромку СЕЙЧАС (фаза teeter). Читают hull_rig.gd и test_ground.gd.
func is_falling() -> bool:
	return _tip_angle > 0.0005

## Текущий угол завала корпуса через кромку, рад (0 — ровно). Читает hull_rig.gd — рисует его.
func tip_angle() -> float:
	return _tip_angle

## Знаковый зазор ЦМ до края опоры (м): < 0 — на опоре, > 0 — за краем. Для табло полигона.
func com_margin() -> float:
	return _com_margin

## Сглаженная близость к краю опоры, 0..1 (стадия BRINK). Для табло.
func edge_approach() -> float:
	return _edge_approach

## Множитель скорости от уклона под гусеницами. Нормаль пола берётся у самого CharacterBody3D
## (get_floor_normal() — результат ПРОШЛОГО move_and_slide(), что для плавно меняющегося рельефа
## достаточно), а не своим лучом: незачем плодить второй источник правды о поверхности.
## `grade` = синус угла между направлением движения и опорной плоскостью: > 0 в горку, < 0 под
## горку, 0 на ровном. `travel_dir` — горизонтальный единичный вектор фактического хода (forward,
## развёрнутый на задний ход), поэтому задним ходом в горку танк тормозится ровно так же.
## Предел линейной скорости с учётом ГРУЗА в слоте модификации (см.
## Modification.carry_speed_multiplier). Пустой слот — ровно move_speed, поведение не меняется.
## Гружёный — медленнее: тяжёлый груз (контейнер режима экстракшена) заставляет носителя держаться
## своей команды и активнее пользоваться маскировкой, а не бежать в одиночку.
##
## Именно ПРЕДЕЛ, а не мгновенная скорость: разгон/торможение по-прежнему идут через acceleration,
## так что подбор груза на ходу не даёт рывка — танк плавно сбрасывает до нового предела.
## Складывается с уклоном (_slope_speed_multiplier) мультипликативно: гружёный в гору медленнее
## обоих эффектов по отдельности — это осознанно, подъём с грузом и должен быть тяжёлым.
func _effective_move_speed() -> float:
	if _mod == null:
		return move_speed
	return move_speed * _mod.carry_speed_multiplier()

func _slope_speed_multiplier(travel_dir: Vector3) -> float:
	if not slope_speed_enabled or not _body.is_on_floor():
		return 1.0
	var normal: Vector3 = _body.get_floor_normal()
	if normal.is_zero_approx():
		return 1.0
	var grade: float = -travel_dir.dot(normal)
	return clampf(1.0 - grade * slope_speed_penalty, slope_speed_min_mult, slope_speed_max_mult)

## Урон от падения: пока танк в воздухе — копим МАКСИМАЛЬНУЮ достигнутую высоту, на приземлении
## считаем перепад от неё до точки касания. Именно перепад, а не вертикальная скорость: скорость
## после отскока/скольжения по краю площадки занижена и недооценивает реальную высоту падения.
## Порог `fall_damage_min_height` глушит мелкие отрывы на стыках пандусов (танк регулярно на кадр
## теряет опору на переломе уклона — без порога это капало бы уроном на ровном месте).
## Урон идёт через обычный take_hit(killer = null): дебаг-бессмертие его гасит (как и любой другой
## урон), а ScoreManager смерть с killer == null не засчитывает никому — падение не «убийство».
func _track_fall_damage() -> void:
	var y: float = _body.global_position.y
	if _body.is_on_floor():
		if _airborne:
			_airborne = false
			_apply_fall_damage(_fall_peak_y - y)
		_fall_peak_y = y
		return
	_airborne = true
	_fall_peak_y = maxf(_fall_peak_y, y)

func _apply_fall_damage(drop: float) -> void:
	if _health == null or drop < GameConfig.fall_damage_min_height:
		return
	var damage: int = 1
	if drop >= GameConfig.fall_damage_3hp_height:
		damage = 3
	elif drop >= GameConfig.fall_damage_2hp_height:
		damage = 2
	_health.take_hit(null, damage)
