extends Control
## MortarReticle — экранный кружок для точки падения навесного снаряда. НЕ ИСПОЛЬЗУЕТСЯ: прицел
## режима прицеливания мортиры — кольцо на земле (mortar_behavior._reticle_ring), а hud.gd в этом
## режиме прячет все экранные прицелы. Узел оставлен в HUD.tscn мёртвым (см.
## Tank_Prop_Hunt_Modifications.md).

func _draw() -> void:
	var c := size * 0.5
	var col := Color(1.0, 0.3, 0.2, 0.95)
	draw_arc(c, 12.0, 0.0, TAU, 32, col, 2.0)
	draw_circle(c, 2.0, col)
