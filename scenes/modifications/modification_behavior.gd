extends Node3D
## ModificationBehavior — базовый КОНТРАКТ поведения одной подбираемой модификации танка.
##
## Конкретная модификация = СЦЕНА (`Modification.behavior_scene`), корень которой наследует этот
## скрипт (`extends "res://scenes/modifications/modification_behavior.gd"` — path-based, БЕЗ
## `class_name`: грабля headless-рескана, как везде в проекте) и переопределяет только нужные
## методы. `ModificationController` инстансирует эту сцену ребёнком себя при `install()`, зовёт
## `setup()` + `on_installed()`, форвардит сюда весь игровой/AI-контракт (null-safe: пустой слот →
## нейтральный ответ), а при `clear_slot()` зовёт `on_removed()` + `queue_free()`.
##
## Все методы по умолчанию — no-op / нейтральное значение: пассивной модификации переопределять
## нечего (заняла слот, HUD её показывает — и всё). Полная реализация-образец — мортира:
## `scenes/modifications/mortar/mortar_behavior.gd` (+ vault `Tank_Prop_Hunt_Modifications.md`).

## Ставится `ModificationController`'ом сразу после `setup()`: false у бота (режим прицеливания с
## мышью/камерой — только у игрока; бот применяет модификацию через `ai_fire_at()`).
var is_player_controlled: bool = true

## Кэшировать нужные ссылки на компоненты танка. `tank` — корневой CharacterBody3D (Tank.tscn).
func setup(_tank: Node) -> void:
	pass

## Модификация встала в слот — построить визуал, подготовить состояние.
func on_installed() -> void:
	pass

## Модификация покидает слот (использована / потеряна на респавне). Снять визуал, выйти из
## любого активного режима. ОБЯЗАНА быть идемпотентной.
func on_removed() -> void:
	pass

# --- Игрок ------------------------------------------------------------------------------------

## true — нажатие игроком `fire` идёт СЮДА (`on_fire_pressed`), а не в обычную пушку
## (`WeaponController`). Пока true, обычный выстрел недоступен.
func intercepts_fire() -> bool:
	return false

## Игрок нажал `fire` (только если `intercepts_fire()`). Мортира: 1-й клик — режим прицеливания,
## 2-й — навесной выстрел.
func on_fire_pressed() -> void:
	pass

## true — корпус танка заморожен (`TankMovement` гейтит `_physics_process`). Мортира: пока целится.
func blocks_hull_movement() -> bool:
	return false

## true — HUD прячет экранный прицел. Мортира: пока целится (роль прицела играет кольцо на земле).
func hides_crosshair() -> bool:
	return false

# --- Боты (TankAIController) ----------------------------------------------------------------

## true — у бота есть готовый к применению спец-эффект в слоте (бот заходит в MOD/MORTAR-цикл).
func ai_usable() -> bool:
	return false

## Предпочтительная дистанция подхода к цели перед применением (approach в State.MORTAR_ATTACK).
func ai_engage_range() -> float:
	return 0.0

## Сколько секунд удерживать сведённый прицел до залпа (фаза подготовки бота).
func ai_prep_sec() -> float:
	return 0.0

## Углы наводки `{"yaw": float (мировой), "pitch": float}`, к которым бот сводит башню/дуло, чтобы
## попасть в `target` из точки `from`. Пустой Dictionary — решения нет (цель недостижима).
func ai_aim_solution(_from: Vector3, _target: Vector3) -> Dictionary:
	return {}

## Выполнить выстрел спец-эффектом по мировой точке `target`. true — выстрел состоялся (эффект
## израсходован, слот сейчас очистится самой модификацией). false — нельзя (нет боеприпаса / RELOAD).
func ai_fire_at(_target: Vector3) -> bool:
	return false
