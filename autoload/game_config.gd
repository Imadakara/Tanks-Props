extends Node
## Autoload: GameConfig — единая точка настройки баланса MVP (ТЗ 11.4).
## Значения по умолчанию соответствуют ТЗ; часть параметров (objective_hold_time_sec,
## defense_wins_ties, ai_can_see_disguised_tanks) — решения по открытым вопросам ТЗ §14,
## подлежат пересмотру на плейтесте.

@export var disguise_duration_sec: float = 30.0
@export var disguise_cooldown_sec: float = 10.0
@export var reload_duration_sec: float = 10.0
@export var ammo_per_tank: int = 10
@export var team_size: int = 2  # временно 2 для тестов 2×2 (1 бот игроку в помощь, 2 бота противнику) — вернуть на 5 для полного MVP-состава
@export var final_stage_duration_sec: float = 30.0
@export var ammo_crate_count: int = 2
@export var ammo_per_crate: int = 3
@export var round_timer_sec: float = 240.0
@export var objective_hold_time_sec: float = 10.0
@export var defense_wins_ties: bool = true
@export var ai_can_see_disguised_tanks: bool = false
