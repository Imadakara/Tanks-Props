extends RefCounted
## ObjectiveAlertState — общая логика централизованного ALERT-таймера/гео-проверки для
## State.ALERT у TankAIController (таймер "секунд с последнего попадания по objective" +
## факт "враг физически внутри ObjectiveAlertZone прямо сейчас"), вынесена из bot_arena.gd в
## переиспользуемый класс.
##
## [ДОБАВЛЕНО, по прямому запросу — "боты это универсальная система для любой карты, если есть
## недоработка в этом ключе — пофиксить"] TankAIController теперь ЕДИНСТВЕННЫЙ ИИ проекта,
## используется и на Main.tscn (team_spawner.gd) — а централизованный ALERT-таймер раньше жил
## ТОЛЬКО в bot_arena.gd (методы time_since_objective_hit()/enemy_in_alert_zone(), которые
## TankAIController зовёт на закэшированном _arena = get_tree().current_scene). На продакшене
## корень сцены — main.gd, у которого этих методов не было вообще: живьём поймано
## "Nonexistent function 'time_since_objective_hit' in base main.gd" на первом же прогоне.
## Не дублировать одну и ту же логику в main.gd и bot_arena.gd по отдельности (два места чинить
## один и тот же баг в будущем) — общий класс, оба владеют СВОИМ экземпляром, тикают/сбрасывают
## его в нужные для себя моменты, наружу отдают ОДИНАКОВЫЕ публичные имена методов
## (time_since_objective_hit()/enemy_in_alert_zone() на самих main.gd/bot_arena.gd, просто
## форвардящие сюда) — TankAIController вызывает их одинаково независимо от карты, ничего не
## знает про этот класс напрямую.

var _time_since_hit: float = INF

## Владелец вызывает из своего _physics_process(delta).
func tick(delta: float) -> void:
	_time_since_hit += delta

## Владелец вызывает из своего обработчика HealthComponent.damaged на objective.
func reset() -> void:
	_time_since_hit = 0.0

func time_since_hit() -> float:
	return _time_since_hit

## alert_zone — узел ObjectiveAlertZone (spawn_zone.gd — есть .radius/global_position, тот же
## переиспользуемый префаб, что и на SpawnZone). tree — SceneTree владельца (этот класс не Node,
## своего get_tree() нет). "Противник" — любой танк is_attacker()==true, tank.visible-фильтр —
## тот же паттерн, что уже применён в _can_see()/tank_ai_controller.gd — труп, ждущий
## respawn (visible=false), не считается "противником в круге".
func enemy_in_zone(alert_zone: Node3D, tree: SceneTree) -> bool:
	if alert_zone == null or not is_instance_valid(alert_zone):
		return false
	var radius: float = float(alert_zone.get("radius"))
	var zone_pos: Vector3 = alert_zone.global_position
	for tank in tree.get_nodes_in_group("tanks"):
		if not is_instance_valid(tank) or not tank.is_attacker() or not tank.visible:
			continue
		var dist: float = Vector2(tank.global_position.x - zone_pos.x, tank.global_position.z - zone_pos.z).length()
		if dist <= radius:
			return true
	return false
