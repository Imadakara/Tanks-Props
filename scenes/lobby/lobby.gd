extends Control
## Lobby — выбор игрового класса танка перед боем. Стоит МЕЖДУ меню выбора режима и картой:
## main_menu.gd кладёт выбранную карту в MatchState.pending_map_path и открывает эту сцену, отсюда
## кнопка «В бой» ведёт на карту. В самом бою класс не меняется — выбор фиксируется здесь в
## MatchState.player_chassis, а карта подменяет свой PlayerTank танком этого класса
## (chassis_catalog.gd, swap_player_tank) при каждой загрузке, включая рестарт раунда.
##
## Интерфейс собирается кодом (как отладочные кнопки map_scene.gd и галочка динамических
## препятствий в меню) — сцена Lobby.tscn содержит только корень. Характеристики карточек не
## дублируются здесь числами: они читаются из самих сцен-префабов классов (узел Chassis), так что
## правка префаба сразу видна в лобби.
##
## Клавиши: 1-4 — выбрать класс, Enter — в бой, Esc — назад в меню.

const ChassisCatalog := preload("res://scenes/tank/chassis_catalog.gd")
const _MAIN_MENU_SCENE := "res://scenes/main_menu/MainMenu.tscn"

## Скорость среднего — точка отсчёта для «+30% / −30%» на карточках.
const _BASE_SPEED := 6.0

const _COLOR_BG := Color(0.08, 0.09, 0.11)
const _COLOR_CARD := Color(0.14, 0.15, 0.18)
const _COLOR_CARD_SELECTED := Color(0.18, 0.22, 0.30)
const _COLOR_BORDER := Color(0.28, 0.30, 0.34)
const _COLOR_BORDER_SELECTED := Color(0.95, 0.75, 0.25)
const _COLOR_TRAIT := Color(0.95, 0.80, 0.40)

var _selected: StringName = ChassisCatalog.DEFAULT_ID
var _cards: Dictionary = {}  # id -> PanelContainer
var _profiles: Dictionary = {}  # id -> Dictionary (chassis.gd, profile())

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_selected = MatchState.player_chassis if ChassisCatalog.is_known(MatchState.player_chassis) \
		else ChassisCatalog.DEFAULT_ID
	for id in ChassisCatalog.ORDER:
		_profiles[id] = ChassisCatalog.read_profile(id)
	_build_ui()
	_refresh_selection()

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key: Key = (event as InputEventKey).keycode
	if key >= KEY_1 and key <= KEY_4:
		var i: int = key - KEY_1
		if i < ChassisCatalog.ORDER.size():
			_select(ChassisCatalog.ORDER[i])
	elif key == KEY_ENTER or key == KEY_KP_ENTER:
		_start_battle()
	elif key == KEY_ESCAPE:
		_back_to_menu()

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = _COLOR_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 40
	root.offset_right = -40
	root.offset_top = 30
	root.offset_bottom = -30
	root.add_theme_constant_override("separation", 22)
	add_child(root)

	var title := Label.new()
	title.text = "ВЫБОР ТАНКА"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 40)
	root.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "%s   ·   класс фиксируется на весь матч" % _map_title()
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.modulate = Color(0.75, 0.78, 0.82)
	root.add_child(subtitle)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 18)
	root.add_child(row)
	for i in ChassisCatalog.ORDER.size():
		var id: StringName = ChassisCatalog.ORDER[i]
		var card := _build_card(id, i + 1)
		_cards[id] = card
		row.add_child(card)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 24)
	root.add_child(buttons)

	var back := Button.new()
	back.name = "BackButton"
	back.text = "Назад  (Esc)"
	back.custom_minimum_size = Vector2(220, 52)
	back.pressed.connect(_back_to_menu)
	buttons.add_child(back)

	var go := Button.new()
	go.name = "StartButton"
	go.text = "В бой  (Enter)"
	go.custom_minimum_size = Vector2(260, 52)
	go.add_theme_font_size_override("font_size", 20)
	go.pressed.connect(_start_battle)
	buttons.add_child(go)

func _build_card(id: StringName, hotkey: int) -> PanelContainer:
	var p: Dictionary = _profiles.get(id, {})
	var card := PanelContainer.new()
	card.name = "Card_%s" % id
	# Резиновая ширина: четыре карточки делят экран поровну, текст переносится. Фиксированная
	# ширина по самой длинной строке выталкивала последнюю карточку за край окна.
	card.custom_minimum_size = Vector2(180, 360)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.gui_input.connect(_on_card_input.bind(id))

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(box)

	var name_label := Label.new()
	name_label.text = "%d.  %s" % [hotkey, String(p.get("name", id))]
	name_label.add_theme_font_size_override("font_size", 26)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(name_label)

	var stats := Label.new()
	stats.text = _stats_text(p)
	stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(stats)

	var trait_label := Label.new()
	trait_label.text = "Особенность:\n%s" % String(p.get("trait", ""))
	trait_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	trait_label.modulate = _COLOR_TRAIT
	trait_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(trait_label)

	var pick := Button.new()
	pick.text = "Выбрать"
	pick.pressed.connect(_select.bind(id))
	box.add_child(pick)
	return card

## Характеристики карточки. Скорость — ещё и в процентах от среднего: дизайн формулирует классы
## именно так («на 30% быстрее»), игрок сравнивает так же.
func _stats_text(p: Dictionary) -> String:
	if p.is_empty():
		return "(сцена класса не загрузилась)"
	var speed: float = float(p.get("move_speed", _BASE_SPEED))
	var pct: int = roundi((speed / _BASE_SPEED - 1.0) * 100.0)
	var pct_text: String = "базовая" if pct == 0 else ("%+d%%" % pct)
	var scale: float = float(p.get("size_scale", 1.0))
	var size_text: String = "средний" if is_equal_approx(scale, 1.0) \
		else ("в %.1f раза %s" % [maxf(scale, 1.0 / scale), "больше" if scale > 1.0 else "меньше"])
	var penalty: String = ("−%d%% за ящик" % roundi(GameConfig.cargo_speed_penalty_per_lot * 100.0)) \
		if bool(p.get("cargo_speed_penalty_enabled", true)) else "нет"
	var lines := [
		"Размер: %s" % size_text,
		"Скорость: %.1f м/с (%s)" % [speed, pct_text],
		"Прочность: %d HP" % int(p.get("max_hits", 3)),
		"Трюм: %d" % int(p.get("cargo_capacity", 3)),
		"Груз замедляет: %s" % penalty,
		"Боекомплект: %d" % int(p.get("ammo_capacity", 10)),
		"Маскировка: %d с × %d" % [roundi(float(p.get("disguise_duration_sec", 20.0))),
			int(p.get("disguise_charges", 3))],
	]
	# Черты класса (подвижная маскировка, пружина, запрет маскировки с грузом) здесь не повторяются —
	# они в строке «Особенность» ниже, из того же префаба.
	return "\n".join(lines)

func _on_card_input(event: InputEvent, id: StringName) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_select(id)
		if event.double_click:
			_start_battle()

func _select(id: StringName) -> void:
	if not ChassisCatalog.is_known(id):
		return
	_selected = id
	_refresh_selection()

func _refresh_selection() -> void:
	for id in _cards:
		var card: PanelContainer = _cards[id]
		var style := StyleBoxFlat.new()
		var on: bool = id == _selected
		style.bg_color = _COLOR_CARD_SELECTED if on else _COLOR_CARD
		style.border_color = _COLOR_BORDER_SELECTED if on else _COLOR_BORDER
		style.set_border_width_all(4 if on else 2)
		style.set_corner_radius_all(8)
		style.content_margin_left = 16
		style.content_margin_right = 16
		style.content_margin_top = 14
		style.content_margin_bottom = 14
		card.add_theme_stylebox_override("panel", style)

## Выбор фиксируется в MatchState только здесь, на входе в бой — дальше класс не меняется до
## следующего захода через лобби.
func _start_battle() -> void:
	MatchState.player_chassis = _selected
	var target: String = MatchState.pending_map_path
	if target.is_empty():
		_back_to_menu()
		return
	get_tree().change_scene_to_file(target)

func _back_to_menu() -> void:
	get_tree().change_scene_to_file(_MAIN_MENU_SCENE)

## Подзаголовок: какой бой ждёт после лобби (по пути карты — меню кладёт его в MatchState).
func _map_title() -> String:
	var path: String = MatchState.pending_map_path
	if path.ends_with("TeamArenaMap.tscn"):
		return "Командный бой"
	if path.ends_with("KitchenMap.tscn"):
		return "Экстракшен — кухня"
	if path.ends_with("TestGroundMap.tscn"):
		return "Полигон ходовой"
	return "Бой"
