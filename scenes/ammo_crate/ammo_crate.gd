extends Area3D
## AmmoCrate — подбираемый ящик патронов (ТЗ §8.4). Доступен любому танку любой команды;
## при подборе выдаёт GameConfig.ammo_per_crate патронов и исчезает. Спавнится периодически
## в случайной точке поля через MatchManager.CrateSpawnTimer (пост-ревью, см. match_manager.gd)
## — группа "ammo_crates" нужна ему, чтобы посчитать, сколько ящиков сейчас не подобрано.

func _ready() -> void:
	add_to_group("ammo_crates")
	body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node) -> void:
	var ammo: Node = body.get_node_or_null("AmmoComponent")
	if ammo == null:
		return
	ammo.add_ammo(GameConfig.ammo_per_crate)
	queue_free()
