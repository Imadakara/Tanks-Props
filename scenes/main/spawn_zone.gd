extends Node3D
## SpawnZone — круглая зона спавна команды, единый механизм на ЛЮБОЙ карте
## (`TargetObjectiveMap.tscn`/`TeamArenaMap.tscn`).
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
## [ПЕРЕИСПОЛЬЗУЕТСЯ] Ещё один потребитель — узел "DropArea" в префабе AmmoDropZone.tscn (зона
## сброса ящиков боеприпасов, см. scenes/ammo_crate/ammo_drop_zone.gd): круг тем же
## _draw_debug_circle() (жёлтый — имя не Attack/Defense) + pick_spawn_position() как источник
## случайной точки на реальной земле для падающего ящика.
## ObjectiveAlertZone — ДОЧЕРНИЙ узел самого объекта-цели (`NavigationRegion3D/Objective`), с
## локальным y=-1, чтобы круг лёг на землю. Освобождается ВМЕСТЕ с целью (free_on_destroy=true) —
## на картах без objective (`TeamArenaMap.tscn`, режим TEAM_ARENA) его нет вовсе. Все читатели
## ссылки используют is_instance_valid() — после разрушения цели ссылка висячая, != null.

@export var radius: float = 6.0
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

func _ready() -> void:
	# Круг на земле — отладочный визуал (зоны спавна + круги зон сброса ящиков): только в
	# debug-режиме (MatchState.debug_enabled, галочка в меню). show_debug_circle остаётся
	# вложенным per-instance фильтром.
	if show_debug_circle and MatchState.debug_enabled:
		_draw_debug_circle()

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
