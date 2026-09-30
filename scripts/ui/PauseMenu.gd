## PauseMenu.gd - 暂停菜单逻辑脚本
## 职责：管理游戏暂停界面，处理继续游戏、打开设置、返回主菜单三种操作
## 继承：Control（UI控件基类，作为暂停菜单的根节点）
## 数据流：按钮点击 / 导航器cancel_pressed(ESC) → 信号(resume_game/open_settings/quit_to_menu) → Main.gd 监听后执行
## 注意：游戏中按ESC打开暂停菜单由 Main.gd 统一处理；暂停菜单打开时按ESC走导航器取消 = 继续游戏
extends Control

## 图标加载库（状态面板显示核心血/属性/技能/护盾图标用；装备面板解析装备图标用）
const IconLibraryLib = preload("res://scripts/ui/IconLibrary.gd")

## 槽位中文名（索引与 EquipmentData.Slot 枚举对齐：0=武器 1=护甲 2=鞋子 3=盾牌 4=戒指 5=法宝）
## 说明：空槽位没有 EquipmentData 实例、拿不到 get_slot_text()，故此处保留一份槽位名常量
const SLOT_TEXTS: Array[String] = ["武器", "护甲", "鞋子", "盾牌", "戒指", "法宝"]

## 一键分解的二次确认时限（秒）：首次按下进入待确认，此时限内再按一次才真正执行
const BULK_CONFIRM_TIME: int = 3

## 暂停菜单必须在暂停状态下仍能处理输入，需要 ALWAYS 模式
func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

## ========== 信号定义（用于与其他节点通信） ==========

## 继续游戏信号：当用户点击继续游戏按钮时发出，通知上层恢复游戏
signal resume_game()

## 打开设置信号：当用户点击设置按钮时发出，通知上层打开设置界面
signal open_settings()

## 返回主菜单信号：当用户点击返回主菜单按钮时发出，通知上层返回主菜单
signal quit_to_menu()

## ========== UI节点引用（使用 @onready 延迟初始化） ==========

## 暂停菜单标题标签（显示"暂停"）
@onready var title_label: Label = $VBoxContainer/Title

## 继续游戏按钮
@onready var resume_button: Button = $VBoxContainer/ResumeButton

## 设置按钮（打开设置界面）
@onready var settings_button: Button = $VBoxContainer/SettingsButton

## 状态与装备按钮（打开暂停菜单内的"状态 + 装备/背包"合并面板）
@onready var player_panel_button: Button = $VBoxContainer/PlayerPanelButton

## 返回主菜单按钮
@onready var quit_button: Button = $VBoxContainer/QuitButton

## ========== 菜单导航器（用于手柄/键盘导航） ==========

## 菜单导航器脚本（用于处理键盘/手柄的菜单导航）
var MENU_NAVIGATOR_SCRIPT: Script = load("res://scripts/autoload/MenuController.gd")

## 菜单导航器实例
var _navigator: Node = null

## ========== 状态与装备合并面板（暂停菜单内，单屏左右分栏） ==========

## 合并面板根容器（隐藏主菜单按钮后显示）
var _player_panel: Control = null

## 合并面板标题标签
var _player_panel_title_label: Label = null

## 双子页容器（页签0=状态，页签1=背包）
## 键鼠点击页签切页；手柄 LT/RT 由 _process 轮询 game_choice_prev/next 修改 current_tab
var _player_tabs: TabContainer = null

## 状态行容器（核心血/属性/技能/护盾逐行展示）
var _status_rows: VBoxContainer = null

## "已装备"栏标题标签（语言切换时需更新）
var _equipment_slots_header: Label = null

## 已装备槽位列表容器（6 个槽位各一个按钮；已装备的可点击卸下）
var _equipment_slots_box: VBoxContainer = null

## 背包装备列表容器（每件装备一个按钮；点击穿戴）
var _equipment_backpack_box: VBoxContainer = null

## 背包容量提示标签（显示"背包 (n/容量)"，满时追加提示）
var _equipment_capacity_label: Label = null

## 装备碎片数值标签（按槽位索引与 SLOT_TEXTS 对齐，展示各槽位已累计的碎片数）
var _fragment_value_labels: Array[Label] = []

## "装备碎片"分组标题标签（语言切换时需更新）
var _fragment_header_label: Label = null

## 一键分解按钮（顺序与 _bulk_rarities 一一对应）
var _bulk_buttons: Array[Button] = []

## 一键分解按钮对应的稀有度（与 _bulk_buttons 一一对应）
var _bulk_rarities: Array[int] = []

## 待二次确认的稀有度（-1 表示当前无待确认操作）
var _bulk_confirm_pending: int = -1

## 二次确认剩余秒数（<=0 即自动取消，回到初始文案）
var _bulk_confirm_left: int = 0

## 二次确认倒计时定时器（每秒一跳；暂停菜单为 ALWAYS 模式，故暂停中仍计时）
var _bulk_confirm_timer: Timer = null

## 合并面板底部操作提示标签
var _equipment_hint_label: Label = null

## 合并面板返回按钮
var _player_panel_back_button: Button = null

## ========== 装备对比弹窗（按住对比键时，展示"聚焦的背包装备 vs 同槽位已装备件"） ==========

## 对比弹窗根容器（浮层，默认隐藏；按住 ui_compare 键且焦点在背包装备上时显示）
var _compare_panel: PanelContainer = null

## 对比弹窗内容容器（每次显示时清空重建；仅放 Label，不含 Button，避免抢导航焦点）
var _compare_rows: VBoxContainer = null

## 当前可作为对比候选的背包装备（焦点/悬停落在背包条目上时记录；落在已装备槽位/按钮上时置空）
var _focused_compare_candidate: EquipmentData = null

## 当前弹窗正在展示的候选件（用于避免每帧清空重建：候选未变则复用已生成的内容）
var _compare_shown_candidate: EquipmentData = null

## ========== 生命周期方法 ==========

## _ready() - 节点进入场景树时调用一次，用于初始化
func _ready() -> void:
	## 构建"状态 + 装备/背包"合并面板（先于文本刷新，保证各标签/返回按钮引用就绪）
	_build_player_panel()
	## 更新界面文本（支持多语言）
	_update_text()
	
	## 连接按钮信号到处理方法
	resume_button.pressed.connect(_on_resume_button_pressed)
	settings_button.pressed.connect(_on_settings_button_pressed)
	player_panel_button.pressed.connect(_on_player_panel_button_pressed)
	quit_button.pressed.connect(_on_quit_button_pressed)
	
	## 监听语言变化信号（语言切换时更新界面文本）
	TranslationManager.language_changed.connect(_on_language_changed)

	## 添加菜单导航器为子节点（用于键盘/手柄导航）
	if MENU_NAVIGATOR_SCRIPT != null:
		_navigator = MENU_NAVIGATOR_SCRIPT.new()
		add_child(_navigator)
		## 连接导航器的取消信号到统一取消分发（状态面板打开时先返回主菜单，否则继续游戏）
		_navigator.cancel_pressed.connect(_on_navigator_cancel)
		## 等待一帧确保节点完全加入场景树
		await get_tree().process_frame
		## 激活导航器
		_navigator.activate(self)
	else:
		print("MenuNavigator script not found!")

## _exit_tree() - 节点离开场景树时调用，用于清理
func _exit_tree() -> void:
	## 如果导航器存在，停用导航器
	if _navigator != null:
		_navigator.deactivate()

## _process() - 合并面板打开期间轮询"切页"与"按住对比"两类持续输入
## 设计意图：暂停菜单在暂停状态下仍运行（PROCESS_MODE_ALWAYS），故这两类输入无法走
##           _unhandled_input 的"事件驱动"路径（扳机轴与"按住不放"都只体现为状态而非单次事件），
##           统一在 _process 里轮询；面板未打开时首帧即 return，零开销
func _process(_delta: float) -> void:
	## 必须判"树内可见"而非仅判面板自身：暂停菜单整体隐藏（游戏中）时本节点仍在 ALWAYS 模式下运行，
	## 若继续轮询会提前消费 game_choice_prev/next，导致游戏内"主动技能切换"收不到该输入
	if not is_visible_in_tree():
		return
	if _player_panel == null or not _player_panel.visible:
		return
	_handle_tab_switch_input()
	_update_compare_hold()

## 手柄 LT/RT（键盘 Q/E）循环切换"状态 / 背包"页签
## 说明：LT/RT 由 InputManager 做轴越阈边沿检测后转为 game_choice_prev/next 动作，
##       与设置界面切页共用同一套映射与手感；切页成功才播点击音
func _handle_tab_switch_input() -> void:
	if _player_tabs == null:
		return
	var tab_count: int = _player_tabs.get_tab_count()
	if tab_count <= 0:
		return
	if InputManager and InputManager.is_action_just_pressed_safe("game_choice_next"):
		## RT：下一页（右循环，最后一页 → 回第一页）
		_player_tabs.current_tab = (_player_tabs.current_tab + 1) % tab_count
		if AudioManager:
			AudioManager.play("ui_click", 0.5)
	elif InputManager and InputManager.is_action_just_pressed_safe("game_choice_prev"):
		## LT：上一页（左循环，第一页 → 回最后一页）
		_player_tabs.current_tab = (_player_tabs.current_tab - 1 + tab_count) % tab_count
		if AudioManager:
			AudioManager.play("ui_click", 0.5)

## 页签切换回调（tab_changed）：刷新导航器可聚焦控件列表
## 鼠标点击与 LT/RT 触发两条切页路径都会走到这里，故刷新逻辑只写一处
## 必要性：隐藏页的控件仍在场景树中但 is_visible_in_tree() 为 false，导航列表必须重建，
##         否则焦点会落进看不见的页（手柄表现为"导航到空白处、按A没反应"）
func _on_player_tab_changed(_tab_index: int) -> void:
	if _navigator != null and _navigator.has_method("refresh_controls"):
		_navigator.refresh_controls()

## 按住对比键（手柄/键盘 X）时展示装备对比弹窗，松开即收起
## 说明：需求要求"按住才出现"，故不能再用 focus_entered 的瞬时触发；
##       此处每帧检查按住状态，仅在候选件发生变化时才重建内容（避免每帧清空重建导致闪烁）
func _update_compare_hold() -> void:
	var holding: bool = InputManager != null and InputManager.is_action_pressed_safe("ui_compare")
	if not holding or _focused_compare_candidate == null:
		_hide_equip_compare()
		return
	if _compare_shown_candidate == _focused_compare_candidate:
		return
	_show_equip_compare(_focused_compare_candidate)

## ========== 界面文本更新方法 ==========

## 更新界面文本（支持多语言）
func _update_text() -> void:
	title_label.text = TranslationManager.t("PAUSED_TITLE")
	resume_button.text = TranslationManager.t("BUTTON_RESUME")
	settings_button.text = TranslationManager.t("BUTTON_SETTINGS")
	player_panel_button.text = TranslationManager.t("BUTTON_PLAYER_PANEL")
	quit_button.text = TranslationManager.t("BUTTON_QUIT_TO_MENU")
	## 合并面板固定文本（页签标题/列标题/底部提示/返回按钮；列表内文本由数据驱动，在刷新时生成）
	if _player_panel_title_label != null:
		_player_panel_title_label.text = TranslationManager.t("PLAYER_PANEL_TITLE")
	## 页签标题：TabContainer 默认取子节点名，此处用翻译 key 覆盖（切语言时同步生效）
	if _player_tabs != null:
		_player_tabs.set_tab_title(0, TranslationManager.t("STATUS_TITLE"))
		_player_tabs.set_tab_title(1, TranslationManager.t("EQUIPMENT_BACKPACK"))
	if _equipment_slots_header != null:
		_equipment_slots_header.text = TranslationManager.t("EQUIPMENT_SLOTS")
	if _fragment_header_label != null:
		_fragment_header_label.text = TranslationManager.t("EQUIPMENT_FRAGMENTS")
	if _equipment_hint_label != null:
		_equipment_hint_label.text = TranslationManager.t("EQUIPMENT_HINT")
	if _player_panel_back_button != null:
		_player_panel_back_button.text = TranslationManager.t("BUTTON_BACK")

## ========== 信号回调方法 ==========

## 语言变化回调：重新更新界面文本
func _on_language_changed(_lang: String) -> void:
	_update_text()
	## 合并面板可见时同步重建两侧内容（列表文本由数据生成，非固定 key，需刷新才随语言变化）
	if _player_panel != null and _player_panel.visible:
		_refresh_status_list()
		_refresh_equipment_panel()

## 继续游戏按钮点击回调：发出继续游戏信号
func _on_resume_button_pressed() -> void:
	print("Resuming game...")
	resume_game.emit()

## 设置按钮点击回调：发出打开设置信号
func _on_settings_button_pressed() -> void:
	print("Opening settings from pause...")
	open_settings.emit()

## 返回主菜单按钮点击回调：发出返回主菜单信号
func _on_quit_button_pressed() -> void:
	print("Quitting to menu...")
	quit_to_menu.emit()

## ========== 状态与装备合并面板 ==========

## 状态与装备按钮点击回调：打开合并面板
func _on_player_panel_button_pressed() -> void:
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	_open_player_panel()

## 合并面板返回按钮点击回调：关闭合并面板，回到暂停主菜单
func _on_player_panel_back_pressed() -> void:
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	_close_player_panel()

## 导航器取消分发：合并面板打开时先返回主菜单，否则（暂停主菜单）继续游戏
func _on_navigator_cancel() -> void:
	if _player_panel != null and _player_panel.visible:
		_close_player_panel()
	else:
		_on_resume_button_pressed()

## 构建"状态 + 背包"合并面板（纯代码UI，隐藏在主菜单之后，点击状态与装备按钮时显示）
## 结构：PlayerPanel(Control) → Title + Tabs(TabContainer[页签0=状态, 页签1=背包]) + Hint + BackButton
##       页签0"状态"=核心血/属性/技能/护盾（纯文本行，整页可滚动）
##       页签1"背包"= HBox[左列(碎片 + 已装备6槽), 右列(容量 + 一键分解 + 背包列表)]，两列各自独立滚动
## 切页方式：键鼠点击页签，手柄 LT/RT（或键盘 Q/E，同映射 game_choice_prev/next）
func _build_player_panel() -> void:
	_player_panel = Control.new()
	_player_panel.name = "PlayerPanel"
	_player_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_player_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_player_panel.visible = false
	add_child(_player_panel)

	## 标题（顶部居中）
	_player_panel_title_label = Label.new()
	_player_panel_title_label.name = "PlayerPanelTitle"
	_player_panel_title_label.anchor_left = 0.0
	_player_panel_title_label.anchor_right = 1.0
	_player_panel_title_label.offset_top = 40.0
	_player_panel_title_label.offset_bottom = 90.0
	_player_panel_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_player_panel_title_label.add_theme_font_size_override("font_size", 30)
	_player_panel_title_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_player_panel_title_label.add_theme_constant_override("outline_size", 4)
	_player_panel_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_player_panel.add_child(_player_panel_title_label)

	## 双子页容器（viewport 1920x1280 下取 1240x740 居中）
	_player_tabs = TabContainer.new()
	_player_tabs.name = "PlayerTabs"
	_player_tabs.anchor_left = 0.5
	_player_tabs.anchor_right = 0.5
	_player_tabs.anchor_top = 0.5
	_player_tabs.anchor_bottom = 0.5
	_player_tabs.offset_left = -620.0
	_player_tabs.offset_right = 620.0
	_player_tabs.offset_top = -400.0
	_player_tabs.offset_bottom = 340.0
	## 必须保持可点击：键鼠玩家靠鼠标点击页签切页（设 IGNORE 会让页签点不动）
	_player_tabs.mouse_filter = Control.MOUSE_FILTER_PASS
	## 切页后必须重建导航焦点列表：隐藏页控件要移出、新页控件要收进来，
	## 否则焦点会停在看不见的控件上（手柄表现为"导航到空白处"）
	_player_tabs.tab_changed.connect(_on_player_tab_changed)
	_player_panel.add_child(_player_tabs)

	## ---------------------- 页签0：状态 ----------------------
	## 页内为纯文本行、没有任何可聚焦控件；手柄上下键由导航器降级为直接滚动本页
	var status_scroll := ScrollContainer.new()
	status_scroll.name = "StatusScroll"
	status_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_player_tabs.add_child(status_scroll)

	_status_rows = VBoxContainer.new()
	_status_rows.name = "StatusRows"
	_status_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_rows.add_theme_constant_override("separation", 8)
	status_scroll.add_child(_status_rows)

	## ---------------------- 页签1：背包（已装备 | 背包 左右分栏） ----------------------
	## 设计意图：拆成两个页签后纵向空间全部让给列表，已装备与背包改左右并排，
	##           两列各自独立滚动，可视行数约为原上下堆叠时的两倍
	var bag_page := VBoxContainer.new()
	bag_page.name = "BackpackPage"
	bag_page.add_theme_constant_override("separation", 8)
	_player_tabs.add_child(bag_page)

	var split := HBoxContainer.new()
	split.name = "BackpackSplit"
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 28)
	bag_page.add_child(split)

	## ---------- 左列：装备碎片 + 已装备 6 槽位 ----------
	var left_col := VBoxContainer.new()
	left_col.name = "EquippedColumn"
	left_col.custom_minimum_size = Vector2(430.0, 0.0)
	left_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_col.add_theme_constant_override("separation", 8)
	split.add_child(left_col)

	## 左列最上段：装备碎片（按 6 槽位展示分解累计的碎片数）
	## 设计意图：碎片是「分解装备」的产物、也是「合成装备」的消耗，与左列槽位同屏可与
	##           下方背包形成"分解 → 碎片增长"的即时反馈闭环，玩家无需再切到商店页签查看存量
	_fragment_header_label = Label.new()
	_fragment_header_label.text = TranslationManager.t("EQUIPMENT_FRAGMENTS")
	_fragment_header_label.add_theme_font_size_override("font_size", 20)
	_fragment_header_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.4))
	_fragment_header_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_fragment_header_label.add_theme_constant_override("outline_size", 3)
	left_col.add_child(_fragment_header_label)

	## 碎片数值网格：3 列 × 2 行，恰好放下 6 个槽位（顺序与 EquipmentData.Slot / SLOT_TEXTS 对齐）
	var fragment_grid := GridContainer.new()
	fragment_grid.name = "EquipmentFragmentGrid"
	fragment_grid.columns = 3
	fragment_grid.add_theme_constant_override("h_separation", 16)
	fragment_grid.add_theme_constant_override("v_separation", 6)
	left_col.add_child(fragment_grid)

	_fragment_value_labels.clear()
	for slot in range(SLOT_TEXTS.size()):
		var frag_label := Label.new()
		frag_label.add_theme_font_size_override("font_size", 15)
		frag_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
		fragment_grid.add_child(frag_label)
		_fragment_value_labels.append(frag_label)

	## 左列下段：已装备 6 槽位（独立滚动区；手柄焦点移出可视区时自动滚动跟随）
	_equipment_slots_header = Label.new()
	_equipment_slots_header.add_theme_font_size_override("font_size", 20)
	_equipment_slots_header.add_theme_color_override("font_color", Color(0.9, 0.85, 0.4))
	_equipment_slots_header.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_equipment_slots_header.add_theme_constant_override("outline_size", 3)
	left_col.add_child(_equipment_slots_header)

	var slots_scroll := ScrollContainer.new()
	slots_scroll.name = "EquipmentScroll"
	slots_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slots_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	slots_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left_col.add_child(slots_scroll)

	_equipment_slots_box = VBoxContainer.new()
	_equipment_slots_box.name = "EquipmentSlotsBox"
	_equipment_slots_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_equipment_slots_box.add_theme_constant_override("separation", 8)
	slots_scroll.add_child(_equipment_slots_box)

	## ---------- 右列：背包（容量提示 + 一键分解 + 列表） ----------
	## 设计说明：一键分解原在商店面板，操作对象却是背包内容，语义与场景都不匹配；
	##           移到背包列头部后「看背包 → 一键清理」在同一屏完成，无需再进商店
	var right_col := VBoxContainer.new()
	right_col.name = "BackpackColumn"
	right_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_col.add_theme_constant_override("separation", 8)
	split.add_child(right_col)

	var backpack_header := HBoxContainer.new()
	backpack_header.name = "EquipmentBackpackHeader"
	backpack_header.add_theme_constant_override("separation", 8)
	right_col.add_child(backpack_header)

	_equipment_capacity_label = Label.new()
	_equipment_capacity_label.add_theme_font_size_override("font_size", 20)
	_equipment_capacity_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.4))
	_equipment_capacity_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_equipment_capacity_label.add_theme_constant_override("outline_size", 3)
	_equipment_capacity_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	backpack_header.add_child(_equipment_capacity_label)

	## 一键分解按钮：普通 / 稀有各一个（带二次确认，避免误触清空背包）
	_bulk_buttons.clear()
	_bulk_rarities.clear()
	for rarity in [EquipmentData.Rarity.COMMON, EquipmentData.Rarity.RARE]:
		var bulk_btn := Button.new()
		bulk_btn.custom_minimum_size = Vector2(132.0, 34.0)
		bulk_btn.add_theme_font_size_override("font_size", 13)
		bulk_btn.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
		bulk_btn.add_theme_constant_override("outline_size", 2)
		bulk_btn.pressed.connect(_on_bulk_dismantle_pressed.bind(rarity))
		backpack_header.add_child(bulk_btn)
		_bulk_buttons.append(bulk_btn)
		_bulk_rarities.append(rarity)

	## 二次确认倒计时定时器：1 秒一跳，到期自动取消待确认状态
	_bulk_confirm_timer = Timer.new()
	_bulk_confirm_timer.name = "BulkConfirmTimer"
	_bulk_confirm_timer.wait_time = 1.0
	_bulk_confirm_timer.one_shot = false
	_bulk_confirm_timer.autostart = false
	_bulk_confirm_timer.timeout.connect(_on_bulk_confirm_tick)
	add_child(_bulk_confirm_timer)

	## 背包列表独立滚动区（手柄焦点移出可视区时自动滚动跟随）
	var bag_scroll := ScrollContainer.new()
	bag_scroll.name = "BackpackScroll"
	bag_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bag_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bag_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right_col.add_child(bag_scroll)

	_equipment_backpack_box = VBoxContainer.new()
	_equipment_backpack_box.name = "EquipmentBackpackBox"
	_equipment_backpack_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_equipment_backpack_box.add_theme_constant_override("separation", 8)
	bag_scroll.add_child(_equipment_backpack_box)

	## 底部操作提示（返回按钮上方，居中）
	_equipment_hint_label = Label.new()
	_equipment_hint_label.anchor_left = 0.0
	_equipment_hint_label.anchor_right = 1.0
	_equipment_hint_label.anchor_top = 1.0
	_equipment_hint_label.anchor_bottom = 1.0
	_equipment_hint_label.offset_top = -112.0
	_equipment_hint_label.offset_bottom = -80.0
	_equipment_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_equipment_hint_label.add_theme_font_size_override("font_size", 14)
	_equipment_hint_label.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
	_equipment_hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_player_panel.add_child(_equipment_hint_label)

	## 返回按钮（底部居中）
	_player_panel_back_button = Button.new()
	_player_panel_back_button.name = "PlayerPanelBackButton"
	_player_panel_back_button.anchor_left = 0.5
	_player_panel_back_button.anchor_right = 0.5
	_player_panel_back_button.anchor_top = 1.0
	_player_panel_back_button.anchor_bottom = 1.0
	_player_panel_back_button.offset_left = -120.0
	_player_panel_back_button.offset_right = 120.0
	_player_panel_back_button.offset_top = -70.0
	_player_panel_back_button.offset_bottom = -30.0
	_player_panel_back_button.pressed.connect(_on_player_panel_back_pressed)
	_player_panel.add_child(_player_panel_back_button)

	## 装备对比弹窗（浮层）：默认隐藏，按住对比键且聚焦背包装备、同槽位已有已装备件时显示
	## 位置：屏幕左侧竖向居中（属于临时浮层，不占用主体布局；松开对比键或焦点离开背包装备即隐藏）
	_compare_panel = PanelContainer.new()
	_compare_panel.name = "EquipmentComparePanel"
	_compare_panel.anchor_left = 0.0
	_compare_panel.anchor_right = 0.0
	_compare_panel.anchor_top = 0.5
	_compare_panel.anchor_bottom = 0.5
	_compare_panel.offset_left = 40.0
	_compare_panel.offset_right = 700.0
	_compare_panel.offset_top = -320.0
	_compare_panel.offset_bottom = 320.0
	## 鼠标穿透：弹窗只是展示层，不能抢占底层按钮的悬停/点击（否则会"挡住"装备列表）
	_compare_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_compare_panel.visible = false
	## 深底 + 金色描边 + 圆角，与暂停菜单整体风格一致
	var compare_style := StyleBoxFlat.new()
	compare_style.bg_color = Color(0.06, 0.06, 0.10, 0.94)
	compare_style.border_color = Color(0.9, 0.8, 0.4, 0.9)
	compare_style.set_border_width_all(2)
	compare_style.set_corner_radius_all(8)
	compare_style.set_content_margin_all(16)
	_compare_panel.add_theme_stylebox_override("panel", compare_style)
	_player_panel.add_child(_compare_panel)

	var compare_scroll := ScrollContainer.new()
	compare_scroll.name = "EquipmentCompareScroll"
	compare_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	compare_scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_compare_panel.add_child(compare_scroll)

	_compare_rows = VBoxContainer.new()
	_compare_rows.name = "EquipmentCompareRows"
	_compare_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_compare_rows.add_theme_constant_override("separation", 6)
	compare_scroll.add_child(_compare_rows)

## 打开合并面板：隐藏主菜单按钮、刷新状态与背包两侧内容、重建导航焦点
## 每次打开都回到"状态"页签并清空对比候选，保证每次进入的起始状态一致（不残留上次的页签/浮层）
func _open_player_panel() -> void:
	if _player_panel == null:
		return
	$VBoxContainer.visible = false
	_player_panel.visible = true
	_focused_compare_candidate = null
	_hide_equip_compare()
	if _player_tabs != null:
		_player_tabs.current_tab = 0
	_refresh_status_list()
	_refresh_equipment_panel()
	## 焦点列表刷新：隐藏的主菜单按钮不再可聚焦，仅面板内可交互控件参与导航
	if _navigator != null and _navigator.has_method("refresh_controls"):
		_navigator.refresh_controls()

## 关闭合并面板：显示主菜单按钮、重建导航焦点
func _close_player_panel() -> void:
	if _player_panel == null:
		return
	_focused_compare_candidate = null
	_hide_equip_compare()
	## 关闭面板即撤销未完成的二次确认，避免下次打开时残留"再按一次确认"状态
	_clear_bulk_confirm()
	_player_panel.visible = false
	$VBoxContainer.visible = true
	if _navigator != null and _navigator.has_method("refresh_controls"):
		_navigator.refresh_controls()

## 刷新状态列表：清空后按"核心血/属性/技能/护盾"四组逐行填充
## 装备化口径：属性组=全部已装备装备的基础属性词条；技能组=全部已装备装备携带的子弹特效
##             （原「构型」组随装备化删除，构型改由装备主动技能承载、不再单列）
func _refresh_status_list() -> void:
	if _status_rows == null:
		return
	## 清空旧行：先 remove_child 立即脱离容器（等价于 free() 的"本帧即消失"，
	## 避免旧行残留到下一帧造成重叠闪烁），再 queue_free() 延后到帧末真正释放。
	## 注意：不能直接 child.free()——若该行正处在按钮 pressed 回调中（信号发射方被 Godot 锁定），
	## free() 会报 "Object is locked and can't be freed" 并中止本函数，导致列表被清空却不重建
	for child in _status_rows.get_children():
		_status_rows.remove_child(child)
		child.queue_free()

	## 核心血组（玩家基础生存值：当前/上限）
	## 设计意图：核心血上限会被装备词条提升，但此前面板只列词条、不列结果值，
	##           玩家看不到"上限真的变大了"；补这一行让血量成长像伤害/护盾一样有具体数字
	_add_status_header(TranslationManager.t("STATUS_HEALTH"))
	_add_core_health_row()

	## 属性组（聚合全部已装备装备的基础属性词条）
	_add_status_header(TranslationManager.t("STATUS_ATTR"))
	if not _add_equipped_affix_rows():
		_add_status_empty()

	## 被动技能组（装备携带的子弹特效，随射击自动生效）
	_add_status_header(TranslationManager.t("STATUS_PASSIVE_SKILL"))
	if not _add_equipped_effect_rows():
		_add_status_empty()

	## 主动技能组（装备携带的主动技能，按键释放 + 冷却）
	_add_status_header(TranslationManager.t("STATUS_ACTIVE_SKILL"))
	if not _add_equipped_active_skill_rows():
		_add_status_empty()

	## 护盾组（当前装备护盾）
	_add_status_header(TranslationManager.t("STATUS_SHIELD"))
	_add_shield_row()

## 添加分组标题（核心血/属性/技能/护盾）
func _add_status_header(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.4))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("outline_size", 3)
	_status_rows.add_child(label)

## 添加空提示行（该分组无内容时）
func _add_status_empty() -> void:
	var label := Label.new()
	label.text = TranslationManager.t("STATUS_NONE")
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_status_rows.add_child(label)

## 获取玩家装备组件（状态列表聚合"已装备内容"的唯一数据源）
## 返回：EquipmentComponent 节点；无玩家或未初始化时 null
func _get_equipment_component() -> Node:
	var player: Node = _get_player()
	if player != null and player.has_method("get_equipment_component"):
		return player.get_equipment_component()
	return null

## 添加"全部已装备装备的基础属性词条"累计行
## 数据流：EquipmentComponent.get_all_equipped() → 各 EquipmentData.affixes →
##         按 stat_key 合并求和 → 每个属性仅一行累计值（不再按装备拆分、不显示来源装备名）
## 设计意图：玩家关心的是"我当前的总加成是多少"，而非"这加成来自哪件装备"；
##          同属性分散成多行既占空间又难比较，故此处做聚合展示（对应"只显示叠加累计的效果"）
## 返回：true=至少添加了一行（供调用方决定是否显示空提示）
func _add_equipped_affix_rows() -> bool:
	var comp: Node = _get_equipment_component()
	if comp == null or not comp.has_method("get_all_equipped"):
		return false

	## 第一步：遍历全部已装备装备，按 stat_key 累加数值，
	##        同时记录该键的图标/稀有度颜色（图标取提供该键装备中稀有度最高者）
	var totals: Dictionary = {}
	var icon_texts: Dictionary = {}
	var rarity_ranks: Dictionary = {}
	for data in comp.get_all_equipped():
		if data == null:
			continue
		var rarity: int = int(data.rarity)
		var icon_tex: Texture2D = IconLibraryLib.get_equipment_icon(data)
		for affix: EquipmentAffix in data.affixes:
			if affix == null or affix.stat_key.is_empty():
				continue
			var key: String = affix.stat_key
			totals[key] = float(totals.get(key, 0.0)) + affix.value
			## 图标/颜色跟随"最高稀有度"的贡献装备，让强势装备的词条更醒目
			if not rarity_ranks.has(key) or rarity > int(rarity_ranks[key]):
				rarity_ranks[key] = rarity
				icon_texts[key] = icon_tex

	## 第二步：每个属性键输出一行累计效果（需求：不显示词条名称，只显示效果）
	var added: bool = false
	for key in totals.keys():
		var stat_key: String = String(key)
		var color: Color = Color(0.9, 0.9, 0.9)
		match int(rarity_ranks.get(stat_key, 0)):
			1:
				color = Color(0.4, 0.7, 1.0)
			2:
				color = Color(0.8, 0.4, 1.0)
		_add_status_row(icon_texts.get(stat_key), color, "",
			"", _describe_stat(stat_key, float(totals[stat_key])))
		added = true
	return added

## 添加"全部已装备装备携带的被动技能（子弹特效）"行
## 数据流：EquipmentComponent.get_all_equipped() → 各 EquipmentData.bullet_effects → 逐条成行
## 返回：true=至少添加了一行（供调用方决定是否显示空提示）
func _add_equipped_effect_rows() -> bool:
	var comp: Node = _get_equipment_component()
	if comp == null or not comp.has_method("get_all_equipped"):
		return false
	var added: bool = false
	for data in comp.get_all_equipped():
		if data == null:
			continue
		for effect in data.bullet_effects:
			if effect == null:
				continue
			## 特效无独立图标：沿用所属装备图标
			## 需求：不显示技能名称，只显示效果——由特效自身把已叠层放大的参数翻译成效果说明
			var effect_desc: String = effect.get_effect_description() if effect.has_method("get_effect_description") else ""
			_add_status_row(IconLibraryLib.get_equipment_icon(data), data.get_rarity_color(),
				"", "", effect_desc)
			added = true
	return added

## 添加"全部已装备装备携带的主动技能"行
## 数据流：EquipmentComponent.get_all_equipped() → 各 EquipmentData.active_skill → 按 skill_id 去重成行
## 展示：所属槽位 + 冷却时长（需求：不显示技能名称，只显示效果；运行时冷却倒计时由主界面 HUD 技能栏承担）
## 返回：true=至少添加了一行（供调用方决定是否显示空提示）
func _add_equipped_active_skill_rows() -> bool:
	var comp: Node = _get_equipment_component()
	if comp == null or not comp.has_method("get_all_equipped"):
		return false
	## 按 skill_id 去重（与 EquipmentComponent._refresh_active_skill 口径一致），
	## 避免同一主动技能因 skill_id 相同时被重复列出
	var seen: Dictionary = {}
	var added: bool = false
	for data in comp.get_all_equipped():
		if data == null or not data.has_method("has_active_skill") or not data.has_active_skill():
			continue
		var skill: Resource = data.active_skill
		var sid: String = str(skill.skill_id) if "skill_id" in skill else ""
		## skill_id 为空时用实例 id 兜底去重
		var dedupe_key: String = sid if sid != "" else str(skill.get_instance_id())
		if seen.has(dedupe_key):
			continue
		seen[dedupe_key] = true
		## 需求：不显示技能名称，仅保留"所属槽位 + 冷却时长"作为效果信息
		## 补充整轮伤害倍率：主动技能的核心强度来源，玩家需要能看到它才判断得出强弱
		var cd: float = float(skill.cooldown) if "cooldown" in skill else 0.0
		var dmg_mult: float = float(skill.damage_multiplier) if "damage_multiplier" in skill else 1.0
		var slot_text: String = data.get_slot_text() if data.has_method("get_slot_text") else ""
		_add_status_row(IconLibraryLib.get_equipment_icon(data), data.get_rarity_color(),
			"", slot_text, "CD %.1fs，伤害×%.1f" % [cd, dmg_mult])
		added = true
	return added

## 添加核心血行（显示玩家核心血"当前/上限"，数据源 Player.get_survival_state()）
## 说明：核心血是混合生命系统的最后一层（前两层为装备护盾、分段护盾），
##       本行只反映结果值，不参与任何数值计算；描述位留空（血量红血警示已由 HUD 血条承担）
func _add_core_health_row() -> void:
	var state: Dictionary = {}
	var players: Array = get_tree().get_nodes_in_group("player")
	if players.size() > 0 and players[0].has_method("get_survival_state"):
		state = players[0].get_survival_state()

	## 玩家不存在或控制器缺失：与护盾/构型一致走空提示，不报错
	if state.is_empty():
		_add_status_empty()
		return

	var core_hp: int = int(round(float(state.get("core", 0.0))))
	var max_core: int = int(round(float(state.get("max_core", 0.0))))
	## 图标复用血量上限词条图（白色普通目录的 icon_upg_max_hp）；色块取血量条同款红
	var icon_tex: Texture2D = IconLibraryLib.get_upgrade_icon("upg_max_hp", 0)
	_add_status_row(icon_tex, Color(1.0, 0.4, 0.4), TranslationManager.t("STATUS_HEALTH"),
		"%d/%d" % [core_hp, max_core], "")

## 添加护盾行（未装备时显示空提示）
func _add_shield_row() -> void:
	var data: Resource = null
	var stack: int = 1
	var players: Array = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		var shield_comp: Node = players[0].get_node_or_null("EquipmentShieldComponent")
		if shield_comp != null and shield_comp.has_method("get_shield_data"):
			data = shield_comp.get_shield_data()
			if data != null and shield_comp.has_method("get_shield_stack"):
				stack = shield_comp.get_shield_stack()

	if data == null:
		_add_status_empty()
		return

	var shield_id: String = str(data.shield_id) if "shield_id" in data else ""
	var shield_color: Color = data.shield_color if "shield_color" in data else Color(0.3, 0.6, 1.0)
	var icon_tex: Texture2D = IconLibraryLib.get_shield_icon(shield_id)
	var shield_name: String = str(data.display_name) if "display_name" in data else "护盾"
	var is_special: bool = bool(data.is_special) if "is_special" in data else false
	## 护盾无描述字段，按配置动态生成说明（耐久/单次吸收随叠层放大）
	var desc: String = "耐久 %d · 单次吸收 %d" % [
		int(float(data.max_hp) * float(stack)),
		int(float(data.absorb_per_hit) * float(stack)),
	]
	if is_special:
		desc += " · 特效护盾"
	_add_status_row(icon_tex, shield_color, shield_name, "×%d" % stack, desc)

## 添加一行（图标 + 名称[等级] 效果），用PanelContainer做底框增强可读性
## 说明：item_name 为空 = "只显示效果"行（属性/被动技能/主动技能组），此时省略名称位
func _add_status_row(icon_tex: Texture2D, color: Color, item_name: String, level_text: String, desc: String) -> void:
	var shell := PanelContainer.new()
	shell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.1, 0.6)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	shell.add_theme_stylebox_override("panel", style)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	shell.add_child(hbox)

	hbox.add_child(_make_status_icon(icon_tex, color))

	var label := Label.new()
	## 拼接文本：名称为空时省略名称位（"只显示效果"行）；等级位为空时省略方括号
	if item_name.is_empty():
		label.text = desc if level_text.is_empty() else "[%s]  %s" % [level_text, desc]
	elif level_text.is_empty():
		label.text = "%s  %s" % [item_name, desc]
	else:
		label.text = "%s  [%s]  %s" % [item_name, level_text, desc]
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	label.add_theme_constant_override("outline_size", 2)
	hbox.add_child(label)

	_status_rows.add_child(shell)

## 创建28px图标（有贴图用TextureRect，无贴图回退稀有度/护盾色块）
func _make_status_icon(icon_tex: Texture2D, color: Color) -> Control:
	var panel := Panel.new()
	panel.custom_minimum_size = Vector2(28, 28)
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = 3
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 3
	style.corner_radius_bottom_right = 3
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.border_color = Color(1, 1, 1, 0.4)
	panel.add_theme_stylebox_override("panel", style)

	if icon_tex != null:
		var rect := TextureRect.new()
		rect.texture = icon_tex
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		rect.offset_left = 2
		rect.offset_top = 2
		rect.offset_right = -2
		rect.offset_bottom = -2
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(rect)
	return panel

## ========== 装备/背包：槽位与背包操作 ==========

## 已装备槽位按钮点击回调：把该槽位装备卸下并放回背包
## 参数：slot - 槽位（EquipmentData.Slot）
## 说明：背包已满时卸下会被 BackpackComponent 拒绝（避免装备丢失），刷新后界面保持不变
func _on_equip_slot_pressed(slot: int) -> void:
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	var player: Node = _get_player()
	if player != null and player.has_method("unequip_equipment_slot"):
		player.unequip_equipment_slot(slot)
	_refresh_equipment_panel()
	## 左栏"状态"随装备变化（词条/特效/护盾均来自已装备），需一并重建
	_refresh_status_list()
	## 列表重建后按钮对象已换新，需让导航器重新收集可聚焦控件
	if _navigator != null and _navigator.has_method("refresh_controls"):
		_navigator.refresh_controls()

## 背包物品按钮点击回调：穿戴该件装备（同槽位原装备自动回退背包）
## 参数：index - 背包物品下标（0-based，构建按钮时捕获；每次操作后立即重建列表故不会错位）
func _on_backpack_item_pressed(index: int) -> void:
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	var player: Node = _get_player()
	if player != null and player.has_method("equip_equipment_from_backpack"):
		player.equip_equipment_from_backpack(index)
	_refresh_equipment_panel()
	## 左栏"状态"随装备变化（词条/特效/护盾均来自已装备），需一并重建
	_refresh_status_list()
	if _navigator != null and _navigator.has_method("refresh_controls"):
		_navigator.refresh_controls()

## 背包"分解"按钮点击回调：分解该件装备（产出梦境碎片 + 同槽位装备碎片）
## 参数：index - 背包物品下标（0-based，构建按钮时捕获）
func _on_backpack_dismantle_pressed(index: int) -> void:
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	var player: Node = _get_player()
	if player != null and player.has_method("get_backpack"):
		var backpack: Node = player.get_backpack()
		if backpack != null and backpack.has_method("dismantle_at"):
			backpack.dismantle_at(index)
	## 分解只影响背包，不影响已装备 → 仅重建装备面板，不刷新状态栏
	_refresh_equipment_panel()
	if _navigator != null and _navigator.has_method("refresh_controls"):
		_navigator.refresh_controls()

## 背包"丢弃"按钮点击回调：直接丢弃该件装备（无任何产出）
## 参数：index - 背包物品下标（0-based）
func _on_backpack_drop_pressed(index: int) -> void:
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	var player: Node = _get_player()
	if player != null and player.has_method("get_backpack"):
		var backpack: Node = player.get_backpack()
		if backpack != null and backpack.has_method("drop_at"):
			backpack.drop_at(index)
	_refresh_equipment_panel()
	if _navigator != null and _navigator.has_method("refresh_controls"):
		_navigator.refresh_controls()

## ========== 装备碎片展示（右栏顶部，随背包/分解实时刷新） ==========

## 刷新装备碎片数值：读取 Player 各槽位已累计的碎片数
## 数据源：Player.get_equipment_fragment(slot)（索引与 EquipmentData.Slot / SLOT_TEXTS 对齐）
func _refresh_fragment_row() -> void:
	if _fragment_value_labels.is_empty():
		return
	var player: Node = _get_player()
	for slot in range(_fragment_value_labels.size()):
		var amount: int = 0
		if player != null and player.has_method("get_equipment_fragment"):
			amount = int(player.get_equipment_fragment(slot))
		var slot_name: String = SLOT_TEXTS[slot] if slot < SLOT_TEXTS.size() else "?"
		_fragment_value_labels[slot].text = "%s %d" % [slot_name, amount]

## ========== 一键分解（背包头部行，带二次确认门槛） ==========

## 一键分解按钮点击回调：首次按下进入待确认，倒计时内再按一次才真正执行
## 参数：rarity - 目标稀有度（EquipmentData.Rarity）
func _on_bulk_dismantle_pressed(rarity: int) -> void:
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	## 二次确认：目标与当前待确认不一致时只"武装"确认态，不执行
	if _bulk_confirm_pending != rarity:
		_arm_bulk_confirm(rarity)
		return
	_clear_bulk_confirm()
	_execute_bulk_dismantle(rarity)

## 进入二次确认状态：记录目标稀有度并启动倒计时
func _arm_bulk_confirm(rarity: int) -> void:
	_bulk_confirm_pending = rarity
	_bulk_confirm_left = BULK_CONFIRM_TIME
	if _bulk_confirm_timer != null:
		_bulk_confirm_timer.start()
	_update_bulk_buttons()

## 倒计时每秒一跳：递减剩余秒数，归零则自动取消待确认
func _on_bulk_confirm_tick() -> void:
	if _bulk_confirm_pending < 0:
		return
	_bulk_confirm_left -= 1
	if _bulk_confirm_left <= 0:
		_clear_bulk_confirm()
	else:
		_update_bulk_buttons()

## 取消待确认状态（停止计时并还原按钮文案/可用状态）
func _clear_bulk_confirm() -> void:
	if _bulk_confirm_timer != null:
		_bulk_confirm_timer.stop()
	_bulk_confirm_pending = -1
	_bulk_confirm_left = 0
	_update_bulk_buttons()

## 执行批量分解：委托背包组件按稀有度分解（回收规则与单件"分解"按钮完全一致）
## 参数：rarity - 目标稀有度
func _execute_bulk_dismantle(rarity: int) -> void:
	var player: Node = _get_player()
	if player == null or not player.has_method("get_backpack"):
		return
	var backpack: Node = player.get_backpack()
	if backpack == null or not backpack.has_method("dismantle_by_rarity"):
		return
	var summary: Dictionary = backpack.dismantle_by_rarity(rarity)
	if int(summary.get("count", 0)) <= 0:
		return
	if AudioManager:
		AudioManager.play("upgrade_pick", 0.9)
	## 批量分解只影响背包与碎片存量、不动已装备 → 仅重建装备面板，无需刷新状态栏
	_refresh_equipment_panel()
	if _navigator != null and _navigator.has_method("refresh_controls"):
		_navigator.refresh_controls()

## 刷新一键分解按钮：文案带可分解件数、无可分解件时置灰；待确认时切换为确认提示
func _update_bulk_buttons() -> void:
	if _bulk_buttons.is_empty():
		return
	var backpack: Node = null
	var player: Node = _get_player()
	if player != null and player.has_method("get_backpack"):
		backpack = player.get_backpack()
	for i in range(_bulk_buttons.size()):
		var rarity: int = _bulk_rarities[i]
		var btn: Button = _bulk_buttons[i]
		## 待确认态：显示"再按一次确认 (剩余秒数)"，保持可点击
		if _bulk_confirm_pending == rarity and _bulk_confirm_left > 0:
			btn.text = TranslationManager.t("EQUIPMENT_BULK_CONFIRM") % _bulk_confirm_left
			btn.disabled = false
			continue
		var count: int = 0
		if backpack != null and backpack.has_method("count_by_rarity"):
			count = int(backpack.count_by_rarity(rarity))
		var key: String = "EQUIPMENT_BULK_COMMON" if rarity == EquipmentData.Rarity.COMMON else "EQUIPMENT_BULK_RARE"
		btn.text = "%s (%d)" % [TranslationManager.t(key), count]
		btn.disabled = count <= 0

## 获取玩家节点（装备/背包面板的数据源入口）
## 返回：玩家节点；场景中不存在时返回 null（面板显示空内容而不报错）
func _get_player() -> Node:
	var players: Array = get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		return players[0]
	return null

## 刷新装备/背包区：重建 6 个槽位按钮与背包列表按钮
## 数据源：Player.get_equipment_component()（已装备） / Player.get_backpack()（背包）
func _refresh_equipment_panel() -> void:
	if _equipment_slots_box == null or _equipment_backpack_box == null:
		return
	## 列表即将重建，原聚焦的按钮会被销毁 → 先清空对比候选并收起弹窗，避免残留旧（已释放）装备引用
	_focused_compare_candidate = null
	_hide_equip_compare()
	## 清空旧内容：先 remove_child 立即脱离容器（本帧即消失，避免新旧重叠），再 queue_free() 帧末释放。
	## 关键：穿戴/卸下是由被点击的那个按钮自己 emit 的 pressed 触发的，此时该按钮被 Godot 锁定，
	## 对它调用 free() 会报 "Object is locked and can't be freed" 并中止本函数 → 列表被清空却不重建，
	## 表现为"装备/卸下后整个列表消失，必须退出再进面板才恢复"。故必须用 remove_child + queue_free
	for child in _equipment_slots_box.get_children():
		_equipment_slots_box.remove_child(child)
		child.queue_free()
	for child in _equipment_backpack_box.get_children():
		_equipment_backpack_box.remove_child(child)
		child.queue_free()

	var equipment: Node = null
	var backpack: Node = null
	var player: Node = _get_player()
	if player != null:
		if player.has_method("get_equipment_component"):
			equipment = player.get_equipment_component()
		if player.has_method("get_backpack"):
			backpack = player.get_backpack()

	## 左栏：6 个槽位（已装备可点击卸下；空槽禁用，不参与导航）
	for slot in range(SLOT_TEXTS.size()):
		var data: EquipmentData = null
		if equipment != null:
			data = equipment.get_equipped(slot)
		var btn: Button = _make_equipment_button(_build_slot_button_text(slot, data), data)
		btn.disabled = data == null
		btn.pressed.connect(_on_equip_slot_pressed.bind(slot))
		## 聚焦已装备槽位：收起对比弹窗（对比只在"背包装备 vs 已装备"时有意义）
		btn.focus_entered.connect(_on_equipment_button_focused.bind(data, false))
		btn.mouse_entered.connect(_on_equipment_button_focused.bind(data, false))
		_equipment_slots_box.add_child(btn)

	## 右栏：背包装备（点击穿戴）
	var count: int = 0
	var cap: int = 0
	if backpack != null:
		var items: Array = backpack.get_items()
		count = items.size()
		cap = int(backpack.capacity)
		for i in range(items.size()):
			var item: EquipmentData = items[i]
			if item == null:
				continue
			## 每件背包装备占一行：主按钮（点击穿戴）+ 分解按钮 + 丢弃按钮
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 4)

			var bag_btn: Button = _make_equipment_button(_build_backpack_button_text(item), item)
			bag_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			bag_btn.pressed.connect(_on_backpack_item_pressed.bind(i))
			## 聚焦/悬停背包装备：若同槽位已有已装备件则弹出对比弹窗
			bag_btn.focus_entered.connect(_on_equipment_button_focused.bind(item, true))
			bag_btn.mouse_entered.connect(_on_equipment_button_focused.bind(item, true))
			row.add_child(bag_btn)

			## 分解按钮：产出梦境碎片 + 同槽位装备碎片
			var dismantle_btn: Button = _make_row_action_button(TranslationManager.t("EQUIPMENT_DISMANTLE"))
			dismantle_btn.pressed.connect(_on_backpack_dismantle_pressed.bind(i))
			row.add_child(dismantle_btn)

			## 丢弃按钮：直接消失、无产出
			var drop_btn: Button = _make_row_action_button(TranslationManager.t("EQUIPMENT_DROP"))
			drop_btn.pressed.connect(_on_backpack_drop_pressed.bind(i))
			row.add_child(drop_btn)

			_equipment_backpack_box.add_child(row)
	if count == 0:
		_equipment_backpack_box.add_child(_make_equipment_plain_label(TranslationManager.t("EQUIPMENT_EMPTY")))

	## 容量提示（满时追加警告，提示"卸下会被拒绝"的原因）
	if _equipment_capacity_label != null:
		var cap_text: String = "%s (%d/%d)" % [TranslationManager.t("EQUIPMENT_BACKPACK"), count, cap]
		if backpack != null and backpack.is_full():
			cap_text += "  ·  " + TranslationManager.t("EQUIPMENT_FULL")
		_equipment_capacity_label.text = cap_text

	## 碎片存量展示 + 一键分解按钮（件数/可用状态）需随背包内容变化同步刷新
	_refresh_fragment_row()
	_update_bulk_buttons()

## 创建一个装备条目按钮（左侧图标 + 左对齐多行文本；有装备时按稀有度着色）
## 参数：text - 多行按钮文本；data - 对应装备（为 null 表示空槽，不配图标/配色）
func _make_equipment_button(text: String, data: EquipmentData) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.custom_minimum_size = Vector2(0.0, 72.0)
	btn.add_theme_font_size_override("font_size", 15)
	btn.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	btn.add_theme_constant_override("outline_size", 2)
	if data != null:
		btn.icon = IconLibraryLib.get_equipment_icon(data)
		## 注意：icon_max_width 在 Godot 4 中是 Button 的「主题常量」而非属性，
		## 必须用 add_theme_constant_override 设置；直接 btn.icon_max_width = 48 会抛运行时报错，
		## 导致本函数中止返回 null，进而使背包/已装备条目按钮全部创建失败（面板空白）
		btn.add_theme_constant_override("icon_max_width", 48)
		## 稀有度着色必须覆盖「全部状态色」：Button 的 font_color 只作用于普通态，
		## 悬停/聚焦/按下态分别走主题默认的 font_hover_color / font_focus_color /
		## font_pressed_color / font_hover_pressed_color（Godot 默认主题为近白色）。
		## 若只设 font_color，按钮一旦被导航器聚焦（打开面板即聚焦首个可聚焦控件）或鼠标悬停，
		## 文字就会由稀有度色变成白色——这正是「背包装备有色、已装备槽位却显示为白色」的原因
		var rarity_color: Color = data.get_rarity_color()
		btn.add_theme_color_override("font_color", rarity_color)
		btn.add_theme_color_override("font_hover_color", rarity_color)
		btn.add_theme_color_override("font_pressed_color", rarity_color)
		btn.add_theme_color_override("font_focus_color", rarity_color)
		btn.add_theme_color_override("font_hover_pressed_color", rarity_color)
	return btn

## 创建一个面板内的普通文本标签（空提示等）
func _make_equipment_plain_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	return label

## 创建背包行内的小操作按钮（分解 / 丢弃）
## 参数：text - 按钮文字
func _make_row_action_button(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(56.0, 56.0)
	btn.add_theme_font_size_override("font_size", 13)
	btn.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	btn.add_theme_constant_override("outline_size", 2)
	return btn

## 拼接"已装备槽位"按钮文本（多行：槽位名 + 装备名[稀有度] / 词条 / 特效 / 护盾 / 主动技）
## 参数：slot - 槽位；data - 该槽位装备（null 表示空槽）
func _build_slot_button_text(slot: int, data: EquipmentData) -> String:
	var slot_name: String = SLOT_TEXTS[slot] if slot >= 0 and slot < SLOT_TEXTS.size() else "?"
	if data == null:
		return "%s · %s" % [slot_name, TranslationManager.t("EQUIPMENT_EMPTY")]

	var lines: Array[String] = []
	lines.append("%s · %s  [%s]" % [slot_name, data.display_name, data.get_rarity_text()])
	_append_equipment_detail_lines(lines, data)
	return "\n".join(PackedStringArray(lines))

## 追加装备内容明细行（属性词条 / 特效词条 / 护盾 / 主动技能），供槽位按钮与背包按钮共用
## 设计意图：背包不再显示"属性×N / 特效×N"这类数量简报，而是像已装备槽位一样逐条列出实际词条
func _append_equipment_detail_lines(lines: Array[String], data: EquipmentData) -> void:
	if data == null:
		return
	## 基础属性词条（每条一行，展示键名+数值）
	for affix: EquipmentAffix in data.affixes:
		if affix != null:
			lines.append("  " + affix.get_display_text())
	## 子弹特效（显示名 + 层数）
	for effect: BulletEffect in data.bullet_effects:
		if effect == null:
			continue
		var eff_name: String = effect.display_name if effect.display_name != "" else effect.effect_id
		var eff_line: String = "  %s：%s" % [TranslationManager.t("EQUIPMENT_EFFECT"), eff_name]
		if effect.stack_count > 1:
			eff_line += " Lv.%d" % effect.stack_count
		lines.append(eff_line)
	## 护盾蓝图（仅盾牌槽携带）
	if data.shield_data != null:
		lines.append("  %s：%d / %d" % [
			TranslationManager.t("EQUIPMENT_SHIELD_LABEL"),
			int(data.shield_data.max_hp),
			int(data.shield_data.absorb_per_hit),
		])
	## 主动技能（名称 + 冷却 + 整轮伤害倍率）
	if data.has_active_skill():
		lines.append("  %s：%s (CD %.1fs，伤害×%.1f)" % [
			TranslationManager.t("EQUIPMENT_ACTIVE"),
			data.active_skill.display_name,
			float(data.active_skill.cooldown),
			float(data.active_skill.damage_multiplier),
		])

## 拼接"背包物品"按钮文本（装备名[稀有度] + 逐条词条明细）
## 参数：data - 背包装备实例
func _build_backpack_button_text(data: EquipmentData) -> String:
	if data == null:
		return TranslationManager.t("EQUIPMENT_EMPTY")

	var lines: Array[String] = []
	lines.append("%s  [%s]" % [data.display_name, data.get_rarity_text()])
	## 直接逐条展示属性词条、特效词条、护盾、主动技（不再用"属性×N/特效×N"简报）
	_append_equipment_detail_lines(lines, data)
	return "\n".join(PackedStringArray(lines))

## ========== 装备对比弹窗：展示"背包装备 vs 同槽位已装备件"的差异 ==========

## 装备条目获得焦点/鼠标悬停回调：只记录"对比候选"，不直接弹窗
## 参数：data - 该条目对应的装备（可能为 null，如空槽）；from_backpack - true=背包条目
## 设计意图：需求要求"按住对比键才显示"，故此处仅登记候选件；
##           弹窗的显隐由 _update_compare_hold() 按按住状态统一驱动
##           聚焦已装备槽位（from_backpack=false）或空槽 → 无对比意义，清空候选并收起弹窗
func _on_equipment_button_focused(data: EquipmentData, from_backpack: bool) -> void:
	if not from_backpack or data == null:
		_focused_compare_candidate = null
		_hide_equip_compare()
		return
	_focused_compare_candidate = data
	## 候选已变：若此刻正按住对比键，立即重建内容（否则等松开再按才刷新，手感滞后）
	if _compare_panel != null and _compare_panel.visible:
		_hide_equip_compare()

## 收起对比弹窗（不清内容，下次显示时整体重建；弹窗隐藏后不占用视觉）
func _hide_equip_compare() -> void:
	## 同步复位"已展示候选"，否则下次按住对比键时会因候选相同而误判为"内容没变"、不重建
	_compare_shown_candidate = null
	if _compare_panel != null:
		_compare_panel.visible = false

## 显示对比弹窗：把背包装备与"其槽位当前已装备件"逐维度对比
## 参数：candidate - 玩家聚焦/悬停的背包装备（待装候选）
## 说明：该槽位无已装备件时不做对比（按需求"如果存在已装备的"才弹窗），直接收起
func _show_equip_compare(candidate: EquipmentData) -> void:
	if _compare_panel == null or _compare_rows == null or candidate == null:
		return
	var equipped: EquipmentData = _get_equipped_for_slot(candidate.slot)
	if equipped == null:
		_hide_equip_compare()
		return

	## 清空旧内容（同样用 remove_child + queue_free，规避信号期释放限制）
	for child in _compare_rows.get_children():
		_compare_rows.remove_child(child)
		child.queue_free()

	## 标题：槽位 · 装备对比
	_add_compare_text("%s · %s" % [
		candidate.get_slot_text(),
		TranslationManager.t("EQUIPMENT_COMPARE"),
	], 18, Color(0.9, 0.85, 0.4))

	## 两侧名称行（各自按稀有度着色，一眼分辨品质）
	_add_compare_text("%s：%s" % [
		TranslationManager.t("EQUIPMENT_COMPARE_CURRENT"),
		equipped.display_name,
	], 16, equipped.get_rarity_color())
	_add_compare_text("%s：%s" % [
		TranslationManager.t("EQUIPMENT_COMPARE_CANDIDATE"),
		candidate.display_name,
	], 16, candidate.get_rarity_color())

	## 基础属性段（词条按 stat_key 取并集，逐键显示 旧 → 新 与差值）
	_add_compare_text(TranslationManager.t("STATUS_ATTR"), 16, Color(0.9, 0.85, 0.4))
	var has_diff: bool = _add_affix_diff_rows(equipped, candidate)

	## 特效段（两边特效名清单，按数量差着色）
	_add_compare_text(TranslationManager.t("STATUS_SKILL"), 16, Color(0.9, 0.85, 0.4))
	if _add_effect_diff_rows(equipped, candidate):
		has_diff = true

	## 护盾行（任一侧携带护盾蓝图时显示，按最大耐久差着色）
	if (equipped.shield_data != null) or (candidate.shield_data != null):
		var old_hp: float = equipped.shield_data.max_hp if equipped.shield_data != null else 0.0
		var new_hp: float = candidate.shield_data.max_hp if candidate.shield_data != null else 0.0
		_add_compare_text("%s：%s → %s" % [
			TranslationManager.t("EQUIPMENT_SHIELD_LABEL"),
			_shield_text(equipped),
			_shield_text(candidate),
		], 14, _diff_color(new_hp - old_hp))
		has_diff = true

	## 主动技能行（按 skill_id 逐条对比：新增=绿 / 被替换=红 / 同名=白）
	if _add_active_skill_diff_rows(equipped, candidate):
		has_diff = true

	## 全维度无差异时给一句"暂无"，避免弹窗里只有标题和名字
	if not has_diff:
		_add_compare_text(TranslationManager.t("STATUS_NONE"), 14, Color(0.7, 0.7, 0.7))

	_compare_panel.visible = true
	## 记录"本帧展示的候选件"：_update_compare_hold() 借此判断内容是否已同步，避免每帧清空重建
	_compare_shown_candidate = candidate

## 取指定槽位当前已装备件
## 参数：slot - 槽位（EquipmentData.Slot）
## 返回：已装备的 EquipmentData；该槽位为空/玩家不可用时返回 null
func _get_equipped_for_slot(slot: int) -> EquipmentData:
	var player: Node = _get_player()
	if player != null and player.has_method("get_equipment_component"):
		var equipment: Node = player.get_equipment_component()
		if equipment != null and equipment.has_method("get_equipped"):
			return equipment.get_equipped(slot)
	return null

## 向对比弹窗追加一行文本（自动换行、黑描边、鼠标穿透）
func _add_compare_text(text: String, font_size: int, color: Color) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("outline_size", 2)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_compare_rows.add_child(label)

## 追加"基础属性"对比行：两件装备的词条按 stat_key 取并集，逐键显示 旧 → 新（差值）
## 返回：true=至少输出了一行差异（无词条时为 false）
func _add_affix_diff_rows(equipped: EquipmentData, candidate: EquipmentData) -> bool:
	var equipped_totals: Dictionary = equipped.get_affix_totals()
	var candidate_totals: Dictionary = candidate.get_affix_totals()
	## 键集合：先列"当前已装备"的键，再补"待装"独有的键（阅读顺序更自然）
	var keys: Array[String] = []
	for key in equipped_totals.keys():
		keys.append(String(key))
	for key in candidate_totals.keys():
		var k: String = String(key)
		if not keys.has(k):
			keys.append(k)
	if keys.is_empty():
		return false

	for key: String in keys:
		var old_value: float = float(equipped_totals.get(key, 0.0))
		var new_value: float = float(candidate_totals.get(key, 0.0))
		## 先各自按"显示精度"四舍五入成整数显示单位（百分比键 → 整数个百分点；固定加值键 → 十分位），
		## 再用"取精后的新值 − 取精后的旧值"作为差值，保证弹窗里
		## 「显示差值 == 显示新值 − 显示旧值」；全程在整数口径下相减可彻底消除浮点误差，
		## 若对原始浮点差值单独取整，会因两侧取整方向不同而出现 "8% → 9% 却显示 (+2%)" 这类 ±1 误差
		var old_units: int = _stat_display_units(key, old_value)
		var new_units: int = _stat_display_units(key, new_value)
		var diff_units: int = new_units - old_units
		_add_compare_text("%s  %s → %s  (%s)" % [
			_affix_display_name(equipped, candidate, key),
			_fmt_stat_units(key, old_units) + _stat_unit(key),
			_fmt_stat_units(key, new_units) + _stat_unit(key),
			_fmt_stat_units(key, diff_units) + _stat_unit(key),
		], 14, _diff_color(float(diff_units)))
	return true

## 追加"特效(被动技能)"对比行：按 effect_id 逐条对比
## 返回：true=至少输出一行（两侧都无特效时为 false）
func _add_effect_diff_rows(equipped: EquipmentData, candidate: EquipmentData) -> bool:
	return _add_id_diff_rows(
		_effect_map(equipped), _effect_map(candidate), TranslationManager.t("EQUIPMENT_EFFECT"))

## 追加"主动技能"对比行：按 skill_id 逐条对比（单技能装备也走同一套并集逻辑）
## 返回：true=至少输出一行（两侧都无主动技时为 false）
func _add_active_skill_diff_rows(equipped: EquipmentData, candidate: EquipmentData) -> bool:
	return _add_id_diff_rows(
		_active_skill_map(equipped), _active_skill_map(candidate), TranslationManager.t("EQUIPMENT_ACTIVE"))

## 通用"逐条对比"：把两侧 {id: 展示文本} 取并集，逐条输出 旧 → 新
## 着色规则（对应需求"技能也按红绿区分增减，效果一致则白"）：
##   待装新增=绿；当前有而待装无（被替换掉）=红；两侧同名=白
## 参数：current_map/candidate_map - 当前已装备/待装的 {id: 文本}；label - 行首标签（如"特效""主动技能"）
## 返回：true=至少输出一行
func _add_id_diff_rows(current_map: Dictionary, candidate_map: Dictionary, label: String) -> bool:
	if current_map.is_empty() and candidate_map.is_empty():
		return false

	## 键集合：先列"当前已装备"的键，再补"待装"独有的键（阅读顺序更自然）
	var ids: Array[String] = []
	for id in current_map.keys():
		ids.append(String(id))
	for id in candidate_map.keys():
		var k: String = String(id)
		if not ids.has(k):
			ids.append(k)

	for id: String in ids:
		var has_current: bool = current_map.has(id)
		var has_candidate: bool = candidate_map.has(id)
		var color: Color = Color(0.7, 0.7, 0.7)
		if has_candidate and not has_current:
			## 待装多出的条目：新增 → 绿色
			color = Color(0.4, 1.0, 0.5)
		elif has_current and not has_candidate:
			## 当前有而待装没有：被替换掉 → 红色
			color = Color(1.0, 0.45, 0.45)
		## 两侧同名：只显示白色（含层数差异，同名前后的层数变化由文本本身体现）
		var current_text: String = String(current_map[id]) if has_current else TranslationManager.t("STATUS_NONE")
		var candidate_text: String = String(candidate_map[id]) if has_candidate else TranslationManager.t("STATUS_NONE")
		_add_compare_text("%s  %s → %s" % [label, current_text, candidate_text], 14, color)
	return true

## 提取"effect_id → 展示文本(特效名 + 层数标记)"映射（供逐条对比使用）
## 参数：data - 装备（可为 null）
## 返回：字典；无特效时为空字典
func _effect_map(data: EquipmentData) -> Dictionary:
	var out: Dictionary = {}
	if data == null:
		return out
	for effect: BulletEffect in data.bullet_effects:
		if effect == null:
			continue
		var eid: String = String(effect.effect_id)
		var name: String = effect.display_name if effect.display_name != "" else eid
		if effect.stack_count > 1:
			name += " Lv.%d" % effect.stack_count
		out[eid] = name
	return out

## 取某属性键在两件装备上的显示名（优先取待装侧的名称，便于玩家对应新装备词条）
## 参数：equipped - 当前已装备；candidate - 待装装备；key - 属性键
## 返回：词条显示名；两侧都查不到时回退为键名本身
func _affix_display_name(equipped: EquipmentData, candidate: EquipmentData, key: String) -> String:
	for data: EquipmentData in [candidate, equipped]:
		if data == null:
			continue
		for affix: EquipmentAffix in data.affixes:
			if affix != null and affix.stat_key == key:
				return affix.display_name if affix.display_name != "" else key
	return key

## 属性词条"具体效果"描述模板（键 → 模板，{v} 为该属性按显示口径换算后的带符号数值）
## 设计意图：状态栏不再只显示"词条名 + 裸数值"，而是直接说明它到底带来什么效果
## 说明：百分比口径键（_mult 乘算键，以及数值本身就是比例的 damage_reduction）已 ×100 换算为百分比，
##       模板里直接补 "%" 即可
const STAT_DESC_TEMPLATES := {
	"max_hp_bonus": "生命上限 {v}",
	"hp_regen": "每秒回血 {v} 点",
	"damage_mult": "子弹伤害 {v}%",
	"fire_rate_mult": "射速 {v}%",
	"bullet_speed_mult": "子弹飞行速度 {v}%",
	"shield_regen_mult": "护盾回复速度 {v}%",
	"shield_max_mult": "护盾上限 {v}%",
	"move_speed_mult": "移动速度 {v}%",
	"invincible_mult": "受击无敌时间 {v}%",
	"damage_reduction": "受到伤害降低 {v}%",
}

## 把属性词条翻译成"具体效果"描述（未收录的键回退为"带符号数值 + 单位"的通用展示）
## 参数：stat_key - 属性键；value - 该属性累计值（原始口径，乘算键为系数）
func _describe_stat(stat_key: String, value: float) -> String:
	var template: String = String(STAT_DESC_TEMPLATES.get(stat_key, ""))
	if template.is_empty():
		return _fmt_stat(stat_key, value)
	## 模板里已自带 "%" 等单位，故此处只填"数值部分"（不含单位）
	return template.replace("{v}", _fmt_stat_units(stat_key, _stat_display_units(stat_key, value)))

## 判断属性键是否按"百分比"口径展示
## 约定：_mult 结尾为乘算倍率；damage_reduction 虽为加算比例，但数值本身就是"比例"，
##       展示时同样需 ×100 并补 "%"（否则会显示成 +0.1 而非 +10%）
## 参数：stat_key - 属性键
## 返回：true=按百分比展示
func _is_percent_stat(stat_key: String) -> bool:
	return stat_key.ends_with("_mult") or stat_key == "damage_reduction"

## 属性键的单位后缀（百分比口径键为 "%"，加算键无单位）
func _stat_unit(stat_key: String) -> String:
	return "%" if _is_percent_stat(stat_key) else ""

## 属性值按显示口径缩放（百分比键 ×100 转百分比，加算键原样）
func _stat_scaled(stat_key: String, value: float) -> float:
	return value * 100.0 if _is_percent_stat(stat_key) else value

## 把属性值换算成"显示整数单位"：百分比键 → 整数个百分点；固定加值键 → 十分位整数（值 ×10）
## 设计意图：展示与差值一律在整数口径下完成，彻底规避浮点误差，
##           也避免"先取整再相减"与"先相减再取整"导致的两侧方向不一致
## 参数：stat_key - 属性键；value - 原始口径数值（乘算键为系数）
## 返回：显示单位整数值（如 8 表示 +8%；124 表示 +12.4）
func _stat_display_units(stat_key: String, value: float) -> int:
	var scaled: float = _stat_scaled(stat_key, value)
	if _is_percent_stat(stat_key):
		return int(round(scaled))
	return int(round(scaled * 10.0))

## 把"显示整数单位"渲染为带正负号的文本（非负补 "+"）
## 精度约定：百分比键只显示整数（由 _stat_unit 补 "%" 得到 "+8%"）；
##           固定加值键保留 1 位小数（如 "+12.4"），与装备词条展示口径一致
## 参数：stat_key - 属性键；units - _stat_display_units 计算出的显示单位整数
func _fmt_stat_units(stat_key: String, units: int) -> String:
	if _is_percent_stat(stat_key):
		return ("+" if units >= 0 else "") + str(units)
	## 固定加值：由十分位整数还原出 1 位小数（整数取精、浮点仅用于渲染，不会有尾数误差）
	var sign_prefix: String = "-" if units < 0 else "+"
	return "%s%.1f" % [sign_prefix, float(absi(units)) / 10.0]

## 格式化属性值（带正负号 + 单位），如 "+9%" / "+12.4"
func _fmt_stat(stat_key: String, value: float) -> String:
	return _fmt_stat_units(stat_key, _stat_display_units(stat_key, value)) + _stat_unit(stat_key)

## 按差值正负取色（提升=绿 / 下降=红 / 持平=灰）
func _diff_color(diff: float) -> Color:
	if diff > 0.001:
		return Color(0.4, 1.0, 0.5)
	if diff < -0.001:
		return Color(1.0, 0.45, 0.45)
	return Color(0.7, 0.7, 0.7)

## 护盾蓝图文本（"最大耐久 / 单次吸收"；无护盾时为"暂无"）
func _shield_text(data: EquipmentData) -> String:
	if data == null or data.shield_data == null:
		return TranslationManager.t("STATUS_NONE")
	return "%d / %d" % [int(data.shield_data.max_hp), int(data.shield_data.absorb_per_hit)]

## 提取"主动技能 skill_id → 展示文本(名称 + 冷却 + 整轮伤害倍率)"映射（供逐条对比使用）
## 说明：单件装备至多一个主动技，映射至多一个条目；skill_id 为空时退化为按名称归并
func _active_skill_map(data: EquipmentData) -> Dictionary:
	var out: Dictionary = {}
	if data == null or not data.has_active_skill():
		return out
	var skill: EquipmentActiveSkill = data.active_skill
	## skill_id 为空时退化为按名称归并，保证仍有稳定的对比键
	var sid: String = String(skill.skill_id)
	if sid.is_empty():
		sid = String(skill.display_name)
	out[sid] = "%s (CD %.1fs，伤害×%.1f)" % [
		skill.display_name, float(skill.cooldown), float(skill.damage_multiplier)]
	return out