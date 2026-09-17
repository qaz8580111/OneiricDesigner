## UpgradeData.gd - 升级词条数据资源类
## 职责：定义一条可被玩家获得的升级词条（属性加成或子弹特效），实现词条的数据驱动
## 继承：Resource（Godot资源类，可在编辑器中创建和配置）
## 使用场景：在 data/upgrades/ 目录下创建 .tres 文件即可新增词条，
##          UpgradeManager会自动扫描该目录加载所有词条（无需改代码，可扩展性核心）
## 被引用方：UpgradeManager（扫描/按稀有度抽取/应用词条）、LevelUpPanel（三选一UI展示）、
##           Player（应用后按stat_modifiers修改属性、把bullet_effect追加进子弹effects）
## 数据流：data/upgrades/*.tres → UpgradeManager加载入池 → 升级时三选一展示 →
##         玩家选择后属性词条累加进Player、特效词条追加进子弹配置
## 设计意图：roguelike三选一升级系统的基础数据单元——
##          属性词条通过stat_modifiers字典描述数值加成，
##          特效词条直接引用BulletEffect资源（复用已有的16种子弹特效）
class_name UpgradeData
extends Resource

## ========== 稀有度枚举 ==========

## 词条稀有度（影响抽取权重和UI显示颜色）
enum Rarity {
	COMMON,  ## 普通（白色，抽取权重最高，数值较小）
	RARE,    ## 稀有（蓝色，中等权重，特效词条常用）
	EPIC     ## 史诗（紫色，低权重，强力特效或大数值）
}

## ========== 词条基础属性 ==========

## 词条唯一标识（用于去重、日志和调试）
@export var upgrade_id: String = ""

## 词条显示名称（三选一界面展示）
@export var display_name: String = ""

## 词条描述文本（说明效果，三选一界面展示）
@export var description: String = ""

## 词条稀有度（决定抽取权重和UI颜色）
@export var rarity: Rarity = Rarity.COMMON

## 最大叠加层数（全局统一规则：所有技能均可升至5级，满级后从三选一候选中移除）
@export var max_stacks: int = 5

## ========== 数值加成（属性词条使用） ==========

## 属性修正字典：键=属性名，值=增量（累加到玩家属性乘算上）
## 支持的键：
##   "damage_mult"     - 子弹伤害乘算增量（0.15 = 每层+15%伤害）
##   "bullet_speed_mult" - 子弹速度乘算增量（0.15 = 每层+15%弹速）
##   "fire_rate_mult"  - 射速乘算增量（0.12 = 每层射速+12%，冷却缩短）
##   "move_speed_mult" - 移动速度乘算增量（0.10 = 每层移速+10%）
##   "max_hp_bonus"    - 核心血量上限加值（整数，每层+15上限并立即治疗）
## 设计意图：字典结构让新增属性词条无需修改任何代码，
##          Player/UpgradeManager按约定键名读取即可
@export var stat_modifiers: Dictionary = {}

## ========== 子弹特效（特效词条使用） ==========

## 子弹特效资源引用（复用data/bullet/effect/下的16种特效.tres）
## 非空时表示这是特效词条：应用后特效被追加到玩家子弹的effects数组
## 同一特效不重复挂载（UpgradeManager按effect_id去重），重复获得改为
## 调用已拥有特效实例的add_stack()叠层成长（每级放大关键参数）
@export var bullet_effect: Resource = null

## ========== 核心方法 ==========

## 获取稀有度显示颜色（三选一界面使用）
## 返回：稀有度对应的Color
func get_rarity_color() -> Color:
	match rarity:
		Rarity.RARE:
			return Color(0.4, 0.7, 1.0)    ## 稀有：蓝色
		Rarity.EPIC:
			return Color(0.8, 0.4, 1.0)    ## 史诗：紫色
		_:
			return Color(0.9, 0.9, 0.9)    ## 普通：白色

## 获取稀有度显示文本（三选一界面使用）
## 返回：稀有度中文名
func get_rarity_text() -> String:
	match rarity:
		Rarity.RARE:
			return "稀有"
		Rarity.EPIC:
			return "史诗"
		_:
			return "普通"

## 判断这是否为特效词条
## 返回：true表示特效词条（bullet_effect非空），false表示属性词条
func is_effect_upgrade() -> bool:
	return bullet_effect != null
