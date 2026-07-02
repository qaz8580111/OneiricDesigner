## GameHUD.gd - 游戏 HUD 界面脚本
## 职责：显示玩家健康状态（血量）、梦境碎片数量等实时游戏信息
## 继承：Control（Godot 4的UI控制节点，作为HUD容器）
extends Control

## ========== 节点引用（使用 @onready 延迟初始化） ==========

## 血量条节点，用于显示玩家核心血量
@onready var health_bar: ProgressBar = $HealthBar

## 梦境碎片标签节点，用于显示玩家当前拥有的梦境碎片数量
@onready var fragment_label: Label = $FragmentLabel

## ========== 成员变量（运行时数据） ==========

## 玩家引用，用于获取玩家状态和连接信号
var _player: Node2D = null

## 当前梦境碎片数量（用于显示）
var _dream_fragment: int = 0

## 健康控制器引用，用于监听玩家健康状态变化
var _health_controller: Node = null

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 尝试查找玩家，如果找不到则延迟查找
	if not _find_player():
		call_deferred("_deferred_find_player")

## 延迟查找玩家（第一次查找失败后调用）
func _deferred_find_player() -> void:
	## 如果仍然找不到玩家，通过 process_frame 信号持续查找
	if not _find_player():
		get_tree().process_frame.connect(_on_process_frame_once)

## process_frame 回调（只触发一次）
## 用于在玩家节点创建后立即找到并连接信号
func _on_process_frame_once() -> void:
	## 断开信号（只需要查找一次）
	get_tree().process_frame.disconnect(_on_process_frame_once)
	## 再次尝试查找玩家
	_find_player()

## ========== 玩家查找与信号连接 ==========

## 查找玩家并连接相关信号
## 返回：true表示找到玩家，false表示未找到
func _find_player() -> bool:
	## 从"player"组查找玩家
	var players: Array[Node] = get_tree().get_nodes_in_group("player")
	if players.size() <= 0:
		return false
	
	## 获取玩家引用
	_player = players[0] as Node2D
	
	## 连接梦境碎片变化信号：当玩家收集梦境碎片时触发回调
	if _player.has_signal("dream_fragment_changed"):
		_player.connect("dream_fragment_changed", _on_dream_fragment_changed)
	
	## 获取玩家的健康控制器节点
	_health_controller = _player.get_node_or_null("HealthController")
	
	## 如果有健康控制器，连接健康相关信号
	if _health_controller != null:
		## 连接健康状态变化信号：当护盾/核心血变化时触发回调
		if _health_controller.has_signal("health_changed"):
			_health_controller.connect("health_changed", _on_health_changed)
		## 连接玩家死亡信号：当玩家死亡时触发回调
		if _health_controller.has_signal("player_died"):
			_health_controller.connect("player_died", _on_player_killed)
	## 如果没有健康控制器（备用方案），连接玩家自身的信号
	elif _player.has_signal("damaged"):
		_player.connect("damaged", _on_player_damaged)
		if _player.has_signal("killed"):
			_player.connect("killed", _on_player_killed)
	
	## 初始化梦境碎片显示
	_dream_fragment = _player.dream_fragment
	_update_fragment_display()
	
	## 初始化血量显示
	if _health_controller != null:
		## 通过健康控制器获取当前生存状态并更新显示
		var state: Dictionary = _health_controller.get_survival_state()
		_update_health_display(state)
	## 备用方案：直接读取玩家的 health 和 max_health 属性
	elif "health" in _player and "max_health" in _player:
		update_health(_player.health, _player.max_health)
	
	return true

## ========== 血量更新方法 ==========

## 更新血量显示（简单版本，备用方案）
## 参数：current - 当前血量，max - 最大血量
func update_health(current: int, max: int) -> void:
	if health_bar:
		health_bar.max_value = max
		health_bar.value = current

## 更新梦境碎片显示
func _update_fragment_display() -> void:
	if fragment_label:
		fragment_label.text = "梦境碎片: %d" % _dream_fragment

## 更新健康显示（通过生存状态字典）
## 参数：state - 包含护盾、核心血、红血状态等信息的字典
func _update_health_display(state: Dictionary) -> void:
	if health_bar:
		## 获取核心血量和最大核心血量
		var core_hp: float = state.get("core", 0.0)
		var max_core: float = state.get("max_core", 100.0)
		## 设置血量条的最大值和当前值
		health_bar.max_value = max_core
		health_bar.value = core_hp
		
		## 如果处于红血状态，将血量条设为红色警示
		if state.get("is_critical", false):
			health_bar.modulate = Color(1, 0.3, 0.3, 1)
		else:
			## 正常状态下使用白色
			health_bar.modulate = Color.WHITE

## ========== 信号回调方法 ==========

## 健康状态变化回调：当护盾/核心血变化时调用
## 参数：state - 最新的生存状态字典
func _on_health_changed(state: Dictionary) -> void:
	_update_health_display(state)

## 玩家受伤回调（备用方案，无健康控制器时使用）
## 参数：amount - 受到的伤害数值
func _on_player_damaged(amount: int) -> void:
	## 如果玩家有 health 和 max_health 属性，更新血量显示
	if _player and "health" in _player and "max_health" in _player:
		update_health(_player.health, _player.max_health)

## 梦境碎片变化回调：当玩家收集梦境碎片时调用
## 参数：amount - 新的梦境碎片数量
func _on_dream_fragment_changed(amount: int) -> void:
	## 更新当前碎片数量
	_dream_fragment = amount
	## 更新显示
	_update_fragment_display()

## 玩家死亡回调：当玩家死亡时调用
func _on_player_killed() -> void:
	## 隐藏 HUD（游戏结束时不再显示）
	visible = false