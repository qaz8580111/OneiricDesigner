## EnhanceEquipmentTempleOption.gd - 神庙「强化装备」选项
## 职责：随机强化一件已装备装备的某一类数值（属性/被动/主动/护盾任选其一），并把结果写回反馈文本
## 继承：TempleOption（数据驱动，对应 data/temple/option_enhance_equipment.tres）
## 设计意图：
##   1. 强化实现全部收敛到 UpgradeManager（_collect_enhance_candidates 把四类目标统一成同构候选），
##      本类只负责"预检查 → 扣费 → 调用 → 回传反馈"这条策略链，便于后续扩展新的强化口径
##   2. 结果随机 → 必须通过 result_message 回传"哪件装备被强化成了什么"，
##      由 Temple 读出并交给 TemplePanel 结果视图展示（否则玩家不知道强化了什么）
##   3. 碎片沿用累加计价（UpgradeManager.get_temple_boost_cost），与既有神庙强化口径一致
## 被引用方：Temple 扫描 data/temple/*.tres 加载，TemplePanel 展示，Temple 调用 apply()
class_name EnhanceEquipmentTempleOption
extends "res://scripts/resources/temple/TempleOption.gd"

## 应用强化：预检查 → 扣碎片 → 随机强化 → 写入结果反馈
## 参数：player - 玩家节点
## 返回：true=强化成功（神庙消失）；false=失败（神庙保留可重试）
func apply(player: Node) -> bool:
	if player == null:
		return false
	## 没有任何可强化的已装备装备：直接失败（面板已置灰，此处为双保险）
	if not UpgradeManager.has_enhanceable_equipped():
		return false
	## 先扣碎片：成功即累加计价计数 +1（扣费失败则神庙保留、不消耗）
	if not UpgradeManager.consume_temple_boost(player):
		return false
	## 随机强化一件已装备装备的某一类数值（属性/被动/主动/护盾）
	var result: Dictionary = UpgradeManager.enhance_random_equipped_equipment()
	result_message = String(result.get("message", ""))
	return bool(result.get("success", false))

## 获取本次强化消耗的梦境碎片（累加计价：第1次400、第2次500……）
## 面板价格展示与置灰判定共用，故与实际扣费同源
func get_cost(_player: Node) -> int:
	return UpgradeManager.get_temple_boost_cost()

## 是否可选：碎片充足 且 至少有一件可强化的已装备装备
## 重写基类默认（仅看支付能力），补上"无可强化目标"这一前置条件
func can_select(player: Node) -> bool:
	if not UpgradeManager.has_enhanceable_equipped():
		return false
	return is_affordable(player)
