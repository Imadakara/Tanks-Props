extends Node3D
## ModificationController — единственный слот подбираемой модификации танка. Сиблинг-компонент
## под корнем Tank.tscn, тот же паттерн композиции и развязки player/AI через is_player_controlled,
## что у остальных компонентов танка. (Полное описание системы — vault Tank_Prop_Hunt_Modifications.md.)
##
## Слот:
## - подобрать модификацию можно ТОЛЬКО в пустой слот (can_pick_up()); подбор доступен обеим
##   командам (в т.ч. чтобы denyнуть противнику);
## - сбросить/удалить модификацию нельзя — только использовать (модификация сама зовёт clear_slot()
##   после применения) или потерять вместе с танком (RespawnController зовёт clear_slot() на респавне);
## - боты подбирают И применяют (см. tank_ai_controller.gd, State.MOD_SEEK/MOD_RETRIEVE/MORTAR_ATTACK).
##
## Логика конкретной модификации живёт в её СЦЕНЕ-ПОВЕДЕНИИ (Modification.behavior_scene, корень —
## Node3D со скриптом-наследником scenes/modifications/modification_behavior.gd). install()
## инстансирует эту сцену ребёнком этого узла, зовёт setup(tank) + on_installed(); clear_slot()
## зовёт on_removed() + queue_free(). Весь игровой/AI-контракт (intercepts_fire / on_fire_pressed /
## blocks_hull_movement / hides_crosshair / ai_*) этот узел ФОРВАРДИТ в поведение, null-safe:
## пустой слот → нейтральный ответ. Образец поведения — мортира:
## scenes/modifications/mortar/mortar_behavior.gd.

signal mod_changed(mod: Resource)

## Ботам ставится в false из TankAIController._initialize(): режим прицеливания (мышь/камера) —
## только у игрока, бот применяет модификацию через ai_fire_at(). Передаётся в поведение при install().
@export var is_player_controlled: bool = true

## null == слот пуст. Ссылка на Modification-ресурс (scenes/modifications/*.tres).
var current_mod: Resource = null

## Инстанс current_mod.behavior_scene — ребёнок этого узла, живёт пока модификация в слоте.
var _behavior: Node = null

@onready var _body: CharacterBody3D = get_parent()

# --- Слот -------------------------------------------------------------------------------------

func can_pick_up() -> bool:
	return current_mod == null

## Вставить модификацию в слот. false — слот занят / mod == null. Зовётся из ModCrate при
## физическом контакте танка с ящиком (игрок и бот одинаково).
func install(mod: Resource) -> bool:
	if current_mod != null or mod == null:
		return false
	current_mod = mod
	if mod.behavior_scene != null:
		_behavior = mod.behavior_scene.instantiate()
		add_child(_behavior)
		_behavior.setup(_body)
		_behavior.is_player_controlled = is_player_controlled
		_behavior.on_installed()
	mod_changed.emit(current_mod)
	return true

## Освободить слот. Точки вызова: сама модификация после применения («использована») и
## RespawnController на респавне («потеряна с танком»). Идемпотентна.
func clear_slot() -> void:
	if _behavior != null:
		_behavior.on_removed()
		_behavior.queue_free()
		_behavior = null
	if current_mod == null:
		return
	current_mod = null
	mod_changed.emit(null)

# --- Форвардинг контракта в поведение (null-safe: пустой слот → нейтральный ответ) -----------

func intercepts_fire() -> bool:
	return _behavior != null and _behavior.intercepts_fire()

func on_fire_pressed() -> void:
	if _behavior != null:
		_behavior.on_fire_pressed()

func blocks_hull_movement() -> bool:
	return _behavior != null and _behavior.blocks_hull_movement()

func hides_crosshair() -> bool:
	return _behavior != null and _behavior.hides_crosshair()

func ai_usable() -> bool:
	return _behavior != null and _behavior.ai_usable()

func ai_engage_range() -> float:
	return _behavior.ai_engage_range() if _behavior != null else 0.0

func ai_prep_sec() -> float:
	return _behavior.ai_prep_sec() if _behavior != null else 0.0

func ai_aim_solution(from: Vector3, target: Vector3) -> Dictionary:
	return _behavior.ai_aim_solution(from, target) if _behavior != null else {}

func ai_fire_at(target: Vector3) -> bool:
	return _behavior != null and _behavior.ai_fire_at(target)
