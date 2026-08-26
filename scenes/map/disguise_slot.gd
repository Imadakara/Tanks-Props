extends Area3D
## DisguiseSlot — маркер маскировки: валидная точка активации с закреплённой моделью-
## заменителем (ТЗ §6). Сам по себе не отображается — визуал накладывается на танк,
## который здесь замаскировался (см. DisguiseController).

@export var disguise_mesh: Mesh

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func _on_body_entered(body: Node) -> void:
	var controller: Node = body.get_node_or_null("DisguiseController")
	if controller != null:
		controller.register_slot(self)

func _on_body_exited(body: Node) -> void:
	var controller: Node = body.get_node_or_null("DisguiseController")
	if controller != null:
		controller.unregister_slot(self)
