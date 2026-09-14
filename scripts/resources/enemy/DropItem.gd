## DropItem.gd - 掉落道具数据资源类
## 职责：定义敌人死亡时可能掉落的道具数据，实现数据与逻辑分离
## 继承：Resource（Godot资源类，可在编辑器中创建和配置）
## 使用场景：在编辑器中创建 .tres 文件配置道具属性，或通过词条系统动态修改
## 被引用方：EnemyData.drop_items（敌人掉落配置）、PickUp（持有并展示/拾取）、
##           EnemyData.generate_drops()/get_drops_to_spawn()（掉落判定与生成）
## 数据流：敌人死亡 → 概率判定should_drop() → 生成PickUp挂载DropItem数据 → 拾取时apply()生效
class_name DropItem
extends Resource

## ========== 道具类型枚举 ==========

enum ItemType {
	DREAM_FRAGMENT,  ## 梦境碎片（自动吸附，积累后用于升级）
	HEALTH,          ## 回血道具（自动吸附，恢复玩家核心血量）
	WEAPON,          ## 武器（需要手动拾取，切换武器类型）
	ITEM,            ## 普通物品（需要手动拾取，用于合成或任务）
	BUFF,            ## 技能书（需要手动按E拾取；拾取后打开三选一升级面板，由玩家自选词条）
	EQUIPMENT        ## 装备（需要手动拾取，护盾等装备类型）
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

## 装备数据引用（ItemType.EQUIPMENT 时使用，指向 ShieldEquipmentData 等装备资源）
## 扩展：未来新增武器/饰品等装备类型时，可增加对应的装备数据字段
@export var shield_equipment: Resource = null

## ========== 核心方法 ==========

## 获取是否自动吸附（考虑类型默认值）
## 碎片和回血默认自动吸附，武器、物品、BUFF需要手动拾取（按E键）
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
		ItemType.WEAPON, ItemType.ITEM, ItemType.BUFF, ItemType.EQUIPMENT:
			## 武器、物品、BUFF、装备：需要手动拾取
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
			## 技能书：交给玩家 add_buff → UpgradeManager.open_level_up_choice
			## 打开"三选一"升级面板由玩家自选词条（不是随机直接发放）
			if target.has_method("add_buff"):
				target.add_buff(item_id, value)
				return true
		ItemType.EQUIPMENT:
			## 装备护盾（调用玩家的equip_shield方法，传入护盾数据）
			if shield_equipment != null and target.has_method("equip_shield"):
				target.equip_shield(shield_equipment)
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