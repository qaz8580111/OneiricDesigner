extends CharacterBody2D

const EnemyDataClass = preload("res://scripts/resources/enemy/EnemyData.gd")
const BulletDataClass = preload("res://scripts/resources/bullet/BulletData.gd")
const BulletFormClass = preload("res://scripts/resources/bullet/BulletForm.gd")
const BULLET_SCENE: PackedScene = preload("res://scenes/gameplay/Bullet.tscn")

@export var enemy_data: EnemyDataClass = null

@export var speed: float = 100.0
@export var wander_speed: float = 60.0
@export var wander_interval: float = 2.0
@export var max_health: int = 5
@export var health: int = 5
@export var damage: int = 10

@export var detection_range: float = 300.0
@export var attack_range: float = 150.0
@export var attack_cooldown: float = 1.0

@onready var sprite: Sprite2D = $Sprite2D
@onready var hitbox: Area2D = $Hitbox

var _player: CharacterBody2D = null
var _original_color: Color = Color.WHITE
var _attack_timer: float = 0.0
var _wander_timer: float = 0.0
var _wander_direction: Vector2 = Vector2.ZERO
var _current_state: EnemyState = EnemyState.WANDER

enum EnemyState {
	WANDER,
	CHASE,
	ATTACK
}

signal killed()
signal damaged(amount: int)
signal drops_generated(position: Vector2, drops: Array)
signal attacked(direction: Vector2)


func _ready() -> void:
	if enemy_data != null:
		enemy_data.apply_to_enemy(self)
	
	health = max_health
	_attack_timer = 0.0
	_wander_timer = 0.0
	_wander_direction = _get_random_direction()
	
	var color: Color = Color(1, 0.2, 0.2, 1)
	var width: int = 30
	var height: int = 30
	if enemy_data != null:
		color = enemy_data.placeholder_color
		width = int(enemy_data.placeholder_size.x)
		height = int(enemy_data.placeholder_size.y)
	_create_placeholder_texture(sprite, color, width, height)
	
	_original_color = sprite.modulate
	
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
		if _player == null:
			_handle_wander(delta)
			return
	
	_attack_timer -= delta
	_wander_timer -= delta
	
	_update_state()
	
	match _current_state:
		EnemyState.WANDER:
			_handle_wander(delta)
		EnemyState.CHASE:
			_handle_chase(delta)
		EnemyState.ATTACK:
			_handle_attack(delta)


func _find_player() -> void:
	var parent_node: Node = get_parent()
	if parent_node != null and "player" in parent_node:
		var potential_player: CharacterBody2D = parent_node.player
		if potential_player != null and is_instance_valid(potential_player):
			_player = potential_player
			return
	
	var players: Array[Node] = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		_player = players[0] as CharacterBody2D


func _get_random_direction() -> Vector2:
	var angle: float = RandomManager.randf() * TAU
	return Vector2(cos(angle), sin(angle)).normalized()


func _update_state() -> void:
	if _player == null:
		_current_state = EnemyState.WANDER
		return
	
	var distance: float = global_position.distance_to(_player.global_position)
	
	# 在攻击范围内 → 攻击
	if distance <= attack_range:
		_current_state = EnemyState.ATTACK
	else:
		# 攻击范围外 → 始终追踪玩家（无论是否在检测范围内）
		_current_state = EnemyState.CHASE


func _handle_wander(delta: float) -> void:
	if _wander_timer <= 0.0:
		_wander_direction = _get_random_direction()
		_wander_timer = wander_interval
	
	velocity = _wander_direction * wander_speed
	move_and_slide()


func _handle_chase(delta: float) -> void:
	if _player == null:
		return
	
	var direction: Vector2 = (_player.global_position - global_position).normalized()
	velocity = direction * speed
	move_and_slide()


func _handle_attack(delta: float) -> void:
	velocity = Vector2.ZERO
	
	if _player == null:
		return
	
	if _attack_timer <= 0.0:
		_perform_attack()
		_attack_timer = attack_cooldown


func _perform_attack() -> void:
	if _player == null:
		return
	
	var direction: Vector2 = (_player.global_position - global_position).normalized()
	
	var bullet_data: BulletDataClass = null
	if enemy_data != null:
		bullet_data = enemy_data.get_bullet_data()
	if bullet_data == null:
		bullet_data = BulletDataClass.new()
		bullet_data.damage = damage
		bullet_data.speed = 300.0
	
	if BULLET_SCENE == null:
		return
	
	var bullet: Area2D = BULLET_SCENE.instantiate()
	
	bullet.set_bullet_data(bullet_data)
	bullet.set_owner_group("enemy")
	bullet.collision_layer = 8
	bullet.collision_mask = 1
	
	get_parent().add_child(bullet)
	
	bullet.set_direction(direction)
	bullet.global_position = global_position + direction * 30.0
	
	var bullet_sprite: Sprite2D = bullet.get_node_or_null("Sprite2D")
	if bullet_sprite:
		var form: BulletFormClass = bullet_data.get_final_form()
		if form != null:
			form.apply_visual(bullet_sprite)
		else:
			bullet_sprite.modulate = Color(1, 0.2, 0.2, 1)
	
	attacked.emit(direction)


func take_damage(amount: int) -> void:
	if amount <= 0:
		return

	health -= amount
	health = max(health, 0)
	damaged.emit(amount)

	_flash_hit()

	if health <= 0:
		_die()


func _flash_hit() -> void:
	if sprite == null:
		return

	sprite.modulate = Color.WHITE
	await get_tree().create_timer(0.1).timeout
	if is_instance_valid(sprite):
		sprite.modulate = _original_color


func _die() -> void:
	var drop_items: Array = []
	if enemy_data != null:
		drop_items = enemy_data.get_drops_to_spawn()
	if drop_items.size() > 0:
		drops_generated.emit(global_position, drop_items)
	
	killed.emit()
	queue_free()


func on_player_collision(player: Node2D) -> void:
	if player.has_method("take_damage"):
		player.take_damage(damage)


func _on_hitbox_body_entered(body: Node2D) -> void:
	if body.is_in_group("player"):
		on_player_collision(body)