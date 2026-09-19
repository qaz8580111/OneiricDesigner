## RandomShieldTempleOption.gd - 神庙选项：强化护盾（赌博式）
## 职责：将当前装备护盾的叠层 +1 层（突破3层上限，不封顶）
## 赌博性：仅在"是否装备护盾"这一前提上赌博——未装备护盾时该强化无意义
## 继承：TempleOption（策略模式子类，路径式继承避免依赖全局类缓存刷新）
## 数据流：apply() → 预检查已装备护盾/扣累加碎片 → player.boost_shield_stack(1)
## 变更说明（2026-09-18）：选项更名"强化护盾"（原"随机护盾"），效果逻辑不变
## 变更说明（2026-09-19）：强化层数由 1~3 随机改为固定 +1 层，并接入神庙碎片累加消耗
class_name RandomShieldTempleOption
extends "res://scripts/resources/temple/TempleOption.gd"

## 重写：强化当前装备护盾 +1 层（突破3层上限，不封顶）
## 前置校验：未装备护盾或碎片不足时返回 false（神庙保留不消失）
func apply(player: Node) -> bool:
	if player == null or not player.has_method("boost_shield_stack"):
		return false
	## 未装备护盾时直接失败（不扣碎片）
	if player.has_method("has_equipped_shield") and not player.has_equipped_shield():
		return false
	## 扣除本次累加碎片（成功后才递增强化计数）
	if not UpgradeManager.consume_temple_boost(player):
		return false
	## 固定 +1 层（可突破3层上限，不封顶）
	return player.boost_shield_stack(1)

## 重写：本次消耗的碎片数 = 神庙强化累加计价（第1次2000、第2次2500……）
func get_cost(_player: Node) -> int:
	return UpgradeManager.get_temple_boost_cost()
