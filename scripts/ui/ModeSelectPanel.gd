## ModeSelectPanel.gd - 模式选择面板（纯代码构建UI，无需.tscn）
## 职责：主菜单点击"开始游戏"后弹出，让玩家在【通关模式】与【无尽模式】之间二选一，
##       选中的模式在下方即时展示该模式的玩法介绍，确认后即开始游戏
## 继承：Control（全屏覆盖层，挂在ui_stack下）
## 设计意图：
##   1. 知情选择：两种模式的节奏与收尾完全不同（击破终极BOSS结束 vs 无限登塔至死），
##      必须在开局前讲清楚，避免玩家"打了半小时不知道自己在玩什么"
##   2. 沿用 GameOverPanel 的输入范式（LT/RT 切换 + A 确认 + B 返回），
##      与结算面板共用同一套肌肉记忆
##   3. 面板无状态：只负责"选模式 + 发信号"，开局流程仍由 Main.gd 掌控
## 数据流：MainMenu.start_game → Main._show_mode_select() → 本面板 →
##         start_requested(mode) → Main._start_game(mode) → GameManager.start_new_game(seed, mode)
extends Control

## ========== 信号定义 ==========

## 开始游戏信号：玩家确认模式后发出
## 参数：mode - 所选模式（GameManager.RunMode.CLASSIC / ENDLESS）
signal start_requested(mode: int)

## 取消信号：玩家返回/取消时发出（Main.gd 监听后回主菜单）
signal cancelled

## ========== 成员变量 ==========

## 当前选中的模式索引：0=通关模式，1=无尽模式
var _selected_index: int = 0

## 两个模式按钮的引用（导航时需要高亮）
var _mode_buttons: Array[Button] = []

## 文本控件引用（语言切换/选中变化时刷新）
var _title_label: Label = null
var _desc_label: Label = null
var _hint_label: Label = null
var _start_btn: Button = null
var _back_btn: Button = null

## 是否已构建完成（防止输入在构建前触发）
var _is_ready: bool = false

## 选中态样式常量（与结算面板保持一致的高亮语言）
const SELECTED_MODULATE: Color = Color(1.25, 1.15, 0.75)  ## 金色高亮
const NORMAL_MODULATE: Color = Color(1.0, 1.0, 1.0)
const SELECT_TWEEN_TIME: float = 0.06

## 模式介绍文本区的固定宽度：保证切换模式时布局不跳动（1920×1280下足够容纳中英双语文案）
const DESC_MIN_WIDTH: float = 660.0

## ========== 生命周期方法 ==========

## _ready() - 构建整个面板UI
func _ready() -> void:
	## 主菜单路径下场景树未暂停，但保险起见与其它面板保持一致的处理模式
	process_mode = Node.PROCESS_MODE_ALWAYS
	## 全屏覆盖：必须用 set_anchors_and_offsets_preset（等价编辑器Layout菜单），
	## 不能用 set_anchors_preset——后者只改锚点并按"保持当前矩形"重算偏移，
	## 新建Control的矩形是(0,0,0,0)，面板会塌缩成左上角0x0的点
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	## 拦截鼠标点击，防止穿透到下层
	mouse_filter = Control.MOUSE_FILTER_STOP

	## ---------- 全屏暗色背景 ----------
	## 深蓝黑背景：比主菜单背景更暗一档，形成"进入子菜单"的层级感
	var bg: ColorRect = ColorRect.new()
	bg.color = Color(0.08, 0.1, 0.18, 0.96)
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	## 背景不接收鼠标事件，否则挡住按钮点击（项目教训）
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE

	## ---------- 居中容器 ----------
	## CenterContainer全屏铺满，子节点按最小尺寸永远居中，不依赖锚点偏移语义
	var center: CenterContainer = CenterContainer.new()
	add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE

	## ---------- 垂直布局 ----------
	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 18)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(vbox)

	## ---------- 标题 ----------
	_title_label = Label.new()
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 40)
	_title_label.add_theme_color_override("font_color", Color(0.9, 0.92, 1.0))
	vbox.add_child(_title_label)

	## ---------- 模式选项（水平排列的两个大按钮） ----------
	var mode_hbox: HBoxContainer = HBoxContainer.new()
	mode_hbox.add_theme_constant_override("separation", 24)
	mode_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	mode_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(mode_hbox)

	## 两个选项按钮：鼠标点击=选中（并在下方展示介绍），手柄/键盘用 LT/RT 切换
	for i in 2:
		var mode_btn: Button = Button.new()
		mode_btn.custom_minimum_size = Vector2(280, 64)
		## 禁用内置焦点导航，改用手动 D-Pad/扳机逻辑（避免一次按键跳两格）
		mode_btn.focus_mode = Control.FOCUS_NONE
		## bind 固定索引：回调里无需猜测是哪个按钮
		mode_btn.pressed.connect(_on_mode_button_pressed.bind(i))
		mode_hbox.add_child(mode_btn)
		_mode_buttons.append(mode_btn)

	## ---------- 模式介绍（随选中模式即时切换） ----------
	_desc_label = Label.new()
	_desc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_desc_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	## 自动换行 + 固定宽度：中英双语文案长度差异大，固定宽度可避免切换时整体布局抖动
	_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc_label.custom_minimum_size = Vector2(DESC_MIN_WIDTH, 150)
	_desc_label.add_theme_font_size_override("font_size", 20)
	_desc_label.add_theme_color_override("font_color", Color(0.85, 0.88, 0.95))
	vbox.add_child(_desc_label)

	## ---------- 操作按钮 ----------
	_start_btn = Button.new()
	_start_btn.custom_minimum_size = Vector2(300, 48)
	_start_btn.focus_mode = Control.FOCUS_NONE
	_start_btn.pressed.connect(_on_start_pressed)
	vbox.add_child(_start_btn)

	_back_btn = Button.new()
	_back_btn.custom_minimum_size = Vector2(300, 40)
	_back_btn.focus_mode = Control.FOCUS_NONE
	_back_btn.pressed.connect(_on_back_pressed)
	vbox.add_child(_back_btn)

	## ---------- 操作提示 ----------
	_hint_label = Label.new()
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.add_theme_font_size_override("font_size", 16)
	_hint_label.add_theme_color_override("font_color", Color(0.6, 0.63, 0.72))
	vbox.add_child(_hint_label)

	## 监听语言变化：切换语言时全部文案即时刷新
	TranslationManager.language_changed.connect(_on_language_changed)

	## 刷新全部文案（含模式介绍）
	_update_text()
	## 标记构建完成（输入生效前提）
	_is_ready = true
	## 应用初始选中态的高亮（不经过 _set_selection 的去重分支）
	_refresh_selection_visual()

## _process() - 手柄/键盘导航：LT/RT（或左右方向键）切换模式，A 确认开始，B 返回
## 设计意图：选择面板必须支持手柄全操作；复用 InputManager 网关保证与其它面板一致的输入过滤，
## LT/RT 走 InputManager 的扳机轴越阈边沿检测（game_choice_prev/next，SETTINGS 上下文放行）
func _process(_delta: float) -> void:
	## 构建未完成时不响应
	if not _is_ready:
		return
	## LT扳机/方向键左：选中【通关模式】
	if InputManager.is_action_just_pressed_safe("game_choice_prev") \
			or InputManager.is_action_just_pressed_safe("ui_left"):
		_set_selection(0)
	## RT扳机/方向键右：选中【无尽模式】
	elif InputManager.is_action_just_pressed_safe("game_choice_next") \
			or InputManager.is_action_just_pressed_safe("ui_right"):
		_set_selection(1)
	## A键/空格/回车：确认开始游戏
	elif InputManager.is_action_just_pressed_safe("ui_confirm"):
		_on_start_pressed()
	## B键/ESC：返回主菜单
	elif InputManager.is_action_just_pressed_safe("ui_cancel"):
		_on_back_pressed()

## ========== 界面文本更新 ==========

## 刷新全部文案（语言切换与选中变化时调用）
func _update_text() -> void:
	if _title_label != null:
		_title_label.text = TranslationManager.t("MODE_SELECT_TITLE")
	if _hint_label != null:
		_hint_label.text = TranslationManager.t("MODE_SELECT_HINT")
	if _start_btn != null:
		_start_btn.text = TranslationManager.t("BUTTON_CONFIRM_START")
	if _back_btn != null:
		_back_btn.text = TranslationManager.t("BUTTON_BACK")
	## 两个模式按钮文案
	var mode_keys: Array[String] = ["MODE_CLASSIC", "MODE_ENDLESS"]
	for i in _mode_buttons.size():
		if i < mode_keys.size():
			_mode_buttons[i].text = TranslationManager.t(mode_keys[i])
	## 模式介绍随选中项刷新
	_refresh_description()

## 刷新模式介绍文本（下方介绍区随选中模式切换）
func _refresh_description() -> void:
	if _desc_label == null:
		return
	var desc_key: String = "MODE_CLASSIC_DESC" if _selected_index == 0 else "MODE_ENDLESS_DESC"
	_desc_label.text = TranslationManager.t(desc_key)

## ========== 导航辅助方法 ==========

## 设置选中索引（去重 + clamp保护），并同步刷新高亮与介绍
## 参数：index - 目标索引（0=通关模式，1=无尽模式）
func _set_selection(index: int) -> void:
	index = clampi(index, 0, _mode_buttons.size() - 1)
	if index == _selected_index:
		return
	## 切换音效：给出"选项已改变"的即时反馈
	if AudioManager:
		AudioManager.play("ui_click", 0.5)
	_selected_index = index
	_refresh_selection_visual()
	_refresh_description()

## 刷新选中项的高亮视觉（选中项金色，未选中项常态）
func _refresh_selection_visual() -> void:
	if _mode_buttons.is_empty():
		return
	## 单个 tween 并行插值：同时高亮选中项、淡化未选中项
	var tw: Tween = create_tween().set_parallel(true)
	for i in _mode_buttons.size():
		var target: Color = SELECTED_MODULATE if i == _selected_index else NORMAL_MODULATE
		tw.tween_property(_mode_buttons[i], "modulate", target, SELECT_TWEEN_TIME).set_ease(Tween.EASE_OUT)

## ========== 信号回调 ==========

## 模式按钮点击回调（鼠标路径：点击=选中，不直接开局，便于玩家先读介绍）
## 参数：index - 被点击的模式索引
func _on_mode_button_pressed(index: int) -> void:
	_set_selection(index)

## 确认开始回调（"开始游戏"按钮 / A键 都走这里）
func _on_start_pressed() -> void:
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	## 索引 → 模式枚举的映射（UI 索引是展示顺序，与枚举值解耦）
	var mode: int = GameManager.RunMode.CLASSIC if _selected_index == 0 else GameManager.RunMode.ENDLESS
	start_requested.emit(mode)

## 返回回调（"返回"按钮 / B键 都走这里）
func _on_back_pressed() -> void:
	if AudioManager:
		AudioManager.play("ui_click", 0.6)
	cancelled.emit()

## 语言变化回调：重新刷新界面文本
func _on_language_changed(_lang: String) -> void:
	_update_text()
