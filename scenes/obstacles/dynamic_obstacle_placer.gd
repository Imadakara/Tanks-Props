extends RefCounted
## Динамическая расстановка препятствий перед матчем — MVP-правила (см. корневой CLAUDE.md
## "Dynamic obstacle system", Tank_Prop_Hunt_Obstacles_Navmesh_Guide.md §9). Ставит до
## MAX_OBSTACLES коричневых кубов (Obstacle.tscn, дефолтный размер) в случайные точки карты:
##  - не более MAX_OBSTACLES штук;
##  - не внутри ни одной круглой зоны (группа "zone_circles": spawn / waypoint / alert / ammo /
##    hide) + запас;
##  - не внутри непроходимых зон (группа "hazard_zones", editor-placed) + запас;
##  - не внутри объекта-цели / стационарной турели + запас;
##  - не пересекаясь с уже поставленными кубами (минимальная дистанция между центрами);
##  - в пределах Ground минус EDGE_MARGIN (куб не торчит в стену-границу карты).
## Непроходимые зоны САМА не трогает — они editor-placed и служат ограничением поля.
##
## RNG seeded (RandomNumberGenerator + явный seed), всё аналитически и синхронно — раскладка
## воспроизводима по одному int (для будущего сетевого кода: хост шлёт seed, пиры строят
## идентичную карту). Единственный physics-запрос — луч вниз за реальной высотой земли.
##
## Вызывается map_scene.gd._apply_dynamic_obstacles() после _build_map_borders() и ДО
## TeamSpawner.spawn_team(); статические Obstacle.tscn убирает вызывающий код. После populate()
## вызывающий перепекает навмеш (NavigationRegion3D.bake_navigation_mesh + await bake_finished).
##
## Без class_name намеренно — headless run_project не подхватывает свежий class_name без
## пересканирования редактором (см. CLAUDE.md). Подключается через preload, вызовы статические.

const ObstacleScene := preload("res://scenes/obstacles/Obstacle.tscn")

const MAX_OBSTACLES := 30
## Габарит куба Obstacle.tscn по умолчанию (= GameConfig.disguise_prop_size — важно для маскировки:
## имитируемый пропом объект должен совпадать по виду с этими кубами). Если дефолт префаба
## поменяется — поправить здесь.
const OBSTACLE_SIZE := Vector3(2.0, 1.25, 2.0)
const EDGE_MARGIN := 3.0          # от края карты (стены-границы MapBorders)
const ZONE_CLEARANCE := 1.5       # сверх радиуса круглой зоны
const KEEPOUT_CLEARANCE := 1.0    # сверх габарита hazard / objective / турели
const OBSTACLE_GAP := 0.6         # минимальный зазор между двумя кубами
const ATTEMPTS_PER_OBSTACLE := 40
const _GROUND_RAY_UP := 12.0
const _GROUND_RAY_DOWN := 24.0

## map_root — корень сцены карты (Node3D). nav_region — узел, под который вешать кубы (обычно
## map_root/NavigationRegion3D — запекатель навмеша берёт их геометрию по слою 1). seed_value —
## зерно RNG. Возвращает число реально поставленных кубов (может быть < MAX_OBSTACLES на тесной
## карте — это норма, правило «не более 30»).
static func populate(map_root: Node3D, nav_region: Node3D, seed_value: int) -> int:
	var ground := map_root.find_child("Ground", true, false) as Node3D
	if ground == null:
		push_warning("dynamic_obstacle_placer: узла Ground нет — расстановка пропущена")
		return 0
	var ground_cs := ground.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if ground_cs == null or not (ground_cs.shape is BoxShape3D):
		push_warning("dynamic_obstacle_placer: Ground без BoxShape3D — расстановка пропущена")
		return 0
	var ground_box := ground_cs.shape as BoxShape3D

	var half_fp: float = OBSTACLE_SIZE.x * 0.5
	var bx: float = maxf(1.0, ground_box.size.x * 0.5 - EDGE_MARGIN - half_fp)
	var bz: float = maxf(1.0, ground_box.size.z * 0.5 - EDGE_MARGIN - half_fp)
	var cx: float = ground.global_position.x
	var cz: float = ground.global_position.z
	var ground_top: float = ground.global_position.y + ground_box.size.y * 0.5  # верх пола (обычно 0)

	var circles := _collect_circles(map_root)      # (center_x, center_z, radius)
	var boxes := _collect_keepout_boxes(map_root)  # (center_x, center_z, half_x, half_z)

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var space := map_root.get_world_3d().direct_space_state
	var placed := PackedVector2Array()  # центры уже поставленных кубов (XZ)
	var min_pair: float = OBSTACLE_SIZE.x + OBSTACLE_GAP

	for _i in range(MAX_OBSTACLES):
		var found := false
		var p := Vector2.ZERO
		for _a in range(ATTEMPTS_PER_OBSTACLE):
			var cand := Vector2(cx + rng.randf_range(-bx, bx), cz + rng.randf_range(-bz, bz))
			if _hits_circle(cand, half_fp + ZONE_CLEARANCE, circles):
				continue
			if _hits_box(cand, half_fp + KEEPOUT_CLEARANCE, boxes):
				continue
			if _too_close(cand, placed, min_pair):
				continue
			p = cand
			found = true
			break
		if not found:
			continue  # места не нашлось за ATTEMPTS_PER_OBSTACLE — просто меньше кубов, идём дальше
		var y := _ground_y(space, p, ground_top)
		var obs := ObstacleScene.instantiate() as Node3D
		nav_region.add_child(obs)
		# Куб стоит НА земле: центр = верх пола + половина высоты (как статические Obstacle* в .tscn).
		obs.global_position = Vector3(p.x, y + OBSTACLE_SIZE.y * 0.5, p.y)
		placed.append(p)

	return placed.size()


## Все круглые зоны-маркеры (spawn_zone.gd сам регистрируется в группу "zone_circles" в _ready()).
## Каждая → Vector3(center_x, center_z, radius).
static func _collect_circles(map_root: Node) -> PackedVector3Array:
	var out := PackedVector3Array()
	for node in map_root.get_tree().get_nodes_in_group("zone_circles"):
		var z := node as Node3D
		if z == null or not ("radius" in z):
			continue
		var r: float = z.get("radius")
		out.append(Vector3(z.global_position.x, z.global_position.z, r))
	return out


## Прямоугольные keep-out: непроходимые зоны (editor-placed) + объект-цель + стационарные турели.
## Каждый → Vector4(center_x, center_z, half_x, half_z).
static func _collect_keepout_boxes(map_root: Node) -> PackedVector4Array:
	var out := PackedVector4Array()
	for node in map_root.get_tree().get_nodes_in_group("hazard_zones"):
		var h := node as Node3D
		if h == null:
			continue
		var box := _world_box_xz(h, h.get_node_or_null("CollisionShape3D") as CollisionShape3D)
		if box.w >= 0.0:
			out.append(box)
	var obj := map_root.find_child("Objective", true, false) as Node3D
	if obj != null:
		var box := _world_box_xz(obj, obj.get_node_or_null("CollisionShape3D") as CollisionShape3D)
		if box.w >= 0.0:
			out.append(box)
	for node in map_root.get_tree().get_nodes_in_group("turrets"):
		var t := node as Node3D
		if t == null or not ("body_size" in t):
			continue
		var bs: Vector3 = t.get("body_size")
		out.append(Vector4(t.global_position.x, t.global_position.z, bs.x * 0.5, bs.z * 0.5))
	return out


## Мировой XZ-AABB коробки `box_node.global_transform * BoxShape3D` — учитывает масштаб и поворот
## (HazardZone* в .tscn заданы через scale, часть повёрнута на 90°). Для повёрнутого не-на-90°
## бокса это консервативная (более широкая) оценка — для keep-out безопасно.
## Возвращает Vector4(center_x, center_z, half_x, half_z); w (half_z) = -1.0, если формы нет.
static func _world_box_xz(box_node: Node3D, shape_holder: CollisionShape3D) -> Vector4:
	if shape_holder == null or not (shape_holder.shape is BoxShape3D):
		return Vector4(0.0, 0.0, 0.0, -1.0)
	var hs: Vector3 = (shape_holder.shape as BoxShape3D).size * 0.5
	var t: Transform3D = box_node.global_transform
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for sx: float in [-1.0, 1.0]:
		for sy: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				var w: Vector3 = t * Vector3(hs.x * sx, hs.y * sy, hs.z * sz)
				min_x = minf(min_x, w.x)
				max_x = maxf(max_x, w.x)
				min_z = minf(min_z, w.z)
				max_z = maxf(max_z, w.z)
	return Vector4((min_x + max_x) * 0.5, (min_z + max_z) * 0.5, (max_x - min_x) * 0.5, (max_z - min_z) * 0.5)


static func _hits_circle(p: Vector2, pad: float, circles: PackedVector3Array) -> bool:
	for c in circles:
		if p.distance_to(Vector2(c.x, c.y)) < c.z + pad:
			return true
	return false


static func _hits_box(p: Vector2, pad: float, boxes: PackedVector4Array) -> bool:
	for b in boxes:
		if absf(p.x - b.x) < b.z + pad and absf(p.y - b.y) < b.w + pad:
			return true
	return false


static func _too_close(p: Vector2, placed: PackedVector2Array, min_dist: float) -> bool:
	for q in placed:
		if p.distance_to(q) < min_dist:
			return true
	return false


static func _ground_y(space: PhysicsDirectSpaceState3D, p: Vector2, fallback_top: float) -> float:
	var from := Vector3(p.x, fallback_top + _GROUND_RAY_UP, p.y)
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * _GROUND_RAY_DOWN)
	q.collision_mask = 1  # environment (Ground)
	var hit: Dictionary = space.intersect_ray(q)
	if hit.is_empty():
		return fallback_top
	var pos: Vector3 = hit["position"]
	return pos.y
