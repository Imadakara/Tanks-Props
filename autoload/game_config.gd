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
## --- Режим EXTRACTION: цикл добычи и вывоза -----------------------------------------------
## Полное описание цикла — Tank_Prop_Hunt_Extraction_Loop_Concept.md, техрешения —
## Tank_Prop_Hunt_Extraction_Loop_TZ.md. Здесь ВЕСЬ числовой баланс режима: в коде правил
## (extraction_manager.gd, cargo_hold.gd, loot_crate.gd) не должно быть ни одного числа.
@export var extraction_round_sec: float = 300.0  # единственный раунд, 5 минут
## Насколько танк может отличаться по высоте от центра зоны (склад, точка выхода), чтобы попадание
## в круг засчиталось. На многоуровневой карте под базой проходит пол — без этого выгрузка
## срабатывала бы этажом ниже склада.
@export var extraction_zone_height_tolerance: float = 4.0

## Добыча. Куб-укрытие держит столько попаданий, прежде чем развалиться — фарм обязан ощутимо
## стоить боеприпасов (концепт §6: «хорошо пофармил» = «встречу врага полупустым»).
@export var loot_node_hits: int = 2
## Сколько кубов карты содержат лут. Раздаётся детерминированно по MatchState.loot_seed среди ВСЕХ
## кубов группы "obstacles" — визуально лутовый куб неотличим от пустого и от замаскированного танка.
@export var loot_node_count: int = 10
## Базовая ценность одного ящика (сырой, только что выбитый).
@export var loot_base_value: int = 100

## Склад. Припаркованный на своей базе ящик дорожает от ×1 до этого потолка за loot_ripen_sec.
## Потолок обязателен (концепт §4): без него нет причины вывозить раньше последнего окна.
@export var loot_ripe_multiplier: float = 2.0
## За сколько секунд на складе ящик дозревает до потолка. Должно быть НЕ МЕНЬШЕ интервала окон,
## иначе рост ценности превращается в декорацию (концепт §13, критерий 3).
@export var loot_ripen_sec: float = 90.0

## Трюм. Вместимость — сколько СВОБОДНЫХ ящиков танк увозит за раз. Ящик со склада всегда ровно
## один и только в пустой трюм («главный замок», концепт §4) — это правило в cargo_hold.gd, не число.
@export var cargo_capacity: int = 3
## Штраф к скорости за КАЖДЫЙ ящик в трюме (мультипликативно). 0.85 при трёх ящиках даёт ×0.61.
@export var cargo_speed_penalty_per_lot: float = 0.85

## Окна эвакуации. Расписание известно заранее, точка — нет (концепт §8).
@export var extraction_first_window_sec: float = 75.0   # когда открывается первое окно от старта раунда
@export var extraction_window_interval_sec: float = 75.0  # период между открытиями
@export var extraction_window_duration_sec: float = 35.0  # длительность окна
@export var extraction_announce_lead_sec: float = 12.0    # за сколько до открытия объявляется точка
## Последнее окно обязано ЗАКРЫТЬСЯ не позже, чем за столько до конца раунда — иначе матч сводится
## к финальной свалке (концепт §8).
@export var extraction_last_window_margin_sec: float = 40.0

## Каденс красного ящика мортиры в режиме EXTRACTION — РЕЖЕ, чем в TARGET_OBJECTIVE (30 с):
## мортира там эпизодическое усиление, а не постоянная опция.
@export var mortar_drop_interval_extraction_sec: float = 75.0

## Урон от падения с высоты (нужен только на многоуровневых картах; на плоских танк с такой высоты
## не падает вовсе). Порог — падение НИЖЕ fall_damage_min_height безвредно, чтобы прыжки на стыках
## пандусов не наносили урона. Значения в юнитах мира; на кухонной карте 24 юнита = 1 метр, то есть
## 8 ≈ высота стула, 16 ≈ высота стола, 28 ≈ высота полки.
@export var fall_damage_min_height: float = 8.0   # ниже — 0 HP
@export var fall_damage_2hp_height: float = 16.0  # от этого — 2 HP
@export var fall_damage_3hp_height: float = 28.0  # от этого — 3 HP (для танка с max_hits 3 — смерть)

@export var respawn_cooldown_sec: float = 10.0  # уничтоженный танк возвращается в игру через столько сек (пост-ревью, см. respawn_controller.gd)
@export var defense_wins_ties: bool = true
## Читается TankAIController._can_see() (disguise_controller.gd — реализация самой маскировки). false
## (дефолт) — бот НЕ видит замаскированного противника, даже если тот в конусе обзора/обстрела, пока
## маскировка не спадёт. true — «читерский» режим для отладки/калибровки, гейт маскировки отключён
## целиком. Открытый вопрос баланса, подлежит пересмотру на плейтесте.
@export var ai_can_see_disguised_tanks: bool = false
