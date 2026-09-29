## ShopProduct.gd - 商店商品数据资源类
## 职责：定义商店单个商品的展示数据、价格与购买后效果，实现商品的数据驱动
## 继承：Resource（运行时由 Shop 生成器填充，也可扩展为 .tres 配置）
## 使用场景：主场景中央商店（5分钟后出现）每 60 秒随机刷新 3 件商品
## 数据流：Shop._roll_products() → 构造 ShopProduct → ShopPanel 展示 →
##         玩家选定 → Shop 扣款 → ShopProduct.apply() 应用效果
## 设计意图：装备化重构后商品只保留两类，均落在"现有装备体系"内——
##           装备类=随机生成的 EquipmentData（入背包，属性/特效/护盾/主动技能全在其中）；
##           血包=直接回核心血量。新增商品只需扩展生成器，无需改面板代码
class_name ShopProduct
extends Resource

## ========== 商品类型枚举 ==========

enum ProductType {
	EQUIPMENT,  ## 装备类：随机生成一件装备（含词条/特效/护盾/主动技能）放入背包
	HEALTH      ## 血包：立即恢复核心血量
}

## ========== 展示与价格数据 ==========

## 商品唯一标识
@export var product_id: String = ""

## 商品显示名称
@export var display_name: String = ""

## 商品描述（tooltip 详情）
@export var description: String = ""

## 商品主题色（按钮边框/名称颜色）
@export var product_color: Color = Color(1.0, 1.0, 1.0, 1.0)

## 商品类型（决定效果与价格档位）
@export var product_type: ProductType = ProductType.HEALTH

## 售价（梦境碎片数量，价格体系见 docs 清单，由 Shop 生成器按品类/稀有度赋值）
@export var price: int = 0

## ========== 运行时商品载荷（非导出，由生成器填充） ==========

## 装备类商品挂载的 EquipmentData 资源
var equipment_data: Resource = null

## 血包商品恢复的核心血量值
var heal_amount: int = 0

## ========== 核心方法 ==========

## 应用商品效果到玩家（购买成功后由 Shop 调用）
## 参数：player - 玩家节点
## 返回：是否应用成功（失败时 Shop 不扣款/退款）
func apply(player: Node) -> bool:
	if player == null:
		return false

	match product_type:
		ProductType.EQUIPMENT:
			## 装备：走 Player.add_equipment_to_backpack 入背包（背包满时返回 false）
			if equipment_data != null and player.has_method("add_equipment_to_backpack"):
				return player.add_equipment_to_backpack(equipment_data)
		ProductType.HEALTH:
			## 回血：走 Player.heal（可溢出至上限，由 CoreHealthComponent 自行钳制）
			if heal_amount > 0 and player.has_method("heal"):
				player.heal(float(heal_amount))
				return true

	return false
