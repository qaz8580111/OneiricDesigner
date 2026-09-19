## RandomSkillTempleOption.gd - 神庙选项：强化技能（赌博式）
## 职责：随机选中一个已拥有的"技能类"词条（子弹特效），将其等级 +1 级
##       （突破5级上限，不封顶）；只针对技能类，不包含属性类
## 赌博性：强化目标随机——可能点到关键史诗技能（血赚），也可能点到鸡肋技能（血亏）
## 继承：TempleOption（策略模式子类，路径式继承避免依赖全局类缓存刷新）
## 数据流：apply() → 预检查/扣累加碎片 → UpgradeManager.boost_random_skill(1)
## 变更说明（2026-09-18）：选项更名"强化技能"；效果由"随机强化任意技能"收紧为
##         "只强化技能类（特效词条）"，属性类交由"强化属性"选项单独处理
## 变更说明（2026-09-19）：强化幅度由 1~3 级改为固定 +1 级，并接入神庙碎片累加消耗
class_name RandomSkillTempleOption
extends "res://scripts/resources/temple/TempleOption.gd"

## 重写：随机强化一个已拥有的技能类词条 +1 级（突破5级上限，不封顶）
## 前置校验：无已拥有特效技能或碎片不足时返回 false（神庙保留不消失）
func apply(player: Node) -> bool:
	if player == null or not player.has_method("spend_dream_fragment"):
		return false
	## 无可强化技能时直接失败（不扣碎片）
	if not UpgradeManager.has_boostable_skill():
		return false
	## 扣除本次累加碎片（成功后才递增强化计数）
	if not UpgradeManager.consume_temple_boost(player):
		return false
	## 固定 +1 级（可突破5级上限，不封顶）
	return UpgradeManager.boost_random_skill(1)

## 重写：本次消耗的碎片数 = 神庙强化累加计价（第1次2000、第2次2500……）
func get_cost(_player: Node) -> int:
	return UpgradeManager.get_temple_boost_cost()
