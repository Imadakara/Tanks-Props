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
##      KILLER со сконфигурированной зоной охоты (см. HUNT ниже) → HUNT.
##   3. Нет вообще ничего подходящего (ACHIEVER без вейпоинтов/KILLER без зоны охоты) → IDLE.
## Явный класс-приоритет, а не набор независимых if — переход между "домашним" стейтом и DEFEND
## всегда решается заново каждый think-тик, поэтому оба направления (заметил/потерял цель) идут
## через одну и ту же точку принятия решения, не рассинхронизируются. PURSUE — ИСКЛЮЧЕНИЕ из этого
## правила по конструкции, см. его описание ниже.
##
## Стейты:
## - IDLE ("ожидание") — бот неподвижен, взгляд блуждает по всему кругу (360°, см. _wander()).
## - PATROL ("патруль", домашнее для ACHIEVER) — бесконечное движение по вейпоинтам (см. ниже).
## - HUNT ("охота", домашнее для KILLER, по прямому запросу) — бесконечное движение по СЛУЧАЙНЫМ
##   точкам в пределах зоны охоты (см. _pick_new_hunt_target()) — тот же driving-стек
##   (NavMesh/pure pursuit/тормоз/антизастрял/gap-scan-обход), что и PATROL, просто без привязки к
##   вейпоинтам objective: KILLER не сторожит точку, а прочёсывает всю карту в поиске цели.
##   Достигнутая точка не даёт "накопленного маршрута" — просто выбирается новая случайная (в
##   отличие от PATROL, где порядок вейпоинтов фиксирован). Цель недостижима (перегорожена
##   геометрией, слишком далеко) — hunt_target_timeout_sec страхует от вечного тыка в одну точку.
## - PURSUE ("преследование", по прямому запросу) — включается ТОЛЬКО у KILLER, ТОЛЬКО в момент
##   потери видимой цели (_on_target_lost()), еду к _pursue_target_pos — последней ЖИВОЙ позиции
##   цели (запоминается в _last_known_target_pos КАЖДЫЙ кадр, пока цель видна в DEFEND, см.
##   _aim_and_fire()). Тот же driving-стек, что PATROL/HUNT. Доехал (или изначально не видел, кого
##   догонять) → возврат в HUNT. Заметил цель СНОВА по дороге — обычный приоритет "видит → DEFEND"
##   из _think() срабатывает как обычно (PURSUE не особый случай для этой проверки, только для
##   _ensure_home_state(), см. её комментарий — PURSUE не перезаписывается домашним поведением
##   каждый think-тик, завершается только сам, доехав до точки).
## - DEFEND ("оборона позиции") — стоит на месте, башня/взгляд каждый кадр наводятся на ЖИВУЮ
##   позицию цели, огонь по готовности прицела/дальности/боекомплекта.
## Обнаружил цель в любом "домашнем" стейте → мгновенно (в рамках think_interval_sec) переход в
## DEFEND, движение останавливается. Потерял цель (вышла из конуса/дальности/видимости, или
## уничтожена) → ACHIEVER возвращается к PATROL как раньше; KILLER уходит в PURSUE (см. выше), из
## которого попадает в HUNT. Блуждание взгляда продолжается с текущего угла на всех переходах;
## вейпоинт-прогресс ACHIEVER (индекс/точка в круге) не сбрасывается.
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
## - HUNT/PURSUE (см. выше) реализованы для роли KILLER целиком, не только у HARD, по прямому
##   запросу — изначально в ТЗ PURSUE обсуждался как HARD-эксклюзив, но финальное решение шире:
##   это часть цикла самой роли KILLER, не тонкая настройка сложности. Если позже понадобится
##   разница по уровням — например, EASY/MEDIUM забывают last-known-position быстрее или вообще
##   возвращаются в HUNT сразу без PURSUE — единая точка правки всё та же: _on_target_lost().
## - Роль ACHIEVER для команды атаки — сейчас проверена только для обороны (движение к
##   objective/патруль вокруг него). Поведение атакующего ачивера (движение К objective противника,
##   через собственные вейпоинты/линию атаки) не проверялось.
## - Пересчёт положения вейпоинтов относительно objective для произвольной боевой карты (не
##   зафиксировано формулой, сейчас три точки подобраны вручную под конкретную геометрию тестовой
##   арены).
## - Правка знака `ai_turn_input` в продакшен `tank_ai_controller.gd` — см. дев-план в Bot AI
##   Sandbox §8, находка №7.
##
## Уровни сложности (difficulty) — все числовые @export ниже это тюнинг MEDIUM (тот самый
## "текущий бот"), EASY/HARD — пресеты в _apply_difficulty_preset(), применяются поверх этих
## значений при _ready(). Чтобы поменять баланс MEDIUM — править сами @export; чтобы
## поменять EASY/HARD — саму таблицу _DIFFICULTY_PRESETS.

enum State { IDLE, PATROL, DEFEND, HUNT, PURSUE }
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

## HUNT — зона охоты для роли KILLER (см. заголовок файла). Прямоугольник по X/Z вокруг
## hunt_area_center с половинными размерами hunt_area_half_extents — оставлены НУЛЯМИ по умолчанию,
## тогда в _ready() зона детектится АВТОМАТИЧЕСКИ по AABB узла "Ground" на карте (см.
## _detect_hunt_area()): архитектурная заметка в заголовке файла требует, чтобы логика бота не была
## завязана на конкретную геометрию тестовой арены — на боевой карте другой размер/форма земли не
## потребует правки кода, только пересборки навмеша. Задать вручную (например, если Ground на карте
## не единый прямоугольник, или нужна зона УЖЕ карты) — выставить hunt_area_half_extents ненулевым,
## тогда автодетект пропускается целиком.
@export var hunt_area_center: Vector3 = Vector3.ZERO
@export var hunt_area_half_extents: Vector2 = Vector2.ZERO
## Точка HUNT недостижима (перегорожена геометрией, слишком далеко) — не тыкаться в неё вечно,
## переключиться на новую случайную точку после этого времени. Отдельная страховка ПОВЕРХ
## stuck_reverse_sec/stuck_detour_sec (те лечат локальное заедание, эта — "может, сама точка
## недостижима в принципе", не про физику конкретного столкновения).
@export var hunt_target_timeout_sec: float = 25.0

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
## pure pursuit выше, а угол объезда при застревании — отдельный скан _scan_gap(), см. ниже).
## [ИСПРАВЛЕНО] Один луч строго по центру не ловил контакт корпусом ПОД УГЛОМ (см. Bot AI Sandbox
## §12 — живой тест: get_slide_collision() показал реальный физический контакт с препятствием, а
## brake_hit с одним центральным лучом был false, тот же слепой угол, что и у одиночного луча в
## самой первой версии объезда, §11.1) — веер, ЛЮБОЙ хит близко считается тормозом. Если что-то
## оказалось ближе emergency_brake_range — ai_move_input жёстко на 0 в этом кадре (доворот
## продолжается) — последний рубеж защиты от несовершенства pure-pursuit-следования, не замена
## NavMesh-планирования тем самым реактивным лидаром, от которого ушли (три коротких луча на кадр
## несравнимо дешевле прежних 3 непрерывно качающихся на полную дальность, и не участвуют в выборе
## курса вообще). Пробовал расширить веер ещё двумя лучами ±60° — откачено, см. ниже.
## Длина лучей (по прямому запросу — "бот порой не успевает остановиться перед препятствием"):
## тормозной путь на полном ходу v²/(2·acceleration) = 4.5²/(2·12) ≈ 0.84м (TankMovement:
## move_speed=6.0 × move_speed_multiplier=0.75, acceleration=12 м/с²) — геометрически 1.8м уже
## хватало с запасом на статике. [ПОПРОБОВАНО И ОТКАЧЕНО] Поднимал до 3.0 — на этой карте статика
## расставлена ПЛОТНО, а NavMesh-путь по конструкции идёт впритык к agent_radius (см. @export выше
## про полудиагональ) — луч длиннее ~1.8-2.0м стабильно задевает СОСЕДНЕЕ препятствие на обычной
## дуге объезда угла, даже когда прямо по курсу ничего нет. Проверено живьём (`run_script`, один и
## тот же стартовый сегмент карты, без игрока-блокиратора вообще, 20с): range=1.8 → 2 ложных
## реверса/25.6м прогресса; range=2.0 → уже 4/11.3м; range=2.2 → 9/1.9м; range=3.0 → 5-10/3.5-5.4м
## (хуже почти вдвое-впятеро при любом угле). Вывод: на ЭТОЙ карте 1.8м — практический потолок,
## дальше цена (частые ложные "застревания" на ровном месте) быстро перекрывает выгоду реакции.
## Оставлено 1.8 — если карта станет просторнее, стоит перепроверить эмпирически заново, не
## поднимать вслепую.
@export var emergency_brake_range: float = 1.8
@export var emergency_brake_spread_deg: float = 20.0
## [ЗАМЕНЕНО НА GAP-SCAN] Была пара фиксированных лучей ±60° для выбора стороны объезда — по
## прямому запросу заменена на скан веером (_scan_gap() ниже), см. Bot AI Sandbox §12.9: два
## фиксированных угла не находили реально свободный проём, если он лежал под ДРУГИМ углом (узкое
## место у стыка двух статических препятствий + рядом стоящий игрок) — бот выбирал "LEFT" или
## "RIGHT" по зонду, физически упирался во что-то ещё под этим же зафиксированным углом, откатывался
## и пробовал ТО ЖЕ самое направление снова (зонд на новой попытке видел ту же геометрию) —
## наблюдаемый живьём бесконечный "отъехал-довернул-снова уткнулся" без сходимости.
## Скан кастует лучи от -stuck_detour_scan_span_deg/2 до +.../2 с шагом stuck_detour_scan_step_deg
## на stuck_detour_probe_range, ищет самый широкий НЕПРЕРЫВНЫЙ интервал лучей с клиренсом не хуже
## stuck_detour_scan_clear_ratio·probe_range — то есть находит РЕАЛЬНО открытый проём, а не гадает
## по двум точкам.
@export var stuck_detour_scan_span_deg: float = 160.0
@export var stuck_detour_scan_step_deg: float = 10.0
@export var stuck_detour_scan_clear_ratio: float = 0.6

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

## Реверс один не спасает от СТАТИЧНО стоящего динамического препятствия (игрок специально встал
## поперёк маршрута) — навмеш ничего не знает про игрока, путь остаётся тем же, pure pursuit после
## реверса снова целится в ту же точку старого пути → снова тормоз → снова реверс, бесконечный
## цикл подъехал-откатился (воспроизведено живьём по прямому запросу — скриншот). После реверса —
## короткая фаза БОКОВОГО обхода: прямое рулевое отклонение в сторону найденного скан-веером проёма
## (_scan_gap(), не выбор навмеша) на stuck_detour_sec, потом возвращаемся к обычному pure pursuit.
## Целимся в ФИКСИРОВАННЫЙ мировой угол (посчитанный ОДИН раз в момент обнаружения застревания —
## см. _detour_target_world_yaw), не пересчитываем его каждый кадр от текущего rotation.y — иначе
## по мере доворота цель "убегает" вместе с корпусом, yaw_diff никогда не уменьшается, руль
## насыщен весь stuck_detour_sec целиком, и на второй/третий такой цикл подряд бот каждый раз
## доворачивает на один и тот же (иногда неверный) угол вместо плавного схождения к найденному
## проёму — см. Bot AI Sandbox §12.9.
##
## [ДОБАВЛЕНО, по прямому запросу — "после отъезда надо запускать пересчёт маршрута"] По окончании
## фазы обхода — принудительный реассайн _nav_agent.target_position (см. _drive_to_waypoint()).
## Проверено эмпирически (run_script, подписка на path_changed): NavigationAgent3D САМ ПО СЕБЕ не
## перезапрашивает путь просто от того, что агент физически сдвинулся — 5 кадров движения без
## нашего вмешательства дали 0 эмиссий path_changed. Путь остаётся ТОЙ ЖЕ полилинией, посчитанной
## один раз при первой постановке target_position; get_next_path_position()/pure pursuit лишь
## проецируют текущую позицию на эту старую полилинию (см. Bot AI Sandbox §12.6 про её собственный
## "рефреш" — это продвижение курсора по СУЩЕСТВУЮЩЕМУ пути, не новый A*-запрос). Пользователь был
## прав: "маршрут тот же" — буквально так и есть. Реассайн target_position ЛЮБЫМ значением (даже
## тем же самым) форсит НОВЫЙ запрос к NavigationServer3D от ТЕКУЩЕЙ позиции (подтверждено: +1
## эмиссия path_changed на реассайн тем же значением) — после обхода бот физически в другой точке,
## новый путь от неё может быть удобнее старого.
@export var stuck_detour_sec: float = 1.2
@export var stuck_detour_probe_range: float = 4.5

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
## Кнопка на экране, переключающая enemy_reaction_enabled ниже (по прямому запросу — гонять
## поведение вживую, катаясь на PlayerTank, без правки кода/рестарта).
@export var show_reaction_toggle_button: bool = true

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

## HUNT — зона детектится в _ready() (см. @export-блок выше), _hunt_area_valid=false, если не
## удалось (нет ни ручных half_extents, ни узла "Ground" на карте) — тогда KILLER без вейпоинтов
## падает в IDLE, симметрично тому, как ACHIEVER без вейпоинтов падает в IDLE.
var _hunt_area_valid: bool = false
var _hunt_target_pos: Vector3 = Vector3.ZERO
var _has_hunt_target: bool = false
var _hunt_target_timer: float = 0.0

## PURSUE — _pursue_target_pos выставляется РОВНО ОДИН РАЗ в _on_target_lost() (не меняется по
## ходу самой фазы, в отличие от _waypoint_target_pos/_hunt_target_pos, которые живут много кадров
## и требуют флага "уже выбрана" — PURSUE-цель разовая, флаг не нужен). _last_known_target_pos —
## обновляется КАЖДЫЙ кадр в _aim_and_fire(), пока цель видна (для ЛЮБОЙ роли — дёшево, читается
## только когда роль KILLER решает уйти в PURSUE, но пишется всегда, не хранить отдельный путь для
## KILLER-only).
var _pursue_target_pos: Vector3 = Vector3.ZERO
var _last_known_target_pos: Vector3 = Vector3.ZERO

## NavigationAgent3D — заводится в _ready() как ребёнок _body (см. заголовок файла). Плюс сам
## meш для отрисовки текущего пути (see _update_path_debug_draw()).
var _nav_agent: NavigationAgent3D
var _path_debug_mesh: MeshInstance3D

## Антизастрял — по чистому смещению за окно, см. @export-блок выше. _stuck_check_pos — позиция
## на начало текущего окна замера, _stuck_check_timer — сколько уже накопилось в этом окне.
var _stuck_check_pos: Vector3 = Vector3.ZERO
var _stuck_check_timer: float = 0.0
var _stuck_reverse_timer: float = 0.0

## Фаза бокового обхода после реверса (см. @export-блок выше) — _detour_target_world_yaw:
## ФИКСИРОВАННЫЙ мировой угол (посчитан один раз в момент обнаружения застревания через
## _scan_gap(), см. её комментарий), не пересчитывается по ходу самой фазы. _detour_timer<=0 —
## обход не идёт (либо не начинался, либо скан не нашёл проёма при последней попытке).
var _detour_timer: float = 0.0
var _detour_target_world_yaw: float = 0.0

var _brain_debug_label: Label

## Тумблер "реакция на противников" (по прямому запросу) — обычная var, НЕ @export: регулируется
## В РАНТАЙМЕ кнопкой (_setup_reaction_toggle_button()), а не настройкой инстанса при старте.
## ВЫКЛ означает: бот продолжает домашнее поведение роли (патруль/ожидание), не сканирует и не
## реагирует на попадания (см. гейты в _think()/_on_damaged()) — но физически всё ещё считает
## противника препятствием: _check_emergency_brake() смотрит на collision_mask 1|2|4 (tanks
## входит) и вообще не завязан на _think()/_current_target, так что тормозит перед игроком
## независимо от этого флага — ровно то разделение "игнорирует как цель, но объезжает как объект",
## которое просили.
var enemy_reaction_enabled: bool = true
var _reaction_toggle_button: Button

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
	_detect_hunt_area()

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
	if show_reaction_toggle_button:
		_setup_reaction_toggle_button()

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

## Зона охоты для KILLER (см. @export-блок выше) — вручную заданный hunt_area_half_extents
## побеждает автодетект целиком (проверяется первым). Автодетект ищет узел "Ground" РЕКУРСИВНО по
## всей текущей сцене (find_child, owned=false — вейпоинты лежат в корне, но статическая геометрия
## карты в этой песочнице живёт глубже, под NavigationRegion3D, см. BotArena.tscn), берёт его
## CollisionShape3D и, если это BoxShape3D, вычисляет мировой AABB по X/Z из shape.size и
## глобальной позиции узла (предполагает, что земля НЕ повёрнута — разумное допущение для плоской
## карты; если понадобится наклонная/непрямоугольная земля — тогда вручную через @export).
## Ничего не нашли/не тот тип формы — _hunt_area_valid остаётся false, KILLER без зоны падает в
## IDLE (см. _ensure_home_state()), не молча катается по всей карте с нулевым радиусом.
func _detect_hunt_area() -> void:
	if hunt_area_half_extents != Vector2.ZERO:
		_hunt_area_valid = true
		return
	var ground: Node = get_tree().current_scene.find_child("Ground", true, false)
	if ground == null:
		return
	var collision_shape: CollisionShape3D = ground.get_node_or_null("CollisionShape3D")
	if collision_shape == null or collision_shape.shape == null:
		return
	var shape: Shape3D = collision_shape.shape
	if not (shape is BoxShape3D):
		return
	var box: BoxShape3D = shape
	hunt_area_center = collision_shape.global_position
	hunt_area_half_extents = Vector2(box.size.x * 0.5, box.size.z * 0.5)
	_hunt_area_valid = true

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
		State.HUNT:
			_drive_to_hunt_point(delta)
			_wander(delta, true)
			_turret.target_yaw = wrapf(_look_yaw - _body.rotation.y, -PI, PI)
		State.PURSUE:
			# Доехал до последней видимой позиции цели (или не с чем сравнивать — reach_dist от
			# самого начала) → возврат к поиску; нет зоны охоты (не настроена) — тогда IDLE, а не
			# HUNT-без-области (см. _detect_hunt_area()/_ensure_home_state()).
			if _drive_to_point(delta, _pursue_target_pos, waypoint_reach_dist):
				state = State.HUNT if _hunt_area_valid else State.IDLE
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
	# Тумблер выключен (см. @export-блок про show_reaction_toggle_button) — не сканируем и не
	# держим цель вообще, сразу домашнее поведение роли. Если бот был в DEFEND в момент выключения
	# (нажали кнопку прямо во время боя) — выходим из него тем же путём, что при обычной потере
	# цели, максимум через один think_interval_sec.
	if not enemy_reaction_enabled:
		if state == State.DEFEND:
			_on_target_lost()
		_ensure_home_state()
		return

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
## с расставленными вейпоинтами патрулирует; KILLER со сконфигурированной зоной охотится (HUNT);
## иначе — просто стоит и смотрит по кругу (IDLE). PURSUE — ИСКЛЮЧЕНИЕ: не трогаем, пока сам
## не завершится (доехал до последней видимой позиции цели, см. State.PURSUE в _physics_process())
## — иначе эта функция, вызываемая КАЖДЫЙ think-тик, пока цель не видна, немедленно перезаписала бы
## только что начатую погоню обратно на HUNT на первом же тике.
func _ensure_home_state() -> void:
	if state == State.PURSUE:
		return
	var desired: State
	if role == Role.ACHIEVER and not _waypoints.is_empty():
		desired = State.PATROL
	elif role == Role.KILLER and _hunt_area_valid:
		desired = State.HUNT
	else:
		desired = State.IDLE
	if state != desired:
		state = desired
		# _look_yaw/_wander_holding намеренно НЕ сбрасываются — блуждание продолжается с
		# текущего угла на любом переходе.

## Цель потеряна/уничтожена во время DEFEND. ACHIEVER — единообразно для всех уровней сложности,
## просто возврат к домашнему поведению роли (_ensure_home_state() вызывается сразу после в
## _think()). KILLER (любой уровень сложности, по прямому запросу — не HARD-эксклюзив, см. дев-план
## в заголовке файла) — уходит в PURSUE к _last_known_target_pos (записана КАЖДЫЙ кадр, пока цель
## была видна, см. _aim_and_fire() — не читаем target.global_position ЗДЕСЬ, target может быть уже
## невалиден/freed к этому моменту, если цель именно уничтожена, не просто скрылась из виду).
func _on_target_lost() -> void:
	if role == Role.KILLER:
		_pursue_target_pos = _last_known_target_pos
		state = State.PURSUE
		_nav_agent.target_position = _pursue_target_pos
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

## Вызывается КАЖДЫЙ think-тик, пока _can_see(target) подтверждает видимость (см. _think()) — не
## каждый физ.кадр. Поэтому именно здесь, а не в _aim_and_fire() (которая крутится каждый физ.кадр
## БЕЗ проверки видимости, чисто по живой позиции _current_target для плавной наводки), обновляем
## _last_known_target_pos — источник PURSUE у KILLER (см. _on_target_lost()). [ИСПРАВЛЕНО] Раньше
## обновлялась в _aim_and_fire() каждый физ.кадр безусловно — между think-тиками (до
## think_interval_sec) цель могла реально скрыться из виду, а _aim_and_fire() продолжала бы писать
## её ТЕКУЩУЮ (уже физически невидимую боту) позицию до следующей проверки _can_see(); PURSUE тогда
## ехал бы не к последней ВИДИМОЙ точке, а к точке, где цель оказалась ПОСЛЕ того как скрылась —
## найдено живым тестом с резким телепортом цели (утрировало обычно небольшую 0.1с-погрешность до
## абсурдной: pursue-точка совпала с координатами телепорта за 96м от бота, не с последней реально
## видимой позицией).
func _enter_defend(target: Node) -> void:
	state = State.DEFEND
	_current_target = target
	_last_known_target_pos = target.global_position

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
	if not enemy_reaction_enabled:
		return
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
## следующему (индекс всегда по модулю — патруль бесконечный). Тонкая обёртка над _drive_to_point()
## (общий driving-стек, см. её комментарий) — тут только вейпоинт-специфика: выбор точки внутри
## круга текущего маркера и статистика _leg_timer/_advance_waypoint().
func _drive_to_waypoint(delta: float) -> void:
	_leg_timer += delta  # копится, пока пытаемся дойти до текущего вейпоинта — см. _advance_waypoint()
	if _waypoints.is_empty():
		_movement.ai_move_input = 0.0
		_movement.ai_turn_input = 0.0
		return
	if not _has_waypoint_target:
		_pick_new_waypoint_target()
		_nav_agent.target_position = _waypoint_target_pos
	if _drive_to_point(delta, _waypoint_target_pos, waypoint_reach_dist):
		_advance_waypoint()

## HUNT — доехать до случайной точки в зоне охоты, затем выбрать новую (см. @export-блок про
## hunt_area_*/_pick_new_hunt_target()). Тонкая обёртка, симметричная _drive_to_waypoint(), только
## без вейпоинт-индекса (все точки равноправны, никакого фиксированного порядка) и с
## hunt_target_timeout_sec — точка может оказаться физически недостижимой (перегорожена
## геометрией), обычный антизастрял в _drive_to_point() лечит ЛОКАЛЬНОЕ заедание, а не "эта
## конкретная точка в принципе плохая цель", отдельный таймер страхует именно от второго.
func _drive_to_hunt_point(delta: float) -> void:
	if not _hunt_area_valid:
		_movement.ai_move_input = 0.0
		_movement.ai_turn_input = 0.0
		return
	if not _has_hunt_target:
		_pick_new_hunt_target()
		_nav_agent.target_position = _hunt_target_pos
		_hunt_target_timer = 0.0
	_hunt_target_timer += delta
	if _drive_to_point(delta, _hunt_target_pos, waypoint_reach_dist) or _hunt_target_timer >= hunt_target_timeout_sec:
		_has_hunt_target = false

## Общий driving-стек для ЛЮБОЙ точки-цели (PATROL/HUNT/PURSUE зовут её с разным target_pos) —
## NavigationAgent3D/NavMesh для маршрута, pure pursuit для следования (см. _get_lookahead_point()),
## короткий луч-тормоз (emergency_brake_range), антизастрял по чистому смещению за окно, и, если
## застряли — реверс + gap-scan-обход (см. соответствующие @export-блоки выше). НЕ трогает
## _nav_agent.target_position САМ — это ответственность вызывающего (решает, КОГДА цель сменилась
## и требует нового реассайна, см. _drive_to_waypoint()/_drive_to_hunt_point() и State.PURSUE).
## Возвращает true, когда target_pos достигнута (reach_dist) — что делать дальше решает вызывающий.
func _drive_to_point(delta: float, target_pos: Vector3, reach_dist: float) -> bool:
	# NavigationAgent3D добавляется через add_child.call_deferred() в _ready() (сцена ещё строится
	# в момент, когда доходит очередь до этого сиблинга) — на первый физ.кадр(ы) он ещё может быть
	# не в дереве. get_next_path_position() на таком агенте кидает ошибку ("agent has no parent"),
	# а не просто возвращает нейтральный результат — ждём, пока агент реально окажется в дереве.
	if not _nav_agent.is_inside_tree():
		_movement.ai_move_input = 0.0
		_movement.ai_turn_input = 0.0
		return false

	# Аварийный реверс уже идёт — досиживаем его, дальше идёт фаза обхода (ниже), а не сразу
	# обратно к pure pursuit.
	if _stuck_reverse_timer > 0.0:
		_stuck_reverse_timer -= delta
		_movement.ai_move_input = -1.0
		_movement.ai_turn_input = 0.0
		return false

	# Фаза бокового обхода после реверса (см. @export-блок про stuck_detour_*/_scan_gap() выше) —
	# рулим к ФИКСИРОВАННОМУ мировому углу _detour_target_world_yaw (посчитан один раз в момент
	# обнаружения застревания, не пересчитывается тут) — та же формула, что и обычный pure pursuit
	# ниже, поэтому yaw_diff естественно СХОДИТСЯ по мере доворота, а не остаётся насыщенным весь
	# stuck_detour_sec (в отличие от прежней версии, где цель пересчитывалась каждый кадр от
	# текущего rotation.y — см. её разбор в @export-блоке). Тормоз по-прежнему только гасит ход,
	# не рулит; yaw-гейт на move_input здесь не нужен — двигаться боком и есть цель этой фазы.
	if _detour_timer > 0.0:
		_detour_timer -= delta
		var detour_yaw_diff: float = wrapf(_detour_target_world_yaw - _body.rotation.y, -PI, PI)
		_movement.ai_turn_input = clamp(-detour_yaw_diff / 0.5, -1.0, 1.0)
		_movement.ai_move_input = 1.0 if not _check_emergency_brake() else 0.0
		if _detour_timer <= 0.0:
			# Обход закончился — форсируем пересчёт пути от ТЕКУЩЕЙ (уже смещённой в сторону)
			# позиции (см. @export-блок про stuck_detour_* — проверено живьём: без этого путь
			# остаётся старой полилинией). Реассайн тем же значением достаточен — сработает даже
			# если target_pos не поменялась.
			_nav_agent.target_position = target_pos
		return false

	var to_target: Vector3 = target_pos - _body.global_position
	to_target.y = 0.0
	if to_target.length() < reach_dist:
		return true

	# [ИСПРАВЛЕНО] get_current_navigation_path() САМ ПО СЕБЕ не обновляется — Godot пересчитывает
	# путь под капотом именно по вызову get_next_path_position() (проверено живьём: path[0] был
	# позицией бота МНОГИХ кадров/вейпоинтов давности, пока не звали эту функцию — один вызов
	# мгновенно освежал путь). Раньше эта функция вызывалась для СВОЕГО возврата, теперь — для
	# ПОБОЧНОГО ЭФФЕКТА обновления, сам возврат не используется: целимся не в сырую точку, а в
	# pure-pursuit lookahead (см. @export-блок выше про срез угла), но БЕЗ этого вызова
	# _get_lookahead_point() работала бы по протухшему пути и бот кружил бы у собственной позиции
	# нескольких вейпоинтов назад (живой тест: 0-2 перехода/30с вместо 30+, пока не нашли).
	_nav_agent.get_next_path_position()
	var next_point: Vector3 = _get_lookahead_point(target_pos)
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
				# Проём выбирается ЗДЕСЬ (позиция/поворот на момент обнаружения застревания), а
				# не после реверса — реверс не меняет rotation.y (turn_input=0 всё это время), так
				# что мировой угол остаётся валиден к началу фазы обхода. Проёма нет вообще (NAN) —
				# detour-фазу пропускаем в этот раз, только реверс (см. блок выше).
				var gap_deg: float = _scan_gap()
				if is_nan(gap_deg):
					_detour_timer = 0.0
				else:
					_detour_target_world_yaw = wrapf(_body.rotation.y + deg_to_rad(gap_deg), -PI, PI)
					_detour_timer = stuck_detour_sec
	else:
		_stuck_check_timer = 0.0
		_stuck_check_pos = _body.global_position
	return false

## Текущая цель driving-стека — какой бы стейт её ни задавал. Нужна ТОЛЬКО для отладочной
## отрисовки (см. _update_path_debug_draw()) — сама driving-логика (_drive_to_point()) получает
## target_pos явным параметром от вызывающего стейта и этот helper не использует. IDLE/DEFEND сюда
## не попадают (см. вызывающий код), но на случай будущих изменений возвращают текущую позицию
## бота как безопасный no-op, а не мусорное значение.
func _current_drive_target() -> Vector3:
	match state:
		State.PATROL:
			return _waypoint_target_pos
		State.HUNT:
			return _hunt_target_pos
		State.PURSUE:
			return _pursue_target_pos
		_:
			return _body.global_position

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
## до target_pos (общий параметр — раньше читался прямо из _waypoint_target_pos, когда эта функция
## умела следовать только за PATROL-вейпоинтом; см. @export-блок про refactor под HUNT/PURSUE):
## далеко от цели используется полный nav_lookahead_distance (широкие дуги вокруг препятствий), а
## на подъезде lookahead плавно сжимается до нуля, вырождаясь в "целься точно в цель" — без этого
## схождение вообще невозможно геометрически, не только медленное.
func _get_lookahead_point(target_pos: Vector3) -> Vector3:
	var path: PackedVector3Array = _nav_agent.get_current_navigation_path()
	if path.size() < 2:
		return _nav_agent.get_next_path_position()

	var pos: Vector3 = _body.global_position
	var effective_lookahead: float = minf(nav_lookahead_distance, pos.distance_to(target_pos))

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

## Веер из 3 коротких лучей (0°, ±emergency_brake_spread_deg от корпуса) — см. @export-блок про
## отдельную, широкую попытку добавить сюда ещё пару лучей и её откат. ЛЮБОЙ хит ближе
## emergency_brake_range считается тормозом; сторона/направление здесь не выбирается, только да/нет
## (сторону/угол объезда решает _scan_gap()).
func _check_emergency_brake() -> bool:
	for offset_deg in [0.0, -emergency_brake_spread_deg, emergency_brake_spread_deg]:
		if _cast_ray(offset_deg, emergency_brake_range):
			return true
	return false

## Один луч от корпуса (высота +0.4, тот же принцип, что у аварийного тормоза), возвращает
## РАССТОЯНИЕ до хита (или range, если ничего не поймал) — не просто bool, нужно для _scan_gap()
## (сравнение с порогом клиренса), для bool-использования (_check_emergency_brake()) достаточно
## сравнить результат с range.
func _cast_ray_dist(offset_deg: float, range: float) -> float:
	var origin: Vector3 = _body.global_position + Vector3.UP * 0.4
	var ray_yaw: float = _body.rotation.y + deg_to_rad(offset_deg)
	var dir := Vector3(-sin(ray_yaw), 0.0, -cos(ray_yaw))
	var space_state := _body.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * range)
	query.exclude = [_body]
	query.collision_mask = 1 | 2 | 4
	query.collide_with_areas = true
	var result: Dictionary = space_state.intersect_ray(query)
	if result.is_empty():
		return range
	return origin.distance_to(result["position"])

## bool-обёртка над _cast_ray_dist() — true, если что-то есть БЛИЖЕ range (используется тормозом,
## где нужен только да/нет, не расстояние).
func _cast_ray(offset_deg: float, range: float) -> bool:
	return _cast_ray_dist(offset_deg, range) < range

## Скан веером (см. @export-блок про stuck_detour_scan_*) — ищет РЕАЛЬНО открытый проём вместо
## гадания по двум фиксированным углам (см. её историю в @export-блоке). Кастует лучи от
## -stuck_detour_scan_span_deg/2 до +.../2 с шагом stuck_detour_scan_step_deg на
## stuck_detour_probe_range; луч считается "открытым", если хит дальше stuck_detour_scan_clear_ratio
## · stuck_detour_probe_range (или вообще не поймал ничего). Среди НЕПРЕРЫВНЫХ пробегов открытых
## лучей берём самый широкий (при равенстве — ближе к 0°, минимальный лишний доворот) и возвращаем
## угол его середины в градусах, ОТНОСИТЕЛЬНО текущего _body.rotation.y. Ни одного открытого луча —
## возвращаем NAN (вызывающий код тогда не запускает фазу обхода, только реверс).
func _scan_gap() -> float:
	var half_span: float = stuck_detour_scan_span_deg * 0.5
	var step: float = maxf(stuck_detour_scan_step_deg, 1.0)
	var angles: Array[float] = []
	var a: float = -half_span
	while a <= half_span + 0.01:
		angles.append(a)
		a += step

	var clearance: float = stuck_detour_probe_range * stuck_detour_scan_clear_ratio
	var clear: Array[bool] = []
	for ang in angles:
		clear.append(_cast_ray_dist(ang, stuck_detour_probe_range) >= clearance)

	var zero_idx := 0
	var zero_dist := INF
	for i in range(angles.size()):
		if absf(angles[i]) < zero_dist:
			zero_dist = absf(angles[i])
			zero_idx = i

	var best_start := -1
	var best_len := 0
	var best_center_dist := INF
	var i := 0
	while i < clear.size():
		if not clear[i]:
			i += 1
			continue
		var start: int = i
		while i < clear.size() and clear[i]:
			i += 1
		var run_len: int = i - start
		var center_dist: float = absf((start + i - 1) / 2.0 - zero_idx)
		if run_len > best_len or (run_len == best_len and center_dist < best_center_dist):
			best_len = run_len
			best_start = start
			best_center_dist = center_dist

	if best_start == -1:
		return NAN
	var center_idx: float = (best_start + best_start + best_len - 1) / 2.0
	return -half_span + center_idx * step

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

## Случайная точка в прямоугольнике зоны охоты (равномерно по X/Z — тут это буквально
## randf_range на каждую ось независимо, не нужен трюк со sqrt(), как у круга вейпоинта: зона
## прямоугольная, не круглая, равномерность площади уже есть "из коробки").
func _pick_new_hunt_target() -> void:
	var x: float = randf_range(-hunt_area_half_extents.x, hunt_area_half_extents.x)
	var z: float = randf_range(-hunt_area_half_extents.y, hunt_area_half_extents.y)
	_hunt_target_pos = hunt_area_center + Vector3(x, 0.0, z)
	_has_hunt_target = true

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
		State.HUNT:
			fill_color = Color(0.95, 0.7, 0.1, 0.24)  # жёлто-оранжевый — "охотится", между PATROL и DEFEND
		State.PURSUE:
			fill_color = Color(1.0, 0.45, 0.05, 0.26)  # ближе к красному — уже почти нашёл, погоня
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
	var driving: bool = state == State.PATROL or state == State.HUNT or state == State.PURSUE
	if not driving or _nav_agent == null or not _nav_agent.is_inside_tree():
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
	# с самой ломаной пути. Целевая точка зависит от текущего state (см. _current_drive_target()).
	var lookahead: Vector3 = inv_xform * (_get_lookahead_point(_current_drive_target()) + Vector3.UP * HEIGHT)
	const MARK := 0.4
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_set_color(Color(1.0, 0.6, 0.1, 0.95))
	mesh.surface_add_vertex(lookahead + Vector3(-MARK, 0, 0))
	mesh.surface_add_vertex(lookahead + Vector3(MARK, 0, 0))
	mesh.surface_add_vertex(lookahead + Vector3(0, 0, -MARK))
	mesh.surface_add_vertex(lookahead + Vector3(0, 0, MARK))
	mesh.surface_end()

	# Веер из 3 лучей-тормоза (0°, ±emergency_brake_spread_deg, см. @export-блок в заголовке файла
	# про то, почему широкая пара НЕ входит сюда) — красные, если ЛЮБОЙ хит ближе
	# emergency_brake_range (тормоз реально держит ai_move_input на нуле для всех разом, см.
	# _check_emergency_brake()), иначе все зелёные. ЛОКАЛЬНЫЕ координаты корпуса (0° = -Z).
	var brake_hit_dbg: bool = _check_emergency_brake()
	var brake_color: Color = Color(0.95, 0.15, 0.1, 0.9) if brake_hit_dbg else Color(0.2, 0.9, 0.3, 0.7)
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_set_color(brake_color)
	for offset_deg in [0.0, -emergency_brake_spread_deg, emergency_brake_spread_deg]:
		var local_dir := Vector3(-sin(deg_to_rad(offset_deg)), 0.0, -cos(deg_to_rad(offset_deg)))
		mesh.surface_add_vertex(Vector3(0.0, HEIGHT, 0.0))
		mesh.surface_add_vertex(local_dir * emergency_brake_range + Vector3(0.0, HEIGHT, 0.0))
	mesh.surface_end()

	# Пока идёт фаза обхода — жёлтая линия на найденный _scan_gap() проём (_detour_target_world_yaw,
	# мировой угол, переводим в локальные координаты корпуса вычитанием rotation.y). Не
	# пересчитываем сам скан каждый кадр только ради отрисовки (17 лучей — не бесплатно) — рисуем
	# уже сохранённый результат, есть только пока _detour_timer>0.
	if _detour_timer > 0.0:
		var local_target_deg: float = rad_to_deg(wrapf(_detour_target_world_yaw - _body.rotation.y, -PI, PI))
		var target_dir := Vector3(-sin(deg_to_rad(local_target_deg)), 0.0, -cos(deg_to_rad(local_target_deg)))
		mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		mesh.surface_set_color(Color(0.95, 0.85, 0.15, 0.9))
		mesh.surface_add_vertex(Vector3(0.0, HEIGHT, 0.0))
		mesh.surface_add_vertex(target_dir * stuck_detour_probe_range + Vector3(0.0, HEIGHT, 0.0))
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

## Тот же приём, что и у _setup_brain_debug_label() — отдельный CanvasLayer, не трогаем разметку
## HUD.tscn. Внизу слева (HUD занимает левый верх, brain debug — правый верх, тут свободно).
func _setup_reaction_toggle_button() -> void:
	var layer := CanvasLayer.new()
	layer.name = "BotReactionToggleLayer"
	var button := Button.new()
	button.name = "BotReactionToggleButton"
	button.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	button.offset_left = 16.0
	button.offset_top = -56.0
	button.offset_right = 236.0
	button.offset_bottom = -16.0
	button.pressed.connect(_on_reaction_toggle_pressed)
	layer.add_child(button)
	_reaction_toggle_button = button
	# call_deferred по той же причине, что и у остальных дебаг-узлов (см. _setup_fov_debug_draw) —
	# сцена ещё строится в момент, когда доходит очередь до этого (последнего) сиблинга.
	get_tree().current_scene.add_child.call_deferred(layer)
	_update_reaction_toggle_button()

func _on_reaction_toggle_pressed() -> void:
	enemy_reaction_enabled = not enemy_reaction_enabled
	_update_reaction_toggle_button()

func _update_reaction_toggle_button() -> void:
	if _reaction_toggle_button == null:
		return
	_reaction_toggle_button.text = "Enemy reaction: ON" if enemy_reaction_enabled else "Enemy reaction: OFF"

func _update_brain_debug_label() -> void:
	if _brain_debug_label == null:
		return
	var lines: Array = []
	lines.append("=== BOT BRAIN ===")
	lines.append("session: %.1f min   record leg: %.1fs" % [_total_time_sec / 60.0, _max_leg_time_sec])
	lines.append("role: %s   difficulty: %s" % [Role.keys()[role], Difficulty.keys()[difficulty]])
	lines.append("state: %s   reaction: %s" % [State.keys()[state], "ON" if enemy_reaction_enabled else "OFF"])
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
				lines.append("to point: %.1fm" % _body.global_position.distance_to(_waypoint_target_pos))
			_append_nav_debug_lines(lines)
		State.HUNT:
			if _has_hunt_target:
				lines.append("to point: %.1fm" % _body.global_position.distance_to(_hunt_target_pos))
			_append_nav_debug_lines(lines)
		State.PURSUE:
			lines.append("last seen at: %.1fm" % _body.global_position.distance_to(_pursue_target_pos))
			_append_nav_debug_lines(lines)
		State.IDLE:
			lines.append("looking around")
	if _wander_holding:
		lines.append("look: holding (%.1fs left)" % _wander_hold_timer)
	else:
		lines.append("look: turning")
	_brain_debug_label.text = "\n".join(lines)

## Общий хвост для всех driving-стейтов (PATROL/HUNT/PURSUE) в brain-панели — путь навмеша и
## статус реверса/обхода, если он идёт. Вынесено, чтобы не дублировать одни и те же 5 строк трижды.
func _append_nav_debug_lines(lines: Array) -> void:
	if _nav_agent != null and _nav_agent.is_inside_tree():
		lines.append("nav: %d pts left" % _nav_agent.get_current_navigation_path().size())
	if _stuck_reverse_timer > 0.0:
		lines.append("STUCK: reversing (%.1fs left)" % _stuck_reverse_timer)
	elif _detour_timer > 0.0:
		var local_deg: float = rad_to_deg(wrapf(_detour_target_world_yaw - _body.rotation.y, -PI, PI))
		lines.append("STUCK: detour %.0f° (%.1fs left)" % [local_deg, _detour_timer])
