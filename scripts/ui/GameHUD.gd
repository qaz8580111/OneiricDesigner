## GameHUD.gd - 游戏 HUD 界面脚本
## 职责：显示玩家健康状态（血量）、梦境碎片数量、难度、装备护盾状态等实时游戏信息
## 继承：Control（Godot 4的UI控制节点，作为HUD容器）
## 数据流（被动刷新，HUD不持有游戏逻辑状态）：
##   Player.dream_fragment_changed / HealthController(health_changed, player_died) → 血量与碎片显示
##   DifficultyManager(difficulty_changed) → 难度文字
##   EquipmentComponent(equipment_changed) → 底部 6 装备槽展示（武器/护甲/鞋子/盾牌/戒指/法宝）
##   EquipmentShieldComponent(shield_equipped/shield_hit/...) → 护盾名称与耐久条
extends Control

## 图标加载库（按"icon_<id>.png"路径契约自动加载，缺失时回退文字图标）
const IconLibraryLib = preload("res://scripts/ui/IconLibrary.gd")

## 装备数据类（仅用于访问 Slot 枚举常量；走 preload 与项目"资源类显式 preload"惯例一致）
const EquipmentDataLib = preload("res://scripts/resources/equipment/EquipmentData.gd")

## ========== 节点引用（使用 @onready 延迟初始化） ==========

## 屏幕正下方状态行容器（血量组 | 护盾条 | 碎片数，水平排成一行）
## 护盾面板由 _build_shield_display() 在运行时插入其中（move_child 到索引 1，即血量组之后）
@onready var _bottom_status_row: HBoxContainer = $BottomStatusRow

## 血量条节点，用于显示玩家核心血量（位于底部状态行内的 HealthGroup 组中）
## 血量条不再显示引擎自带百分比文字（场景中 show_percentage=false），
## 数值改由同组的 _health_value_label 以"当前/上限"形式展示
@onready var health_bar: ProgressBar = $BottomStatusRow/HealthGroup/HealthBar

## 红血阈值刻度线（血条子节点）：锚点由 _sync_critical_marker() 对齐到阈值百分比，
## 血量跌破此线即进入红血，刻度线与数值一起呼吸闪烁
@onready var _critical_marker: ColorRect = $BottomStatusRow/HealthGroup/HealthBar/CriticalMarker

## 血量数值标签：显示核心血"当前/上限"（如 175/225）
## 与血条同属 HealthGroup，护盾面板插入时不会把二者拆散
@onready var _health_value_label: Label = $BottomStatusRow/HealthGroup/HealthValueLabel

## 梦境碎片标签节点，用于显示玩家当前拥有的梦境碎片数量（位于底部状态行内）
@onready var fragment_label: Label = $BottomStatusRow/FragmentLabel

## 难度标签节点，显示当前难度等级（随时间提升，位于左上角信息列）
@onready var diff_label: Label = $DiffLabel

## ========== 左上角信息列布局契约（跨脚本：需与 StageDirector 的 _stage_label 保持一致） ==========
## 左上角为"两列三行"排版，共 6 项（跨 GameHUD 与 StageDirector 两个 CanvasLayer，共用同一套坐标常量）：
##   左列 x=20 ：阶段(由 StageDirector 创建) / 存活时间 / 击杀数
##   右列 x=220：难度 / 场上怪物数 / FPS
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

## ========== 底部装备栏（屏幕中间下方：6 个装备槽，直接反映玩家当前穿戴） ==========
## 设计意图：装备系统成为唯一成长载体后，HUD 只需展示"穿了什么"——
##   武器/护甲/鞋子/盾牌/戒指/法宝六槽，图标取自装备本体（IconLibrary.get_equipment_icon）
##   或槽位兜底图标；护盾槽角标显示叠层；携带主动技能的槽位叠一层冷却遮罩

## 装备栏根容器（单组"装备"，屏幕底部居中，向上生长）
var _bottom_icon_root: HBoxContainer = null

## 装备栏内部图标行（6 个槽位控件水平排列）
var _equipment_row: HBoxContainer = null

## 槽位控件引用（下标即 EquipmentData.Slot 枚举值 0..5，长度固定 6）
var _equip_slot_panels: Array[Panel] = []       ## 槽位底板（提供稀有度边框/底色）
var _equip_slot_icons: Array[TextureRect] = []  ## 槽位图标
var _equip_slot_badges: Array[Label] = []       ## 右下角角标（护盾叠层 ×N）
var _equip_slot_masks: Array[ColorRect] = []    ## 主动技能冷却遮罩（自上而下覆盖）
var _equip_slot_labels: Array[Label] = []       ## 槽位名标签（图标下方）

## 装备组件引用（数据源：Player 的 EquipmentComponent；装备变更时刷新六槽）
var _equipment_component: Node = null
## 当前携带主动技能的槽位（-1=无；用于把冷却遮罩定位到对应槽位）
var _active_skill_slot: int = -1

## 槽位中文名（下标与 EquipmentData.Slot 枚举对齐：0=武器 1=护甲 2=鞋子 3=盾牌 4=戒指 5=法宝）
## 说明：空槽位没有 EquipmentData 实例、拿不到 get_slot_text()，故此处保留一份槽位名常量
const SLOT_TEXTS: Array[String] = ["武器", "护甲", "鞋子", "盾牌", "戒指", "法宝"]

## 单个图标的尺寸（正方形，像素）
const BUFF_ICON_SIZE: float = 36.0

## 图标之间的间距（像素）
const BUFF_ICON_GAP: float = 6.0

## 装备栏外框与组名主题色（金色，RPG 装备的通用视觉语言）
const EQUIPMENT_ACCENT_COLOR: Color = Color(0.95, 0.8, 0.4)

## ========== 底部主动技能栏（屏幕中间下方：N 个主动技能图标 + 冷却遮罩 + CD 倒计时） ==========
## 设计意图：装备化后主动技能无数量上限（可同时持有多件带技能的装备），
##   HUD 需与装备栏并列展示全部技能：选中项高亮边框、每技能独立冷却遮罩与剩余秒数；
##   切换键位（键盘 Q/E、手柄 LT/RT）由 Player._update_active_skill 处理，HUD 只读状态被动刷新
## 数据流：Player.get_active_skills()/get_active_skill_index()/get_active_skill_cooldown_ratio_at()
##         → 本模块写 UI（equipment_changed 时重建控件，_process 每帧推进冷却表现）

## 技能栏外框与组名主题色（青色，与装备金色区分）
const SKILL_ACCENT_COLOR: Color = Color(0.5, 0.85, 1.0)

## 技能栏外壳（PanelContainer；无技能时整体隐藏）
var _skill_shell: PanelContainer = null
## 技能栏内部图标行（N 个技能控件水平排列）
var _skill_row: HBoxContainer = null
## 技能控件引用（下标 = Player 主动技能下标，长度随技能数动态变化）
var _skill_widgets: Array[VBoxContainer] = []     ## 技能控件（图标+名称）
var _skill_panels: Array[Panel] = []              ## 技能底板（提供选中高亮边框）
var _skill_icons: Array[TextureRect] = []         ## 技能图标
var _skill_masks: Array[ColorRect] = []           ## 冷却遮罩（自上而下覆盖）
var _skill_cd_labels: Array[Label] = []           ## 冷却剩余秒数（居中大字）
var _skill_name_labels: Array[Label] = []         ## 技能名（图标下方小字）

## ========== 装备护盾显示（屏幕正下方状态行：名称 + 耐久条） ==========

## 护盾显示面板容器（名称耐久文字+耐久条，未装备护盾时整体隐藏）
## 运行时插入底部状态行，排在血条与碎片数之间
var _shield_panel: HBoxContainer = null
## 护盾名称+耐久数值标签（如"冰霜护盾 45/60"）
var _shield_name_label: Label = null
## 护盾耐久条（颜色随护盾类型）
var _shield_durability_bar: ProgressBar = null
## 装备护盾组件引用（数据源：Player下的EquipmentShieldComponent节点）
var _equipment_shield: Node = null
## 当前显示的护盾id（防止节流刷新时重复重建名称/颜色）
var _shield_display_id: String = ""

## ========== 成员变量（运行时数据） ==========

## 玩家引用，用于获取玩家状态和连接信号
var _player: Node2D = null

## 当前梦境碎片数量（用于显示）
var _dream_fragment: int = 0

## 健康控制器引用，用于监听玩家健康状态变化
var _health_controller: Node = null

## ---------- 血量显示（真实值 + 动画值分离） ----------
## 真实核心血 / 真实上限（由 health_changed 信号写入；数字文字直接显示这两个"事实值"）
var _target_core: float = 0.0
var _target_max_core: float = 0.0
## 动画核心血（每帧缓动逼近 _target_core，驱动血条填充分量）
## 上限不参与缓动：上限变化即刻生效，条"先退一格再回填"才是成长观感的来源
var _display_core: float = 0.0
## 是否已收到过血量状态：首次收到时动画值直接对齐，避免开局看到血条从 0 涨上来
var _health_ready: bool = false
## 是否处于红血状态（HUD 侧副本，供每帧呼吸与配色使用）
var _is_critical_ui: bool = false
## 红血阈值（0~1，来自 CoreHealthData.critical_threshold，用于摆放危险刻度线）
var _critical_threshold: float = 0.3
## 危险刻度线上次写入的锚点值（缓存：锚点写入会触发重排，避免重复写）
var _marker_threshold: float = 0.3
## 上限增长高亮剩余时长（>0 时数值文字转金并放大，让"上限变大"被看见）
var _max_grow_flash: float = 0.0
## 红血呼吸相位累加器（仅在红血时累加）
var _pulse_time: float = 0.0
## 数值文字上次写入的颜色（血量刷新高频，避免每帧重复写 theme override）
var _last_value_color: Color = Color(-1, -1, -1)

## ---------- 血量表现参数 ----------
## 血条动画收敛速率（指数缓动，帧率无关）：回血与上限增长用，越大越快（6≈0.3秒基本到位）
const HP_ANIM_RATE: float = 6.0
## 红血呼吸频率（弧度/秒）与呼吸时最低透明度
const CRITICAL_PULSE_SPEED: float = 6.0
const CRITICAL_PULSE_MIN_ALPHA: float = 0.45
## 上限增长时数值文字的金色放大高亮：持续时长（秒）与最大放大倍数
const MAX_GROW_FLASH_TIME: float = 0.8
const MAX_GROW_SCALE: float = 0.18

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
## 场上怪物数标签（右列第 2 行，y=40）
var _enemy_count_label: Label = null
## 状态栏刷新节流计时器（0.5秒刷新一次，避免每帧读单例）
var _stat_refresh_timer: float = 0.0
const STAT_REFRESH_INTERVAL: float = 0.5

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 尝试查找玩家，如果找不到则延迟查找
	if not _find_player():
		call_deferred("_deferred_find_player")

	## ========== 难度信号连接 ==========

	## 监听难度变化信号：更新难度文字（颜色随难度加深，制造紧迫感）
	if DifficultyManager:
		DifficultyManager.difficulty_changed.connect(_on_difficulty_changed)

	## 初始化难度显示（本项目无角色等级系统，仅难度随时间提升；读取单例当前值兜底中途创建HUD）
	_refresh_progress_displays()

	## ========== 底部装备栏初始化 ==========
	## 设计意图：屏幕中间下方展示 6 个装备槽（武器/护甲/鞋子/盾牌/戒指/法宝），
	## 让玩家一眼看到当前穿戴与主动技能冷却
	_build_equipment_bar()
	## ========== 底部主动技能栏初始化 ==========
	## 与装备栏并列展示全部主动技能（数量随装备变化；无技能时整组隐藏）
	_build_skill_bar()
	## ========== 装备护盾显示初始化 ==========
	## 护盾名称+耐久条（未装备时隐藏，装备后插入屏幕正下方状态行）
	_build_shield_display()
	## 面板就绪后立即刷新一次（兜底HUD在护盾已装备后才创建的情况；
	## _find_player中的那次刷新因面板未构建被空引用保护跳过）
	_refresh_shield_display()
	## 装备栏就绪后立即刷新一次（兜底HUD在玩家已穿戴装备后才创建的情况）
	_refresh_equipment_slots()

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
	## 设计意图：非操作观众一眼看到"活了多久/杀了多少/场上还剩多少怪"，
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
		## 动态创建 FPS 标签（左上角信息列右列第 3 行，紧随场上怪物数之后，不与其他信息重叠）
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

	## ---------- 血量条表现（每帧：动画缓动 + 红血呼吸 + 上限增长高亮） ----------
	## 必须放在 _show_fps 的提前 return 之前：血量表现与 FPS 显示开关无关
	_process_health_visuals(delta)

	## ---------- 主动技能冷却遮罩（每帧平滑推进；无主动技能时零开销） ----------
	_refresh_active_skill_cooldown()

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

	## ========== 装备栏接管 ==========
	## 获取装备组件引用（6 装备槽展示的数据源）
	if _player.has_method("get_equipment_component"):
		_equipment_component = _player.get_equipment_component()
	if _equipment_component != null and _equipment_component.has_signal("equipment_changed"):
		_equipment_component.connect("equipment_changed", _on_equipment_changed)

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
	## 首次连接后立即刷新一次装备栏（兜底HUD在玩家已穿戴装备后才创建的情况）
	_refresh_equipment_slots()
	## 首次连接后立即刷新一次技能栏（兜底HUD在玩家已获得主动技能后才创建的情况）
	_refresh_skill_bar()

	return true

## ========== 血量更新方法 ==========

## 更新血量显示（简单版本，备用方案：无 HealthController 时由 damaged/killed 信号驱动）
## 参数：current - 当前血量，max - 最大血量
## 说明：只登记目标值，实际绘制交给每帧的 _process_health_visuals()
func update_health(current: int, max: int) -> void:
	_target_core = float(current)
	_target_max_core = float(max)
	## 备用路径拿不到红血状态与阈值，按正常态处理
	_is_critical_ui = false
	## 首次收到状态时动画值直接对齐（避免开局看到血条从 0 涨上来）
	if not _health_ready:
		_health_ready = true
		_display_core = _target_core

## 更新梦境碎片显示
func _update_fragment_display() -> void:
	if fragment_label:
		fragment_label.text = "梦境碎片: %d" % _dream_fragment

## 更新健康显示（生存状态字典：核心血/上限/红血状态/红血阈值）
## 数据流：CoreHealthComponent.core_health_changed → PlayerHealthController.health_changed → 此方法
## 说明：本方法只登记"真实值 + 触发一次性的上限增长高亮"，条与数字的实际绘制
##       交给 _process_health_visuals() 每帧完成（上限增长/红血呼吸都需要逐帧过渡）
func _update_health_display(state: Dictionary) -> void:
	## 获取核心血量、上限、红血状态与阈值
	var core_hp: float = state.get("core", 0.0)
	var max_core: float = state.get("max_core", 100.0)

	## 上限增长检测：非首次且上限确实变大 → 触发数值文字金色放大高亮
	## （首次不触发：HUD 中途创建时 _target_max_core 还为 0，会被误判成"涨了一大截"）
	if _health_ready and max_core > _target_max_core + 0.01:
		_max_grow_flash = MAX_GROW_FLASH_TIME

	_target_core = core_hp
	_target_max_core = max_core
	_is_critical_ui = bool(state.get("is_critical", false))
	## 阈值来自 CoreHealthData.critical_threshold（可被词条改），钳制到可见区间避免刻度线贴边
	_critical_threshold = clampf(float(state.get("critical_threshold", _critical_threshold)), 0.01, 0.99)

	## 首次收到状态：动画值直接对齐，避免开局看到血条从 0 涨上来
	if not _health_ready:
		_health_ready = true
		_display_core = core_hp

	_sync_critical_marker()

## 对齐红血阈值刻度线（锚点 = 阈值百分比，条宽变化时刻度线自动跟随）
## 说明：写锚点会触发该 Control 重排，而血量变化是高频事件，故用 _marker_threshold
##       缓存"上次写入值"，仅在阈值真变化时才写
func _sync_critical_marker() -> void:
	if _critical_marker == null:
		return
	if absf(_critical_threshold - _marker_threshold) <= 0.0005:
		return
	_marker_threshold = _critical_threshold
	_critical_marker.anchor_left = _critical_threshold
	_critical_marker.anchor_right = _critical_threshold

## 血量条表现刷新（每帧）：填充分量缓动 + 绘制 + 红血呼吸 + 上限增长高亮
## 参数：delta - 帧间隔
## 设计意图（"上限增长动画"的实现口径）：
##   上限即时生效、当前血缓动回填。扩容时（如 50/100 → 75/125）分母先变大，
##   条先"退一格"到 40%，再缓缓灌回 60%，配合金色放大数字，把"上限撑开了"演出来；
##   若让上限也缓动，分母与分子同步增长、条长几乎不动，反而看不出变化
func _process_health_visuals(delta: float) -> void:
	## 未收到过血量状态时不绘制（保持场景默认满条，避免开局先空一条再跳满）
	if health_bar == null or not _health_ready:
		return

	## ---------- 血条长度 ----------
	## 上限不缓动：分母立刻变化，条的"退格—回填"过程才是成长观感
	health_bar.max_value = maxf(_target_max_core, 1.0)
	## 掉血即时到位（受击反馈要干脆）；回血/扩容带来的治疗走缓动
	if _target_core < _display_core:
		_display_core = _target_core
	else:
		_display_core = _approach(_display_core, _target_core, HP_ANIM_RATE, delta)
	health_bar.value = clampf(_display_core, 0.0, health_bar.max_value)

	## ---------- 红血呼吸（只脉动"危险线 + 数字"，整条血条不做透明度闪烁） ----------
	var pulse_alpha: float = 1.0
	if _is_critical_ui:
		_pulse_time += delta
		pulse_alpha = CRITICAL_PULSE_MIN_ALPHA + (1.0 - CRITICAL_PULSE_MIN_ALPHA) \
			* (0.5 + 0.5 * sin(_pulse_time * CRITICAL_PULSE_SPEED))
	else:
		_pulse_time = 0.0
	## 血条整体：红血转警示底色（CriticalMarker 是其子节点，会一并被染色）
	health_bar.modulate = Color(1.0, 0.3, 0.3, 1.0) if _is_critical_ui else Color.WHITE
	if _critical_marker:
		_critical_marker.modulate = Color(1, 1, 1, pulse_alpha)

	## ---------- 上限增长高亮：数字短暂放大并转金 ----------
	var grow_ratio: float = 0.0
	if _max_grow_flash > 0.0:
		_max_grow_flash = maxf(_max_grow_flash - delta, 0.0)
		grow_ratio = _max_grow_flash / MAX_GROW_FLASH_TIME
	if _health_value_label:
		## 放大以中心为轴（否则从左上角"长出来"，观感别扭）；容器布局不受 scale 影响
		if grow_ratio > 0.0 and _health_value_label.pivot_offset == Vector2.ZERO:
			_health_value_label.pivot_offset = _health_value_label.size * 0.5
		var label_scale: float = 1.0 + MAX_GROW_SCALE * grow_ratio
		_health_value_label.scale = Vector2(label_scale, label_scale)

	## ---------- 刷新数值文字 ----------
	_update_health_value_text(_target_core, _target_max_core, _is_critical_ui, grow_ratio, pulse_alpha)

## 指数缓动逼近（帧率无关）
## 参数：from - 当前值；to - 目标值；rate - 收敛速率（越大越快）；delta - 帧间隔
## 返回：本帧更新后的值
## 说明：用 1-exp(-rate*delta) 作为插值系数，不同帧率下收敛速度一致（比 lerp(a,b,rate) 更稳）
func _approach(from: float, to: float, rate: float, delta: float) -> float:
	return lerpf(from, to, 1.0 - exp(-rate * delta))

## 刷新血量数值文字（"当前/上限"）
## 参数：current - 当前核心血；max_value - 核心血上限；is_critical - 是否红血
##       grow_ratio - 上限增长高亮剩余比例（1→0，0 表示无高亮）；pulse_alpha - 红血呼吸透明度
## 说明：数字始终显示真实值（不跟缓动走）——条是"感觉"，数字是"事实"，两者互补；
##       取整口径与护盾耐久/伤害数字一致
func _update_health_value_text(current: float, max_value: float, is_critical: bool, grow_ratio: float = 0.0, pulse_alpha: float = 1.0) -> void:
	if _health_value_label == null:
		return
	_health_value_label.text = "%d/%d" % [int(round(current)), int(round(max_value))]

	## 颜色优先级：红血 > 上限增长高亮 > 常态
	var target_color: Color
	if is_critical:
		target_color = Color(1.0, 0.35, 0.35, 1)
	elif grow_ratio > 0.0:
		target_color = Color(1.0, 0.85, 0.2, 1)
	else:
		target_color = Color(1.0, 0.85, 0.85, 1)
	## 仅在颜色真变化时写 theme override（血量刷新高频，避免每帧重复覆盖）
	if target_color != _last_value_color:
		_last_value_color = target_color
		_health_value_label.add_theme_color_override("font_color", target_color)

	## 红血呼吸：数字与危险线同步脉动
	_health_value_label.modulate = Color(1, 1, 1, pulse_alpha)

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

## ========== 底部装备栏 ==========

## 构建底部装备栏（屏幕底部，6 个装备槽一组展示）
## 位置：锚定屏幕底部居中、向上生长，位于底部状态行（血条/护盾条/碎片数）之上，不遮挡战斗画面
func _build_equipment_bar() -> void:
	## 根容器：单组水平排列，锚定底部居中
	_bottom_icon_root = HBoxContainer.new()
	_bottom_icon_root.name = "EquipmentBar"
	_bottom_icon_root.add_theme_constant_override("separation", 14)
	_bottom_icon_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	## 锚定底部居中：水平双向生长（始终居中）、垂直向上生长（内容变高不压出屏幕）
	_bottom_icon_root.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_bottom_icon_root.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_bottom_icon_root.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_bottom_icon_root.offset_top = -120.0   ## 向上留出"组名 + 图标 + 槽位名"三行高度
	_bottom_icon_root.offset_bottom = -52.0 ## 距屏幕底边 52px：下方 44px 让给底部状态行
	add_child(_bottom_icon_root)

	## 单组"装备"：_build_icon_group 返回内部图标行(row)，其父 VBox 的父 PanelContainer 才是外壳
	_equipment_row = _build_icon_group("装备", EQUIPMENT_ACCENT_COLOR)
	_bottom_icon_root.add_child(_equipment_row.get_parent().get_parent())

	## 预创建 6 个槽位控件（下标即 Slot 枚举值），初始为"空槽"外观
	_equip_slot_panels.clear()
	_equip_slot_icons.clear()
	_equip_slot_badges.clear()
	_equip_slot_masks.clear()
	_equip_slot_labels.clear()
	for slot: int in range(SLOT_TEXTS.size()):
		_create_equipment_slot_widget(slot)

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

## 创建单个装备槽控件（VBox[底板 Panel(图标+冷却遮罩+角标), 槽位名 Label]）
## 参数：slot - 槽位下标（EquipmentData.Slot）
## 结构说明：底板用 Panel 提供稀有度边框与底色；冷却遮罩为自上而下覆盖的 ColorRect，
##           高度由 anchor_bottom = 冷却剩余比例驱动（可在 0 尺寸下仍随容器等比缩放）
func _create_equipment_slot_widget(slot: int) -> void:
	## 外层：图标 + 槽位名（垂直排列）
	var widget: VBoxContainer = VBoxContainer.new()
	widget.name = "EquipSlot_%d" % slot
	widget.add_theme_constant_override("separation", 2)
	widget.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _equipment_row != null:
		_equipment_row.add_child(widget)

	## 底板：稀有度边框 + 底色（尺寸固定，内容用满铺锚点）
	var panel: Panel = Panel.new()
	panel.name = "Frame"
	panel.custom_minimum_size = Vector2(BUFF_ICON_SIZE, BUFF_ICON_SIZE)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	widget.add_child(panel)

	## 图标（等比居中，四边内缩 1px 露出底板描边）
	var icon: TextureRect = TextureRect.new()
	icon.name = "Icon"
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 1
	icon.offset_top = 1
	icon.offset_right = -1
	icon.offset_bottom = -1
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(icon)

	## 冷却遮罩：默认隐藏，携带主动技能的槽位上由 _refresh_active_skill_cooldown() 驱动
	## anchor_bottom = 剩余冷却比例 → 遮罩自上而下覆盖，冷却完毕整块消失
	var mask: ColorRect = ColorRect.new()
	mask.name = "CooldownMask"
	mask.color = Color(0.05, 0.05, 0.1, 0.7)
	mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mask.anchor_bottom = 0.0
	mask.offset_bottom = 0.0
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.visible = false
	panel.add_child(mask)

	## 角标：右下角（护盾槽显示叠层 ×N）
	var badge: Label = Label.new()
	badge.name = "Badge"
	badge.add_theme_font_size_override("font_size", 11)
	badge.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	badge.add_theme_constant_override("outline_size", 3)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	badge.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	badge.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	badge.offset_left = -10
	badge.offset_top = -12
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(badge)

	## 槽位名（图标下方小字，空槽时半透明以示意"未装备"）
	var name_label: Label = Label.new()
	name_label.name = "SlotName"
	name_label.text = SLOT_TEXTS[slot]
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 10)
	name_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9, 0.9))
	name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	name_label.add_theme_constant_override("outline_size", 3)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	widget.add_child(name_label)

	## 登记引用（下标即槽位值，供刷新逻辑按槽位直取）
	_equip_slot_panels.append(panel)
	_equip_slot_icons.append(icon)
	_equip_slot_badges.append(badge)
	_equip_slot_masks.append(mask)
	_equip_slot_labels.append(name_label)

## 应用槽位底板样式（底色 + 边框色）
## 参数：panel - 槽位底板；bg_color - 底色；border_color - 边框色（空槽用暗灰，已装备用稀有度色）
func _apply_slot_frame_style(panel: Panel, bg_color: Color, border_color: Color) -> void:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = bg_color
	style.set_content_margin_all(0.0)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.border_color = border_color
	panel.add_theme_stylebox_override("panel", style)

## ========== 装备槽刷新 ==========

## 刷新底部 6 个装备槽（响应 EquipmentComponent.equipment_changed 与首次手动刷新）
## 数据流：EquipmentComponent.get_equipped(slot) → 本方法写UI
## 说明：以"槽位"为唯一遍历单位，每个槽位直接读该槽的装备数据，天然支持任意替换/卸下
func _refresh_equipment_slots() -> void:
	## 面板未构建时直接返回（_find_player 先于 _ready 执行的兜底）
	if _equipment_row == null or _equip_slot_panels.size() < SLOT_TEXTS.size():
		return
	## 懒获取装备组件（玩家可能在 HUD 之后创建）
	if _equipment_component == null and _player != null and _player.has_method("get_equipment_component"):
		_equipment_component = _player.get_equipment_component()

	## 护盾叠层（盾牌槽角标；无护盾时为 0）
	var shield_stack: int = 0
	if _equipment_shield != null and _equipment_shield.has_method("get_shield_stack"):
		shield_stack = _equipment_shield.get_shield_stack()

	## 主动技能槽位：固定取"首个携带主动技能的槽位"（与 EquipmentComponent 的穿戴顺序一致）
	_active_skill_slot = -1

	for slot: int in range(SLOT_TEXTS.size()):
		var data: Resource = null
		if _equipment_component != null and _equipment_component.has_method("get_equipped"):
			data = _equipment_component.get_equipped(slot)
		## 记录主动技能槽位（首个命中即锁定，与 EquipmentComponent._refresh_active_skill 口径一致）
		if data != null and _active_skill_slot < 0:
			if data.has_method("has_active_skill") and data.has_active_skill():
				_active_skill_slot = slot
		_update_equipment_slot_visual(slot, data, shield_stack)

	## 槽位集合变化后立即同步一次冷却遮罩（避免切换装备后遮罩残留/缺失）
	_refresh_active_skill_cooldown()

## 刷新单个装备槽的视觉（空槽暗灰占位 / 已装备稀有度边框 + 本体图标 + 叠层角标）
## 参数：slot - 槽位下标；data - 该槽装备数据（null 表示空槽）；shield_stack - 护盾叠层（仅盾牌槽用）
func _update_equipment_slot_visual(slot: int, data: Resource, shield_stack: int) -> void:
	if slot < 0 or slot >= _equip_slot_panels.size():
		return
	var panel: Panel = _equip_slot_panels[slot]
	var icon: TextureRect = _equip_slot_icons[slot]
	var badge: Label = _equip_slot_badges[slot]
	var mask: ColorRect = _equip_slot_masks[slot]
	var name_label: Label = _equip_slot_labels[slot]
	## 冷却遮罩由 _refresh_active_skill_cooldown() 统一驱动，此处先收起避免槽位复用残留
	mask.visible = false

	if data == null:
		## 空槽：暗灰底板 + 槽位兜底图标（低透明度示意"未装备"）
		_apply_slot_frame_style(panel, Color(0.12, 0.12, 0.16, 0.7), Color(0.4, 0.4, 0.5, 0.6))
		icon.texture = IconLibraryLib.get_slot_icon(slot, 0)
		icon.modulate = Color(1, 1, 1, 0.3)
		badge.text = ""
		name_label.modulate = Color(1, 1, 1, 0.5)
		panel.tooltip_text = "%s：空" % SLOT_TEXTS[slot]
		return

	## 已装备：稀有度边框 + 底色
	var rarity_color: Color = data.get_rarity_color() if data.has_method("get_rarity_color") else Color(0.85, 0.85, 0.9)
	_apply_slot_frame_style(panel, Color(0.1, 0.1, 0.14, 0.85), rarity_color)

	## 图标：装备本体图标（盾牌蓝图/词条/特效/槽位多级兜底由 IconLibrary 内部完成）
	icon.texture = IconLibraryLib.get_equipment_icon(data)
	icon.modulate = Color.WHITE
	name_label.modulate = Color.WHITE

	## 盾牌槽叠层角标（2 层起显示，满 3 层金色）
	badge.text = ""
	if slot == EquipmentDataLib.Slot.SHIELD and shield_stack > 1:
		badge.text = "×%d" % shield_stack
		if shield_stack >= 3:
			badge.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
		else:
			badge.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))

	## Tooltip：装备名 + 稀有度
	var equip_name: String = str(data.display_name) if "display_name" in data else SLOT_TEXTS[slot]
	var rarity_text: String = data.get_rarity_text() if data.has_method("get_rarity_text") else ""
	panel.tooltip_text = "%s [%s]" % [equip_name, rarity_text]

## 刷新主动技能冷却表现（每帧调用；无主动技能时零开销）
## 两块内容：
##   1. 装备槽遮罩：在"首个携带主动技能的装备槽"上覆盖当前选中技能的冷却比例（沿用旧逻辑）
##   2. 技能栏：逐技能驱动冷却遮罩 + CD 倒计时 + 选中高亮（多技能核心展示）
func _refresh_active_skill_cooldown() -> void:
	## ---------- 1. 装备槽遮罩（选中技能的冷却反馈） ----------
	if _active_skill_slot >= 0 and _active_skill_slot < _equip_slot_masks.size() \
			and _player != null and _player.has_method("get_active_skill_cooldown_ratio"):
		var mask: ColorRect = _equip_slot_masks[_active_skill_slot]
		var ratio: float = float(_player.get_active_skill_cooldown_ratio())
		## 冷却完毕（比例归零）：遮罩收起
		if ratio <= 0.001:
			mask.visible = false
		else:
			## 冷却中：遮罩自上而下覆盖，高度 = 剩余冷却比例
			mask.visible = true
			mask.anchor_bottom = clampf(ratio, 0.0, 1.0)
			mask.offset_bottom = 0.0
	## ---------- 2. 技能栏逐技能冷却/倒计时/高亮 ----------
	_update_skill_visuals()

## 装备变更信号回调（穿戴/替换/卸下装备时触发）
func _on_equipment_changed() -> void:
	_refresh_equipment_slots()
	## 装备变化可能改变主动技能集合（数量/内容），需重建技能栏
	_refresh_skill_bar()

## ========== 底部主动技能栏 ==========

## 构建技能栏外壳（与装备栏同处的底部居中容器，向右并列）
## 调用时机：_ready 中紧随 _build_equipment_bar 之后（依赖 _bottom_icon_root 已创建）
func _build_skill_bar() -> void:
	## 底部居中容器缺失时不构建（防御：正常流程不会发生）
	if _bottom_icon_root == null:
		return
	## 复用装备栏的图标分组外壳工厂：返回内部图标行，其父的父即外壳
	_skill_row = _build_icon_group("主动技能", SKILL_ACCENT_COLOR)
	_skill_shell = _skill_row.get_parent().get_parent() as PanelContainer
	_bottom_icon_root.add_child(_skill_shell)
	## 初始无技能：先整组隐藏，待 _refresh_skill_bar 按玩家实际技能数显隐
	_skill_shell.visible = false
	_refresh_skill_bar()

## 刷新技能栏（按 Player 当前主动技能集合重建 N 个技能控件）
## 调用时机：_ready 构建后 / _find_player 首次连接后 / equipment_changed 信号
## 说明：技能数量与内容会随装备变化，故此处整体重建（技能数很少，重建成本可忽略）
func _refresh_skill_bar() -> void:
	if _skill_row == null or _skill_shell == null:
		return
	## 读取玩家当前主动技能集合（Player 未就绪时视为空）
	var skills: Array = []
	if _player != null and _player.has_method("get_active_skills"):
		skills = _player.get_active_skills()
	## 清空旧控件（remove_child 立即脱离容器，避免旧图标残留一帧；再 queue_free 延后释放）
	for child in _skill_row.get_children():
		_skill_row.remove_child(child)
		child.queue_free()
	_skill_widgets.clear()
	_skill_panels.clear()
	_skill_icons.clear()
	_skill_masks.clear()
	_skill_cd_labels.clear()
	_skill_name_labels.clear()
	## 逐个技能创建控件
	for i in range(skills.size()):
		_create_skill_widget(i, skills[i])
	## 无技能时整组隐藏（避免空壳占据屏幕）
	_skill_shell.visible = not skills.is_empty()
	## 建好后立即同步一次选中高亮/冷却表现，避免重建到首帧之间闪空
	_update_skill_visuals()

## 创建单个技能控件（VBox[底板 Panel(图标+冷却遮罩+CD文字), 技能名 Label]）
## 参数：index - 技能下标（与 Player._active_skills 对齐）；skill - EquipmentActiveSkill 资源
func _create_skill_widget(index: int, skill: Resource) -> void:
	## 外层：图标 + 技能名（垂直排列）
	var widget: VBoxContainer = VBoxContainer.new()
	widget.name = "SkillSlot_%d" % index
	widget.add_theme_constant_override("separation", 2)
	widget.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_skill_row.add_child(widget)

	## 底板：提供选中高亮边框（样式由 _apply_skill_frame_style 统一写入）
	var panel: Panel = Panel.new()
	panel.name = "Frame"
	panel.custom_minimum_size = Vector2(BUFF_ICON_SIZE, BUFF_ICON_SIZE)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	widget.add_child(panel)

	## 技能图标（统一使用 IconLibrary 技能图；缺失时调用方无需回退，底板即占位）
	var icon: TextureRect = TextureRect.new()
	icon.name = "Icon"
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 1
	icon.offset_top = 1
	icon.offset_right = -1
	icon.offset_bottom = -1
	icon.texture = IconLibraryLib.get_active_skill_icon()
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(icon)

	## 冷却遮罩：默认隐藏，由 _update_skill_visuals() 按剩余冷却比例驱动（自上而下覆盖）
	var mask: ColorRect = ColorRect.new()
	mask.name = "CooldownMask"
	mask.color = Color(0.05, 0.05, 0.1, 0.7)
	mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mask.anchor_bottom = 0.0
	mask.offset_bottom = 0.0
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.visible = false
	panel.add_child(mask)

	## CD 倒计时文字：冷却中居中显示剩余秒数（如 "6.4"），可用时留空
	var cd_label: Label = Label.new()
	cd_label.name = "CDLabel"
	cd_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cd_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cd_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cd_label.add_theme_font_size_override("font_size", 14)
	cd_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	cd_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	cd_label.add_theme_constant_override("outline_size", 3)
	cd_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cd_label.text = ""
	panel.add_child(cd_label)

	## 技能名（图标下方小字；技能未命名时回退"技能N"）
	var name_label: Label = Label.new()
	name_label.name = "SkillName"
	var skill_name: String = str(skill.display_name) if "display_name" in skill else ""
	if skill_name.is_empty():
		skill_name = "技能%d" % (index + 1)
	name_label.text = skill_name
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 10)
	name_label.add_theme_color_override("font_color", Color(0.85, 0.92, 1.0, 0.95))
	name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	name_label.add_theme_constant_override("outline_size", 3)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	widget.add_child(name_label)

	## 登记引用（下标与技能集合对齐，供每帧刷新直取）
	_skill_widgets.append(widget)
	_skill_panels.append(panel)
	_skill_icons.append(icon)
	_skill_masks.append(mask)
	_skill_cd_labels.append(cd_label)
	_skill_name_labels.append(name_label)

## 每帧刷新技能栏视觉（选中高亮 + 冷却遮罩 + CD 倒计时）
## 数据流：Player.get_active_skill_index()/get_active_skill_cooldown_ratio_at()/
##         get_active_skill_cooldown_remaining_at() → 逐技能写 UI
## 说明：控件数量与技能数不一致时（极少数竞态）先重建再刷新，保证下标可安全访问
func _update_skill_visuals() -> void:
	if _player == null or _skill_panels.is_empty():
		return
	## 竞态防护：技能数与控件数不符时重建一次
	var skill_count: int = 0
	if _player.has_method("get_active_skills"):
		skill_count = _player.get_active_skills().size()
	if skill_count != _skill_panels.size():
		_refresh_skill_bar()
		return
	## 当前选中技能下标（用于高亮边框）
	var selected: int = 0
	if _player.has_method("get_active_skill_index"):
		selected = int(_player.get_active_skill_index())

	for i in range(_skill_panels.size()):
		## 读取该技能冷却比例与剩余秒数（越界由 Player 侧钳制并返回 0）
		var ratio: float = 0.0
		var remain: float = 0.0
		if _player.has_method("get_active_skill_cooldown_ratio_at"):
			ratio = float(_player.get_active_skill_cooldown_ratio_at(i))
		if _player.has_method("get_active_skill_cooldown_remaining_at"):
			remain = float(_player.get_active_skill_cooldown_remaining_at(i))

		## 冷却遮罩：归零收起，否则自上而下覆盖
		var mask: ColorRect = _skill_masks[i]
		if ratio <= 0.001:
			mask.visible = false
		else:
			mask.visible = true
			mask.anchor_bottom = clampf(ratio, 0.0, 1.0)
			mask.offset_bottom = 0.0

		## CD 倒计时文字：仅在冷却中显示剩余秒数
		var cd_label: Label = _skill_cd_labels[i]
		cd_label.text = "%.1f" % remain if remain > 0.05 else ""

		## 选中高亮边框
		_apply_skill_frame_style(_skill_panels[i], i == selected)

## 应用技能底板样式（选中=金色粗边框，未选中=暗青细边框）
## 参数：panel - 技能底板；is_selected - 是否为当前选中技能
func _apply_skill_frame_style(panel: Panel, is_selected: bool) -> void:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.14, 0.85)
	style.set_content_margin_all(0.0)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	var border_w: int = 2 if is_selected else 1
	style.border_width_left = border_w
	style.border_width_right = border_w
	style.border_width_top = border_w
	style.border_width_bottom = border_w
	style.border_color = Color(1.0, 0.85, 0.3) if is_selected else Color(0.4, 0.6, 0.8, 0.8)
	panel.add_theme_stylebox_override("panel", style)

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
		return

	## 护盾颜色（缺属性时兜底默认青蓝色，与掉落物视觉一致）
	var shield_color: Color = data.shield_color if "shield_color" in data else Color(0.3, 0.6, 1.0)
	var shield_id: String = str(data.shield_id) if "shield_id" in data else ""

	## 护盾类型变化时才重建配色（节流轮询下避免每0.5秒重建样式）
	if shield_id != _shield_display_id:
		_shield_display_id = shield_id
		## 名称与耐久条颜色随护盾类型
		_shield_name_label.add_theme_color_override("font_color", shield_color)
		_shield_durability_bar.tint_over = shield_color
		_shield_durability_bar.tint_under = Color(0.3, 0.3, 0.3, 0.5)

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

## 玩家死亡回调：当玩家死亡时调用
func _on_player_killed() -> void:
	## 隐藏 HUD（游戏结束时不再显示）
	visible = false

## ========== 左上角常驻信息列（直播增强：观众可读性） ==========

## 构建左上角信息列（两列三行排版，坐标契约见文件顶部 TOP_LEFT_* 常量）
## 左列：存活时间 / 击杀数；右列：场上怪物数（右列第 1 行是 DiffLabel"难度"，由场景文件定义）
func _build_top_status_bar() -> void:
	## 信息列配置：[标签前缀, 颜色, 列索引, 行索引]
	var configs: Array = [
		["⏱", Color(0.75, 0.9, 1.0), 0, 1],  ## 存活时间：淡蓝色，左列第 2 行
		["💀", Color(1.0, 0.5, 0.4), 0, 2],   ## 击杀数：淡红色，左列第 3 行
		["👾", Color(0.8, 0.6, 1.0), 1, 1],  ## 场上怪物数：淡紫色，右列第 2 行
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
	_enemy_count_label = labels[2]

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

	## 场上怪物数：以 "enemy" 组为唯一真源
	## 说明：GameWorld 常规刷怪与 StageDirector 的 BOSS 均加入该组，敌人死亡 queue_free
	##       后自动出组，无需额外维护计数（读 GameWorld._enemy_count 会漏掉 BOSS）
	if _enemy_count_label:
		_enemy_count_label.text = "👾 %d" % get_tree().get_nodes_in_group("enemy").size()