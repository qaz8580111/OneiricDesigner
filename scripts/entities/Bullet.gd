extends Area2D

@export var speed: float = 500.0
@export var damage: int = 10
@export var screen_margin: float = 100.0
@export var spawn_offset: float = 30.0

@onready var sprite: Sprite2D = $Sprite2D

var _direction: Vector2 = Vector2.RIGHT
var _ignore_bodies: Array[Node2D] = []

signal hit(target: Node2D)
signal destroyed()

func _ready() -> void:
	_create_placeholder_texture(sprite, Color(0.2, 0.8, 1, 1), 16, 16)
	body_entered.connect(_on_body_entered)

func _create_placeholder_texture(sprite_node: Sprite2D, color: Color, width: int, height: int) -> void:
	var image: Image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(color)
	var texture: ImageTexture = ImageTexture.create_from_image(image)
	sprite_node.texture = texture

func _physics_process(delta: float) -> void:
	var velocity: Vector2 = _direction * speed
	position += velocity * delta
	_check_screen_boundary()

func set_direction(direction: Vector2) -> void:
	_direction = direction.normalized()
	rotation = _direction.angle()
	position += _direction * spawn_offset

func add_ignore_body(body: Node2D) -> void:
	_ignore_bodies.append(body)

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
		screen_size + Vector2(margin * 2, margin * 2)
	)
	
	if not visible_rect.has_point(global_position):
		_destroy()

func _on_body_entered(body: Node2D) -> void:
	if body in _ignore_bodies:
		return
	if body.has_method("take_damage"):
		hit.emit(body)
		_destroy()

func _destroy() -> void:
	destroyed.emit()
	queue_free()
