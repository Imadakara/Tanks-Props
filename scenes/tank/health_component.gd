extends Node
## HealthComponent — one-hit kill: любое попадание снаряда уничтожает танк (ТЗ §7).
## Для MVP хитбокс общий (CollisionShape3D танка), место попадания не учитывается.

signal destroyed(killer: Node)

var is_alive: bool = true

func take_hit(killer: Node = null) -> void:
	if not is_alive:
		return
	is_alive = false
	destroyed.emit(killer)
	get_parent().queue_free()
