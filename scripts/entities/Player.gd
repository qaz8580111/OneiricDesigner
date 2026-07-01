extends CharacterBody2D

@export var speed: float = 300.0
@export var shoot_cooldown: float = 0.2
@export var max_health: int = 100

@onready var sprite: Sprite2D = $Sprite2D
@onready var hitbox: Area2D = $Hitbox

var health: int = 100
var dream_fragment: int = 0

var _shoot_timer: float = 0.0

signal damaged(amount: int)
signal killed()
signal shot(position: Vector2, direction: Vector2)
signal dream_fragment_changed(amount: int)

func _ready() -> void:
	health = max_health
	dream_fragment = 0
	_create_placeholder_texture(sprite, Color(0, 0.5, 1, 1), 40, 40)
	
	if not is_in_group("player"):
		add_to_group("player")
	
	if hitbox:
		hitbox.body_entered.connect(_on_hitbox_body_entered)

func _create_placeholder_texture(sprite_node: Sprite2D, color: Color, width: int, height: int) -> void:
	var image: Image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(color)
	var texture: ImageTexture = ImageTexture.create_from_image(image)
	sprite_node.texture = texture

func _physics_process(delta: float) -> void:
	_move(delta)
	_handle_shoot(delta)

func _move(delta: float) -> void:
	var input_dir: Vector2 = InputManager.get_movement()
	
	if input_dir != Vector2.ZERO:
		input_dir = input_dir.normalized()
	
	velocity = input_dir * speed
	move_and_slide()

func _handle_shoot(delta: float) -> void:
	_shoot_timer -= delta
	
	if _shoot_timer <= 0.0 and InputManager.is_action_pressed_safe("game_shoot"):
		_shoot()
		_shoot_timer = shoot_cooldown

func _shoot() -> void:
	var mouse_pos: Vector2 = get_global_mouse_position()
	var direction: Vector2 = (mouse_pos - global_position).normalized()
	shot.emit(global_position, direction)

func take_damage(amount: int) -> void:
	health -= amount
	damaged.emit(amount)
	
	if health <= 0:
		health = 0
		killed.emit()

func heal(amount: int) -> void:
	health = min(health + amount, max_health)

func add_dream_fragment(amount: int) -> void:
	if amount <= 0:
		return
	dream_fragment += amount
	dream_fragment_changed.emit(dream_fragment)

func _on_hitbox_body_entered(body: Node2D) -> void:
	if body.has_method("on_player_collision"):
		body.on_player_collision(self)