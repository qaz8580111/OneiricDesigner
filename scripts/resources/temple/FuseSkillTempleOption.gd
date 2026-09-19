## FuseSkillTempleOption.gd - 神庙选项：融合技能
## 职责：随机融合两个已拥有的"技能类"词条，效果叠加并释放技能格子
## 继承：TempleOption（策略模式子类，路径式继承避免依赖全局类缓存刷新）
## 数据流：apply() → 校验可融合/扣10000碎片 → UpgradeManager.fuse_random_skills()
## 可见性/可选性：该选项恒显示，碎片 <10000 或已持有技能 <2 时置灰不可选（can_select 判定），
##               不再像旧版那样直接隐藏
## 融合规则（UpgradeManager.fuse_random_skills 实现）：
##   随机两个技能 A、B；融合等级 = max(A等级, B等级)；两个特效都提升到融合等级（效果叠加）；
##   源技能从词条栈移除（释放格子，且不再被"强化技能"选中）；玩家只保留一个融合技能，二次融合替换旧融合
## 变更说明（2026-09-19）：由"未完善占位"改为完整实现；碎片门槛改为置灰而非隐藏；生效扣10000碎片
class_name FuseSkillTempleOption
extends "res://scripts/resources/temple/TempleOption.gd"

## 融合技能固定消耗的梦境碎片数（兜底值，正常以 UpgradeManager.FUSE_SKILL_COST 为唯一数据源）
const FUSE_FRAGMENT_COST: int = 10000

## 重写：本次融合消耗的碎片数（固定10000）
func get_cost(_player: Node) -> int:
	## 优先取 UpgradeManager 常量，避免 10000 双处维护不一致
	if UpgradeManager:
		return UpgradeManager.FUSE_SKILL_COST
	return FUSE_FRAGMENT_COST

## 重写可选性：碎片充足（≥10000）且已持有至少2个技能类词条才可选，否则置灰
func can_select(player: Node) -> bool:
	if not is_affordable(player):
		return false
	return UpgradeManager != null and UpgradeManager.can_fuse_skills()

## 重写：校验可融合 → 扣10000碎片 → 融合（任一环节失败返回 false，神庙保留不消失）
func apply(player: Node) -> bool:
	if player == null or not player.has_method("spend_dream_fragment"):
		return false
	## 技能不足2个时直接失败（不扣碎片）
	if not UpgradeManager.can_fuse_skills():
		return false
	## 扣除10000碎片（余额不足返回 false，神庙保留）
	if not player.spend_dream_fragment(get_cost(player)):
		return false
	## 执行融合（内部随机选两个技能、撤销旧融合、生成新融合）
	return UpgradeManager.fuse_random_skills()

## 重写：标记为融合技能选项（TemplePanel 据此渲染金色边框与"融"字图标）
func is_fuse_option() -> bool:
	return true
