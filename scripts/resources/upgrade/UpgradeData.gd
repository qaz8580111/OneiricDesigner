## UpgradeData.gd - 装备词条模板数据资源类
## 职责：定义一条可被装备携带的词条（属性加成或子弹特效），实现词条的数据驱动
## 继承：Resource（Godot资源类，可在编辑器中创建和配置）
## 使用场景：在 data/upgrades/ 目录下创建 .tres 文件即可新增词条模板，
##          UpgradeManager会自动扫描该目录加载所有词条（无需改代码，可扩展性核心）
## 被引用方：UpgradeManager（扫描/作为装备基础属性与特效词条模板来源）、
##           EquipmentGenerator（按槽位/稀有度为装备实例 roll 出词条）
## 数据流：data/upgrades/*.tres → UpgradeManager加载入模板池 → EquipmentGenerator 生成装备时抽取 →
##         装备穿戴后由 EquipmentComponent 聚合进 UpgradeManager.recompute_stats()
## 设计意图：装备词条系统的数据单元——
##          属性词条通过stat_modifiers字典描述数值加成，
##          特效词条直接引用BulletEffect资源（生成装备特效实例时复用）
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

## 词条显示名称（装备面板展示）
@export var display_name: String = ""

## 词条描述文本（说明效果，装备面板展示）
@export var description: String = ""

## 词条稀有度（决定抽取权重和UI颜色）
@export var rarity: Rarity = Rarity.COMMON

## 最大叠加层数（全局统一规则：所有技能均可升至5级，满级后不再参与装备抽词）
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

## ========== 装备词条模板适配（RPG装备化改造） ==========

## 装备槽位适配：该词条可作为哪些装备槽的"基础属性/特效"参与随机 roll
## 取值对应 EquipmentData.Slot（WEAPON=0, ARMOR=1, BOOTS=2, SHIELD=3, RING=4, TALISMAN=5）
## 空数组 = 该词条仅作占位、不参与装备生成抽词
## 设计意图：让同一份 .tres 词条模板可被 EquipmentGenerator._templates_for_slot() 按槽位筛选，
##          实现"每件装备有各自的基础属性池"（如鞋子池含移速、护甲池含血量/回血）
@export var equip_slots: Array[int] = []

## ========== 子弹特效（特效词条使用） ==========

## 子弹特效资源引用（复用data/bullet/effect/下的16种特效.tres）
## 非空时表示这是特效词条：应用后特效被追加到玩家子弹的effects数组
## 同一特效不重复挂载（UpgradeManager按effect_id去重），重复获得改为
## 调用已拥有特效实例的add_stack()叠层成长（每级放大关键参数）
@export var bullet_effect: Resource = null

## ========== 核心方法 ==========

## 获取稀有度显示颜色（装备面板使用）
## 返回：稀有度对应的Color
func get_rarity_color() -> Color:
	match rarity:
		Rarity.RARE:
			return Color(0.4, 0.7, 1.0)    ## 稀有：蓝色
		Rarity.EPIC:
			return Color(0.8, 0.4, 1.0)    ## 史诗：紫色
		_:
			return Color(0.9, 0.9, 0.9)    ## 普通：白色

## 获取稀有度显示文本（装备面板使用）
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
