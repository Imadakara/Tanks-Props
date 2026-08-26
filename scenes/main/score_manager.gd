extends Node
## ScoreManager — счёт команд по уничтожениям (ТЗ §8.4, §10). Подключается к
## HealthComponent.destroyed(killer) каждого танка из группы "tanks" (Tank._ready()
## регистрирует себя в группе).

signal score_changed(attack_kills: int, defense_kills: int)

var attack_kills: int = 0
var defense_kills: int = 0

## Вызывается из Main._ready() (см. main.gd), ПОСЛЕ TeamSpawner.spawn_team().
func begin_match() -> void:
	for tank in get_tree().get_nodes_in_group("tanks"):
		var health: Node = tank.get_node_or_null("HealthComponent")
		if health != null:
			health.destroyed.connect(_on_tank_destroyed)

func _on_tank_destroyed(killer: Node) -> void:
	if killer == null or not killer.has_method("is_attacker"):
		return
	if killer.is_attacker():
		attack_kills += 1
	else:
		defense_kills += 1
	score_changed.emit(attack_kills, defense_kills)
