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
	DREAM_FRAGMENT,  ## 梦境碎片（自动吸附，纯收集计数：HUD 显示 + 结算统计 + 商店支付）
	HEALTH,          ## 回血道具（自动吸附，恢复玩家核心血量）
	WEAPON,          ## 武器（需要手动拾取，切换武器类型）
	ITEM,            ## 普通物品（需要手动拾取，用于合成或任务）
	EQUIPMENT        ## 装备（需要手动按E拾取；拾取后直接放入背包，由玩家在背包/装备面板中穿戴）
	                 ## 四大成长维度（基础属性/特效/护盾/弹道构型）已聚合进装备，不设独立掉落类型
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

## 装备数据引用（ItemType.EQUIPMENT 使用，指向 EquipmentData 装备实例）
## 由掉落源（Enemy/Boss/精英）通过 UpgradeManager.generate_equipment() 生成后挂载；
## 拾取时经 Player.add_equipment_to_backpack() 直接放入背包
@export var equipment_data: Resource = null

## ========== 核心方法 ==========

## 获取是否自动吸附（考虑类型默认值）
## 碎片和回血默认自动吸附，武器、物品、装备需要手动拾取（按E键）
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
		ItemType.WEAPON, ItemType.ITEM, ItemType.EQUIPMENT:
			## 武器、物品、装备：需要手动拾取
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
		ItemType.EQUIPMENT:
			## 装备：直接放入玩家背包（不弹面板），由玩家在背包/装备面板中自行穿戴
			## 四大成长维度（属性/特效/护盾/弹道构型）已聚合进装备，故拾取即"获得一件成长载体"
			## 返回 false（背包已满/组件缺失）时拾取物保留在原地，玩家可稍后重试
			if equipment_data != null and target.has_method("add_equipment_to_backpack"):
				return target.add_equipment_to_backpack(equipment_data)
	
	## 未知类型或目标无对应方法，应用失败
	return false

## 根据概率判断是否掉落
## 使用随机数判断是否触发掉落
## 返回：true表示应该掉落，false表示不掉落
func should_drop() -> bool:
	## 概率为1或更高：必定掉落（保底掉落不受难度模式影响，保证 Boss 奖励等核心收益）
	if drop_chance >= 1.0:
		return true
	## 概率为0或更低：不会掉落
	if drop_chance <= 0.0:
		return false
	## 难度模式掉率修正：困难/专家按 HARD_DROP_MULT 下调概率（用户规则"爆率适当下降"），
	## 普通档系数恒为 1.0 → 完全沿用既有逻辑（需求：普通就按照当前逻辑和数值）
	var effective_chance: float = drop_chance
	if DifficultyManager != null:
		effective_chance = clampf(drop_chance * DifficultyManager.get_mode_drop_mult(), 0.0, 1.0)
	## 使用随机数判断（0-1之间的随机数小于掉落概率则掉落）
	return RandomManager.randf() < effective_chance