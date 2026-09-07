@tool
extends StaticBody3D
## ToyRamp — наклонный въезд между двумя игровыми поверхностями разной высоты (линейка, книга,
## кусок гоночного трека — один и тот же примитив, разный `size`/`color`). Единственный новый
## геометрический тип, потребовавшийся для вертикальной карты: `Obstacle`/`Structure` дают только
## осевые коробки, а танк по ступеньке не заедет (`CharacterBody3D` в проекте не умеет step-up —
## связность уровней держится ИСКЛЮЧИТЕЛЬНО на наклонных поверхностях).
##
## Геометрия — один повёрнутый вокруг X тонкий бокс. Узел ставится В ТОЧКУ НИЗА въезда (на нижнюю
## поверхность), крутится по Y в сторону подъёма; `run`/`rise` задают, куда он приедет:
## верхний конец верхней грани оказывается РОВНО на `run` вперёд (по -Z узла, как и весь остальной
## forward в проекте, см. `tank_movement.gd`) и на `rise` вверх от начала координат узла. Нижний
## конец верхней грани — ровно в начале координат узла (y=0), поэтому «поставил узел на пол/на
## столешницу» = «въезд лежит заподлицо».
##
## ПРАВИЛО РАССТАНОВКИ: верхний конец обязан приходиться РОВНО на КРАЙ верхней площадки, не внутрь
## неё. Если целиться внутрь, последний отрезок въезда идёт ниже верхней плоскости и танк упирается
## в вертикальную грань площадки, а не заезжает на неё.
##
## Наклон = atan(rise/run). Держать <= ~32°: `floor_max_angle` танка 45°, `agent_max_slope` навмеша
## карты 40° — запас на то, что коробка танка на склоне не наклоняется, а опирается передним ребром.
##
## НЕ масштабировать узел через `Transform → Scale` (как и `Obstacle`/`Structure`) — размер только
## через эти поля.

## Горизонтальная проекция въезда (вперёд, по -Z узла).
@export var run: float = 24.0:
	set(value):
		run = maxf(value, 0.01)
		_apply()

## Подъём по вертикали от начала координат узла до верхнего конца.
@export var rise: float = 10.8:
	set(value):
		rise = maxf(value, 0.0)
		_apply()

## Ширина полотна (поперёк движения, по X узла).
@export var width: float = 8.0:
	set(value):
		width = maxf(value, 0.01)
		_apply()

## Толщина полотна. Уходит ПОД верхнюю грань — нижний торец утапливается в нижнюю поверхность,
## порога на въезде не образует.
@export var thickness: float = 1.0:
	set(value):
		thickness = maxf(value, 0.01)
		_apply()

@export var color: Color = Color(0.85, 0.78, 0.55):
	set(value):
		color = value
		_apply()

@onready var _shape: CollisionShape3D = $CollisionShape3D
@onready var _mesh: MeshInstance3D = $Mesh

func _ready() -> void:
	_apply()
	if not Engine.is_editor_hint():
		add_to_group("structures")  # постоянная геометрия карты, как Structure — см. structure.gd

## Полотно — бокс (width, thickness, length), повёрнутый вокруг X на угол наклона так, что его
## конец по -Z уходит ВВЕРХ, и сдвинутый в локальных координатах ровно настолько, чтобы середина
## верхней грани нижнего торца легла в (0, 0, 0), а верхнего — в (0, rise, -run). Вывод сдвига:
## точка бокса (0, t/2, +L/2) после поворота на угол a вокруг X даёт y = t·cos(a)/2 − rise/2 и
## z = t·sin(a)/2 + run/2 — центр компенсирует ровно это.
func _apply() -> void:
	if not is_node_ready():
		return
	var length: float = sqrt(run * run + rise * rise)
	var angle: float = atan2(rise, run)
	var box_size := Vector3(width, thickness, length)
	var basis := Basis(Vector3.RIGHT, angle)
	var origin := Vector3(
		0.0,
		rise * 0.5 - thickness * cos(angle) * 0.5,
		-(thickness * sin(angle) * 0.5 + run * 0.5)
	)
	var xform := Transform3D(basis, origin)
	if _shape != null:
		_shape.transform = xform
		if _shape.shape is BoxShape3D:
			_shape.shape.size = box_size
	if _mesh != null:
		_mesh.transform = xform
		if _mesh.mesh is BoxMesh:
			_mesh.mesh.size = box_size
		if _mesh.material_override is StandardMaterial3D:
			_mesh.material_override.albedo_color = color
