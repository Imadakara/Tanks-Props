extends Node
class_name TankStateMachine
## TankStateMachine — состояния танка и переходы между ними (ТЗ §5).
## Публичный контракт для остальных компонентов танка (WeaponController,
## DisguiseController, TurretController, TankMovement, столкновения):
## request_fire(), request_disguise(), break_disguise(reason), can_fire(),
## can_enter_disguise(). Тайминги берутся из автозагрузки GameConfig (ТЗ §11.4).

signal state_changed(old_state: State, new_state: State)

enum State { NORMAL, DISGUISED, DISGUISE_COOLDOWN, RELOAD }

var state: State = State.NORMAL

@onready var _disguise_timer: Timer = $DisguiseTimer
@onready var _cooldown_timer: Timer = $CooldownTimer
@onready var _reload_timer: Timer = $ReloadTimer

func _ready() -> void:
	_disguise_timer.one_shot = true
	_cooldown_timer.one_shot = true
	_reload_timer.one_shot = true
	_disguise_timer.wait_time = GameConfig.disguise_duration_sec
	_cooldown_timer.wait_time = GameConfig.disguise_cooldown_sec
	# reload_timer.wait_time НЕ кэшируется здесь — читается заново в request_fire() при каждом
	# выстреле (см. ниже). Кэш в _ready() дал бы устаревшее значение, если бы какая-то карта
	# переопределяла GameConfig.reload_duration_sec точечно из своего корневого _ready() (тот
	# срабатывает ПОСЛЕДНИМ, когда все танки уже готовы) — сейчас ни одна карта так не делает
	# (единый дефолт 3с везде, см. autoload/game_config.gd), но чтение "по требованию" остаётся
	# правильным на случай, если такое переопределение понадобится снова.
	_disguise_timer.timeout.connect(_on_disguise_timeout)
	_cooldown_timer.timeout.connect(_on_cooldown_timeout)
	_reload_timer.timeout.connect(_on_reload_timeout)

func _set_state(new_state: State) -> void:
	if new_state == state:
		return
	var old := state
	state = new_state
	state_changed.emit(old, new_state)

func can_fire() -> bool:
	return state == State.NORMAL or state == State.DISGUISED

func can_enter_disguise() -> bool:
	return state == State.NORMAL

## Выстрел. Вызывается WeaponController. Возвращает false, если выстрел сейчас недоступен
## (RELOAD/DISGUISE_COOLDOWN). Выстрел из DISGUISED снимает маскировку в момент выстрела
## и переводит сразу в RELOAD, минуя NORMAL (ТЗ §5.1, §7).
func request_fire() -> bool:
	if not can_fire():
		return false
	if state == State.DISGUISED:
		_disguise_timer.stop()
	_set_state(State.RELOAD)
	_reload_timer.wait_time = GameConfig.reload_duration_sec
	_reload_timer.start()
	return true

## Активация маскировки. Вызывается DisguiseController при валидном слоте вне кулдауна.
func request_disguise() -> bool:
	if not can_enter_disguise():
		return false
	_set_state(State.DISGUISED)
	_disguise_timer.start()
	return true

## Досрочное снятие маскировки: поворот башни / начало движения / столкновение с
## движущимся танком (ТЗ §5.1, §5.2). Не действует, если маскировка уже не активна.
func break_disguise(_reason: String) -> void:
	if state != State.DISGUISED:
		return
	_disguise_timer.stop()
	_set_state(State.DISGUISE_COOLDOWN)
	_cooldown_timer.start()

func _on_disguise_timeout() -> void:
	_set_state(State.DISGUISE_COOLDOWN)
	_cooldown_timer.start()

func _on_cooldown_timeout() -> void:
	_set_state(State.NORMAL)

func _on_reload_timeout() -> void:
	_set_state(State.NORMAL)

## Принудительный сброс в NORMAL при респауне (пост-ревью, см. respawn_controller.gd) —
## глушит все таймеры состояний напрямую, минуя обычные переходы (танк мог умереть в любом
## состоянии, например посреди RELOAD/DISGUISED). Если состояние было DISGUISED,
## state_changed корректно долетает до DisguiseController._on_state_changed → визуал
## маскировки снимается как обычно.
func force_reset() -> void:
	_disguise_timer.stop()
	_cooldown_timer.stop()
	_reload_timer.stop()
	_set_state(State.NORMAL)
