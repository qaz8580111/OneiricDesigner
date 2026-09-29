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

## 神庙"求购装备"固定消耗的梦境碎片数（比随机强化贵，但直接获得一件完整新装备入背包）
const PURCHASE_EQUIPMENT_COST: int = 500

## 神庙"强化装备属性"每次强化的数值增幅比例（在现有词条数值基础上 ×(1+该比例)）
const EQUIPMENT_BOOST_RATIO: float = 0.2

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

## 收集全部已穿戴装备的 (装备实例, 词条) 对
## 返回：字典数组，元素结构 {owner: EquipmentData, affix: EquipmentAffix}
func _collect_equipped_affix_pairs() -> Array:
	var pairs: Array = []
	var comp: Node = _get_equipment_component()
	if comp == null or not comp.has_method("get_all_equipped"):
		return pairs
	for data in comp.get_all_equipped():
		if data == null:
			continue
		var affixes: Variant = data.get("affixes")
		if affixes is Array:
			for affix in affixes:
				if affix != null:
					pairs.append({"owner": data, "affix": affix})
	return pairs

## 收集全部已穿戴装备的 (装备实例, 特效) 对
## 返回：字典数组，元素结构 {owner: EquipmentData, effect: BulletEffect}
func _collect_equipped_effect_pairs() -> Array:
	var pairs: Array = []
	var comp: Node = _get_equipment_component()
	if comp == null or not comp.has_method("get_all_equipped"):
		return pairs
	for data in comp.get_all_equipped():
		if data == null:
			continue
		var effects: Variant = data.get("bullet_effects")
		if effects is Array:
			for effect in effects:
				if effect != null:
					pairs.append({"owner": data, "effect": effect})
	return pairs

## 是否有可强化的装备词条（"强化装备属性"选项预检查/置灰用）
## 返回：true=至少有一件已穿戴装备携带词条
func has_boostable_equipment_affix() -> bool:
	return not _collect_equipped_affix_pairs().is_empty()

## 是否有可强化的装备特效（"强化装备特效"选项预检查/置灰用）
## 返回：true=至少有一件已穿戴装备携带特效
func has_boostable_equipment_effect() -> bool:
	return not _collect_equipped_effect_pairs().is_empty()

## 随机强化一件已穿戴装备的一条词条（数值 ×(1+EQUIPMENT_BOOST_RATIO)）
## 流程：随机取一条词条 → 放大其 value → 原地重新 equip 触发 EquipmentComponent._refresh() 全量重算
## 返回：是否强化成功（无已穿戴词条时返回 false，神庙保留不消失）
func boost_random_equipment_affix() -> bool:
	var pairs: Array = _collect_equipped_affix_pairs()
	if pairs.is_empty():
		return false
	var pair: Dictionary = pairs[RandomManager.randi_range(0, pairs.size() - 1)]
	var affix: Resource = pair["affix"]
	affix.value = float(affix.value) * (1.0 + EQUIPMENT_BOOST_RATIO)
	return _reequip_owner(pair["owner"])

## 随机强化一件已穿戴装备的一个特效（叠层 +1，触发 _on_stack_grown 参数放大）
## 流程：随机取一个特效 → add_stack() → 原地重新 equip 触发 _refresh() 全量重建特效
## 返回：是否强化成功（无已穿戴特效时返回 false，神庙保留不消失）
func boost_random_equipment_effect() -> bool:
	var pairs: Array = _collect_equipped_effect_pairs()
	if pairs.is_empty():
		return false
	var pair: Dictionary = pairs[RandomManager.randi_range(0, pairs.size() - 1)]
	var effect: Resource = pair["effect"]
	if effect.has_method("add_stack"):
		effect.add_stack()
	return _reequip_owner(pair["owner"])

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
