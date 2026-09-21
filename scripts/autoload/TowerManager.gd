## TowerManager.gd - 无尽登塔单例
## 职责：无尽模式下，难度10封顶后接管"继续变强"的节奏——每分钟登一层，每层敌人属性全面增幅
## 继承：Node（作为全局单例运行）
## 设计意图：
##   1. 与 DifficultyManager 解耦：难度曲线本身在10级封顶（不改其曲线语义），
##      登塔阶段把"逐层增幅"作为独立系数写入 DifficultyManager.tower_multiplier，
##      由 apply_to_enemy_data 统一参与属性缩放——业务刷怪链路零修改（AOP 注入思想）
##   2. 敌人数量上限恒定：本类只改属性系数，绝不触碰 get_max_enemies 的任何参数
##   3. 层数即成绩：玩家死亡时的 current_floor 直接作为无尽榜记录（层数越多排名越高）
## 数据流：StageDirector 在无尽模式触发登塔 → begin_tower() →
##         本类自计时（每 FLOOR_INTERVAL 秒 +1 层）→ set_tower_multiplier() →
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

## 每登一层的间隔（秒）：每分钟 +1 层（用户定制节奏）
const FLOOR_INTERVAL: float = 60.0

## 每层敌人属性全面增幅：12%（用户定制固定值）
## 说明：增幅作用于血量/伤害/移速（含敌人子弹伤害），按层数乘算叠加；
##       第 1 层为登塔起点、无增幅，第 2 层起每层 +12%
const FLOOR_ATTRIBUTE_BONUS: float = 0.12

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
	## 第 1 层为登塔起点：属性增幅系数回到 1.0（不额外增强）
	DifficultyManager.set_tower_multiplier(1.0)
	tower_started.emit(current_floor)
	print("[TowerManager] 登塔开启：第 %d 层" % current_floor)

## 获取当前登塔层数（结算/榜单读取）
## 返回：当前层数（0 = 本局未登塔）
func get_current_floor() -> int:
	return current_floor

## ========== 内部方法 ==========

## 登上一层：层数+1 → 计算累计增幅 → 写入 DifficultyManager → 广播
## 增幅公式：(1 + FLOOR_ATTRIBUTE_BONUS) ^ (层数 - 1)
##   第1层=1.0（起点）→ 第2层=1.12 → 第3层=1.2544 → …… 逐层乘算叠加
func _advance_floor() -> void:
	current_floor += 1
	var mult: float = pow(1.0 + FLOOR_ATTRIBUTE_BONUS, float(current_floor - 1))
	DifficultyManager.set_tower_multiplier(mult)
	floor_changed.emit(current_floor)
	print("[TowerManager] 登上第 %d 层：敌人属性增幅 ×%.3f" % [current_floor, mult])

## 响应 GameManager.game_started：每局重置登塔状态
## 覆盖所有重开路径（R键重开/菜单重开/死亡重开），业务如何重开与本类无关
func _on_game_started() -> void:
	is_tower_active = false
	current_floor = 0
	_elapsed = 0.0
	_next_floor_time = FLOOR_INTERVAL
