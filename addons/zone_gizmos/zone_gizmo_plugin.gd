@tool
extends EditorNode3DGizmoPlugin
## Editor-only визуализация зон: кольцо на земле под каждым спавнером, вейпоинтом, objective и
## каждой зоной сброса ящиков. Гизмо рисуются во вьюпорте редактора ВСЕГДА (не только у
## выделенного узла) и НЕ попадают ни в рантайм, ни в .tscn. Рантайм держит свои круги
## (spawn_zone.gd, gated MatchState.debug_enabled) — это их зеркало на этапе редактирования карты.
##
## [ИЗМЕНЕНО, по прямому запросу — "общая универсальная система зон вместо разрозненных точек"]
## Вейпоинты (`Waypoint*`/`AttackWaypoint*`/`DefenseWaypoint*`) больше НЕ голые Node3D с
## захардкоженным радиусом — это узлы на spawn_zone.gd, как и все остальные зоны (одна и та же
## строка правды и для рантайма, и для этого гизмо). Приоритет детекта: script == spawn_zone.gd
## РЕШАЕТ И цвет, И радиус (читает СОБСТВЕННЫЙ @export radius узла — движимый/масштабируемый в
## инспекторе, реально используется в _pick_new_waypoint_target()/pick_spawn_position(), не только
## для вида). Имя "*Waypoint*" остаётся ФОЛБЭКОМ на случай будущего немигрированного маркера без
## этого скрипта (тогда — старый хардкод _WAYPOINT_RADIUS, как раньше).
##
## Детект:
##   - имя == "Objective"        → разрушаемая цель. Маленькое кольцо + вертикальная «мачта».
##   - script == spawn_zone.gd   → AttackSpawnZone/DefenseSpawnZone/ObjectiveAlertZone/DropArea/
##                                 Waypoint*/AttackWaypoint*/DefenseWaypoint*/MortarHideZone*.
##                                 Радиус — из @export radius САМОГО узла.
##   - имя содержит "Waypoint"   → ФОЛБЭК для маркера без скрипта. Радиус 7.5 (см.
##                                 TankAIController.waypoint_radius — тот же дефолт-фолбэк).
## Цвет — тот же, что в рантайм-дебаге (spawn_zone.gd._draw_debug_circle()): Attack* — красный,
## Defense* — синий, MortarHide* — фиолетовый (зона ожидания маскировки), иначе — жёлтый
## (ObjectiveAlertZone/DropArea/голый Waypoint* без командного префикса), Objective — пурпурный.
##
## Ограничение: spawn_zone.gd не @tool, поэтому смена radius в инспекторе не перерисовывает
## кольцо сразу — перевыделить узел или перезагрузить сцену.

## Сравниваем скрипт узла по пути ресурса, а НЕ preload'ом самого spawn_zone.gd в этот плагин —
## тот тянет autoload MatchState, и незачем связывать editor-плагин с геймплейным кодом.
const _SPAWN_ZONE_SCRIPT_PATH := "res://scenes/main/spawn_zone.gd"

const _WAYPOINT_RADIUS := 7.5
const _OBJECTIVE_RADIUS := 3.0
const _DEFAULT_ZONE_RADIUS := 6.0
const _SEGMENTS := 48
const _RING_Y := 0.12

const _C_ATTACK := Color(0.9, 0.2, 0.15)
const _C_DEFENSE := Color(0.2, 0.45, 0.9)
const _C_NEUTRAL := Color(0.9, 0.85, 0.15)
const _C_OBJECTIVE := Color(0.95, 0.2, 0.95)
## Тот же фиолетовый, что spawn_zone.gd._draw_debug_circle() даёт зонам "MortarHide*" — зона
## ожидания маскировки (см. tank_ai_controller.gd, сценарий 1).
const _C_HIDE := Color(0.6, 0.25, 0.85)


func _init() -> void:
	# on_top=true — кольца видно и сквозь препятствия/землю (это про дизайн-раскладку, не про
	# честную оклюзию).
	create_material("attack", _C_ATTACK, false, true)
	create_material("defense", _C_DEFENSE, false, true)
	create_material("neutral", _C_NEUTRAL, false, true)
	create_material("objective", _C_OBJECTIVE, false, true)
	create_material("hide", _C_HIDE, false, true)


func _get_gizmo_name() -> String:
	return "Zone Gizmos"


func _has_gizmo(node: Node3D) -> bool:
	return _material_key(node) != ""


## "" — узел не наш. Иначе — ключ материала ("attack"/"defense"/"hide"/"neutral"/"objective").
## script == spawn_zone.gd решает ПЕРВЫМ (все реальные зоны, включая мигрированные вейпоинты) —
## имя "Waypoint" остаётся только фолбэком для маркера без скрипта (см. doc-comment файла).
func _material_key(node: Node3D) -> String:
	var n := String(node.name)
	if node.name == &"Objective":
		return "objective"
	if _has_spawn_zone_script(node):
		if n.begins_with("Attack"):
			return "attack"
		if n.begins_with("Defense"):
			return "defense"
		if n.begins_with("MortarHide"):
			return "hide"
		return "neutral"
	if n.contains("Waypoint"):
		return "attack" if n.begins_with("Attack") else "defense"
	return ""


func _has_spawn_zone_script(node: Node3D) -> bool:
	var s: Script = node.get_script()
	return s != null and s.resource_path == _SPAWN_ZONE_SCRIPT_PATH


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node := gizmo.get_node_3d()
	var key := _material_key(node)
	if key == "":
		return

	var radius := _radius_for(node, key)
	var lines := PackedVector3Array()
	for i in _SEGMENTS:
		var a0 := TAU * float(i) / float(_SEGMENTS)
		var a1 := TAU * float(i + 1) / float(_SEGMENTS)
		lines.push_back(Vector3(cos(a0) * radius, _RING_Y, sin(a0) * radius))
		lines.push_back(Vector3(cos(a1) * radius, _RING_Y, sin(a1) * radius))

	# крестик в центре — маленькое кольцо всё равно находимо
	var m := maxf(0.6, radius * 0.08)
	lines.push_back(Vector3(-m, _RING_Y, 0.0))
	lines.push_back(Vector3(m, _RING_Y, 0.0))
	lines.push_back(Vector3(0.0, _RING_Y, -m))
	lines.push_back(Vector3(0.0, _RING_Y, m))

	# у objective — вертикальная «мачта», чтобы читалось в общем плане карты
	if key == "objective":
		lines.push_back(Vector3.ZERO)
		lines.push_back(Vector3(0.0, 3.0, 0.0))

	gizmo.add_lines(lines, get_material(key, gizmo))


func _radius_for(node: Node3D, key: String) -> float:
	if key == "objective":
		return _OBJECTIVE_RADIUS
	if _has_spawn_zone_script(node):
		var v: Variant = node.get("radius")  # @export radius на spawn_zone.gd — движимый/масштабируемый
		return float(v) if v != null else _DEFAULT_ZONE_RADIUS
	if String(node.name).contains("Waypoint"):
		return _WAYPOINT_RADIUS  # фолбэк для маркера без скрипта, см. doc-comment файла
	return _DEFAULT_ZONE_RADIUS
