## RandomSkillTempleOption.gd - 神庙选项：随机技能强化（赌博式）
## 职责：随机选中一个已拥有技能，将其等级 +1~3 级（突破5级上限，理论最高8级）
## 赌博性：强化目标随机、强化等级 1~3 随机——可能点到关键史诗技能 +3 级（血赚），
##         也可能点到鸡肋技能 +1 级（血亏）
## 继承：TempleOption（策略模式子类，路径式继承避免依赖全局类缓存刷新）
## 数据流：apply() → UpgradeManager.boost_random_skill(1~3) → 随机抽已拥有技能逐级成长
## 变更说明（2026-09-17）：旧实现为 open_level_up_choice() 三选一给新词条，已按需求废弃；
##         新实现不再给新技能、不再弹面板，改为"随机强化已有技能等级"
class_name RandomSkillTempleOption
extends "res://scripts/resources/temple/TempleOption.gd"

## 重写：随机强化一个已拥有技能 1~3 级（突破5级上限）
func apply(_player: Node) -> bool:
	## 强化等级 1~3 随机
	var boost: int = RandomManager.randi_range(1, 3)
	## 交给 UpgradeManager 随机挑选已拥有技能并叠加等级；
	## 无已拥有技能时返回 false（神庙保留不消失）
	return UpgradeManager.boost_random_skill(boost)
