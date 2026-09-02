## StatBoostTempleOption.gd - 神庙选项：属性强化（稳妥式）
## 职责：按配置的 stat_modifiers 字典小幅强化玩家属性
## 稳妥性：效果固定可预期（如伤害+10%、生命上限+20），无随机成分
## 继承：TempleOption（策略模式子类，路径式继承避免依赖全局类缓存刷新）
## 数据驱动：一个子类覆盖两种稳妥选项——
##   伤害强化：stat_modifiers = {"damage_mult": 0.1}
##   生命上限：stat_modifiers = {"max_hp_bonus": 20}
## 数据流：apply() → 构造临时 UpgradeData → UpgradeManager.apply_upgrade()
##         → player_stats 累积 → upgrade_applied 信号 → Player 生效
class_name StatBoostTempleOption
extends "res://scripts/resources/temple/TempleOption.gd"

## 属性修改字典（键名与 UpgradeData.stat_modifiers 约定一致）：
##   damage_mult（伤害乘算增量）/ max_hp_bonus（生命上限加值）
##   / fire_rate_mult / move_speed_mult / bullet_speed_mult
@export var stat_modifiers: Dictionary = {}

## 重写：构造临时词条并走现有应用管线
func apply(_player: Node) -> bool:
	if stat_modifiers.is_empty():
		return false

	## 构造临时 UpgradeData（不入词条池，仅作为应用载体）
	var UpgradeDataClass = load("res://scripts/resources/upgrade/UpgradeData.gd")
	var upgrade: Resource = UpgradeDataClass.new()
	upgrade.upgrade_id = "temple_" + option_id
	upgrade.display_name = display_name
	upgrade.description = description
	upgrade.stat_modifiers = stat_modifiers.duplicate()

	## 复用现有应用管线（统计/音效/信号/属性累积全部自动处理）
	UpgradeManager.apply_upgrade(upgrade)
	return true
