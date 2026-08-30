extends Node
## BotSentryController — тестовый ИИ для песочницы "Bot Arena" (scenes/bot_arena/BotArena.tscn).
## Отдельно от продакшен-ИИ scenes/tank/tank_ai_controller.gd (ТЗ §9, патруль/маскировка) —
## тот не трогаем.
##
## Модель обзора (v2, по прямому запросу — "как в других играх"): бот ВСЕГДА видит то, что перед
## корпусом, ПЛЮС то, куда сейчас физически повёрнута башня. Два независимых конуса, оба нужны
## для _can_see():
## - ГЛАВНЫЙ (look_cone_deg, радиус vision_range) — жёстко зафиксирован на направлении КОРПУСА
##   (_body.rotation.y), НЕ блуждает и не зависит от башни/взгляда вообще. Широкий (шире, чем был
##   раньше) — "видит противника перед собой" безусловно, пока цель физически в поле зрения и не
##   загорожена.
## - ПРИЦЕЛЬНЫЙ (secondary_cone_deg, тот же vision_range) — узкий, зафиксирован на РЕАЛЬНОМ
##   текущем угле башни (_body.rotation.y + _turret.rotation.y) — "или в направлении поворота
##   башни", как ствол/прицел в других танковых играх.
## Случайное блуждание (_wander()/_look_yaw, см. ниже) управляет ТОЛЬКО башней, никакого влияния
## на главный конус больше нет: сначала (в _pick_new_wander_target()) выбирается угол, куда нужно
## повернуться — тот самый "линией определяем угол", — затем TurretController.rotate_toward()
## физически доворачивает башню туда, и уже РЕАЛЬНЫЙ (не целевой) угол башни двигает прицельный
## конус. Раньше было наоборот (абстрактная "камера" мгновенно скакала на новый угол блуждания,
## двигая главный конус, а башня только физически догоняла её с задержкой) — эта версия проще и
## буквально соответствует тому, что игрок видит на экране: обзор бота = хулл-конус + туда, куда
## сейчас направлен ствол, без скрытой "невидимой камеры".
##
## РОЛЬ (role) + ДВИЖОК ВЫБОРА СТЕЙТА (_think()) — приоритет один и тот же для всех ролей:
##   1. Видна цель (только что замечена ЛИБО уже отслеживаемая и всё ещё видна) → DEFEND.
##   2. Иначе — "домашнее" поведение роли: ACHIEVER с расставленными вейпоинтами → PATROL;
##      KILLER — пока НЕ реализован (нет стейта "охота", см. дев-план ниже) → падает в IDLE,
##      это временная заглушка, не финальное поведение убийцы.
##   3. Нет вообще ничего подходящего (ACHIEVER без вейпоинтов на карте) → IDLE.
## Явный класс-приоритет, а не набор независимых if — переход между PATROL/IDLE и DEFEND всегда
## решается заново каждый think-тик, поэтому оба направления (заметил/потерял цель) идут через
## одну и ту же точку принятия решения, не рассинхронизируются.
##
## Стейты:
## - IDLE ("ожидание") — бот неподвижен, взгляд блуждает по всему кругу (360°, см. _wander()).
## - PATROL ("патруль") — бесконечное движение по вейпоинтам (см. ниже), взгляд блуждает С
##   УКЛОНОМ ВПЕРЁД (forward_look_bias) — чаще смотрит по ходу движения, реже — по сторонам/назад.
## - DEFEND ("оборона позиции") — стоит на месте, башня/взгляд каждый кадр наводятся на ЖИВУЮ
##   позицию цели, огонь по готовности прицела/дальности/боекомплекта.
## Обнаружил цель в PATROL/IDLE → мгновенно (в рамках think_interval_sec) переход в DEFEND,
## движение останавливается. Потерял цель (вышла из конуса/дальности/видимости, или уничтожена)
## → возврат к "домашнему" поведению роли (см. приоритет выше) — блуждание взгляда продолжается
## с текущего угла, вейпоинт-прогресс (индекс/выбранная точка внутри круга) не сбрасывается.
##
## Патруль по вейпоинтам — маркеры "WaypointN" (Node3D, ищутся по имени в корне текущей сцены,
## сортируются по имени — тот же принцип, что PatrolWaypointN у tank_ai_controller.gd). Каждый
## вейпоинт — не точка, а круглая область радиуса waypoint_radius: доехав до случайной точки
## внутри круга ТЕКУЩЕГО вейпоинта, бот выбирает новую случайную точку в круге СЛЕДУЮЩЕГО и едет
## дальше, по кругу бесконечно (индекс всегда % количество).
##
## Объезд препятствий ("лидар", см. _scan_obstacle_rays()/_compute_travel_yaw()) — ТРИ луча, все ИЗ
## ОДНОЙ ТОЧКИ (центр корпуса) — различаются только УГЛОМ, ни один не смещается физически в сторону:
## "center" качается вокруг направления на цель УГЛОМ, как и "left"/"right" (см.
## _advance_obstacle_sweep()), но амплитудой всего ±_center_sweep_max_deg — этот угол подобран так,
## чтобы на характерной дистанции center_sweep_ref_distance боковой охват качания равнялся
## hull_half_width (tan(угол) = hull_half_width / center_sweep_ref_distance). Луч ровно по центру
## иногда скользит впритык мимо узкого препятствия/угла, не хитуя, хотя корпус своей шириной его
## реально заденет — качающийся угол рано или поздно проходит и через то отклонение, которое
## соответствует задеванию препятствия корпусом. "left"/"right" качаются зеркально УГЛОМ между 0° и
## ±avoid_sweep_max_deg (как дворники), решают только "куда объезжать", не
## "перекрыто ли". Не статичный веер из многих одновременных лучей — сознательный выбор ради
## дешевизны на масштабе 10×10+ ботов (потенциально по сети — считать нужно на каждого бота
## каждый тик, а сами лучи по сети гонять не надо, реплицируется только результат): 3 raycast/кадр
## вместо 9 — заметно меньше аллокаций (Array/Dictionary на луч) при сопоставимом качестве решения.
## Если "center"-луч упирается в препятствие ближе avoid_trigger_range — бот переключается на объезд: выбирает
## сторону (лево/право — куда сейчас свободнее) один раз при входе в объезд (держит её, пока
## препятствие не пропадёт из виду — без этого «держания стороны» бот на симметричном препятствии
## дёргался бы то влево, то вправо каждый кадр), дальше едет на тот из двух лучей, что сейчас
## свободнее на выбранной стороне, вместо направления на цель. КРИТИЧНО: танк физически не может
## двигаться боком (только гусеницы — вперёд/назад + поворот корпуса), поэтому "объезд" — это
## ВСЕГДА смена желаемого угла поворота корпуса, а не какое-либо боковое смещение; сам разворот
## идёт тем же путём, что и обычная наводка на цель (ai_turn_input/ai_move_input, TankMovement).
##
## Реакция на обстрел: HealthComponent.damaged() несёт killer — при попадании (в любом стейте,
## кроме уже-DEFEND) бот разворачивает "камеру" в сторону выстрела; видна оттуда — сразу DEFEND.
##
## Архитектурная заметка (по прямому запросу): логика бота разрабатывается ЗДЕСЬ полностью и
## универсально (не завязана на конкретную геометрию этой тестовой карты, кроме положения
## конкретных вейпоинтов/objective, которые снаружи и так параметр карты) — расчёт на то, что для
## боевой карты она будет просто ПОДКЛЮЧЕНА, а не переписана заново; конкретные числа (сектор
## обзора, радиусы, etc.) — это настройка под тип objective/карту, не смена алгоритма.
##
## Дев-план (не реализовано в этом заходе, только заложены точки расширения):
## - Стейт HUNT (свободный поиск) и роль KILLER — сейчас KILLER это IDLE-заглушка.
## - Стейт PURSUE (преследование к последней видимой точке) — по ТЗ должен включаться у HARD
##   при потере цели ВМЕСТО возврата в PATROL/IDLE; сейчас HARD ведёт себя как EASY/MEDIUM
##   (_on_target_lost() ниже — единая точка, куда позже добавится ветка по difficulty).
##
## Уровни сложности (difficulty) — все числовые @export ниже это тюнинг MEDIUM (тот самый
## "текущий бот"), EASY/HARD — пресеты в _apply_difficulty_preset(), применяются поверх этих
## значений при _ready(). Чтобы поменять баланс MEDIUM — править сами @export; чтобы
## поменять EASY/HARD — саму таблицу _DIFFICULTY_PRESETS.

enum State { IDLE, PATROL, DEFEND }
enum Difficulty { EASY, MEDIUM, HARD }
enum Role { KILLER, ACHIEVER }

const _WANDER_ARRIVE_TOLERANCE_DEG := 3.0  # когда считать, что "камера" дошла до выбранного угла

@export var role: Role = Role.ACHIEVER
@export var difficulty: Difficulty = Difficulty.MEDIUM

## Радиус обзора (общий для обоих конусов) и полуширина ГЛАВНОГО конуса — жёстко на направлении
## корпуса, всегда активен, независимо от башни/блуждания (см. _can_see() и заголовок файла).
## Шире, чем в v1 (была движущаяся "камера") — по прямому запросу, "как в других играх".
@export var vision_range: float = 10.0
@export var look_cone_deg: float = 100.0  # полный угол конуса вокруг направления корпуса
@export var fire_range: float = 8.0
@export var fire_aim_tolerance_deg: float = 5.0

## ПРИЦЕЛЬНЫЙ сектор — узкий, зафиксирован на РЕАЛЬНОМ текущем угле башни (не на _look_yaw, куда
## башня только стремится, а именно на _turret.rotation.y — куда ствол физически повёрнут прямо
## сейчас). Даёт видеть цель в стороне/сзади корпуса, если бот как раз довернул туда башню
## (блуждание, слежение за целью, разворот на выстрел) — "или в направлении поворота башни".
## См. _can_see() — засчитывается, если цель попала В ЛЮБОЙ из двух секторов (главный ИЛИ этот).
@export var secondary_cone_deg: float = 15.0

## Обзор при блуждании (IDLE и, с уклоном, PATROL) — полный круг: следующий угол может быть
## любым (в т.ч. назад), но не ближе wander_min_turn_deg к текущему (см. _pick_new_wander_target()).
@export var wander_min_turn_deg: float = 30.0
@export var wander_hold_min_sec: float = 1.0  # задержка на выбранном угле после доворота
@export var wander_hold_max_sec: float = 2.0

## В PATROL взгляд чаще смотрит по ходу движения (вперёд по корпусу), а не куда попало —
## forward_look_bias — вероятность такого выбора при каждой смене угла, forward_look_cone_deg —
## ширина сектора "вперёд", внутри которого в этом случае ищется угол.
@export var forward_look_bias: float = 0.7
@export var forward_look_cone_deg: float = 70.0

## Патруль по вейпоинтам (см. заголовок файла).
@export var waypoint_radius: float = 7.5  # ~4.2 корпуса танка (корпус 1.8м) — область вокруг маркера
@export var waypoint_reach_dist: float = 1.5

## Объезд препятствий ("лидар" — 2 качающихся луча из центра корпуса, см. заголовок файла).
@export var avoid_sensor_range: float = 7.0  # макс. дальность луча
@export var avoid_trigger_range: float = 4.5  # ближе этого по лучу-к-цели — считаем путь перекрытым
@export var avoid_sweep_max_deg: float = 70.0  # качание от 0° до ±70° от направления корпуса
@export var avoid_sweep_speed_deg_per_sec: float = 240.0  # скорость качания — полный ход 0→70→0 за ~0.6с
## Полуширина корпуса (Tank.tscn: BoxShape3D 1.2×0.6×1.8 → ширина 1.2 → половина 0.6) — не смещение,
## а исходные данные для расчёта амплитуды качания "center"-луча УГЛОМ (см. _ready() и заголовок
## файла): amplitude_deg = atan(hull_half_width / center_sweep_ref_distance).
@export var hull_half_width: float = 0.6
## Дистанция, на которой боковой охват качания "center"-луча должен равняться hull_half_width —
## это примерно "перед носом корпуса", где грань препятствия, задевающая корпус впритык, чаще
## всего и оказывается в момент, когда её вообще стоит заметить.
@export var center_sweep_ref_distance: float = 2.0
@export var center_sweep_speed_deg_per_sec: float = 60.0  # полный ход -max..+max..-max за ~1.1-1.2с

## Резервный "антизастрял" — лучи есть только 3, а не 9, поэтому иногда (эмпирически ~1 раз из
## 3 на угле реального препятствия — Jolt в контакте с углом коробки не всегда стабильно даёт
## соскользнуть) корпус может физически залипнуть НЕ ЗАМЕТИВ этого через лучи (например, если оба
## качающихся луча в момент контакта смотрят мимо угла). Если едем (ai_move_input>0), но реальная
## скорость корпуса меньше stuck_min_speed дольше stuck_detect_sec — считаем застрявшим, коротко
## сдаём назад (stuck_reverse_sec), чтобы физически разорвать контакт, дальше обычная логика сама
## пересчитает объезд с чистого листа.
@export var stuck_detect_sec: float = 0.6
@export var stuck_reverse_sec: float = 0.4
@export var stuck_min_speed: float = 0.15

@export var think_interval_sec: float = 0.1  # реже физ.кадра — проверка "вижу/не вижу", не сама наводка
@export var turret_turn_speed: float = 1.0  # рад/сек — применяется на Turret при _ready() (см. turret_controller.gd), также скорость блуждания обзора

## Множитель к TankMovement.move_speed (см. _ready()) — по прямому запросу боты EASY/MEDIUM должны
## быть медленнее танка игрока, 0.75 = на 25% медленнее. HARD возвращает полную скорость игрока
## обратно в своём пресете (см. _DIFFICULTY_PRESETS) — сложность в первую очередь про осведомлённость
## и реакцию, не про то, что HARD-бот физически едет быстрее MEDIUM/EASY.
@export var move_speed_multiplier: float = 0.75

## Дистанция, ближе которой препятствие считается "практически вплотную" — резко доворачивать
## ВО ВРЕМЯ движения на такой дистанции реально задевает препятствие корпусом (шире, чем тонкий
## луч-датчик, который его засёк). См. _drive_to_waypoint() — на этой дистанции бот полностью
## останавливается и доворачивается НА МЕСТЕ (гусеницы это позволяют без всякого "обмана" — тот
## же принцип, что и обычный поворот корпуса), едет дальше только когда почти довернул.
@export var avoid_close_range: float = 1.5
@export var avoid_close_turn_tolerance_deg: float = 8.0

## Дебажная отрисовка (ImmediateMesh) поверх земли под ботом: веер — ГЛАВНЫЙ конус обзора
## (look_cone_deg, жёстко по направлению корпуса, радиус vision_range); цвет = текущий стейт
## (зелёный IDLE, голубой PATROL, красный DEFEND). Жёлтая линия — куда РЕАЛЬНО сейчас повёрнута
## башня; узкий белый контур вокруг неё — прицельный конус (secondary_cone_deg).
@export var show_fov_debug: bool = true
## Веер лучей объезда препятствий (зелёный — чисто, оранжевый — замечено, красный — перекрыто в
## пределах avoid_trigger_range, голубой — выбранное направление объезда). Виден только в PATROL.
@export var show_lidar_debug: bool = true
## Текстовая панель "что сейчас в голове у бота" — роль/сложность/стейт/цель/объезд — в правом
## верхнем углу экрана (отдельный CanvasLayer поверх HUD, не часть его разметки).
@export var show_brain_debug: bool = true

## EASY/HARD — множители/значения поверх полей выше (MEDIUM = как объявлены, без изменений).
## Разница по трём осям: осведомлённость (радиус/угол конуса), реакция (think_interval +
## скорость доворота башни — та же скорость и для блуждания), "непоседливость" взгляда
## (wander_hold — у HARD короче, крутит обзором активнее, у EASY дольше держит один угол).
## wander_min_turn_deg — общий для всех уровней, сложность его не меняет.
const _DIFFICULTY_PRESETS := {
	Difficulty.EASY: {
		"vision_range": 6.0,
		"look_cone_deg": 75.0,
		"fire_range": 5.0,
		"fire_aim_tolerance_deg": 9.0,
		"wander_hold_min_sec": 2.0,
		"wander_hold_max_sec": 3.5,
		"think_interval_sec": 0.25,
		"turret_turn_speed": 0.8,
	},
	Difficulty.HARD: {
		"vision_range": 14.0,
		"look_cone_deg": 130.0,
		"fire_range": 11.0,
		"fire_aim_tolerance_deg": 3.0,
		"wander_hold_min_sec": 0.5,
		"wander_hold_max_sec": 1.2,
		"think_interval_sec": 0.05,
		"turret_turn_speed": 2.2,
		"move_speed_multiplier": 1.0,  # единственный уровень БЕЗ замедления — как танк игрока
	},
}

@onready var _body: CharacterBody3D = get_parent()
@onready var _movement: Node = get_parent().get_node("TankMovement")
@onready var _turret: Node3D = get_parent().get_node("Turret")
@onready var _barrel: Node3D = get_parent().get_node("Turret/Barrel")
@onready var _weapon: Node = get_parent().get_node("WeaponController")
@onready var _disguise: Node = get_parent().get_node("DisguiseController")
@onready var _health: Node = get_parent().get_node("HealthComponent")

var state: State = State.IDLE
## Мировой угол, куда сейчас должна повернуться БАШНЯ (v2 — только башня, на главный конус
## обзора больше не влияет, см. заголовок файла).
var _look_yaw: float = 0.0
var _current_target: Node = null
var _think_timer: float = 0.0
var _fov_debug_mesh: MeshInstance3D

## Состояние блуждания взгляда в IDLE/PATROL (см. _wander()).
var _wander_holding: bool = false
var _wander_hold_timer: float = 0.0

## Вейпоинты — собираются в _ready() поиском по имени на текущей сцене (см. _collect_waypoints()).
var _waypoints: Array = []
var _waypoint_index: int = 0
var _waypoint_target_pos: Vector3 = Vector3.ZERO
var _has_waypoint_target: bool = false

## Объезд препятствий (см. _compute_travel_yaw()). _avoid_side: 0 — не объезжаем, -1/+1 — держим
## сторону объезда (лево/право), пока путь не расчистится. _chosen_avoid_local_deg — угол
## (локальный, относительно корпуса) выбранного луча-направления объезда — только для дебаг-отрисовки.
var _avoid_side: int = 0
var _avoid_active: bool = false
## true, если выбранный сейчас борт объезда РЕАЛЬНО свободен (dist >= avoid_trigger_range), а не
## просто "менее плохой" из двух. Пока false — ai_move_input держим на 0 (см. _drive_to_waypoint()):
## танк доворачивается на месте, но НЕ едет туда, где ещё не убедился, что реально проедет —
## иначе на пограничной дистанции он всё равно чиркает препятствие бортом на подъезде.
var _avoid_chosen_clear: bool = true
var _chosen_avoid_local_deg: float = 0.0
var _last_lidar_fan: Array = []
var _lidar_debug_mesh: MeshInstance3D

## Качание бортовых лучей-датчиков (см. _advance_obstacle_sweep()) — 0..avoid_sweep_max_deg,
## _avoid_sweep_dir хранит направление (+1 расходятся от центра, -1 сходятся обратно к центру).
var _avoid_sweep_deg: float = 0.0
var _avoid_sweep_dir: float = 1.0

## Качание УГЛА центрального луча вокруг направления на цель — от -_center_sweep_max_deg до
## +_center_sweep_max_deg и обратно (см. тот же _advance_obstacle_sweep()); максимум считается
## один раз в _ready() из hull_half_width/center_sweep_ref_distance.
var _center_sweep_deg: float = 0.0
var _center_sweep_dir: float = 1.0
var _center_sweep_max_deg: float = 0.0

## Антизастрял, 4 эскалирующих тира (см. _drive_to_waypoint()) — каждый следующий включается,
## когда предыдущий уже пробовался и не помог: (1) короткий аварийный реверс — _stuck_timer
## копится, пока едем без реального продвижения, _stuck_reverse_timer>0 — реверс идёт прямо
## сейчас; (2) 2 реверса подряд на ОДНОЙ стороне объезда — сторона явно не работает на этом
## препятствии, флип на другую (_stuck_trigger_count); (3) флип стороны УЖЕ пробовали на этой же
## цели и он тоже не спас (_stuck_side_flip_count) — проблема не в стороне, а в самом угле подхода
## к точке (узкий проход под углом, а не влево/вправо-развилка) — бросаем текущую точку внутри
## вейпоинта, берём новую случайную (другая точка почти всегда даёт другой угол подхода); (4) и
## смена точки внутри вейпоинта не спасла ВТОРОЙ раз подряд (_stuck_reroute_count) — не долбим
## третий раз в то же геометрическое узкое место, идём к следующему вейпоинту, вернёмся сюда
## обычным ходом патруля позже.
var _stuck_timer: float = 0.0
var _stuck_reverse_timer: float = 0.0
var _stuck_trigger_count: int = 0
var _stuck_side_flip_count: int = 0
var _stuck_reroute_count: int = 0
var _brain_debug_label: Label

func _ready() -> void:
	_apply_difficulty_preset()
	_center_sweep_max_deg = rad_to_deg(atan(hull_half_width / center_sweep_ref_distance))

	# Тот же трюк, что у TankAIController._initialize() — без этого бот читал бы Input
	# игрока напрямую (is_player_controlled по умолчанию true у всех этих компонентов).
	_movement.is_player_controlled = false
	_turret.is_player_controlled = false
	_barrel.is_player_controlled = false
	_weapon.is_player_controlled = false
	_disguise.is_player_controlled = false
	_turret.turn_speed = turret_turn_speed
	_movement.move_speed *= move_speed_multiplier
	_look_yaw = _body.rotation.y
	_health.damaged.connect(_on_damaged)
	_collect_waypoints()

	# CameraRig этого танка на статичной сцене нельзя выключить оверрайдом в .tscn (нет
	# редактируемых детей у инстанса) — гасим камеру здесь. BotSentryController стоит
	# ПОСЛЕДНИМ сиблингом среди детей Tank-инстанса, поэтому его _ready() гарантированно
	# отрабатывает уже ПОСЛЕ CameraRig._ready() (которая успела выставить Camera3D.current=true
	# по умолчанию is_active=true) — здесь это откатывается ДО первого кадра рендера, игрок
	# не видит вспышку смены камеры (тот же класс бага, что описан в team_spawner.gd).
	var camera_rig: Node3D = _body.get_node("CameraRig")
	camera_rig.is_active = false
	var camera: Camera3D = camera_rig.get_node("Camera3D")
	camera.current = false

	if show_fov_debug:
		_setup_fov_debug_draw()
	if show_lidar_debug:
		_setup_lidar_debug_draw()
	if show_brain_debug:
		_setup_brain_debug_label()

## MEDIUM ничего не меняет (числа выше УЖЕ тюнинг medium). EASY/HARD перезаписывают поля
## значениями из _DIFFICULTY_PRESETS — правки конкретных @export-полей в инспекторе этого
## инстанса для EASY/HARD смысла не имеют, они всё равно будут перетёрты отсюда при старте.
func _apply_difficulty_preset() -> void:
	if not _DIFFICULTY_PRESETS.has(difficulty):
		return
	var preset: Dictionary = _DIFFICULTY_PRESETS[difficulty]
	vision_range = preset["vision_range"]
	look_cone_deg = preset["look_cone_deg"]
	fire_range = preset["fire_range"]
	fire_aim_tolerance_deg = preset["fire_aim_tolerance_deg"]
	wander_hold_min_sec = preset["wander_hold_min_sec"]
	wander_hold_max_sec = preset["wander_hold_max_sec"]
	think_interval_sec = preset["think_interval_sec"]
	turret_turn_speed = preset["turret_turn_speed"]
	if preset.has("move_speed_multiplier"):
		move_speed_multiplier = preset["move_speed_multiplier"]

## Вейпоинты ищутся на КОРНЕ текущей сцены (не в "Map" — у этой тестовой арены нет отдельного
## Map-узла, всё лежит прямо в BotArena.tscn), по префиксу имени "Waypoint", сортировка по
## имени даёт стабильный порядок обхода (Waypoint1 → Waypoint2 → Waypoint3 → снова Waypoint1).
func _collect_waypoints() -> void:
	_waypoints.clear()
	for child in get_tree().current_scene.get_children():
		if String(child.name).begins_with("Waypoint"):
			_waypoints.append(child)
	_waypoints.sort_custom(func(a, b): return String(a.name) < String(b.name))

func _physics_process(delta: float) -> void:
	_think_timer -= delta
	if _think_timer <= 0.0:
		_think_timer = think_interval_sec
		_think()

	match state:
		State.DEFEND:
			_movement.ai_move_input = 0.0
			_movement.ai_turn_input = 0.0
			if _current_target != null and is_instance_valid(_current_target):
				_aim_and_fire(_current_target)
		State.PATROL:
			_drive_to_waypoint(delta)
			_wander(delta, true)
			_turret.target_yaw = wrapf(_look_yaw - _body.rotation.y, -PI, PI)
		State.IDLE:
			_movement.ai_move_input = 0.0
			_movement.ai_turn_input = 0.0
			_wander(delta, false)
			_turret.target_yaw = wrapf(_look_yaw - _body.rotation.y, -PI, PI)

	if show_fov_debug:
		_update_fov_debug_draw()
	if show_lidar_debug:
		_update_lidar_debug_draw()
	if show_brain_debug:
		_update_brain_debug_label()

## Движок выбора стейта — приоритет "вижу цель" НАД любым домашним поведением роли (см.
## заголовок файла). Вызывается раз в think_interval_sec, не каждый физ.кадр.
func _think() -> void:
	var visible_target: Node = null
	if state == State.DEFEND and _current_target != null and is_instance_valid(_current_target) and _can_see(_current_target):
		visible_target = _current_target
	else:
		visible_target = _scan_for_target()

	if visible_target != null:
		_enter_defend(visible_target)
		return

	if state == State.DEFEND:
		_on_target_lost()
	_ensure_home_state()

## "Домашнее" поведение роли, когда цель не видна (см. приоритет в заголовке файла). ACHIEVER
## с расставленными вейпоинтами патрулирует; иначе (в т.ч. KILLER — заглушка, см. дев-план)
## просто стоит и смотрит по кругу.
func _ensure_home_state() -> void:
	var desired: State = State.PATROL if (role == Role.ACHIEVER and not _waypoints.is_empty()) else State.IDLE
	if state != desired:
		state = desired
		# _look_yaw/_wander_holding намеренно НЕ сбрасываются — блуждание продолжается с
		# текущего угла что при переходе в PATROL, что в IDLE.

## Цель потеряна/уничтожена во время DEFEND. Сейчас единообразно для всех уровней сложности —
## возврат к домашнему поведению роли (_ensure_home_state() вызывается сразу после в _think()).
## Точка расширения под HARD → PURSUE, см. дев-план в заголовке файла.
func _on_target_lost() -> void:
	_current_target = null

func _scan_for_target() -> Node:
	for other in get_tree().get_nodes_in_group("tanks"):
		if other == _body or not is_instance_valid(other):
			continue
		if other.team == _body.team:
			continue
		if _can_see(other):
			return other
	return null

## Триггер обнаружения — попадание в ЛЮБОЙ из двух конусов (v2, см. заголовок файла): ГЛАВНЫЙ
## (look_cone_deg, жёстко на направлении корпуса — "видит перед собой" безусловно) ИЛИ
## ПРИЦЕЛЬНЫЙ (secondary_cone_deg вокруг РЕАЛЬНОГО угла башни _turret.rotation.y — "или в
## направлении поворота башни"). Главный конус вообще не двигается сам по себе (только корпус
## поворотом); прицельный следует за физическим поворотом башни (блуждание/слежение за целью).
func _can_see(target: Node3D) -> bool:
	var to_target: Vector3 = target.global_position - _turret.global_position
	var dist: float = to_target.length()
	if dist > vision_range or dist < 0.01:
		return false
	var world_yaw: float = _yaw_to_world_point(_turret.global_position, target.global_position)

	var hull_diff_deg: float = rad_to_deg(absf(wrapf(world_yaw - _body.rotation.y, -PI, PI)))
	var in_hull_cone: bool = hull_diff_deg <= look_cone_deg * 0.5

	var turret_world_yaw: float = _body.rotation.y + _turret.rotation.y
	var turret_diff_deg: float = rad_to_deg(absf(wrapf(world_yaw - turret_world_yaw, -PI, PI)))
	var in_turret_cone: bool = turret_diff_deg <= secondary_cone_deg * 0.5

	if not (in_hull_cone or in_turret_cone):
		return false
	var space_state := _body.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		_turret.global_position,
		target.global_position + Vector3.UP * 0.3
	)
	query.exclude = [_body]
	query.collision_mask = 1 | 2  # environment (стенка) + tanks
	var result: Dictionary = space_state.intersect_ray(query)
	return result.is_empty() or result.get("collider") == target

func _enter_defend(target: Node) -> void:
	state = State.DEFEND
	_current_target = target

## Наводка пересчитывается КАЖДЫЙ кадр по живой позиции цели — "камера"/башня физически
## движутся вслед за её перемещением, пока цель остаётся видна (проверяет _think()).
func _aim_and_fire(target: Node3D) -> void:
	_look_yaw = _yaw_to_world_point(_turret.global_position, target.global_position)
	_turret.target_yaw = wrapf(_look_yaw - _body.rotation.y, -PI, PI)

	var dist: float = _body.global_position.distance_to(target.global_position)
	var aim_diff_deg: float = rad_to_deg(absf(wrapf(_turret.target_yaw - _turret.rotation.y, -PI, PI)))
	if dist <= fire_range and aim_diff_deg <= fire_aim_tolerance_deg:
		_weapon.try_fire()

func _yaw_to_world_point(from: Vector3, to_point: Vector3) -> float:
	var d: Vector3 = to_point - from
	return atan2(-d.x, -d.z)

## Реакция на попадание — разворот "камеры" (значит и башни) туда, откуда стреляли, в любом
## стейте, кроме уже-DEFEND. Если после разворота цель уже в конусе — сразу DEFEND.
func _on_damaged(_current_hits: int, _max_hits: int, killer: Node) -> void:
	if killer == null or not is_instance_valid(killer) or killer == _body:
		return
	_look_yaw = _yaw_to_world_point(_turret.global_position, killer.global_position)
	_wander_holding = false
	if state != State.DEFEND and _can_see(killer):
		_enter_defend(killer)

## Блуждание БАШНИ в IDLE/PATROL (v2 — только башня, см. заголовок файла) — то вперёд, то в
## сторону, с паузами, а не мерное качание туда-сюда. Пока не дошли до _look_yaw — просто ждём
## (физический доворот делает TurretController.rotate_toward()); дошли — держим
## wander_hold_min_sec..wander_hold_max_sec, затем выбираем новый угол (_pick_new_wander_target()
## — "сперва линией определяем угол"). biased_forward=true (PATROL) — чаще целимся по ходу
## движения, а не куда попало.
func _wander(delta: float, biased_forward: bool) -> void:
	if _wander_holding:
		_wander_hold_timer -= delta
		if _wander_hold_timer <= 0.0:
			_pick_new_wander_target(biased_forward)
		return
	var aim_diff_deg: float = rad_to_deg(absf(wrapf(_turret.target_yaw - _turret.rotation.y, -PI, PI)))
	if aim_diff_deg <= _WANDER_ARRIVE_TOLERANCE_DEG:
		_wander_holding = true
		_wander_hold_timer = randf_range(wander_hold_min_sec, wander_hold_max_sec)

## Следующий угол обзора — полный круг (360°, любое направление, включая назад), но не ближе
## wander_min_turn_deg к текущему: например, при текущем угле 45° и min_turn=30° новый угол
## обязан оказаться <=15° или >=75° (запретная зона — открытый интервал (15,75), 30°-разница
## ровно на границе разрешена). Реализация — сдвиг на случайный офсет из [min_turn, 360-min_turn]
## от ТЕКУЩЕГО угла: покрывает все углы, отстоящие от текущего не менее чем на min_turn, без
## разрывов и без нужды в отдельной проверке/повторной выборке.
## biased_forward=true — с вероятностью forward_look_bias вместо этого ищем угол в узком
## секторе "вперёд по корпусу" (см. _pick_forward_biased_deg()), не нарушая то же ограничение.
func _pick_new_wander_target(biased_forward: bool) -> void:
	var current_local_deg: float = rad_to_deg(wrapf(_look_yaw - _body.rotation.y, -PI, PI))
	var target_local_deg: float
	if biased_forward and randf() < forward_look_bias:
		target_local_deg = _pick_forward_biased_deg(current_local_deg)
	else:
		var offset_deg: float = randf_range(wander_min_turn_deg, 360.0 - wander_min_turn_deg)
		target_local_deg = wrapf(current_local_deg + offset_deg, -180.0, 180.0)
	_look_yaw = _body.rotation.y + deg_to_rad(target_local_deg)
	_wander_holding = false

## Угол в узком секторе вокруг направления корпуса (±forward_look_cone_deg/2), отстоящий от
## текущего не менее чем на wander_min_turn_deg — отбор с повторными попытками (сектор+
## ограничение почти никогда не конфликтуют при разумных значениях по умолчанию); на случай
## редкого невезения за MAX_TRIES — берём дальний от текущего угла край сектора как гарантированно
## валидный запасной вариант.
func _pick_forward_biased_deg(current_local_deg: float) -> float:
	const MAX_TRIES := 6
	for i in range(MAX_TRIES):
		var candidate: float = randf_range(-forward_look_cone_deg * 0.5, forward_look_cone_deg * 0.5)
		var diff_deg: float = rad_to_deg(absf(wrapf(deg_to_rad(candidate - current_local_deg), -PI, PI)))
		if diff_deg >= wander_min_turn_deg:
			return candidate
	return forward_look_cone_deg * 0.5 if current_local_deg <= 0.0 else -forward_look_cone_deg * 0.5

## Движение в PATROL — доехать до случайной точки в круге текущего вейпоинта, затем перейти к
## следующему (индекс всегда по модулю — патруль бесконечный). Тот же принцип наведения
## корпуса, что и в tank_ai_controller.gd._drive_toward().
func _drive_to_waypoint(delta: float) -> void:
	if _waypoints.is_empty():
		_movement.ai_move_input = 0.0
		_movement.ai_turn_input = 0.0
		return

	# Аварийный реверс уже идёт — досиживаем его, не трогая остальную логику (объезд пересчитает
	# всё заново, как только реверс закончится и контакт с препятствием физически разорван).
	if _stuck_reverse_timer > 0.0:
		_stuck_reverse_timer -= delta
		_movement.ai_move_input = -1.0
		_movement.ai_turn_input = 0.0
		return

	if not _has_waypoint_target:
		_pick_new_waypoint_target()

	var to_target: Vector3 = _waypoint_target_pos - _body.global_position
	to_target.y = 0.0
	if to_target.length() < waypoint_reach_dist:
		_advance_waypoint()
		return

	var desired_world_yaw: float = _yaw_to_world_point(_body.global_position, _waypoint_target_pos)

	# "Лидар" — 2 качающихся луча из центра корпуса; если направление на цель перекрыто
	# препятствием, едем не на цель, а на тот из лучей, что сейчас свободнее на выбранной
	# стороне обхода (см. _compute_travel_yaw() и заголовок файла — танк не умеет двигаться
	# боком, только рулить корпусом, поэтому объезд — это ВСЕГДА замена желаемого угла
	# поворота, не смещение).
	_advance_obstacle_sweep(delta)
	_last_lidar_fan = _scan_obstacle_rays(desired_world_yaw)
	var travel_world_yaw: float = _compute_travel_yaw(desired_world_yaw, _last_lidar_fan)

	var yaw_diff: float = wrapf(travel_world_yaw - _body.rotation.y, -PI, PI)
	# Знак: TankMovement._physics_process() делает _body.rotate_y(-turn_input*turn_speed*delta),
	# т.е. turn_input>0 УМЕНЬШАЕТ rotation.y, а не увеличивает (проверено живьём покадровым
	# прогоном — с прямым знаком (turn_input=yaw_diff/0.5, как в этой же формуле у
	# tank_ai_controller.gd._drive_toward(), см. дев-план в заголовке файла) бот ехал К ЦЕЛИ
	# ДЛИННЫМ путём и на развороте, близком к 180°, залипал на антиподе цели, до конца не сходясь
	# — ai_turn_input каждый кадр дёргался -1/+1 без прогресса). Поэтому здесь знак ОБРАТНЫЙ.
	_movement.ai_turn_input = clamp(-yaw_diff / 0.5, -1.0, 1.0)

	# Препятствие "практически вплотную" (center-луч короче avoid_close_range) — резкий доворот
	# ВО ВРЕМЯ движения на такой дистанции реально задевает его корпусом (луч тонкий, корпус
	# широкий). По прямому запросу: на этой дистанции ХОДОВАЯ полностью останавливается и корпус
	# доворачивается НА МЕСТЕ (гусеницы это позволяют без обмана — тот же поворот, что и всегда,
	# просто без одновременного хода), едем дальше только когда угол почти сошёлся
	# (avoid_close_turn_tolerance_deg — узкий допуск, а не обычные 60°, которые нормально дают
	# смягчённую дугу на безопасной дистанции, но здесь означали бы въезд боком в препятствие).
	var center_dist: float = _last_lidar_fan[0]["dist"]
	var too_close: bool = _avoid_active and center_dist < avoid_close_range
	var turn_tolerance_deg: float = avoid_close_turn_tolerance_deg if too_close else 60.0

	# Едем, только если направление либо не требует объезда вообще, либо выбранный борт объезда
	# УЖЕ подтверждён реально свободным (_avoid_chosen_clear) — пока не подтверждён, доворачиваемся
	# на месте (move_input=0), но НЕ едем туда, где ещё не убедились, что реально проедем. Раньше
	# ехали к "менее плохому" борту сразу — на пограничной дистанции корпус чиркал препятствие,
	# что физически выглядело как боковое скольжение (см. также фикс в tank_movement.gd).
	var can_advance: bool = (not _avoid_active) or _avoid_chosen_clear
	_movement.ai_move_input = 1.0 if (can_advance and absf(yaw_diff) < deg_to_rad(turn_tolerance_deg)) else 0.0

	# Антизастрял: едем, но физически почти не скользим (застряли на углу препятствия — лучей
	# всего 3, геометрию корнера они иногда не ловят, см. @export-блок выше), ЛИБО стоим и ждём
	# (подтверждения свободного борта, ИЛИ доворота на месте у самого препятствия) — все три случая
	# копим тем же таймером, по истечении — короткий аварийный реверс (без этого "стоим и ждём" сам
	# по себе не запускал бы ниже эскалацию — ai_move_input тут же 0, а ожидание может не наступить
	# никогда на симметрично узком препятствии).
	var actual_speed: float = Vector2(_body.velocity.x, _body.velocity.z).length()
	var waiting_for_clear_side: bool = _avoid_active and (not _avoid_chosen_clear or too_close)
	if (_movement.ai_move_input > 0.5 or waiting_for_clear_side) and actual_speed < stuck_min_speed:
		_stuck_timer += delta
		if _stuck_timer >= stuck_detect_sec:
			_stuck_timer = 0.0
			_stuck_reverse_timer = stuck_reverse_sec
			_stuck_trigger_count += 1
			# Тир 2: застряли подряд ДВАЖДЫ на одной и той же выбранной стороне объезда — сама
			# сторона явно не работает на этом препятствии, пробуем другую.
			if _stuck_trigger_count >= 2 and _avoid_side != 0:
				_avoid_side = -_avoid_side
				_stuck_trigger_count = 0
				_stuck_side_flip_count += 1
				# Тир 3: флип стороны на ЭТОЙ ЖЕ цели уже пробовали, и снова застряли — не
				# помогает ни одна из двух локальных сторон объезда, значит дело не в стороне,
				# а в самом угле подхода (узкий проход под углом между двумя препятствиями —
				# см. Bot AI Sandbox §11.4). Бросаем текущую точку, берём новую случайную внутри
				# того же вейпоинта — другая точка почти всегда даёт другой угол подхода.
				if _stuck_side_flip_count >= 2:
					_stuck_side_flip_count = 0
					_avoid_side = 0
					_avoid_active = false
					_stuck_reroute_count += 1
					# Тир 4: смена точки внутри вейпоинта ТОЖЕ не спасла второй раз подряд — не
					# долбим третий раз в то же геометрическое узкое место, идём к следующему
					# вейпоинту (_advance_waypoint() сам резетит _stuck_reroute_count).
					if _stuck_reroute_count >= 2:
						_advance_waypoint()
					else:
						_has_waypoint_target = false
	else:
		_stuck_timer = 0.0
		_stuck_trigger_count = 0
		_stuck_side_flip_count = 0

## Продвигает оба качания на один физ.кадр — оба УГЛОМ, оба из одной и той же точки (центр
## корпуса): бортовые лучи — 0..avoid_sweep_max_deg (как дворники), центральный — вокруг
## direction-to-target, -_center_sweep_max_deg..+_center_sweep_max_deg (та же механика, амплитуда
## на порядок меньше — см. заголовок файла и hull_half_width/center_sweep_ref_distance).
func _advance_obstacle_sweep(delta: float) -> void:
	_avoid_sweep_deg += _avoid_sweep_dir * avoid_sweep_speed_deg_per_sec * delta
	if _avoid_sweep_deg >= avoid_sweep_max_deg:
		_avoid_sweep_deg = avoid_sweep_max_deg
		_avoid_sweep_dir = -1.0
	elif _avoid_sweep_deg <= 0.0:
		_avoid_sweep_deg = 0.0
		_avoid_sweep_dir = 1.0

	_center_sweep_deg += _center_sweep_dir * center_sweep_speed_deg_per_sec * delta
	if _center_sweep_deg >= _center_sweep_max_deg:
		_center_sweep_deg = _center_sweep_max_deg
		_center_sweep_dir = -1.0
	elif _center_sweep_deg <= -_center_sweep_max_deg:
		_center_sweep_deg = -_center_sweep_max_deg
		_center_sweep_dir = 1.0

## ТРИ луча-датчика, ВСЕ из одной точки (центр корпуса, чуть приподнят) — различаются только
## углом. "center" качается вокруг desired_world_yaw в пределах ±_center_sweep_max_deg (см.
## _advance_obstacle_sweep()) — этот угол подобран так, что на дистанции center_sweep_ref_distance
## боковой охват качания равен hull_half_width: узкий столб, который луч строго по курсу
## проскочил бы мимо (хотя корпус своей шириной его заденет), рано или поздно попадает под
## качающийся угол. "left"/"right" качаются зеркально между 0° и ±avoid_sweep_max_deg от
## направления корпуса — они не решают "перекрыто ли", только "куда объезжать" (см.
## _compute_travel_yaw()).
func _scan_obstacle_rays(desired_world_yaw: float) -> Array:
	var rays: Array = []
	var origin: Vector3 = _body.global_position + Vector3.UP * 0.4
	var space_state := _body.get_world_3d().direct_space_state
	var body_yaw: float = _body.rotation.y
	var ray_defs: Array = [
		{"id": "center", "world_yaw": desired_world_yaw + deg_to_rad(_center_sweep_deg)},
		{"id": "left", "world_yaw": body_yaw + deg_to_rad(-_avoid_sweep_deg)},
		{"id": "right", "world_yaw": body_yaw + deg_to_rad(_avoid_sweep_deg)},
	]
	for def in ray_defs:
		var ray_yaw: float = def["world_yaw"]
		var dir := Vector3(-sin(ray_yaw), 0.0, -cos(ray_yaw))
		var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * avoid_sensor_range)
		query.exclude = [_body]
		query.collision_mask = 1 | 2  # environment (препятствия) + tanks
		var result: Dictionary = space_state.intersect_ray(query)
		var dist: float = avoid_sensor_range
		var hit: bool = not result.is_empty()
		if hit:
			dist = origin.distance_to(result["position"])
		rays.append({"id": def["id"], "local_deg": rad_to_deg(wrapf(ray_yaw - body_yaw, -PI, PI)), "world_yaw": ray_yaw, "dist": dist, "hit": hit, "origin": origin, "dir": dir})
	return rays

## Решает, куда РЕАЛЬНО рулить: на цель напрямую, либо в объезд препятствия. "center"-луч
## (см. _scan_obstacle_rays()) перекрыт ближе avoid_trigger_range → включаем объезд: один раз
## выбираем сторону, глядя, какой из бортовых лучей СЕЙЧАС свободнее (left/right), и держим её
## (_avoid_side), пока center не расчистится — без удержания стороны бот на препятствии ровно
## по курсу дёргался бы то влево, то вправо каждый кадр. Дальше едем на бортовой луч выбранной
## стороны — с всего двумя кандидатами (не веером из многих) выбор тривиален, не нужен
## тайбрейк-перебор.
func _compute_travel_yaw(desired_world_yaw: float, rays: Array) -> float:
	var center: Dictionary = rays[0]
	var sweep_left: Dictionary = rays[1]
	var sweep_right: Dictionary = rays[2]

	if center["dist"] >= avoid_trigger_range:
		_avoid_side = 0
		_avoid_active = false
		_avoid_chosen_clear = true
		return desired_world_yaw

	_avoid_active = true
	if _avoid_side == 0:
		_avoid_side = -1 if sweep_left["dist"] >= sweep_right["dist"] else 1

	var chosen: Dictionary = sweep_left if _avoid_side < 0 else sweep_right
	# Выбранный борт может сам быть "просто менее плохим", а не реально свободным (оба сейчас
	# ближе avoid_trigger_range) — в этом случае ai_move_input держим на нуле, см. _drive_to_waypoint().
	_avoid_chosen_clear = chosen["dist"] >= avoid_trigger_range
	_chosen_avoid_local_deg = chosen["local_deg"]
	return chosen["world_yaw"]


## Случайная точка внутри круга (равномерно по площади — sqrt(randf()), не randf() напрямую,
## иначе точки скучивались бы у центра).
func _pick_new_waypoint_target() -> void:
	var wp: Node3D = _waypoints[_waypoint_index]
	var angle: float = randf() * TAU
	var dist: float = sqrt(randf()) * waypoint_radius
	var offset := Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)
	_waypoint_target_pos = wp.global_position + offset
	_has_waypoint_target = true

func _advance_waypoint() -> void:
	_waypoint_index = (_waypoint_index + 1) % _waypoints.size()
	_has_waypoint_target = false
	_stuck_reroute_count = 0  # новый вейпоинт — прежнее узкое место больше не актуально

## Создаётся один раз в _ready(): MeshInstance3D с ImmediateMesh — ребилдится каждый физ.кадр
## в _update_fov_debug_draw(). Ребёнок именно _body (CharacterBody3D), не self (self — plain
## Node, у Node3D-детей под ним не было бы осмысленной мировой трансформации) — так веер сам
## наследует позицию/поворот корпуса, координаты внутри считаем в ЛОКАЛЬНОМ пространстве бота.
func _setup_fov_debug_draw() -> void:
	_fov_debug_mesh = MeshInstance3D.new()
	_fov_debug_mesh.name = "FovDebugMesh"
	_fov_debug_mesh.mesh = ImmediateMesh.new()
	_fov_debug_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	_fov_debug_mesh.material_override = mat
	# call_deferred: _ready() всей ветки Tank-инстанса (в т.ч. _body) ещё выполняется в момент,
	# когда доходит очередь до этого (последнего) сиблинга — add_child() в это окно падает
	# с "Parent node is busy setting up children" (тот же класс проблемы, что и в main.gd).
	_body.add_child.call_deferred(_fov_debug_mesh)

## Точка в ЛОКАЛЬНЫХ координатах бота: local_deg=0 — прямо вперёд по корпусу (локальный -Z,
## та же система отсчёта, что и rotation.y у Turret).
func _local_point(local_deg: float, radius: float, height: float) -> Vector3:
	var rad: float = deg_to_rad(local_deg)
	return Vector3(-sin(rad) * radius, height, -cos(rad) * radius)

func _update_fov_debug_draw() -> void:
	var mesh: ImmediateMesh = _fov_debug_mesh.mesh
	mesh.clear_surfaces()

	const SEGMENTS := 16
	const HEIGHT := 0.55  # чуть выше корпуса — видно поверх HullMesh, не тонет в земле
	var radius: float = vision_range
	var fill_color: Color
	match state:
		State.DEFEND:
			fill_color = Color(1.0, 0.15, 0.1, 0.28)
		State.PATROL:
			fill_color = Color(0.2, 0.6, 0.95, 0.22)
		_:
			fill_color = Color(0.15, 0.9, 0.2, 0.22)
	var center := Vector3(0.0, HEIGHT, 0.0)

	# ГЛАВНЫЙ конус обзора (v2) — жёстко на направлении корпуса (0° в локальных координатах
	# бота), НЕ двигается сам по себе — только вместе с поворотом всего корпуса.
	var cone_min_deg: float = -look_cone_deg * 0.5
	var cone_max_deg: float = look_cone_deg * 0.5

	# Заливка веера — треугольниками (у ImmediateMesh нет отдельного TRIANGLE_FAN).
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	mesh.surface_set_color(fill_color)
	var prev_point: Vector3 = _local_point(cone_min_deg, radius, HEIGHT)
	for i in range(1, SEGMENTS + 1):
		var t: float = float(i) / float(SEGMENTS)
		var deg: float = lerp(cone_min_deg, cone_max_deg, t)
		var cur_point: Vector3 = _local_point(deg, radius, HEIGHT)
		mesh.surface_add_vertex(center)
		mesh.surface_add_vertex(prev_point)
		mesh.surface_add_vertex(cur_point)
		prev_point = cur_point
	mesh.surface_end()

	# Контур конуса (боковые радиусы + дуга) — ярче заливки, чтобы границы читались чётко.
	var outline_color := Color(fill_color.r, fill_color.g, fill_color.b, 0.9)
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	mesh.surface_set_color(outline_color)
	mesh.surface_add_vertex(center)
	for i in range(SEGMENTS + 1):
		var t2: float = float(i) / float(SEGMENTS)
		var deg2: float = lerp(cone_min_deg, cone_max_deg, t2)
		mesh.surface_add_vertex(_local_point(deg2, radius, HEIGHT))
	mesh.surface_add_vertex(center)
	mesh.surface_end()

	# Текущее РЕАЛЬНОЕ направление башни (куда башня уже физически довернула, не куда стремится) —
	# turret уже дочерний узел _body, rotation.y у неё локальный без пересчёта.
	var turret_local_deg: float = rad_to_deg(_turret.rotation.y)
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_set_color(Color(1.0, 1.0, 0.2, 0.95))
	mesh.surface_add_vertex(center)
	mesh.surface_add_vertex(_local_point(turret_local_deg, radius, HEIGHT))
	mesh.surface_end()

	# Прицельный сектор (см. _can_see()) — узкий контур белым, зафиксирован на РЕАЛЬНОМ угле
	# башни (том же turret_local_deg, что и жёлтая линия выше), не на _look_yaw. Только контур,
	# не заливка — чтобы не забивать читаемость главного конуса поверх него.
	var sec_min_deg: float = turret_local_deg - secondary_cone_deg * 0.5
	var sec_max_deg: float = turret_local_deg + secondary_cone_deg * 0.5
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	mesh.surface_set_color(Color(1.0, 1.0, 1.0, 0.6))
	mesh.surface_add_vertex(center)
	for i in range(SEGMENTS + 1):
		var t3: float = float(i) / float(SEGMENTS)
		var deg3: float = lerp(sec_min_deg, sec_max_deg, t3)
		mesh.surface_add_vertex(_local_point(deg3, radius, HEIGHT))
	mesh.surface_add_vertex(center)
	mesh.surface_end()

	# Целевой угол блуждания башни (_look_yaw — куда башня СЕЙЧАС стремится довернуться, "линия",
	# см. заголовок файла) — короткая пунктирная-по-цвету (сплошная линия, ImmediateMesh не умеет
	# пунктир) фиолетовая метка ближе к центру, чтобы не путать с реальным углом башни (жёлтая,
	# полной длины) выше — видно, куда башня едет, ДО того как физически туда довернёт.
	var wander_target_local_deg: float = rad_to_deg(wrapf(_look_yaw - _body.rotation.y, -PI, PI))
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_set_color(Color(0.85, 0.2, 0.95, 0.9))
	mesh.surface_add_vertex(center)
	mesh.surface_add_vertex(_local_point(wander_target_local_deg, radius * 0.5, HEIGHT))
	mesh.surface_end()

## Тот же приём, что и с конусом обзора (_setup_fov_debug_draw) — отдельный MeshInstance3D,
## ребёнок _body, ребилдится каждый физ.кадр.
func _setup_lidar_debug_draw() -> void:
	_lidar_debug_mesh = MeshInstance3D.new()
	_lidar_debug_mesh.name = "LidarDebugMesh"
	_lidar_debug_mesh.mesh = ImmediateMesh.new()
	_lidar_debug_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	_lidar_debug_mesh.material_override = mat
	_body.add_child.call_deferred(_lidar_debug_mesh)

## Два качающихся луча объезда: зелёный — луч чист, оранжевый — что-то видно, но ещё не в
## пределах avoid_trigger_range, красный — препятствие перекрывает в пределах срабатывания,
## голубой — луч, выбранный как направление объезда (_chosen_avoid_local_deg, только пока
## _avoid_active). Видно только в PATROL — вне патруля бот не едет, лучам качаться незачем.
##
## РЕАЛЬНЫЙ БАГ (не в физике объезда — там центр корпуса всегда был верный, см.
## _scan_obstacle_rays() — а именно в этой отрисовке): _lidar_debug_mesh — ДОЧЕРНИЙ узел _body,
## значит ImmediateMesh ждёт вершины в ЛОКАЛЬНЫХ координатах относительно корпуса — а сюда
## подавались ray["origin"]/ray["dir"]*dist, которые МИРОВЫЕ (нужны для самого raycast-запроса
## в _scan_obstacle_rays(), но не годятся напрямую для отрисовки). Трансформация корпуса
## применялась к ним ВТОРОЙ раз поверх уже мировых координат — рядом с центром карты (мировые
## координаты малы) сдвиг был почти незаметен на глаз, поэтому баг не бросался в глаза на
## прежних скриншотах; вдали от центра (проверено живьём на x=-20) лучи улетали за пределы
## кадра целиком. Фикс — как и у конуса обзора (_local_point()): координаты только локальные,
## относительно _body, вообще без обращения к ray["origin"]/["dir"].
func _update_lidar_debug_draw() -> void:
	var mesh: ImmediateMesh = _lidar_debug_mesh.mesh
	mesh.clear_surfaces()
	if state != State.PATROL or _last_lidar_fan.is_empty():
		return

	const HEIGHT := 0.4  # совпадает с высотой origin в _scan_obstacle_rays()

	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for ray in _last_lidar_fan:
		var color: Color
		if _avoid_active and absf(ray["local_deg"] - _chosen_avoid_local_deg) < 0.01:
			color = Color(0.2, 0.95, 0.95, 0.95)
		elif ray["hit"] and ray["dist"] < avoid_trigger_range:
			color = Color(0.95, 0.15, 0.1, 0.85)
		elif ray["hit"]:
			color = Color(0.9, 0.6, 0.1, 0.7)
		else:
			color = Color(0.2, 0.9, 0.3, 0.6)
		mesh.surface_set_color(color)
		# Все три луча стартуют строго из центра корпуса (см. _scan_obstacle_rays()) — отличаются
		# только УГЛОМ, поэтому local_origin один и тот же для всех, никакого бокового сдвига.
		var rad: float = deg_to_rad(ray["local_deg"])
		var local_origin := Vector3(0.0, HEIGHT, 0.0)
		var to_local: Vector3 = local_origin + Vector3(-sin(rad), 0.0, -cos(rad)) * ray["dist"]
		mesh.surface_add_vertex(local_origin)
		mesh.surface_add_vertex(to_local)
	mesh.surface_end()

## Текстовая панель "что сейчас в голове у бота" — отдельный CanvasLayer+Label поверх HUD (не
## трогаем разметку самого HUD.tscn — это дебаг конкретно этой песочницы, не часть продакшен-UI).
func _setup_brain_debug_label() -> void:
	var layer := CanvasLayer.new()
	layer.name = "BotBrainDebugLayer"
	var label := Label.new()
	label.name = "BotBrainDebugLabel"
	label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	label.offset_left = -340.0
	label.offset_top = 16.0
	label.offset_right = -16.0
	label.offset_bottom = 260.0
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	layer.add_child(label)
	_brain_debug_label = label
	# call_deferred по той же причине, что и у остальных дебаг-узлов (см. _setup_fov_debug_draw) —
	# сцена ещё строится в момент, когда доходит очередь до этого (последнего) сиблинга.
	get_tree().current_scene.add_child.call_deferred(layer)

func _update_brain_debug_label() -> void:
	if _brain_debug_label == null:
		return
	var lines: Array = []
	lines.append("=== BOT BRAIN ===")
	lines.append("role: %s   difficulty: %s" % [Role.keys()[role], Difficulty.keys()[difficulty]])
	lines.append("state: %s" % State.keys()[state])
	match state:
		State.DEFEND:
			if _current_target != null and is_instance_valid(_current_target):
				var dist: float = _body.global_position.distance_to(_current_target.global_position)
				lines.append("target: %s (%.1fm)" % [String(_current_target.name), dist])
			else:
				lines.append("target: -")
		State.PATROL:
			if not _waypoints.is_empty():
				lines.append("waypoint: %d/%d" % [_waypoint_index + 1, _waypoints.size()])
			if _has_waypoint_target:
				var to_point: float = _body.global_position.distance_to(_waypoint_target_pos)
				lines.append("to point: %.1fm" % to_point)
			if _avoid_active:
				lines.append("AVOID OBSTACLE: %s" % ("<- left" if _avoid_side < 0 else "right ->"))
			else:
				lines.append("path: clear")
		State.IDLE:
			lines.append("looking around")
	if _wander_holding:
		lines.append("look: holding (%.1fs left)" % _wander_hold_timer)
	else:
		lines.append("look: turning")
	_brain_debug_label.text = "\n".join(lines)
