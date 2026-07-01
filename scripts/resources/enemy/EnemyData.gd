## EnemyData - 敌人数据资源类
## 定义敌人的所有配置数据，实现数据与逻辑分离
## 便于后续扩展：不同类型敌人、不同掉落道具、不同射击配置
class_name EnemyData
extends Resource


## 预加载相关资源类型
const DropItemClass = preload("res://scripts/resources/enemy/DropItem.gd")
const BulletDataClass = preload("res://scripts/resources/bullet/BulletData.gd")


## 敌人唯一标识（用于日志、调试和按ID查找）
@export var enemy_id: String = ""

## 敌人名称（用于显示）
@export var enemy_name: String = "Enemy"

## 敌人移动速度（追踪玩家时的速度）
@export var speed: float = 100.0

## 敌人自由移动速度（无玩家时的漫游速度）
@export var wander_speed: float = 60.0

## 敌人自由移动方向切换间隔（秒）
@export var wander_interval: float = 2.0

## 敌人最大血量
@export var max_health: int = 5

## 敌人对玩家造成的碰撞伤害（直接接触时的伤害）
@export var damage: int = 10

## 敌人检测范围（玩家进入此范围后敌人开始追踪）
@export var detection_range: float = 300.0

## 敌人攻击范围（玩家进入此范围后敌人停止移动并攻击）
@export var attack_range: float = 150.0

## 敌人攻击冷却时间（秒）
@export var attack_cooldown: float = 1.0

## 敌人射击子弹配置（决定子弹伤害、速度、形态、特效等）
## 通过此配置可创建不同射击风格的敌人
@export var bullet_data: BulletDataClass = null

## 敌人死亡时可能掉落的道具列表
## 每个道具都有独立的掉落概率
@export var drop_items: Array[DropItemClass] = []

## 敌人占位纹理颜色（无美术资源时使用）
@export var placeholder_color: Color = Color(1, 0.2, 0.2, 1)

## 敌人占位纹理大小（无美术资源时使用）
@export var placeholder_size: Vector2 = Vector2(30, 30)


## 获取敌人射击用的子弹数据（带默认值）
## [return] 子弹配置数据
func get_bullet_data() -> BulletDataClass:
	if bullet_data != null:
		return bullet_data
	var default_bullet: BulletDataClass = BulletDataClass.new()
	default_bullet.damage = damage
	default_bullet.speed = 300.0
	return default_bullet


## 生成死亡掉落物（直接应用效果）
## [param target] 掉落物应用目标（通常是玩家）
## [return] 实际掉落并应用成功的道具列表
func generate_drops(target: Node2D) -> Array[DropItemClass]:
	var dropped_items: Array[DropItemClass] = []
	
	for drop_item in drop_items:
		if drop_item == null:
			continue
		if not drop_item.should_drop():
			continue
		if drop_item.apply(target):
			dropped_items.append(drop_item)
	
	return dropped_items


## 获取需要生成 PickUp 的掉落列表（只计算概率，不应用效果）
## [return] 实际需要生成 PickUp 的道具列表
func get_drops_to_spawn() -> Array[DropItemClass]:
	var drops_to_spawn: Array[DropItemClass] = []
	
	for drop_item in drop_items:
		if drop_item == null:
			continue
		if not drop_item.should_drop():
			continue
		drops_to_spawn.append(drop_item.duplicate())
	
	return drops_to_spawn


## 应用敌人配置到敌人生成参数
## [param enemy_node] 敌人节点
func apply_to_enemy(enemy_node: CharacterBody2D) -> void:
	if enemy_node == null:
		return
	
	if "speed" in enemy_node:
		enemy_node.speed = speed
	if "wander_speed" in enemy_node:
		enemy_node.wander_speed = wander_speed
	if "wander_interval" in enemy_node:
		enemy_node.wander_interval = wander_interval
	if "max_health" in enemy_node:
		enemy_node.max_health = max_health
	if "damage" in enemy_node:
		enemy_node.damage = damage
	if "detection_range" in enemy_node:
		enemy_node.detection_range = detection_range
	if "attack_range" in enemy_node:
		enemy_node.attack_range = attack_range
	if "attack_cooldown" in enemy_node:
		enemy_node.attack_cooldown = attack_cooldown