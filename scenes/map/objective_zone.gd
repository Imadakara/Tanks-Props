extends Area3D
## ObjectiveZone — минимальный objective MVP (ТЗ §8.2; решение по открытому вопросу
## ТЗ §14 №1): атакующий танк должен непрерывно находиться в зоне
## GameConfig.objective_hold_time_sec подряд. Выход любого атакующего танка, пока
## внутри не осталось других атакующих, сбрасывает накопленный прогресс.

signal captured()
signal progress_changed(elapsed: float, required: float)

var _attackers_inside: Array = []
var _elapsed: float = 0.0
var _is_captured: bool = false

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func _on_body_entered(body: Node) -> void:
	if _is_attacker(body):
		_attackers_inside.append(body)

func _on_body_exited(body: Node) -> void:
	_attackers_inside.erase(body)
	if _attackers_inside.is_empty():
		_elapsed = 0.0
		progress_changed.emit(_elapsed, GameConfig.objective_hold_time_sec)

func _is_attacker(body: Node) -> bool:
	return body.has_method("is_attacker") and body.is_attacker()

func _process(delta: float) -> void:
	if _is_captured or _attackers_inside.is_empty():
		return
	_elapsed += delta
	progress_changed.emit(_elapsed, GameConfig.objective_hold_time_sec)
	if _elapsed >= GameConfig.objective_hold_time_sec:
		_is_captured = true
		captured.emit()
