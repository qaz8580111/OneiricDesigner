## TempleOption.gd - 神庙选项资源基类（策略模式）
## 职责：定义神庙单个选项的展示数据与效果接口，子类实现具体效果
## 继承：Resource（数据驱动，每个选项一个 .tres 文件）
## 设计意图：
##   1. 开闭原则：新增神庙选项只需新建子类 + .tres 文件，无需修改 Temple/TemplePanel 代码
##   2. 展示与效果分离：display_name/description/option_color 供 UI 展示，apply() 执行效果
##   3. is_gamble 标记赌博式选项（UI 上区分"赌博"/"稳妥"标签）
## 被引用方：Temple.tscn 扫描 data/temple/*.tres 加载全部选项
class_name TempleOption
extends Resource

## ========== 展示数据 ==========

## 选项唯一标识
@export var option_id: String = ""

## 选项名称（按钮主文字）
@export var display_name: String = ""

## 选项描述（tooltip 详情）
@export var description: String = ""

## 选项主题色（按钮边框/标题颜色，直观区分选项类型）
@export var option_color: Color = Color(0.9, 0.8, 0.5, 1.0)

## 是否赌博式选项（true=赌博：结果随机可能好可能差；false=稳妥：小幅度固定强化）
@export var is_gamble: bool = false

## ========== 虚方法（子类按需重写） ==========

## 应用选项效果（玩家选定后由 Temple 调用）
## 参数：player - 玩家节点
## 返回：是否应用成功（false=应用失败，神庙保留不消失）
func apply(_player: Node) -> bool:
	return false

## 获取本次选择消耗的梦境碎片（神庙面板价格展示与置灰判定共用）
## 参数：player - 玩家节点（部分选项费用可能随状态变化，如累加计价）
## 返回：需消耗的碎片数，默认0=无消耗
func get_cost(_player: Node) -> int:
	return 0

## 判断玩家是否支付得起本次选择（用于按钮置灰）
## 参数：player - 玩家节点（可能为 null，子类/本类需自行防御）
## 返回：true=碎片充足（或无需消耗）
func is_affordable(player: Node) -> bool:
	var cost: int = get_cost(player)
	if cost <= 0:
		return true
	if player == null or not ("dream_fragment" in player):
		return false
	return int(player.get("dream_fragment")) >= cost

## 判断该选项当前是否可选（TemplePanel 据此置灰不可选项：仍显示但不可确认）
## 默认仅看支付能力；带额外前置条件的子类（如"求购装备"还需背包未满）应重写
## 参数：player - 玩家节点
## 返回：true=可选，false=置灰
func can_select(player: Node) -> bool:
	return is_affordable(player)
