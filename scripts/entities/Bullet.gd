extends Area2D

## 预加载子弹相关资源类型
## 使用 preload 避免 Godot 全局类注册延迟导致运行时找不到类型
## 注意：预加载的脚本 const 不应标注为 Script 类型，否则无法调用 new()
const BulletDataClass = preload("res://scripts/resources/bullet/BulletData.gd")
const BulletFormClass = preload("res://scripts/resources/bullet/BulletForm.gd")
const BulletEffectClass = preload("res://scripts/resources/bullet/BulletEffect.gd")

## 屏幕边界余量，飞出屏幕+余量后自动销毁
@export var screen_margin: float = 100.0

## 生成偏移距离，避免子弹刚生成就和发射者碰撞
@export var spawn_offset: float = 30.0

@onready var sprite: Sprite2D = $Sprite2D

## 子弹数据资源（包含伤害、速度、形态、特效等配置）
var _bullet_data: BulletDataClass = null

## 飞行方向（单位向量）
var _direction: Vector2 = Vector2.RIGHT

## 命中目标时发出，传递子弹自身和命中目标
signal hit(bullet: Area2D, target: Node2D)

## 子弹销毁时发出
signal destroyed()


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	# 如果没有外部传入数据，使用默认数据
	if _bullet_data == null:
		_bullet_data = BulletDataClass.new()
	_apply_bullet_data()
	# 触发生成时特效
	_bullet_data.trigger_effects(BulletEffectClass.TriggerType.ON_SPAWN, self)


## 设置子弹数据，应在 add_child 之前调用
## [param data] 子弹配置资源
func set_bullet_data(data: BulletDataClass) -> void:
	_bullet_data = data


## 获取当前子弹数据（方便外部读取伤害等信息）
func get_bullet_data() -> BulletDataClass:
	return _bullet_data


## 应用子弹数据到子弹实例（形态、速度、外观等）
func _apply_bullet_data() -> void:
	if _bullet_data == null:
		return

	var form: BulletFormClass = _bullet_data.get_final_form()
	if form != null and sprite != null:
		form.apply_visual(sprite)


## 设置子弹飞行方向
## [param direction] 飞行方向向量
func set_direction(direction: Vector2) -> void:
	_direction = direction.normalized()
	rotation = _direction.angle()
	position += _direction * spawn_offset


func _physics_process(delta: float) -> void:
	if _bullet_data == null:
		return

	var velocity: Vector2 = _direction * _bullet_data.get_final_speed()
	position += velocity * delta

	# 触发飞行过程中特效
	_bullet_data.trigger_effects(BulletEffectClass.TriggerType.ON_TRAVEL, self)

	_check_screen_boundary()


## 检查是否飞出屏幕边界
func _check_screen_boundary() -> void:
	var camera: Camera2D = get_viewport().get_camera_2d()
	if camera == null:
		return

	var screen_size: Vector2 = get_viewport_rect().size
	var camera_pos: Vector2 = camera.global_position
	var half_screen: Vector2 = screen_size / 2.0
	var margin: float = screen_margin

	var visible_rect: Rect2 = Rect2(
		camera_pos - half_screen - Vector2(margin, margin),
		screen_size + Vector2(margin * 2.0, margin * 2.0)
	)

	if not visible_rect.has_point(global_position):
		_destroy()


## 碰撞体进入时调用
func _on_body_entered(body: Node2D) -> void:
	# 触发命中特效（无论目标是否能受伤）
	if _bullet_data != null:
		_bullet_data.trigger_effects(
			BulletEffectClass.TriggerType.ON_HIT,
			self,
			body,
			{"direction": _direction}
		)

	# 如果目标可以受伤，发出命中信号并销毁自身
	if body.has_method("take_damage"):
		hit.emit(self, body)
		_destroy()


## 销毁子弹
func _destroy() -> void:
	if _bullet_data != null:
		_bullet_data.trigger_effects(BulletEffectClass.TriggerType.ON_DESTROY, self)
	destroyed.emit()
	queue_free()
