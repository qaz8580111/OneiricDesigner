extends CharacterBody2D

@export var speed: float = 100.0
@export var health: int = 30
@export var damage: int = 10
@export var exp_reward: int = 20

@onready var sprite: Sprite2D = $Sprite2D
@onready var hitbox: Area2D = $Hitbox

var _max_health: int = 30
var _player: CharacterBody2D = null

signal killed()
signal damaged(amount: int)

func _ready() -> void:
	_max_health = health
	_create_placeholder_texture(sprite, Color(1, 0.2, 0.2, 1), 30, 30)
	if hitbox:
		hitbox.body_entered.connect(_on_hitbox_body_entered)

func _create_placeholder_texture(sprite_node: Sprite2D, color: Color, width: int, height: int) -> void:
	var image: Image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(color)
	var texture: ImageTexture = ImageTexture.create_from_image(image)
	sprite_node.texture = texture

func _physics_process(delta: float) -> void:
	if _player == null:
		_find_player()
		return
	
	_chase_player(delta)

func _find_player() -> void:
	var players: Array[Node] = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		_player = players[0] as CharacterBody2D

func _chase_player(delta: float) -> void:
	if _player == null:
		return
	
	var direction: Vector2 = (_player.position - position).normalized()
	velocity = direction * speed
	move_and_slide()

func take_damage(amount: int) -> void:
	health -= amount
	damaged.emit(amount)
	
	if health <= 0:
		health = 0
		killed.emit()
		queue_free()

func on_player_collision(player: Node2D) -> void:
	if player.has_method("take_damage"):
		player.take_damage(damage)

func _on_hitbox_body_entered(body: Node2D) -> void:
	if body.name == "Player":
		on_player_collision(body)