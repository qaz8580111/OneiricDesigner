## TowerManager.gd - 无尽登塔单例
## 职责：无尽模式下，难度10封顶后接管"继续变强"的节奏——每半分钟登一层，每层敌人分轴增幅
## 继承：Node（作为全局单例运行）
## 设计意图：
##   1. 与 DifficultyManager 解耦：难度曲线本身在10级封顶（不改其曲线语义），
##      登塔阶段把"逐层分轴增幅"作为独立系数组写入 DifficultyManager.tower_mults，
##      由 apply_to_enemy_data 统一参与属性缩放——业务刷怪链路零修改（AOP 注入思想）
##   2. 敌人数量上限恒定：本类只改属性系数，绝不触碰 get_max_enemies 的任何参数
##   3. 层数即成绩：玩家死亡时的 current_floor 直接作为无尽榜记录（层数越多排名越高）
## 数据流：StageDirector 在无尽模式触发登塔 → begin_tower() →
##         本类自计时（每 FLOOR_INTERVAL 秒 +1 层）→ set_tower_mults() →
##         GameWorld 后续刷怪自动继承增幅 → 玩家死亡 → Main 读取 current_floor 写入榜单
extends Node

## ========== 信号定义 ==========

## 登塔开始信号：进入第 1 层时发出（UI 展示"登塔开始"横幅）
## 参数：floor - 起始层数（恒为 1）
signal tower_started(floor: int)

## 层数提升信号：登上一层时发出（UI 更新层数显示与播报）
## 参数：floor - 新层数
signal floor_changed(floor: int)

## ========== 调参常量（登塔节奏的核心配置，集中管理便于平衡调整） ==========

## 每登一层的间隔（秒）：每半分钟 +1 层
## 说明：登塔数值增幅已大幅放缓（见下方分轴增幅常量），用节奏密度补偿数值密度，
##       让"登塔在变强"这件事始终可被玩家感知，也让登塔榜有足够的区分度
const FLOOR_INTERVAL: float = 30.0

## ========== 每层分轴增幅常量（用户定制） ==========
## 为什么不再"全面提升"（全部属性同一系数）：
##   1. 血量/伤害是"耐力轴"——玩家 DPS 总会跟上，血厚只是拉长战斗，可预期、可追赶；
##      但换成统一系数后它会与速度轴一起指数膨胀，第10层就是2.77倍，压力失控
##   2. 攻速/移速/弹速是"速度轴"——直接压缩玩家容错（躲不掉/反应不过来），
##      一旦被指数放大就是"贴上即死"，必须用远小于耐力轴的涨幅
## 计算方式：第 N 层系数 = (1 + 对应增幅) ^ (N - 1)，第 1 层为登塔起点、无增幅

## 每层敌人血量增幅：+3%（耐力轴）
const FLOOR_HEALTH_BONUS: float = 0.03

## 每层敌人伤害增幅：+4%（耐力轴，碰撞伤害与子弹伤害同系数）
## 说明：略高于血量，让"失误"有实际惩罚，避免玩家只是被慢慢磨死
const FLOOR_DAMAGE_BONUS: float = 0.04

## 每层敌人攻速增幅：+1%（速度轴，内部由 DifficultyManager 换算为攻击冷却缩短）
## 说明：弹幕密度是无尽模式后期唯一真实的杀伤来源，故涨幅需高于移速/弹速
const FLOOR_ATTACK_SPEED_BONUS: float = 0.01

## 每层敌人移速增幅：+0.5%（速度轴，最危险的一轴，刻意压到最低）
const FLOOR_MOVE_SPEED_BONUS: float = 0.005

## 每层敌人子弹飞行速度增幅：+0.8%（速度轴，影响玩家的反应窗口）
const FLOOR_BULLET_SPEED_BONUS: float = 0.008

## ========== 运行时状态（每局由 game_started 重置） ==========

## 登塔是否已开启（false 时本类完全不介入，通关模式全程为 false）
var is_tower_active: bool = false

## 当前层数（0 = 尚未登塔）
var current_floor: int = 0

## 登塔开始后经过的时间（秒，仅游戏进行中累计）
var _elapsed: float = 0.0

## 下一次登层的时间点（秒，相对登塔开始）
var _next_floor_time: float = FLOOR_INTERVAL

## ========== 生命周期方法 ==========

## _ready() - 进入场景树时初始化：监听每局开始以重置状态
func _ready() -> void:
	GameManager.game_started.connect(_on_game_started)

## _process() - 每帧推进登塔计时（仅登塔开启且游戏进行中）
## 参数：delta - 帧间隔时间（秒）
func _process(delta: float) -> void:
	## 门禁 1：未登塔 → 不介入（通关模式全程走这里）
	if not is_tower_active:
		return
	## 门禁 2：只在游戏进行中计时（暂停/菜单/结算时冻结，与难度曲线同拍）
	if not GameManager.is_playing():
		return

	_elapsed += delta
	## while 处理极端情况（如长时间卡顿后一次跨多层），保证层数不错漏
	while _elapsed >= _next_floor_time:
		_next_floor_time += FLOOR_INTERVAL
		_advance_floor()

## ========== 登塔控制接口 ==========

## 开启登塔（由 StageDirector 在无尽模式难度10收尾时调用）
## 执行：标记开启 → 层数归 1 → 清空增幅（第1层为起点）→ 广播 tower_started
func begin_tower() -> void:
	## 重复开启保护：已在登塔中则忽略（防止事件重入导致层数被重置）
	if is_tower_active:
		return
	is_tower_active = true
	current_floor = 1
	_elapsed = 0.0
	_next_floor_time = FLOOR_INTERVAL
	## 第 1 层为登塔起点：所有轴增幅系数全部回到 1.0（不额外增强）
	DifficultyManager.reset_tower_mults()
	tower_started.emit(current_floor)
	print("[TowerManager] 登塔开启：第 %d 层" % current_floor)

## 获取当前登塔层数（结算/榜单读取）
## 返回：当前层数（0 = 本局未登塔）
func get_current_floor() -> int:
	return current_floor

## ========== 内部方法 ==========

## 登上一层：层数+1 → 计算各轴累计增幅 → 写入 DifficultyManager → 广播
## 增幅公式：各轴系数 = (1 + 对应 FLOOR_*_BONUS) ^ (层数 - 1)
##   第1层=1.0（起点）→ 第2层=血1.03/伤1.04/攻速1.01/移速1.005/弹速1.008 → …… 逐层乘算
func _advance_floor() -> void:
	current_floor += 1
	## 已过去的层数步数（第1层为起点，故减1）
	var steps: int = current_floor - 1
	var mults: Dictionary = {
		"health": pow(1.0 + FLOOR_HEALTH_BONUS, float(steps)),
		"damage": pow(1.0 + FLOOR_DAMAGE_BONUS, float(steps)),
		"attack_speed": pow(1.0 + FLOOR_ATTACK_SPEED_BONUS, float(steps)),
		"move_speed": pow(1.0 + FLOOR_MOVE_SPEED_BONUS, float(steps)),
		"bullet_speed": pow(1.0 + FLOOR_BULLET_SPEED_BONUS, float(steps)),
	}
	DifficultyManager.set_tower_mults(mults)
	floor_changed.emit(current_floor)
	print("[TowerManager] 登上第 %d 层：血×%.3f 伤×%.3f 攻速×%.3f 移速×%.3f 弹速×%.3f"
		% [current_floor, mults["health"], mults["damage"],
			mults["attack_speed"], mults["move_speed"], mults["bullet_speed"]])

## 响应 GameManager.game_started：每局重置登塔状态
## 覆盖所有重开路径（R键重开/菜单重开/死亡重开），业务如何重开与本类无关
func _on_game_started() -> void:
	is_tower_active = false
	current_floor = 0
	_elapsed = 0.0
	_next_floor_time = FLOOR_INTERVAL
