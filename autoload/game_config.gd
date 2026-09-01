extends Node
## Autoload: GameConfig — единая точка настройки баланса MVP (ТЗ 11.4).
## Значения по умолчанию соответствуют ТЗ; часть параметров (objective_hits_required,
## defense_wins_ties, ai_can_see_disguised_tanks) — решения по открытым вопросам ТЗ §14,
## подлежат пересмотру на плейтесте.

@export var disguise_duration_sec: float = 30.0
@export var disguise_cooldown_sec: float = 10.0
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
@export var ai_can_see_disguised_tanks: bool = false
