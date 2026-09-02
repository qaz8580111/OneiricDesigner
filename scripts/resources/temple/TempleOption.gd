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

## ========== 虚方法（子类必须重写） ==========

## 应用选项效果（玩家选定后由 Temple 调用）
## 参数：player - 玩家节点
## 返回：是否应用成功（false=应用失败，神庙保留不消失）
func apply(_player: Node) -> bool:
	return false
