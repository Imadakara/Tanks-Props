extends Resource
## Modification — данные одной подбираемой модификации танка (см. Tank_Prop_Hunt_Modifications.md).
## Одноразовая вставка в единственный слот танка (ModificationController): подобрать можно только
## в пустой слот, сбросить/удалить нельзя — только использовать или погибнуть вместе с танком.
##
## БЕЗ class_name намеренно — headless `run_project` не подхватывает свежий class_name без
## пересканирования редактором (общая грабля проекта, см. CLAUDE.md). Ссылки на конкретные
## модификации — через preload("res://scenes/modifications/<name>.tres"); .tres хранит указатель
## на этот скрипт как [ext_resource type="Script" path=...], что работает и headless.
##
## Поля — только идентичность/отображение. Числовой баланс мортиры (дальность, урон, каденс
## спавна) живёт в GameConfig (mortar_range / mortar_objective_damage / mortar_drop_interval_sec),
## как и остальной баланс проекта.

@export var id: StringName = &""
@export var display_name: String = ""
## Короткая подпись для строки HUD «Модификация: <hud_short>».
@export var hud_short: String = ""
