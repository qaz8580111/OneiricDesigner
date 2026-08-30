## GameHUD.gd - 游戏 HUD 界面脚本
## 职责：显示玩家健康状态（血量）、梦境碎片数量、经验/等级、难度等实时游戏信息
## 继承：Control（Godot 4的UI控制节点，作为HUD容器）
## 数据流（被动刷新，HUD不持有游戏逻辑状态）：
##   Player.dream_fragment_changed / HealthController(health_changed, player_died) → 血量与碎片显示
##   UpgradeManager(exp_changed, level_up) → 经验条与等级；DifficultyManager(difficulty_changed) → 难度文字
extends Control

## ========== 节点引用（使用 @onready 延迟初始化） ==========

## 血量条节点，用于显示玩家核心血量
@onready var health_bar: ProgressBar = $HealthBar

## 梦境碎片标签节点，用于显示玩家当前拥有的梦境碎片数量
@onready var fragment_label: Label = $FragmentLabel

## 经验条节点，显示升级进度（碎片即经验）
@onready var exp_bar: ProgressBar = $ExpBar

## 等级标签节点，显示玩家当前等级
@onready var level_label: Label = $LevelLabel

## 难度标签节点，显示当前难度等级（随时间提升）
@onready var diff_label: Label = $DiffLabel

## ========== 成员变量（运行时数据） ==========

## 玩家引用，用于获取玩家状态和连接信号
var _player: Node2D = null

## 当前梦境碎片数量（用于显示）
var _dream_fragment: int = 0

## 健康控制器引用，用于监听玩家健康状态变化
var _health_controller: Node = null

## ---------- FPS 计数器（可选显示模块） ----------
## 是否启用FPS显示（从 settings.cfg 读取 show_fps）
var _show_fps: bool = false

## 动态创建的FPS标签（未启用时为null，节省节点/绘制开销）
var _fps_label: Label = null

## FPS 采样定时器：与 _fps_frame_count 配合每 0.25s 刷新一次文字
var _fps_timer: float = 0.0
var _fps_frame_count: int = 0
const FPS_REFRESH_INTERVAL: float = 0.25  # 每秒4次刷新：流畅 + 低CPU

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 尝试查找玩家，如果找不到则延迟查找
	if not _find_player():
		call_deferred("_deferred_find_player")

	## ========== 升级/难度系统信号连接 ==========

	## 监听经验变化信号：碎片拾取时更新经验条
	## 数据流：Player.add_dream_fragment → UpgradeManager.add_exp → exp_changed → 此回调
	if UpgradeManager:
		UpgradeManager.exp_changed.connect(_on_exp_changed)
		## 监听等级提升信号：更新等级文字
		UpgradeManager.level_up.connect(_on_level_up)

	## 监听难度变化信号：更新难度文字（颜色随难度加深，制造紧迫感）
	if DifficultyManager:
		DifficultyManager.difficulty_changed.connect(_on_difficulty_changed)

	## 初始化经验条/等级/难度显示（读取单例当前值，兜底中途创建HUD的情况）
	_refresh_progress_displays()

	## 最后：根据 Settings 保存的 show_fps 初始化 FPS 标签
	_init_fps_display()

## ========== FPS 计数器：读取设置 + 动态创建/刷新标签 ==========

## 读取 settings.cfg 中的 show_fps 值：true 就创建 Label 并启动 _process 计数，false 则什么都不做
func _init_fps_display() -> void:
	var config := ConfigFile.new()
	var err: int = config.load("user://settings.cfg")
	if err == OK:
		_show_fps = bool(config.get_value("Settings", "show_fps", false))
	else:
		_show_fps = false  # 默认不显示（避免影响首次游戏体验）

	if _show_fps:
		## 动态创建 FPS 标签（放在 HUD 左上角下方、血量条之下，不遮挡其他信息）
		_fps_label = Label.new()
		_fps_label.name = "FPSLabel"
		_fps_label.text = "FPS: --"
		_fps_label.position = Vector2(20, 95)  # 经验条(72+8=80) + 15 空隙
		_fps_label.size = Vector2(200, 24)
		_fps_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		## 样式：白色半透明加粗字体 + 青色数值，性能调试友好
		_fps_label.add_theme_color_override("font_color", Color(0.6, 0.95, 1.0, 0.95))
		_fps_label.add_theme_font_size_override("font_size", 18)
		add_child(_fps_label)
		## 重置采样计数
		_fps_timer = 0.0
		_fps_frame_count = 0
		## 设置 process_mode 启用 _process 帧计数（HUD 根节点默认已是 INHERIT，这里仅记录）
		set_process(true)

## _process：FPS 计数 + 周期性刷新标签文本
## 只在 _show_fps=true 时跑计数逻辑（零性能浪费在关闭状态）
func _process(delta: float) -> void:
	if not _show_fps or _fps_label == null:
		return

	## 每帧 +1 帧计数 + 累计时间
	_fps_frame_count += 1
	_fps_timer += delta

	## 到达刷新阈值（默认0.25s）：计算平均FPS并刷新文字
	if _fps_timer >= FPS_REFRESH_INTERVAL:
		var avg_fps: float = float(_fps_frame_count) / maxf(_fps_timer, 0.0001)
		## 高帧率绿色 / 正常白色 / 低帧率红色警示
		var fps_text: String
		if avg_fps >= 55.0:
			fps_text = "FPS: %d  ✓" % int(round(avg_fps))
			_fps_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.5, 0.95))
		elif avg_fps >= 30.0:
			fps_text = "FPS: %d" % int(round(avg_fps))
			_fps_label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95, 0.95))
		else:
			fps_text = "FPS: %d  !" % int(round(avg_fps))
			_fps_label.add_theme_color_override("font_color", Color(1.0, 0.45, 0.45, 0.95))
		_fps_label.text = fps_text

		## 清零进入下一采样窗口
		_fps_timer = 0.0
		_fps_frame_count = 0

## 刷新等级/经验/难度显示（读取UpgradeManager和DifficultyManager的当前状态）
func _refresh_progress_displays() -> void:
	## 经验条：0~1进度
	if exp_bar and UpgradeManager:
		exp_bar.value = UpgradeManager.get_exp_progress()
	## 等级文字
	if level_label and UpgradeManager:
		level_label.text = "Lv %d" % UpgradeManager.level
	## 难度文字
	if diff_label and DifficultyManager:
		diff_label.text = DifficultyManager.get_difficulty_label()

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

## 经验变化回调：更新经验条进度（响应UpgradeManager.exp_changed）
## 参数：current_exp - 当前经验，needed - 距下一级所需
func _on_exp_changed(current_exp: int, needed: int) -> void:
	if exp_bar:
		## 进度=当前/所需（needed有0保护，Progress值域0~1）
		exp_bar.value = float(current_exp) / float(maxi(needed, 1))

## 等级提升回调：更新等级文字（响应UpgradeManager.level_up）
## 参数：new_level - 新等级
func _on_level_up(new_level: int) -> void:
	if level_label:
		level_label.text = "Lv %d" % new_level

## 难度变化回调：更新难度文字与颜色（响应DifficultyManager.difficulty_changed）
## 参数：new_level - 新难度等级
func _on_difficulty_changed(new_level: int) -> void:
	if diff_label == null:
		return
	## 更新难度文字
	diff_label.text = "难度 %d" % new_level
	## 颜色随难度渐进变化：1-2级灰色 → 3-4级黄色 → 5级以上红色（紧迫感）
	if new_level >= 5:
		diff_label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
	elif new_level >= 3:
		diff_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	else:
		diff_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))

## 玩家死亡回调：当玩家死亡时调用
func _on_player_killed() -> void:
	## 隐藏 HUD（游戏结束时不再显示）
	visible = false