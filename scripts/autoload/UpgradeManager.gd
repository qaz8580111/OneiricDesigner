## UpgradeManager.gd - 玩家装备成长管理单例
## 职责：管理词条模板池加载、装备随机生成、玩家属性全量重算、神庙强化装备
## 继承：Node（作为全局单例运行）
## 设计意图：
##   1. 装备是唯一的成长载体：属性词条/特效/护盾/弹道构型全部聚合到装备中，
##      掉落源（Enemy/Boss/精英）、商店、神庙只产出装备（调 generate_equipment()），
##      不再直接发放词条/技能
##   2. 数据驱动扩展：自动扫描 data/upgrades/ 加载词条模板、data/equipment/ 加载护盾蓝图、
##      data/bullet/pattern/ 加载弹道构型，新增内容只需创建 .tres，无需修改任何代码
##   3. 全量重算：player_stats = BASE_STATS + 装备词条汇总，杜绝增量 += / -= 留下的脏数据
extends Node

## ========== 预加载资源 ==========

## 词条数据资源类（作为装备属性/特效模板来源）
const UpgradeDataClass = preload("res://scripts/resources/upgrade/UpgradeData.gd")

## 装备护盾数据资源类（data/equipment/*.tres 类型校验用）
const ShieldEquipmentDataClass = preload("res://scripts/resources/equipment/ShieldEquipmentData.gd")

## 弹道构型资源类（data/bullet/pattern/*.tres 类型校验用）
const BulletShotPatternClass = preload("res://scripts/resources/bullet/BulletShotPattern.gd")

## 装备随机生成器（纯工具类）：掉落/商店/神庙生成装备实例的统一入口
const EquipmentGeneratorClass = preload("res://scripts/resources/equipment/EquipmentGenerator.gd")

## 装备数据类（用于访问 Slot/Rarity 枚举，走 preload 避免全局类缓存刷新问题）
const EquipmentDataClass = preload("res://scripts/resources/equipment/EquipmentData.gd")

## 护盾装备池目录（数据驱动扫描，装备生成时作为盾牌槽护盾蓝图来源）
const SHIELD_POOL_DIR: String = "res://data/equipment"

## 弹道构型池目录（数据驱动扫描，装备生成时作为武器主动技能来源）
const SHOT_PATTERN_POOL_DIR: String = "res://data/bullet/pattern"

## ========== 装备掉落随机权重（掉落源统一入口 generate_equipment 消费） ==========

## 装备稀有度权重（下标=EquipmentData.Rarity：COMMON/RARE/EPIC）
## 设计意图：普通装备为绝对主流，史诗为惊喜，保证"随机性/趣味性/合理性"平衡
const EQUIPMENT_RARITY_WEIGHTS: Array = [76.0, 20.0, 4.0]

## 装备槽位权重（下标=EquipmentData.Slot：WEAPON/ARMOR/BOOTS/SHIELD/RING/TALISMAN）
## 设计意图：攻防核心槽位（武器/护甲）略高，其余槽位更均衡，避免单一槽位刷屏
const EQUIPMENT_SLOT_WEIGHTS: Array = [22.0, 20.0, 18.0, 14.0, 13.0, 13.0]

## ========== 神庙强化碎片消耗（累加计价） ==========

## 神庙强化首次消耗的梦境碎片数（第一次400）
const TEMPLE_BOOST_BASE_COST: int = 400

## 神庙强化每次消耗的增量（第二次500、第三次600……每次+100）
const TEMPLE_BOOST_COST_STEP: int = 100

## 神庙"强化装备"每次强化的数值增幅比例（在现有词条数值基础上 ×(1+该比例)）
const EQUIPMENT_BOOST_RATIO: float = 0.2

## ========== 神庙"融合装备"概率配置 ==========

## 融合"更好"结果概率：产出优于三件材料中任意一件
const FUSE_BETTER_CHANCE: float = 0.30

## 融合"更差或持平"结果概率：产出不如材料或与之相当
const FUSE_WORSE_CHANCE: float = 0.30

## 融合稀有度提升的基准概率（仅"更好"结果分支内再 roll）
const FUSE_RARITY_UPGRADE_BASE: float = 0.10

## 融合稀有度提升概率上限（基准 + 三件材料稀有度权重之和后的封顶）
const FUSE_RARITY_UPGRADE_MAX: float = 0.60

## 材料稀有度对"提升概率"的权重贡献（下标=EquipmentData.Rarity：普通/稀有/史诗）
## 设计意图：材料越稀有，融合越容易突破稀有度——稀有度权重越高概率越大
const FUSE_RARITY_WEIGHT_BY_RARITY: Array = [0.02, 0.06, 0.12]

## 融合"更好"结果的词条数值额外增幅（在保底生成基础上 ×(1+该比例)）
const FUSE_BETTER_BOOST_RATIO: float = 0.10

## 神庙"融合装备"每次消耗的梦境碎片（在消耗 3 件材料之外的额外成本）
const FUSE_DREAM_COST: int = 200

## ========== 信号定义 ==========

## 玩家属性重算完成信号：装备穿戴/卸下/强化导致 player_stats 重算后发出
## 参数：stats - 重算后的完整属性字典（= player_stats）
## 数据流：recompute_stats() → 此信号 → Player._sync_upgrade_stats() 统一同步到自身
signal stats_recomputed(stats: Dictionary)

## ========== 玩家属性（全量重算模型，装备系统核心） ==========

## 属性基准值：所有加成来源（装备词条）都以此为基础重算，绝不在此之上做增量 +/-=
## 键名约定与 UpgradeData.stat_modifiers / EquipmentAffix.stat_key 完全一致：
##   damage_mult（子弹伤害乘算）/ bullet_speed_mult（弹速乘算）
##   fire_rate_mult（射速乘算）/ move_speed_mult（移速乘算）
##   max_hp_bonus（核心血上限加值）/ hp_regen（每秒核心血回复量）
##   shield_max_mult（装备护盾耐久上限乘算，EquipmentShieldComponent消费）
##   shield_regen_mult（装备护盾回盾速度乘算，EquipmentShieldComponent消费）
##   invincible_mult（受击无敌时间乘算，CoreHealthComponent消费）
##   damage_reduction（受击减伤比例，0~0.9钳制，Player.take_damage消费）
## 值语义：乘算类（键名以_mult结尾）基准1.0；加值类基准0
const BASE_STATS: Dictionary = {
	"damage_mult": 1.0,
	"bullet_speed_mult": 1.0,
	"fire_rate_mult": 1.0,
	"move_speed_mult": 1.0,
	"max_hp_bonus": 0.0,
	"shield_max_mult": 1.0,
	"shield_regen_mult": 1.0,
	"hp_regen": 0.0,
	"invincible_mult": 1.0,
	"damage_reduction": 0.0,
}

## 当前生效的玩家属性字典（= BASE_STATS + 装备词条汇总的全量重算结果）
## 只读消费：外部（Player/HUD）读取此字典获取最终属性，禁止直接写入，
##          写入一律通过各自的"加成字典" + recompute_stats() 完成
var player_stats: Dictionary = BASE_STATS.duplicate()

## 装备词条汇总值（由 Player 的 EquipmentComponent 通过 set_equipment_bonus 推送）
var _equipment_bonus: Dictionary = {}

## ========== 神庙强化运行时状态 ==========

## 神庙强化已执行次数（每次强化消耗累加：第1次400、第2次500……）
## 跨神庙累计，游戏开始重置
var _temple_boost_count: int = 0

## ========== 词条/护盾/构型池（装备生成的模板来源） ==========

## 所有加载的词条数据（UpgradeData数组，作为装备属性/特效模板来源）
var _upgrade_pool: Array = []

## 所有加载的护盾装备数据（ShieldEquipmentData数组，装备盾牌槽蓝图来源）
var _shield_pool: Array = []

## 所有加载的弹道构型数据（BulletShotPattern数组，装备主动技能来源）
var _shot_pattern_pool: Array = []

## ========== 生命周期方法 ==========

## _ready() - 进入场景树时初始化
func _ready() -> void:
	## 扫描并加载所有词条资源（装备词条模板来源）
	_load_upgrade_pool()
	## 扫描并加载所有护盾装备资源（装备盾牌槽蓝图来源）
	_load_shield_pool()
	## 扫描并加载所有弹道构型资源（装备主动技能来源）
	_load_shot_pattern_pool()
	## 监听游戏开始信号：每局开始时重置强化状态
	GameManager.game_started.connect(_on_game_started)

## 重置本局强化状态（响应GameManager.game_started）
func _on_game_started() -> void:
	## 重置属性加成来源（装备词条汇总），并全量重算回基准值
	_equipment_bonus.clear()
	recompute_stats()
	## 重置神庙强化计数
	_temple_boost_count = 0

## ========== 属性全量重算（装备系统核心） ==========

## 全量重算玩家属性：player_stats = BASE_STATS + 装备词条汇总
## 数据流：装备穿戴/卸下/强化 → 本方法 → stats_recomputed 信号 → Player 同步
## 设计意图：装备只写自己的"加成字典"（_equipment_bonus），
##          最终值每次从基准重算，彻底消除增量 += / -= 在"替换/卸下"路径上留下的脏数据
func recompute_stats() -> void:
	var result: Dictionary = BASE_STATS.duplicate()
	_accumulate_into(result, _equipment_bonus)
	player_stats = result
	stats_recomputed.emit(player_stats)

## 将加成字典按"加算"语义累加进目标字典（乘算键的加成值如 +0.15 表示 +15%）
## 参数：target - 目标属性字典（被就地修改）；bonus - 加成字典（stat_key → 加成值）
func _accumulate_into(target: Dictionary, bonus: Dictionary) -> void:
	for key in bonus.keys():
		target[key] = float(target.get(key, 0.0)) + float(bonus[key])

## 设置装备词条汇总值并触发重算（由 Player 的 EquipmentComponent 在装备变更时推送）
## 参数：totals - stat_key → 汇总加成值（各已穿装备 get_affix_totals() 的合并结果）
func set_equipment_bonus(totals: Dictionary) -> void:
	_equipment_bonus = totals.duplicate() if totals != null else {}
	recompute_stats()

## ========== 词条池加载 ==========

## 扫描data/upgrades/目录加载所有词条.tres
## 使用DirAccess动态扫描（而非硬编码列表），保证可扩展性：
## 新增词条只需放入.tres文件，重启即生效
func _load_upgrade_pool() -> void:
	_upgrade_pool.clear()
	var dir_path: String = "res://data/upgrades"
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		push_warning("UpgradeManager: 无法打开词条目录 " + dir_path)
		return

	## 遍历目录下所有文件
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		## 只处理.tres资源文件
		if not dir.current_is_dir() and file_name.ends_with(".tres"):
			var resource: Resource = load(dir_path + "/" + file_name)
			## 校验资源类型（防止误放其他资源导致崩溃）
			if resource is UpgradeDataClass:
				_upgrade_pool.append(resource)
			else:
				push_warning("UpgradeManager: " + file_name + " 不是UpgradeData类型，已跳过")
		file_name = dir.get_next()
	dir.list_dir_end()
	print("UpgradeManager: 已加载 %d 条装备词条模板" % _upgrade_pool.size())

## 扫描 data/equipment/ 目录加载所有护盾装备（装备盾牌槽蓝图来源）
## 与 _load_upgrade_pool 同款数据驱动：新增护盾只需放入 .tres，重启即生效，无需改代码
func _load_shield_pool() -> void:
	_shield_pool.clear()
	var dir: DirAccess = DirAccess.open(SHIELD_POOL_DIR)
	if dir == null:
		push_warning("UpgradeManager: 无法打开护盾目录 " + SHIELD_POOL_DIR)
		return

	## 遍历目录下所有文件
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		## 只处理.tres资源文件
		if not dir.current_is_dir() and file_name.ends_with(".tres"):
			var resource: Resource = load(SHIELD_POOL_DIR + "/" + file_name)
			## 校验资源类型（防止误放其他装备资源导致崩溃）
			if resource is ShieldEquipmentDataClass:
				_shield_pool.append(resource)
			else:
				push_warning("UpgradeManager: " + file_name + " 不是ShieldEquipmentData类型，已跳过")
		file_name = dir.get_next()
	dir.list_dir_end()
	print("UpgradeManager: 已加载 %d 件护盾蓝图" % _shield_pool.size())

## 扫描 data/bullet/pattern/ 目录加载所有弹道构型（装备主动技能来源）
## 与 _load_shield_pool 同款数据驱动：新增构型只需放入 .tres，重启即生效，无需改代码
func _load_shot_pattern_pool() -> void:
	_shot_pattern_pool.clear()
	var dir: DirAccess = DirAccess.open(SHOT_PATTERN_POOL_DIR)
	if dir == null:
		push_warning("UpgradeManager: 无法打开弹道构型目录 " + SHOT_PATTERN_POOL_DIR)
		return

	## 遍历目录下所有文件
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		## 只处理.tres资源文件
		if not dir.current_is_dir() and file_name.ends_with(".tres"):
			var resource: Resource = load(SHOT_PATTERN_POOL_DIR + "/" + file_name)
			## 校验资源类型（防止误放其他资源导致崩溃）
			if resource is BulletShotPatternClass:
				_shot_pattern_pool.append(resource)
			else:
				push_warning("UpgradeManager: " + file_name + " 不是BulletShotPattern类型，已跳过")
		file_name = dir.get_next()
	dir.list_dir_end()
	print("UpgradeManager: 已加载 %d 种弹道构型" % _shot_pattern_pool.size())

## ========== 装备随机生成（掉落/商店/神庙共用统一入口） ==========

## 随机生成一件装备（装备系统"唯一成长载体"的产出入口）
## 参数：slot   - 指定槽位（EquipmentData.Slot）；-1 = 按 EQUIPMENT_SLOT_WEIGHTS 随机
##       rarity - 指定稀有度（EquipmentData.Rarity）；-1 = 按 EQUIPMENT_RARITY_WEIGHTS 随机
## 返回：EquipmentData 装备实例（池为空时对应部分留空，不会报错）
## 设计意图：把"随机性收敛到一处"——掉落源（Enemy/Boss/精英）、商店、神庙只需调用本方法，
##          无需关心词条池/特效池/护盾池/构型池的组织方式
func generate_equipment(slot: int = -1, rarity: int = -1) -> Resource:
	var final_slot: int = slot if slot >= 0 else EquipmentGeneratorClass.roll_slot(EQUIPMENT_SLOT_WEIGHTS)
	var final_rarity: int = rarity if rarity >= 0 else EquipmentGeneratorClass.roll_rarity(EQUIPMENT_RARITY_WEIGHTS)
	return EquipmentGeneratorClass.generate(final_slot, final_rarity, _build_equipment_pools())

## 生成一件"稀有度保底"的装备（商店碎片合成专用）
## 参数：slot - 指定槽位（EquipmentData.Slot）；rarity_floor - 稀有度下限（EquipmentData.Rarity）
## 返回：词条总数不低于 rarity_floor 的 EquipmentData（池不足时可能仍达不到，属数据边界）
## 设计意图：合成是"消耗玩家资源"的行为，复用掉落生成器后再补足词条，保证回报不低于稀有
func generate_equipment_with_floor(slot: int, rarity_floor: int) -> Resource:
	return EquipmentGeneratorClass.generate_with_floor(slot, rarity_floor, _build_equipment_pools())

## 组装装备生成所需的模板池字典（从既有池派生，零新增数据目录）
## 返回：池字典，键约定与 EquipmentGenerator.generate 的 pools 参数一致：
##       "affix_templates"  - 属性词条模板（旧词条中含 stat_modifiers 者，读 equip_slots 决定槽位）
##       "effect_templates" - 特效模板（旧词条中含 bullet_effect 者，读 equip_slots 决定槽位）
##       "pattern_pool"     - 弹道构型池（主动技能来源）
##       "shield_pool"      - 护盾蓝图池（盾牌槽护盾来源）
## 设计意图：装备是"聚合/来源层"——词条/特效模板直接复用 data/upgrades/*.tres，
##          护盾/构型复用各自目录，因此新增成长内容无需为装备系统单独维护模板
func _build_equipment_pools() -> Dictionary:
	var affix_templates: Array = []
	var effect_templates: Array = []
	for upgrade in _upgrade_pool:
		if upgrade == null:
			continue
		## 含属性修正 → 可作基础属性词条模板
		var mods: Variant = upgrade.stat_modifiers
		if mods is Dictionary and not (mods as Dictionary).is_empty():
			affix_templates.append(upgrade)
		## 含子弹特效 → 可作特效模板
		if upgrade.bullet_effect != null:
			effect_templates.append(upgrade)
	return {
		"affix_templates": affix_templates,
		"effect_templates": effect_templates,
		"pattern_pool": _shot_pattern_pool,
		"shield_pool": _shield_pool,
	}

## 随机生成一件装备并放入玩家背包（开局赠送 / 专家拾取 / 神庙求购的统一入口）
## 返回：true=成功入背包；false=生成失败 / 背包已满 / 玩家无效
func grant_random_equipment() -> bool:
	var eq: Resource = generate_equipment()
	if eq == null:
		return false
	var player: Node2D = _get_player()
	if player == null or not player.has_method("add_equipment_to_backpack"):
		return false
	return bool(player.add_equipment_to_backpack(eq))

## ========== 神庙强化碎片消耗（累加计价） ==========

## 获取当前神庙强化的消耗碎片数（累加：第1次400、第2次500、第3次600……）
## 返回：本次强化需消耗的碎片数
func get_temple_boost_cost() -> int:
	return TEMPLE_BOOST_BASE_COST + _temple_boost_count * TEMPLE_BOOST_COST_STEP

## 尝试扣除神庙强化的碎片（累加计价）
## 规则：扣除成功后才递增计数（失败不计数，神庙保留可重试）
## 参数：player - 玩家节点
## 返回：true=扣除成功，false=碎片不足或玩家无效
func consume_temple_boost(player: Node) -> bool:
	if player == null or not player.has_method("spend_dream_fragment"):
		return false
	var cost: int = get_temple_boost_cost()
	if not player.spend_dream_fragment(cost):
		return false
	_temple_boost_count += 1
	return true

## ========== 神庙"强化装备"（属性/特效，作用于已穿戴装备） ==========

## 获取玩家的装备组件（EquipmentComponent）
## 返回：组件节点；玩家无该组件时返回 null
func _get_equipment_component() -> Node:
	var player: Node2D = _get_player()
	if player == null or not player.has_method("get_equipment_component"):
		return null
	var comp: Variant = player.get_equipment_component()
	if comp is Node:
		return comp as Node
	return null

## 获取玩家的背包组件（BackpackComponent；融合材料与产出入包用）
## 返回：组件节点；玩家无该组件时返回 null
func _get_backpack() -> Node:
	var player: Node2D = _get_player()
	if player == null or not player.has_method("get_backpack"):
		return null
	var bp: Variant = player.get_backpack()
	if bp is Node:
		return bp as Node
	return null

## 收集全部已穿戴装备上的可强化项（"强化装备"选项的强化目标池）
## 返回：字典数组，元素结构 { owner: EquipmentData, kind: String, ref: Resource }
##       kind ∈ {"affix"属性词条, "effect"被动特效, "skill"主动技能, "shield"护盾蓝图}
## 设计意图：把"属性/被动/主动/护盾"四类强化目标统一成同构候选，
##          随机抽一项即可实现"随机强化某件装备的某一类数值"
func _collect_enhance_candidates() -> Array:
	var candidates: Array = []
	var comp: Node = _get_equipment_component()
	if comp == null or not comp.has_method("get_all_equipped"):
		return candidates
	for data in comp.get_all_equipped():
		if data == null:
			continue
		## 属性词条
		var affixes: Variant = data.get("affixes")
		if affixes is Array:
			for affix in affixes:
				if affix != null:
					candidates.append({"owner": data, "kind": "affix", "ref": affix})
		## 被动特效
		var effects: Variant = data.get("bullet_effects")
		if effects is Array:
			for effect in effects:
				if effect != null:
					candidates.append({"owner": data, "kind": "effect", "ref": effect})
		## 主动技能（仅武器/戒指/法宝可能携带）
		if data.has_method("has_active_skill") and data.has_active_skill():
			candidates.append({"owner": data, "kind": "skill", "ref": data.active_skill})
		## 护盾蓝图（仅盾牌槽携带）
		var shield: Variant = data.get("shield_data")
		if shield != null:
			candidates.append({"owner": data, "kind": "shield", "ref": shield})
	return candidates

## 是否存在可强化的已穿戴装备（"强化装备"选项预检查/置灰用）
## 返回：true=至少有一件已穿戴装备携带可强化项（属性/被动/主动/护盾任一）
func has_enhanceable_equipped() -> bool:
	return not _collect_enhance_candidates().is_empty()

## 随机强化一件已穿戴装备上的某一类数值（属性/被动/主动/护盾任选其一）
## 返回：结果字典 { "success": bool, "message": String }；message 为给玩家的反馈文案
## 强化口径：
##   属性词条 → value ×(1+EQUIPMENT_BOOST_RATIO)
##   被动特效 → add_stack() 叠层 +1（子类 _on_stack_grown 放大参数）
##   主动技能 → cooldown ×(1-EQUIPMENT_BOOST_RATIO)，下限 1.0 秒
##   护盾蓝图 → 走 Player.boost_shield_stack(1) 叠层 +1（改蓝图会因同引用短路不生效）
## 前三类强化后调 _reequip_owner 原地重穿，触发 EquipmentComponent._refresh() 全量重算
func enhance_random_equipped_equipment() -> Dictionary:
	var candidates: Array = _collect_enhance_candidates()
	if candidates.is_empty():
		return {"success": false, "message": "没有可强化的已装备装备"}
	var pick: Dictionary = candidates[RandomManager.randi_range(0, candidates.size() - 1)]
	var owner: Resource = pick["owner"]
	var kind: String = String(pick["kind"])
	var ref: Variant = pick["ref"]
	## 装备前缀文案（稀有度 + 槽位，如"史诗武器"），让玩家知道是哪件装备被强化
	var prefix: String = _equipment_prefix(owner)
	match kind:
		"affix":
			var affix: Resource = ref
			affix.value = float(affix.value) * (1.0 + EQUIPMENT_BOOST_RATIO)
			_reequip_owner(owner)
			var affix_text: String = String(affix.get_display_text()) if affix.has_method("get_display_text") else ""
			return {"success": true, "message": "强化成功！\n%s\n属性「%s」" % [prefix, affix_text]}
		"effect":
			var effect: Resource = ref
			if effect.has_method("add_stack"):
				effect.add_stack()
			_reequip_owner(owner)
			var effect_text: String = String(effect.get_effect_description()) if effect.has_method("get_effect_description") else ""
			var stacks: int = int(effect.stack_count) if "stack_count" in effect else 1
			return {"success": true, "message": "强化成功！\n%s\n被动「%s」（%d 层）" % [prefix, effect_text, stacks]}
		"skill":
			var skill: Resource = ref
			skill.cooldown = maxf(float(skill.cooldown) * (1.0 - EQUIPMENT_BOOST_RATIO), 1.0)
			_reequip_owner(owner)
			return {"success": true, "message": "强化成功！\n%s\n主动「%s」冷却缩短至 %.1f 秒" % [prefix, String(skill.display_name), float(skill.cooldown)]}
		"shield":
			## 护盾强化必须走 Player.boost_shield_stack：
			## EquipmentComponent._refresh_shield() 对同一 shield_data 引用做短路，改蓝图数值不会生效
			var player: Node2D = _get_player()
			if player == null or not player.has_method("boost_shield_stack"):
				return {"success": false, "message": "护盾强化失败"}
			if not bool(player.boost_shield_stack(1)):
				return {"success": false, "message": "护盾强化失败"}
			return {"success": true, "message": "强化成功！\n%s\n护盾叠层 +1" % prefix}
	return {"success": false, "message": "强化失败"}

## 拼装备前缀文案（稀有度 + 槽位，如"史诗武器"）
## 参数：data - EquipmentData
## 返回：前缀文本
func _equipment_prefix(data: Resource) -> String:
	if data == null:
		return "装备"
	var rarity_text: String = String(data.get_rarity_text()) if data.has_method("get_rarity_text") else ""
	var slot_text: String = String(data.get_slot_text()) if data.has_method("get_slot_text") else ""
	return rarity_text + slot_text

## 组织装备简要明细文案（词条/被动/主动/护盾，供融合结果反馈展示）
## 参数：data - EquipmentData
## 返回：多行明细文本（无内容为空串）
func _equipment_summary(data: Resource) -> String:
	if data == null:
		return ""
	var lines: Array = []
	for affix in data.affixes:
		if affix != null and affix.has_method("get_display_text"):
			lines.append("· " + String(affix.get_display_text()))
	for effect in data.bullet_effects:
		if effect == null:
			continue
		var desc: String = String(effect.get_effect_description()) if effect.has_method("get_effect_description") else ""
		lines.append("· 被动 " + desc)
	if data.has_method("has_active_skill") and data.has_active_skill():
		lines.append("· 主动 " + String(data.active_skill.display_name))
	if data.get("shield_data") != null:
		lines.append("· 护盾 " + String(data.shield_data.display_name))
	return "\n".join(lines)

## 组织「获得装备」反馈文案（前缀 + 明细），供商店合成等产出统一展示
## 参数：data - 产出的装备数据
## 返回：形如 "获得「史诗武器」\n· 攻击力 +12%\n· 被动 穿透"；data 为空返回空串
func build_obtain_message(data: Resource) -> String:
	if data == null:
		return ""
	var head: String = "获得「%s」" % _equipment_prefix(data)
	var summary: String = _equipment_summary(data)
	return head if summary == "" else head + "\n" + summary

## ========== 神庙"融合装备"（背包同槽位 3 件材料 → 随机产出） ==========

## 是否可进行融合（"融合装备"选项预检查/置灰用）
## 规则：背包中存在某槽位装备 ≥3 件
func can_fuse_equipment() -> bool:
	return not _collect_fuse_materials().is_empty()

## 获取神庙"融合装备"每次消耗的梦境碎片数（面板价格展示与置灰判定共用）
func get_fuse_cost() -> int:
	return FUSE_DREAM_COST

## 尝试扣除神庙"融合装备"消耗的梦境碎片
## 参数：player - 玩家节点
## 返回：true=扣费成功；false=玩家无效或碎片不足（不扣费）
func consume_fuse_cost(player: Node) -> bool:
	if player == null or not player.has_method("spend_dream_fragment"):
		return false
	return bool(player.spend_dream_fragment(FUSE_DREAM_COST))

## 收集本次融合材料：取"件数最多且≥3"的槽位，再取该槽位稀有度最低的 3 件
## 返回：{ "slot": int, "materials": Array }；不满足条件时返回空字典
## 设计意图：材料全部取自背包（装备系统唯一成长载体），材料消耗即成本；
##          另需消耗梦境碎片（FUSE_DREAM_COST），由调用方先行扣除
func _collect_fuse_materials() -> Dictionary:
	var backpack: Node = _get_backpack()
	if backpack == null or not backpack.has_method("get_items"):
		return {}
	var items: Array = backpack.get_items()
	## 按槽位分组（记录背包下标，便于按稀有度排序后取最低 3 件）
	var groups: Dictionary = {}
	for i in range(items.size()):
		var data: Resource = items[i]
		if data == null:
			continue
		var slot: int = int(data.slot)
		if not groups.has(slot):
			groups[slot] = []
		(groups[slot] as Array).append(i)
	## 选"件数最多且≥3"的槽位；并列时取槽位序号小者，保证结果稳定可预期
	var best_slot: int = -1
	var best_count: int = 0
	for slot in groups.keys():
		var count: int = (groups[slot] as Array).size()
		if count < 3:
			continue
		if count > best_count or (count == best_count and (best_slot < 0 or int(slot) < best_slot)):
			best_slot = int(slot)
			best_count = count
	if best_slot < 0:
		return {}
	## 该槽位按稀有度升序排列（同稀有度保持原背包顺序），取最低 3 件为材料
	var idxs: Array = groups[best_slot]
	idxs.sort_custom(func(a: int, b: int) -> bool:
		return int(items[a].rarity) < int(items[b].rarity)
	)
	var materials: Array = []
	for k in range(3):
		materials.append(items[idxs[k]])
	return {"slot": best_slot, "materials": materials}

## 执行融合：消耗 3 件同槽位最低稀有度材料，随机产出一件融合装备
## 返回：结果字典 { "success": bool, "message": String }
## 概率模型：
##   30% → "更好"（词条总数不低于材料最高稀有度对应的保底，数值再放大，并 roll 稀有度提升）
##   30% → "更差或持平"（无保底常规生成，可能低于材料）
##   40% → "融合失败"（无产出）
## 材料无论成败全部消耗（success=操作是否执行，不代表"是否产出装备"）
func fuse_equipment() -> Dictionary:
	var info: Dictionary = _collect_fuse_materials()
	if info.is_empty():
		return {"success": false, "message": "没有可融合的装备"}
	var slot: int = int(info["slot"])
	var materials: Array = info["materials"]
	var backpack: Node = _get_backpack()
	if backpack == null or not backpack.has_method("remove_item"):
		return {"success": false, "message": "融合失败：背包不可用"}

	## 材料最高稀有度：用于"更好"结果的保底下限与稀有度提升判定
	var best_rarity: int = 0
	for m in materials:
		best_rarity = maxi(best_rarity, int(m.rarity))

	## 先消耗全部材料（成败一致：融合失败也消耗 3 件）
	for m in materials:
		backpack.remove_item(m)

	## roll 融合结果
	var roll: float = RandomManager.randf()
	if roll < FUSE_BETTER_CHANCE:
		var eq: Resource = _fuse_make_better(slot, best_rarity, materials)
		## 极端异常（池为空等）无产出时按失败处理，避免向玩家展示空结果
		if eq == null:
			return {"success": true, "message": "融合失败……三件材料已消耗"}
		## 材料已消耗 3 件，背包必有空位；入包失败仅作兜底提示，不影响操作成功
		if not bool(backpack.add_item(eq)):
			return {"success": true, "message": "融合大成功！结果优于材料\n（背包空间不足，产出已遗失）"}
		return {"success": true, "message": "融合大成功！结果优于材料\n获得「%s」\n%s" % [_equipment_prefix(eq), _equipment_summary(eq)]}
	if roll < FUSE_BETTER_CHANCE + FUSE_WORSE_CHANCE:
		var eq2: Resource = _fuse_make_worse_or_same(slot)
		if eq2 == null:
			return {"success": true, "message": "融合失败……三件材料已消耗"}
		if not bool(backpack.add_item(eq2)):
			return {"success": true, "message": "融合完成，结果平平\n（背包空间不足，产出已遗失）"}
		return {"success": true, "message": "融合完成，结果平平\n获得「%s」\n%s" % [_equipment_prefix(eq2), _equipment_summary(eq2)]}
	return {"success": true, "message": "融合失败……三件材料已消耗"}

## 生成"更好"的融合结果：以材料最高稀有度为保底生成，再整体放大词条数值
## 稀有度提升：仅在本分支内再 roll，概率 = 基准 + 三件材料稀有度权重之和（封顶 FUSE_RARITY_UPGRADE_MAX）
## 参数：slot - 目标槽位；best_rarity - 材料最高稀有度；materials - 三件材料
## 返回：EquipmentData；生成失败返回 null
func _fuse_make_better(slot: int, best_rarity: int, materials: Array) -> Resource:
	var upgrade_chance: float = FUSE_RARITY_UPGRADE_BASE
	for m in materials:
		var r: int = clampi(int(m.rarity), 0, FUSE_RARITY_WEIGHT_BY_RARITY.size() - 1)
		upgrade_chance += float(FUSE_RARITY_WEIGHT_BY_RARITY[r])
	upgrade_chance = minf(upgrade_chance, FUSE_RARITY_UPGRADE_MAX)
	var floor_rarity: int = best_rarity
	if RandomManager.chance(upgrade_chance):
		floor_rarity = mini(best_rarity + 1, EquipmentDataClass.Rarity.EPIC)
	var eq: Resource = generate_equipment_with_floor(slot, floor_rarity)
	if eq == null:
		return null
	## 在保底生成基础上再整体放大词条数值，确保"比材料好一点"
	for affix in eq.affixes:
		if affix != null:
			affix.value = float(affix.value) * (1.0 + FUSE_BETTER_BOOST_RATIO)
	return eq

## 生成"更差或持平"的融合结果：无保底常规生成（可能低于材料）
## 参数：slot - 目标槽位
## 返回：EquipmentData；生成失败返回 null
func _fuse_make_worse_or_same(slot: int) -> Resource:
	return generate_equipment(slot)

## 原地刷新一件已穿戴装备（重新 equip 触发 EquipmentComponent._refresh 全量重算/特效重建）
## 说明：装备是同一对象引用，_refresh 会按当前装备数据重新下发词条/特效/护盾/主动技能
## 参数：data - 已穿戴的 EquipmentData
## 返回：true=刷新成功
func _reequip_owner(data: Resource) -> bool:
	if data == null:
		return false
	var comp: Node = _get_equipment_component()
	if comp == null or not comp.has_method("equip"):
		return false
	return bool(comp.equip(data))

## ========== 辅助方法 ==========

## 获取玩家节点（通过player组查找）
## 返回：玩家节点，未找到返回null
func _get_player() -> Node2D:
	var players: Array = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		return players[0] as Node2D
	return null
