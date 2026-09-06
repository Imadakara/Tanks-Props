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

@onready var _camera_rig: Node3D = get_parent().get_node_or_null("CameraRig")
@onready var _state_machine: Node = get_parent().get_node_or_null("TankStateMachine")

func _physics_process(delta: float) -> void:
	if is_player_controlled and _camera_rig != null:
		target_yaw = _camera_rig.rotation.y

	if _state_machine != null and _state_machine.state == TankStateMachineScript.State.DISGUISED:
		var diff := absf(wrapf(target_yaw - rotation.y, -PI, PI))
		if rad_to_deg(diff) > freeze_epsilon_deg:
			_state_machine.break_disguise("turret_rotation")
		else:
			return  # башня заморожена, мелкий шум камеры не в счёт

	rotation.y = rotate_toward(rotation.y, target_yaw, turn_speed * delta)
