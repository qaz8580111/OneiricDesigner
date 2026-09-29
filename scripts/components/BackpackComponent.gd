## BackpackComponent.gd - 背包组件（RPG装备系统的存储与穿戴入口）
## 职责：持有玩家拾取/掉落得到的装备（EquipmentData），提供增删查询与"穿戴/卸下"操作
## 继承：Node（纯逻辑组件，无 class_name，由 Player._ready() 代码创建并 add_child）
## 挂载位置：由 Player 运行时创建，名称为 "BackpackComponent"
##
## 设计意图：
##   1. 背包与装备分离：背包是"仓库"（含容量上限），装备是"已生效的成长来源"，
##      两者通过 equip_from_backpack() / unequip_to_backpack() 交互，职责单一
##   2. 穿戴即交换：把背包装备到槽位时，该槽位原有装备自动回退到背包（无丢失），
##      并正确处理"背包已满"的边界（先腾位再放入，避免溢出丢件）
##   3. 每件装备独占一格（装备为随机产物，不做堆叠），保证"随机性/趣味性"不被合并抹平
##
## 数据流：掉落/商店 → Player.add_equipment_to_backpack() → 本组件持有
##         → UI 背包面板 → equip_from_backpack() → EquipmentComponent.equip() → 生效
extends Node

## ========== 信号定义 ==========

## 背包内容变化信号（供 HUD / 背包面板刷新显示）
signal backpack_changed()

## ========== 成员变量 ==========

## 归属玩家（由 setup 注入；用于转发查询）
var _player: Node = null

## 关联的装备组件（穿戴/卸下的执行者；由 setup 注入）
var _equipment: Node = null

## 背包物品列表（Array[EquipmentData]，每件独占一格）
var _items: Array = []

## 背包容量（格数）
var capacity: int = 24

## ========== 生命周期 ==========

## 初始化组件（由 Player._ready() 调用）
## 参数：player - 归属玩家节点
##       equipment - 装备组件（EquipmentComponent）
##       cap - 背包容量（格数，<=0 时使用默认 24）
func setup(player: Node, equipment: Node, cap: int = 24) -> void:
	_player = player
	_equipment = equipment
	capacity = cap if cap > 0 else 24

## ========== 公开接口：增删查询 ==========

## 向背包添加一件装备
## 参数：data - EquipmentData 装备实例
## 返回：true=添加成功；false=参数为空或背包已满
func add_item(data: Resource) -> bool:
	if data == null:
		return false
	if is_full():
		return false
	_items.append(data)
	backpack_changed.emit()
	return true

## 移除指定下标的物品
## 参数：index - 物品下标（0-based）
## 返回：true=移除成功；false=下标越界
func remove_item_at(index: int) -> bool:
	if index < 0 or index >= _items.size():
		return false
	_items.remove_at(index)
	backpack_changed.emit()
	return true

## 移除指定物品实例（按引用匹配第一个）
## 参数：data - 物品实例
## 返回：true=移除成功；false=未找到
func remove_item(data: Resource) -> bool:
	var idx: int = _items.find(data)
	if idx < 0:
		return false
	return remove_item_at(idx)

## 获取全部物品（返回内部数组引用；仅供读取展示，勿直接改动）
## 返回：Array[EquipmentData]
func get_items() -> Array:
	return _items

## 获取指定下标物品
## 参数：index - 物品下标（0-based）
## 返回：EquipmentData；越界时返回 null
func get_item_at(index: int) -> Resource:
	if index < 0 or index >= _items.size():
		return null
	return _items[index]

## 获取当前物品数量
## 返回：物品件数
func get_count() -> int:
	return _items.size()

## 背包是否已满
## 返回：true=已满（数量达到容量上限）
func is_full() -> bool:
	return _items.size() >= capacity

## 清空背包（重开一局时调用）
func clear() -> void:
	if _items.is_empty():
		return
	_items.clear()
	backpack_changed.emit()

## ========== 公开接口：穿戴 / 卸下 ==========

## 穿戴背包中指定下标的装备（该槽位原有装备自动回退到背包）
## 参数：index - 背包物品下标（0-based）
## 返回：true=穿戴成功；false=下标越界或组件缺失
func equip_from_backpack(index: int) -> bool:
	if _equipment == null or index < 0 or index >= _items.size():
		return false
	var data: Resource = _items[index]
	if data == null:
		return false
	## 记录该装备将要占用的槽位，取出待穿装备与槽位原有装备（用于交换）
	var slot: int = int(data.slot)
	var old_equipped: Resource = _equipment.get_equipped(slot)
	## 先把待穿装备从背包移出（腾出至少一格，保证后续回退件能放回而不溢出）
	_items.remove_at(index)
	## 执行穿戴（EquipmentComponent 内部会全量重算四类成长来源）
	if not _equipment.equip(data):
		## 穿戴失败：回滚，把装备放回背包（保持数据不丢失）
		_items.append(data)
		backpack_changed.emit()
		return false
	## 槽位原有装备回退到背包（此时已有一格空位，容量充足）
	if old_equipped != null:
		_items.append(old_equipped)
	backpack_changed.emit()
	return true

## 卸下指定槽位的装备并放回背包
## 参数：slot - 槽位（EquipmentData.Slot）
## 返回：true=卸下成功；false=槽位为空 / 背包已满 / 组件缺失
func unequip_to_backpack(slot: int) -> bool:
	if _equipment == null:
		return false
	var data: Resource = _equipment.get_equipped(slot)
	if data == null:
		return false
	## 背包已满则拒绝（避免装备丢失）
	if is_full():
		return false
	## 先从装备组件卸下（全量重算），再放入背包
	if not _equipment.unequip(slot):
		return false
	_items.append(data)
	backpack_changed.emit()
	return true
