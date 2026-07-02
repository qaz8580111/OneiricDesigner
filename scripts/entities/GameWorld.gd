## GameWorld.gd - 游戏世界管理脚本
## 职责：管理敌人生成、子弹创建、道具掉落、玩家交互等核心游戏逻辑
## 继承：Node2D（Godot 4的2D节点，作为游戏世界容器）
extends Node2D

## ========== 预加载资源（避免运行时加载延迟） ==========

## 子弹数据资源类，用于配置子弹属性（伤害、速度、形态、特效等）
const BulletDataClass = preload("res://scripts/resources/bullet/BulletData.gd")

## ========== 导出变量（编辑器可配置） ==========

## 敌人生成间隔（秒），控制敌人出现频率
@export var enemy_spawn_interval: float = 2.0

## 屏幕上同时存在的最大敌人数，防止敌人过多导致性能问题
@export var max_enemies: int = 100

## ========== 节点引用（使用 @onready 延迟初始化） ==========

## 玩家引用，用于传递给敌人生成时使用
@onready var player: CharacterBody2D = null

## ========== 场景预加载（避免运行时重复加载） ==========

## 子弹场景预加载
var BULLET_SCENE: PackedScene = preload("res://scenes/gameplay/Bullet.tscn")

## 敌人场景预加载
var ENEMY_SCENE: PackedScene = preload("res://scenes/gameplay/Enemy.tscn")

## 拾取物场景预加载
var PICKUP_SCENE: PackedScene = preload("res://scenes/gameplay/PickUp.tscn")

## ========== 配置数据 ==========

## 默认子弹数据（玩家发射子弹时使用），可在编辑器中覆盖
@export var default_bullet_data: BulletDataClass = null

## ========== 成员变量（运行时数据） ==========

## 敌人生成计时器，递减到0时生成新敌人
var _spawn_timer: float = 0.0

## 当前场景中存活的敌人数
var _enemy_count: int = 0

## 场景中所有敌人的管理列表
var _enemies: Array[CharacterBody2D] = []

## 场景中所有子弹的管理列表
var _bullets: Array[Area2D] = []

## 场景中所有拾取物的管理列表
var _pickups: Array[Area2D] = []

## ========== 信号定义（用于与其他节点通信） ==========

## 游戏结束时发出此信号（玩家死亡）
signal game_over()

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 如果默认子弹数据为空，创建默认子弹数据
	if default_bullet_data == null:
		default_bullet_data = BulletDataClass.new()
	
	## 查找玩家并连接信号
	_find_player()

## ========== 玩家查找与信号连接 ==========

## 查找玩家并连接相关信号
func _find_player() -> void:
	## 从"player"组查找玩家
	var players: Array[Node] = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		player = players[0] as CharacterBody2D
		
		## 连接玩家射击信号：当玩家发射子弹时触发回调
		if player.has_signal("shot"):
			player.connect("shot", _on_player_shot)
		
		## 连接玩家死亡信号：优先连接player.killed，否则连接HealthController.player_died
		if player.has_signal("killed"):
			player.connect("killed", _on_player_killed)
		else:
			var health_controller: Node = player.get_node_or_null("HealthController")
			if health_controller != null and health_controller.has_signal("player_died"):
				health_controller.connect("player_died", _on_player_killed)

## ========== 帧更新方法 ==========

## _process() - 每帧调用一次，用于处理非物理相关逻辑
func _process(delta: float) -> void:
	## 处理敌人生成
	_spawn_enemies(delta)
	
	## 处理手动拾取输入（按E键拾取道具）
	_handle_manual_pickup()

## ========== 敌人生成系统 ==========

## 处理敌人生成逻辑
## 参数：delta - 帧间隔时间（秒）
func _spawn_enemies(delta: float) -> void:
	## 如果当前敌人数量已达上限，不生成新敌人
	if _enemy_count >= max_enemies:
		return

	## 递减敌人生成计时器
	_spawn_timer -= delta

	## 如果计时器归零，生成新敌人
	if _spawn_timer <= 0.0:
		_spawn_enemy()
		## 重置生成计时器
		_spawn_timer = enemy_spawn_interval

## 生成单个敌人
func _spawn_enemy() -> void:
	## 实例化敌人节点
	var enemy: CharacterBody2D = ENEMY_SCENE.instantiate()

	## 设置敌人生成位置（屏幕边缘随机位置）
	var margin: float = 100.0          # 生成位置距屏幕边缘的距离
	var screen_size: Vector2 = get_viewport_rect().size  # 获取屏幕尺寸
	var side: int = RandomManager.randi_range(0, 3)       # 随机选择生成边（上/右/下/左）

	## 根据随机选择的边设置敌人位置
	match side:
		0:
			## 上边：随机X位置，Y在屏幕上方
			enemy.position = Vector2(RandomManager.randf_range(0, screen_size.x), -margin)
		1:
			## 右边：X在屏幕右方，随机Y位置
			enemy.position = Vector2(screen_size.x + margin, RandomManager.randf_range(0, screen_size.y))
		2:
			## 下边：随机X位置，Y在屏幕下方
			enemy.position = Vector2(RandomManager.randf_range(0, screen_size.x), screen_size.y + margin)
		3:
			## 左边：X在屏幕左方，随机Y位置
			enemy.position = Vector2(-margin, RandomManager.randf_range(0, screen_size.y))

	## 将敌人添加到场景树中
	add_child(enemy)
	## 将敌人添加到管理列表
	_enemies.append(enemy)
	## 增加敌人计数
	_enemy_count += 1

	## 连接敌人死亡信号：当敌人死亡时触发回调（绑定敌人实例）
	enemy.killed.connect(_on_enemy_killed.bind(enemy))
	## 连接敌人掉落信号：当敌人生成掉落物时触发回调
	enemy.drops_generated.connect(_on_enemy_drops_generated)

## ========== 道具拾取系统 ==========

## 处理手动拾取输入（玩家按E键拾取道具）
func _handle_manual_pickup() -> void:
	## 如果没有按下交互键，直接返回
	if not InputManager.is_action_just_pressed_safe("game_interact"):
		return
	
	## 如果玩家为空，直接返回
	if player == null:
		return
	
	## 遍历所有拾取物，查找玩家附近可手动拾取的道具
	for pickup in _pickups:
		## 检查拾取物是否有必要的方法
		if pickup.has_method("is_player_in_range") and pickup.has_method("pickup"):
			## 如果玩家在拾取范围内，执行拾取
			if pickup.is_player_in_range():
				pickup.pickup(player)
				break

## ========== 子弹系统 ==========

## 玩家发射子弹时的回调（响应player.shot信号）
## 参数：position - 子弹发射位置，direction - 子弹飞行方向
func _on_player_shot(position: Vector2, direction: Vector2) -> void:
	## 实例化子弹节点
	var bullet: Area2D = BULLET_SCENE.instantiate()
	## 将子弹添加到场景树中
	add_child(bullet)
	## 设置子弹发射位置
	bullet.global_position = position

	## 复制默认子弹数据（每个子弹独立一份，避免共享数据被修改）
	var bullet_data: BulletDataClass = default_bullet_data.duplicate()
	## 设置子弹数据
	if bullet.has_method("set_bullet_data"):
		bullet.set_bullet_data(bullet_data)

	## 设置子弹飞行方向
	bullet.set_direction(direction)
	## 设置子弹所属阵营为"player"（防止误伤玩家）
	bullet.set_owner_group("player")
	## 将子弹添加到管理列表
	_bullets.append(bullet)

	## 连接子弹命中信号：当子弹命中目标时触发回调
	bullet.hit.connect(_on_bullet_hit)
	## 连接子弹销毁信号：当子弹销毁时触发回调（绑定子弹实例）
	bullet.destroyed.connect(_on_bullet_destroyed.bind(bullet))

## 子弹命中目标时的回调（响应bullet.hit信号）
## 参数：bullet - 命中的子弹实例，target - 被命中的目标节点
func _on_bullet_hit(bullet: Area2D, target: Node2D) -> void:
	## 如果目标没有take_damage方法，直接返回
	if not target.has_method("take_damage"):
		return

	## 默认伤害为1
	var damage: int = 1
	## 如果子弹有子弹数据，获取最终伤害值
	if bullet != null and bullet.has_method("get_bullet_data"):
		var bullet_data: BulletDataClass = bullet.get_bullet_data()
		if bullet_data != null:
			damage = bullet_data.get_final_damage()

	## 调用目标的take_damage方法造成伤害
	target.take_damage(damage)

## 子弹销毁时的回调（响应bullet.destroyed信号）
## 参数：bullet - 被销毁的子弹实例
func _on_bullet_destroyed(bullet: Area2D) -> void:
	## 从管理列表中移除子弹
	if bullet in _bullets:
		_bullets.erase(bullet)

## ========== 敌人死亡与掉落 ==========

## 敌人死亡时的回调（响应enemy.killed信号）
## 参数：enemy - 死亡的敌人实例
func _on_enemy_killed(enemy: CharacterBody2D) -> void:
	## 从管理列表中移除敌人
	if enemy in _enemies:
		_enemies.erase(enemy)
		## 减少敌人计数
		_enemy_count -= 1

## 敌人掉落道具时的回调（响应enemy.drops_generated信号）
## 参数：position - 掉落位置，drops - 掉落道具列表
func _on_enemy_drops_generated(position: Vector2, drops: Array) -> void:
	## 遍历所有掉落道具，生成拾取物
	for drop_item in drops:
		if drop_item == null:
			continue
		_spawn_pickup(position, drop_item)

## 生成拾取物
## 参数：position - 生成位置，drop_item - 道具数据资源
func _spawn_pickup(position: Vector2, drop_item: Resource) -> void:
	## 实例化拾取物节点
	var pickup: Area2D = PICKUP_SCENE.instantiate()
	## 将拾取物添加到场景树中
	add_child(pickup)
	## 设置拾取物位置（在掉落位置基础上添加随机偏移）
	pickup.global_position = position + Vector2(
		RandomManager.randf_range(-20, 20),
		RandomManager.randf_range(-20, 20)
	)
	
	## 设置拾取物的道具数据
	if pickup.has_method("set_drop_item"):
		pickup.set_drop_item(drop_item)
	
	## 将拾取物添加到管理列表
	_pickups.append(pickup)
	
	## 连接拾取物移除信号：当拾取物从场景树移除时触发回调（绑定拾取物实例）
	pickup.tree_exiting.connect(_on_pickup_tree_exiting.bind(pickup))

## 拾取物被移除时的回调（响应pickup.tree_exiting信号）
## 参数：pickup - 被移除的拾取物实例
func _on_pickup_tree_exiting(pickup: Area2D) -> void:
	## 从管理列表中移除拾取物
	if pickup in _pickups:
		_pickups.erase(pickup)

## ========== 玩家死亡处理 ==========

## 玩家死亡时的回调（响应player.killed或HealthController.player_died信号）
func _on_player_killed() -> void:
	## 发出游戏结束信号（用于Main.gd处理游戏结束流程）
	game_over.emit()

## ========== 清理方法 ==========

## 清理所有游戏对象（用于场景切换或游戏结束）
func clear_all() -> void:
	## 清理所有敌人
	for enemy in _enemies:
		if enemy.is_inside_tree():
			enemy.queue_free()
	_enemies.clear()
	_enemy_count = 0

	## 清理所有子弹
	for bullet in _bullets:
		if bullet.is_inside_tree():
			bullet.queue_free()
	_bullets.clear()

	## 清理所有拾取物
	for pickup in _pickups:
		if pickup.is_inside_tree():
			pickup.queue_free()
	_pickups.clear()