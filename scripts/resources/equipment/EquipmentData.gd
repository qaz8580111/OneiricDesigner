## EquipmentData.gd - 装备实例数据资源类
## 职责：描述一件具体装备（槽位 / 稀有度 / 基础属性词条 / 特效 / 护盾蓝图 / 主动技能）
## 继承：Resource（可在编辑器中查看/调试，正常情况下由 EquipmentGenerator 运行时生成）
## 设计意图：装备系统"唯一成长载体"——
##   1. 基础属性词条（affixes）穿戴后汇总进 UpgradeManager.player_stats
##   2. 特效（bullet_effects）穿戴后注入 Player 的私有子弹副本
##   3. 护盾蓝图（shield_data，仅盾牌槽）穿戴后驱动 EquipmentShieldComponent
##   4. 主动技能（active_skill，仅武器/戒指/法宝）提供"带冷却的弹道构型大招"
##   四维成长全部通过"聚合"接入，不修改任何策略基类（解耦性核心）
## 被引用方：BackpackComponent（背包持有）、EquipmentComponent（穿戴）、
##           EquipmentGenerator（生成）、UI（背包/装备面板展示）
## 数据流：EquipmentGenerator 随机生成 → 入背包 → 穿戴 → EquipmentComponent 汇总
##         → player_stats / 子弹副本 / 护盾组件 / 主动技能运行时
class_name EquipmentData
extends Resource

## ========== 槽位枚举 ==========

## 装备槽位（决定该装备可穿戴的位置与可 roll 的属性池/特效池）
enum Slot {
	WEAPON,    ## 武器：伤害/弹速/射速 + 特效 + 主动技能
	ARMOR,     ## 护甲：血量/回血/减伤 + 受击类特效
	BOOTS,     ## 鞋子：移速/血量/回血/护盾
	SHIELD,    ## 盾牌：护盾值/护盾恢复 + 护盾特效（携带护盾蓝图）
	RING,      ## 戒指：伤害/射速/弹速 + 特效 + 主动技能
	TALISMAN   ## 法宝：混合属性 + 特效 + 主动技能
}

## ========== 稀有度枚举 ==========

## 装备稀有度（由掉落源权重决定，进一步决定词条条数权重/特效概率/主动技能概率）
enum Rarity { COMMON, RARE, EPIC }

## ========== 装备基础属性 ==========

## 装备唯一标识（调试/去重/日志）
@export var equipment_id: String = ""

## 装备显示名称（背包/装备面板展示）
@export var display_name: String = ""

## 装备图标（为空时由 UI 按槽位回退显示默认图标）
@export var icon: Texture2D = null

## 装备槽位（决定可穿戴位置与生成时使用的属性池/特效池）
@export var slot: Slot = Slot.WEAPON

## 装备稀有度（影响词条条数权重、特效概率、主动技能概率与 UI 颜色）
@export var rarity: Rarity = Rarity.COMMON

## ========== 词条 / 特效 / 护盾 / 主动技能 ==========

## 基础属性词条列表（1..N 条，由 EquipmentGenerator 从该槽位的词条池随机 roll）
@export var affixes: Array[EquipmentAffix] = []

## 特效列表（0..N 个，由 EquipmentGenerator 从该槽位的特效池随机 roll；
## 每个均为独立 duplicate 副本，运行时叠层不会污染共享 .tres）
@export var bullet_effects: Array[BulletEffect] = []

## 护盾蓝图（仅 SHIELD 槽使用；为 ShieldEquipmentData 的独立副本，
## 提供护盾耐久/吸收/回盾/护盾特效，经 EquipmentShieldComponent.equip() 生效）
@export var shield_data: ShieldEquipmentData = null

## 主动技能（仅武器/戒指/法宝可能携带；可为 null，表示无主动技能）
@export var active_skill: EquipmentActiveSkill = null

## ========== 核心方法 ==========

## 判断该槽位是否允许携带主动技能（武器/戒指/法宝）
## 返回：true=该槽位可携带主动技能
func slot_supports_active_skill() -> bool:
	return slot == Slot.WEAPON or slot == Slot.RING or slot == Slot.TALISMAN

## 是否携带主动技能
## 返回：true=携带（active_skill 非空且含构型）
func has_active_skill() -> bool:
	return active_skill != null and active_skill.shot_pattern != null

## 获取槽位中文名（UI 展示用）
## 返回：槽位中文名
func get_slot_text() -> String:
	match slot:
		Slot.WEAPON:
			return "武器"
		Slot.ARMOR:
			return "护甲"
		Slot.BOOTS:
			return "鞋子"
		Slot.SHIELD:
			return "盾牌"
		Slot.RING:
			return "戒指"
		Slot.TALISMAN:
			return "法宝"
	return ""

## 获取稀有度中文名（UI 展示用）
## 返回：稀有度中文名
func get_rarity_text() -> String:
	match rarity:
		Rarity.RARE:
			return "稀有"
		Rarity.EPIC:
			return "史诗"
		_:
			return "普通"

## 获取稀有度显示颜色（UI 展示用，与旧词条配色保持一致）
## 返回：稀有度对应的 Color
func get_rarity_color() -> Color:
	match rarity:
		Rarity.RARE:
			return Color(0.4, 0.7, 1.0)    ## 稀有：蓝色
		Rarity.EPIC:
			return Color(0.8, 0.4, 1.0)    ## 史诗：紫色
		_:
			return Color(0.9, 0.9, 0.9)    ## 普通：白色

## 汇总本装备全部词条，得到"属性键 → 累加值"的字典
## 返回：字典（乘算键累加的是增量，加算键累加的是加值；供 EquipmentComponent 汇总）
func get_affix_totals() -> Dictionary:
	var totals: Dictionary = {}
	for affix in affixes:
		if affix == null:
			continue
		totals[affix.stat_key] = float(totals.get(affix.stat_key, 0.0)) + affix.value
	return totals
