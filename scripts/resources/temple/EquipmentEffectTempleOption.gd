## EquipmentEffectTempleOption.gd - 神庙选项：强化装备特效（赌博式）
## 职责：随机选中一件已穿戴装备上的一个特效（子弹特效），将其叠层 +1 层
## 赌博性：强化目标随机——可能点到关键史诗特效（血赚），也可能点到鸡肋特效（血亏）
## 继承：TempleOption（策略模式子类，路径式继承避免依赖全局类缓存刷新）
## 数据流：apply() → 预检查/扣累加碎片 → UpgradeManager.boost_random_equipment_effect()
## 设计说明：装备化重构后，原"强化技能类词条等级"改为直接强化已穿戴装备的特效叠层
class_name EquipmentEffectTempleOption
extends "res://scripts/resources/temple/TempleOption.gd"

## 重写：随机强化一件已穿戴装备的一个特效（叠层 +1，触发 _on_stack_grown 参数放大）
## 前置校验：无已穿戴装备特效或碎片不足时返回 false（神庙保留不消失）
func apply(player: Node) -> bool:
	if player == null or not player.has_method("spend_dream_fragment"):
		return false
	## 无已穿戴装备特效时直接失败（不扣碎片）
	if not UpgradeManager.has_boostable_equipment_effect():
		return false
	## 扣除本次累加碎片（成功后才递增强化计数）
	if not UpgradeManager.consume_temple_boost(player):
		return false
	## 执行强化（内部随机选一个特效并叠层 +1）
	return UpgradeManager.boost_random_equipment_effect()

## 重写：本次消耗的碎片数 = 神庙强化累加计价（起步价/增量见 UpgradeManager.TEMPLE_BOOST_* 常量）
func get_cost(_player: Node) -> int:
	return UpgradeManager.get_temple_boost_cost()
