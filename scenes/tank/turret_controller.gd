extends Node3D
class_name TurretController
## TurretController — поворот башни к направлению камеры с задержкой.
## Пока танк в DISGUISED, башня заморожена (§6: «корпус и башня фиксируются»):
## расхождение целевого направления с текущим сверх freeze_epsilon_deg трактуется
## как «игрок повернул башню» и снимает маскировку (§5.1) — мелкий шум от свободного
## обзора камерой (в пределах эпсилона) маскировку не снимает.
## is_player_controlled=true берёт target_yaw из CameraRig-сиблинга; для ботов —
## false, TankAIController пишет target_yaw напрямую тем же полем.
## Довод — rotate_toward (линейная угловая скорость, turn_speed = реальные рад/сек), не
## lerp_angle: тот давал нелинейное ощущение (быстрый рывок на большом расхождении, потом
## бесконечно замедляющийся "дотяг" на подходе — доля ОТ ОСТАВШЕГОСЯ угла в кадр, а не
## постоянная скорость) — особенно било по бою у ботов (см. tank_ai_controller.gd):
## доворот на дальнюю цель ощущался быстрым, а финальная точная наводка — неестественно
## медленной. rotate_toward идёт с постоянной скоростью и всё равно не мгновенна.

const TankStateMachineScript := preload("res://scenes/tank/tank_state_machine.gd")

@export var turn_speed: float = 1.0  # рад/сек — постоянная угловая скорость довода
@export var freeze_epsilon_deg: float = 2.0
@export var is_player_controlled: bool = true
@export var target_yaw: float = 0.0

## Башня — ребёнок ПИВОТА КОРПУСА (`Hull`, см. hull_rig.gd), а не корня танка: погон физически
## стоит на корпусе и наклоняется вместе с ним, а этот узел вращает башню ровно по ОДНОЙ оси —
## своей локальной Y, то есть по нормали наклонённой палубы. Поэтому соседей (CameraRig,
## TankStateMachine) ищем не у прямого родителя, а у КОРНЯ танка. Тот же скрипт стоит и на
## `TurretPivot` стационарной турели (`scenes/turret/Turret.tscn`), где корень — StaticBody3D и
## ни камеры, ни стейт-машины нет вовсе: поиск обязан возвращать null, а не падать.
@onready var _camera_rig: Node3D = _find_on_body("CameraRig")
@onready var _state_machine: Node = _find_on_body("TankStateMachine")
## Для черты лёгкого класса (подвижная маскировка, DisguiseController.mobile_disguise). У турели
## узла нет — null.
@onready var _disguise: Node = _find_on_body("DisguiseController")

## Ближайший предок-физтело (CharacterBody3D танка или StaticBody3D турели) — на нём и висят
## компоненты. Поиск вверх, а не по фиксированному пути: глубина вложенности башни у танка и у
## турели разная.
func _find_on_body(node_name: String) -> Node:
	var ancestor: Node = get_parent()
	while ancestor != null:
		if ancestor is CollisionObject3D:
			return ancestor.get_node_or_null(node_name)
		ancestor = ancestor.get_parent()
	return null

func _physics_process(delta: float) -> void:
	if is_player_controlled and _camera_rig != null:
		target_yaw = _camera_rig.rotation.y

	if _state_machine != null and _state_machine.state == TankStateMachineScript.State.DISGUISED:
		# Подвижная маскировка (лёгкий): танк едет и поворачивает корпус, поэтому «башня отстала от
		# камеры» здесь не намерение игрока, а следствие хода. Башня просто замирает ОТНОСИТЕЛЬНО
		# КОРПУСА и маскировку не сбрасывает; камера при этом свободна. Сбросит выстрел / попадание /
		# враг рядом — как у всех.
		if _disguise != null and _disguise.mobile_disguise:
			return
		var diff := absf(wrapf(target_yaw - rotation.y, -PI, PI))
		if rad_to_deg(diff) > freeze_epsilon_deg:
			_state_machine.break_disguise("turret_rotation")
		else:
			return  # башня заморожена, мелкий шум камеры не в счёт

	rotation.y = rotate_toward(rotation.y, target_yaw, turn_speed * delta)
