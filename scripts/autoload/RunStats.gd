## RunStats.gd - 局内统计单例
## 职责：记录单局游戏的核心数据（存活时间、击杀数、碎片、等级、难度、词条数），
##      供游戏结束结算界面展示
## 继承：Node（作为全局单例运行）
## 设计意图：roguelike的"再来一局"驱动力来自可量化的成长反馈——
##          每局结束展示本局数据，让玩家感知进步并追求更高记录
## 架构角色：autoload单例，纯被动的数据收集器——各系统（GameWorld/Player/UpgradeManager/
##           DifficultyManager）主动调用add_/report_接口上报，本类不反查任何业务节点；
##           结算界面直接读字段或调用get_formatted_time()展示
extends Node

## ========== 统计数据 ==========

## 本局击杀敌人数
var kills: int = 0

## 本局累计获得的梦境碎片总数
var fragments_total: int = 0

## 本局存活时间（秒）
var elapsed_time: float = 0.0

## 本局达到的最高等级
var level_reached: int = 1

## 本局达到的最高难度
var difficulty_reached: int = 1

## 本局获得的升级词条总数
var upgrades_taken: int = 0

## ========== 生命周期方法 ==========

## _ready() - 进入场景树时初始化
func _ready() -> void:
	## 监听游戏开始信号：每局开始时重置所有统计
	GameManager.game_started.connect(reset_stats)

## 重置所有统计数据（新局开始时调用）
func reset_stats() -> void:
	kills = 0
	fragments_total = 0
	elapsed_time = 0.0
	level_reached = 1
	difficulty_reached = 1
	upgrades_taken = 0

## ========== 帧更新方法 ==========

## _process() - 每帧累计存活时间（仅游戏进行中）
## 参数：delta - 帧间隔时间（秒）
func _process(delta: float) -> void:
	## 只在游戏进行时计时（暂停/菜单/结算时不计时）
	if GameManager.is_playing():
		elapsed_time += delta

## ========== 数据上报接口（供其他系统调用） ==========

## 上报一次击杀（GameWorld敌人死亡时调用）
func add_kill() -> void:
	kills += 1

## 上报碎片获得（Player拾取碎片时调用）
## 参数：amount - 本次获得的碎片数
func add_fragment(amount: int) -> void:
	fragments_total += amount

## 上报等级提升（UpgradeManager升级时调用）
## 参数：new_level - 新等级
func report_level(new_level: int) -> void:
	level_reached = max(level_reached, new_level)

## 上报难度提升（DifficultyManager难度变化时调用）
## 参数：new_difficulty - 新难度
func report_difficulty(new_difficulty: int) -> void:
	difficulty_reached = max(difficulty_reached, new_difficulty)

## 上报词条获得（UpgradeManager应用词条时调用）
func add_upgrade_taken() -> void:
	upgrades_taken += 1

## ========== 展示格式化方法（结算界面使用） ==========

## 获取格式化的存活时间文本（分:秒）
## 返回："3分25秒" 格式的时间文本
func get_formatted_time() -> String:
	## int()先截断小数秒，再做整数除法取分钟部分
	var minutes: int = int(elapsed_time) / 60
	## 取余得剩余秒数；%02d保证个位数秒补零显示（如"3分05秒"）
	var seconds: int = int(elapsed_time) % 60
	return "%d分%02d秒" % [minutes, seconds]
