## ShopProduct.gd - 商店商品数据资源类
## 职责：定义商店单个商品的展示数据、价格与购买后效果，实现商品的数据驱动
## 继承：Resource（运行时由 Shop 生成器填充，也可扩展为 .tres 配置）
## 使用场景：主场景中央商店（游戏开始即存在）的三大固定服务
## 数据流：Shop._build_services() → 构造 ShopProduct → ShopPanel 展示 →
##         玩家选定 → Shop 扣款 → ShopProduct.apply() 应用效果
## 设计意图：商品收敛为两件可直接"扣碎片即生效"的固定服务
##           （恢复健康 / 随机装备）；「合成装备」由 ShopPanel 子视图承载，
##           走 Shop._on_craft_requested 消耗装备碎片，不经本类 apply()。
##           新增服务只需加一个 ProductType 分支，无需改面板结构
class_name ShopProduct
extends Resource

## ========== 商品类型枚举 ==========

enum ProductType {
	HEAL_FULL,        ## 恢复健康：消耗梦境碎片，直接把核心血回满
	RANDOM_EQUIPMENT  ## 随机装备：消耗梦境碎片，获得随机稀有度的随机装备入背包
}

## ========== 展示与价格数据 ==========

## 商品唯一标识
@export var product_id: String = ""

## 商品显示名称
@export var display_name: String = ""

## 商品描述（面板提示栏的说明文字，含概率分布等）
@export var description: String = ""

## 商品主题色（按钮边框/名称颜色）
@export var product_color: Color = Color(1.0, 1.0, 1.0, 1.0)

## 商品类型（决定购买后效果）
@export var product_type: ProductType = ProductType.HEAL_FULL

## 售价（梦境碎片数量，由 Shop 生成器赋值）
@export var price: int = 0

## ========== 核心方法 ==========

## 应用商品效果到玩家（购买成功后由 Shop 调用）
## 参数：player - 玩家节点
## 返回：是否应用成功（失败时 Shop 退款兜底，保证玩家不白花钱）
func apply(player: Node) -> bool:
	if player == null:
		return false

	match product_type:
		ProductType.HEAL_FULL:
			## 恢复健康：读取当前缺失血量（上限 - 当前核心血）后一次性补满
			if not player.has_method("get_survival_state") or not player.has_method("heal"):
				return false
			var state: Dictionary = player.get_survival_state()
			var missing: float = float(state.get("max_core", 0.0)) - float(state.get("core", 0.0))
			## 已满血：无需治疗，视为不可应用（由 Shop 前置校验拦截）
			if missing <= 0.0:
				return false
			player.heal(missing)
			return true
		ProductType.RANDOM_EQUIPMENT:
			## 随机装备：从统一生成器产出一件随机稀有度/槽位装备，直接入背包（背包满返回 false）
			if not player.has_method("add_equipment_to_backpack"):
				return false
			var eq: Resource = UpgradeManager.generate_equipment()
			if eq == null:
				return false
			return player.add_equipment_to_backpack(eq)

	return false
