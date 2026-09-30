## EquipmentComponent.gd - 装备组件（RPG装备系统核心）
## 职责：管理玩家6个装备槽，聚合装备的四类成长来源（词条/特效/护盾/主动技能）
## 继承：Node（纯逻辑组件，无 class_name，由 Player._ready() 代码创建并 add_child；
##       遵循"组合优于继承"——装备是可插拔能力，不应污染 Player 的继承链）
## 挂载位置：由 Player 运行时创建，名称为 "EquipmentComponent"
##
## 设计意图（解耦性核心）：
##   装备只是"成长来源的聚合层"，不修改任何策略基类——
##   1. 词条：汇总各装备 get_affix_totals() → UpgradeManager.set_equipment_bonus()（触发全量重算）
##   2. 特效：全量重建注入 Player 私有子弹副本（apply_equipment_effect / remove_bullet_effect）
##   3. 护盾：盾牌槽数据变化时驱动 Player.equip_shield()/unequip_equipped_shield()
##   4. 主动技能：收集全部携带技能的装备（按 skill_id 去重）→ Player.set_active_skills()
##
## 数据流：装备生成 → 入背包 → BackpackComponent 穿戴 → 本组件.equip() → _refresh() 下发四类来源
##         → UpgradeManager.stats_recomputed → Player._sync_upgrade_stats 同步到自身
##
## 健壮性：每次装备变更都 _refresh() 全量重算（而非增量），彻底消除"卸下/替换"路径上的脏数据
extends Node

## 装备数据类（用于访问 Slot 枚举；无 class_name 依赖，走 preload）
const EquipmentDataClass = preload("res://scripts/resources/equipment/EquipmentData.gd")

## ========== 信号定义 ==========

## 装备变更信号（供 HUD / 背包 / 装备面板刷新显示）
signal equipment_changed()

## ========== 成员变量 ==========

## 归属玩家（由 setup 注入；用于下发特效/护盾/主动技能）
var _player: Node = null

## 已装备映射：槽位(int, EquipmentData.Slot) → EquipmentData（未装备的槽位不出现）
var _equipped: Dictionary = {}

## 上一轮注入到 Player 的装备特效 id 集合（用于全量重建时精准移除）
var _applied_effect_ids: Dictionary = {}

## 上一轮下发给 EquipmentShieldComponent 的护盾数据（用于判断盾牌槽是否真正变化，
## 避免非盾牌槽装备变更时重复 equip 造成同盾叠层）
var _applied_shield_data: Resource = null

## ========== 生命周期 ==========

## 初始化组件（由 Player._ready() 调用）
## 参数：player - 归属玩家节点（用于回调 Player 的公开方法）
func setup(player: Node) -> void:
	_player = player
	## 初始下发一次（此时通常无装备，等于把装备加成重置为空并同步一次状态）
	_refresh()

## ========== 公开接口：穿戴 / 卸下 / 查询 ==========

## 穿戴一件装备（同槽位已有装备则整体替换，不叠层）
## 参数：data - EquipmentData 装备实例（非空）
## 返回：true=穿戴成功；false=参数非法（空/槽位越界/未初始化）
func equip(data: Resource) -> bool:
	if data == null or _player == null:
		return false
	## 槽位合法性校验（防止误传其他 Resource 导致后续按错误槽位归档）
	var slot: int = int(data.slot)
	if slot < 0 or slot > EquipmentDataClass.Slot.TALISMAN:
		return false
	## 直接覆盖同槽位（旧装备无需先卸下——_refresh 全量重算，不会残留旧装备加成）
	_equipped[slot] = data
	_refresh()
	return true

## 卸下指定槽位的装备
## 参数：slot - 槽位（EquipmentData.Slot）
## 返回：true=卸下成功；false=该槽位本就为空
func unequip(slot: int) -> bool:
	if not _equipped.has(slot):
		return false
	_equipped.erase(slot)
	_refresh()
	return true

## 查询指定槽位当前装备
## 参数：slot - 槽位（EquipmentData.Slot）
## 返回：EquipmentData；未装备时返回 null
func get_equipped(slot: int) -> Resource:
	return _equipped.get(slot, null)

## 查询某槽位是否已装备
## 参数：slot - 槽位（EquipmentData.Slot）
## 返回：true=已装备
func is_slot_equipped(slot: int) -> bool:
	return _equipped.has(slot) and _equipped[slot] != null

## 获取全部已装备的装备列表（按槽位枚举顺序，供 UI 稳定展示）
## 返回：Array[EquipmentData]（不含空槽）
func get_all_equipped() -> Array:
	var result: Array = []
	for slot in _slot_order():
		var data: Resource = _equipped.get(slot, null)
		if data != null:
			result.append(data)
	return result

## 获取已装备数量（HUD 展示用）
## 返回：已装备件数
func get_equipped_count() -> int:
	return _equipped.size()

## ========== 内部：全量重算下发 ==========

## 装备变更后的统一入口：全量重算四类成长来源并广播变更信号
## 设计意图：所有"穿戴/卸下/替换"都走同一条全量重算路径，避免增量逻辑分叉出错
func _refresh() -> void:
	_refresh_affixes()
	_refresh_effects()
	_refresh_shield()
	_refresh_active_skill()
	equipment_changed.emit()

## 汇总全部已装备装备的词条 → 推送给 UpgradeManager 触发属性全量重算
## 数据流：各 EquipmentData.get_affix_totals() → 合并字典 → UpgradeManager.set_equipment_bonus()
func _refresh_affixes() -> void:
	var totals: Dictionary = {}
	for slot in _slot_order():
		var data: Resource = _equipped.get(slot, null)
		if data == null:
			continue
		var part: Dictionary = data.get_affix_totals()
		for key in part.keys():
			totals[key] = float(totals.get(key, 0.0)) + float(part[key])
	## 未初始化 UpgradeManager（如脱离主场景的单元测试）时跳过，保证健壮性
	if UpgradeManager and UpgradeManager.has_method("set_equipment_bonus"):
		UpgradeManager.set_equipment_bonus(totals)

## 全量重建装备来源的子弹特效：先移除上一轮注入的全部特效，再按当前装备重新注入
## 设计意图：
##   1. 采用"全量重建"而非"差量增删"——每件装备的特效资源自带 stack_count，
##      重建后可精确还原层数，且天然处理"两件装备提供同 id 特效"的叠层语义
##   2. 移除走 Player.remove_bullet_effect（按 effect_id 精准移除），注入走
##      Player.apply_equipment_effect（同 id 自动叠层成长）
func _refresh_effects() -> void:
	if _player == null:
		return
	## 第一步：移除上一轮注入的全部装备特效（按 id 精准移除）
	if _player.has_method("remove_bullet_effect"):
		for eid in _applied_effect_ids.keys():
			_player.remove_bullet_effect(eid)
	_applied_effect_ids.clear()
	## 第二步：按当前已装备件重新注入（同 id 特效会经 Player 侧叠层成长）
	if not _player.has_method("apply_equipment_effect"):
		return
	for slot in _slot_order():
		var data: Resource = _equipped.get(slot, null)
		if data == null:
			continue
		for effect in data.bullet_effects:
			if effect == null:
				continue
			var eid: String = effect.effect_id if "effect_id" in effect else ""
			if eid == "":
				continue
			_player.apply_equipment_effect(effect)
			_applied_effect_ids[eid] = true

## 同步盾牌槽的护盾数据到 EquipmentShieldComponent（仅当盾牌数据真正变化时才操作）
## 设计意图：先卸旧再装新——避免"同 shield_id 叠加"把替换误当成强化，
##           同时避免非盾牌槽变更时对未变化的盾牌重复 equip 造成层数虚增
func _refresh_shield() -> void:
	if _player == null:
		return
	var data: Resource = _equipped.get(EquipmentDataClass.Slot.SHIELD, null)
	var new_shield: Resource = data.shield_data if data != null else null
	## 未变化 → 不做任何操作（关键：防止重复 equip 叠加层数）
	if new_shield == _applied_shield_data:
		return
	## 变化：先卸下旧护盾
	if _applied_shield_data != null:
		if _player.has_method("unequip_equipped_shield"):
			_player.unequip_equipped_shield()
		_applied_shield_data = null
	## 再装备新护盾（为 null 时表示该槽位无盾，保持卸载状态即可）
	if new_shield != null:
		if _player.has_method("equip_shield"):
			_player.equip_shield(new_shield)
		_applied_shield_data = new_shield

## 下发主动技能：收集全部携带主动技能的装备（按槽位顺序，武器优先），按 skill_id 去重
## 设计意图：主动技能不再"同时只生效一个"——持有多件带技能的装备时全部下发，
##           由 Player 用 Q/E 或手柄 LT/RT 在技能间切换，各技能独立冷却
##           同一 skill_id 可能被多件装备 roll 到，去重避免 HUD 出现重复技能
func _refresh_active_skill() -> void:
	if _player == null:
		return
	var skills: Array[Resource] = []
	var seen: Dictionary = {}
	for slot in _slot_order():
		var data: Resource = _equipped.get(slot, null)
		if data == null:
			continue
		if not data.has_active_skill():
			continue
		var skill: Resource = data.active_skill
		var sid: String = str(skill.skill_id) if "skill_id" in skill else ""
		## skill_id 为空时用实例 id 兜底去重，避免把不同技能误判为同一个
		var dedupe_key: String = sid if sid != "" else str(skill.get_instance_id())
		if seen.has(dedupe_key):
			continue
		seen[dedupe_key] = true
		skills.append(skill)
	if _player.has_method("set_active_skills"):
		_player.set_active_skills(skills)

## 获取槽位遍历顺序（武器→护甲→鞋子→盾牌→戒指→法宝）
## 返回：Array[int] 固定顺序的槽位数组（保证 UI/技能优先级稳定，不随字典插入顺序漂移）
func _slot_order() -> Array:
	return [
		EquipmentDataClass.Slot.WEAPON,
		EquipmentDataClass.Slot.ARMOR,
		EquipmentDataClass.Slot.BOOTS,
		EquipmentDataClass.Slot.SHIELD,
		EquipmentDataClass.Slot.RING,
		EquipmentDataClass.Slot.TALISMAN,
	]
