extends CharacterBody2D

## 预加载敌人数据资源类型
const EnemyDataClass = preload("res://scripts/resources/enemy/EnemyData.gd")

## 敌人数据资源（包含经验、掉落等配置）
@export var enemy_data: EnemyDataClass = null

## 敌人移动速度（若未配置 enemy_data，使用此值）
@export var speed: float = 100.0

## 敌人最大血量（若未配置 enemy_data，使用此值）
@export var max_health: int = 5

## 当前血量，运行时会自动初始化为 max_health
@export var health: int = 5

## 敌人对玩家造成的碰撞伤害（若未配置 enemy_data，使用此值）
@export var damage: int = 10

@onready var sprite: Sprite2D = $Sprite2D
@onready var hitbox: Area2D = $Hitbox

## 玩家引用（缓存避免每帧查找）
var _player: CharacterBody2D = null

## 原始颜色（用于受击闪烁后恢复）
var _original_color: Color = Color.WHITE

signal killed(exp_reward: int)
signal damaged(amount: int)


func _ready() -> void:
	# 如果配置了 enemy_data，应用配置到敌人参数
	if enemy_data != null:
		enemy_data.apply_to_enemy(self)
	
	# 确保当前血量不超过最大血量
	health = max_health
	
	# 根据 enemy_data 或默认值创建占位纹理
	var color: Color = Color(1, 0.2, 0.2, 1)
	var width: int = 30
	var height: int = 30
	if enemy_data != null:
		color = enemy_data.placeholder_color
		width = int(enemy_data.placeholder_size.x)
		height = int(enemy_data.placeholder_size.y)
	_create_placeholder_texture(sprite, color, width, height)
	
	# 保存原始颜色，用于受击闪烁后恢复
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


## 受到伤害接口
## [param amount] 伤害数值
func take_damage(amount: int) -> void:
	if amount <= 0:
		return

	health -= amount
	health = max(health, 0)
	damaged.emit(amount)

	# 受击视觉反馈：短暂变白闪烁
	_flash_hit()

	if health <= 0:
		_die()


## 受击闪烁反馈
func _flash_hit() -> void:
	if sprite == null:
		return

	# 简单闪烁：变白后 0.1 秒恢复
	sprite.modulate = Color.WHITE
	await get_tree().create_timer(0.1).timeout
	# 敌人可能已在等待期间被销毁，需检查有效性
	if is_instance_valid(sprite):
		sprite.modulate = _original_color


## 敌人死亡
func _die() -> void:
	# 获取经验奖励（优先从 enemy_data 获取）
	var exp_reward: int = 20
	if enemy_data != null:
		exp_reward = enemy_data.get_final_exp_reward()
	
	# 如果存在玩家，直接给予经验和掉落道具
	if _player != null:
		# 直接加经验
		if _player.has_method("add_exp"):
			_player.add_exp(exp_reward)
		
		# 生成并应用掉落道具
		if enemy_data != null:
			enemy_data.generate_drops(_player)
	
	# 发出死亡信号，传递经验奖励（供 GameWorld 统计）
	killed.emit(exp_reward)
	queue_free()


## 与玩家碰撞时调用
func on_player_collision(player: Node2D) -> void:
	if player.has_method("take_damage"):
		player.take_damage(damage)


func _on_hitbox_body_entered(body: Node2D) -> void:
	if body.is_in_group("player"):
		on_player_collision(body)
