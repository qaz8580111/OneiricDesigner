## TemplePanel.gd - 神庙选项面板（紧凑底栏样式，不暂停游戏）
## 职责：展示神庙的4个选项（随机技能/随机护盾/强化伤害/生命上限），玩家选定后发信号
## 设计意图：
##   1. 与 LevelUpPanel 同风格：屏幕底部居中小面板，无全屏蒙层，不暂停游戏
##   2. 鼠标点击/数字键1-4/手柄D-Pad上下+A选择；描述走tooltip减小占用
##   3. 赌博式选项带"赌"角标，稳妥式带"稳"角标，玩家可预判风险
## 输入架构：选择输入全部经InputManager网关（TEMPLE_CHOICE上下文放行ui_up/down/confirm）；
##           按钮FOCUS_NONE，选中态由_selected_index统一管理，避免内置焦点双重移动
## 数据流：Temple.interact() → 创建面板 → setup(options)
##         → 玩家选定 option_chosen 信号 → Temple 应用效果并消失
extends Control

## ========== 信号定义 ==========

## 选项选定信号
## 参数：option - 被选中的神庙选项资源
signal option_chosen(option: Resource)

## ========== 成员变量 ==========

var _options: Array = []          ## 全部选项（TempleOption资源）
var _buttons: Array[Button] = []  ## 选项按钮列表（动画用）
var _vbox: VBoxContainer = null   ## 内部垂直容器
var _locked: bool = false         ## 防重复选择锁

## 当前选中选项索引（鼠标悬停/D-Pad上下共用一个选中态，A键确认）
var _selected_index: int = -1

## ========== 选中态视觉常量 ==========

## 选中选项的紫金提亮（呼应神庙紫金边框主题）
const SELECTED_MODULATE: Color = Color(1.2, 1.1, 1.6, 1.0)
## 未选中选项的正常颜色
const NORMAL_MODULATE: Color = Color.WHITE
## 选中选项放大倍数
const SELECTED_SCALE: Vector2 = Vector2(1.05, 1.05)
## 选中态切换动画时长（秒）
const SELECT_TWEEN_TIME: float = 0.06

## ========== 生命周期方法 ==========

## _ready() - 构建紧凑底栏UI
func _ready() -> void:
	## 根Control全屏（用于捕获键盘事件），鼠标穿透不拦截游戏点击
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	## ---------- 底部居中面板容器 ----------
	var panel_bg: PanelContainer = PanelContainer.new()
	add_child(panel_bg)
	## 锚定到屏幕底部居中，底部留出 56px 安全区（底部状态栏高28px + 间距28px）
	## 避免与 GameHUD 底部常驻状态栏重叠，同时保证面板完整显示不贴边
	panel_bg.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	panel_bg.offset_top = -150.0  ## 面板自身高度约92px（4选项+标题）
	panel_bg.offset_bottom = -58.0  ## 距屏幕底边 58px

	## 面板背景样式：半透明深色 + 金色细边框 + 圆角（与升级面板一致）
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.09, 0.92)
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_color = Color(0.7, 0.6, 0.95, 0.6)  ## 紫金色边框（区别于升级面板）
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	panel_bg.add_theme_stylebox_override("panel", sb)

	## ---------- 内部垂直布局：标题 + 选项行 ----------
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 3)
	panel_bg.add_child(_vbox)

	## 标题
	var title: Label = Label.new()
	title.text = "◈ 远古神庙 ◈"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(0.75, 0.6, 1.0))
	_vbox.add_child(title)

	## 入场动画初始状态
	panel_bg.modulate.a = 0.0
	var tween: Tween = create_tween()
	tween.tween_property(panel_bg, "modulate:a", 1.0, 0.15)

## _process() - 手柄D-Pad/键盘方向键导航与确认（经InputManager网关轮询消费）
## 面板为垂直列表，用ui_up/ui_down移动选中项
func _process(_delta: float) -> void:
	## 已锁定选择后不响应，防重复触发
	if _locked or _buttons.is_empty():
		return
	## D-Pad上/上方向键：选中上一项（边界夹取不循环）
	if InputManager.is_action_just_pressed_safe("ui_up"):
		_set_selection(_selected_index - 1)
	## D-Pad下/下方向键：选中下一项
	elif InputManager.is_action_just_pressed_safe("ui_down"):
		_set_selection(_selected_index + 1)
	## A键/Space/Enter：确认当前选中项
	if InputManager.is_action_just_pressed_safe("ui_confirm"):
		_choose(_selected_index)

## _unhandled_input() - 数字键1/2/3/4快捷选择
func _unhandled_input(event: InputEvent) -> void:
	if _locked:
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var index: int = -1
	match event.physical_keycode:
		KEY_1: index = 0
		KEY_2: index = 1
		KEY_3: index = 2
		KEY_4: index = 3
	if index >= 0 and index < _options.size():
		_choose(index)

## ========== 对外接口 ==========

## 初始化面板显示（Temple创建面板后调用）
## 参数：options - 神庙选项数组（TempleOption资源）
func setup(options: Array) -> void:
	_options = options
	_buttons.clear()
	## 选中索引置-1：构建完成后_set_selection(0)才会真正刷新高亮（同索引会被去重跳过）
	_selected_index = -1
	for i in range(options.size()):
		var btn: Button = _create_option_button(options[i], i)
		_vbox.add_child(btn)
		_buttons.append(btn)
	## 默认高亮第一项（Temple.push_context自带0.2s屏蔽期，已替输入防抖，无需额外动画锁）
	_set_selection(0)

## ========== 内部构建方法 ==========

## 创建单个选项按钮
## 参数：option - 神庙选项资源, index - 序号（数字键提示用）
func _create_option_button(option: Resource, index: int) -> Button:
	var btn: Button = Button.new()
	var gamble_tag: String = "赌" if option.is_gamble else "稳"
	var key_hint: String = str(index + 1)
	btn.text = "[%s] %s %s" % [key_hint, gamble_tag, option.display_name]
	## 描述走tooltip（减小面板占用）
	btn.tooltip_text = option.description
	btn.custom_minimum_size = Vector2(150, 34)
	btn.focus_mode = Control.FOCUS_NONE

	## 按钮样式：深色底 + 选项主题色边框
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.1, 0.16, 0.9)
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_color = option.option_color
	sb.corner_radius_top_left = 4
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_left = 4
	sb.corner_radius_bottom_right = 4
	btn.add_theme_stylebox_override("normal", sb)

	## 悬停样式：底色提亮
	var sb_hover: StyleBoxFlat = sb.duplicate()
	sb_hover.bg_color = Color(0.18, 0.18, 0.28, 0.95)
	btn.add_theme_stylebox_override("hover", sb_hover)

	## 按下样式：更亮
	var sb_pressed: StyleBoxFlat = sb.duplicate()
	sb_pressed.bg_color = Color(0.24, 0.24, 0.36, 1.0)
	btn.add_theme_stylebox_override("pressed", sb_pressed)

	## 字体颜色跟随选项主题色
	btn.add_theme_color_override("font_color", option.option_color)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_font_size_override("font_size", 13)

	## 点击选择
	btn.pressed.connect(_choose.bind(index))
	## 缩放以按钮中心为原点（选中放大时不偏移）
	btn.pivot_offset = btn.custom_minimum_size * 0.5
	## 鼠标悬停即同步选中索引：键鼠与手柄共用同一套选中高亮/确认逻辑
	btn.mouse_entered.connect(_set_selection.bind(index))
	return btn

## 设置当前选中选项（鼠标悬停与D-Pad导航的唯一入口）
## 参数：index - 目标索引，自动夹取到[0,选项数)边界，不循环
func _set_selection(index: int) -> void:
	if _buttons.is_empty():
		return
	var new_index: int = clampi(index, 0, _buttons.size() - 1)
	if new_index == _selected_index:
		return
	_selected_index = new_index
	_refresh_selection_visual()

## 刷新全部选项的选中态视觉（选中=紫金提亮+放大，其余=正常）
func _refresh_selection_visual() -> void:
	for i in range(_buttons.size()):
		var btn: Button = _buttons[i]
		var is_selected: bool = i == _selected_index
		var target_modulate: Color = SELECTED_MODULATE if is_selected else NORMAL_MODULATE
		var target_scale: Vector2 = SELECTED_SCALE if is_selected else Vector2.ONE
		## 短tween过渡，选中反馈干脆利落
		var t: Tween = btn.create_tween()
		t.set_parallel(true)
		t.tween_property(btn, "modulate", target_modulate, SELECT_TWEEN_TIME)
		t.tween_property(btn, "scale", target_scale, SELECT_TWEEN_TIME).set_ease(Tween.EASE_OUT)

## 选定选项
func _choose(index: int) -> void:
	if _locked or index < 0 or index >= _options.size():
		return
	_locked = true
	var chosen: Resource = _options[index]
	if AudioManager:
		AudioManager.play_ui("ui_click", 0.7)
	option_chosen.emit(chosen)
