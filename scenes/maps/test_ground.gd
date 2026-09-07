extends Node3D
## TestGround — ПОЛИГОН ИСПЫТАНИЙ ходовой части (scenes/maps/TestGroundMap.tscn).
##
## Это НЕ игровой режим и НЕ карта: сцена не запускает `map_scene.gd`, здесь нет ни
## MatchManager/ScoreManager, ни ростера ботов, ни HUD матча, ни навмеша. Одна задача — прогнать
## танк по рельефу и увидеть, что делает `hull_rig.gd`: наклон корпуса, просадка подвески,
## вращение катков и бег гусениц, зависимость скорости от уклона (`tank_movement.gd`).
##
## Весь курс СТРОИТСЯ КОДОМ из штатных префабов проекта (`Structure.tscn` — коробки,
## `ToyRamp.tscn` — наклонные полотна), а не лежит узлами в .tscn. Причина прикладная: углы
## пандусов здесь — главный измеряемый параметр, а `ToyRamp` задаёт угол парой run/rise; считать
## их и повороты руками в текстовом .tscn (где Transform3D сериализуется ПОСТРОЧНО, легко
## получить транспонированную матрицу) — ровно тот способ ошибиться, которого стоит избегать.
## В коде `Basis(Vector3.UP, yaw)` берёт столбцы правильно, а угол пандуса пишется градусами.
##
## Секции (старт — в +Z, движение по -Z):
##  - «Пандусы» прямо по курсу: восемь подъёмов 6°…48° с площадкой и спуском. Замерено живьём
##    (старт с места вплотную к подошве — самый строгий вариант): всё до 44° включительно танк
##    берёт, 48° не берёт вовсе, потому что это круче `floor_max_angle` (45°) и движок такую
##    поверхность полом не считает. Так стало ПОСЛЕ того, как нижние рёбра коллайдера срезали
##    фаской (см. секцию «Порожки» ниже): до фаски танк вставал уже на 36°, а старая заметка в
##    базе знаний §54 давала «практический предел ~24-25°». То есть предел определялся не уклоном,
##    а тем, что прямоугольная коробка утыкалась в полотно ребром.
##  - «Порожки» поперёк курса, сразу за стартом: восемь ступенек 0.04…0.40 высотой. Это НЕ про
##    наклон — это про то, что коробчатый танк не умеет step-up и упирается в любую вертикальную
##    грань. Практический случай, ради которого секция и появилась: подошва пандуса лежит чуть
##    выше поверхности, с которой на него заезжают, — и танк встаёт перед въездом. Замерено: до
##    фаски коллайдера танк не брал ДАЖЕ порожек 0.04 (то есть 7% высоты корпуса); с фаской берёт
##    до 0.20 включительно, на 0.24 встаёт. Величину задаёт сама фаска, см. `Tank.tscn`.
##  - «Стиральная доска» слева: шесть треугольных бугров подряд — быстрый знакопеременный тангаж.
##  - «Волны» справа: четыре очень пологих сегмента цилиндров — плавный тангаж без изломов.
##  - «Косогор» слева-впереди: широкое полотно, которое переезжают ПОПЕРЁК — чистый крен.
##  - «Трамплин» справа-впереди: подъём, площадка и обрыв — отрыв, приземление, просадка подвески.
##
## Клавиши: R — вернуть танк на старт, T — вкл/выкл наклон корпуса (сравнить «до/после»),
## Y — вкл/выкл анимацию ходовой, F — вкл/выкл информационное табло.

const StructureScene := preload("res://scenes/obstacles/Structure.tscn")
const RampScene := preload("res://scenes/obstacles/ToyRamp.tscn")
const TankScene := preload("res://scenes/tank/Tank.tscn")

## Половина стороны квадратного пола. Верх пола — ровно y = 0, как на боевых картах.
const GROUND_HALF := 34.0
const START_POSITION := Vector3(0.0, 0.3, 24.0)

## Пандусы курса: угол в градусах. run считается из угла, поэтому пологие пандусы автоматически
## получаются длинными. Последний (48°) — заведомо непроходимый: он круче `floor_max_angle` танка
## (45°), то есть движок вообще не считает такую поверхность полом. 44° — последний берущийся.
const RAMP_ANGLES_DEG := [6.0, 12.0, 18.0, 24.0, 30.0, 36.0, 44.0, 48.0]
const RAMP_PLATFORM_HEIGHT := 1.2
const RAMP_LANE_SPACING := 6.5
## Площадка каждого пандуса: ближний край z = 0, дальний z = -RAMP_PLATFORM_DEPTH.
const RAMP_PLATFORM_DEPTH := 4.0
const RAMP_WIDTH := 4.5

## Порожки: высота каждой ступеньки. Меряют не уклон, а способность танка перевалить вертикальную
## грань — тем, насколько срезаны нижние рёбра его коллайдера (фаска в `Tank.tscn`).
const LIP_HEIGHTS := [0.04, 0.08, 0.12, 0.16, 0.20, 0.24, 0.30, 0.40]
const LIP_LANE_Z := 17.0
const LIP_DEPTH := 3.0

const COLOR_GROUND := Color(0.24, 0.42, 0.24)
const COLOR_RAMP := Color(0.82, 0.74, 0.5)
const COLOR_PLATFORM := Color(0.7, 0.66, 0.58)
const COLOR_BUMP := Color(0.66, 0.5, 0.36)
const COLOR_WAVE := Color(0.45, 0.55, 0.62)
const COLOR_BORDER := Color(0.6, 0.15, 0.15)

@onready var _player: CharacterBody3D = $PlayerTank

var _hull: Node3D
var _movement: Node
var _info_label: Label
var _dummy: CharacterBody3D

func _ready() -> void:
	_build_ground()
	_build_ramp_lane()
	_build_lip_lane()
	_build_washboard()
	_build_waves()
	_build_side_slope()
	_build_jump()
	_build_info_panel()
	_hull = _player.get_node("Hull")
	_movement = _player.get_node("TankMovement")
	_spawn_dummy_tank()

func _process(_delta: float) -> void:
	if _info_label == null or not _info_label.visible:
		return
	_info_label.text = _info_text()

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match (event as InputEventKey).keycode:
		KEY_R:
			_reset_player()
		KEY_T:
			_hull.terrain_tilt_enabled = not _hull.terrain_tilt_enabled
		KEY_Y:
			_hull.animate_running_gear = not _hull.animate_running_gear
		KEY_F:
			_info_label.visible = not _info_label.visible

func _reset_player() -> void:
	_player.global_position = START_POSITION
	_player.rotation = Vector3.ZERO
	_player.velocity = Vector3.ZERO

# ---------------------------------------------------------------------------------------------
# Постройка курса
# ---------------------------------------------------------------------------------------------

## Коробка постоянной геометрии (`Structure.tscn`): размер/цвет ставятся ДО add_child() — сеттеры
## префаба до входа в дерево только запоминают значение, реальную геометрию собирает его _ready().
func _add_box(box_name: String, size: Vector3, position: Vector3, color: Color) -> Node3D:
	var box: Node3D = StructureScene.instantiate()
	box.name = box_name
	box.size = size
	box.color = color
	box.position = position
	add_child(box)
	return box

## Наклонное полотно (`ToyRamp.tscn`). Узел ставится в НИЗ въезда; `yaw` — куда он поднимается
## (0 — в сторону -Z, PI — в сторону +Z, PI/2 — в сторону -X).
func _add_ramp(
	ramp_name: String, position: Vector3, yaw: float, run: float, rise: float, width: float, color: Color
) -> Node3D:
	var ramp: Node3D = RampScene.instantiate()
	ramp.name = ramp_name
	ramp.run = run
	ramp.rise = rise
	ramp.width = width
	ramp.thickness = 0.6
	ramp.color = color
	ramp.transform = Transform3D(Basis(Vector3.UP, yaw), position)
	add_child(ramp)
	return ramp

func _add_label(text: String, position: Vector3) -> void:
	var label := Label3D.new()
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.fixed_size = true
	label.pixel_size = 0.0009
	label.outline_size = 14
	label.modulate = Color(1, 1, 1)
	label.outline_modulate = Color(0, 0, 0)
	label.position = position
	add_child(label)

## Пол + красная стенка по периметру. Стенка — та же идея, что `map_scene._build_map_borders()`
## на боевых картах (не дать съехать в пустоту), только здесь она нужна ещё и чтобы разогнавшийся
## на спуске танк не улетал за край.
func _build_ground() -> void:
	_add_box("Ground", Vector3(GROUND_HALF * 2.0, 2.0, GROUND_HALF * 2.0), Vector3(0.0, -1.0, 0.0), COLOR_GROUND)
	var thickness := 1.0
	var height := 3.0
	var span: float = GROUND_HALF * 2.0 + thickness * 2.0
	var offset: float = GROUND_HALF + thickness * 0.5
	_add_box("BorderNorth", Vector3(span, height, thickness), Vector3(0.0, height * 0.5, -offset), COLOR_BORDER)
	_add_box("BorderSouth", Vector3(span, height, thickness), Vector3(0.0, height * 0.5, offset), COLOR_BORDER)
	_add_box("BorderWest", Vector3(thickness, height, span), Vector3(-offset, height * 0.5, 0.0), COLOR_BORDER)
	_add_box("BorderEast", Vector3(thickness, height, span), Vector3(offset, height * 0.5, 0.0), COLOR_BORDER)

## Полоса пандусов: у каждого подъём с юга, площадка, спуск на север. Верхний конец каждого полотна
## приходится РОВНО на край площадки — правило расстановки из toy_ramp.gd (целиться внутрь
## площадки нельзя, танк упрётся в её вертикальную грань).
func _build_ramp_lane() -> void:
	var lane_count: int = RAMP_ANGLES_DEG.size()
	var first_x: float = -RAMP_LANE_SPACING * float(lane_count - 1) * 0.5
	for i in lane_count:
		var angle_deg: float = RAMP_ANGLES_DEG[i]
		var x: float = first_x + RAMP_LANE_SPACING * float(i)
		var run: float = RAMP_PLATFORM_HEIGHT / tan(deg_to_rad(angle_deg))
		_add_box(
			"RampPlatform%d" % i,
			Vector3(RAMP_WIDTH + 1.5, RAMP_PLATFORM_HEIGHT, RAMP_PLATFORM_DEPTH),
			Vector3(x, RAMP_PLATFORM_HEIGHT * 0.5, -RAMP_PLATFORM_DEPTH * 0.5),
			COLOR_PLATFORM
		)
		_add_ramp(
			"RampUp%d" % i, Vector3(x, 0.0, run), 0.0, run, RAMP_PLATFORM_HEIGHT, RAMP_WIDTH, COLOR_RAMP
		)
		_add_ramp(
			"RampDown%d" % i,
			Vector3(x, 0.0, -RAMP_PLATFORM_DEPTH - run),
			PI,
			run,
			RAMP_PLATFORM_HEIGHT,
			RAMP_WIDTH,
			COLOR_RAMP
		)
		var note: String = "%.0f°" % angle_deg
		if angle_deg > 45.0:
			note += " — не заедет (круче floor_max_angle)"
		_add_label(note, Vector3(x, RAMP_PLATFORM_HEIGHT + 1.6, -RAMP_PLATFORM_DEPTH * 0.5))

## Порожки — ступеньки разной высоты поперёк курса, по одной на полосу пандусов (стоят ПЕРЕД
## подошвами всех въездов, так что не мешают им). Воспроизводят практическую проблему: подошва
## пандуса чуть выше поверхности, с которой на неё заезжают → танк упирается в вертикальную грань
## и встаёт. Максимальная берущаяся высота задаётся фаской нижних рёбер коллайдера (`Tank.tscn`).
func _build_lip_lane() -> void:
	var lane_count: int = LIP_HEIGHTS.size()
	var first_x: float = -RAMP_LANE_SPACING * float(lane_count - 1) * 0.5
	for i in lane_count:
		var height: float = LIP_HEIGHTS[i]
		var x: float = first_x + RAMP_LANE_SPACING * float(i)
		_add_box(
			"Lip%d" % i,
			Vector3(RAMP_WIDTH + 1.5, height, LIP_DEPTH),
			Vector3(x, height * 0.5, LIP_LANE_Z),
			COLOR_BUMP
		)
		_add_label("порожек %.2f" % height, Vector3(x, height + 1.2, LIP_LANE_Z))

## «Стиральная доска»: треугольные бугры из двух встречных полотен — вершины сходятся в одной
## точке, получается ребро поперёк курса. Знакопеременный тангаж на каждом бугре.
func _build_washboard() -> void:
	var x := -30.0
	var half_run := 1.4
	var height := 0.28
	for i in 6:
		var z: float = 18.0 - float(i) * 4.0
		_add_ramp("BumpUp%d" % i, Vector3(x, 0.0, z + half_run), 0.0, half_run, height, 5.0, COLOR_BUMP)
		_add_ramp("BumpDown%d" % i, Vector3(x, 0.0, z - half_run), PI, half_run, height, 5.0, COLOR_BUMP)
	_add_label("Стиральная доска (11°, ребро)", Vector3(x, 2.4, 21.0))

## «Волны»: сегменты очень большого цилиндра, из которых наружу торчит лишь малая доля радиуса.
## Именно поэтому радиус такой большой: у закопанного цилиндра САМЫЙ крутой участок — у самой
## земли, и он тем положе, чем меньше отношение «высота над землёй / радиус». При r = 5 и
## высоте 0.25 кромка даёт ~18° — танк въезжает; при r = 1 та же высота дала бы ~41° и стену.
func _build_waves() -> void:
	var x := 30.0
	var radius := 5.0
	var exposure := 0.25
	for i in 4:
		var z: float = 18.0 - float(i) * 6.0
		var body := StaticBody3D.new()
		body.name = "Wave%d" % i
		body.collision_layer = 1
		body.collision_mask = 0
		body.transform = Transform3D(Basis(Vector3.BACK, PI * 0.5), Vector3(x, exposure - radius, z))
		add_child(body)

		var shape := CollisionShape3D.new()
		var cylinder := CylinderShape3D.new()
		cylinder.radius = radius
		cylinder.height = 6.0
		shape.shape = cylinder
		body.add_child(shape)

		var mesh_resource := CylinderMesh.new()
		mesh_resource.top_radius = radius
		mesh_resource.bottom_radius = radius
		mesh_resource.height = 6.0
		mesh_resource.radial_segments = 48
		var mesh := MeshInstance3D.new()
		mesh.mesh = mesh_resource
		var material := StandardMaterial3D.new()
		material.albedo_color = COLOR_WAVE
		mesh.material_override = material
		body.add_child(mesh)
	_add_label("Волны (плавный тангаж)", Vector3(x, 2.4, 21.0))

## «Косогор»: полотно, поднимающееся в сторону -X, шириной вдоль Z. Переезжают его ПОПЕРЁК
## (движение по Z) — корпус кренится, курс при этом не меняется. Единственная секция, где
## проверяется именно крен, а не тангаж.
func _build_side_slope() -> void:
	var run := 8.0
	var rise := 2.4
	_add_ramp("SideSlope", Vector3(-2.0, 0.0, -20.0), PI * 0.5, run, rise, 16.0, COLOR_RAMP)
	_add_box(
		"SideSlopeTop",
		Vector3(4.0, rise, 16.0),
		Vector3(-run - 4.0, rise * 0.5, -20.0),
		COLOR_PLATFORM
	)
	_add_label("Косогор %.0f° (переезжать поперёк)" % rad_to_deg(atan2(rise, run)), Vector3(-6.0, 3.6, -20.0))

## «Трамплин»: подъём на площадку, дальний край которой обрывается на землю. Показывает отрыв,
## приземление и пружину просадки (hull_rig._update_landing_bob). Высота 1.8 сознательно НИЖЕ
## GameConfig.fall_damage_min_height — прыжок не должен отнимать HP, иначе секцию не покатать.
func _build_jump() -> void:
	var run := 6.0
	var rise := 1.8
	_add_ramp("JumpRamp", Vector3(14.0, 0.0, -18.0), 0.0, run, rise, 5.0, COLOR_RAMP)
	_add_box(
		"JumpPlatform",
		Vector3(5.0, rise, 3.0),
		Vector3(14.0, rise * 0.5, -18.0 - run - 1.5),
		COLOR_PLATFORM
	)
	_add_label("Трамплин %.0f°" % rad_to_deg(atan2(rise, run)), Vector3(14.0, rise + 2.0, -20.0))

# ---------------------------------------------------------------------------------------------
# Обвязка: манекен и табло
# ---------------------------------------------------------------------------------------------

## Второй танк — неподвижный манекен на площадке 18°: со стороны видно наклон корпуса под
## стоящей ровно башней (гиростабилизация, см. hull_rig.gd), чего на своём танке от третьего лица
## толком не разглядеть. Флаги управления снимаются ДО add_child(): у Tank.tscn каждый компонент
## по умолчанию is_player_controlled = true и иначе читал бы ту же клавиатуру, что игрок, а
## CameraRig перехватил бы Camera3D.current прямо в своём _ready() (см. CLAUDE.md, «Scene
## bring-up ordering»).
func _spawn_dummy_tank() -> void:
	_dummy = TankScene.instantiate()
	_dummy.name = "DummyTank"
	_dummy.get_node("CameraRig").is_active = false
	for path in ["TankMovement", "Turret", "Turret/Barrel", "WeaponController", "DisguiseController"]:
		_dummy.get_node(path).is_player_controlled = false
	_dummy.team = 1
	# Ставим его серединой КОСОГОРА, а не на ровное место: там корпус кренится вбок, и со стороны
	# отлично видно главное — корпус наклонён, а башня стоит ровно. Пандусы при этом остаются
	# свободными: манекен посреди испытательной полосы просто мешал бы заезжать.
	# Гравитация досадит его на полотно за пару кадров.
	_dummy.position = Vector3(-6.0, 1.6, -20.0)
	add_child(_dummy)
	_dummy.apply_team_visuals()

func _build_info_panel() -> void:
	var layer := CanvasLayer.new()
	layer.name = "InfoLayer"
	add_child(layer)
	_info_label = Label.new()
	_info_label.name = "InfoLabel"
	_info_label.position = Vector2(16.0, 16.0)
	_info_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_info_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_info_label.add_theme_constant_override("outline_size", 6)
	layer.add_child(_info_label)

func _info_text() -> String:
	var forward: Vector3 = -_player.global_transform.basis.z
	var speed: float = _player.velocity.dot(forward)
	var lines := [
		"ПОЛИГОН ХОДОВОЙ — R: на старт | T: наклон корпуса | Y: анимация ходовой | F: табло",
		"Скорость: %+.2f м/с   На земле: %s" % [speed, "да" if _player.is_on_floor() else "нет"],
		"Корпус (визуал): тангаж %+.1f°  крен %+.1f°" % [rad_to_deg(_hull.rotation.x), rad_to_deg(_hull.rotation.z)],
		"Опора (лучи):    тангаж %+.1f°  крен %+.1f°  просадка %+.2f" % [
			rad_to_deg(_hull.ground_pitch), rad_to_deg(_hull.ground_roll), _hull.position.y
		],
		"Наклон корпуса: %s   Анимация ходовой: %s" % [
			"вкл" if _hull.terrain_tilt_enabled else "ВЫКЛ",
			"вкл" if _hull.animate_running_gear else "ВЫКЛ"
		],
		"Множитель скорости от уклона: %.2f" % _movement._slope_speed_multiplier(forward * signf(speed)),
		"Позиция: (%.1f, %.1f, %.1f)" % [_player.global_position.x, _player.global_position.y, _player.global_position.z],
	]
	return "\n".join(lines)
