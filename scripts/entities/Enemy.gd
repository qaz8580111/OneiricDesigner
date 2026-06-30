extends CharacterBody2D

## 敌人移动速度
@export var speed: float = 100.0

## 敌人最大血量（默认 5，配合子弹默认伤害 1，需命中 5 次）
@export var max_health: int = 5

## 当前血量，运行时会自动初始化为 max_health
@export var health: int = 5

## 敌人对玩家造成的碰撞伤害
@export var damage: int = 10

## 死亡时掉落经验值
@export var exp_reward: int = 20

@onready var sprite: Sprite2D = $Sprite2D
@onready var hitbox: Area2D = $Hitbox

## 玩家引用（缓存避免每帧查找）
var _player: CharacterBody2D = null

## 原始颜色（用于受击闪烁后恢复）
var _original_color: Color = Color.WHITE

signal killed()
signal damaged(amount: int)


func _ready() -> void:
	# 确保当前血量不超过最大血量
	health = max_health
	_create_placeholder_texture(sprite, Color(1, 0.2, 0.2, 1), 30, 30)
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
	killed.emit()
	queue_free()


## 与玩家碰撞时调用
func on_player_collision(player: Node2D) -> void:
	if player.has_method("take_damage"):
		player.take_damage(damage)


func _on_hitbox_body_entered(body: Node2D) -> void:
	if body.is_in_group("player"):
		on_player_collision(body)
