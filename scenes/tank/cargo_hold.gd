extends Node
## CargoHold — трюм танка: сколько ценности он везёт ПРЯМО СЕЙЧАС и чем за это платит.
##
## Компонент-сиблинг под корнем `Tank.tscn`, как остальные части танка. Хранит не узлы, а «лоты» —
## `{value: int, frozen: bool}`: пока ящик едет, физического узла не существует (см.
## `scenes/loot/loot_crate.gd` — четыре состояния ценности).
##
## ЦЕНТРАЛЬНАЯ СВЯЗКА КОНЦЕПЦИИ (§5): гружёный танк **не может маскироваться** и едет медленнее.
## Не «маскируется хуже» — не может вовсе. Из-за этого каждый подобранный ящик — сознательный отказ
## от главного защитного инструмента, а не просто «+1 к счёту». Оба следствия торчат наружу двумя
## методами (`blocks_disguise()`, `speed_multiplier()`), которые читают `disguise_controller.gd` и
## `tank_movement.gd`; здесь нет ни одного числа — весь баланс в `GameConfig`.
##
## ПРАВИЛО «ГЛАВНЫЙ ЗАМОК» (§4). Свободную добычу с земли можно набирать до вместимости трюма, а вот
## ящик СО СКЛАДА (своего или чужого — грабёж это тот же физический акт) берётся только в ПУСТОЙ
## трюм и блокирует добор до конца рейса. Без этого можно было бы накопить всё и вывезти разом, и
## весь цикл выродился бы в один финальный рейс. Правило живёт ЗДЕСЬ, в одной точке, а не в местах
## подбора: подбирающему коду (`loot_crate.gd`) достаточно спросить `try_take()`.

signal cargo_changed(lots: int, total_value: int)

## Список лотов: `{"value": int, "frozen": bool}`. Порядок = порядок подбора.
var _lots: Array[Dictionary] = []
## true — в трюме ящик, взятый со склада: добор запрещён до выгрузки/сдачи/гибели.
var _withdrawn: bool = false

func lot_count() -> int:
	return _lots.size()

func is_loaded() -> bool:
	return not _lots.is_empty()

func is_full() -> bool:
	return _lots.size() >= GameConfig.cargo_capacity

## Взят ли в трюм ящик со склада (см. правило «главный замок» в шапке).
func has_withdrawn() -> bool:
	return _withdrawn

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

## Попытка принять ящик. `frozen` — не дозревает дальше (украденное/уже дозревшее);
## `from_warehouse` — ящик взят с ЧЬЕГО-ЛИБО склада, значит действует правило «только один и только
## в пустой трюм». false — подбор не состоялся, ящик остаётся лежать (это не ошибка, а штатный отказ).
func try_take(value: int, frozen: bool, from_warehouse: bool) -> bool:
	if from_warehouse:
		if not _lots.is_empty():
			return false
	elif is_full() or _withdrawn:
		return false
	_lots.append({"value": value, "frozen": frozen})
	if from_warehouse:
		_withdrawn = true
	cargo_changed.emit(_lots.size(), total_value())
	return true

## Забрать ВСЁ содержимое (выгрузка на склад, банк на точке выхода, россыпь при гибели). Трюм
## пустеет; вызывающий решает, во что превратить лоты.
func take_all() -> Array[Dictionary]:
	var out: Array[Dictionary] = _lots.duplicate()
	_lots.clear()
	_withdrawn = false
	cargo_changed.emit(0, 0)
	return out

## Полный сброс без выдачи содержимого — только для респавна (груз уже рассыпан на месте гибели
## обработчиком смерти; здесь просто гарантируем, что воскресший танк пуст).
func clear() -> void:
	if _lots.is_empty() and not _withdrawn:
		return
	_lots.clear()
	_withdrawn = false
	cargo_changed.emit(0, 0)
