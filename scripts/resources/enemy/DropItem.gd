## DropItem - 掉落道具资源类
## 定义敌人死亡时可能掉落的道具
## 便于后续扩展：金币、回血药、武器、词条等
class_name DropItem
extends Resource


## 道具类型枚举
enum ItemType {
	GOLD,        # 金币
	HEALTH,      # 回血
	WEAPON,      # 武器
	ITEM,        # 普通物品
	BUFF,        # 增益效果
	EXPERIENCE   # 额外经验
}


## 道具唯一标识（用于日志、调试和按ID查找）
@export var item_id: String = ""

## 道具名称（用于显示）
@export var item_name: String = ""

## 道具类型
@export var item_type: ItemType = ItemType.GOLD

## 道具数值（金币数量、回血量、经验值等）
@export var value: int = 0

## 掉落概率（0.0-1.0）
@export var drop_chance: float = 1.0

## 是否稀有道具（用于特殊显示）
@export var is_rare: bool = false


## 应用道具效果到目标（默认实现基础效果）
## [param target] 道具应用目标（通常是玩家）
## [return] 是否应用成功
func apply(target: Node2D) -> bool:
	if target == null:
		return false
	
	match item_type:
		ItemType.GOLD:
			if target.has_method("add_gold"):
				target.add_gold(value)
				return true
		ItemType.HEALTH:
			if target.has_method("heal"):
				target.heal(value)
				return true
		ItemType.EXPERIENCE:
			if target.has_method("add_exp"):
				target.add_exp(value)
				return true
		ItemType.BUFF:
			if target.has_method("add_buff"):
				target.add_buff(item_id, value)
				return true
	
	return false


## 根据概率判断是否掉落
## [return] 是否应该掉落
func should_drop() -> bool:
	if drop_chance >= 1.0:
		return true
	if drop_chance <= 0.0:
		return false
	return RandomManager.randf() < drop_chance