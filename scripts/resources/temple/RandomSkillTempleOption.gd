## RandomSkillTempleOption.gd - 神庙选项：随机技能（赌博式）
## 职责：从 UpgradeManager 的词条池中随机抽取一条词条并应用
## 赌博性：完全随机——可能抽到史诗词条（血赚），也可能抽到普通词条甚至满层的废话（血亏）
## 继承：TempleOption（策略模式子类，路径式继承避免依赖全局类缓存刷新）
## 数据流：apply() → UpgradeManager.get_random_upgrade() → UpgradeManager.apply_upgrade()
##         → player_stats 累积 → upgrade_applied 信号 → Player._sync_upgrade_stats 生效
class_name RandomSkillTempleOption
extends "res://scripts/resources/temple/TempleOption.gd"

## 重写：随机应用一条升级词条
func apply(_player: Node) -> bool:
	var upgrade: Resource = UpgradeManager.get_random_upgrade()
	if upgrade == null:
		return false
	## 复用现有词条应用管线（统计/音效/信号/属性累积全部自动处理）
	UpgradeManager.apply_upgrade(upgrade)
	return true
