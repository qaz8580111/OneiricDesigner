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

## ========== Buff图标栏（展示已激活的子弹特效词条） ==========

## Buff图标容器（水平排列在左上角血量条下方）
var _buff_container: HBoxContainer = null

## Buff图标缓存字典：key=effect_id, value=对应图标节点
var _buff_icons: Dictionary = {}

## 单个Buff图标的尺寸（正方形，像素）
const BUFF_ICON_SIZE: float = 36.0

## Buff图标之间的间距（像素）
const BUFF_ICON_GAP: float = 6.0

## ---------- 顶部居中游戏计时（玩家随时知道本局时长） ----------
## 顶部居中时间标签
var _time_center_label: Label = null
## 顶部计时刷新节流（0.25秒刷新一次，避免每帧拼字符串）
var _center_time_timer: float = 0.0
const CENTER_TIME_REFRESH_INTERVAL: float = 0.25

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

## ---------- 底部常驻状态栏（直播增强：观众可读性） ----------
## 存活时间标签（底部居中左）
var _time_label: Label = null
## 击杀数标签（底部居中中）
var _kills_label: Label = null
## 最高连击标签（底部居中右）
var _max_combo_label: Label = null
## 状态栏刷新节流计时器（0.5秒刷新一次，避免每帧读单例）
var _stat_refresh_timer: float = 0.0
const STAT_REFRESH_INTERVAL: float = 0.5

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

	## 监听已获得词条变化：新增技能/层数提升时刷新左上角buff图标栏
	## 数据流：UpgradeManager.apply_upgrade → upgrades_changed → 此回调
	if UpgradeManager:
		UpgradeManager.upgrades_changed.connect(_on_upgrades_changed)

	## 初始化经验条/等级/难度显示（读取单例当前值，兜底中途创建HUD的情况）
	_refresh_progress_displays()

	## ========== Buff图标栏初始化 ==========
	## 设计意图：左上角血量/经验条下方横向排列已获得的技能图标（含层数角标），
	## 让玩家直观看到当前持有哪些词条、各自几级（解决"吃了技能没感觉"的体验问题）
	_build_buff_bar()
	## 容器就绪后立即刷新一次（HUD可能在已有词条后才创建）
	if UpgradeManager:
		_refresh_buff_icons(UpgradeManager.get_acquired_upgrades())

	## 最后：根据 Settings 保存的 show_fps 初始化 FPS 标签
	_init_fps_display()

	## ========== 连击HUD挂载 ==========
	## ComboHUD 作为子节点挂到 GameHUD 下，自动跟随 GameHUD 生命周期
	var ComboHUDClass = preload("res://scripts/ui/ComboHUD.gd")
	var combo_hud: Control = Control.new()
	combo_hud.name = "ComboHUD"
	combo_hud.set_script(ComboHUDClass)
	combo_hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(combo_hud)

	## ========== 底部常驻状态栏（直播增强：观众可读性） ==========
	## 设计意图：非操作观众抬头就能看到"活了多久/杀了多少/最高连击"，
	## 创造"这个主播很猛"的印象；位置在屏幕底部居中，不遮挡游戏视野
	_build_bottom_status_bar()

	## ========== 顶部居中游戏计时 ==========
	## 玩家游戏中随时需要知道已存活时长，放屏幕顶部正中央最醒目
	_build_center_timer()

## 构建顶部居中的游戏计时标签
func _build_center_timer() -> void:
	_time_center_label = Label.new()
	_time_center_label.name = "CenterTimer"
	_time_center_label.text = "00:00"
	_time_center_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_time_center_label.add_theme_font_size_override("font_size", 22)
	## 金色半透明白字+黑色描边：任意背景上都可读
	_time_center_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.65, 0.95))
	_time_center_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_time_center_label.add_theme_constant_override("outline_size", 5)
	_time_center_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	## 水平居中于屏幕顶部（距顶12px，宽度200px）
	var screen_size: Vector2 = get_viewport_rect().size
	_time_center_label.position = Vector2(screen_size.x * 0.5 - 100.0, 12.0)
	_time_center_label.size = Vector2(200.0, 30.0)
	add_child(_time_center_label)

## 刷新顶部居中计时（节流调用）
func _refresh_center_timer() -> void:
	if _time_center_label == null or RunStats == null:
		return
	var total_sec: int = int(RunStats.elapsed_time)
	var mins: int = total_sec / 60
	var secs: int = total_sec % 60
	_time_center_label.text = "%02d:%02d" % [mins, secs]

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
		## 动态创建 FPS 标签（放在 HUD 左上角、buff栏下方，不遮挡其他信息）
		## buff栏在y=80高36px，故FPS从y=122开始
		_fps_label = Label.new()
		_fps_label.name = "FPSLabel"
		_fps_label.text = "FPS: --"
		_fps_label.position = Vector2(20, 122)
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

## _process：FPS 计数 + 周期性刷新底部状态栏
## FPS 只在 _show_fps=true 时跑计数逻辑；状态栏始终刷新（节流0.5秒）
func _process(delta: float) -> void:
	## ---------- 底部状态栏刷新（节流0.5秒） ----------
	if GameManager.is_playing():
		_stat_refresh_timer += delta
		if _stat_refresh_timer >= STAT_REFRESH_INTERVAL:
			_stat_refresh_timer = 0.0
			_refresh_bottom_status()
		## 顶部居中计时刷新（节流0.25秒）
		_center_time_timer += delta
		if _center_time_timer >= CENTER_TIME_REFRESH_INTERVAL:
			_center_time_timer = 0.0
			_refresh_center_timer()

	## ---------- FPS 计数 ----------
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

## ========== Buff图标栏 ==========

## 构建Buff图标栏容器（左上角，血量/经验条下方）
func _build_buff_bar() -> void:
	_buff_container = HBoxContainer.new()
	_buff_container.name = "BuffBar"
	_buff_container.add_theme_constant_override("separation", int(BUFF_ICON_GAP))
	## 位置：左上角，经验条(72px)下方，留8px间隙
	## 经验条在y=64，高8，所以buff栏起点y≈80
	_buff_container.position = Vector2(20, 80)
	## 不拦截鼠标（纯展示）
	_buff_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_buff_container)

## 稀有度对应的图标底色（普通灰白/稀有蓝/史诗紫，与三选一面板配色一致）
func _get_rarity_color(rarity: int) -> Color:
	match rarity:
		1:
			return Color(0.4, 0.7, 1.0)    ## 稀有：蓝色
		2:
			return Color(0.8, 0.4, 1.0)    ## 史诗：紫色
		_:
			return Color(0.85, 0.85, 0.9)  ## 普通：浅灰白

## 刷新Buff图标栏（响应UpgradeManager.upgrades_changed信号）
## 设计意图：增量更新——已存在的词条id保留节点（仅更新层数角标，避免闪烁），
##           新增的创建图标，已移除的销毁节点
## 参数：acquired - get_acquired_upgrades()返回的词条信息字典数组
func _refresh_buff_icons(acquired: Array) -> void:
	if _buff_container == null:
		return

	## 构建当前词条id集合（用于判断哪些图标需要保留）
	var current_ids: Dictionary = {}
	for info in acquired:
		current_ids[info["id"]] = info

	## 移除不再激活的buff图标
	for eid in _buff_icons.keys():
		if not current_ids.has(eid):
			var old: Control = _buff_icons[eid]
			if old != null and is_instance_valid(old):
				old.queue_free()
			_buff_icons.erase(eid)

	## 新增激活的buff图标；已存在的仅同步层数角标
	for eid in current_ids.keys():
		var info: Dictionary = current_ids[eid]
		if _buff_icons.has(eid):
			_update_buff_badge(_buff_icons[eid], int(info["stacks"]), int(info["max_stacks"]))
			continue
		var icon: Control = _create_buff_icon(info)
		_buff_container.add_child(icon)
		_buff_icons[eid] = icon

## 创建单个Buff图标（稀有度底色+技能名首2字+右下角层数角标）
## 参数：info - 词条信息字典（id/name/rarity/stacks/max_stacks）
## 返回：Buff图标节点
func _create_buff_icon(info: Dictionary) -> Control:
	## 外层Panel作为底色方块
	var icon: Panel = Panel.new()
	icon.custom_minimum_size = Vector2(BUFF_ICON_SIZE, BUFF_ICON_SIZE)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	## 用StyleBoxFlat设置稀有度底色与白色描边
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = _get_rarity_color(int(info["rarity"]))
	style.set_content_margin_all(0.0)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.border_color = Color(1, 1, 1, 0.4)
	icon.add_theme_stylebox_override("panel", style)

	## 内层Label显示技能名称首2字符（中文游戏名的快速识别方式）
	var label: Label = Label.new()
	var skill_name: String = String(info["name"])
	label.text = skill_name.substr(0, 2)
	label.add_theme_color_override("font_color", Color(0, 0, 0, 0.85))
	label.add_theme_font_size_override("font_size", 13)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.add_child(label)

	## 层数角标（右下角，Lv.2起显示；满级10用金色）
	var badge: Label = Label.new()
	badge.name = "LevelBadge"
	badge.add_theme_font_size_override("font_size", 11)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	badge.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	badge.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	badge.offset_left = -10
	badge.offset_top = -12
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.add_child(badge)
	_update_buff_badge(icon, int(info["stacks"]), int(info["max_stacks"]))

	## Tooltip显示完整技能名与层数（鼠标悬停查看）
	icon.tooltip_text = "%s  Lv.%d/%d" % [skill_name, int(info["stacks"]), int(info["max_stacks"])]

	return icon

## 更新图标右下角的层数角标（1级不显示，2级起白字，满级金字）
## 参数：icon - 图标节点；stacks - 当前层数；max_stacks - 上限
func _update_buff_badge(icon: Control, stacks: int, max_stacks: int) -> void:
	var badge: Label = icon.get_node_or_null("LevelBadge")
	if badge == null:
		return
	if stacks <= 1:
		badge.text = ""
		return
	badge.text = "×%d" % stacks
	if stacks >= max_stacks:
		badge.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))  ## 满级金色
	else:
		badge.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))  ## 普通白色
	## 描边保证深色底图上也清晰可读
	badge.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	badge.add_theme_constant_override("outline_size", 3)

## 已获得词条变化回调（响应UpgradeManager.upgrades_changed）
## 参数：acquired - 最新的词条信息数组
func _on_upgrades_changed(acquired: Array) -> void:
	_refresh_buff_icons(acquired)

## 玩家死亡回调：当玩家死亡时调用
func _on_player_killed() -> void:
	## 隐藏 HUD（游戏结束时不再显示）
	visible = false

## ========== 底部常驻状态栏（直播增强：观众可读性） ==========

## 构建底部常驻状态栏（屏幕底部居中：存活时间 | 击杀数 | 最高连击）
## 设计意图：非操作观众抬头就能看到本局核心数据，制造"主播很猛"的印象
## 位置：屏幕底部居中，距底边 24px，三栏等宽
func _build_bottom_status_bar() -> void:
	## 状态栏配置：[标签前缀, 颜色]
	var configs: Array = [
		["⏱", Color(0.75, 0.9, 1.0)],      ## 存活时间：淡蓝色
		["💀", Color(1.0, 0.5, 0.4)],       ## 击杀数：淡红色
		["🔥", Color(1.0, 0.85, 0.3)],      ## 最高连击：金色
	]
	var labels: Array = []

	## 三栏等宽，每栏 120px，总宽 360px，居中
	var bar_width: float = 360.0
	var bar_height: float = 28.0
	var column_width: float = bar_width / 3.0

	for i in range(3):
		var label: Label = Label.new()
		label.name = "BottomStat_%d" % i
		label.text = "%s --" % configs[i][0]
		label.add_theme_color_override("font_color", configs[i][1])
		label.add_theme_font_size_override("font_size", 14)
		label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
		label.add_theme_constant_override("outline_size", 4)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		## 位置：底部居中，三栏水平排列
		var center_x: float = get_viewport_rect().size.x * 0.5
		var col_x: float = center_x - bar_width * 0.5 + column_width * float(i)
		label.position = Vector2(col_x, get_viewport_rect().size.y - bar_height - 24.0)
		label.size = Vector2(column_width, bar_height)
		add_child(label)
		labels.append(label)

	_time_label = labels[0]
	_kills_label = labels[1]
	_max_combo_label = labels[2]

## 刷新底部状态栏文字（节流0.5秒调用一次，避免每帧读单例）
func _refresh_bottom_status() -> void:
	## 存活时间：从 RunStats 读取，格式 "MM:SS"
	if _time_label and RunStats:
		var total_sec: int = int(RunStats.elapsed_time)
		var mins: int = total_sec / 60
		var secs: int = total_sec % 60
		_time_label.text = "⏱ %02d:%02d" % [mins, secs]

	## 击杀数：从 RunStats 读取
	if _kills_label and RunStats:
		_kills_label.text = "💀 %d" % RunStats.kills

	## 最高连击：从 ComboManager 读取
	if _max_combo_label and ComboManager:
		var max_combo: int = ComboManager.get_max_combo()
		if max_combo > 0:
			_max_combo_label.text = "🔥 %d" % max_combo
		else:
			_max_combo_label.text = "🔥 --"