extends Node3D
## BarrelController — вертикальный наклон дула. Следует за питчем камеры (независимой от корпуса,
## см. camera_rig.gd) с плавным доводом, аналогично тому, как TurretController доводит yaw за
## камерой. Итоговое направление выстрела WeaponController берёт прямо из basis.z дула — своих
## формул угла там больше нет.
##
## ДВЕ РАЗНЫЕ СИСТЕМЫ ОТСЧЁТА, это здесь главное:
## - `target_pitch` — угол, который ЗАКАЗЫВАЮТ, в МИРОВОЙ системе (горизонт = 0). Ровно это и
##   имеют в виду все, кто в него пишет: камера игрока (её питч мировой, CameraRig висит на корне
##   танка и не кренится), баллистика бота (`_compute_ballistic_pitch()` решает уравнение
##   траектории относительно горизонта) и решение мортиры. Менять смысл поля было нельзя.
## - `rotation.x` — то, на что реально повёрнут узел дула ОТНОСИТЕЛЬНО БАШНИ, а башня с некоторых
##   пор кренится вместе с корпусом (она ребёнок пивота `Hull`, см. hull_rig.gd). Именно к этой,
##   локальной величине применяются механические пределы `min_pitch_deg`/`max_pitch_deg` — у
##   настоящей пушки предел возвышения задан цапфами в башне, а не горизонтом.
##
## Отсюда вся арифметика: из заказанного мирового угла вычитается наклон САМОГО ПОГОНА в текущем
## направлении башни (`_mount_pitch()`), остаток и есть требуемый локальный угол, и уже он
## зажимается пределами. На ровной земле наклон погона равен нулю и поведение в точности прежнее.
## Практическое следствие, которое так и задумано: на крутом подъёме пушка физически не
## опускается до горизонта — упирается в предел склонения, и прицел это честно показывает.

@export var pitch_speed: float = 3.0  # рад/сек довода
@export var min_pitch_deg: float = -15.0
## Предел возвышения ОБЫЧНОГО выстрела. Держать невысоким сознательно: камера 3-го лица при
## подъёме прицела подходит к макушке башни (см. camera_rig.gd), и чем выше задирается дуло, тем
## сильнее корпус лезет в кадр. Навесной стрельбе мортиры этот предел не мешает — она на время
## прицеливания поднимает его сама (mortar_behavior.gd) и всё равно стреляет по собственному
## направлению через WeaponController.fire_special().
@export var max_pitch_deg: float = 20.0
@export var is_player_controlled: bool = true
@export var target_pitch: float = 0.0

## CameraRig живёт на КОРНЕ танка, а дуло теперь лежит глубже (`Hull/Turret/Barrel`), поэтому ищем
## вверх по предкам до физтела, а не по фиксированному числу get_parent(). Тот же скрипт стоит на
## стволе стационарной турели (`scenes/turret/Turret.tscn`), где камеры нет вовсе — там поиск
## штатно возвращает null.
@onready var _camera_rig: Node3D = _find_on_body("CameraRig")

func _find_on_body(node_name: String) -> Node:
	var ancestor: Node = get_parent()
	while ancestor != null:
		if ancestor is CollisionObject3D:
			return ancestor.get_node_or_null(node_name)
		ancestor = ancestor.get_parent()
	return null

func _physics_process(delta: float) -> void:
	if is_player_controlled and _camera_rig != null:
		target_pitch = _camera_rig.rotation.x
	var limits: Vector2 = local_pitch_limits()
	var local_target: float = clampf(target_pitch - mount_pitch(), limits.x, limits.y)
	rotation.x = lerp_angle(rotation.x, local_target, pitch_speed * delta)

## Наклон ПОГОНА в текущем направлении башни: питч оси, вокруг которой поднимается дуло. Берётся
## из живой ориентации родителя (башни), поэтому автоматически учитывает и тангаж, и крен корпуса
## под любым углом поворота башни. На ровной земле — 0.
func mount_pitch() -> float:
	var mount: Node3D = get_parent() as Node3D
	if mount == null:
		return 0.0
	return asin(clampf((-mount.global_transform.basis.z).y, -1.0, 1.0))

func local_pitch_limits() -> Vector2:
	return Vector2(deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))

## Фактический угол дула В МИРОВОЙ системе — то, во что реально полетит снаряд. Читатели, которые
## проверяют «прицел сведён» (tank_ai_controller.gd), обязаны сравнивать заказанный `target_pitch`
## именно с ним, а НЕ с `rotation.x`: на склоне это разные величины, и сравнение с локальным углом
## никогда бы не сошлось — бот перестал бы стрелять.
func world_pitch() -> float:
	return asin(clampf((-global_transform.basis.z).y, -1.0, 1.0))

## Диапазон, достижимый В МИРОВОЙ системе с текущим наклоном погона. Баллистика бота зажимает
## своё решение этим, а не сырыми min/max: на уклоне окно возвышения уезжает вместе с корпусом.
func world_pitch_limits() -> Vector2:
	var mount: float = mount_pitch()
	return Vector2(deg_to_rad(min_pitch_deg) + mount, deg_to_rad(max_pitch_deg) + mount)
