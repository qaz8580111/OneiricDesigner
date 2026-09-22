## LeaderboardPanel.gd - 排行榜面板（纯代码构建UI，无需.tscn）
## 职责：在同一个面板内展示两种模式的排行榜——通关榜（终极BOSS战用时升序）与登塔榜（层数降序），
##       通过 LT/RT（或左右方向键）切换两个榜单
## 继承：Control（全屏覆盖层，挂在ui_stack下）
## 设计意图：
##   1. 单一数据源：数据全部来自 LeaderboardManager（已排序、已截断），面板只做展示，不排序不裁剪
##   2. 双榜同屏切换：两个榜单结构完全对称（排名/成绩/日期），切换即重建行，
##      不用两套控件避免状态不同步
##   3. 复用 GameOverPanel 的输入范式（LT/RT 切换 + B 返回），与其它面板肌肉记忆一致
## 数据流：LeaderboardManager（启动时载入 user://leaderboard.cfg）→ 本面板 → 展示
extends Control

## ========== 信号定义 ==========

## 返回信号：玩家返回时发出（Main.gd 监听后回主菜单）
signal back_requested

## ========== 成员变量 ==========

## 当前榜单索引：0=通关榜，1=登塔榜
var _current_tab: int = 0

## 列表网格（3列：排名 / 成绩 / 日期），切换榜单或数据更新时整表重建
var _grid: GridContainer = null

## 空榜提示标签（无记录时替代网格显示）
var _empty_label: Label = null

## 文本控件引用（语言切换时刷新）
var _title_label: Label = null
var _best_label: Label = null
var _hint_label: Label = null
var _back_btn: Button = null
var _tab_buttons: Array[Button] = []

## 是否已构建完成（防止输入在构建前触发）
var _is_ready: bool = false

## 选中态样式常量（与其它面板保持一致的高亮语言）
const SELECTED_MODULATE: Color = Color(1.25, 1.15, 0.75)
const NORMAL_MODULATE: Color = Color(1.0, 1.0, 1.0)
const SELECT_TWEEN_TIME: float = 0.06

## ---------- 表格列宽（固定值保证两个榜单切换时列对齐一致） ----------
const COL_RANK_WIDTH: float = 80.0    ## 排名列（"1"~"10" 仅 2 字符，缩窄留出空间给昵称列）
const COL_NICKNAME_WIDTH: float = 200.0  ## 昵称列（玩家输入的昵称，最长 MAX_NICKNAME_LENGTH=12 字符）
const COL_VALUE_WIDTH: float = 300.0  ## 成绩列（用时 / 层数）
const COL_DATE_WIDTH: float = 320.0   ## 日期列

## ========== 生命周期方法 ==========

## _ready() - 构建整个面板UI并填充榜单数据
func _ready() -> void:
	## 主菜单路径下场景树未暂停，保持与其它面板一致的处理模式
	process_mode = Node.PROCESS_MODE_ALWAYS
	## 全屏覆盖：必须用 set_anchors_and_offsets_preset（不能用只改锚点的 set_anchors_preset）
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	## 拦截鼠标点击，防止穿透到下层
	mouse_filter = Control.MOUSE_FILTER_STOP

	## ---------- 全屏暗色背景 ----------
	var bg: ColorRect = ColorRect.new()
	bg.color = Color(0.08, 0.1, 0.18, 0.96)
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	## 背景不接收鼠标事件，否则挡住按钮点击
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE

	## ---------- 居中容器 ----------
	var center: CenterContainer = CenterContainer.new()
	add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE

	## ---------- 垂直布局 ----------
	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(vbox)

	## ---------- 标题 ----------
	_title_label = Label.new()
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 40)
	_title_label.add_theme_color_override("font_color", Color(0.9, 0.92, 1.0))
	vbox.add_child(_title_label)

	## ---------- 榜单切换按钮（鼠标可点，手柄走 LT/RT） ----------
	var tab_hbox: HBoxContainer = HBoxContainer.new()
	tab_hbox.add_theme_constant_override("separation", 20)
	tab_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	tab_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(tab_hbox)

	for i in 2:
		var tab_btn: Button = Button.new()
		tab_btn.custom_minimum_size = Vector2(220, 44)
		## 禁用内置焦点导航，改用手动 D-Pad/扳机逻辑
		tab_btn.focus_mode = Control.FOCUS_NONE
		## bind 固定索引：回调里无需猜测是哪个标签
		tab_btn.pressed.connect(_on_tab_button_pressed.bind(i))
		tab_hbox.add_child(tab_btn)
		_tab_buttons.append(tab_btn)

	## ---------- 榜单表格（4列：排名/昵称/成绩/日期） ----------
	_grid = GridContainer.new()
	_grid.columns = 4
	## 行距与列距：数值较小以保证10行能在1920×1280内完整显示
	_grid.add_theme_constant_override("h_separation", 16)
	_grid.add_theme_constant_override("v_separation", 6)
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_grid)

	## ---------- 空榜提示（无记录时替代表格） ----------
	_empty_label = Label.new()
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	## 空榜宽度=4列总宽，保证空榜提示与表格左右对齐
	_empty_label.custom_minimum_size = Vector2(COL_RANK_WIDTH + COL_NICKNAME_WIDTH + COL_VALUE_WIDTH + COL_DATE_WIDTH, 80)
	_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_label.add_theme_font_size_override("font_size", 22)
	_empty_label.add_theme_color_override("font_color", Color(0.6, 0.63, 0.72))
	vbox.add_child(_empty_label)

	## ---------- 历史最佳 ----------
	_best_label = Label.new()
	_best_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_best_label.add_theme_font_size_override("font_size", 20)
	_best_label.add_theme_color_override("font_color", Color(0.95, 0.9, 0.6))
	vbox.add_child(_best_label)

	## ---------- 返回按钮 ----------
	_back_btn = Button.new()
	_back_btn.custom_minimum_size = Vector2(300, 44)
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
	## 监听榜单更新：面板打开期间若有新成绩写入（联网/外部改动），即时刷新
	LeaderboardManager.leaderboard_updated.connect(_rebuild_list)

	## 刷新全部文案 + 重建榜单
	_update_text()
	_rebuild_list()
	## 标记构建完成（输入生效前提）
	_is_ready = true
	## 应用初始选中态的高亮
	_refresh_tab_visual()

## _process() - 手柄/键盘导航：LT/RT（或左右方向键）切换榜单，B 返回
func _process(_delta: float) -> void:
	if not _is_ready:
		return
	## LT扳机/方向键左：切到通关榜
	if InputManager.is_action_just_pressed_safe("game_choice_prev") \
			or InputManager.is_action_just_pressed_safe("ui_left"):
		_set_tab(0)
	## RT扳机/方向键右：切到登塔榜
	elif InputManager.is_action_just_pressed_safe("game_choice_next") \
			or InputManager.is_action_just_pressed_safe("ui_right"):
		_set_tab(1)
	## A键/空格/回车：也用于切换（两榜之间无第三项，A 键切换符合直觉）
	elif InputManager.is_action_just_pressed_safe("ui_confirm"):
		_set_tab(1 - _current_tab)
	## B键/ESC：返回主菜单
	elif InputManager.is_action_just_pressed_safe("ui_cancel"):
		_on_back_pressed()

## ========== 界面文本更新 ==========

## 刷新全部文案（语言切换/榜单切换时调用）
func _update_text() -> void:
	if _title_label != null:
		_title_label.text = TranslationManager.t("LEADERBOARD_TITLE")
	if _back_btn != null:
		_back_btn.text = TranslationManager.t("BUTTON_BACK")
	if _hint_label != null:
		_hint_label.text = TranslationManager.t("LEADERBOARD_HINT")
	if _empty_label != null:
		_empty_label.text = TranslationManager.t("LEADERBOARD_EMPTY")
	## 两个标签页按钮文案
	var tab_keys: Array[String] = ["LEADERBOARD_TAB_CLASSIC", "LEADERBOARD_TAB_TOWER"]
	for i in _tab_buttons.size():
		if i < tab_keys.size():
			_tab_buttons[i].text = TranslationManager.t(tab_keys[i])
	## 历史最佳文案随榜单类型切换
	_refresh_best_label()

## 刷新"历史最佳"文案（当前榜单为通关榜时显示最佳用时，登塔榜时显示最高层数）
func _refresh_best_label() -> void:
	if _best_label == null:
		return
	var prefix: String = TranslationManager.t("LEADERBOARD_BEST")
	if _current_tab == 0:
		var best_time: float = LeaderboardManager.get_best_classic_time()
		## 空榜返回 -1.0：没有成绩时不显示"历史最佳"，交由空榜提示承担说明职责
		if best_time < 0.0:
			_best_label.text = ""
			return
		_best_label.text = "%s：%s" % [prefix, LeaderboardManager.format_time(best_time)]
	else:
		var best_floor: int = LeaderboardManager.get_best_tower_floor()
		if best_floor <= 0:
			_best_label.text = ""
			return
		_best_label.text = "%s：%d%s" % [prefix, best_floor, TranslationManager.t("LEADERBOARD_FLOOR_UNIT")]

## ========== 榜单重建 ==========

## 重建榜单表格（切换标签或数据更新时整表重建）
## 实现说明：整表重建而非增量更新——榜单最多10行，重建成本可忽略，
##           且能天然规避"两个榜单列语义不同"导致的状态残留
func _rebuild_list() -> void:
	if _grid == null:
		return
	## 清空旧行（用 free 立即销毁，避免 queue_free 延迟到帧末导致新旧行短暂共存）
	for child in _grid.get_children():
		child.free()

	## 取当前榜单数据（LeaderboardManager 返回的是可直接使用的已排序副本）
	var is_classic: bool = _current_tab == 0
	var entries: Array = LeaderboardManager.get_classic_times() if is_classic else LeaderboardManager.get_tower_floors()

	## 空榜：隐藏表格，显示提示
	if entries.is_empty():
		_grid.visible = false
		_empty_label.visible = true
		_refresh_best_label()
		return
	_grid.visible = true
	_empty_label.visible = false

	## ---------- 表头 ----------
	var header_rank: String = TranslationManager.t("LEADERBOARD_COL_RANK")
	var header_value: String = TranslationManager.t("LEADERBOARD_COL_TIME") if is_classic \
			else TranslationManager.t("LEADERBOARD_COL_FLOOR")
	var header_date: String = TranslationManager.t("LEADERBOARD_COL_DATE")
	_add_row(header_rank, TranslationManager.t("LEADERBOARD_COL_NICKNAME"), header_value, header_date, Color(0.7, 0.76, 0.9), true)

	## ---------- 数据行 ----------
	for i in entries.size():
		var entry: Dictionary = entries[i]
		## 排名：1~10
		var rank_text: String = "%d" % (i + 1)
		## 昵称：玩家输入或历史数据回读（LeaderboardManager 已规整空值为 "佚名"）
		var nickname_text: String = str(entry.get("nickname", LeaderboardManager.DEFAULT_NICKNAME))
		var value_text: String = ""
		if is_classic:
			value_text = LeaderboardManager.format_time(float(entry.get("time", 0.0)))
		else:
			value_text = "%d%s" % [int(entry.get("floor", 0)), TranslationManager.t("LEADERBOARD_FLOOR_UNIT")]
		var date_text: String = str(entry.get("date", ""))
		## 前三名用金色区分（荣誉感），其余用常规色
		var row_color: Color = Color(1.0, 0.88, 0.55) if i < 3 else Color(0.87, 0.9, 0.96)
		_add_row(rank_text, nickname_text, value_text, date_text, row_color, false)

	_refresh_best_label()

## 向表格追加一行（4个等宽标签：排名/昵称/成绩/日期）
## 参数：rank/nickname/value/date - 四列的文本
##       color - 文本颜色
##       is_header - 是否表头（表头加粗底色区分）
func _add_row(rank: String, nickname: String, value: String, date: String, color: Color, is_header: bool) -> void:
	var texts: Array[String] = [rank, nickname, value, date]
	var widths: Array[float] = [COL_RANK_WIDTH, COL_NICKNAME_WIDTH, COL_VALUE_WIDTH, COL_DATE_WIDTH]
	for i in 4:
		var cell: Label = Label.new()
		cell.text = texts[i]
		cell.custom_minimum_size = Vector2(widths[i], 34 if is_header else 30)
		cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cell.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		cell.add_theme_font_size_override("font_size", 22 if is_header else 20)
		cell.add_theme_color_override("font_color", color)
		## 昵称列文本超长裁剪：玩家昵称最长 12 字，正常情况不会溢出；
		## 但保险起见启用 ELLIPSIS 避免极端情况下撑破布局
		if i == 1:
			cell.clip_text = true
			cell.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_grid.add_child(cell)

## ========== 导航辅助方法 ==========

## 切换榜单（去重 + clamp保护），并同步刷新高亮、文案与表格
## 参数：index - 目标榜单索引（0=通关榜，1=登塔榜）
func _set_tab(index: int) -> void:
	index = clampi(index, 0, _tab_buttons.size() - 1)
	if index == _current_tab:
		return
	## 切换音效：给出"榜单已改变"的即时反馈
	if AudioManager:
		AudioManager.play("ui_click", 0.5)
	_current_tab = index
	_refresh_tab_visual()
	_update_text()
	_rebuild_list()

## 刷新选中榜单按钮的高亮视觉
func _refresh_tab_visual() -> void:
	if _tab_buttons.is_empty():
		return
	var tw: Tween = create_tween().set_parallel(true)
	for i in _tab_buttons.size():
		var target: Color = SELECTED_MODULATE if i == _current_tab else NORMAL_MODULATE
		tw.tween_property(_tab_buttons[i], "modulate", target, SELECT_TWEEN_TIME).set_ease(Tween.EASE_OUT)

## ========== 信号回调 ==========

## 榜单标签按钮点击回调（鼠标路径）
## 参数：index - 被点击的榜单索引
func _on_tab_button_pressed(index: int) -> void:
	_set_tab(index)

## 返回回调（"返回"按钮 / B键 / ESC 都走这里）
func _on_back_pressed() -> void:
	if AudioManager:
		AudioManager.play("ui_click", 0.6)
	back_requested.emit()

## 语言变化回调：重新刷新界面文本与表格（表头/单位需要跟着语言变）
func _on_language_changed(_lang: String) -> void:
	_update_text()
	_rebuild_list()
