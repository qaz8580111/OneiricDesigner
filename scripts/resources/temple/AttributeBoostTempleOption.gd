## AttributeBoostTempleOption.gd - 神庙选项：强化属性
## 职责：随机选中一个已拥有的"属性类"词条（纯数值加成），将其等级 +1 级
##       （突破5级上限）；只针对属性类，不包含技能类
## 继承：TempleOption（策略模式子类，路径式继承避免依赖全局类缓存刷新）
## 数据流：apply() → 预检查/扣累加碎片 → UpgradeManager.boost_random_attribute(1)
## 变更说明（2026-09-18）：由旧"强化伤害/生命上限"两个稳妥式选项合并而来，
##         新效果不再是固定数值加成，而是"随机强化已拥有属性类技能 +1 级并可突破上限"
## 变更说明（2026-09-19）：接入神庙碎片累加消耗（具体数值见 UpgradeManager 的 TEMPLE_BOOST_* 常量）
class_name AttributeBoostTempleOption
extends "res://scripts/resources/temple/TempleOption.gd"

## 重写：随机强化一个已拥有的属性类词条 +1 级（突破5级上限）
## 前置校验：无已拥有属性词条或碎片不足时返回 false（神庙保留不消失）
func apply(player: Node) -> bool:
	if player == null or not player.has_method("spend_dream_fragment"):
		return false
	## 无可强化属性时直接失败（不扣碎片）
	if not UpgradeManager.has_boostable_attribute():
		return false
	## 扣除本次累加碎片（成功后才递增强化计数）
	if not UpgradeManager.consume_temple_boost(player):
		return false
	## 固定 +1 级（可突破5级上限）
	return UpgradeManager.boost_random_attribute(1)

## 重写：本次消耗的碎片数 = 神庙强化累加计价（起步价/增量见 UpgradeManager.TEMPLE_BOOST_* 常量）
func get_cost(_player: Node) -> int:
	return UpgradeManager.get_temple_boost_cost()
