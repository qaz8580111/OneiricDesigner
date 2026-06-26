extends Area2D

@export var exp_amount: int = 20
@export var speed: float = 100.0
@export var lifetime: float = 5.0

@onready var sprite: Sprite2D = $Sprite2D

var _target: Node2D = null
var _lifetime_timer: float = 0.0
var _floating_offset: float = 0.0

signal collected(amount: int)

func _ready() -> void:
	_lifetime_timer = lifetime
	_create_placeholder_texture(sprite, Color(0.2, 1, 0.5, 1), 20, 20)
	body_entered.connect(_on_body_entered)

func _create_placeholder_texture(sprite_node: Sprite2D, color: Color, width: int, height: int) -> void:
	var image: Image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(color)
	var texture: ImageTexture = ImageTexture.create_from_image(image)
	sprite_node.texture = texture

func _physics_process(delta: float) -> void:
	_lifetime_timer -= delta
	
	if _lifetime_timer <= 0.0:
		queue_free()
		return
	
	if _target == null:
		_find_player()
	
	_floating_offset += delta * 2.0
	sprite.offset.y = sin(_floating_offset) * 5.0
	
	if _target != null:
		_move_to_target(delta)

func _find_player() -> void:
	var players: Array[Node] = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		_target = players[0] as Node2D

func _move_to_target(delta: float) -> void:
	if _target == null:
		return
	
	var distance: float = position.distance_to(_target.position)
	
	if distance < 150.0:
		var direction: Vector2 = (_target.position - position).normalized()
		var velocity: Vector2 = direction * speed * (1.0 - distance / 150.0)
		position += velocity * delta

func _on_body_entered(body: Node2D) -> void:
	if body.name == "Player" or body.has_method("add_exp"):
		collected.emit(exp_amount)
		queue_free()