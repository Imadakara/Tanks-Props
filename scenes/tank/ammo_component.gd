extends Node
## AmmoComponent — боезапас танка: расход при выстреле, пополнение от подобранного ящика
## боеприпасов (зона сброса AmmoDropZone, см. scenes/ammo_crate/ammo_drop_zone.gd).
## Ёмкость — своя у каждого класса танка (chassis.gd → set_capacity()); GameConfig.ammo_per_tank —
## только дефолт для танка без узла Chassis.

signal ammo_changed(current: int, max: int)
signal ammo_depleted()

var current_ammo: int
var max_ammo: int

func _ready() -> void:
	max_ammo = GameConfig.ammo_per_tank
	current_ammo = max_ammo
	ammo_changed.emit(current_ammo, max_ammo)

## Ёмкость боекомплекта класса. Зовёт chassis.gd уже после _ready() — поэтому заодно доливает
## текущий запас до новой ёмкости: класс применяется на спавне, танк должен выйти в бой полным.
func set_capacity(value: int) -> void:
	max_ammo = maxi(value, 0)
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
