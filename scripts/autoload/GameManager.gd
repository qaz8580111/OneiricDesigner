## GameManager.gd - 游戏状态管理单例
## 职责：管理游戏生命周期（开始/结束/暂停/恢复），统一游戏状态，广播游戏事件
## 继承：Node（作为全局单例运行）
## 架构角色：autoload单例，全局状态机+事件广播中枢；RunStats/UpgradeManager/DifficultyManager
##           均监听其game_started信号完成每局重置——本类是"一局"概念的权威定义者
## 暂停实现：直接驱动场景树paused开关（get_tree().paused），配合各UI节点的
##           PROCESS_MODE_ALWAYS实现"世界冻结、界面照常"的标准Godot暂停方案
extends Node

## ========== 信号定义（用于与其他节点通信） ==========

## 游戏开始信号：当游戏开始时发出（玩家进入游戏场景）
signal game_started

## 游戏结束信号：当游戏结束时发出（玩家死亡）
signal game_ended

## 游戏暂停信号：当游戏暂停时发出（玩家打开暂停菜单）
signal game_paused

## 游戏恢复信号：当游戏恢复时发出（玩家关闭暂停菜单）
signal game_resumed

## ========== 游戏状态枚举 ==========

## 定义游戏的所有状态
enum GameState {
	MENU,      ## 菜单状态：主菜单或设置界面
	PLAYING,   ## 游戏中：玩家正在进行游戏
	PAUSED,    ## 暂停状态：游戏暂停但未结束
	GAME_OVER  ## 游戏结束：玩家死亡
}

## 定义游戏模式
## CLASSIC：通关模式——难度10后走完终极BOSS战即通关（榜单按 BOSS 战用时升序）
## ENDLESS：无尽模式——难度10后进入登塔，层数每分钟+1、敌人属性逐层增幅（榜单按层数降序）
enum RunMode {
	CLASSIC,   ## 通关模式：击败终极BOSS「梦境根源」即通关
	ENDLESS    ## 无尽模式：难度10后无限登塔，直至死亡
}

## ========== 成员变量（运行时数据） ==========

## 当前游戏状态
var current_state: GameState = GameState.MENU

## 当前游戏种子（用于生成随机地图、敌人等）
var game_seed: int = 0

## 当前游戏模式（在 start_new_game 中定稿，game_started 之前写入，各监听者可在回调中读取）
var current_mode: RunMode = RunMode.CLASSIC

## ========== 核心方法（游戏生命周期） ==========

## 开始新游戏
## 参数：seed - 游戏种子（0表示自动生成随机种子）
##       mode - 游戏模式（通关/无尽），默认通关模式
func start_new_game(seed: int = 0, mode: RunMode = RunMode.CLASSIC) -> void:
	## 如果未指定种子，生成真正随机的种子
	if seed == 0:
		game_seed = RandomManager.generate_true_random_seed()
	else:
		## 使用指定的种子（用于测试或重播）
		game_seed = seed
	
	## 定稿本局模式：必须在 game_started 之前写入，
	## 确保各监听者（RunStats/StageDirector/TowerManager 等）在回调里读到的模式已就位
	current_mode = mode
	## 将种子设置到随机管理器（确保游戏内所有随机数基于此种子）
	## 顺序关键：必须先定种子再发game_started——监听者初始化期间产生的随机数也已确定可复现
	RandomManager.set_seed(game_seed)
	## 设置当前游戏状态为 PLAYING
	current_state = GameState.PLAYING
	## 发出游戏开始信号（通知其他节点开始游戏逻辑）
	game_started.emit()
	## 输出日志（用于调试和记录）
	print("Game started with seed: ", game_seed, " mode: ", RunMode.keys()[current_mode])

## 结束游戏（玩家死亡时调用）
func end_game() -> void:
	## 设置当前游戏状态为 GAME_OVER
	current_state = GameState.GAME_OVER
	## 发出游戏结束信号（通知其他节点处理游戏结束逻辑）
	game_ended.emit()

## 暂停游戏（打开暂停菜单时调用）
func pause_game() -> void:
	## 只有在游戏中状态才能暂停
	if current_state == GameState.PLAYING:
		## 设置当前游戏状态为 PAUSED
		current_state = GameState.PAUSED
		## 暂停场景树（所有节点停止更新）
		get_tree().paused = true
		## 发出游戏暂停信号（通知其他节点处理暂停逻辑）
		game_paused.emit()

## 恢复游戏（关闭暂停菜单时调用）
func resume_game() -> void:
	## 只有在暂停状态才能恢复
	if current_state == GameState.PAUSED:
		## 设置当前游戏状态为 PLAYING
		current_state = GameState.PLAYING
		## 恢复场景树（所有节点继续更新）
		get_tree().paused = false
		## 发出游戏恢复信号（通知其他节点处理恢复逻辑）
		game_resumed.emit()

## 判断游戏是否正在进行中
## 返回：true表示游戏正在进行，false表示其他状态
func is_playing() -> bool:
	return current_state == GameState.PLAYING