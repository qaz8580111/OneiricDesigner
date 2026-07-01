extends Node2D

## 预加载子弹数据类型，避免 Godot 全局类注册延迟导致运行时找不到类型
const BulletDataClass = preload("res://scripts/resources/bullet/BulletData.gd")

## 敌人生成间隔（秒）
@export var enemy_spawn_interval: float = 2.0

## 屏幕上同时存在的最大敌人数
@export var max_enemies: int = 100

@onready var player: CharacterBody2D = null

var BULLET_SCENE: PackedScene = preload("res://scenes/gameplay/Bullet.tscn")
var ENEMY_SCENE: PackedScene = preload("res://scenes/gameplay/Enemy.tscn")
var PICKUP_SCENE: PackedScene = preload("res://scenes/gameplay/PickUp.tscn")

## 默认子弹数据（可在编辑器中覆盖，方便调试和后续升级系统）
@export var default_bullet_data: BulletDataClass = null

var _spawn_timer: float = 0.0
var _enemy_count: int = 0
var _enemies: Array[CharacterBody2D] = []
var _bullets: Array[Area2D] = []
var _pickups: Array[Area2D] = []

signal game_over()


func _ready() -> void:
	if default_bullet_data == null:
		default_bullet_data = BulletDataClass.new()
	_find_player()


func _find_player() -> void:
	var players: Array[Node] = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		player = players[0] as CharacterBody2D
		player.shot.connect(_on_player_shot)
		player.killed.connect(_on_player_killed)


func _process(delta: float) -> void:
	_spawn_enemies(delta)
	
	# 处理手动拾取输入
	_handle_manual_pickup()


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
	enemy.drops_generated.connect(_on_enemy_drops_generated)


## 处理手动拾取输入
func _handle_manual_pickup() -> void:
	if not InputManager.is_action_just_pressed_safe("game_interact"):
		return
	
	if player == null:
		return
	
	# 查找玩家附近可手动拾取的道具
	for pickup in _pickups:
		if pickup.has_method("is_player_in_range") and pickup.has_method("pickup"):
			if pickup.is_player_in_range():
				pickup.pickup(player)
				break


## 玩家发射子弹时调用
## [param position]   子弹生成位置
## [param direction]  子弹飞行方向
func _on_player_shot(position: Vector2, direction: Vector2) -> void:
	var bullet: Area2D = BULLET_SCENE.instantiate()
	add_child(bullet)
	bullet.global_position = position

	var bullet_data: BulletDataClass = default_bullet_data.duplicate()
	if bullet.has_method("set_bullet_data"):
		bullet.set_bullet_data(bullet_data)

	bullet.set_direction(direction)
	bullet.set_owner_group("player")
	_bullets.append(bullet)

	bullet.hit.connect(_on_bullet_hit)
	bullet.destroyed.connect(_on_bullet_destroyed.bind(bullet))


## 子弹命中目标时调用
## [param bullet] 命中的子弹实例
## [param target] 被命中的目标
func _on_bullet_hit(bullet: Area2D, target: Node2D) -> void:
	if not target.has_method("take_damage"):
		return

	var damage: int = 1
	if bullet != null and bullet.has_method("get_bullet_data"):
		var bullet_data: BulletDataClass = bullet.get_bullet_data()
		if bullet_data != null:
			damage = bullet_data.get_final_damage()

	target.take_damage(damage)


## 子弹销毁时调用，从管理列表中移除
func _on_bullet_destroyed(bullet: Area2D) -> void:
	if bullet in _bullets:
		_bullets.erase(bullet)


## 敌人死亡时调用
## [param enemy] 死亡的敌人实例
func _on_enemy_killed(enemy: CharacterBody2D) -> void:
	if enemy in _enemies:
		_enemies.erase(enemy)
		_enemy_count -= 1


## 敌人掉落道具时调用
## [param position] 掉落位置
## [param drops]    掉落道具列表
func _on_enemy_drops_generated(position: Vector2, drops: Array) -> void:
	for drop_item in drops:
		if drop_item == null:
			continue
		_spawn_pickup(position, drop_item)


## 生成拾取物
## [param position] 生成位置
## [param drop_item] 道具数据
func _spawn_pickup(position: Vector2, drop_item: Resource) -> void:
	var pickup: Area2D = PICKUP_SCENE.instantiate()
	add_child(pickup)
	pickup.global_position = position + Vector2(
		RandomManager.randf_range(-20, 20),
		RandomManager.randf_range(-20, 20)
	)
	
	if pickup.has_method("set_drop_item"):
		pickup.set_drop_item(drop_item)
	
	_pickups.append(pickup)
	
	pickup.tree_exiting.connect(_on_pickup_tree_exiting.bind(pickup))


## 拾取物被移除时调用
func _on_pickup_tree_exiting(pickup: Area2D) -> void:
	if pickup in _pickups:
		_pickups.erase(pickup)


func _on_player_killed() -> void:
	game_over.emit()


## 清理所有敌人和子弹（用于场景切换或游戏结束）
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

	for pickup in _pickups:
		if pickup.is_inside_tree():
			pickup.queue_free()
	_pickups.clear()