extends Node
## CargoHold — трюм танка: сколько ценности он везёт ПРЯМО СЕЙЧАС и чем за это платит.
##
## Компонент-сиблинг под корнем `Tank.tscn`, как остальные части танка. Хранит не узлы, а «лоты» —
## `{value: int, frozen: bool, rarity: int}`: пока ящик едет, физического узла не существует (см.
## `scenes/loot/loot_crate.gd` — четыре состояния ценности).
##
## ЦЕНТРАЛЬНАЯ СВЯЗКА КОНЦЕПЦИИ (§5): гружёный танк **не может маскироваться** и едет медленнее.
## Не «маскируется хуже» — не может вовсе. Из-за этого каждый подобранный ящик — сознательный отказ
## от главного защитного инструмента, а не просто «+1 к счёту». Оба следствия торчат наружу двумя
## методами (`blocks_disguise()`, `speed_multiplier()`), которые читают `disguise_controller.gd` и
## `tank_movement.gd`; здесь нет ни одного числа — весь баланс в `GameConfig`.
##
## ВМЕСТИМОСТЬ. Любой ящик — сырой с земли или дозревший со склада — это 1 место трюма, набирать
## можно до `GameConfig.cargo_capacity` (3). Отдельного правила «со склада только один за рейс» нет
## (снято по решению дизайнера — сырой и созревший лут должны везтись одинаково). Мгновенную
## авто-переукладку только что взятого со склада ящика гасит `ExtractionManager._deposit_lock`
## (отдельный механизм, по `LootCrate.owner_team`).

signal cargo_changed(lots: int, total_value: int)

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
	return _lots.size() >= GameConfig.cargo_capacity

func total_value() -> int:
	var sum: int = 0
	for lot in _lots:
		sum += int(lot["value"])
	return sum

## Гружёный танк не может маскироваться — концепт §5. Единственная точка, где это правило
## сформулировано; `disguise_controller.gd` спрашивает отсюда.
func blocks_disguise() -> bool:
	return is_loaded()

## Множитель скорости: за каждый лот отдельный штраф, поэтому «взять ещё один» — всегда осязаемая
## плата, а не бесплатное действие до потолка трюма.
func speed_multiplier() -> float:
	return pow(GameConfig.cargo_speed_penalty_per_lot, float(_lots.size()))

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
