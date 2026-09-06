extends Area3D
## Projectile — параболический снаряд (урон 1 по умолчанию). Траектория считается
## вручную (кинематическая интеграция вместо RigidBody3D) — детерминированно и легко
## проверяется тестами. Столкновение с любым телом (танк или окружение) завершает
## полёт; урон наносится только если у тела есть HealthComponent.

signal hit_tank(tank: Node)

@export var speed: float = 20.0
@export var fall_acceleration: float = 9.8
@export var max_lifetime_sec: float = 8.0
## Урон, передаётся в HealthComponent.take_hit(). Обычный выстрел = 1; спец-выстрел модификации
## (WeaponController.fire_special; мортира ставит GameConfig.mortar_objective_damage = 20) —
## этого хватает и на one-shot по танку (max_hits 3), и на кусок 100-HP objective.
@export var damage: int = 1

var velocity: Vector3 = Vector3.ZERO
var _shooter: Node = null
var _age: float = 0.0

func launch(from: Vector3, direction: Vector3, shooter: Node) -> void:
	global_position = from
	velocity = direction.normalized() * speed
	_shooter = shooter

func _ready() -> void:
	# Группа — MatchManager ждёт приземления всех снарядов в полёте, прежде чем засчитать
	# защите победу по таймауту («баскетбольное» правило, см. match_manager._on_round_timeout).
	add_to_group("projectiles")
	body_entered.connect(_on_body_entered)

func _physics_process(delta: float) -> void:
	_age += delta
	if _age > max_lifetime_sec:
		queue_free()
		return
	velocity.y -= fall_acceleration * delta
	global_position += velocity * delta

func _on_body_entered(body: Node) -> void:
	if body == _shooter:
		return
	var health: Node = body.get_node_or_null("HealthComponent")
	if health != null:
		hit_tank.emit(body)
		health.take_hit(_shooter, damage)
	queue_free()
