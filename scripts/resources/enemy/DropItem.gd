## DropItem.gd - 掉落道具数据资源类
## 职责：定义敌人死亡时可能掉落的道具数据，实现数据与逻辑分离
## 继承：Resource（Godot资源类，可在编辑器中创建和配置）
## 使用场景：在编辑器中创建 .tres 文件配置道具属性，或通过词条系统动态修改
class_name DropItem
extends Resource

## ========== 道具类型枚举 ==========

enum ItemType {
	DREAM_FRAGMENT,  ## 梦境碎片（自动吸附，积累后用于升级）
	HEALTH,          ## 回血道具（自动吸附，恢复玩家核心血量）
	WEAPON,          ## 武器（需要手动拾取，切换武器类型）
	ITEM,            ## 普通物品（需要手动拾取，用于合成或任务）
	BUFF             ## 增益效果（需要手动拾取，临时或永久提升属性）
}

## ========== 道具基础属性 ==========

## 道具唯一标识（用于日志、调试和按ID查找）
@export var item_id: String = ""

## 道具名称（用于显示）
@export var item_name: String = ""

## 道具类型（决定道具效果和拾取方式）
@export var item_type: ItemType = ItemType.DREAM_FRAGMENT

## 道具数值（根据类型不同含义不同：碎片数量、回血量、增益持续时间等）
@export var value: int = 0

## 掉落概率（0.0-1.0，0表示不会掉落，1表示必定掉落）
@export var drop_chance: float = 1.0

## 是否稀有道具（用于特殊显示效果，如发光、稀有音效）
@export var is_rare: bool = false

## 是否自动吸附（默认false，根据类型自动判断）
@export var auto_adsorb: bool = false

## ========== 核心方法 ==========

## 获取是否自动吸附（考虑类型默认值）
## 碎片和回血默认自动吸附，其他道具默认需要手动拾取
## 返回：true表示自动吸附，false表示需要手动拾取
func get_auto_adsorb() -> bool:
	## 如果显式设置了auto_adsorb，使用设置值
	if auto_adsorb:
		return true
	## 根据道具类型判断默认行为
	match item_type:
		ItemType.DREAM_FRAGMENT, ItemType.HEALTH:
			## 碎片和回血：自动吸附
			return true
		ItemType.WEAPON, ItemType.ITEM, ItemType.BUFF:
			## 武器、物品、BUFF：需要手动拾取
			return false
	return false

## 应用道具效果到目标（默认实现基础效果）
## 参数：target - 道具应用目标（通常是玩家）
## 返回：是否应用成功
func apply(target: Node2D) -> bool:
	if target == null:
		return false
	
	## 根据道具类型执行不同效果
	match item_type:
		ItemType.DREAM_FRAGMENT:
			## 添加梦境碎片（调用玩家的add_dream_fragment方法）
			if target.has_method("add_dream_fragment"):
				target.add_dream_fragment(value)
				return true
		ItemType.HEALTH:
			## 恢复血量（调用玩家的heal方法）
			if target.has_method("heal"):
				target.heal(value)
				return true
		ItemType.BUFF:
			## 添加增益效果（调用玩家的add_buff方法）
			if target.has_method("add_buff"):
				target.add_buff(item_id, value)
				return true
	
	## 未知类型或目标无对应方法，应用失败
	return false

## 根据概率判断是否掉落
## 使用随机数判断是否触发掉落
## 返回：true表示应该掉落，false表示不掉落
func should_drop() -> bool:
	## 概率为1或更高：必定掉落
	if drop_chance >= 1.0:
		return true
	## 概率为0或更低：不会掉落
	if drop_chance <= 0.0:
		return false
	## 使用随机数判断（0-1之间的随机数小于掉落概率则掉落）
	return RandomManager.randf() < drop_chance