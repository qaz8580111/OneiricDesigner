extends CharacterBody2D

@export var speed: float = 300.0
@export var shoot_cooldown: float = 0.2
@export var max_health: int = 100

@onready var sprite: Sprite2D = $Sprite2D
@onready var hitbox: Area2D = $Hitbox

var health: int = 100
var level: int = 1
var exp: int = 0
var exp_to_next_level: int = 100

var _shoot_timer: float = 0.0

signal damaged(amount: int)
signal killed()
signal leveled_up(new_level: int)
signal exp_gained(amount: int)
signal shot(position: Vector2, direction: Vector2)

func _ready() -> void:
	health = max_health
	if hitbox:
		hitbox.body_entered.connect(_on_hitbox_body_entered)

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
	
	if _shoot_timer <= 0.0 and InputManager.is_action_just_pressed_safe("game_shoot"):
		_shoot()
		_shoot_timer = shoot_cooldown

func _shoot() -> void:
	var direction: Vector2 = Vector2.RIGHT
	
	var input_dir: Vector2 = InputManager.get_movement()
	if input_dir != Vector2.ZERO:
		direction = input_dir.normalized()
	
	shot.emit(position, direction)

func take_damage(amount: int) -> void:
	health -= amount
	damaged.emit(amount)
	
	if health <= 0:
		health = 0
		killed.emit()

func heal(amount: int) -> void:
	health = min(health + amount, max_health)

func add_exp(amount: int) -> void:
	exp += amount
	exp_gained.emit(amount)
	
	while exp >= exp_to_next_level:
		exp -= exp_to_next_level
		level_up()

func level_up() -> void:
	level += 1
	exp_to_next_level = int(exp_to_next_level * 1.5)
	max_health = int(max_health * 1.2)
	health = max_health
	speed = speed * 1.05
	leveled_up.emit(level)

func _on_hitbox_body_entered(body: Node2D) -> void:
	if body.has_method("on_player_collision"):
		body.on_player_collision(self)

func get_exp_progress() -> float:
	return float(exp) / float(exp_to_next_level)