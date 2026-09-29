## PurchaseEquipmentTempleOption.gd - 神庙选项：求购装备
## 职责：消耗固定梦境碎片，随机获得一件装备并放入背包（由神庙替代商店的应急补给）
## 继承：TempleOption（策略模式子类，路径式继承避免依赖全局类缓存刷新）
## 数据流：apply() → 背包可容纳预检查 → 扣固定碎片 → UpgradeManager.grant_random_equipment()
## 可选性：该选项恒显示，碎片 < 本次消耗 或 背包已满 时置灰不可选（can_select 判定）
## 变更说明：装备化重构后，原"融合技能"选项替换为"求购装备"
class_name PurchaseEquipmentTempleOption
extends "res://scripts/resources/temple/TempleOption.gd"

## 重写：本次求购消耗的碎片数（固定价，不参与神庙强化累加）
## 优先取 UpgradeManager 常量，避免固定价双处维护不一致
func get_cost(_player: Node) -> int:
	if UpgradeManager:
		return UpgradeManager.PURCHASE_EQUIPMENT_COST
	return 500

## 重写可选性：碎片充足（≥ 本次固定消耗）且背包有空间才可选，否则置灰
func can_select(player: Node) -> bool:
	if not is_affordable(player):
		return false
	return not _is_backpack_full(player)

## 重写：背包校验 → 扣固定碎片 → 发放随机装备（任一环节失败返回 false，神庙保留不消失）
func apply(player: Node) -> bool:
	if player == null or not player.has_method("spend_dream_fragment"):
		return false
	## 背包已满时直接失败（不扣碎片）
	if _is_backpack_full(player):
		return false
	## 扣除本次固定碎片（余额不足返回 false，神庙保留）
	if not player.spend_dream_fragment(get_cost(player)):
		return false
	## 发放随机装备入背包（发放失败 → 退款兜底，保证玩家不白花钱）
	if not UpgradeManager.grant_random_equipment():
		if player.has_method("add_dream_fragment"):
			player.add_dream_fragment(get_cost(player))
		return false
	return true

## 判断玩家背包是否已满（无背包组件时视为未满）
func _is_backpack_full(player: Node) -> bool:
	if player == null or not player.has_method("get_backpack"):
		return false
	var backpack: Variant = player.get_backpack()
	if backpack != null and backpack.has_method("is_full"):
		return bool(backpack.is_full())
	return false
