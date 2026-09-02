## ComboManager.gd - 击杀连击系统单例
## 职责：追踪连续击杀数，在里程碑触发屏幕大字弹出+音效，超时后连击中断
## 继承：Node（autoload单例）
## 直播价值：
##   1. 观众可跟着计数"50杀！100杀！"——创造直播互动高光时刻
##   2. 里程碑(10/25/50/100/250)触发屏幕大字+专属音效——情绪爆点
##   3. 连击越高音效升调——紧张感累积，"别断！别断！"
## 架构：纯被动——GameWorld._on_enemy_killed 调用 add_kill()，本类不反查任何业务节点
extends Node

## ========== 信号定义 ==========

## 连击里程碑达成信号（UI层监听后弹出大字）
## 参数：milestone - 里程碑数值(10/25/50/100/250)
signal combo_milestone(milestone: int)

## ========== 常量 ==========

## 连击超时时间（秒，超时未击杀则连击中断归零）
const COMBO_TIMEOUT: float = 3.0

## 里程碑列表（达到这些击杀数时触发庆祝特效）
const MILESTONES: Array[int] = [10, 25, 50, 100, 250, 500]

## 击杀时停触发阈值：连击达到此值时触发微冻帧（普通击杀）
const KILL_STOP_COMBO_THRESHOLD: int = 10
## 击杀时停持续帧数（极短：5帧≈0.08秒，仅够观众反应过来）
const KILL_STOP_FRAMES: int = 5

## ---------- 击杀时停冷却（防止连续触发造成卡顿） ----------
## 上次触发时停的时间戳（帧数计数）
var _last_kill_stop_frame: int = 0
## 冷却帧数（每 15 帧最多触发一次，约 0.25 秒）
const KILL_STOP_COOLDOWN_FRAMES: int = 15

## ---------- 击杀时停帧计数状态（process_frame 回调需要持久化） ----------
var _kill_stop_remaining: int = 0
var _kill_stop_callback: Callable = Callable()

## ========== 成员变量 ==========

## 当前连击数
var _combo: int = 0

## 最高连击数（本局最高记录）
var _max_combo: int = 0

## 连击计时器（超时归零）
var _combo_timer: float = 0.0

## 已触发的里程碑集合（防止重复触发）
var _triggered_milestones: Array[int] = []

## ========== 生命周期方法 ==========

## _ready() - 监听游戏开始信号
func _ready() -> void:
	GameManager.game_started.connect(_reset)

## _process() - 连击超时计时
func _process(delta: float) -> void:
	if not GameManager.is_playing():
		return
	## 连击中且计时器归零 → 连击中断
	if _combo > 0:
		_combo_timer -= delta
		if _combo_timer <= 0.0:
			_combo = 0
			_triggered_milestones.clear()

## ========== 对外接口 ==========

## 上报一次击杀（GameWorld._on_enemy_killed调用）
## 参数：position - 击杀位置（用于音效空间播放，可选），is_big_kill - 是否大击杀（精英/Boss）
func add_kill(position: Vector2 = Vector2.ZERO, is_big_kill: bool = false) -> void:
	if not GameManager.is_playing():
		return
	_combo += 1
	_max_combo = maxi(_combo, _max_combo)
	_combo_timer = COMBO_TIMEOUT

	## 检查里程碑
	for m in MILESTONES:
		if _combo >= m and not (m in _triggered_milestones):
			_triggered_milestones.append(m)
			_on_milestone(m)

	## 连击音效（每杀一个播放，音调随连击数升高）
	if AudioManager and _combo > 1:
		## 基频220Hz，每杀升20Hz，上限880Hz
		var pitch: float = minf(220.0 + _combo * 20.0, 880.0)
		AudioManager.play("combo_tick", 0.4)

	## ---------- 击杀时停（直播增强：微冻帧制造打击感） ----------
	## 触发条件：大击杀（精英/Boss）或 连击 >= 10
	## 冷却保护：避免连续触发造成卡顿
	var should_stop: bool = is_big_kill or _combo >= KILL_STOP_COMBO_THRESHOLD
	if should_stop:
		_try_trigger_kill_stop()

## 获取当前连击数
func get_combo() -> int:
	return _combo

## 获取最高连击数
func get_max_combo() -> int:
	return _max_combo

## ========== 内部方法 ==========

## 里程碑达成处理（屏幕大字+专属音效）
func _on_milestone(milestone: int) -> void:
	combo_milestone.emit(milestone)
	## 里程碑专属音效（高音"叮"）
	if AudioManager:
		AudioManager.play("combo_milestone", 0.8)

## 重置连击（新局开始）
func _reset() -> void:
	_combo = 0
	_max_combo = 0
	_combo_timer = 0.0
	_triggered_milestones.clear()
	_last_kill_stop_frame = 0  ## 同时重置击杀时停冷却

## 尝试触发击杀时停（微冻帧，制造打击感）
## 冷却保护：每 KILL_STOP_COOLDOWN_FRAMES 帧最多触发一次
func _try_trigger_kill_stop() -> void:
	## 检查冷却（用 Engine.get_process_frames() 获取全局帧计数）
	var current_frame: int = Engine.get_process_frames()
	if current_frame - _last_kill_stop_frame < KILL_STOP_COOLDOWN_FRAMES:
		return
	_last_kill_stop_frame = current_frame

	## 设置时停（极短：5帧≈0.08秒）+ 绑定帧回调恢复
	_kill_stop_remaining = KILL_STOP_FRAMES
	_kill_stop_callback = _on_kill_stop_tick
	Engine.time_scale = 0.0
	get_tree().process_frame.connect(_kill_stop_callback)

## 击杀时停帧回调（每帧减1，到0时恢复 time_scale=1.0）
func _on_kill_stop_tick() -> void:
	_kill_stop_remaining -= 1
	if _kill_stop_remaining <= 0:
		Engine.time_scale = 1.0
		get_tree().process_frame.disconnect(_kill_stop_callback)
