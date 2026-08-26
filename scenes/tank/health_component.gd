extends Node
## HealthComponent — многоударное разрушение (изначально было one-hit-kill для танков,
## ТЗ §7; теперь настраивается через max_hits — переиспользуется и для DestructibleObjective
## режима "Destroy Target"). Танки читают max_hits из JSON-конфига игрока/бота
## (config/*_tank_config.json), DestructibleObjective — из GameConfig.objective_hits_required
## (оба выставляются извне, см. team_spawner.gd/match_manager.gd).

## killer добавлен в damaged (не только в destroyed) — нужен на КАЖДОМ попадании, не только
## смертельном, чтобы бот мог развернуться в сторону выстрела (см. bot_sentry_controller.gd).
## ВАЖНО: Godot требует у подписчика ровно столько параметров, сколько эмитит сигнал (лишний
## аргумент НЕ отбрасывается молча — рантайм-ошибка) — все существующие подписчики (tank.gd)
## обновлены под новую сигнатуру.
signal damaged(current_hits: int, max_hits: int, killer: Node)
signal destroyed(killer: Node)

@export var max_hits: int = 1
## true только на HealthComponent DestructibleObjective (ставит match_manager.gd) — оборона
## не должна вредить цели (см. «Игровые режимы»/Destroy Target). Определяем атакующего через
## killer.is_attacker() — killer это корень танка-стрелка (см. weapon_controller.gd).
@export var attackers_only: bool = false
## true (дефолт) — владелец удаляется из сцены при уничтожении, как и раньше (DestructibleObjective:
## разрушенная цель должна пропасть с карты). false — на танках (см. Tank.tscn), респаун берёт на
## себя RespawnController: он подписан на destroyed и решает, что делать с телом сам, поэтому
## здесь освобождать узел нельзя (пост-ревью).
@export var free_on_destroy: bool = true
var current_hits: int = 0
var is_alive: bool = true

func take_hit(killer: Node = null) -> void:
	if not is_alive:
		return
	if attackers_only and (killer == null or not killer.has_method("is_attacker") or not killer.is_attacker()):
		return  # снаряд обороны просто гасится о цель, урона нет — без сигнала damaged
	current_hits += 1
	damaged.emit(current_hits, max_hits, killer)
	if current_hits >= max_hits:
		is_alive = false
		destroyed.emit(killer)
		if free_on_destroy:
			get_parent().queue_free()
