extends Node
## CargoHold — трюм танка: сколько ценности он везёт ПРЯМО СЕЙЧАС и чем за это платит.
##
## Компонент-сиблинг под корнем `Tank.tscn`, как остальные части танка. Хранит не узлы, а «лоты» —
## `{value: int, frozen: bool, rarity: int}`: пока ящик едет, физического узла не существует (см.
## `scenes/loot/loot_crate.gd` — четыре состояния ценности).
##
## ЦЕНА ГРУЗА — два следствия, торчащие наружу двумя методами:
##  - `speed_multiplier()` — каждый ящик замедляет носителя (общее правило всех классов: минус
##    `GameConfig.cargo_speed_penalty_per_lot` = 15% за ящик, аддитивно). Грузовой класс от штрафа
##    освобождён (`speed_penalty_enabled = false`).
##  - `blocks_disguise()` — гружёный танк не может маскироваться. Раньше это было общим правилом
##    режима; теперь это ЧЕРТА СРЕДНЕГО класса (`blocks_disguise_when_loaded`), цена за его
##    универсальность. Остальные классы маскируются и с грузом.
## Читают их `tank_movement.gd` (скорость) и `disguise_controller.gd` / HUD / бот (маскировка) —
## все одно и то же правило, из одной точки.
##
## ВМЕСТИМОСТЬ (`capacity`) — своя у каждого класса, её выставляет `chassis.gd`. Любой ящик — сырой
## с земли или дозревший со склада — это 1 место трюма. Отдельного правила «со склада только один за
## рейс» нет (сырой и созревший лут везутся одинаково). Мгновенную авто-переукладку только что
## взятого со склада ящика гасит `ExtractionManager._deposit_lock` (по `LootCrate.owner_team`).

signal cargo_changed(lots: int, total_value: int)

## Сколько ящиков помещается. Своё у каждого класса — выставляет chassis.gd (у среднего 3).
var capacity: int = 3
## Штрафует ли груз скорость (грузовой класс — нет). Размер штрафа — общий, из GameConfig.
var speed_penalty_enabled: bool = true
## Блокирует ли груз маскировку — черта среднего класса (chassis.gd).
var blocks_disguise_when_loaded: bool = false

## Список лотов: `{"value": int, "frozen": bool, "rarity": int}`. Порядок = порядок подбора.
var _lots: Array[Dictionary] = []
## Сколько секунд ещё нельзя подбирать (см. block_pickup). 0 — можно.
var _pickup_block_left: float = 0.0

func _ready() -> void:
	set_process(false)  # тикаем только пока идёт запрет подбора

func lot_count() -> int:
	return _lots.size()

func is_loaded() -> bool:
	return not _lots.is_empty()

func is_full() -> bool:
	return _lots.size() >= capacity

func total_value() -> int:
	var sum: int = 0
	for lot in _lots:
		sum += int(lot["value"])
	return sum

## Гружёный танк не может маскироваться — но только если это черта его класса (средний).
## Единственная точка, где правило сформулировано; `disguise_controller.gd`, HUD и бот спрашивают
## отсюда.
func blocks_disguise() -> bool:
	return blocks_disguise_when_loaded and is_loaded()

## Множитель скорости: за каждый лот отдельный штраф, поэтому «взять ещё один» — всегда осязаемая
## плата, а не бесплатное действие до потолка трюма. Аддитивно: 15% за ящик → 1 ящик ×0.85,
## 3 ящика ×0.55. Нижняя граница — страховка на случай, если баланс когда-нибудь выкрутят так, что
## штраф съест всю скорость: танк с грузом всё равно должен ехать.
const _MIN_SPEED_MULT := 0.1

func speed_multiplier() -> float:
	if not speed_penalty_enabled:
		return 1.0
	return maxf(1.0 - GameConfig.cargo_speed_penalty_per_lot * float(_lots.size()), _MIN_SPEED_MULT)

## Запретить подбор на `GameConfig.cargo_respawn_pickup_block_sec`. Зовёт `RespawnController` сразу
## после телепорта на точку спавна: танк ПОЯВЛЯЕТСЯ в круге своей базы, а `Area3D` ящика честно шлёт
## `body_entered` и на телепорт — без этого запрета воскресший танк молча всасывал лежащий там лут
## (прежде всего свой же, выпавший при гибели у базы) и следующим кадром выгружал его на склад.
## Игрок видел «умер с лутом — лут выпал — на респавне оказался на базе». Подбор должен быть
## действием: надо ВЪЕХАТЬ в ящик, а не появиться в нём.
func block_pickup() -> void:
	_pickup_block_left = GameConfig.cargo_respawn_pickup_block_sec
	set_process(true)

func _process(delta: float) -> void:
	_pickup_block_left -= delta
	if _pickup_block_left <= 0.0:
		_pickup_block_left = 0.0
		set_process(false)

## Попытка принять ящик. `frozen` — не дозревает дальше (украденное / уже дозревшее). false —
## трюм полон или идёт пост-респавн запрет; ящик остаётся лежать (штатный отказ, не ошибка).
func try_take(value: int, frozen: bool, rarity: int = 0) -> bool:
	if _pickup_block_left > 0.0 or is_full():
		return false
	_lots.append({"value": value, "frozen": frozen, "rarity": rarity})
	cargo_changed.emit(_lots.size(), total_value())
	return true

## Забрать ВСЁ содержимое (выгрузка на склад, банк на точке выхода, россыпь при гибели). Трюм
## пустеет; вызывающий решает, во что превратить лоты.
func take_all() -> Array[Dictionary]:
	var out: Array[Dictionary] = _lots.duplicate()
	_lots.clear()
	cargo_changed.emit(0, 0)
	return out

## Полный сброс без выдачи содержимого — только для респавна (груз уже рассыпан на месте гибели
## обработчиком смерти; здесь просто гарантируем, что воскресший танк пуст).
func clear() -> void:
	if _lots.is_empty():
		return
	_lots.clear()
	cargo_changed.emit(0, 0)
