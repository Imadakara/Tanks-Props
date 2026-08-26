extends Node3D
## BarrelController — вертикальный наклон дула: -15° (вниз) .. +30° (вверх), диапазон
## 45°. Следует за питчем камеры (независимой от корпуса, см. camera_rig.gd) с плавным
## доводом, аналогично тому, как TurretController доводит yaw за камерой. Итоговое
## направление выстрела WeaponController берёт прямо из basis.z дула — своих формул угла
## там больше нет.

@export var pitch_speed: float = 3.0  # рад/сек довода
@export var min_pitch_deg: float = -15.0
@export var max_pitch_deg: float = 30.0
@export var is_player_controlled: bool = true
@export var target_pitch: float = 0.0

@onready var _camera_rig: Node3D = get_parent().get_parent().get_node_or_null("CameraRig")

func _physics_process(delta: float) -> void:
	if is_player_controlled and _camera_rig != null:
		target_pitch = clamp(_camera_rig.rotation.x, deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))
	rotation.x = lerp_angle(rotation.x, target_pitch, pitch_speed * delta)
