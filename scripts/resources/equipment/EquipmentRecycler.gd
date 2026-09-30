## EquipmentRecycler.gd - 装备回收/合成工具类（纯静态，无状态）
## 职责：集中定义"分解装备"与"碎片合成装备"的数值口径，并提供纯函数式计算
## 继承：RefCounted（与 EquipmentGenerator 同构的纯工具类，便于单点调参）
## 设计意图：
##   1. 数值全部收敛在常量区，策划调参只改这里，不散落到 UI/组件
##   2. 分解产出严格低于商店售价，堵死"买→分解→赚差价"的套利漏洞
##   3. 装备碎片按槽位堆叠（不携带词条实体），合成时从该槽位词条池重新随机 roll，
##      避免碎片各自带词条导致不可堆叠、背包管理失控
## 被引用方：BackpackComponent（分解产出）、商店合成面板（消耗碎片合成装备）
class_name EquipmentRecycler
extends RefCounted

## ========== 数值配置（集中调节点） ==========

## 分解产出的梦境碎片占商店售价的比例（建议 0.3~0.4；必须 < 1.0 以防套利）
const RECYCLE_RATE: float = 0.35

## 装备售价基准表（用于分解产出折算：售价 × RECYCLE_RATE；商店已改为固定服务，
## 不再按稀有度直接售卖装备，此表仅作分解收益的定价基准，改价只影响分解产出）
const SELL_PRICE := {
	EquipmentData.Rarity.COMMON: 60,
	EquipmentData.Rarity.RARE: 120,
	EquipmentData.Rarity.EPIC: 220,
}

## 每分解一件装备，额外产出的"同槽位装备碎片"数量
const FRAGMENT_PER_DISMANTLE: int = 1

## 合成一件装备所需的"同槽位装备碎片"数量
const CRAFT_FRAGMENT_COST: int = 3

## 合成一件装备额外消耗的"梦境碎片"数量（在 CRAFT_FRAGMENT_COST 装备碎片之外）
const CRAFT_DREAM_COST: int = 100

## 合成装备的稀有度保底（保底稀有 = 至少 3 条词条，见 EquipmentGenerator._derive_rarity）
const CRAFT_RARITY_FLOOR: int = EquipmentData.Rarity.RARE

## ========== 对外接口：分解 ==========

## 计算分解一件装备可获得的梦境碎片数量
## 参数：data - 待分解装备
## 返回：梦境碎片数量（售价 × RECYCLE_RATE 向下取整，至少 1；data 为空返回 0）
static func get_fragment_yield(data: EquipmentData) -> int:
	if data == null:
		return 0
	var price: int = int(SELL_PRICE.get(data.rarity, SELL_PRICE[EquipmentData.Rarity.COMMON]))
	return maxi(1, int(floor(float(price) * RECYCLE_RATE)))

## 计算分解一件装备的完整产出明细
## 参数：data - 待分解装备
## 返回：{ "dream": 梦境碎片数, "slot": 槽位, "fragment": 装备碎片数 }；data 为空时返回 {}
static func get_dismantle_result(data: EquipmentData) -> Dictionary:
	if data == null:
		return {}
	return {
		"dream": get_fragment_yield(data),
		"slot": int(data.slot),
		"fragment": FRAGMENT_PER_DISMANTLE,
	}
