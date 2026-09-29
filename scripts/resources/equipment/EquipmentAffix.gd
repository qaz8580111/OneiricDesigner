## EquipmentAffix.gd - 装备单条基础属性词条（运行时产物）
## 职责：描述一件装备上"一条"已 roll 出的基础属性加成（属性键 + 实际数值 + 极品度）
## 继承：Resource（可在编辑器中查看/调试，但正常情况下由 EquipmentGenerator 运行时生成）
## 设计意图：
##   1. 装备系统"基础属性"的唯一落点——一条词条只携带一个 stat_key，
##      便于按统一规则累加进 UpgradeManager.player_stats（键名完全复用旧词条约定）
##   2. roll_ratio 记录本次 roll 占最大值的比例，用于展示"平庸/极品"（趣味性）
## 被引用方：EquipmentData.affixes（装备实例）、EquipmentGenerator（生成）、
##           EquipmentComponent（穿戴时汇总进 player_stats）
## 数据流：data/upgrades/*.tres(词条模板) → EquipmentGenerator 按槽位池随机 roll →
##         EquipmentAffix → EquipmentComponent 汇总 → UpgradeManager.player_stats
class_name EquipmentAffix
extends Resource

## 属性键：复用现有 stat_modifiers 约定键名（如 move_speed_mult / max_hp_bonus / hp_regen）
@export var stat_key: String = ""

## 本次 roll 出的实际数值（已按 roll_ratio 缩放后的最终值，直接累加进 player_stats）
@export var value: float = 0.0

## 极品度：本次 roll 占该词条模板最大值的比例（0.5~1.0，仅用于展示"平庸/极品"，不参与计算）
@export var roll_ratio: float = 1.0

## 词条显示名称（取自词条模板 display_name，缺省时回退显示 stat_key）
@export var display_name: String = ""

## 词条来源模板 id（取自词条模板 upgrade_id，如 "upg_move_speed"）
## 设计意图：装备实例本身不存图标，UI 需要借此回查词条模板图标（IconLibrary.get_upgrade_icon）
##           从而让"装备展示的图标"随其首条词条变化，无需给每件装备单独配图
@export var source_id: String = ""

## ========== 辅助方法 ==========

## 判断该词条是否为"乘算键"
## 约定：键名以 _mult 结尾为乘算（基准 1.0），其余为加值（基准 0）
## 返回：true=乘算键，false=加值键
func is_multiplier() -> bool:
	return stat_key.ends_with("_mult")

## 获取词条格式化显示文本（背包/装备面板 tooltip 用）
## 返回：如 "移动速度 +8.5%" 或 "血量上限 +12.0"
func get_display_text() -> String:
	var label: String = display_name if display_name != "" else stat_key
	if is_multiplier():
		return "%s +%.1f%%" % [label, value * 100.0]
	return "%s +%.1f" % [label, value]
