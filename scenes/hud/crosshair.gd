extends Control
## Crosshair — прицел: перекрестие, показывающее реальное текущее направление дула
## (не просто центр экрана — учитывает довод башни/питч дула). Позицию на экране
## выставляет hud.gd каждый кадр проекцией точки перед дулом через camera.unproject_position().

func _draw() -> void:
	var c := size * 0.5
	var col := Color(1, 1, 1, 0.9)
	draw_line(c - Vector2(9, 0), c - Vector2(3, 0), col, 2.0)
	draw_line(c + Vector2(3, 0), c + Vector2(9, 0), col, 2.0)
	draw_line(c - Vector2(0, 9), c - Vector2(0, 3), col, 2.0)
	draw_line(c + Vector2(0, 3), c + Vector2(0, 9), col, 2.0)
	draw_circle(c, 1.5, col)
