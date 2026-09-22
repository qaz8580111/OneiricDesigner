## GameHUD.gd - 游戏 HUD 界面脚本
## 职责：显示玩家健康状态（血量）、梦境碎片数量、难度、装备护盾状态等实时游戏信息
## 继承：Control（Godot 4的UI控制节点，作为HUD容器）
## 数据流（被动刷新，HUD不持有游戏逻辑状态）：
##   Player.dream_fragment_changed / HealthController(health_changed, player_died) → 血量与碎片显示
##   DifficultyManager(difficulty_changed) → 难度文字
##   EquipmentShieldComponent(shield_equipped/shield_hit/...) → 护盾类型图标与耐久显示
extends Control

## 图标加载库（按"icon_<id>.png"路径契约自动加载，缺失时回退文字图标）
const IconLibraryLib = preload("res://scripts/ui/IconLibrary.gd")

## ========== 节点引用（使用 @onready 延迟初始化） ==========

## 屏幕正下方状态行容器（血条 | 护盾条 | 碎片数，水平排成一行）
## 护盾面板由 _build_shield_display() 在运行时插入其中（move_child 到索引 1）
@onready var _bottom_status_row: HBoxContainer = $BottomStatusRow

## 血量条节点，用于显示玩家核心血量（位于底部状态行内）
@onready var health_bar: ProgressBar = $BottomStatusRow/HealthBar

## 梦境碎片标签节点，用于显示玩家当前拥有的梦境碎片数量（位于底部状态行内）
@onready var fragment_label: Label = $BottomStatusRow/FragmentLabel

## 难度标签节点，显示当前难度等级（随时间提升，位于左上角信息列）
@onready var diff_label: Label = $DiffLabel

## ========== 左上角信息列布局契约（跨脚本：需与 StageDirector 的 _stage_label 保持一致） ==========
## 左上角为"两列三行"排版，共 6 项（跨 GameHUD 与 StageDirector 两个 CanvasLayer，共用同一套坐标常量）：
##   左列 x=20 ：阶段(由 StageDirector 创建) / 存活时间 / 击杀数
##   右列 x=220：难度 / 最高连击 / FPS
## 行 y 坐标：14 / 40 / 66（行高 26）
## 统一字号：16（左上角 6 项全部使用同一号字，避免大小混杂）
## 第 4 行（y=92）两列均空置：预留给 StageDirector 的终局文案（"终极关卡 · 用时 123.4 秒"），
## 该文案较长，另起一行独占可避免与右列"难度"重叠
## 注意：改动此处务必同步 StageDirector 的 STAGE_LABEL_POS/STAGE_LABEL_FINAL_POS、GameHUD.tscn 的 DiffLabel
const TOP_LEFT_X: float = 20.0          ## 第一列左基准 x
const TOP_LEFT_COL_W: float = 200.0     ## 列宽（留足阶段文字所需宽度）
const TOP_LEFT_COL2_X: float = TOP_LEFT_X + TOP_LEFT_COL_W  ## 第二列左基准 x
const TOP_LEFT_START_Y: float = 14.0    ## 第一行的 y
const TOP_LEFT_LINE_H: float = 26.0     ## 行高（行距）
const TOP_LEFT_FONT_SIZE: int = 16      ## 统一字号

## ========== 底部图标栏（屏幕中间下方：属性/技能/护盾/构型四组分区） ==========

## 底部图标栏根容器（四组水平排列，屏幕底部居中，向上生长）
var _bottom_icon_root: HBoxContainer = null

## 四组图标行容器：属性组（纯数值词条）/ 技能组（子弹特效词条）/ 护盾组（当前装备护盾）/
## 构型组（当前装备弹道构型）
var _attribute_row: HBoxContainer = null
var _skill_row: HBoxContainer = null
var _shield_icon_row: HBoxContainer = null
var _pattern_icon_row: HBoxContainer = null

## 属性图标缓存：key=upgrade_id, value=图标节点
var _attribute_icons: Dictionary = {}
## 技能图标缓存：key=upgrade_id, value=图标节点
var _skill_icons: Dictionary = {}
## 底部护盾图标（当前装备护盾，未装备时隐藏）
var _shield_bottom_icon: Control = null
## 底部弹道构型图标（当前装备构型，未装备时隐藏；单槽位、无层数角标）
var _pattern_bottom_icon: Control = null

## 单个图标的尺寸（正方形，像素）
const BUFF_ICON_SIZE: float = 36.0

## 图标之间的间距（像素）
const BUFF_ICON_GAP: float = 6.0

## 弹道构型组边框与图标底色（橙黄，与弹道构型三选一面板主题色一致）
const PATTERN_ACCENT_COLOR: Color = Color(1.0, 0.6, 0.2)

## 弹道构型掉落物图标 id（对应 IconLibrary.DROP_ICON_MAP 的 "shot_pattern" → icon_BC.png）
const PATTERN_DROP_ICON_ID: String = "shot_pattern"

## ========== 装备护盾显示（屏幕正下方状态行：名称 + 耐久条，图标已移到底部护盾组） ==========

## 护盾显示面板容器（名称耐久文字+耐久条，未装备护盾时整体隐藏）
## 运行时插入底部状态行，排在血条与碎片数之间
var _shield_panel: HBoxContainer = null
## 护盾名称+耐久数值标签（如"冰霜护盾 45/60"）
var _shield_name_label: Label = null
## 护盾耐久条（颜色随护盾类型）
var _shield_durability_bar: ProgressBar = null
## 装备护盾组件引用（数据源：Player下的EquipmentShieldComponent节点）
var _equipment_shield: Node = null
## 当前显示的护盾id（防止节流刷新时重复重建图标/颜色）
var _shield_display_id: String = ""
## 底部护盾图标的贴图矩形（随护盾类型变化，缺失时隐藏露出色块）
var _shield_bottom_icon_rect: TextureRect = null

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

## ---------- 左上角常驻信息列（直播增强：观众可读性） ----------
## 存活时间标签（左列第 2 行，y=40）
var _time_label: Label = null
## 击杀数标签（左列第 3 行，y=66）
var _kills_label: Label = null
## 最高连击标签（右列第 2 行，y=40）
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

	## ========== 难度/词条系统信号连接 ==========

	## 监听难度变化信号：更新难度文字（颜色随难度加深，制造紧迫感）
	if DifficultyManager:
		DifficultyManager.difficulty_changed.connect(_on_difficulty_changed)

	## 监听已获得词条变化：新增技能/层数提升时刷新底部图标栏
	## 数据流：UpgradeManager.apply_upgrade → upgrades_changed → 此回调
	if UpgradeManager:
		UpgradeManager.upgrades_changed.connect(_on_upgrades_changed)

	## 初始化难度显示（本项目无角色等级系统，仅难度随时间提升；读取单例当前值兜底中途创建HUD）
	_refresh_progress_displays()

	## ========== 底部图标栏初始化 ==========
	## 设计意图：屏幕中间下方按"属性/技能/护盾/构型"四组分区排列已获得词条、
	## 护盾与弹道构型图标，让玩家直观看到当前持有的属性、技能各自几级（层数角标）
	## 以及当前装备的护盾与构型
	_build_bottom_icon_bar()
	## ========== 装备护盾显示初始化 ==========
	## 护盾名称+耐久条（未装备时隐藏，装备后插入屏幕正下方状态行）
	_build_shield_display()
	## 面板就绪后立即刷新一次（兜底HUD在护盾已装备后才创建的情况；
	## _find_player中的那次刷新因面板未构建被空引用保护跳过）
	_refresh_shield_display()
	## 构型图标同样在就绪后刷新一次（兜底HUD在构型已装备后才创建的情况）
	_refresh_pattern_display()
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

	## ========== 左上角信息列（直播增强：观众可读性） ==========
	## 设计意图：非操作观众一眼看到"活了多久/杀了多少/最高连击"，
	## 位置统一收敛到屏幕左上角，与 StageDirector 的"阶段 N/10"标签纵向排列，互不重叠
	_build_top_status_bar()

	## ========== 右上角小地图挂载 ==========
	## 实时显示玩家位置 + 商店/神庙标记（存在时），作为 GameHUD 子节点跟随生命周期
	var MinimapClass = preload("res://scripts/ui/Minimap.gd")
	var minimap: Control = MinimapClass.new()
	minimap.name = "Minimap"
	add_child(minimap)

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
		## 动态创建 FPS 标签（左上角信息列右列第 3 行，紧随最高连击之后，不与其他信息重叠）
		_fps_label = Label.new()
		_fps_label.name = "FPSLabel"
		_fps_label.text = "FPS: --"
		_fps_label.position = Vector2(TOP_LEFT_COL2_X, TOP_LEFT_START_Y + TOP_LEFT_LINE_H * 2.0)
		_fps_label.size = Vector2(TOP_LEFT_COL_W, TOP_LEFT_LINE_H)
		_fps_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		## 样式：白色半透明加粗字体 + 青色数值，性能调试友好
		_fps_label.add_theme_color_override("font_color", Color(0.6, 0.95, 1.0, 0.95))
		_fps_label.add_theme_font_size_override("font_size", TOP_LEFT_FONT_SIZE)
		add_child(_fps_label)
		## 重置采样计数
		_fps_timer = 0.0
		_fps_frame_count = 0
		## 设置 process_mode 启用 _process 帧计数（HUD 根节点默认已是 INHERIT，这里仅记录）
		set_process(true)

## _process：FPS 计数 + 周期性刷新左上角信息列与护盾显示
## FPS 只在 _show_fps=true 时跑计数逻辑；信息列与护盾显示始终刷新（节流0.5秒）
func _process(delta: float) -> void:
	## ---------- 左上角信息列与护盾显示刷新（节流0.5秒） ----------
	if GameManager.is_playing():
		_stat_refresh_timer += delta
		if _stat_refresh_timer >= STAT_REFRESH_INTERVAL:
			_stat_refresh_timer = 0.0
			_refresh_top_status()
			## 护盾耐久回盾是持续过程（无信号通知），靠节流轮询同步进度条
			_refresh_shield_display()
			## 构型装备不发信号（四类三选一只有词条发 upgrades_changed），同样靠节流轮询同步显隐
			_refresh_pattern_display()

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

## 刷新难度显示（读取DifficultyManager的当前状态）
func _refresh_progress_displays() -> void:
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

	## ========== 装备护盾显示接管 ==========
	## 获取装备护盾组件引用（护盾统计显示的数据源）
	_equipment_shield = _player.get_node_or_null("EquipmentShieldComponent")
	if _equipment_shield != null:
		## 装备变更信号：拾取/替换/卸下护盾时立即刷新显示（含显隐切换）
		if _equipment_shield.has_signal("shield_equipped"):
			_equipment_shield.connect("shield_equipped", _on_shield_equipped_changed)
		## 受击信号：耐久扣减立即刷新（避免等待节流轮询的视觉延迟）
		if _equipment_shield.has_signal("shield_hit"):
			_equipment_shield.connect("shield_hit", _on_shield_vital_changed)
		## 破碎/回满信号：状态突变立即同步
		if _equipment_shield.has_signal("shield_broken"):
			_equipment_shield.connect("shield_broken", _on_shield_state_changed)
		if _equipment_shield.has_signal("shield_regen_full"):
			_equipment_shield.connect("shield_regen_full", _on_shield_state_changed)
	
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

	## 首次连接后立即刷新一次护盾显示（兜底HUD在护盾已装备后才创建的情况）
	## 面板未构建时该调用被内部空引用保护跳过，_ready构建面板后会再次刷新
	_refresh_shield_display()

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

## ========== 底部图标栏 ==========

## 构建底部图标栏（屏幕底部，属性/技能/护盾/构型四组分区展示）
## 位置：锚定屏幕底部居中、向上生长，位于底部状态行（血条/护盾条/碎片数）之上，不遮挡战斗画面
## 分区设计：四组各自独立外壳（边框色不同）+ 组名标签，属性/技能/护盾/构型互不混排
func _build_bottom_icon_bar() -> void:
	## 根容器：四组水平排列，锚定底部居中
	_bottom_icon_root = HBoxContainer.new()
	_bottom_icon_root.name = "BottomIconBar"
	_bottom_icon_root.add_theme_constant_override("separation", 14)
	_bottom_icon_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	## 锚定底部居中：水平双向生长（始终居中）、垂直向上生长（内容变高不压出屏幕）
	_bottom_icon_root.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_bottom_icon_root.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_bottom_icon_root.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_bottom_icon_root.offset_top = -112.0   ## 向上留 60px（组名+图标一行的高度）
	_bottom_icon_root.offset_bottom = -52.0 ## 距屏幕底边 52px：下方 44px 让给底部状态行（血条/护盾条/碎片数）
	add_child(_bottom_icon_root)

	## 四组：属性（金色边框）/ 技能（蓝色边框）/ 护盾（绿色边框）/ 构型（橙黄边框，紧邻护盾之后）
	_attribute_row = _build_icon_group("属性", Color(0.95, 0.75, 0.3))
	_skill_row = _build_icon_group("技能", Color(0.4, 0.7, 1.0))
	_shield_icon_row = _build_icon_group("护盾", Color(0.4, 0.9, 0.5))
	_pattern_icon_row = _build_icon_group("构型", PATTERN_ACCENT_COLOR)
	## _build_icon_group 返回的是内部图标行(row)，其父级是 VBox，VBox 父级是外壳 PanelContainer；
	## 必须把外壳加入根容器，边框/底色/组名才会真正显示
	_bottom_icon_root.add_child(_attribute_row.get_parent().get_parent())
	_bottom_icon_root.add_child(_skill_row.get_parent().get_parent())
	_bottom_icon_root.add_child(_shield_icon_row.get_parent().get_parent())
	_bottom_icon_root.add_child(_pattern_icon_row.get_parent().get_parent())

	## 护盾组内预创建护盾图标（初始隐藏，装备护盾后由_refresh_shield_display显示）
	_create_shield_bottom_icon()
	## 构型组内预创建构型图标（初始隐藏，装备构型后由_refresh_pattern_display显示）
	_create_pattern_bottom_icon()

## 创建单个图标分组（外壳 + 组名标签 + 图标行），返回内部图标行 HBox
## 参数：group_name - 组名（属性/技能/护盾）；border_color - 分组外壳边框色（视觉区分三组）
func _build_icon_group(group_name: String, border_color: Color) -> HBoxContainer:
	## 外壳：PanelContainer 提供边框 + 半透明底色，三组互不混排
	var shell: PanelContainer = PanelContainer.new()
	shell.name = "Group_" + group_name
	shell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.1, 0.78)
	style.border_color = border_color
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 5
	style.corner_radius_top_right = 5
	style.corner_radius_bottom_left = 5
	style.corner_radius_bottom_right = 5
	style.content_margin_left = 5
	style.content_margin_right = 5
	style.content_margin_top = 3
	style.content_margin_bottom = 3
	shell.add_theme_stylebox_override("panel", style)

	## 内部：组名标签 + 图标行（垂直排列）
	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shell.add_child(vbox)

	var label: Label = Label.new()
	label.text = group_name
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", border_color)
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("outline_size", 3)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(label)

	var row: HBoxContainer = HBoxContainer.new()
	row.name = "IconRow"
	row.add_theme_constant_override("separation", int(BUFF_ICON_GAP))
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(row)
	return row

## 在护盾组内创建护盾图标（Panel底色 + 贴图 + 层数角标，与buff图标风格一致）
## 初始隐藏；装备护盾后由_refresh_shield_display填充底色/贴图/角标并显示
func _create_shield_bottom_icon() -> void:
	if _shield_icon_row == null:
		return
	_shield_bottom_icon = Panel.new()
	_shield_bottom_icon.name = "ShieldBottomIcon"
	_shield_bottom_icon.custom_minimum_size = Vector2(BUFF_ICON_SIZE, BUFF_ICON_SIZE)
	_shield_bottom_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shield_bottom_icon.visible = false
	## 底色样式：初始用默认青蓝（实际颜色在刷新时按护盾类型覆盖）
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.3, 0.6, 1.0)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.border_color = Color(1, 1, 1, 0.4)
	_shield_bottom_icon.add_theme_stylebox_override("panel", style)

	## 贴图矩形：等比缩放居中，内缩1px露出底板描边
	_shield_bottom_icon_rect = TextureRect.new()
	_shield_bottom_icon_rect.name = "ShieldTex"
	_shield_bottom_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_shield_bottom_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_shield_bottom_icon_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_shield_bottom_icon_rect.offset_left = 1
	_shield_bottom_icon_rect.offset_top = 1
	_shield_bottom_icon_rect.offset_right = -1
	_shield_bottom_icon_rect.offset_bottom = -1
	_shield_bottom_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shield_bottom_icon.add_child(_shield_bottom_icon_rect)

	## 层数角标（右下角，2层起显示）
	var badge: Label = Label.new()
	badge.name = "LevelBadge"
	badge.add_theme_font_size_override("font_size", 11)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	badge.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	badge.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	badge.offset_left = -10
	badge.offset_top = -12
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shield_bottom_icon.add_child(badge)

	_shield_icon_row.add_child(_shield_bottom_icon)

## 更新护盾图标角标（层数≥2时显示"×N"，≥3层金色，与buff图标角标视觉一致）
## 参数：stack - 当前护盾叠层数
func _update_shield_bottom_badge(stack: int) -> void:
	if _shield_bottom_icon == null or not is_instance_valid(_shield_bottom_icon):
		return
	var badge: Label = _shield_bottom_icon.get_node_or_null("LevelBadge")
	if badge == null:
		return
	if stack <= 1:
		badge.text = ""
		return
	badge.text = "×%d" % stack
	if stack >= 3:
		badge.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	else:
		badge.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	badge.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	badge.add_theme_constant_override("outline_size", 3)

## 在构型组内创建弹道构型图标（Panel底色 + 贴图）
## 初始隐藏；装备构型后由_refresh_pattern_display显示
## 与护盾图标的结构差异：构型单槽位、不叠层、无等级，故不建层数角标；
## 且构型没有各自专属图标，统一用掉落物图标 icon_BC（地面掉落与HUD所见一致）
func _create_pattern_bottom_icon() -> void:
	if _pattern_icon_row == null:
		return
	_pattern_bottom_icon = Panel.new()
	_pattern_bottom_icon.name = "PatternBottomIcon"
	_pattern_bottom_icon.custom_minimum_size = Vector2(BUFF_ICON_SIZE, BUFF_ICON_SIZE)
	_pattern_bottom_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pattern_bottom_icon.visible = false
	## 底色：构型主题橙黄（固定色，不随构型类型变化，与三选一面板/*掉落图标呼应）
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = PATTERN_ACCENT_COLOR
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.border_color = Color(1, 1, 1, 0.4)
	_pattern_bottom_icon.add_theme_stylebox_override("panel", style)

	## 贴图矩形：等比缩放居中，内缩1px露出底板描边
	## 图标缺失（png未在编辑器内导入）时隐藏贴图，露出底色块作为占位
	var icon_rect: TextureRect = TextureRect.new()
	icon_rect.name = "PatternTex"
	icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon_rect.offset_left = 1
	icon_rect.offset_top = 1
	icon_rect.offset_right = -1
	icon_rect.offset_bottom = -1
	icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon_tex: Texture2D = IconLibraryLib.get_drop_icon(PATTERN_DROP_ICON_ID)
	icon_rect.texture = icon_tex
	icon_rect.visible = icon_tex != null
	_pattern_bottom_icon.add_child(icon_rect)

	_pattern_icon_row.add_child(_pattern_bottom_icon)

## 稀有度对应的图标底色（普通灰白/稀有蓝/史诗紫，与三选一面板配色一致）
func _get_rarity_color(rarity: int) -> Color:
	match rarity:
		1:
			return Color(0.4, 0.7, 1.0)    ## 稀有：蓝色
		2:
			return Color(0.8, 0.4, 1.0)    ## 史诗：紫色
		_:
			return Color(0.85, 0.85, 0.9)  ## 普通：浅灰白

## 刷新底部图标栏（响应UpgradeManager.upgrades_changed信号）
## 设计意图：增量更新——已存在的词条id保留节点（仅更新层数角标，避免闪烁），
##           新增的创建图标并按"属性/技能"类型归入对应组，已移除的销毁节点
## 参数：acquired - get_acquired_upgrades()返回的词条信息字典数组
func _refresh_buff_icons(acquired: Array) -> void:
	if _attribute_row == null or _skill_row == null:
		return

	## 按类型分离：属性（is_effect=false）→ 属性组；技能（is_effect=true）→ 技能组
	var attr_ids: Dictionary = {}
	var skill_ids: Dictionary = {}
	for info in acquired:
		if bool(info.get("is_effect", false)):
			skill_ids[info["id"]] = info
		else:
			attr_ids[info["id"]] = info

	## 移除不再激活的属性图标
	for eid in _attribute_icons.keys():
		if not attr_ids.has(eid):
			var old: Control = _attribute_icons[eid]
			if old != null and is_instance_valid(old):
				old.queue_free()
			_attribute_icons.erase(eid)
	## 新增/更新属性图标
	for eid in attr_ids.keys():
		var info: Dictionary = attr_ids[eid]
		if _attribute_icons.has(eid):
			_update_buff_badge(_attribute_icons[eid], int(info["stacks"]), int(info["max_stacks"]))
			continue
		var icon: Control = _create_buff_icon(info)
		_attribute_row.add_child(icon)
		_attribute_icons[eid] = icon

	## 移除不再激活的技能图标
	for eid in _skill_icons.keys():
		if not skill_ids.has(eid):
			var old: Control = _skill_icons[eid]
			if old != null and is_instance_valid(old):
				old.queue_free()
			_skill_icons.erase(eid)
	## 新增/更新技能图标
	for eid in skill_ids.keys():
		var info: Dictionary = skill_ids[eid]
		if _skill_icons.has(eid):
			_update_buff_badge(_skill_icons[eid], int(info["stacks"]), int(info["max_stacks"]))
			continue
		var icon: Control = _create_buff_icon(info)
		_skill_row.add_child(icon)
		_skill_icons[eid] = icon

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

	## 内层显示内容：优先真实图标（IconLibrary按id+稀有度加载），
	## 图标缺失时回退技能名首2字文字（容错，游戏不因缺图报错）
	var icon_tex: Texture2D = IconLibraryLib.get_upgrade_icon(String(info["id"]), int(info["rarity"]))
	if icon_tex != null:
		## 真实图标：TextureRect等比铺满（内缩1px露出稀有度边框色）
		var tex_rect: TextureRect = TextureRect.new()
		tex_rect.texture = icon_tex
		## EXPAND_IGNORE_SIZE：忽略纹理原始1024px尺寸，按容器大小显示
		tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		## KEEP_ASPECT_CENTERED：等比缩放居中，不拉伸变形
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		## 四边内缩1px：露出底层Panel的白色描边与稀有度底色边线
		tex_rect.offset_left = 1
		tex_rect.offset_top = 1
		tex_rect.offset_right = -1
		tex_rect.offset_bottom = -1
		tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.add_child(tex_rect)
	else:
		## 回退：Label显示技能名称首2字符（中文游戏名的快速识别方式）
		var label: Label = Label.new()
		var skill_name_fallback: String = String(info["name"])
		label.text = skill_name_fallback.substr(0, 2)
		label.add_theme_color_override("font_color", Color(0, 0, 0, 0.85))
		label.add_theme_font_size_override("font_size", 13)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.add_child(label)

	## 层数角标（右下角，Lv.2起显示；满级5用金色）
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
	icon.tooltip_text = "%s  Lv.%d/%d" % [String(info["name"]), int(info["stacks"]), int(info["max_stacks"])]

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

## ========== 装备护盾显示（类型图标 + 健康度） ==========

## 构建护盾显示面板（屏幕正下方状态行内，未装备时整体隐藏）
## 结构：护盾面板(HBox) → 信息列(VBox：名称耐久文字+耐久条)
## 位置：插入底部状态行的索引 1，形成"血条 | 护盾条 | 碎片数"一行三段的排布
func _build_shield_display() -> void:
	_shield_panel = HBoxContainer.new()
	_shield_panel.name = "ShieldDisplay"
	_shield_panel.add_theme_constant_override("separation", 6)
	## 行内垂直居中（保持名称+耐久条的自身高度，不被行高拉伸）
	_shield_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_shield_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shield_panel.visible = false  ## 初始无护盾，装备后由刷新逻辑显示
	## 护盾图标已在底部护盾组，此处只保留名称+耐久条
	if _bottom_status_row != null:
		_bottom_status_row.add_child(_shield_panel)
		_bottom_status_row.move_child(_shield_panel, 1)  ## 排到血条之后、碎片数之前
	else:
		## 兜底：底部状态行缺失时退回左上角原位置，保证护盾信息不丢失
		_shield_panel.position = Vector2(TOP_LEFT_X, TOP_LEFT_START_Y)
		add_child(_shield_panel)

	## 信息列：名称耐久文字 + 耐久条（垂直排列）
	var info_box: VBoxContainer = VBoxContainer.new()
	info_box.add_theme_constant_override("separation", 2)
	info_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	info_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shield_panel.add_child(info_box)

	## 名称+耐久数值标签（如"冰霜护盾 45/60"），描边保证任意背景可读
	_shield_name_label = Label.new()
	_shield_name_label.add_theme_font_size_override("font_size", 12)
	_shield_name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_shield_name_label.add_theme_constant_override("outline_size", 3)
	_shield_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_box.add_child(_shield_name_label)

	## 耐久条（8px细条，颜色随护盾类型，关闭默认百分比文字）
	_shield_durability_bar = ProgressBar.new()
	_shield_durability_bar.custom_minimum_size = Vector2(150, 8)
	_shield_durability_bar.show_percentage = false
	_shield_durability_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_box.add_child(_shield_durability_bar)

## 刷新护盾显示（显隐/图标/名称/耐久条全面同步）
## 数据流：EquipmentShieldComponent(get_shield_data/get_current_hp) → 本方法写UI
## 调用时机：护盾信号立即刷新 + _process节流轮询（回盾是持续过程无信号）
func _refresh_shield_display() -> void:
	## 面板未构建时直接返回（_find_player先于_ready构建面板执行的兜底）
	if _shield_panel == null:
		return
	## 懒获取装备护盾组件（玩家可能在HUD之后创建）
	if _equipment_shield == null and _player != null:
		_equipment_shield = _player.get_node_or_null("EquipmentShieldComponent")

	## 读取护盾数据与耐久（有护盾数据就显示，耐久为0也保持显示——等待5秒回盾）
	var data: Resource = null
	var hp: float = 0.0
	var max_hp: float = 0.0
	var stack: int = 1
	if _equipment_shield != null and _equipment_shield.has_method("get_shield_data"):
		data = _equipment_shield.get_shield_data()
		if data != null:
			hp = _equipment_shield.get_current_hp()
			max_hp = _equipment_shield.get_max_hp()
			if _equipment_shield.has_method("get_shield_stack"):
				stack = _equipment_shield.get_shield_stack()
	## 有护盾数据就显示面板（即使耐久为0也保持——护盾会在5秒后回盾满值）
	_shield_panel.visible = data != null
	if data == null:
		_shield_display_id = ""
		## 未装备护盾：底部护盾图标同步隐藏
		if _shield_bottom_icon != null and is_instance_valid(_shield_bottom_icon):
			_shield_bottom_icon.visible = false
		return

	## 护盾颜色（缺属性时兜底默认青蓝色，与掉落物视觉一致）
	var shield_color: Color = data.shield_color if "shield_color" in data else Color(0.3, 0.6, 1.0)
	var shield_id: String = str(data.shield_id) if "shield_id" in data else ""

	## 护盾类型变化时才重建配色与贴图（节流轮询下避免每0.5秒重建节点）
	if shield_id != _shield_display_id:
		_shield_display_id = shield_id
		## 名称与耐久条颜色随护盾类型
		_shield_name_label.add_theme_color_override("font_color", shield_color)
		_shield_durability_bar.tint_over = shield_color
		_shield_durability_bar.tint_under = Color(0.3, 0.3, 0.3, 0.5)
		## 底部护盾图标底色=护盾颜色（白色细描边，与buff图标框风格统一）
		if _shield_bottom_icon != null and is_instance_valid(_shield_bottom_icon):
			var holder_style: StyleBoxFlat = StyleBoxFlat.new()
			holder_style.bg_color = shield_color
			holder_style.set_content_margin_all(0.0)
			holder_style.corner_radius_top_left = 4
			holder_style.corner_radius_top_right = 4
			holder_style.corner_radius_bottom_left = 4
			holder_style.corner_radius_bottom_right = 4
			holder_style.border_width_left = 1
			holder_style.border_width_right = 1
			holder_style.border_width_top = 1
			holder_style.border_width_bottom = 1
			holder_style.border_color = Color(1, 1, 1, 0.4)
			_shield_bottom_icon.add_theme_stylebox_override("panel", holder_style)
			## 类型图标：IconLibrary按icon_<shield_id>.png契约加载；缺失时隐藏贴图露出色块
			var icon_tex: Texture2D = IconLibraryLib.get_shield_icon(shield_id)
			if _shield_bottom_icon_rect != null:
				_shield_bottom_icon_rect.texture = icon_tex
				_shield_bottom_icon_rect.visible = icon_tex != null

	## 底部护盾图标显隐 + 层数角标（每次刷新都更新——叠层/耐久归零仍保持显示）
	if _shield_bottom_icon != null and is_instance_valid(_shield_bottom_icon):
		_shield_bottom_icon.visible = true
		_update_shield_bottom_badge(stack)

	## 名称+耐久数值与耐久条进度（每次刷新都更新——耐久是高频变化数据）
	## 叠层显示：2层以上在名称后加×N；耐久为0时显示"回盾中"提示
	var display_name: String = str(data.display_name) if "display_name" in data else "护盾"
	if stack > 1:
		display_name += " ×%d" % stack
	if hp <= 0.0:
		## 护盾破碎等待回盾：显示"回盾中"替代数值
		_shield_name_label.text = "%s 回盾中..." % display_name
		_shield_durability_bar.value = 0.0
	else:
		_shield_name_label.text = "%s %d/%d" % [display_name, int(ceilf(hp)), int(max_hp)]
		_shield_durability_bar.max_value = max_hp
		_shield_durability_bar.value = hp

## 装备变更信号回调（拾取/替换/卸下护盾时触发）
func _on_shield_equipped_changed(_data: Resource) -> void:
	_refresh_shield_display()

## 护盾受击信号回调（耐久扣减立即同步，参数不使用仅触发刷新）
func _on_shield_vital_changed(_remaining_hp: float, _absorbed: float) -> void:
	_refresh_shield_display()

## 护盾破碎/回满信号回调（无参信号）
func _on_shield_state_changed() -> void:
	_refresh_shield_display()

## ========== 弹道构型显示（底部构型组图标） ==========

## 刷新弹道构型图标显隐（构型单槽位：装备后显示，替换后保持显示，未装备时隐藏）
## 数据流：Player.get_shot_pattern() → 本方法写UI
## 调用时机：_process节流轮询（四类三选一中只有词条会发 upgrades_changed，构型装备不发信号，
##           与护盾回盾同款靠轮询同步；贴图固定为 icon_BC，故只需同步显隐）
func _refresh_pattern_display() -> void:
	if _pattern_bottom_icon == null or not is_instance_valid(_pattern_bottom_icon):
		return
	## 玩家未就绪（HUD先于玩家创建）：保持隐藏，找到玩家后的轮询会自动补上
	if _player == null:
		return
	## 未装备时返回 null（刻意不用 get_final_shot_pattern 的兜底单发构型，
	## 否则会把"未装备构型"误显示成已装备）
	var pattern: Resource = null
	if _player.has_method("get_shot_pattern"):
		pattern = _player.get_shot_pattern()
	_pattern_bottom_icon.visible = pattern != null

## 玩家死亡回调：当玩家死亡时调用
func _on_player_killed() -> void:
	## 隐藏 HUD（游戏结束时不再显示）
	visible = false

## ========== 左上角常驻信息列（直播增强：观众可读性） ==========

## 构建左上角信息列（两列三行排版，坐标契约见文件顶部 TOP_LEFT_* 常量）
## 左列：存活时间 / 击杀数；右列：最高连击（右列第 1 行是 DiffLabel"难度"，由场景文件定义）
func _build_top_status_bar() -> void:
	## 信息列配置：[标签前缀, 颜色, 列索引, 行索引]
	var configs: Array = [
		["⏱", Color(0.75, 0.9, 1.0), 0, 1],  ## 存活时间：淡蓝色，左列第 2 行
		["💀", Color(1.0, 0.5, 0.4), 0, 2],   ## 击杀数：淡红色，左列第 3 行
		["🔥", Color(1.0, 0.85, 0.3), 1, 1],  ## 最高连击：金色，右列第 2 行
	]
	var labels: Array = []

	for i in range(3):
		var label: Label = Label.new()
		label.name = "TopStat_%d" % i
		label.text = "%s --" % configs[i][0]
		label.add_theme_color_override("font_color", configs[i][1])
		label.add_theme_font_size_override("font_size", TOP_LEFT_FONT_SIZE)
		label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
		label.add_theme_constant_override("outline_size", 4)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		## 位置：由 [列索引, 行索引] 换算到两列网格坐标
		var col_index: int = configs[i][2]
		var row_index: int = configs[i][3]
		var col_x: float = TOP_LEFT_X if col_index == 0 else TOP_LEFT_COL2_X
		label.position = Vector2(col_x, TOP_LEFT_START_Y + TOP_LEFT_LINE_H * float(row_index))
		label.size = Vector2(TOP_LEFT_COL_W, TOP_LEFT_LINE_H)
		add_child(label)
		labels.append(label)

	_time_label = labels[0]
	_kills_label = labels[1]
	_max_combo_label = labels[2]

## 刷新左上角信息列文字（节流0.5秒调用一次，避免每帧读单例）
func _refresh_top_status() -> void:
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