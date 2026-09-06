@tool
extends Node3D
## SpawnZone — круглая зона спавна команды, единый механизм на ЛЮБОЙ карте
## (`TargetObjectiveMap.tscn`/`TeamArenaMap.tscn`).
##
## [ДОБАВЛЕНО, по прямому запросу — "радиус должен автоматом пересчитываться при изменении
## трансформа в редакторе, прежде всего скейла, а не расходиться с тем что видно"] `@tool` —
## РОВНО ради этого: при перетаскивании Scale-гизмо/правке Transform в инспекторе Godot-редактора
## узел сам конвертирует текущий множитель масштаба в @export radius и тут же сбрасывает
## scale обратно к (1,1,1) — см. _sync_radius_from_scale(). Единственный источник истины по
## размеру зоны — ПОЛЕ radius, никогда transform/scale узла: и рантайм-круг
## (_draw_debug_circle(), ниже), и его зеркало в редакторе (`addons/zone_gizmos/
## zone_gizmo_plugin.gd`), и реальная игровая логика (pick_spawn_position(), ALERT-детект
## в tank_ai_controller.gd) — все читают именно radius. Раньше скейл узла визуально тянул
## оба круга (они — дети узла/гизмо узла, наследуют его transform), но НЕ менял radius —
## тянуть скейл в редакторе показывало неправду: видимый круг рос, а реальный игровой радиус
## оставался прежним. Теперь после любой правки transform'а зона сама возвращается к scale=1,
## растущий/уменьшающийся круг — это всегда живое значение radius, не обман.
##
## Команда кодируется ПРЕФИКСОМ ИМЕНИ узла, не отдельным @export полем — тот же паттерн, что уже
## используется в проекте для Waypoint/AttackWaypoint (tank_ai_controller.gd): "AttackSpawnZone" /
## "DefenseSpawnZone". Ищется РЕКУРСИВНО по всей текущей сцене (find_child), не только среди
## прямых детей — ни одна карта не заворачивает геометрию в промежуточный узел сейчас, но
## рекурсивный поиск не завязывается на это для любой будущей карты.
##
## [ПЕРЕИСПОЛЬЗУЕТСЯ, по прямому запросу] Тот же скрипт стоит и на узле "ObjectiveAlertZone" —
## круглая зона тревоги вокруг уничтожаемого objective (tank_ai_controller.gd, State.ALERT, см.
## её doc-comment). Имя не начинается ни с "Attack", ни с "Defense" — _draw_debug_circle() рисует
## её жёлтой (ветка else), что и требовалось. pick_spawn_position() у этого узла не используется —
## ALERT-логика берёт точки сама (_pick_new_alert_target(), круговая выборка), но радиус/окружность
## общие, дублировать эту механику под другим именем скрипта не было смысла.
##
## [ПЕРЕИСПОЛЬЗУЕТСЯ] Ещё один потребитель — КОРЕНЬ префаба AmmoDropZone.tscn (зона сброса ящиков
## боеприпасов, см. scenes/ammo_crate/ammo_drop_zone.gd): этот скрипт висит прямо на корне
## инстанса (радиус правится на нём, как у MortarHideZone, без дочернего DropArea) — круг тем же
## _draw_debug_circle() (жёлтый — имя не Attack/Defense) + pick_spawn_position() как источник
## случайной точки на реальной земле для падающего ящика. Логика каденса сброса — на дочернем
## DropOrigin (Marker3D + ammo_drop_zone.gd, локальный y≈14).
## ObjectiveAlertZone — ДОЧЕРНИЙ узел самого объекта-цели (`NavigationRegion3D/Objective`), с
## локальным y=-1, чтобы круг лёг на землю. Освобождается ВМЕСТЕ с целью (free_on_destroy=true) —
## на картах без objective (`TeamArenaMap.tscn`, режим TEAM_ARENA) его нет вовсе. Все читатели
## ссылки используют is_instance_valid() — после разрушения цели ссылка висячая, != null.

## Setter вместо голого @export — при правке значения ПРЯМО В ИНСПЕКТОРЕ (не через скейл-гизмо)
## сразу дёргает update_gizmos(), чтобы кольцо `zone_gizmo_plugin.gd` перерисовалось немедленно
## (раньше это было отдельным задокументированным ограничением — "смена radius в инспекторе не
## перерисовывает кольцо сразу, перевыделить узел/перезагрузить сцену" — устранено тем же ходом,
## что и синхронизация со скейлом ниже, один и тот же механизм update_gizmos()).
@export var radius: float = 6.0:
	set(value):
		radius = value
		if Engine.is_editor_hint():
			update_gizmos()

## Реентрантность: само присваивание `scale = Vector3.ONE` в _sync_radius_from_scale() тоже
## порождает NOTIFICATION_TRANSFORM_CHANGED — без этого флага получился бы бесконечный, хоть и
## быстро гасящийся (после первого сброса scale уже (1,1,1), выход по is_equal_approx), цикл.
var _syncing_scale: bool = false

## Сколько раз пробовать случайную точку, прежде чем сдаться. Страховка от вырожденного случая
## "вся зона легла на яму/HazardZone/пустоту за краем карты" — не должно случаться при разумной
## расстановке зоны на реальной карте, но не полагаемся на это молча.
@export var max_attempts: int = 20
## Высота, с которой кастуется луч вниз при проверке поверхности, и как далеко вниз он идёт.
@export var ground_check_height: float = 10.0
@export var ground_check_depth: float = 20.0
## Дебаг-визуал — окружность на земле, обозначающая зону (по прямому запросу — "зона,
## обозначенная окружностью"). Not just a debug nicety here: без визуала невозможно проверить живым
## скриншотом, что зона реально легла в нужный угол карты, не пересекает препятствия и т.п.
@export var show_debug_circle: bool = true

## [ДОБАВЛЕНО, по прямому запросу — "единый общий механизм подсасывания вейпоинтов каждого типа
## в логику ботов, а не поиск по имени, прошитый в код под каждый новый случай"] Если задано — узел
## САМ регистрируется в эту Godot-группу здесь, в _ready() (тот же паттерн, что уже использует
## ammo_drop_zone.gd для "ammo_drop_zones" — не новый механизм, переиспользование существующего).
## Любой потребитель ищет "все зоны этой роли" одним get_nodes_in_group(role), не зная НИЧЕГО об
## имени/префиксе конкретных узлов — имя остаётся чисто человекочитаемым + для сортировки внутри
## роли (см. tank_ai_controller.gd._collect_waypoints()), не идентификатором роли. Пусто (дефолт) —
## узел ни в какую отдельную роль не входит (обычные spawn/ammo/alert-зоны ищутся по точному имени,
## им отдельная роль не нужна — искать их нужно РОВНО ОДНУ, не "все зоны этого типа").
@export var zone_role: String = ""

## Включает NOTIFICATION_TRANSFORM_CHANGED (по умолчанию Node3D его НЕ шлёт — расход не бесплатный,
## Godot требует явного opt-in) — но только в редакторе; в игре зона не двигается, слать эти
## уведомления некому и незачем.
func _enter_tree() -> void:
	if Engine.is_editor_hint():
		set_notify_transform(true)

func _ready() -> void:
	# В редакторе (не в игре) зона существует только чтобы её тут двигали/масштабировали и рисовали
	# гизмо (zone_gizmo_plugin.gd, отдельный @tool-плагин) — ни группа, ни рантайм-круг, ни тем более
	# MatchState (autoload, которого в редакторе просто нет в дереве) ей не нужны и не безопасны.
	if Engine.is_editor_hint():
		return
	if not zone_role.is_empty():
		add_to_group(zone_role)
	# ВСЕ круглые зоны-маркеры (spawn / waypoint / alert / ammo / hide), независимо от zone_role —
	# keep-out для динамической расстановки препятствий (dynamic_obstacle_placer.gd).
	add_to_group("zone_circles")
	# Круг на земле — отладочный визуал (зоны спавна + круги зон сброса ящиков): только в
	# debug-режиме (MatchState.debug_enabled, галочка в меню). show_debug_circle остаётся
	# вложенным per-instance фильтром.
	if show_debug_circle and MatchState.debug_enabled:
		_draw_debug_circle()

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and Engine.is_editor_hint():
		_sync_radius_from_scale()

## Конвертирует текущий scale узла в radius, затем сбрасывает scale к (1,1,1) — см. doc-comment
## файла. Фактор — среднее |scale.x|/|scale.z| (круг лежит в плоскости XZ; непропорциональный
## X≠Z скейл эллипс скалярным radius не выразит, среднее — разумный компромисс, не крах). scale.y
## на форму круга не влияет вовсе, но тоже сбрасывается — единообразия ради (узел зоны никогда не
## должен нести нетривиальный scale, что бы ни трогали).
func _sync_radius_from_scale() -> void:
	if _syncing_scale:
		return
	var s: Vector3 = scale
	if is_equal_approx(s.x, 1.0) and is_equal_approx(s.y, 1.0) and is_equal_approx(s.z, 1.0):
		return  # уже нормализован — обычная правка позиции/поворота, не про нас
	var factor: float = (absf(s.x) + absf(s.z)) * 0.5
	if factor < 0.0001:
		return  # вырожденный/нулевой скейл — не позволяем радиусу схлопнуться в мусор
	_syncing_scale = true
	radius = maxf(radius * factor, 0.01)
	scale = Vector3.ONE
	_syncing_scale = false

## Случайная точка в круге (равномерно по площади — sqrt(randf()), не randf() напрямую, тот же
## приём, что уже используется в tank_ai_controller.gd/_pick_random_point_near()) С ПРОВЕРКОЙ
## ПОВЕРХНОСТИ ПОД НЕЙ (по прямому запросу) — кастует луч вниз (collision_mask=1, "environment",
## та же маска, что и у остальных геометрических проверок в проекте), берёт РЕАЛЬНУЮ высоту
## поверхности из результата хита, не просто center.y. Ничего не нашли за max_attempts попыток —
## сдаётся, возвращает ЦЕНТР зоны (детерминированный fallback — не рискуем спавном в
## неопределённом месте лучше, чем рискуем спавном в проверенно плохом).
## Возвращает точку РОВНО НА поверхности, без зазора — зазор от вырожденного контакта (см.
## team_spawner.gd _spawn_clearance) добавляет вызывающий код, это не забота самой зоны.
func pick_spawn_position() -> Vector3:
	var space_state: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	for i in range(max_attempts):
		var angle: float = randf() * TAU
		var dist: float = sqrt(randf()) * radius
		var candidate_xz := Vector2(global_position.x + cos(angle) * dist, global_position.z + sin(angle) * dist)
		var origin := Vector3(candidate_xz.x, global_position.y + ground_check_height, candidate_xz.y)
		var query := PhysicsRayQueryParameters3D.create(origin, origin + Vector3.DOWN * ground_check_depth)
		query.collision_mask = 1
		var result: Dictionary = space_state.intersect_ray(query)
		if not result.is_empty():
			return result["position"]
	return global_position

## Обе карты (72×72) имеют Ground, центрированный в мировом (0,0) — центр карты ВСЕГДА мировой
## XZ-origin, отдельно вычислять его для конкретной карты не нужно. Разворот только по Y
## (курс/yaw) — pitch/roll должны остаться нулевыми на плоской
## земле, поэтому цель look_at() берётся на ТОЙ ЖЕ высоте, что и сам танк (иначе look_at честно
## наклонил бы корпус по вертикали на разницу высот). forward танка — это -basis.z (см.
## tank_movement.gd _physics_process(), forward = -_body.global_transform.basis.z) — ТО ЖЕ самое
## направление, что и у look_at() (Node3D.look_at() всегда ориентирует -Z на target), поэтому здесь
## не пришлось выводить свою формулу угла руками — та же категория бага, что уже была один раз
## живьём найдена в driving-стеке tank_ai_controller.gd (инвертированный знак поворота, см. её
## _drive_to_point()/дев-план в заголовке того файла) — здесь тот же класс бага заведомо не грозит,
## look_at()/-basis.z уже согласованы напрямую, без ручного вывода знака.
## Статик, не завязан на конкретный инстанс зоны — вызывается как SpawnZoneScript.face_center(tank)
## (через preload этого файла, см. вызывающие скрипты — НЕ class_name: headless run_project не
## подхватывает свежедобавленный class_name без пересканирования редактором, см. CLAUDE.md/vault,
## тот же класс граблей, что и с новыми файлами вообще) из обоих мест спавна
## (team_spawner.gd/respawn_controller.gd), а не дублируется дважды.
static func face_center(tank: Node3D) -> void:
	var pos: Vector3 = tank.global_position
	if Vector2(pos.x, pos.z).length() < 0.01:
		return  # вырожденный случай — танк буквально в центре карты, направление не определено
	tank.look_at(Vector3(0.0, pos.y, 0.0), Vector3.UP)

## Окружность на земле — MeshInstance3D с ImmediateMesh, построена ОДИН раз в _ready() (зона
## статична, не нужно перестраивать каждый кадр, в отличие от дебаг-визуалов tank_ai_controller.gd,
## которые следят за живым состоянием бота). Цвет по префиксу имени — красноватый "Attack",
## синеватый "Defense", нейтральный жёлтый — иначе (на случай другой команды/нейминга в будущем).
func _draw_debug_circle() -> void:
	const SEGMENTS := 48
	const HEIGHT := 0.15
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "DebugCircle"
	var mesh := ImmediateMesh.new()
	mesh_inst.mesh = mesh
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var color: Color
	if String(name).begins_with("Attack"):
		color = Color(0.9, 0.2, 0.15, 0.85)
	elif String(name).begins_with("Defense"):
		color = Color(0.2, 0.45, 0.9, 0.85)
	# [ДОБАВЛЕНО, по прямому запросу — "зона ожидания маскировки должна быть видна в дебаг-режиме"]
	# Свой цвет, не жёлтый общий "else" — иначе неотличима от соседних жёлтых кругов ammo-зон/
	# ObjectiveAlertZone на одном экране (MortarHideZoneN стоят рядом с AmmoDropZone, см.
	# TargetObjectiveMap.tscn).
	elif String(name).begins_with("MortarHide"):
		color = Color(0.6, 0.25, 0.85, 0.85)
	# [ДОБАВЛЕНО, по прямому запросу — регрессия "нет синих вейпоинтов защитников" после перевода
	# вейпоинтов на этот скрипт] Голый "WaypointN" (диамант защитника вокруг objective — по имени
	# без командного префикса, см. tank_ai_controller.gd) — исторически ВСЕГДА цвет обороны: старая
	# рисовалка map_scene.gd._build_waypoint_debug() (до перевода вейпоинтов на spawn_zone.gd)
	# трактовала любое имя БЕЗ "Attack" как синий. Отдельная явная ветка, не общий "else" — иначе
	# неотличим от истинно нейтральных зон без командного смысла (AmmoDropZone/ObjectiveAlertZone),
	# те остаются жёлтыми.
	elif String(name).begins_with("Waypoint"):
		color = Color(0.2, 0.45, 0.9, 0.85)
	else:
		color = Color(0.9, 0.85, 0.15, 0.85)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mesh_inst.material_override = mat

	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	mesh.surface_set_color(color)
	for i in range(SEGMENTS + 1):
		var t: float = TAU * float(i) / float(SEGMENTS)
		mesh.surface_add_vertex(Vector3(cos(t) * radius, HEIGHT, sin(t) * radius))
	mesh.surface_end()

	# Крестик в центре — видно, где именно точка pick_spawn_position() промахнулась бы мимо (не
	# только контур круга, но и его середину, полезно на маленьком radius).
	const MARK := 0.6
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	mesh.surface_set_color(color)
	mesh.surface_add_vertex(Vector3(-MARK, HEIGHT, 0.0))
	mesh.surface_add_vertex(Vector3(MARK, HEIGHT, 0.0))
	mesh.surface_add_vertex(Vector3(0.0, HEIGHT, -MARK))
	mesh.surface_add_vertex(Vector3(0.0, HEIGHT, MARK))
	mesh.surface_end()

	add_child(mesh_inst)
