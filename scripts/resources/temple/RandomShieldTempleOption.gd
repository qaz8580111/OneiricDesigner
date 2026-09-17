## RandomShieldTempleOption.gd - 神庙选项：随机护盾强化（赌博式）
## 职责：将当前装备护盾的叠层 +1~3 层（突破3层上限，理论最高6层）
## 赌博性：强化层数 1~3 随机——可能 +3 层直接质变（血赚），也可能 +1 层聊胜于无（血亏）
## 继承：TempleOption（策略模式子类，路径式继承避免依赖全局类缓存刷新）
## 数据流：apply() → player.boost_shield_stack(1~3) → EquipmentShieldComponent.add_stack()
## 变更说明（2026-09-17）：旧实现为扫描 data/equipment/ 随机替换一件护盾，已按需求废弃；
##         新实现不再随机换装，改为"随机强化当前护盾等级"
class_name RandomShieldTempleOption
extends "res://scripts/resources/temple/TempleOption.gd"

## 重写：随机强化当前护盾 1~3 层（突破3层上限）
func apply(player: Node) -> bool:
	if player == null or not player.has_method("boost_shield_stack"):
		return false
	## 强化层数 1~3 随机
	var boost: int = RandomManager.randi_range(1, 3)
	## 无装备护盾时返回 false（神庙保留不消失）
	return player.boost_shield_stack(boost)
