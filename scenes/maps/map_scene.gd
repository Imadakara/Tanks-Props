extends Node3D
## MapScene — оркестрация одной игровой карты (`TargetObjectiveMap.tscn`/`TeamArenaMap.tscn`, обе —
## шаблоны игровых режимов, см. корневой CLAUDE.md "Game modes"/"Map inventory"). Маленький явный
## orchestration-скрипт в корне сцены вместо разбрасывания правок по чужим `_ready()` — тот же
## паттерн, что и остальные общие оркестраторы проекта (`TeamSpawner`, `MatchManager`).
##
## - Режим карты — `@export match_mode` на корне (задан в `.tscn`: `TargetObjectiveMap.tscn` =
##   TARGET_OBJECTIVE, `TeamArenaMap.tscn` = TEAM_ARENA), НЕ детект по наличию узла `Objective`.
##   Это «настройка карты», не строка в HUD.
## - `_setup_match_context()` заводит из кода `ScoreManager` + узел `"MatchManager"` (см.
##   `scenes/main/match_manager.gd`) — полноценный постраундовый цикл. HUD находит
##   "MatchManager"/`RoundTimer`/`FinalStageTimer` одними и теми же лукапами на любой карте.
## - По `MatchManager.round_ended` (чья-то победа) — `_on_round_ended_teardown()`: глушит
##   `TeamSpawner` + все `RespawnController` и `force_destroy()` всем танкам (MVP-«заморозка поля»
##   на экран результата). Эти смерти не идут в счёт убийств (killer=null).
## - Финальная стадия (доп. время после основного таймера, если бой в тупике) — ОПЦИЯ КАРТЫ:
##   `@export var final_stage_enabled`, задаётся в `.tscn`. По умолчанию вкл на `TeamArenaMap`,
##   выкл на `TargetObjectiveMap` (там время вышло → сразу победа защиты). Условие/поведение —
##   в `match_manager.gd`.
## - Кнопка "Objective On/OFF" — переключает `HealthComponent.invincible` на цели, текст отражает
##   состояние; появляется только там, где на карте вообще есть `Objective` (нет на
##   `TeamArenaMap.tscn`, режим TEAM_ARENA). Здоровье цели в HUD рисует сам `hud.gd`.
## - Переключение камер (1/2/3) — чтобы наблюдать бота от третьего лица, не гоняясь за ним на
##   собственном танке. "1" — обычная камера игрока; "2" — статичная камера над центральным
##   кластером препятствий; "3" — статичная камера сверху над всем полем (тот же приём, что
##   используется для диагностики через `godot-runtime` MCP — см. skill `godot-mcp-testing`).
##   `ObjectiveCamera` целится через `look_at()` в `_ready()`, а не хардкодом `Transform3D` в
##   `.tscn` — ручные `Transform3D`-литералы сериализуются построчно, а не по столбцам, и легко
##   смотрят не туда, если считать поворот как три вектора-столбца (см. кросс-проектную Godot
##   knowledge base, п.1).

const ScoreManagerScript := preload("res://scenes/main/score_manager.gd")
const MatchManagerScript := preload("res://scenes/main/match_manager.gd")
const ObjectiveAlertStateScript := preload("res://scenes/main/objective_alert_state.gd")
const ExtractionManagerScript := preload("res://scenes/main/extraction_manager.gd")
const DynamicObstaclePlacerScript := preload("res://scenes/obstacles/dynamic_obstacle_placer.gd")

## Игровой режим карты — ЗАДАЁТСЯ В СЦЕНЕ (@export на корне: `TargetObjectiveMap.tscn` = 0,
## `TeamArenaMap.tscn` = 1), не детектится по наличию узла Objective. Значения совпадают с
## `MatchState.Mode` (0 = TARGET_OBJECTIVE, 1 = TEAM_ARENA).
## Дефолт = -1 (sentinel, НЕ валидный режим) намеренно: и 0, и 1 тогда — НЕ-дефолтные значения,
## и редактор Godot всегда сериализует их в .tscn. Дефолт 0 приводил к тому, что GUI-сейв карты
## каждый раз вырезал строку `match_mode = 0` из TargetObjectiveMap.tscn (равно дефолту → не
## пишется), а пропавший `match_mode` молча читается как TARGET_OBJECTIVE — на карте, которой
## нужен TEAM_ARENA, это тихая поломка. Проверка на -1 — в _setup_match_context().
@export_enum("TARGET_OBJECTIVE", "TEAM_ARENA", "EXTRACTION") var match_mode: int = -1

## Опция карты: наступает ли финальная стадия (доп. время + продолжающийся сброс ящиков), когда
## основное время раунда вышло, а у всех живых танков кончился боезапас. Условие/логику см.
## match_manager.gd. Дефолт false. В .tscn строка есть ТОЛЬКО у карт с true (TeamArenaMap) —
## редактор Godot не пишет значения, равные дефолту; отсутствие строки в TargetObjectiveMap.tscn
## это норма, не потеря (читается как false).
@export var final_stage_enabled: bool = false

## Опция карты: строить ли непроходимую красную границу по периметру пола (см. _build_map_borders).
## ПО УМОЛЧАНИЮ ВКЛ. Выключить имеет смысл только для карты со своими границами/геометрией края.
## Дефолт true == то, что нужно почти любой карте, поэтому строки `map_border_enabled = true` в
## .tscn обычно НЕТ (редактор не пишет дефолт) — это норма. Строка появляется только если карта
## явно ставит false.
@export var map_border_enabled: bool = true

## Опция карты: печь ли навмеш ЗАНОВО при каждом старте сцены, вместо того чтобы хранить готовый
## в .tscn. Дефолт false — обе «плоские» карты (TargetObjectiveMap/TeamArenaMap) держат запечённый
## редактором навмеш в файле сцены, как и раньше, строки в их .tscn нет.
## true имеет смысл на карте, геометрию которой активно двигают: ручная перепечка кнопкой
## «Bake NavigationMesh» в редакторе после КАЖДОЙ правки (см. Tank_Prop_Hunt_Obstacles_Navmesh_Guide.md)
## — главный тормоз итераций, а для многоуровневой карты правок в разы больше, чем для плоской.
## Механизм тот же, что у динамической расстановки (_apply_dynamic_obstacles): bake_navigation_mesh()
## + await bake_finished + физ.кадр на синк NavigationServer, до спавна ботов. Когда геометрия
## устоится — выключить и запечь в .tscn руками, чтобы не платить запечкой на каждом старте.
@export var bake_navmesh_on_start: bool = false

## Опция карты: применима ли к ней вообще динамическая расстановка препятствий (галочка в меню →
## MatchState.dynamic_obstacles). Дефолт true — строки в .tscn у «плоских» карт нет.
## false обязателен для карты, чья геометрия собрана из Obstacle-подобных узлов НЕ как сменное
## укрытие: _apply_dynamic_obstacles() безусловно сносит всю группу "obstacles". Кухня свою мебель
## держит на Structure (группа "structures", см. structure.gd) и потому уцелела бы, но случайные
## кубы, разбросанные по XZ без понятия об этажах, на многоуровневой карте всё равно бессмысленны.
@export var dynamic_obstacles_supported: bool = true

@onready var _player_camera_rig: Node3D = $PlayerTank/CameraRig
@onready var _player_health: Node = $PlayerTank/HealthComponent
@onready var _objective_camera: Camera3D = $ObjectiveCamera
@onready var _overview_camera: Camera3D = $OverviewCamera
## ObjectiveAlertZone — дочерний узел самого Objective (часть его «префаба») — рекурсивный
## find_child, а не $ObjectiveAlertZone: на TeamArenaMap (TEAM_ARENA, без Objective) его нет
## вовсе → null, enemy_in_alert_zone() это переваривает.
@onready var _alert_zone: Node3D = find_child("ObjectiveAlertZone", true, false)

var _objective_health: Node = null
var _extraction_manager: Node = null  # только в режиме EXTRACTION, иначе null
var _objective_toggle_button: Button
var _invincibility_toggle_button: Button
var _ignore_player_toggle_button: Button
var _bot_spawn_buttons: Array[Button] = []  # debug-кнопки «+ Бот», гасятся на конце раунда

## ALERT-таймер/гео-проверка живут ЗДЕСЬ (корень сцены) — никогда не замораживаются на респавне
## отдельных ботов (в отличие от них самих, см. respawn_controller.gd), копятся РОВНО ОДИН РАЗ на
## всех, не дублируются по ботам. Каждый TankAIController читает через time_since_objective_hit()
## (см. ниже), а не хранит свою копию — "уже существующий" и "только что заспавнившийся" бот видят
## ОДНО И ТО ЖЕ значение. Логика самого таймера/гео-проверки — переиспользуемый класс
## (scenes/main/objective_alert_state.gd), этот скрипт просто владеет своим экземпляром.
var _alert_state := ObjectiveAlertStateScript.new()

## $TeamSpawner.spawn_team() встаёт ПЕРЕД _setup_match_context() — та сканирует группу "tanks"
## через ScoreManager/MatchManager.begin_match()/setup(), должна видеть уже полный состав (см.
## корневой CLAUDE.md, "Scene bring-up ordering").
func _ready() -> void:
	# ПЕРВЫМ ДЕЛОМ, до любого await ниже. Раньше режим проставлялся в _setup_match_context() в
	# конце _ready(), и это работало, пока _ready() был синхронным: чужие ленивые инициализации
	# (ammo_drop_zone.gd в своём первом _process) гарантированно шли после него. Как только в
	# _ready() появились ожидания (запечка навмеша, динамические препятствия), гарантия исчезла —
	# зона сброса успевала прочитать MatchState.match_mode ДО присвоения и получала режим прошлой
	# сцены (кухня заводила мортирный каденс по правилам TARGET_OBJECTIVE, 30с вместо 75с).
	# Присвоение режима ничего из дерева не требует, поэтому его можно и нужно делать до ожиданий.
	_apply_match_mode_to_state()
	_build_map_borders()
	# Динамический пресет препятствий (галочка в меню → MatchState.dynamic_obstacles). Держим
	# старт раунда до конца асинхронной перепечки навмеша — боты/менеджер матча заводятся уже по
	# новой карте проходимости.
	if MatchState.dynamic_obstacles and dynamic_obstacles_supported:
		await _apply_dynamic_obstacles()
	elif bake_navmesh_on_start:
		await _bake_navmesh()
	if MatchState.debug_enabled:
		_setup_invincibility_toggle_button()
		_setup_bot_spawn_buttons()
		_setup_ignore_player_toggle_button()
	$TeamSpawner.spawn_team()
	_setup_match_context()
	# ObjectiveCamera смотрит на саму цель (не хардкод-точка): позиция берётся с узла Objective,
	# если он на карте есть; иначе — центр поля (камера всё равно доступна только в debug, клавиша 2).
	var objective_node: Node3D = get_tree().current_scene.find_child("Objective", true, false)
	var look_target: Vector3 = objective_node.global_position if objective_node != null else Vector3(0.0, 1.0, 0.0)
	_objective_camera.look_at(look_target, Vector3.UP)
	_setup_objective_ui()

## Непроходимая красная граница по периметру карты — 4 стены-коробки вокруг узла `Ground`.
## Строится ИЗ КОДА (не в .tscn каждой карты): размеры берутся из коллайдера `Ground`, работает
## для любой карты без ручной правки. Физическая (StaticBody3D, слой environment) — бот не может
## выехать за край, даже если driving-стек толкнёт его туда (навмеш этого не гарантирует). Танк,
## всё же оказавшийся ниже пола — принудительно убивается (respawn_controller.gd). Контейнер
## кладётся ПОД NavigationRegion3D — при ручной перепечке навмеша (см. Obstacles_Navmesh_Guide)
## стены вырежут края навмеша, и боты будут держаться от них дальше; до перепечки физическая
## стена всё равно не даёт выехать.
const _BORDER_HEIGHT := 3.0
const _BORDER_THICKNESS := 1.0

## Динамическая расстановка: сколько раз перекатить зерно, если раскладка отрезала спавны/цель
## (см. _apply_dynamic_obstacles). 30 кубов 2×2 на 72×72 практически никогда не заваливают
## проход — это страховка, не нормальный путь.
const _DYNAMIC_MAX_REROLLS := 4

func _build_map_borders() -> void:
	if not map_border_enabled:
		return
	var ground: Node3D = find_child("Ground", true, false)
	if ground == null:
		return
	var shape: BoxShape3D = ground.get_node("CollisionShape3D").shape
	var half_x: float = shape.size.x * 0.5
	var half_z: float = shape.size.z * 0.5
	var top_y: float = ground.global_position.y + shape.size.y * 0.5  # верх пола (обычно y = 0)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.15, 0.05, 0.5)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var container := Node3D.new()
	container.name = "MapBorders"
	ground.get_parent().add_child(container)  # под NavigationRegion3D, рядом с Ground

	var t: float = _BORDER_THICKNESS
	var span_x: float = half_x * 2.0 + t * 2.0  # длиннее пола на толщину — углы стыкуются без щели
	var span_z: float = half_z * 2.0 + t * 2.0
	# [центр по XZ, размер коробки] — внутренняя грань каждой стены заподлицо с краем Ground
	var specs := [
		[Vector2(0.0, half_z + t * 0.5), Vector3(span_x, _BORDER_HEIGHT, t)],
		[Vector2(0.0, -half_z - t * 0.5), Vector3(span_x, _BORDER_HEIGHT, t)],
		[Vector2(half_x + t * 0.5, 0.0), Vector3(t, _BORDER_HEIGHT, span_z)],
		[Vector2(-half_x - t * 0.5, 0.0), Vector3(t, _BORDER_HEIGHT, span_z)],
	]
	for i in specs.size():
		var xz: Vector2 = specs[i][0]
		var size: Vector3 = specs[i][1]
		var body := StaticBody3D.new()
		body.name = "Border%d" % (i + 1)
		body.collision_mask = 0  # стена ничего не детектит; слой оставляем дефолтный (1 = environment)
		var col := CollisionShape3D.new()
		col.name = "CollisionShape3D"
		var box := BoxShape3D.new()
		box.size = size
		col.shape = box
		body.add_child(col)
		var mesh_inst := MeshInstance3D.new()
		mesh_inst.name = "Mesh"
		var box_mesh := BoxMesh.new()
		box_mesh.size = size
		mesh_inst.mesh = box_mesh
		mesh_inst.material_override = mat
		body.add_child(mesh_inst)
		container.add_child(body)
		body.global_position = Vector3(xz.x, top_y + _BORDER_HEIGHT * 0.5, xz.y)

## Режим карты → MatchState. Вызывается ПЕРВОЙ строкой _ready(), до любых ожиданий (см. там).
## match_mode дефолт = -1 (см. @export выше). Если он всё ещё -1 — строку `match_mode` вырезали
## из .tscn (GUI-сейв при значении = старому дефолту 0) либо новая карта её не задала. Не молчим:
## 0/1/2 теперь НЕ-дефолтны, редактор их не режет; -1 здесь = реальная ошибка конфигурации карты.
func _apply_match_mode_to_state() -> void:
	if match_mode < 0:
		push_error("map_scene: match_mode не задан на корне %s — выставь в .tscn (0=TARGET_OBJECTIVE, 1=TEAM_ARENA, 2=EXTRACTION). Фолбэк на TARGET_OBJECTIVE." % scene_file_path)
		match_mode = MatchState.Mode.TARGET_OBJECTIVE
	MatchState.match_mode = match_mode
	# Формат матча — свойство режима, не общая константа (экстракшен — один раунд, остальные —
	# best-of-3). Ставим при КАЖДОЙ загрузке карты: autoload переживает смену сцены, иначе число
	# протекло бы с предыдущей карты (см. MatchState.apply_mode_defaults).
	MatchState.apply_mode_defaults(match_mode)

## Перепечь навмеш карты на старте (@export bake_navmesh_on_start, см. его doc-comment). Ждётся
## вызывающим _ready() — боты лениво инициализируются уже после него и стартуют по готовой карте
## проходимости. Тип парсинга форсируем на STATIC_COLLIDERS по той же причине, что и в
## _apply_dynamic_obstacles(): на рантайме читать визуальные меши обратно с GPU дорого и шумит
## варнингом, а вся геометрия карты — StaticBody3D на слое 1 (Ground/Structure/ToyRamp/Obstacle).
func _bake_navmesh() -> void:
	var nav := get_node_or_null("NavigationRegion3D") as NavigationRegion3D
	if nav == null or nav.navigation_mesh == null:
		push_warning("map_scene: bake_navmesh_on_start включён, но NavigationRegion3D/navigation_mesh не найден — запечка пропущена")
		return
	nav.navigation_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav.bake_navigation_mesh()
	await nav.bake_finished
	await get_tree().physics_frame  # NavigationServer синкает карту на физ.кадре после запечки

## Динамический пресет препятствий (см. корневой CLAUDE.md "Dynamic obstacle system",
## Tank_Prop_Hunt_Obstacles_Navmesh_Guide.md §9). Убирает статические Obstacle.tscn карты
## (HazardZone* остаются — они editor-placed и ограничивают поле), расставляет до 30 случайных
## кубов по правилам dynamic_obstacle_placer.gd и ПЕРЕПЕКАЕТ навмеш; если раскладка отрезала
## спавны/цель друг от друга — перекатывает зерно (до _DYNAMIC_MAX_REROLLS раз). Bake асинхронный
## — вызывающий _ready() ждёт этот метод (await), чтобы боты стартовали уже по новой проходимости
## (см. Obstacles_Navmesh_Guide §7.3). Раскладка одна на весь матч: зерно в MatchState переживает
## reload_current_scene(), зануляется в reset_series() (меню / «Новый матч»). Финальное зерно =
## то, что дало связную карту — оно и держится для раундов 2-3 (и его же слал бы хост в сетевой игре).
func _apply_dynamic_obstacles() -> void:
	var nav := get_node_or_null("NavigationRegion3D") as NavigationRegion3D
	if nav == null:
		push_warning("map_scene: NavigationRegion3D не найден — динамические препятствия пропущены")
		return
	# Парсим ТОЛЬКО статические коллайдеры (Ground/Obstacle — StaticBody, слой 1) — быстро, без
	# GPU→CPU readback визуальных мешей (тот на рантайме стопорит рендер, WARNING
	# navigation_mesh_source_geometry_data_3d). HazardZone это НЕ меняет: она и в editor-запечке
	# `BOTH` навмеш не вырезала (проверено — `geometry_collision_mask=5` на деле режет только слой
	# 1), боты обходят зоны реактивно лучами объезда — см. hazard_zone.gd. Статические карты навмеш
	# не перепекают, их .tscn parsed_geometry_type не хранит (дефолт ресурса — BOTH).
	if nav.navigation_mesh != null:
		nav.navigation_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS

	var link_pairs := _dynamic_layout_link_pairs()
	if MatchState.dynamic_obstacles_seed == 0:
		MatchState.dynamic_obstacles_seed = randi() % 2147483646 + 1  # 1..2^31-2, никогда 0

	var attempt := 0
	while true:
		attempt += 1
		# Убрать всё в группе "obstacles": на 1-й итерации — статические кубы карты, на реролле —
		# свои динамические с прошлой попытки. remove_child синхронно, перепечка их уже не увидит.
		for obs in get_tree().get_nodes_in_group("obstacles"):
			if is_instance_valid(obs):
				obs.get_parent().remove_child(obs)
				obs.queue_free()
		var placed := DynamicObstaclePlacerScript.populate(self, nav, MatchState.dynamic_obstacles_seed)
		nav.bake_navigation_mesh()
		await nav.bake_finished
		await get_tree().physics_frame  # NavigationServer синкает карту на физ-кадре после запечки
		var connected := _dynamic_layout_connected(nav, link_pairs)
		if connected or attempt >= _DYNAMIC_MAX_REROLLS:
			if MatchState.debug_enabled:
				print("map_scene: динамический пресет — %d препятствий, seed %d, попыток %d, связно=%s"
					% [placed, MatchState.dynamic_obstacles_seed, attempt, connected])
			if not connected:
				push_warning("map_scene: динамическая раскладка после %d попыток рвёт связность спавнов/цели — оставляю как есть" % attempt)
			return
		MatchState.dynamic_obstacles_seed = randi() % 2147483646 + 1  # реролл

## Пары точек, которые ОБЯЗАНЫ остаться связными по навмешу после расстановки (иначе раунд
## непроходим): спавн атаки ↔ спавн обороны всегда; + каждый спавн ↔ objective, если он на карте.
func _dynamic_layout_link_pairs() -> Array:
	var out: Array = []
	var atk := get_tree().current_scene.find_child("AttackSpawnZone", true, false) as Node3D
	var dfn := get_tree().current_scene.find_child("DefenseSpawnZone", true, false) as Node3D
	var obj := get_tree().current_scene.find_child("Objective", true, false) as Node3D
	if atk != null and dfn != null:
		out.append([atk.global_position, dfn.global_position])
	if obj != null and atk != null:
		out.append([atk.global_position, obj.global_position])
	if obj != null and dfn != null:
		out.append([dfn.global_position, obj.global_position])
	return out

## true — по всем парам _dynamic_layout_link_pairs() навмеш даёт СВЯЗНЫЙ путь. map_get_path с
## optimize возвращает частичный путь до ближайшей достижимой точки, если цель отрезана — поэтому
## мало проверить size()>=2, надо ещё что последняя точка реально рядом с целью.
func _dynamic_layout_connected(nav: NavigationRegion3D, pairs: Array) -> bool:
	var nav_map: RID = nav.get_navigation_map()
	for pair in pairs:
		var from: Vector3 = pair[0]
		var to: Vector3 = pair[1]
		var path: PackedVector3Array = NavigationServer3D.map_get_path(nav_map, from, to, true)
		if path.size() < 2:
			return false
		if path[path.size() - 1].distance_to(to) > 5.0:
			return false
	return true

## [УДАЛЕНО, по прямому запросу — "общая универсальная система для зон, единый визуал"] Раньше
## здесь жила отдельная пунктирная рисовалка кругов под вейпоинтами (`_build_waypoint_debug()`,
## `_WAYPOINT_DEBUG_RADIUS=7.5` — захардкоженное число, НЕ связанное с реальным
## `TankAIController.waypoint_radius`, тоже 7.5, но отдельной константой — два независимых
## источника одного и того же числа). Вейпоинты (`Waypoint*`/`AttackWaypoint*`/`DefenseWaypoint*`)
## теперь — узлы на `spawn_zone.gd`, том же скрипте, что у spawn/ammo/alert/hide-зон: каждый сам
## рисует свой круг в `_ready()` (см. `spawn_zone.gd._draw_debug_circle()`) с СОБСТВЕННЫМ
## `@export radius`, который реально используется в логике (`_pick_new_waypoint_target()`), а не
## только для вида. Один визуал на все виды зон вместо двух параллельных механизмов.

## Заводит ScoreManager/MatchManager из кода (не статичными узлами сцены — обе карты используют
## один и тот же общий оркестратор). Режим берётся из @export match_mode (задан в .tscn — «настройка
## карты»). Серию НЕ сбрасываем: она копится через reload_current_scene() между раундами; сброс —
## только из меню (main_menu.gd) и кнопкой «Новый матч» (hud.gd).
func _setup_match_context() -> void:
	# match_mode дефолт = -1 (см. @export выше). Если он всё ещё -1 — строку `match_mode` вырезали
	# из .tscn (GUI-сейв при значении = старому дефолту 0) либо новая карта её не задала. Не молчим:
	# 0/1 теперь НЕ-дефолтны, редактор их не режет; -1 здесь = реальная ошибка конфигурации карты.
	var score_manager := Node.new()
	score_manager.name = "ScoreManager"
	score_manager.set_script(ScoreManagerScript)
	add_child(score_manager)
	score_manager.begin_match()  # $TeamSpawner.spawn_team() уже отработал в _ready() выше — состав в группе "tanks" полный

	var objective := get_tree().current_scene.find_child("Objective", true, false)
	var objective_health: Node = objective.get_node_or_null("HealthComponent") if objective != null else null
	var round_sec: float = GameConfig.round_timer_sec
	if match_mode == MatchState.Mode.TEAM_ARENA:
		round_sec = GameConfig.team_arena_round_sec
	elif match_mode == MatchState.Mode.EXTRACTION:
		round_sec = GameConfig.extraction_round_sec

	# Правила режима EXTRACTION целиком (раздача добычи по кубам, склады, окна эвакуации, банк,
	# россыпь трюма при гибели) — отдельный менеджер. Тот же паттерн «узел из кода в корне сцены»,
	# что у ScoreManager, и тот же порядок: после спавна состава, до MatchManager, который читает у
	# него счёт при подведении итога.
	if match_mode == MatchState.Mode.EXTRACTION:
		_extraction_manager = Node.new()
		_extraction_manager.name = "ExtractionManager"
		_extraction_manager.set_script(ExtractionManagerScript)
		add_child(_extraction_manager)
		_extraction_manager.setup()

	# Полноценный постраундовый цикл (см. match_manager.gd): TARGET_OBJECTIVE — уничтожение цели →
	# победа атаки / таймаут → победа защиты; TEAM_ARENA — таймаут → победитель по убийствам; плюс
	# опциональная финальная стадия (final_stage_enabled) — доп. время, если время вышло и боезапас
	# у всех живых танков кончился.
	var match_manager := Node.new()
	match_manager.name = "MatchManager"
	match_manager.set_script(MatchManagerScript)
	add_child(match_manager)
	match_manager.setup(match_mode, round_sec, score_manager, objective_health, final_stage_enabled, _extraction_manager)
	match_manager.round_ended.connect(_on_round_ended_teardown)

## Конец раунда зафиксирован (чья-то победа) — в рамках MVP «замораживаем» поле: глушим спавнеры
## обеих сторон (TeamSpawner + все RespawnController — новых/воскресших танков до рестарта не
## будет) и принудительно убиваем все существующие танки, включая игрока. force_destroy() идёт с
## killer=null → ScoreManager такие смерти НЕ засчитывает (важно для отображаемого счёта убийств и
## для TEAM_ARENA, где раунд решается по нему — впрочем, победитель к этому моменту уже определён в
## MatchManager._end_round). Порядок в цикле: halt() РАНЬШЕ force_destroy() того же танка, иначе
## RespawnController._on_destroyed успеет запустить таймер респавна.
func _on_round_ended_teardown(_winner: String) -> void:
	# ПЕРЕД force_destroy() ниже: иначе «заморозка поля» на экран результата рассыпала бы трюмы
	# всех погибших от неё носителей (см. extraction_manager.gd._on_tank_destroyed).
	if _extraction_manager != null:
		_extraction_manager.halt()
	$TeamSpawner.halt()
	for button in _bot_spawn_buttons:
		if is_instance_valid(button):
			button.disabled = true
	for tank in get_tree().get_nodes_in_group("tanks"):
		var rc: Node = tank.get_node_or_null("RespawnController")
		if rc != null:
			rc.halt()
		var hc: Node = tank.get_node_or_null("HealthComponent")
		if hc != null:
			hc.force_destroy()

## Бессмертие игрока — тумблер «Игрок: бессмертие ON/OFF» (низ-справа), ПО УМОЛЧАНИЮ ВКЛ. Тот же
## паттерн, что Objective On/Off. Низ-справа, на слот выше кнопки Objective On/Off (та на самом низу).
func _setup_invincibility_toggle_button() -> void:
	_player_health.invincible = true
	var layer := CanvasLayer.new()
	layer.name = "PlayerInvincibilityToggleLayer"
	var button := Button.new()
	button.name = "PlayerInvincibilityToggleButton"
	button.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	button.offset_left = -236.0
	button.offset_top = -104.0
	button.offset_right = -16.0
	button.offset_bottom = -64.0
	button.pressed.connect(_on_invincibility_toggle_pressed)
	layer.add_child(button)
	_invincibility_toggle_button = button
	# Без call_deferred — этот скрипт на корне сцены, его _ready() идёт последним, дерево готово
	# (та же логика, что у _setup_objective_toggle_button).
	add_child(layer)
	_update_invincibility_toggle_button()

func _on_invincibility_toggle_pressed() -> void:
	_player_health.invincible = not _player_health.invincible
	_update_invincibility_toggle_button()

func _update_invincibility_toggle_button() -> void:
	_invincibility_toggle_button.text = "Игрок: бессмертие %s" % ("ON" if _player_health.invincible else "OFF")

## Одна кнопка «Реакция ботов на игрока ON/OFF» (низ-СЛЕВА — правый низ занят бессмертием/objective/
## спавном ботов). Заменила прежние per-bot кнопки "reaction ON/OFF" из tank_ai_controller.gd,
## которые гасили реакцию бота на ВСЕХ врагов и висели по одной на бота. OFF → MatchState.
## bots_ignore_player = true: боты перестают воспринимать танк игрока как врага (гейт в
## TankAIController._can_see()/_on_damaged(), см. там); бой бот-против-бота не затронут.
func _setup_ignore_player_toggle_button() -> void:
	var layer := CanvasLayer.new()
	layer.name = "IgnorePlayerToggleLayer"
	var button := Button.new()
	button.name = "IgnorePlayerToggleButton"
	button.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	button.offset_left = 16.0
	button.offset_top = -56.0
	button.offset_right = 256.0
	button.offset_bottom = -16.0
	button.pressed.connect(_on_ignore_player_toggle_pressed)
	layer.add_child(button)
	_ignore_player_toggle_button = button
	# Без call_deferred — скрипт на корне сцены, его _ready() идёт последним (см. остальные
	# _setup_*_button() этого файла), дерево готово.
	add_child(layer)
	_update_ignore_player_toggle_button()

func _on_ignore_player_toggle_pressed() -> void:
	MatchState.bots_ignore_player = not MatchState.bots_ignore_player
	_update_ignore_player_toggle_button()

func _update_ignore_player_toggle_button() -> void:
	_ignore_player_toggle_button.text = "Реакция ботов на игрока: %s" % ("OFF" if MatchState.bots_ignore_player else "ON")

## [ДОБАВЛЕНО, по прямому запросу — "2 кнопки в HUD для дебаг-режима для спавна ботов (на каждую
## сторону) — клик спавнит бота"] Тот же паттерн CanvasLayer+Button, что остальные debug-тумблеры
## этого файла — продолжение той же колонки правого нижнего угла, двумя слотами выше бессмертия
## игрока. Не завязано на наличие Objective (в отличие от _setup_objective_toggle_button) — вызывается
## безусловно в debug-режиме, TeamSpawner есть на любой карте. Каждый клик — TeamSpawner.
## spawn_one_bot(team) (см. её doc-comment): добавляет бота ПОВЕРХ уже существующих, одинаково
## работает и когда ростер спавнился при старте целиком, и когда MatchState.
## debug_spawn_bots_on_start=false отключил автоспавн — тогда это единственный способ вообще
## получить бота на карте.
func _setup_bot_spawn_buttons() -> void:
	var spawner: Node = $TeamSpawner
	var layer := CanvasLayer.new()
	layer.name = "BotSpawnButtonsLayer"

	var attack_button := Button.new()
	attack_button.name = "SpawnAttackBotButton"
	attack_button.text = "+ Бот (атака)"
	attack_button.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	attack_button.offset_left = -236.0
	attack_button.offset_top = -152.0
	attack_button.offset_right = -16.0
	attack_button.offset_bottom = -112.0
	attack_button.pressed.connect(spawner.spawn_one_bot.bind(0))
	layer.add_child(attack_button)
	_bot_spawn_buttons.append(attack_button)

	var defense_button := Button.new()
	defense_button.name = "SpawnDefenseBotButton"
	defense_button.text = "+ Бот (оборона)"
	defense_button.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	defense_button.offset_left = -236.0
	defense_button.offset_top = -200.0
	defense_button.offset_right = -16.0
	defense_button.offset_bottom = -160.0
	defense_button.pressed.connect(spawner.spawn_one_bot.bind(1))
	layer.add_child(defense_button)
	_bot_spawn_buttons.append(defense_button)

	# Без call_deferred — этот скрипт на корне сцены, его _ready() идёт последним (см. остальные
	# _setup_*_button() в этом файле), дерево готово.
	add_child(layer)

func _physics_process(delta: float) -> void:
	_alert_state.tick(delta)

## Публичный геттер (не .get() на приватной var с другого скрипта) — вызывается КАЖДЫМ
## TankAIController из _ensure_home_state() вместо хранения собственной копии таймера. Тонкая
## обёртка над ObjectiveAlertState (см. её doc-comment).
func time_since_objective_hit() -> float:
	return _alert_state.time_since_hit()

## Тонкая обёртка над ObjectiveAlertState.enemy_in_zone() — is_instance_valid, не == null:
## ObjectiveAlertZone — дочерний узел Objective и освобождается ВМЕСТЕ с ним при уничтожении
## (free_on_destroy=true) — после этого _alert_zone висячая ссылка, != null, но обращаться к ней
## уже нельзя (сама проверка внутри ObjectiveAlertState тоже это учитывает — дублируем guard здесь
## только чтобы не звать метод класса на заведомо мусорной ссылке).
func enemy_in_alert_zone() -> bool:
	if not is_instance_valid(_alert_zone):
		return false
	return _alert_state.enemy_in_zone(_alert_zone, get_tree())

## Здоровье цели в HUD рисует сам hud.gd (строка под счётом раундов, только TARGET_OBJECTIVE) —
## здесь остаётся только тумблер бессмертия цели + подписка на damaged для сброса ALERT-таймера.
## find_child, не get_node("Map/..."): ни у одной карты нет промежуточного узла "Map".
func _setup_objective_ui() -> void:
	var objective: Node = get_tree().current_scene.find_child("Objective", true, false)
	if objective == null:
		return
	_objective_health = objective.get_node_or_null("HealthComponent")
	if _objective_health == null:
		return
	_objective_health.damaged.connect(_on_objective_damaged)
	# Группа "objective_health" — TankAIController ищет objective по ней, не по имени узла
	# (устраняет зависимость от конкретного имени объекта-цели для любой будущей карты).
	_objective_health.add_to_group("objective_health")
	if MatchState.debug_enabled:
		_setup_objective_toggle_button()

func _on_objective_damaged(_current_hits: int, _max_hits: int, _killer: Node = null) -> void:
	_alert_state.reset()  # сбрасывается на КАЖДЫЙ удар, см. ObjectiveAlertState.reset()

## Отдельный CanvasLayer, не трогаем разметку HUD.tscn. Правый низ — левый низ занят кнопкой
## «Реакция ботов на игрока», правый верх — brain-debug панелями ботов.
func _setup_objective_toggle_button() -> void:
	var layer := CanvasLayer.new()
	layer.name = "ObjectiveToggleLayer"
	var button := Button.new()
	button.name = "ObjectiveToggleButton"
	button.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	button.offset_left = -236.0
	button.offset_top = -56.0
	button.offset_right = -16.0
	button.offset_bottom = -16.0
	button.pressed.connect(_on_objective_toggle_pressed)
	layer.add_child(button)
	_objective_toggle_button = button
	# Без call_deferred — этот скрипт сидит на КОРНЕ сцены, его _ready() уже выполняется последним
	# (после всех детей, см. CLAUDE.md/"Scene bring-up ordering"), дерево к этому моменту полностью
	# построено.
	add_child(layer)
	_update_objective_toggle_button()

func _on_objective_toggle_pressed() -> void:
	_objective_health.invincible = not _objective_health.invincible
	_update_objective_toggle_button()

func _update_objective_toggle_button() -> void:
	_objective_toggle_button.text = "Objective: %s" % ("OFF" if _objective_health.invincible else "ON")

## Камеры-клавиши: "1" (вернуть камеру своего танка) работает всегда; статичные ракурсы "2"/"3"
## (ObjectiveCamera/OverviewCamera) — ТОЛЬКО в debug-режиме. Обзор с 2/3 не игровой: расчёт
## «видит ли бота игрок» для маскировки ботов их не учитывает (см. tank_ai_controller._player_sees_me).
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_1:
			_player_camera_rig.activate()
		KEY_2:
			if MatchState.debug_enabled:
				_player_camera_rig.deactivate()
				_objective_camera.current = true
		KEY_3:
			if MatchState.debug_enabled:
				_player_camera_rig.deactivate()
				_overview_camera.current = true
