@tool
extends EditorPlugin
## Регистрирует ZoneGizmoPlugin — editor-only визуал зон (кольца на земле под спавнерами,
## вейпоинтами, objective, зонами сброса ящиков). См. zone_gizmo_plugin.gd.
## Чисто редакторная штука: в рантайме не грузится, в .tscn ничего не пишет. Рантайм-дебаг
## (MatchState.debug_enabled → круги из spawn_zone.gd / map_scene.gd) живёт отдельно.

const ZoneGizmoPlugin := preload("res://addons/zone_gizmos/zone_gizmo_plugin.gd")

var _gizmo: EditorNode3DGizmoPlugin


func _enter_tree() -> void:
	_gizmo = ZoneGizmoPlugin.new()
	add_node_3d_gizmo_plugin(_gizmo)


func _exit_tree() -> void:
	remove_node_3d_gizmo_plugin(_gizmo)
	_gizmo = null
