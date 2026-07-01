## DropItem - 掉落道具资源类
## 定义敌人死亡时可能掉落的道具
## 便于后续扩展：梦境碎片、回血药、武器、词条等
class_name DropItem
extends Resource


## 道具类型枚举
enum ItemType {
	DREAM_FRAGMENT,  # 梦境碎片
	HEALTH,          # 回血
	WEAPON,          # 武器
	ITEM,            # 普通物品
	BUFF             # 增益效果
}


## 道具唯一标识（用于日志、调试和按ID查找）
@export var item_id: String = ""

## 道具名称（用于显示）
@export var item_name: String = ""

## 道具类型
@export var item_type: ItemType = ItemType.DREAM_FRAGMENT

## 道具数值（碎片数量、回血量等）
@export var value: int = 0

## 掉落概率（0.0-1.0）
@export var drop_chance: float = 1.0

## 是否稀有道具（用于特殊显示）
@export var is_rare: bool = false

## 是否自动吸附（碎片、回血等自动飞向玩家）
## 默认：碎片/回血 = 自动吸附；武器/物品/BUFF = 需要手动拾取
@export var auto_adsorb: bool = false


## 获取是否自动吸附（考虑类型默认值）
func get_auto_adsorb() -> bool:
	if auto_adsorb:
		return true
	match item_type:
		ItemType.DREAM_FRAGMENT, ItemType.HEALTH:
			return true
		ItemType.WEAPON, ItemType.ITEM, ItemType.BUFF:
			return false
	return false


## 应用道具效果到目标（默认实现基础效果）
## [param target] 道具应用目标（通常是玩家）
## [return] 是否应用成功
func apply(target: Node2D) -> bool:
	if target == null:
		return false
	
	match item_type:
		ItemType.DREAM_FRAGMENT:
			if target.has_method("add_dream_fragment"):
				target.add_dream_fragment(value)
				return true
		ItemType.HEALTH:
			if target.has_method("heal"):
				target.heal(value)
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