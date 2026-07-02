## EnemyData.gd - 敌人数据资源类
## 职责：定义敌人的所有配置数据，实现数据与逻辑分离
## 继承：Resource（Godot资源类，可在编辑器中创建和配置）
## 使用场景：在编辑器中创建 .tres 文件配置不同类型敌人，支持扩展不同敌人属性、掉落、射击配置
class_name EnemyData
extends Resource

## ========== 预加载资源（避免运行时加载延迟） ==========

## 掉落道具数据资源类，用于配置敌人掉落的道具
const DropItemClass = preload("res://scripts/resources/enemy/DropItem.gd")

## 子弹数据资源类，用于配置敌人射击的子弹属性
const BulletDataClass = preload("res://scripts/resources/bullet/BulletData.gd")

## ========== 敌人基础属性 ==========

## 敌人唯一标识（用于日志、调试和按ID查找）
@export var enemy_id: String = ""

## 敌人名称（用于显示）
@export var enemy_name: String = "Enemy"

## 敌人移动速度（追踪玩家时的速度，像素/秒）
@export var speed: float = 100.0

## 敌人自由移动速度（无玩家时的漫游速度，像素/秒）
@export var wander_speed: float = 60.0

## 敌人自由移动方向切换间隔（秒）
@export var wander_interval: float = 2.0

## 敌人最大血量
@export var max_health: int = 5

## 敌人对玩家造成的碰撞伤害（直接接触时的伤害）
@export var damage: int = 10

## ========== 敌人AI属性 ==========

## 敌人检测范围（玩家进入此范围后敌人开始追踪，像素）
@export var detection_range: float = 300.0

## 敌人攻击范围（玩家进入此范围后敌人停止移动并攻击，像素）
@export var attack_range: float = 150.0

## 敌人攻击冷却时间（秒）
@export var attack_cooldown: float = 1.0

## ========== 敌人射击配置 ==========

## 敌人射击子弹配置（决定子弹伤害、速度、形态、特效等）
## 通过此配置可创建不同射击风格的敌人（快枪手、重炮手等）
@export var bullet_data: BulletDataClass = null

## ========== 敌人掉落配置 ==========

## 敌人死亡时可能掉落的道具列表
## 每个道具都有独立的掉落概率，支持多种道具混合掉落
@export var drop_items: Array[DropItemClass] = []

## ========== 敌人外观配置（无美术资源时使用） ==========

## 敌人占位纹理颜色（无美术资源时使用，默认红色）
@export var placeholder_color: Color = Color(1, 0.2, 0.2, 1)

## 敌人占位纹理大小（无美术资源时使用，默认30x30像素）
@export var placeholder_size: Vector2 = Vector2(30, 30)

## ========== 精英怪配置 ==========

## 是否为精英怪（精英怪具有更高属性和特殊外观）
@export var is_elite: bool = false

## 精英怪名称前缀（显示时添加到名称前，如"★ 精英"）
@export var elite_prefix: String = "★"

## ========== 核心方法 ==========

## 获取敌人射击用的子弹数据（带默认值）
## 如果配置了bullet_data则返回配置值，否则创建默认子弹数据
## 返回：子弹配置数据
func get_bullet_data() -> BulletDataClass:
	if bullet_data != null:
		return bullet_data
	## 创建默认子弹数据（使用敌人伤害值作为子弹伤害）
	var default_bullet: BulletDataClass = BulletDataClass.new()
	default_bullet.damage = damage
	default_bullet.speed = 300.0
	return default_bullet

## 生成死亡掉落物（直接应用效果到目标）
## 参数：target - 掉落物应用目标（通常是玩家）
## 返回：实际掉落并应用成功的道具列表
func generate_drops(target: Node2D) -> Array[DropItemClass]:
	var dropped_items: Array[DropItemClass] = []
	
	## 遍历所有可能的掉落道具
	for drop_item in drop_items:
		if drop_item == null:
			continue
		## 根据概率判断是否掉落
		if not drop_item.should_drop():
			continue
		## 应用道具效果到目标
		if drop_item.apply(target):
			dropped_items.append(drop_item)
	
	return dropped_items

## 获取需要生成 PickUp 的掉落列表（只计算概率，不应用效果）
## 与generate_drops的区别：此方法只判断概率并复制道具数据，不直接应用效果
## 返回：实际需要生成PickUp的道具列表（已复制，可独立修改）
func get_drops_to_spawn() -> Array[DropItemClass]:
	var drops_to_spawn: Array[DropItemClass] = []
	
	## 遍历所有可能的掉落道具
	for drop_item in drop_items:
		if drop_item == null:
			continue
		## 根据概率判断是否掉落
		if not drop_item.should_drop():
			continue
		## 复制道具数据（确保每个PickUp独立）
		drops_to_spawn.append(drop_item.duplicate())
	
	return drops_to_spawn

## 应用敌人配置到敌人节点
## 将配置数据中的属性值应用到敌人节点的对应变量
## 参数：enemy_node - 敌人节点
func apply_to_enemy(enemy_node: CharacterBody2D) -> void:
	if enemy_node == null:
		return
	
	## 使用"in"关键字检查属性是否存在，避免运行时错误
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