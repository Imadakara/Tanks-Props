extends Control
## MortarReticle — прицел режима прицеливания мортиры: кружок (не перекрестие), обозначающий
## точку падения навесного снаряда на полу. Позицию на экране выставляет hud.gd каждый кадр
## проекцией ModificationController.get_reticle_world_point() через активную камеру. Виден только
## пока игрок в режиме прицеливания (hud.gd/_update_crosshair), иначе показан штатный Crosshair.

func _draw() -> void:
	var c := size * 0.5
	var col := Color(1.0, 0.3, 0.2, 0.95)
	draw_arc(c, 12.0, 0.0, TAU, 32, col, 2.0)
	draw_circle(c, 2.0, col)
