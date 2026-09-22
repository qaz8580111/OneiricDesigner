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
	BUFF,            ## 特效技能书（需要手动按E拾取；拾取后打开"特效技能"三选一面板）
	EQUIPMENT,       ## 装备护盾（需要手动按E拾取；拾取后打开护盾三选一面板，由玩家自选一件护盾）
	ATTRIBUTE_SKILL, ## 属性技能书（需要手动按E拾取；拾取后打开"属性技能"三选一面板）
	SHOT_PATTERN     ## 弹道构型书（需要手动按E拾取；拾取后打开"弹道构型"三选一面板）
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
## 注意：改造后仅作"这是一件护盾装备"的标记——地面掉落阶段不再直接装备该数据，
##       具体护盾由拾取后的护盾三选一（UpgradeManager.open_shield_choice）随机3选1决定
## 扩展：未来新增武器/饰品等装备类型时，可增加对应的装备数据字段
@export var shield_equipment: Resource = null

## ========== 核心方法 ==========

## 获取是否自动吸附（考虑类型默认值）
## 碎片和回血默认自动吸附，武器、物品、技能书/属性技能书/弹道构型书需要手动拾取（按E键）
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
		ItemType.WEAPON, ItemType.ITEM, ItemType.BUFF, ItemType.EQUIPMENT, \
		ItemType.ATTRIBUTE_SKILL, ItemType.SHOT_PATTERN:
			## 武器、物品、三类技能/构型书、装备：需要手动拾取
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
			## 特效技能书：交给玩家 add_buff → UpgradeManager.open_level_up_choice
			## 打开"特效技能三选一"面板由玩家自选词条（只含特效技能，不含属性技能）
			if target.has_method("add_buff"):
				target.add_buff(item_id, value)
				return true
		ItemType.ATTRIBUTE_SKILL:
			## 属性技能书：交给玩家 request_attribute_skill_choice →
			## UpgradeManager.open_attribute_skill_choice，打开"属性技能三选一"面板
			## （只含属性技能，与特效技能掉落完全分离，体验同技能书）
			if target.has_method("request_attribute_skill_choice"):
				target.request_attribute_skill_choice()
				return true
		ItemType.SHOT_PATTERN:
			## 弹道构型书：交给玩家 request_shot_pattern_choice →
			## UpgradeManager.open_shot_pattern_choice，打开"弹道构型三选一"面板
			## （只含弹道构型；选定后直接替换玩家当前弹道，不叠层）
			if target.has_method("request_shot_pattern_choice"):
				target.request_shot_pattern_choice()
				return true
		ItemType.EQUIPMENT:
			## 装备护盾：交给玩家 request_shield_choice → UpgradeManager.open_shield_choice，
			## 打开"护盾三选一"面板由玩家自选一件护盾（与技能书 add_buff 同款体验）。
			## 说明：掉落物携带的 shield_equipment 仅作"这是一件护盾装备"的标记，
			##       面板的3个候选由 UpgradeManager 从 data/equipment/ 随机抽取，
			##       玩家选定后才真正调用 Player.equip_shield（叠层/替换逻辑不变）
			if shield_equipment != null and target.has_method("request_shield_choice"):
				target.request_shield_choice()
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