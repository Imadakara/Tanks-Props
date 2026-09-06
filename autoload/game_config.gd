extends Node
## Autoload: GameConfig — единая точка настройки баланса MVP (ТЗ 11.4).
## Значения по умолчанию соответствуют ТЗ; часть параметров (objective_hits_required,
## defense_wins_ties, ai_can_see_disguised_tanks) — решения по открытым вопросам баланса,
## подлежат пересмотру на плейтесте.

@export var disguise_duration_sec: float = 30.0
@export var disguise_cooldown_sec: float = 10.0

## Маскировка имитирует объект-препятствие карты (см. Tank_Prop_Hunt_Disguise.md). Выбор
## конкретного объекта позже уедет в мета-гейм — для MVP параметры объекта имитации фиксированы
## здесь, а не задаются узлом на карте. Дефолт = коричневая коробка `Obstacle*`
## (scenes/maps/TargetObjectiveMap.tscn): размер и цвет совпадают с её BoxMesh/StandardMaterial3D.
@export var disguise_prop_size: Vector3 = Vector3(2.0, 1.25, 2.0)
@export var disguise_prop_color: Color = Color(0.6, 0.35, 0.15)
## Правило сброса «объект имитации меньше танка хотя бы по одной оси»: маскировка спадает, когда
## вражеский танк подходит к коллайдеру замаскированного танка ближе этого расстояния. Дефолт
## приравнен к TankAIController.emergency_brake_range (1.8) — дистанции, на которой бот реагирует
## на препятствие. Для дефолтного объекта имитации (больше танка по всем осям) это правило спит,
## работает правило «враг въехал в объём объекта имитации» (см. disguise_controller.gd).
@export var disguise_enemy_proximity_break_dist: float = 1.8
## Маскировка ИГРОКА доступна на любой карте по умолчанию (ботам — отдельно, через
## TankAIController.disguise_bot_enabled в ростере карты). false — глобально отнять у игрока
## клавишу M.
@export var disguise_player_enabled: bool = true
## В debug-режиме (MatchState.debug_enabled) объект имитации маскировки красится ЭТИМ цветом
## вместо disguise_prop_color — чтобы на глаз отличать замаскированный танк от статичного
## Obstacle на карте. В релизе (debug off) не применяется.
@export var disguise_debug_prop_color: Color = Color(0.65, 0.1, 0.9)
## Цвет мешей танка (корпус + башня + ствол) по его команде — единственная точка настройки
## «подкраски танков цветом команды». Применяет tank.gd (apply_team_visuals()), вызывается
## сразу после присвоения tank.team (team_spawner.gd) и на респавне. ATTACK (team 0) = Красные,
## DEFENSE (team 1) = Синие — те же названия, что в HUD режима TEAM_ARENA.
@export var team_attack_color: Color = Color(0.75, 0.2, 0.15)
@export var team_defense_color: Color = Color(0.2, 0.4, 0.8)

## Кулдаун на выстрел — общий дефолт для всех танков (игрок + боты). Каждый выстрел уводит
## TankStateMachine в RELOAD на это время.
@export var reload_duration_sec: float = 3.0
@export var ammo_per_tank: int = 10
@export var team_size: int = 2  # дефолт размера отряда, если squad в ростере не задал count (оба текущих ростера задают count явно — это лишь запас)
@export var final_stage_duration_sec: float = 30.0
@export var ammo_crate_count: int = 2  # дефолт потолка одновременно НЕподобранных ящиков НА ОДНУ зону сброса (AmmoDropZone), если её max_pending_crates не задан
@export var ammo_crate_spawn_interval_sec: float = 30.0  # дефолт интервала сброса зоны (AmmoDropZone.drop_interval_sec), если не переопределён на инстансе
@export var ammo_per_crate: int = 3  # дефолт содержимого ящика, если зона сброса не задаёт своё ammo_per_crate
@export var round_timer_sec: float = 180.0  # режим TARGET_OBJECTIVE (Destroy Target) — 3 мин на раунд
@export var team_arena_round_sec: float = 180.0  # режим TEAM_ARENA — командный бой, 3 мин на раунд
## ПОЛНОЕ ЗДОРОВЬЕ objective-цели (HP-модель, см. Tank_Prop_Hunt_Modifications.md): обычный снаряд
## снимает 1 (Projectile.damage), спец-выстрел мортиры — mortar_objective_damage (20).
## HealthComponent.current_hits для цели трактуется как HP. match_manager.gd проставляет это в
## objective_health.max_hits при setup().
@export var objective_hits_required: int = 100  # режим "Destroy Target" — HP объекта-цели для победы атаки

## Модификации танка (подбираемые красные ящики, слот в HUD; см. Tank_Prop_Hunt_Modifications.md).
## Первая модификация — «мортира»: одноразовая насадка на дуло, навесной спец-выстрел.
@export var mortar_range: float = 9.0  # макс. вынос кружка-прицела и дальность навесного выстрела (половина базового vision_range бота)
@export var mortar_launch_speed: float = 12.0  # начальная скорость навесного снаряда мортиры — заметно ниже обычной (~30), чтобы mortar_range был близок к пределу дальности и дуга реально менялась ближе/дальше
@export var mortar_objective_damage: int = 20  # урон навесного выстрела мортиры (по objective — из 100 HP; по танку 20 >= max_hits(3) → one-shot)
@export var mortar_drop_interval_sec: float = 30.0  # раз в столько секунд боя красный ящик падает ОДНОВРЕМЕННО в каждой зоне сброса (только режим TARGET_OBJECTIVE)
@export var mortar_fresh_window_sec: float = 10.0  # сколько секунд ПОСЛЕ сброса атакующий бот считает мортиру «свежей» и едет за ней (иначе продолжает атаковать objective)
@export var mortar_prep_sec: float = 1.5  # «фаза подготовки» бота перед навесным выстрелом: сколько держать сведённый прицел до залпа
@export var respawn_cooldown_sec: float = 10.0  # уничтоженный танк возвращается в игру через столько сек (пост-ревью, см. respawn_controller.gd)
@export var defense_wins_ties: bool = true
## Читается TankAIController._can_see() (disguise_controller.gd — реализация самой маскировки). false
## (дефолт) — бот НЕ видит замаскированного противника, даже если тот в конусе обзора/обстрела, пока
## маскировка не спадёт. true — «читерский» режим для отладки/калибровки, гейт маскировки отключён
## целиком. Открытый вопрос баланса, подлежит пересмотру на плейтесте.
@export var ai_can_see_disguised_tanks: bool = false
