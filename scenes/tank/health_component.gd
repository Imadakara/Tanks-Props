extends Node
## HealthComponent — многоударное разрушение, настраивается через max_hits;
## переиспользуется и для Objective режима "Destroy Target". Танки читают max_hits из JSON-конфига
## игрока/бота (config/*_tank_config.json, 3 у обоих, см. team_spawner.gd), Objective — из
## GameConfig.objective_hits_required (см. match_manager.gd). Дефолт @export (3) — страховка для
## статичного инстанса Tank.tscn в обход TeamSpawner, чтобы он не откатывался на устаревшее число.
## При нефинальном попадании корпус+башня красятся в «подранка» (tank.gd._on_damaged()).

## killer добавлен в damaged (не только в destroyed) — нужен на КАЖДОМ попадании, не только
## смертельном, чтобы бот мог развернуться в сторону выстрела (см. tank_ai_controller.gd).
## ВАЖНО: Godot требует у подписчика ровно столько параметров, сколько эмитит сигнал (лишний
## аргумент НЕ отбрасывается молча — рантайм-ошибка) — все существующие подписчики (tank.gd)
## обновлены под новую сигнатуру.
signal damaged(current_hits: int, max_hits: int, killer: Node)
signal destroyed(killer: Node)

## Танки — 3 HP (config/*_tank_config.json + этот дефолт): мортира (20 ≥ 3) гарантированно
## one-shot, обычный снаряд — 3 попадания. Objective перетирается на 100 (см. objective_hits_required).
@export var max_hits: int = 3
## true только на HealthComponent узла Objective (задано прямо в .tscn каждой карты) — оборона
## не должна вредить цели (см. «Игровые режимы»/Destroy Target). Определяем атакующего через
## killer.is_attacker() — killer это корень танка-стрелка (см. weapon_controller.gd).
@export var attackers_only: bool = false
## true (дефолт) — владелец удаляется из сцены при уничтожении (Objective: разрушенная цель должна
## пропасть с карты). false — на танках (см. Tank.tscn), респаун берёт на себя RespawnController:
## он подписан на destroyed и решает, что делать с телом сам, поэтому здесь освобождать узел нельзя.
@export var free_on_destroy: bool = true
## true — попадания полностью игнорируются (ни damaged, ни destroyed, current_hits не растёт).
## Точечное свойство конкретного инстанса, не общий баланс. Форсится в true на танке игрока в
## debug-режиме (map_scene.gd + тумблер "Игрок: бессмертие"); при debug OFF игрок смертен.
@export var invincible: bool = false
var current_hits: int = 0
var is_alive: bool = true

## damage — сколько единиц урона снимает это попадание (обычный снаряд = 1, спец-выстрел мортиры =
## GameConfig.mortar_objective_damage 20). current_hits/max_hits для цели трактуются как HP; для
## танков (max_hits = 3) мортира (20) — гарантированный one-shot, отдельной ветки не нужно.
func take_hit(killer: Node = null, damage: int = 1) -> void:
	if invincible:
		return
	if not is_alive:
		return
	if attackers_only and (killer == null or not killer.has_method("is_attacker") or not killer.is_attacker()):
		return  # снаряд обороны просто гасится о цель, урона нет — без сигнала damaged
	current_hits += damage
	damaged.emit(current_hits, max_hits, killer)
	if current_hits >= max_hits:
		is_alive = false
		destroyed.emit(killer)
		if free_on_destroy:
			get_parent().queue_free()

## Принудительное уничтожение В ОБХОД invincible / attackers_only — для нештатных ситуаций, где
## танк надо убрать из игры независимо от дебаг-бессмертия (провал за пределы карты, см.
## respawn_controller.gd). Идёт по тому же пути, что обычная смерть: is_alive=false + сигнал
## destroyed (+ free_on_destroy) — подписчики (RespawnController) отрабатывают как всегда.
func force_destroy(killer: Node = null) -> void:
	if not is_alive:
		return
	is_alive = false
	current_hits = max_hits
	destroyed.emit(killer)
	if free_on_destroy:
		get_parent().queue_free()
