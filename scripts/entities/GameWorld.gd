extends Node2D

@export var enemy_spawn_interval: float = 2.0
@export var max_enemies: int = 10

@onready var player: CharacterBody2D = null

var BULLET_SCENE: PackedScene = preload("res://scenes/gameplay/Bullet.tscn")
var ENEMY_SCENE: PackedScene = preload("res://scenes/gameplay/Enemy.tscn")
var EXP_ORB_SCENE: PackedScene = preload("res://scenes/gameplay/ExpOrb.tscn")

var _spawn_timer: float = 0.0
var _enemy_count: int = 0
var _enemies: Array[CharacterBody2D] = []
var _bullets: Array[Area2D] = []

signal game_over()

func _ready() -> void:
	_find_player()

func _find_player() -> void:
	var players: Array[Node] = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		player = players[0] as CharacterBody2D
		player.shot.connect(_on_player_shot)
		player.killed.connect(_on_player_killed)

func _process(delta: float) -> void:
	_spawn_enemies(delta)

func _spawn_enemies(delta: float) -> void:
	if _enemy_count >= max_enemies:
		return
	
	_spawn_timer -= delta
	
	if _spawn_timer <= 0.0:
		_spawn_enemy()
		_spawn_timer = enemy_spawn_interval

func _spawn_enemy() -> void:
	var enemy: CharacterBody2D = ENEMY_SCENE.instantiate()
	
	var margin: float = 100.0
	var screen_size: Vector2 = get_viewport_rect().size
	var side: int = RandomManager.randi_range(0, 3)
	
	match side:
		0:
			enemy.position = Vector2(RandomManager.randf_range(0, screen_size.x), -margin)
		1:
			enemy.position = Vector2(screen_size.x + margin, RandomManager.randf_range(0, screen_size.y))
		2:
			enemy.position = Vector2(RandomManager.randf_range(0, screen_size.x), screen_size.y + margin)
		3:
			enemy.position = Vector2(-margin, RandomManager.randf_range(0, screen_size.y))
	
	add_child(enemy)
	_enemies.append(enemy)
	_enemy_count += 1
	
	enemy.killed.connect(_on_enemy_killed.bind(enemy))

func _on_player_shot(position: Vector2, direction: Vector2) -> void:
	var bullet: Area2D = BULLET_SCENE.instantiate()
	add_child(bullet)
	bullet.global_position = position
	bullet.set_direction(direction)
	if bullet.has_method("add_ignore_body") and player:
		bullet.add_ignore_body(player)
	_bullets.append(bullet)
	
	bullet.hit.connect(_on_bullet_hit)
	bullet.destroyed.connect(_on_bullet_destroyed.bind(bullet))

func _on_bullet_hit(target: Node2D) -> void:
	if target.has_method("take_damage"):
		target.take_damage(10)

func _on_bullet_destroyed(bullet: Area2D) -> void:
	if bullet in _bullets:
		_bullets.erase(bullet)

func _on_enemy_killed(enemy: CharacterBody2D) -> void:
	if enemy in _enemies:
		_enemies.erase(enemy)
		_enemy_count -= 1
		
		_spawn_exp_orb(enemy.position, enemy.exp_reward)

func _spawn_exp_orb(position: Vector2, exp_amount: int) -> void:
	var exp_orb: Area2D = EXP_ORB_SCENE.instantiate()
	exp_orb.position = position
	exp_orb.exp_amount = exp_amount
	add_child(exp_orb)
	
	exp_orb.collected.connect(_on_exp_collected)

func _on_exp_collected(amount: int) -> void:
	if player and player.has_method("add_exp"):
		player.add_exp(amount)

func _on_player_killed() -> void:
	game_over.emit()

func clear_all() -> void:
	for enemy in _enemies:
		if enemy.is_inside_tree():
			enemy.queue_free()
	_enemies.clear()
	_enemy_count = 0
	
	for bullet in _bullets:
		if bullet.is_inside_tree():
			bullet.queue_free()
	_bullets.clear()