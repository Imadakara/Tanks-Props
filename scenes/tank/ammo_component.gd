extends Node
## AmmoComponent — боезапас танка: расход при выстреле, пополнение от подобранного ящика
## боеприпасов (зона сброса AmmoDropZone, см. scenes/ammo_crate/ammo_drop_zone.gd).
## Максимум берётся из GameConfig.ammo_per_tank.

signal ammo_changed(current: int, max: int)
signal ammo_depleted()

var current_ammo: int
var max_ammo: int

func _ready() -> void:
	max_ammo = GameConfig.ammo_per_tank
	current_ammo = max_ammo
	ammo_changed.emit(current_ammo, max_ammo)

func has_ammo() -> bool:
	return current_ammo > 0

func consume() -> void:
	if current_ammo <= 0:
		return
	current_ammo -= 1
	ammo_changed.emit(current_ammo, max_ammo)
	if current_ammo <= 0:
		ammo_depleted.emit()

func add_ammo(amount: int) -> void:
	current_ammo += amount
	ammo_changed.emit(current_ammo, max_ammo)
