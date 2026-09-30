## EquipmentGenerator.gd - 装备随机生成器（纯工具类）
## 职责：按"槽位 + 稀有度 + 池"随机 roll 出一件完整 EquipmentData
##        （基础属性词条条数与数值 + 特效 + 护盾蓝图 + 主动技能）
## 继承：RefCounted（无状态纯工具，便于复用与测试；随机源统一走 RandomManager 保证可复现）
## 设计意图：
##   1. 把"断崖式递减概率"与"极品度 roll"集中收敛在此处，随机性/趣味性/合理性可单点调节
##   2. 只消费"模板池"，不关心池从何而来（由调用方传入），从而与 UpgradeManager 解耦
##   3. 词条模板复用现有 data/upgrades/*.tres（其 equip_slots 决定可出现的槽位）
## 概率模型：
##   - 稀有度：由掉落源权重决定（roll_rarity）
##   - 词条条数：每多一条概率按几何比≈0.25 断崖递减，"全词条"概率极低
##             硬上限：属性 ≤ MAX_STAT_AFFIXES(4) 条、技能（被动+主动）≤ MAX_SKILLS(2) 条，合计 ≤ 6 条
##   - 词条数值：最大值 × randf_range(0.5, 1.0)，制造"平庸/极品"差异
##   - 特效/主动技能：按稀有度给定概率命中，命中后从对应池随机取
## 被引用方：UpgradeManager（或装备管理入口）在掉落/商店/神庙中调用
class_name EquipmentGenerator
extends RefCounted

## ========== 概率与数值配置常量（集中调节点） ==========

## 属性词条条数上限（不分稀有度，单件装备最多 roll 4 条基础属性）
const MAX_STAT_AFFIXES := 4

## 技能条数上限（被动特效 + 主动技能合计，单件装备最多 2 条）
## 说明：与 MAX_STAT_AFFIXES 共同构成"装备词条总上限 6 条"（4 属性 + 2 技能）
const MAX_SKILLS := 2

## 词条条数权重表（下标 0 = 1 条；几何递减≈0.25，"全词条"概率极低）
## 说明：数组长度即该稀有度的属性词条条数上限，统一不超过 MAX_STAT_AFFIXES
const AFFIX_COUNT_WEIGHTS := {
	EquipmentData.Rarity.COMMON: [74.0, 20.0, 5.0, 1.0],
	EquipmentData.Rarity.RARE: [45.0, 36.0, 14.0, 4.0],
	EquipmentData.Rarity.EPIC: [25.0, 33.0, 27.0, 11.0],
}

## 特效个数权重表（下标 0 = 无特效；命中后按衰减取 1~2 个，不超过 MAX_SKILLS）
const EFFECT_COUNT_WEIGHTS := {
	EquipmentData.Rarity.COMMON: [85.0, 15.0],
	EquipmentData.Rarity.RARE: [60.0, 33.0, 7.0],
	EquipmentData.Rarity.EPIC: [25.0, 55.0, 20.0],
}

## 特效强度（叠层数）权重表（下标 0 = 1 级）
const EFFECT_LEVEL_WEIGHTS := [70.0, 25.0, 5.0]

## 主动技能命中概率（仅武器/戒指/法宝参与判定）
const ACTIVE_SKILL_CHANCE := {
	EquipmentData.Rarity.COMMON: 0.05,
	EquipmentData.Rarity.RARE: 0.25,
	EquipmentData.Rarity.EPIC: 0.60,
}

## 主动技能冷却基准（秒，按稀有度；实际再叠加少量随机抖动）
## 说明：CD 已整体下调（12/9/6 → 8/5/3）——原值下"一次技能≈2~3发普通子弹"，
##       与长 CD 严重不匹配，故缩短冷却使主动技能成为可依赖的爆发手段
const ACTIVE_SKILL_COOLDOWN := {
	EquipmentData.Rarity.COMMON: 8.0,
	EquipmentData.Rarity.RARE: 5.0,
	EquipmentData.Rarity.EPIC: 3.0,
}

## 主动技能整轮伤害倍率（按稀有度，仅作用于技能释放、不影响普通射击）
## 设计意图：弹道构型系统本身是"整轮总伤守恒"——构型只改弹道形状/发数分摊，
##          不改整轮强度（详见 GameWorld._assign_conserved_damage），
##          因此主动技能必须叠加本倍率才能拉开与普通射击的差距。
## 数据流：本表 → EquipmentActiveSkill.damage_multiplier →
##         Player._cast_active_skill 放大临时子弹伤害基数 → GameWorld 守恒分配到各发
const ACTIVE_SKILL_DAMAGE_MULT := {
	EquipmentData.Rarity.COMMON: 2.5,
	EquipmentData.Rarity.RARE: 3.5,
	EquipmentData.Rarity.EPIC: 5.0,
}

## 词条数值 roll 比例下限（0.5~1.0，越高越"极品"）
const VALUE_ROLL_MIN := 0.5

## 主动技能冷却随机抖动范围（秒）
## 说明：随 CD 整体下调同步收窄（2.0 → 1.0），避免短 CD 技能因抖动出现"冷却忽长忽短"
const ACTIVE_SKILL_COOLDOWN_JITTER := 1.0

## ========== 对外主入口 ==========

## 生成一件装备
## 参数：slot - 目标槽位（EquipmentData.Slot）
##       rarity - 目标稀有度（EquipmentData.Rarity）
##       pools - 池字典，键约定：
##               "affix_templates"  : Array（属性词条模板，读 stat_modifiers / equip_slots / display_name）
##               "effect_templates" : Array（特效模板，读 bullet_effect / equip_slots）
##               "pattern_pool"     : Array（弹道构型池，读 BulletShotPattern）
##               "shield_pool"      : Array（护盾蓝图池，读 ShieldEquipmentData）
## 返回：生成好的 EquipmentData（池为空时对应部分留空，不会报错）
static func generate(slot: int, rarity: int, pools: Dictionary) -> EquipmentData:
	var affix_templates: Array = pools.get("affix_templates", [])
	var effect_templates: Array = pools.get("effect_templates", [])
	var pattern_pool: Array = pools.get("pattern_pool", [])
	var shield_pool: Array = pools.get("shield_pool", [])

	var eq := EquipmentData.new()
	eq.slot = slot
	eq.rarity = rarity
	eq.affixes = _roll_affixes(slot, rarity, affix_templates)
	eq.bullet_effects = _roll_effects(slot, rarity, effect_templates)
	## 盾牌槽：携带护盾蓝图（含按概率附加的护盾特效）
	if slot == EquipmentData.Slot.SHIELD:
		eq.shield_data = _roll_shield(rarity, shield_pool)
	## 武器/戒指/法宝：按概率携带主动技能
	## 技能名额约束：主动技能与被动特效共享 MAX_SKILLS 名额，被动已占满时不再发主动技能
	## （先 roll 被动、再发主动，天然保证"被动 + 主动 ≤ MAX_SKILLS"）
	if eq.slot_supports_active_skill() and eq.bullet_effects.size() < MAX_SKILLS:
		eq.active_skill = _roll_active_skill(rarity, pattern_pool)
	## 需求：稀有度由"实际词条总数"决定（入参 rarity 仅用于驱动生成时的内容丰富度）
	## 计数口径：属性词条 + 被动特效 + 主动技能（护盾蓝图是蓝图而非词条，不计入）
	var derived_rarity: int = _derive_rarity(_count_affix_total(eq))
	eq.rarity = derived_rarity
	eq.display_name = _build_display_name(slot, derived_rarity)
	eq.equipment_id = "%s_%d_%d" % [slot, derived_rarity, Time.get_ticks_usec()]
	return eq

## 按词条总数派生稀有度
## 参数：total - 属性词条 + 被动特效 + 主动技能 的总条数
## 返回：EquipmentData.Rarity（1~2 普通 / 3~4 稀有 / 5 及以上史诗）
static func _derive_rarity(total: int) -> int:
	if total >= 5:
		return EquipmentData.Rarity.EPIC
	if total >= 3:
		return EquipmentData.Rarity.RARE
	return EquipmentData.Rarity.COMMON

## 统计一件装备的"词条总数"（属性词条 + 被动特效 + 主动技能；护盾蓝图是蓝图而非词条，不计入）
## 设计意图：稀有度派生与保底补足共用同一口径，避免两处各算一套导致判定不一致
## 参数：eq - 装备实例
## 返回：词条总条数
static func _count_affix_total(eq: EquipmentData) -> int:
	var total: int = eq.affixes.size() + eq.bullet_effects.size()
	if eq.active_skill != null:
		total += 1
	return total

## 生成一件"稀有度保底"的装备（碎片合成专用）
## 与 generate 的区别：若随机结果未达 rarity_floor 对应的最小词条总数，则从该槽位属性池补足
## 参数：slot - 目标槽位；rarity_floor - 稀有度下限（EquipmentData.Rarity）；pools - 池字典（同 generate）
## 返回：至少达到 rarity_floor 的 EquipmentData；生成失败返回 null
## 设计意图：合成消耗玩家资源，必须给到"不低于稀有"的确定性回报，避免合成出的装备比碎片本身还差
static func generate_with_floor(slot: int, rarity_floor: int, pools: Dictionary) -> EquipmentData:
	## 先按常规流程 roll（rarity_floor 同时驱动内容丰富度）
	var eq: EquipmentData = generate(slot, rarity_floor, pools)
	if eq == null:
		return null
	## 达标（词条总数已达下限）则原样返回，不做任何改动
	var min_total: int = _min_total_for_rarity(rarity_floor)
	if _count_affix_total(eq) >= min_total:
		return eq
	## 未达标：从该槽位属性词条池补足（跳过已出现的属性键，避免重复词条）
	var affix_templates: Array = pools.get("affix_templates", [])
	var pool: Array = _templates_for_slot(affix_templates, slot)
	var shuffled: Array = pool.duplicate()
	RandomManager.shuffle_array(shuffled)
	var used_keys: Dictionary = {}
	for affix in eq.affixes:
		if affix != null:
			used_keys[affix.stat_key] = true
	for template in shuffled:
		if _count_affix_total(eq) >= min_total:
			break
		## 补足同样受"属性词条上限"约束：不因保底而突破 MAX_STAT_AFFIXES 条
		if eq.affixes.size() >= MAX_STAT_AFFIXES:
			break
		var extra: EquipmentAffix = _make_affix(template)
		if extra == null or used_keys.has(extra.stat_key):
			continue
		used_keys[extra.stat_key] = true
		eq.affixes.append(extra)
	## 补足后词条总数已变，重派生稀有度/名称/ID，保持与 generate 同口径
	var derived: int = _derive_rarity(_count_affix_total(eq))
	eq.rarity = derived
	eq.display_name = _build_display_name(slot, derived)
	eq.equipment_id = "%s_%d_%d" % [slot, derived, Time.get_ticks_usec()]
	return eq

## 各稀有度对应的"最小词条总数"（与 _derive_rarity 互为逆运算，供保底补足使用）
## 参数：rarity - EquipmentData.Rarity
## 返回：达到该稀有度所需的最少"属性词条 + 被动特效 + 主动技能"总数
static func _min_total_for_rarity(rarity: int) -> int:
	match rarity:
		EquipmentData.Rarity.EPIC:
			return 5
		EquipmentData.Rarity.RARE:
			return 3
		_:
			return 0

## 按权重随机一个稀有度
## 参数：weights - 形如 [COMMON权重, RARE权重, EPIC权重]（不足的按 0 处理）
## 返回：EquipmentData.Rarity
static func roll_rarity(weights: Array) -> int:
	var idx: int = _pick_weighted_index(weights)
	## 夹取到合法稀有度范围，避免外部权重表越界
	return clampi(idx, EquipmentData.Rarity.COMMON, EquipmentData.Rarity.EPIC)

## 按权重随机一个槽位（供掉落源决定"掉哪一类装备"）
## 参数：weights - 形如 [WEAPON权重, ARMOR权重, BOOTS权重, SHIELD权重, RING权重, TALISMAN权重]
## 返回：EquipmentData.Slot
static func roll_slot(weights: Array) -> int:
	var idx: int = _pick_weighted_index(weights)
	## 夹取到合法槽位范围，避免外部权重表越界
	return clampi(idx, EquipmentData.Slot.WEAPON, EquipmentData.Slot.TALISMAN)

## ========== 词条生成 ==========

## roll 基础属性词条（条数按稀有度断崖递减，从槽位池中不重复抽取）
## 返回：Array[EquipmentAffix]
static func _roll_affixes(slot: int, rarity: int, affix_templates: Array) -> Array[EquipmentAffix]:
	var result: Array[EquipmentAffix] = []
	var pool: Array = _templates_for_slot(affix_templates, slot)
	if pool.is_empty():
		return result
	## 打乱池副本以"不重复"抽取（同一键不会在一件装备上出现两次）
	var shuffled: Array = pool.duplicate()
	RandomManager.shuffle_array(shuffled)
	var weights: Array = AFFIX_COUNT_WEIGHTS.get(rarity, AFFIX_COUNT_WEIGHTS[EquipmentData.Rarity.COMMON])
	var count: int = _pick_weighted_index(weights) + 1
	## 硬上限：属性词条最多 MAX_STAT_AFFIXES 条；再受槽位可用模板数截断
	count = mini(count, MAX_STAT_AFFIXES)
	count = mini(count, shuffled.size())
	for i in range(count):
		var affix: EquipmentAffix = _make_affix(shuffled[i])
		if affix != null:
			result.append(affix)
	return result

## 从单条词条模板生成一条 EquipmentAffix
## 读取模板 stat_modifiers 的第一个键作为属性键，其值作为"最大值"，再按比例 roll 实际数值
static func _make_affix(template: Variant) -> EquipmentAffix:
	if template == null:
		return null
	var mods: Variant = template.get("stat_modifiers")
	if not (mods is Dictionary) or (mods as Dictionary).is_empty():
		return null
	var dict: Dictionary = mods
	var key: String = String(dict.keys()[0])
	var max_value: float = float(dict[key])
	var ratio: float = RandomManager.randf_range(VALUE_ROLL_MIN, 1.0)
	var affix := EquipmentAffix.new()
	affix.stat_key = key
	affix.value = max_value * ratio
	affix.roll_ratio = ratio
	affix.display_name = String(template.get("display_name"))
	## 记录来源模板 id：UI 借此回查词条模板图标（装备实例本身不存图标）
	affix.source_id = String(template.get("upgrade_id"))
	return affix

## ========== 特效生成 ==========

## roll 子弹特效（个数按稀有度权重，命中后从槽位特效池不重复抽取）
## 返回：Array[BulletEffect]（每个均为独立副本，运行时叠层不污染共享 .tres）
static func _roll_effects(slot: int, rarity: int, effect_templates: Array) -> Array[BulletEffect]:
	var result: Array[BulletEffect] = []
	var pool: Array = _templates_for_slot(effect_templates, slot)
	if pool.is_empty():
		return result
	var shuffled: Array = pool.duplicate()
	RandomManager.shuffle_array(shuffled)
	var weights: Array = EFFECT_COUNT_WEIGHTS.get(rarity, EFFECT_COUNT_WEIGHTS[EquipmentData.Rarity.COMMON])
	var count: int = _pick_weighted_index(weights)
	## 硬上限：被动特效最多 MAX_SKILLS 条（与主动技能共享技能名额）；再受槽位可用模板数截断
	count = mini(count, MAX_SKILLS)
	count = mini(count, shuffled.size())
	for i in range(count):
		var effect: BulletEffect = _make_effect(shuffled[i])
		if effect != null:
			result.append(effect)
	return result

## 从单条特效模板生成一个独立特效副本（并按权重 roll 初始强度 1~3 级）
static func _make_effect(template: Variant) -> BulletEffect:
	if template == null:
		return null
	var src: Variant = template.get("bullet_effect")
	if not (src is BulletEffect):
		return null
	var copy: BulletEffect = (src as BulletEffect).duplicate(true)
	## 记录特效显示名（取自特效模板 display_name，供装备面板展示特效词条）
	copy.display_name = String(template.get("display_name"))
	## 强度 roll：抽到 2/3 级时用 add_stack() 逐级放大（复用现有叠层成长策略）
	var level: int = _pick_weighted_index(EFFECT_LEVEL_WEIGHTS) + 1
	for _i in range(level - 1):
		copy.add_stack()
	return copy

## ========== 护盾蓝图生成 ==========

## roll 护盾蓝图（仅盾牌槽）：随机取一份基础护盾副本，并按稀有度概率附加护盾特效
## 说明：护盾特效池由护盾蓝图自身派生（凡带 shield_effect 的蓝图即为特效来源）
static func _roll_shield(rarity: int, shield_pool: Array) -> ShieldEquipmentData:
	if shield_pool.is_empty():
		return null
	var base: ShieldEquipmentData = (shield_pool[RandomManager.randi_range(0, shield_pool.size() - 1)] as ShieldEquipmentData).duplicate(true)
	## 收集可用护盾特效来源（模板里的 shield_effect）
	var effect_sources: Array = []
	for s in shield_pool:
		if s is ShieldEquipmentData and (s as ShieldEquipmentData).shield_effect != null:
			effect_sources.append((s as ShieldEquipmentData).shield_effect)
	## 特效命中概率沿用"特效命中"规则：稀有度越高越容易带特效
	var chance: float = ACTIVE_SKILL_CHANCE.get(rarity, 0.0)
	if not effect_sources.is_empty() and RandomManager.chance(chance):
		var src_effect: Resource = effect_sources[RandomManager.randi_range(0, effect_sources.size() - 1)]
		base.shield_effect = src_effect.duplicate(true)
		base.is_special = true
	else:
		base.shield_effect = null
		base.is_special = false
	return base

## ========== 主动技能生成 ==========

## roll 主动技能（仅武器/戒指/法宝）：按稀有度概率命中，命中后随机取一个构型
static func _roll_active_skill(rarity: int, pattern_pool: Array) -> EquipmentActiveSkill:
	if pattern_pool.is_empty():
		return null
	var chance: float = ACTIVE_SKILL_CHANCE.get(rarity, 0.0)
	if not RandomManager.chance(chance):
		return null
	var pattern: BulletShotPattern = pattern_pool[RandomManager.randi_range(0, pattern_pool.size() - 1)] as BulletShotPattern
	if pattern == null:
		return null
	var skill := EquipmentActiveSkill.new()
	skill.shot_pattern = pattern
	skill.display_name = pattern.display_name if pattern.display_name != "" else pattern.pattern_id
	skill.description = pattern.description
	var base_cd: float = ACTIVE_SKILL_COOLDOWN.get(rarity, 8.0)
	skill.cooldown = base_cd + RandomManager.randf_range(-ACTIVE_SKILL_COOLDOWN_JITTER, ACTIVE_SKILL_COOLDOWN_JITTER)
	skill.cooldown = maxf(skill.cooldown, 1.0)
	## 整轮伤害倍率（技能专属强度来源，与构型形状/发数解耦）
	skill.damage_multiplier = float(ACTIVE_SKILL_DAMAGE_MULT.get(rarity, 1.0))
	skill.skill_id = "skill_" + pattern.pattern_id
	return skill

## ========== 内部工具 ==========

## 从模板池中筛出"可用于指定槽位"的模板（读 equip_slots 数组）
## 说明：equip_slots 为空表示该模板不参与装备词条 roll
static func _templates_for_slot(templates: Array, slot: int) -> Array:
	var out: Array = []
	for t in templates:
		if t == null:
			continue
		var slots: Variant = t.get("equip_slots")
		if slots is Array and (slots as Array).has(slot):
			out.append(t)
	return out

## 按权重随机一个下标（返回下标，非数值）
## 参数：weights - 权重数组（可含小数）
## 返回：命中的下标；权重全为 0 或为空时返回 0
static func _pick_weighted_index(weights: Array) -> int:
	var total: float = 0.0
	for w in weights:
		total += float(w)
	if total <= 0.0:
		return 0
	var roll: float = RandomManager.randf() * total
	var acc: float = 0.0
	for i in range(weights.size()):
		acc += float(weights[i])
		if roll < acc:
			return i
	return maxi(weights.size() - 1, 0)

## 拼接装备显示名（稀有度 + 槽位名，便于背包快速识别）
static func _build_display_name(slot: int, rarity: int) -> String:
	var slot_text: String = ""
	match slot:
		EquipmentData.Slot.WEAPON:
			slot_text = "武器"
		EquipmentData.Slot.ARMOR:
			slot_text = "护甲"
		EquipmentData.Slot.BOOTS:
			slot_text = "鞋子"
		EquipmentData.Slot.SHIELD:
			slot_text = "盾牌"
		EquipmentData.Slot.RING:
			slot_text = "戒指"
		EquipmentData.Slot.TALISMAN:
			slot_text = "法宝"
	var rarity_text: String = "普通"
	match rarity:
		EquipmentData.Rarity.RARE:
			rarity_text = "稀有"
		EquipmentData.Rarity.EPIC:
			rarity_text = "史诗"
	return "%s%s" % [rarity_text, slot_text]
