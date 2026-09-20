## ShopProduct.gd - 商店商品数据资源类
## 职责：定义商店单个商品的展示数据、价格与购买后效果，实现商品的数据驱动
## 继承：Resource（运行时由 Shop 生成器填充，也可扩展为 .tres 配置）
## 使用场景：主场景中央商店（5分钟后出现）每 60 秒随机刷新 3 件商品
## 数据流：Shop._roll_products() → 构造 ShopProduct → ShopPanel 展示 →
##         玩家选定 → Shop 扣款 → ShopProduct.apply() 应用效果
## 设计意图：商品效果完全落在"现有技能/装备体系"内——
##           属性类=UpgradeManager 属性词条（bullet_effect 为空）；
##           技能类=UpgradeManager 特效词条（bullet_effect 非空）；
##           护盾类=data/equipment/ 下的 ShieldEquipmentData；
##           血包=直接回核心血量。新增商品只需扩展生成器，无需改面板代码
class_name ShopProduct
extends Resource

## ========== 商品类型枚举 ==========

enum ProductType {
	ATTRIBUTE,  ## 属性类：随机一个属性词条（伤害/射速/移速/弹速/生命上限等纯数值加成）
	SKILL,      ## 技能类：随机一个子弹特效词条（爆炸/毒/冰冻/连锁闪电等）
	SHIELD,     ## 护盾类：随机一件装备护盾（同类型叠加，不同类型替换）
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

## 属性类/技能类商品挂载的 UpgradeData 资源
var upgrade_data: Resource = null

## 护盾类商品挂载的 ShieldEquipmentData 资源
var shield_data: Resource = null

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
		ProductType.ATTRIBUTE, ProductType.SKILL:
			## 属性/技能词条：复用 UpgradeManager 统一应用管线（计数/信号/属性累积/HUD刷新）
			if upgrade_data != null:
				UpgradeManager.apply_upgrade(upgrade_data)
				return true
		ProductType.SHIELD:
			## 装备护盾：走 Player.equip_shield → EquipmentShieldComponent.equip
			if shield_data != null and player.has_method("equip_shield"):
				player.equip_shield(shield_data)
				return true
		ProductType.HEALTH:
			## 回血：走 Player.heal（可溢出至上限，由 CoreHealthComponent 自行钳制）
			if heal_amount > 0 and player.has_method("heal"):
				player.heal(float(heal_amount))
				return true

	return false
