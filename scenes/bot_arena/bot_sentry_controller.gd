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
## Объезд препятствий — v3, NavMesh + NavigationAgent3D (по прямому запросу: месяц правок
## реактивного raycast-лидара — v1..v2, вся история ниже сохранена в Bot AI Sandbox §11 как
## архив — упирался в architecture-level потолок: локальные минимумы на углах, дрожание на
## симметричных препятствиях, "не может решить куда ехать" на плотной карте. Каждый патч чинил
## конкретный симптом и открывал новый — потому что чисто РЕАКТИВНАЯ (без памяти о карте) система
## в принципе не может увидеть, что кластер препятствий стоит обогнуть целиком по большой дуге, а
## не тыкаться в него луч за лучом. Стандартный в индустрии (Unity/Unreal/сам Godot — не сторонний
## плагин) подход — ПРЕДИКТ маршрута заранее, потом только следование:
## - Статическая геометрия карты (Ground/Wall/Objective/ObstacleN/HazardZoneN) запечена ОДИН РАЗ
##   в `NavigationRegion3D.navigation_mesh` (см. BotArena.tscn) — A* по этому навмешу гарантированно
##   огибает всё известное, никаких проб лучами.
## - У бота — `NavigationAgent3D` (заводится в _ready(), ребёнок _body): `target_position` = точка
##   в круге текущего вейпоинта, `get_next_path_position()` каждый физ.кадр отдаёт СЛЕДУЮЩУЮ точку
##   УЖЕ посчитанного пути — corpus просто целится в неё тем же способом, что раньше целился в
##   сырую цель (ai_turn_input/ai_move_input, TankMovement, знак и там же обоснование).
## - Hazard-зоны (Area3D на слое 4, см. HazardZoneN) и препятствия (StaticBody3D) оба входят в
##   `NavigationMesh.geometry_collision_mask` при запекании — один и тот же навмеш одинаково
##   обходит и сплошную коробку, и "дыру в полу", разница только в физическом слое, не в логике.
## - Осталась ОДНА страховка на уровне TankMovement — короткий реверс, если едем, но реально не
##   сдвигаемся (см. _drive_to_waypoint()): навмеш не знает про ДИНАМИЧЕСКИЕ помехи (столкновение
##   с игроком/другим танком) — вся эскалация 4 тиров/дебаунсов/заднего луча из v1-v2 больше не
##   нужна, путь по статике уже гарантированно существует и не требует "перебора руками".
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

## Объезд препятствий — см. заголовок файла (v3, NavMesh). NavigationAgent3D заводится в _ready(),
## тюнинг — прямо на нём (radius/path_desired_distance), не через @export здесь: это не параметры
## поведения бота, а геометрическая настройка агента под конкретный навмеш.
## Совпадает с NavigationMesh.agent_radius в BotArena.tscn. ДОЛЖЕН быть не меньше полудиагонали
## корпуса (Tank.tscn BoxShape3D 1.2×0.6×1.8 → half-width 0.6, half-length 0.9 →
## sqrt(0.6²+0.9²)≈1.08) — меньший радиус даёт навмеш, который проводит путь ближе к углам
## препятствий, чем реально требует корпус, и корпус их физически задевает на поворотах (нашли
## живым тестом: 0.9 давало стабильный залип на угле Obstacle5, макс. разрыв без прогресса 14.4с).
@export var nav_agent_radius: float = 1.2

## [ИСПРАВЛЕНО, см. Bot AI Sandbox §12] Целиться ТОЧНО в get_next_path_position() (следующий узел
## пути) заставляло негомономный (не может боком) танк срезать угол вплотную к препятствию — A*
## по навмешу проводит кратчайший путь РОВНО по границе agent_radius вокруг угла, а прицеливание
## точно в эту точку не оставляет запаса на реальный радиус разворота корпуса. Вместо этого —
## pure pursuit (стандартная техника следования по пути для транспортных средств, не point-агента):
## целимся в точку, отстоящую на nav_lookahead_distance ВПЕРЁД по полилинии пути от текущей
## позиции (см. _get_lookahead_point()), а не в саму точку поворота — так на повороте получается
## мягкая дуга, а не срез угла.
@export var nav_lookahead_distance: float = 3.0

## [ГИБРИД, по прямому запросу] Веер из 3 коротких лучей (0°, ±emergency_brake_spread_deg от
## корпуса) — ТОЛЬКО аварийный тормоз, не выбор направления (направление всегда решает навмеш/
## pure pursuit выше). [ИСПРАВЛЕНО] Один луч строго по центру не ловил контакт корпусом ПОД
## УГЛОМ (см. Bot AI Sandbox §12 — живой тест: get_slide_collision() показал реальный физический
## контакт с препятствием, а brake_hit с одним центральным лучом был false, тот же слепой угол,
## что и у одиночного луча в самой первой версии объезда, §11.1) — три луча веером, ЛЮБОЙ хит
## близко считается тормозом. Если что-то оказалось ближе emergency_brake_range — ai_move_input
## жёстко на 0 в этом кадре (доворот продолжается) — последний рубеж защиты от несовершенства
## pure-pursuit-следования, не замена NavMesh-планирования тем самым реактивным лидаром, от
## которого ушли (три коротких луча на кадр несравнимо дешевле прежних 3 непрерывно качающихся
## на полную дальность, и не участвуют в выборе курса вообще).
@export var emergency_brake_range: float = 1.3
@export var emergency_brake_spread_deg: float = 20.0

## Антизастрял — страховка на физические заедания (контакт с препятствием под углом, столкновение
## с другим танком) — по чистому СМЕЩЕНИЮ ПОЗИЦИИ за окно stuck_detect_sec, НЕ по мгновенной
## скорости. [ИСПРАВЛЕНО] Мгновенная Vector2(velocity.x,velocity.z).length() ловится контактной
## вибрацией — та же ловушка, что уже была задокументирована для реактивного лидара (§11.4):
## контакт корпуса с углом препятствия ПОД УГЛОМ даёт болтающуюся скорость чуть ВЫШЕ
## stuck_min_speed каждый кадр (Jolt пересчитывает контакт заново), хотя чистого продвижения нет
## вообще (живой тест: реальный физический контакт по get_slide_collision(), скорость 0.237 —
## выше порога 0.15, обычный таймер так и не накопился бы за много секунд). Решение — сравнивать
## позицию РАЗ в stuck_detect_sec с позицией на начало этого окна: если сдвинулись меньше
## stuck_min_progress ЗА ВСЁ ОКНО — считаем застрявшим, независимо от того, что показывает
## скорость в отдельных кадрах.
@export var stuck_detect_sec: float = 0.6
@export var stuck_reverse_sec: float = 0.4
@export var stuck_min_progress: float = 0.3

@export var think_interval_sec: float = 0.1  # реже физ.кадра — проверка "вижу/не вижу", не сама наводка
@export var turret_turn_speed: float = 1.0  # рад/сек — применяется на Turret при _ready() (см. turret_controller.gd), также скорость блуждания обзора

## Множитель к TankMovement.move_speed (см. _ready()) — по прямому запросу боты EASY/MEDIUM должны
## быть медленнее танка игрока, 0.75 = на 25% медленнее. HARD возвращает полную скорость игрока
## обратно в своём пресете (см. _DIFFICULTY_PRESETS) — сложность в первую очередь про осведомлённость
## и реакцию, не про то, что HARD-бот физически едет быстрее MEDIUM/EASY.
@export var move_speed_multiplier: float = 0.75

## Дебажная отрисовка (ImmediateMesh) поверх земли под ботом: веер — ГЛАВНЫЙ конус обзора
## (look_cone_deg, жёстко по направлению корпуса, радиус vision_range); цвет = текущий стейт
## (зелёный IDLE, голубой PATROL, красный DEFEND). Жёлтая линия — куда РЕАЛЬНО сейчас повёрнута
## башня; узкий белый контур вокруг неё — прицельный конус (secondary_cone_deg).
@export var show_fov_debug: bool = true
## Линия текущего NavMesh-пути (голубая) — видна только в PATROL, см. _update_path_debug_draw().
@export var show_path_debug: bool = true
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

## NavigationAgent3D — заводится в _ready() как ребёнок _body (см. заголовок файла). Плюс сам
## meш для отрисовки текущего пути (see _update_path_debug_draw()).
var _nav_agent: NavigationAgent3D
var _path_debug_mesh: MeshInstance3D

## Антизастрял — по чистому смещению за окно, см. @export-блок выше. _stuck_check_pos — позиция
## на начало текущего окна замера, _stuck_check_timer — сколько уже накопилось в этом окне.
var _stuck_check_pos: Vector3 = Vector3.ZERO
var _stuck_check_timer: float = 0.0
var _stuck_reverse_timer: float = 0.0

var _brain_debug_label: Label

## Статистика для дебаг-панели (по прямому запросу) — обе копятся с _ready(), никогда не
## сбрасываются сами (переживают смену стейта/цели, в отличие от вейпоинт-прогресса):
## _total_time_sec — сколько игрового времени (delta, значит уважает паузу/time_scale) прошло с
## момента запуска этого бота; _leg_timer — копится, пока бот пытается дойти до ТЕКУЩЕГО
## вейпоинта (см. _drive_to_waypoint()), сбрасывается в 0 при каждом _advance_waypoint(), но
## непосредственно ПЕРЕД сбросом обновляет _max_leg_time_sec, если это новый рекорд — та самая
## "максимальная обновляемая" метрика: растёт, если бот когда-либо шёл до вейпоинта дольше, чем
## раньше (включая время застреваний/реверсов — это тоже часть "времени достижения").
var _total_time_sec: float = 0.0
var _leg_timer: float = 0.0
var _max_leg_time_sec: float = 0.0

func _ready() -> void:
	_apply_difficulty_preset()

	# NavigationAgent3D — ребёнок _body (не self, см. заголовок файла: агент берёт текущую позицию
	# от РОДИТЕЛЯ-Node3D). call_deferred по той же причине, что и у остальных дебаг-узлов ниже —
	# сцена ещё строится в момент, когда доходит очередь до этого (последнего) сиблинга.
	_nav_agent = NavigationAgent3D.new()
	_nav_agent.name = "NavigationAgent3D"
	_nav_agent.radius = nav_agent_radius
	# Танк не голономный (не может боком) — на широкой дуге поворота легко проскочить МИМО
	# точки пути на расстоянии больше стандартных 0.5м, ни разу не попав точно в допуск, из-за
	# чего курсор пути не продвигается вообще (см. Bot AI Sandbox §11 про диагностику). Больше,
	# чем у типового point-агента.
	_nav_agent.path_desired_distance = 2.0
	_nav_agent.target_desired_distance = 1.0
	_nav_agent.avoidance_enabled = false  # v1 — только статический навмеш, RVO на потом
	_body.add_child.call_deferred(_nav_agent)

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
	if show_path_debug:
		_setup_path_debug_draw()
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
	_total_time_sec += delta
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
	if show_path_debug:
		_update_path_debug_draw()
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
## следующему (индекс всегда по модулю — патруль бесконечный). Объезд статических препятствий —
## NavigationAgent3D/NavMesh, следование — pure pursuit (см. _get_lookahead_point()), плюс один
## короткий луч-тормоз (emergency_brake_range) как последний рубеж, см. заголовок файла.
func _drive_to_waypoint(delta: float) -> void:
	_leg_timer += delta  # копится, пока пытаемся дойти до текущего вейпоинта — см. _advance_waypoint()
	if _waypoints.is_empty():
		_movement.ai_move_input = 0.0
		_movement.ai_turn_input = 0.0
		return

	# NavigationAgent3D добавляется через add_child.call_deferred() в _ready() (сцена ещё строится
	# в момент, когда доходит очередь до этого сиблинга) — на первый физ.кадр(ы) он ещё может быть
	# не в дереве. get_next_path_position() на таком агенте кидает ошибку ("agent has no parent"),
	# а не просто возвращает нейтральный результат — ждём, пока агент реально окажется в дереве.
	if not _nav_agent.is_inside_tree():
		_movement.ai_move_input = 0.0
		_movement.ai_turn_input = 0.0
		return

	# Аварийный реверс уже идёт — досиживаем его, дальше NavigationAgent3D пересчитает путь сам
	# со следующей (уже сдвинутой реверсом) позиции.
	if _stuck_reverse_timer > 0.0:
		_stuck_reverse_timer -= delta
		_movement.ai_move_input = -1.0
		_movement.ai_turn_input = 0.0
		return

	if not _has_waypoint_target:
		_pick_new_waypoint_target()
		_nav_agent.target_position = _waypoint_target_pos

	var to_target: Vector3 = _waypoint_target_pos - _body.global_position
	to_target.y = 0.0
	if to_target.length() < waypoint_reach_dist:
		_advance_waypoint()
		return

	# [ИСПРАВЛЕНО] get_current_navigation_path() САМ ПО СЕБЕ не обновляется — Godot пересчитывает
	# путь под капотом именно по вызову get_next_path_position() (проверено живьём: path[0] был
	# позицией бота МНОГИХ кадров/вейпоинтов давности, пока не звали эту функцию — один вызов
	# мгновенно освежал путь). Раньше эта функция вызывалась для СВОЕГО возврата, теперь — для
	# ПОБОЧНОГО ЭФФЕКТА обновления, сам возврат не используется: целимся не в сырую точку, а в
	# pure-pursuit lookahead (см. @export-блок выше про срез угла), но БЕЗ этого вызова
	# _get_lookahead_point() работала бы по протухшему пути и бот кружил бы у собственной позиции
	# нескольких вейпоинтов назад (живой тест: 0-2 перехода/30с вместо 30+, пока не нашли).
	_nav_agent.get_next_path_position()
	var next_point: Vector3 = _get_lookahead_point()
	var desired_world_yaw: float = _yaw_to_world_point(_body.global_position, next_point)

	var yaw_diff: float = wrapf(desired_world_yaw - _body.rotation.y, -PI, PI)
	# Знак: TankMovement._physics_process() делает _body.rotate_y(-turn_input*turn_speed*delta),
	# т.е. turn_input>0 УМЕНЬШАЕТ rotation.y, а не увеличивает (проверено живьём покадровым
	# прогоном — с прямым знаком (turn_input=yaw_diff/0.5, как в этой же формуле у
	# tank_ai_controller.gd._drive_toward(), см. дев-план в заголовке файла) бот ехал К ЦЕЛИ
	# ДЛИННЫМ путём и на развороте, близком к 180°, залипал на антиподе цели, до конца не сходясь
	# — ai_turn_input каждый кадр дёргался -1/+1 без прогресса). Поэтому здесь знак ОБРАТНЫЙ.
	_movement.ai_turn_input = clamp(-yaw_diff / 0.5, -1.0, 1.0)

	# Аварийный тормоз — веер из 3 коротких лучей по КОРПУСУ (не по направлению на next_point —
	# тормозим от того, что реально перед носом прямо сейчас, см. @export-блок выше). Только
	# гасит ход, направление не выбирает — это по-прежнему навмеш.
	var brake_hit: bool = _check_emergency_brake()
	_movement.ai_move_input = 1.0 if (not brake_hit and absf(yaw_diff) < deg_to_rad(60.0)) else 0.0

	# Антизастрял по чистому смещению за окно (см. @export-блок выше про контактную вибрацию,
	# которую ловит мгновенная скорость). Копим окно, только пока УЖЕ довернули достаточно, чтобы
	# по-хорошему ехать (yaw_diff < 60° — иначе обычный доворот в начале отрезка, не застревание,
	# ложно посчитался бы "нет прогресса"); тормоз (brake_hit) при этом НЕ исключение — если корпус
	# развёрнут верно, но тормоз/контакт не пускает вперёд кадр за кадром, это и есть застревание.
	# Раз в stuck_detect_sec сравниваем текущую позицию с той, что была на начало окна — если
	# сдвинулись меньше stuck_min_progress ЗА ВСЁ ОКНО, застряли.
	if absf(yaw_diff) < deg_to_rad(60.0):
		_stuck_check_timer += delta
		if _stuck_check_timer >= stuck_detect_sec:
			var progress: float = _body.global_position.distance_to(_stuck_check_pos)
			_stuck_check_pos = _body.global_position
			_stuck_check_timer = 0.0
			if progress < stuck_min_progress:
				_stuck_reverse_timer = stuck_reverse_sec
	else:
		_stuck_check_timer = 0.0
		_stuck_check_pos = _body.global_position

## Pure pursuit — точка на (эффективном) lookahead ВПЕРЁД по полилинии текущего NavMesh-пути от
## позиции, ближайшей к боту прямо сейчас (не просто "следующий узел пути", см. @export-блок в
## заголовке файла про срез угла). Идём по сегментам от ближайшей к боту точки пути, вычитая их
## длины из остатка lookahead, пока не наберётся нужное расстояние — тогда интерполируем внутри
## этого сегмента.
##
## [ИСПРАВЛЕНО] Фиксированный nav_lookahead_distance (3м) давал устойчивое КРУЖЕНИЕ рядом с целью
## вместо схождения — учебный случай деградации pure pursuit: если lookahead больше оставшегося
## расстояния до ФИНАЛЬНОЙ цели, геометрия "целься на N метров вперёд" на подъезде уводит корпус
## по кругу вокруг цели, а не к ней (найдено живым тестом: 0 переходов за 30с, позиция металась в
## радиусе ~0.15м у вейпоинта бесконечно). Решение — эффективный lookahead ограничен расстоянием
## до _waypoint_target_pos: далеко от цели используется полный nav_lookahead_distance (широкие
## дуги вокруг препятствий), а на подъезде lookahead плавно сжимается до нуля, вырождаясь в "целься
## точно в цель" — без этого схождение вообще невозможно геометрически, не только медленное.
func _get_lookahead_point() -> Vector3:
	var path: PackedVector3Array = _nav_agent.get_current_navigation_path()
	if path.size() < 2:
		return _nav_agent.get_next_path_position()

	var pos: Vector3 = _body.global_position
	var effective_lookahead: float = minf(nav_lookahead_distance, pos.distance_to(_waypoint_target_pos))

	# Проекция бота на саму ломаную (на ОТРЕЗОК, не на ближайшую вершину) — иначе получается
	# самоподдерживающееся равновесие "цель = я сам": если считать lookahead-дистанцию от
	# ближайшей ВЕРШИНЫ, а не от текущего положения бота, то как только бот доезжает ровно до
	# точки на расстоянии nav_lookahead_distance от этой вершины (а он к этому и стремится по
	# конструкции pure pursuit), цель перестаёт зависеть от его реального положения и застывает
	# точно в месте, где он стоит — направление на цель вырождается в нулевой вектор, руль
	# получает шумовой (не осмысленный) угол и бот крутится на месте бесконечно, не продвигаясь
	# (воспроизведено живьём: 60с прогон, позиция заморожена, rotation.y растёт линейно — чистый
	# спин без прогресса). Fix: мерить lookahead-дистанцию от ПРОЕКЦИИ бота на путь, не от вершины.
	var best_seg := 0
	var best_t := 0.0
	var best_dist := INF
	for i in range(path.size() - 1):
		var a: Vector3 = path[i]
		var b: Vector3 = path[i + 1]
		var seg: Vector3 = b - a
		var seg_len_sq: float = seg.length_squared()
		var t: float = clampf((pos - a).dot(seg) / seg_len_sq, 0.0, 1.0) if seg_len_sq > 0.0001 else 0.0
		var d: float = pos.distance_to(a + seg * t)
		if d < best_dist:
			best_dist = d
			best_seg = i
			best_t = t

	var from_point: Vector3 = path[best_seg].lerp(path[best_seg + 1], best_t)
	var seg_left: float = from_point.distance_to(path[best_seg + 1])
	var remaining: float = effective_lookahead
	if seg_left >= remaining:
		return from_point.lerp(path[best_seg + 1], remaining / seg_left) if seg_left > 0.0001 else path[best_seg + 1]
	remaining -= seg_left
	var i: int = best_seg + 1
	while i < path.size() - 1:
		var seg_len: float = path[i].distance_to(path[i + 1])
		if seg_len >= remaining:
			return path[i].lerp(path[i + 1], remaining / seg_len)
		remaining -= seg_len
		i += 1
	return path[path.size() - 1]

## Веер из 3 коротких лучей (0°, ±emergency_brake_spread_deg от корпуса) — см. @export-блок в
## заголовке файла про слепой угол одного центрального луча. ЛЮБОЙ хит ближе emergency_brake_range
## считается тормозом; никакая сторона/направление здесь не выбирается, только да/нет.
func _check_emergency_brake() -> bool:
	var origin: Vector3 = _body.global_position + Vector3.UP * 0.4
	var body_yaw: float = _body.rotation.y
	var space_state := _body.get_world_3d().direct_space_state
	for offset_deg in [0.0, -emergency_brake_spread_deg, emergency_brake_spread_deg]:
		var ray_yaw: float = body_yaw + deg_to_rad(offset_deg)
		var dir := Vector3(-sin(ray_yaw), 0.0, -cos(ray_yaw))
		var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * emergency_brake_range)
		query.exclude = [_body]
		query.collision_mask = 1 | 2 | 4
		query.collide_with_areas = true
		if not space_state.intersect_ray(query).is_empty():
			return true
	return false

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
	_max_leg_time_sec = max(_max_leg_time_sec, _leg_timer)  # рекорд — только обновляется, никогда не сбрасывается
	_leg_timer = 0.0
	_waypoint_index = (_waypoint_index + 1) % _waypoints.size()
	_has_waypoint_target = false

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
func _setup_path_debug_draw() -> void:
	_path_debug_mesh = MeshInstance3D.new()
	_path_debug_mesh.name = "PathDebugMesh"
	_path_debug_mesh.mesh = ImmediateMesh.new()
	_path_debug_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	_path_debug_mesh.material_override = mat
	_body.add_child.call_deferred(_path_debug_mesh)

## Голубая ломаная — весь ОСТАВШИЙСЯ путь по навмешу прямо сейчас (NavigationAgent3D.
## get_current_navigation_path()), не только следующая точка — видно всю дугу, которой бот
## огибает препятствия, не только текущий локальный шаг. _path_debug_mesh — ДОЧЕРНИЙ узел
## _body, поэтому мировые точки пути переводятся в ЛОКАЛЬНЫЕ координаты через
## _body.global_transform.affine_inverse() (тот же класс требования, что и у конуса обзора —
## ImmediateMesh ждёт координаты относительно СВОЕГО родителя, не мировые).
func _update_path_debug_draw() -> void:
	var mesh: ImmediateMesh = _path_debug_mesh.mesh
	mesh.clear_surfaces()
	if state != State.PATROL or _nav_agent == null or not _nav_agent.is_inside_tree():
		return
	var path: PackedVector3Array = _nav_agent.get_current_navigation_path()
	if path.size() < 2:
		return

	const HEIGHT := 0.4
	var inv_xform: Transform3D = _body.global_transform.affine_inverse()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	mesh.surface_set_color(Color(0.2, 0.85, 0.95, 0.9))
	for p in path:
		mesh.surface_add_vertex(inv_xform * (p + Vector3.UP * HEIGHT))
	mesh.surface_end()

	# Оранжевая точка — куда РЕАЛЬНО целится pure pursuit прямо сейчас (_get_lookahead_point(),
	# см. заголовок файла) — НЕ то же самое, что ближайший узел голубой линии; лежит дальше по
	# полилинии на nav_lookahead_distance. Маленький крестик, не просто линия, чтобы не путать
	# с самой ломаной пути.
	var lookahead: Vector3 = inv_xform * (_get_lookahead_point() + Vector3.UP * HEIGHT)
	const MARK := 0.4
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_set_color(Color(1.0, 0.6, 0.1, 0.95))
	mesh.surface_add_vertex(lookahead + Vector3(-MARK, 0, 0))
	mesh.surface_add_vertex(lookahead + Vector3(MARK, 0, 0))
	mesh.surface_add_vertex(lookahead + Vector3(0, 0, -MARK))
	mesh.surface_add_vertex(lookahead + Vector3(0, 0, MARK))
	mesh.surface_end()

	# Веер из 3 лучей-тормоза (0°, ±emergency_brake_spread_deg, см. @export-блок в заголовке файла)
	# — красные, если ЛЮБОЙ хит ближе emergency_brake_range (тормоз реально держит ai_move_input
	# на нуле для всех троих разом, см. _check_emergency_brake()), иначе все зелёные. Рисуем в
	# ЛОКАЛЬНЫХ координатах корпуса (0° = -Z), поэтому тут просто deg_to_rad(offset) без world_yaw.
	var brake_hit_dbg: bool = _check_emergency_brake()
	var brake_color: Color = Color(0.95, 0.15, 0.1, 0.9) if brake_hit_dbg else Color(0.2, 0.9, 0.3, 0.7)
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_set_color(brake_color)
	for offset_deg in [0.0, -emergency_brake_spread_deg, emergency_brake_spread_deg]:
		var local_dir := Vector3(-sin(deg_to_rad(offset_deg)), 0.0, -cos(deg_to_rad(offset_deg)))
		mesh.surface_add_vertex(Vector3(0.0, HEIGHT, 0.0))
		mesh.surface_add_vertex(local_dir * emergency_brake_range + Vector3(0.0, HEIGHT, 0.0))
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
	lines.append("session: %.1f min   record leg: %.1fs" % [_total_time_sec / 60.0, _max_leg_time_sec])
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
			if _nav_agent != null and _nav_agent.is_inside_tree():
				lines.append("nav: %d pts left" % _nav_agent.get_current_navigation_path().size())
		State.IDLE:
			lines.append("looking around")
	if _wander_holding:
		lines.append("look: holding (%.1fs left)" % _wander_hold_timer)
	else:
		lines.append("look: turning")
	_brain_debug_label.text = "\n".join(lines)
