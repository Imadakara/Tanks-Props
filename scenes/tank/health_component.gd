extends Node
## HealthComponent — многоударное разрушение (изначально было one-hit-kill для танков,
## ТЗ §7; теперь настраивается через max_hits — переиспользуется и для Objective режима
## "Destroy Target"). Танки читают max_hits из JSON-конфига игрока/бота
## (config/*_tank_config.json, сейчас 2 у обоих, см. team_spawner.gd), Objective — из
## GameConfig.objective_hits_required (см. match_manager.gd).
##
## [ИСПРАВЛЕНО, по прямому запросу — "танки уничтожались с двух попаданий и краснели при первом,
## это надо вернуть и сделать валидным правилом на всех картах"] Дефолт этого @export поднят с 1 на
## 2 — общее правило танкового урона, действующее ВЕЗДЕ, не только там, где team_spawner.gd успевает
## переопределить его из JSON — все карты спавнят ботов через TeamSpawner (см.
## `scenes/main/team_spawner.gd`), но подъём дефолта самого компонента остаётся
## отдельной страховкой: любой будущий статичный инстанс Tank.tscn, добавленный в обход спавнера,
## не должен молча откатываться на старый дефолт скрипта (1, one-hit-kill). Визуальное покраснение при
## нефинальном попадании уже было реализовано отдельно (см. tank.gd._on_damaged()) — оно просто
## никогда не успевало сработать при max_hits=1 (первый удар СРАЗУ финальный).

## killer добавлен в damaged (не только в destroyed) — нужен на КАЖДОМ попадании, не только
## смертельном, чтобы бот мог развернуться в сторону выстрела (см. tank_ai_controller.gd).
## ВАЖНО: Godot требует у подписчика ровно столько параметров, сколько эмитит сигнал (лишний
## аргумент НЕ отбрасывается молча — рантайм-ошибка) — все существующие подписчики (tank.gd)
## обновлены под новую сигнатуру.
signal damaged(current_hits: int, max_hits: int, killer: Node)
signal destroyed(killer: Node)

## [ИЗМЕНЕНО, по прямому запросу — "всем ботам и игроку сделать 3 HP (+1 по дефолту), чтобы был
## смысл применять мортиру по танкам"] Было 2. Танки читают из config/*_tank_config.json (тоже
## подняты на 3); подъём дефолта скрипта — та же страховка, что и раньше, для статичного инстанса
## Tank.tscn в обход спавнера. Objective перетирается на 100 (см. objective_hits_required).
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
## Используется точечно на конкретных инстансах (см. map_scene.gd — тумблер "Игрок: бессмертие",
## чтобы respawn/смерть игрока не мешали обкатывать ИИ бота), не общий баланс — поэтому не в
## GameConfig, а прямое свойство на конкретном танке.
@export var invincible: bool = false
var current_hits: int = 0
var is_alive: bool = true

## damage — сколько единиц урона снимает это попадание (обычный снаряд = 1, спец-выстрел мортиры =
## GameConfig.mortar_objective_damage). До перевода objective на HP-модель было всегда «+1
## попадание»; теперь current_hits/max_hits трактуются как HP. Для танков (max_hits = 3) мортира
## (30) — гарантированный one-shot, отдельной ветки не нужно.
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
