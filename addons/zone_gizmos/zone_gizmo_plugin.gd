@tool
extends EditorNode3DGizmoPlugin
## Editor-only визуализация зон: кольцо на земле под каждым спавнером, вейпоинтом, objective и
## каждой зоной сброса ящиков. Гизмо рисуются во вьюпорте редактора ВСЕГДА (не только у
## выделенного узла) и НЕ попадают ни в рантайм, ни в .tscn. Рантайм держит свои круги
## (spawn_zone.gd / map_scene.gd, gated MatchState.debug_enabled) — это их зеркало на этапе
## редактирования карты.
##
## Детект по тем же конвенциям, что уже использует игровой код:
##   - script == spawn_zone.gd  → AttackSpawnZone / DefenseSpawnZone / ObjectiveAlertZone /
##                                DropArea внутри префаба AmmoDropZone. Радиус — из @export radius.
##   - имя содержит "Waypoint"  → маркер патруля/атаки (обычный Node3D без скрипта). Радиус 7.5,
##                                как map_scene.gd::_WAYPOINT_DEBUG_RADIUS / TankAIController.waypoint_radius.
##   - имя == "Objective"       → разрушаемая цель. Маленькое кольцо + вертикальная «мачта».
## Цвет как в рантайм-дебаге: Attack* — красный, Defense* — синий, «голый» Waypoint* — тоже
## синий (как в _build_waypoint_debug), спавн-зона без префикса (ObjectiveAlertZone/DropArea) —
## жёлтый, Objective — пурпурный.
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


func _init() -> void:
	# on_top=true — кольца видно и сквозь препятствия/землю (это про дизайн-раскладку, не про
	# честную оклюзию).
	create_material("attack", _C_ATTACK, false, true)
	create_material("defense", _C_DEFENSE, false, true)
	create_material("neutral", _C_NEUTRAL, false, true)
	create_material("objective", _C_OBJECTIVE, false, true)


func _get_gizmo_name() -> String:
	return "Zone Gizmos"


func _has_gizmo(node: Node3D) -> bool:
	return _material_key(node) != ""


## "" — узел не наш. Иначе — ключ материала ("attack"/"defense"/"neutral"/"objective").
func _material_key(node: Node3D) -> String:
	var n := String(node.name)
	if node.name == &"Objective":
		return "objective"
	if n.contains("Waypoint"):
		return "attack" if n.begins_with("Attack") else "defense"
	if _has_spawn_zone_script(node):
		if n.begins_with("Attack"):
			return "attack"
		if n.begins_with("Defense"):
			return "defense"
		return "neutral"
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
	if String(node.name).contains("Waypoint"):
		return _WAYPOINT_RADIUS
	var v: Variant = node.get("radius")  # @export radius на spawn_zone.gd
	return float(v) if v != null else _DEFAULT_ZONE_RADIUS
