extends Node
## Autoload: GameConfig — единая точка настройки баланса MVP (ТЗ 11.4).
## Значения по умолчанию соответствуют ТЗ; часть параметров (objective_hits_required,
## defense_wins_ties, ai_can_see_disguised_tanks) — решения по открытым вопросам ТЗ §14,
## подлежат пересмотру на плейтесте.

@export var disguise_duration_sec: float = 30.0
@export var disguise_cooldown_sec: float = 10.0

## Маскировка имитирует объект-препятствие карты (ТЗ §6; см. Tank_Prop_Hunt_Disguise.md). Выбор
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
## [ИЗМЕНЕНО, по прямому запросу — "сделай 3 сек кулдаун на выстрел по умолчанию всем включая
## игрока"] Было 10.0. `bot_arena.gd` отдельно переопределяет на 1.0 ТОЛЬКО на тестовых аренах
## (ускоренная перезарядка для обкатки ИИ) — этот точечный оверрайд не трогаем, запрос был про
## дефолт, действующий везде, где он не переопределён явно (продакшен + игрок).
@export var reload_duration_sec: float = 3.0
@export var ammo_per_tank: int = 10
@export var team_size: int = 2  # временно 2 для тестов 2×2 (1 бот игроку в помощь, 2 бота противнику) — вернуть на 5 для полного MVP-состава
@export var final_stage_duration_sec: float = 30.0
@export var ammo_crate_count: int = 2  # дефолт потолка одновременно НЕподобранных ящиков НА ОДНУ зону сброса (AmmoDropZone), если её max_pending_crates не задан
@export var ammo_crate_spawn_interval_sec: float = 30.0  # дефолт интервала сброса зоны (AmmoDropZone.drop_interval_sec), если не переопределён на инстансе
@export var ammo_per_crate: int = 3  # дефолт содержимого ящика, если зона сброса не задаёт своё ammo_per_crate
@export var round_timer_sec: float = 150.0  # режим TARGET_OBJECTIVE (Destroy Target) — 2:30 на раунд
@export var team_arena_round_sec: float = 180.0  # режим TEAM_ARENA — командный бой, 3 мин на раунд
@export var objective_hits_required: int = 10  # режим "Destroy Target" — попаданий по DestructibleObjective для победы атаки
@export var respawn_cooldown_sec: float = 10.0  # уничтоженный танк возвращается в игру через столько сек (пост-ревью, см. respawn_controller.gd)
@export var defense_wins_ties: bool = true
## Читается TankAIController._can_see() (disguise_controller.gd — реализация самой маскировки). false
## (дефолт) — бот НЕ видит замаскированного противника, даже если тот в конусе обзора/обстрела, пока
## маскировка не спадёт. true — «читерский» режим для отладки/калибровки, гейт маскировки отключён
## целиком. Открытый вопрос ТЗ §14, подлежит пересмотру на плейтесте.
@export var ai_can_see_disguised_tanks: bool = false
