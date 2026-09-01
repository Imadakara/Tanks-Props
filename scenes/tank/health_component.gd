extends Node
## HealthComponent — многоударное разрушение (изначально было one-hit-kill для танков,
## ТЗ §7; теперь настраивается через max_hits — переиспользуется и для DestructibleObjective
## режима "Destroy Target"). Танки читают max_hits из JSON-конфига игрока/бота
## (config/*_tank_config.json, сейчас 2 у обоих), DestructibleObjective — из
## GameConfig.objective_hits_required (оба выставляются извне, см. team_spawner.gd/match_manager.gd).
##
## [ИСПРАВЛЕНО, по прямому запросу — "танки уничтожались с двух попаданий и краснели при первом,
## это надо вернуть и сделать валидным правилом на всех картах"] Дефолт этого @export поднят с 1 на
## 2 — общее правило танкового урона, действующее ВЕЗДЕ, не только там, где team_spawner.gd успевает
## переопределить его из JSON. Продакшен-карта (Main.tscn через team_spawner.gd) уже читала max_hits=2
## из конфига — правка её не трогает (то же самое число, просто переприсваивается заново, без
## эффекта). Тестовые арены (BotArena.tscn/KillerArena.tscn) — танки там СТАТИЧНЫЕ инстансы Tank.tscn
## в .tscn-файле, НИКОГДА не проходящие через team_spawner.gd вообще — раньше молча наследовали
## старый дефолт скрипта (1, one-hit-kill), теперь получают тот же дефолт 2, что и продакшен, без
## необходимости хардкодить override на каждой отдельной тестовой сцене. Визуальное покраснение при
## нефинальном попадании уже было реализовано отдельно (см. tank.gd._on_damaged()) — оно просто
## никогда не успевало сработать при max_hits=1 (первый удар СРАЗУ финальный).

## killer добавлен в damaged (не только в destroyed) — нужен на КАЖДОМ попадании, не только
## смертельном, чтобы бот мог развернуться в сторону выстрела (см. tank_ai_controller.gd).
## ВАЖНО: Godot требует у подписчика ровно столько параметров, сколько эмитит сигнал (лишний
## аргумент НЕ отбрасывается молча — рантайм-ошибка) — все существующие подписчики (tank.gd)
## обновлены под новую сигнатуру.
signal damaged(current_hits: int, max_hits: int, killer: Node)
signal destroyed(killer: Node)

@export var max_hits: int = 2
## true только на HealthComponent DestructibleObjective (ставит match_manager.gd) — оборона
## не должна вредить цели (см. «Игровые режимы»/Destroy Target). Определяем атакующего через
## killer.is_attacker() — killer это корень танка-стрелка (см. weapon_controller.gd).
@export var attackers_only: bool = false
## true (дефолт) — владелец удаляется из сцены при уничтожении, как и раньше (DestructibleObjective:
## разрушенная цель должна пропасть с карты). false — на танках (см. Tank.tscn), респаун берёт на
## себя RespawnController: он подписан на destroyed и решает, что делать с телом сам, поэтому
## здесь освобождать узел нельзя (пост-ревью).
@export var free_on_destroy: bool = true
## true — попадания полностью игнорируются (ни damaged, ни destroyed, current_hits не растёт).
## Используется точечно на конкретных инстансах (см. scenes/bot_arena/bot_arena.gd — игрок
## неубиваем на этой тестовой сцене, чтобы respawn/смерть не мешали обкатывать ИИ бота),
## не общий баланс — поэтому не в GameConfig, а прямое свойство на конкретном танке.
@export var invincible: bool = false
var current_hits: int = 0
var is_alive: bool = true

func take_hit(killer: Node = null) -> void:
	if invincible:
		return
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
