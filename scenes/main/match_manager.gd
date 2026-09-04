extends Node
## MatchManager — постраундовый цикл, единый для любой карты (обе игровые карты — шаблоны режимов
## TARGET_OBJECTIVE/TEAM_ARENA, см. корневой CLAUDE.md "Game modes"). `map_scene.gd._setup_match_context()`
## заводит этот узел из кода под именем "MatchManager" на КАЖДОЙ карте — HUD находит его и его
## дочерние `RoundTimer`/`FinalStageTimer` одними и теми же `get_node_or_null(...)`-лукапами
## независимо от карты.
##
## Условие конца раунда — по режиму карты (`MatchState.match_mode`, задаётся в настройках сцены):
## - TARGET_OBJECTIVE: `HealthComponent.destroyed` цели → победа АТАКИ; `RoundTimer` истёк, цель
##   цела → победа ЗАЩИТЫ.
## - TEAM_ARENA: `RoundTimer` истёк → победитель по числу убийств (`ScoreManager`), ничья по
##   `GameConfig.defense_wins_ties` (`_winner_by_kills()`).
## Результат раунда пишется в серию `MatchState.record_round_result()` ДО эмита `round_ended`,
## чтобы HUD прочитал уже актуальный счёт. Следующий раунд/новый матч — кнопкой в HUD (reload
## сцены), серия копится через autoload.
##
## Финальная стадия — доп. время после ОСНОВНОГО таймера раунда, если бой зашёл в тупик: время
## вышло И у всех оставшихся в живых танков кончились боеприпасы (продолжать нечем). `GameConfig.
## final_stage_duration_sec` (30с) — грейс-период, в течение которого падают ящики (см.
## ammo_drop_zone.gd — его каденс продолжается, пока раунд не закрыт), танки респавнятся с
## боезапасом, HUD показывает обратный отсчёт (`FinalStageLabel`, `hud.gd._update_final_stage_label()`);
## по истечении раунд решается `_winner_by_kills()`. Триггерится РОВНО в момент истечения
## `RoundTimer` (не раньше, не по накоплению `ammo_depleted` в середине боя) и ТОЛЬКО если карта
## включила финальную стадию (`final_stage_enabled`, @export на map_scene.gd — по умолчанию вкл на
## TeamArenaMap, выкл на TargetObjectiveMap).

signal round_ended(winner: String)  # "attack" | "defense"
signal final_stage_started()

var _final_stage_active: bool = false
var _final_stage_enabled: bool = false  # задаётся картой через setup(); см. map_scene.gd @export
var _round_over: bool = false
var _mode: int = 0  # MatchState.Mode; всегда перезаписывается в setup() до первого использования
var _round_timer: Timer
var _final_stage_timer: Timer
var _score_manager: Node

## «Баскетбольное» правило для TARGET_OBJECTIVE: основное время вышло, objective цел, но в
## воздухе ещё есть снаряды — ждём их приземления, и только потом засчитываем защите победу.
## Если долетевший последним снаряд взорвёт objective уже ПОСЛЕ сигнала таймера — это победа
## атаки (_on_objective_destroyed → _end_round("attack")).
##
## Потолок ожидания (`_SETTLE_MAX_SEC`) — ТОЛЬКО страховка от снаряда, который завис в геометрии и
## не самоуничтожился. Обязан быть ВЫШЕ Projectile.max_lifetime_sec (8с) — иначе навесной выстрел
## мортиры с крутой дугой (несколько секунд в полёте) обрубается на потолке, раунд отдаётся защите,
## а долетевший следом снаряд сносит objective уже при _round_over == true → _on_objective_destroyed
## отбивается гейтом, победа атаки теряется. Любой штатный снаряд покидает группу "projectiles" за
## ≤ max_lifetime_sec (попал или самоуничтожился), так что до потолка доходит лишь реально
## застрявший.
var _settling_last_shots: bool = false
var _settle_time: float = 0.0
const _SETTLE_MAX_SEC := 10.0  # > Projectile.max_lifetime_sec (8.0), см. коммент выше

## Вызывается из map_scene.gd._setup_match_context() сразу после add_child() — не _ready(): явным
## вызовом из оркестратора в корне сцены, тот же порядок, что и у ScoreManager.begin_match().
## objective_health = null для режима TEAM_ARENA (цели на карте нет).
func setup(mode: int, round_sec: float, score_manager: Node, objective_health: Node, final_stage_enabled: bool) -> void:
	_mode = mode
	_score_manager = score_manager
	_final_stage_enabled = final_stage_enabled

	_round_timer = Timer.new()
	_round_timer.name = "RoundTimer"
	_round_timer.one_shot = true
	_round_timer.wait_time = round_sec
	add_child(_round_timer)
	_round_timer.timeout.connect(_on_round_timeout)
	_round_timer.start()

	if objective_health != null:
		objective_health.max_hits = GameConfig.objective_hits_required
	if _mode == MatchState.Mode.TARGET_OBJECTIVE and objective_health != null:
		objective_health.destroyed.connect(_on_objective_destroyed)

	set_process(false)  # _process нужен только на фазе «ждём приземления снарядов», см. ниже

func _on_objective_destroyed(_killer: Node) -> void:
	_end_round("attack")  # цель уничтожена — победа атакующих (в т.ч. снарядом, долетевшим уже после таймера)

func _on_round_timeout() -> void:
	if _final_stage_active or _round_over:
		return  # финальная стадия / раунд уже закрыт — обычный таймаут не решает
	# Основное время вышло. Финальная стадия — только если карта её включила И бой зашёл в тупик
	# (все живые танки без боеприпасов). Иначе раунд решается сразу по обычному условию режима.
	if _final_stage_enabled and _alive_tanks_all_out_of_ammo():
		_start_final_stage()
		return
	if _mode == MatchState.Mode.TEAM_ARENA:
		_end_round(_winner_by_kills())
		return
	# TARGET_OBJECTIVE — «баскетбол»: пока в воздухе есть снаряды, ждём их приземления и только
	# потом засчитываем защите победу. Долетевший последним снаряд, взорвавший objective уже
	# после сигнала таймера, разрешит раунд победой атаки (_on_objective_destroyed).
	_settling_last_shots = true
	_settle_time = 0.0
	set_process(true)
	_try_resolve_after_settle()  # снарядов в полёте нет — решаем сразу, без ожидания кадра

func _process(delta: float) -> void:
	if not _settling_last_shots:
		return
	_settle_time += delta
	_try_resolve_after_settle()

## Завершить фазу ожидания и засчитать защите победу, когда все снаряды приземлились ЛИБО вышел
## потолок ожидания. Если objective за это время уже взорвался — _round_over выставлен
## _on_objective_destroyed'ом, просто останавливаемся.
func _try_resolve_after_settle() -> void:
	if _round_over:
		_settling_last_shots = false
		set_process(false)
		return
	if _projectiles_in_flight() == 0 or _settle_time >= _SETTLE_MAX_SEC:
		_settling_last_shots = false
		set_process(false)
		_end_round("defense")  # objective уцелел после падения всех снарядов

func _projectiles_in_flight() -> int:
	return get_tree().get_nodes_in_group("projectiles").size()

## Все ЖИВЫЕ (не на респавне) танки без боезапаса — и хотя бы один живой танк есть. Проверяется
## РОВНО в момент истечения основного таймера раунда (см. _on_round_timeout).
func _alive_tanks_all_out_of_ammo() -> bool:
	var any_alive := false
	for tank in get_tree().get_nodes_in_group("tanks"):
		var health: Node = tank.get_node_or_null("HealthComponent")
		if health == null or not health.is_alive:
			continue  # труп на респавне — не «оставшийся в живых»
		any_alive = true
		var ammo: Node = tank.get_node_or_null("AmmoComponent")
		if ammo != null and ammo.has_ammo():
			return false
	return any_alive

func _start_final_stage() -> void:
	_final_stage_active = true
	_round_timer.stop()  # уже истёк (one_shot) — вызов безвреден, оставлен для ясности
	_final_stage_timer = Timer.new()
	_final_stage_timer.name = "FinalStageTimer"
	_final_stage_timer.one_shot = true
	_final_stage_timer.wait_time = GameConfig.final_stage_duration_sec
	add_child(_final_stage_timer)
	_final_stage_timer.timeout.connect(_on_final_stage_timeout)
	final_stage_started.emit()
	_final_stage_timer.start()

func _on_final_stage_timeout() -> void:
	_end_round(_winner_by_kills())

## Общая формула для обоих режимов: обычный таймаут TEAM_ARENA и финальная стадия любого режима
## решают раунд одинаково — по числу убийств, ничья по GameConfig.defense_wins_ties.
func _winner_by_kills() -> String:
	var atk: int = _score_manager.attack_kills
	var def: int = _score_manager.defense_kills
	if atk > def:
		return "attack"
	if def > atk:
		return "defense"
	return "defense" if GameConfig.defense_wins_ties else "attack"

func _end_round(winner: String) -> void:
	if _round_over:
		return
	_round_over = true
	_round_timer.stop()
	if _final_stage_timer != null:
		_final_stage_timer.stop()
	MatchState.record_round_result(winner)  # засчитываем раунд в серию ДО того, как HUD её прочитает
	round_ended.emit(winner)
