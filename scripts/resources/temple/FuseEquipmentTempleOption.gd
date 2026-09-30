## FuseEquipmentTempleOption.gd - 神庙「融合装备」选项
## 职责：取背包中同槽位最低稀有度 3 件装备融合，随机产出一件融合装备，并把结果写回反馈文本
## 继承：TempleOption（数据驱动，对应 data/temple/option_fuse_equipment.tres）
## 设计意图：
##   1. 融合概率模型/材料选取/产出入包全部收敛到 UpgradeManager.fuse_equipment()（单一实现源），
##      本类只负责"前置检查 → 扣碎片 → 调用 → 回传反馈"这条策略链，便于后续调整概率而不动 UI
##   2. 成本 = 消耗背包 3 件材料 + 消耗梦境碎片（UpgradeManager.get_fuse_cost），失败也全部消耗
##   3. 结果随机 → 通过 result_message 回传"融合出了什么/是否失败"，由 TemplePanel 结果视图展示
## 被引用方：Temple 扫描 data/temple/*.tres 加载，TemplePanel 展示，Temple 调用 apply()
class_name FuseEquipmentTempleOption
extends "res://scripts/resources/temple/TempleOption.gd"

## 应用融合：预检查 → 扣梦境碎片 → 消耗材料并随机产出 → 写入结果反馈
## 参数：player - 玩家节点（材料取自背包，梦境碎片从玩家扣除）
## 返回：true=融合操作已执行（含"融合失败无产出"这一结果，神庙消失）；false=前置不满足（神庙保留）
func apply(player: Node) -> bool:
	## 背包中不存在"某槽位 ≥3 件"：直接失败（面板已置灰，此处为双保险）
	if not UpgradeManager.can_fuse_equipment():
		return false
	## 先扣梦境碎片：碎片不足则神庙保留、不消耗材料（材料由 fuse_equipment 内部消耗）
	if not UpgradeManager.consume_fuse_cost(player):
		return false
	var result: Dictionary = UpgradeManager.fuse_equipment()
	## 融合未执行（材料竞态缺失/背包不可用）→ 退还梦境碎片，神庙保留可重试
	if not bool(result.get("success", false)):
		if player != null and player.has_method("add_dream_fragment"):
			player.add_dream_fragment(UpgradeManager.get_fuse_cost())
		result_message = String(result.get("message", ""))
		return false
	result_message = String(result.get("message", ""))
	return true

## 获取本次融合消耗的梦境碎片（材料之外额外消耗，与 UpgradeManager 同源）
func get_cost(_player: Node) -> int:
	return UpgradeManager.get_fuse_cost()

## 是否可选：背包中存在某槽位装备 ≥3 件（可凑齐融合材料）且梦境碎片充足
func can_select(player: Node) -> bool:
	if not UpgradeManager.can_fuse_equipment():
		return false
	return is_affordable(player)
