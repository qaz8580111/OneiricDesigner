## EquipmentAffixTempleOption.gd - 神庙选项：强化装备属性
## 职责：随机选中一件已穿戴装备上的一条词条（纯数值加成），将其数值放大约 20%
## 继承：TempleOption（策略模式子类，路径式继承避免依赖全局类缓存刷新）
## 数据流：apply() → 预检查/扣累加碎片 → UpgradeManager.boost_random_equipment_affix()
## 设计说明：装备化重构后，原"强化属性词条等级"改为直接强化已穿戴装备的词条数值，
##         强化目标随机——可能点到关键装备，也可能点到次要装备
class_name EquipmentAffixTempleOption
extends "res://scripts/resources/temple/TempleOption.gd"

## 重写：随机强化一件已穿戴装备的一条词条（数值 ×(1+EQUIPMENT_BOOST_RATIO)）
## 前置校验：无已穿戴词条或碎片不足时返回 false（神庙保留不消失）
func apply(player: Node) -> bool:
	if player == null or not player.has_method("spend_dream_fragment"):
		return false
	## 无已穿戴装备词条时直接失败（不扣碎片）
	if not UpgradeManager.has_boostable_equipment_affix():
		return false
	## 扣除本次累加碎片（成功后才递增强化计数）
	if not UpgradeManager.consume_temple_boost(player):
		return false
	## 执行强化（内部随机选一条词条并放大数值）
	return UpgradeManager.boost_random_equipment_affix()

## 重写：本次消耗的碎片数 = 神庙强化累加计价（起步价/增量见 UpgradeManager.TEMPLE_BOOST_* 常量）
func get_cost(_player: Node) -> int:
	return UpgradeManager.get_temple_boost_cost()
