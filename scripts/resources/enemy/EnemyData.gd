## EnemyData - 敌人数据资源类
## 定义敌人的所有配置数据，实现数据与逻辑分离
## 便于后续扩展：不同类型敌人、不同经验奖励、不同掉落道具
class_name EnemyData
extends Resource


## 预加载相关资源类型
const DropItemClass = preload("res://scripts/resources/enemy/DropItem.gd")


## 敌人唯一标识（用于日志、调试和按ID查找）
@export var enemy_id: String = ""

## 敌人名称（用于显示）
@export var enemy_name: String = "Enemy"

## 敌人移动速度
@export var speed: float = 100.0

## 敌人最大血量
@export var max_health: int = 5

## 敌人对玩家造成的碰撞伤害
@export var damage: int = 10

## 敌人死亡时给予的基础经验值
@export var exp_reward: int = 20

## 敌人死亡时可能掉落的道具列表
## 每个道具都有独立的掉落概率
@export var drop_items: Array[DropItemClass] = []

## 敌人占位纹理颜色（无美术资源时使用）
@export var placeholder_color: Color = Color(1, 0.2, 0.2, 1)

## 敌人占位纹理大小（无美术资源时使用）
@export var placeholder_size: Vector2 = Vector2(30, 30)


## 获取实际经验值奖励
## 后续升级/词条系统可继承 EnemyData 重写此方法
func get_final_exp_reward() -> int:
	return exp_reward


## 生成死亡掉落物
## [param target] 掉落物应用目标（通常是玩家）
## [return] 实际掉落并应用成功的道具列表
func generate_drops(target: Node2D) -> Array[DropItemClass]:
	var dropped_items: Array[DropItemClass] = []
	
	for drop_item in drop_items:
		if drop_item == null:
			continue
		# 根据概率判断是否掉落
		if not drop_item.should_drop():
			continue
		# 应用道具效果
		if drop_item.apply(target):
			dropped_items.append(drop_item)
	
	return dropped_items


## 应用敌人配置到敌人生成参数
## [param enemy_node] 敌人节点
func apply_to_enemy(enemy_node: CharacterBody2D) -> void:
	if enemy_node == null:
		return
	
	if "speed" in enemy_node:
		enemy_node.speed = speed
	if "max_health" in enemy_node:
		enemy_node.max_health = max_health
	if "damage" in enemy_node:
		enemy_node.damage = damage