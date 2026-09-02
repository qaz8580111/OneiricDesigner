## LiveGiftBinding.gd - 直播礼物→敌人映射资源类
## 职责：配置不同礼物（或礼物价值区间）生成什么敌人、生成几个
## 继承：Resource（可在编辑器中创建 .tres 配置，也可纯代码使用）
## 被引用方：LiveBridgeManager（启动时加载此资源，根据礼物事件查找映射）
## 数据流：桥接进程推送 gift 事件 → LiveBridgeManager 查 LiveGiftBinding →
##         得到 enemy_path/count/is_elite → 信号传给 GameWorld.spawn_live_enemy()
## 设计意图：礼物→敌人的映射纯数据驱动，新增礼物只需改配置不改代码
class_name LiveGiftBinding
extends Resource

## ========== 礼物→敌人精确映射 ==========
## 每个字典元素的结构：
##   "gift_name": String  — B站礼物名称（如"辣条""小心心""BKT"）
##   "enemy_path": String — 对应的 EnemyData .tres 资源路径
##   "count": int         — 生成几个敌人（默认1）
##   "is_elite": bool     — 是否标记为精英怪（默认false）
##   "display_name": String — 可选：生成时显示的来源标签（如"辣条怪"）
@export var bindings: Array[Dictionary] = []

## ========== 进房事件配置 ==========
## 游客进入直播间时生成什么敌人（空字符串=不生成）
@export var viewer_enter_enemy_path: String = "res://data/enemy/slime_data.tres"

## 每个游客进入时生成几个敌人
@export var viewer_enter_count: int = 1

## 游客进入生成的敌人是否为精英怪
@export var viewer_enter_is_elite: bool = false

## ========== 弹幕事件配置 ==========
## 弹幕触发敌人（空字符串=弹幕不生成敌人，避免高热直播间刷屏）
@export var danmu_enemy_path: String = ""

## 弹幕触发几个敌人
@export var danmu_enemy_count: int = 0

## ========== 未匹配礼物的价值区间兜底映射 ==========
## 当礼物名称不在 bindings 列表中时，按礼物价值(元)区间选择敌人
## 每个元素的结构同 bindings，但用 "value_min" 代替 "gift_name"
@export var value_fallback: Array[Dictionary] = []

## ========== 初始化默认配置 ==========

func _init() -> void:
	## 如果 bindings 为空，填充B站常见礼物默认映射
	if bindings.is_empty():
		_populate_default_bindings()
	## 如果价值兜底为空，填充默认区间
	if value_fallback.is_empty():
		_populate_default_fallback()

## B站常见礼物→敌人默认映射表
## 设计意图：弱礼物→弱敌人（史莱姆），中礼物→中敌人，重礼物→强敌人/精英
func _populate_default_bindings() -> void:
	bindings = [
		# 免费礼物/低价值 → 最弱敌人（史莱姆），1个
		{"gift_name": "辣条", "enemy_path": "res://data/enemy/slime_data.tres", "count": 1, "is_elite": false, "display_name": "辣条怪"},
		# 小额礼物 → 常见敌人，1-2个
		{"gift_name": "小心心", "enemy_path": "res://data/enemy/goblin_data.tres", "count": 2, "is_elite": false, "display_name": "心心哥布林"},
		{"gift_name": "PiKi", "enemy_path": "res://data/enemy/bat_data.tres", "count": 2, "is_elite": false, "display_name": "PiKi蝙蝠"},
		# 中额礼物 → 中强度敌人
		{"gift_name": "干杯", "enemy_path": "res://data/enemy/archer_data.tres", "count": 3, "is_elite": false, "display_name": "干杯弓手"},
		{"gift_name": "BKT", "enemy_path": "res://data/enemy/firemage_data.tres", "count": 2, "is_elite": false, "display_name": "BKT法师"},
		# 大额礼物 → 精英怪/稀有敌人
		{"gift_name": "舰长", "enemy_path": "res://data/enemy/wraith_data.tres", "count": 3, "is_elite": true, "display_name": "舰长幽灵"},
		{"gift_name": "提督", "enemy_path": "res://data/enemy/knight_data.tres", "count": 4, "is_elite": true, "display_name": "提督骑士"},
		# 超大额 → 最强敌人
		{"gift_name": "总督", "enemy_path": "res://data/enemy/tank_data.tres", "count": 5, "is_elite": true, "display_name": "总督巨像"},
	]

## 按礼物价值(元)区间兜底映射
## 设计意图：B站不断上新礼物，无法穷举，用价值区间自动归类
func _populate_default_fallback() -> void:
	value_fallback = [
		# 价值 < 0.1元 → 最弱敌人
		{"value_min": 0.0, "enemy_path": "res://data/enemy/slime_data.tres", "count": 1, "is_elite": false, "display_name": "路人怪"},
		# 0.1 ~ 1元 → 常见敌人
		{"value_min": 0.1, "enemy_path": "res://data/enemy/goblin_data.tres", "count": 2, "is_elite": false, "display_name": "小费哥布林"},
		# 1 ~ 10元 → 中强度敌人
		{"value_min": 1.0, "enemy_path": "res://data/enemy/archer_data.tres", "count": 3, "is_elite": false, "display_name": "土豪弓手"},
		# 10 ~ 50元 → 精英怪
		{"value_min": 10.0, "enemy_path": "res://data/enemy/wraith_data.tres", "count": 3, "is_elite": true, "display_name": "金主幽灵"},
		# 50 ~ 200元 → 稀有精英
		{"value_min": 50.0, "enemy_path": "res://data/enemy/knight_data.tres", "count": 4, "is_elite": true, "display_name": "重氪骑士"},
		# 200元以上 → 最强敌人
		{"value_min": 200.0, "enemy_path": "res://data/enemy/tank_data.tres", "count": 5, "is_elite": true, "display_name": "超管巨像"},
	]

## ========== 查询方法 ==========

## 按礼物名称查找映射
## 参数：gift_name — B站礼物名称
## 返回：映射字典（含 enemy_path/count/is_elite/display_name），未找到返回空字典
func get_binding_for_gift(gift_name: String) -> Dictionary:
	for b in bindings:
		if b.get("gift_name", "") == gift_name:
			return b
	# 未精确匹配，返回空字典（调用方应走 value 兜底）
	return {}

## 按礼物价值(元)查找兜底映射
## 参数：value — 礼物价值（元）
## 返回：映射字典，未找到返回空字典
func get_binding_for_value(value: float) -> Dictionary:
	var best: Dictionary = {}
	var best_min: float = -1.0
	for b in value_fallback:
		var v_min: float = b.get("value_min", 0.0)
		# 找到 value >= value_min 的最高区间
		if value >= v_min and v_min > best_min:
			best = b
			best_min = v_min
	return best

## 综合查找：先按名称精确匹配，再按价值兜底
## 参数：gift_name — 礼物名称, value — 礼物价值(元)
## 返回：最终映射字典（保证返回有效映射，不会返回空字典）
func resolve(gift_name: String, value: float) -> Dictionary:
	# 优先按名称精确匹配
	var b: Dictionary = get_binding_for_gift(gift_name)
	if not b.is_empty():
		return b
	# 未匹配则按价值兜底
	b = get_binding_for_value(value)
	if not b.is_empty():
		return b
	# 最终兜底：返回最弱敌人映射（确保总有敌人生成）
	return {"enemy_path": "res://data/enemy/slime_data.tres", "count": 1, "is_elite": false, "display_name": "未知怪"}
