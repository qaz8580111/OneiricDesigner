extends Area2D

const BulletDataClass = preload("res://scripts/resources/bullet/BulletData.gd")
const BulletFormClass = preload("res://scripts/resources/bullet/BulletForm.gd")
const BulletEffectClass = preload("res://scripts/resources/bullet/BulletEffect.gd")

@export var screen_margin: float = 100.0
@export var spawn_offset: float = 30.0

@onready var sprite: Sprite2D = $Sprite2D

var _bullet_data: BulletDataClass = null
var _direction: Vector2 = Vector2.RIGHT
var _owner_group: String = ""

signal hit(bullet: Area2D, target: Node2D)
signal destroyed()


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	if _bullet_data == null:
		_bullet_data = BulletDataClass.new()
	_apply_bullet_data()
	_bullet_data.trigger_effects(BulletEffectClass.TriggerType.ON_SPAWN, self)


func set_bullet_data(data: BulletDataClass) -> void:
	_bullet_data = data


func get_bullet_data() -> BulletDataClass:
	return _bullet_data


func set_owner_group(group_name: String) -> void:
	_owner_group = group_name


func _apply_bullet_data() -> void:
	if _bullet_data == null:
		return

	var form: BulletFormClass = _bullet_data.get_final_form()
	if form != null and sprite != null:
		form.apply_visual(sprite)


func set_direction(direction: Vector2) -> void:
	_direction = direction.normalized()
	rotation = _direction.angle()
	position += _direction * spawn_offset


func _physics_process(delta: float) -> void:
	if _bullet_data == null:
		return

	var velocity: Vector2 = _direction * _bullet_data.get_final_speed()
	position += velocity * delta

	_bullet_data.trigger_effects(BulletEffectClass.TriggerType.ON_TRAVEL, self)

	_check_screen_boundary()


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


func _on_body_entered(body: Node2D) -> void:
	if _owner_group != "" and body.is_in_group(_owner_group):
		return

	if _bullet_data != null:
		_bullet_data.trigger_effects(
			BulletEffectClass.TriggerType.ON_HIT,
			self,
			body,
			{"direction": _direction}
		)

	if body.has_method("take_damage"):
		hit.emit(self, body)
		_destroy()


func _destroy() -> void:
	if _bullet_data != null:
		_bullet_data.trigger_effects(BulletEffectClass.TriggerType.ON_DESTROY, self)
	destroyed.emit()
	queue_free()