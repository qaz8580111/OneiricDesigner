## TemplePanel.gd - 神庙选项面板（紧凑底栏样式，与升级三选一同款横向排版）
## 职责：展示神庙的4个选项，玩家选定后发信号；支持返回键取消且不消耗神庙
## 设计意图：
##   1. 与 LevelUpPanel 同风格：屏幕底部居中小面板，选项横向一行排开，无全屏蒙层
##   2. 鼠标点击/数字键1-4/手柄LT·RT扳机左右+D-Pad备用+A选择；描述与碎片价格走tooltip
##   3. 赌博式选项带"赌"角标，稳妥式带"稳"角标；融合技能显示"融"字+金色边框
##   4. 碎片不足/前置条件不满足的选项置灰（disabled）但保留显示，不可选中确认
## 输入架构：选择输入全部经InputManager网关（TEMPLE_CHOICE上下文放行game_choice_prev/next=LT/RT、
##           ui_left/right/confirm/cancel）；
##           按钮FOCUS_NONE，选中态由_selected_index统一管理，避免内置焦点双重移动
## 数据流：Temple.interact() → 创建面板 → setup(options, player)
##         → 玩家选定 option_chosen 信号 → Temple 应用效果并消失
##         → 玩家按返回键 option_cancelled 信号 → Temple 关闭面板且神庙保留
extends Control

## ========== 预加载资源 ==========

## 卡片样式共享工具（与三选一/商店同款：粗边框+外发光+底色提亮的选中态）
## 单一来源维护卡片视觉，改一处三个面板同时生效
const ChoiceCardStyleLib = preload("res://scripts/ui/ChoiceCardStyle.gd")

## ========== 信号定义 ==========

## 选项选定信号
## 参数：option - 被选中的神庙选项资源
signal option_chosen(option: Resource)

## 玩家按返回键取消信号（手柄B/键盘ESC）：关闭面板、神庙不消失
signal option_cancelled()

## ========== 成员变量 ==========

var _options: Array = []          ## 全部选项（TempleOption资源）
var _buttons: Array[Button] = []  ## 选项按钮列表（动画/置灰用）

## 每个选项的样式集（与 _buttons 下标一一对应，来自 ChoiceCardStyleLib.build_card_styles()）
var _button_styles: Array[Dictionary] = []
var _vbox: VBoxContainer = null   ## 内部垂直容器（标题在上，选项行在下）
var _hbox: HBoxContainer = null   ## 选项水平容器（4个选项一行排开）
var _locked: bool = false         ## 防重复选择锁
var _player: Node = null          ## 交互玩家（用于价格/支付状态判定）

## 当前选中选项索引（鼠标悬停/D-Pad左右共用一个选中态，A键确认）
var _selected_index: int = -1

## ========== 选中态视觉常量 ==========

## 选中态切换动画时长（秒）；选中的具体样式由 ChoiceCardStyle 统一提供（粗边框+外发光+底色提亮）
const SELECT_TWEEN_TIME: float = 0.06
## 置灰（不可选）选项的固定灰态调制（样式框另由 ChoiceCardStyleLib.build_disabled_style() 提供）
const DISABLED_MODULATE: Color = Color(0.55, 0.55, 0.55, 0.65)
## 融合技能的金色边框/文字颜色
const FUSE_GOLD: Color = Color(1.0, 0.85, 0.2, 1.0)

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
	panel_bg.offset_top = -112.0  ## 面板自身高度约54px（标题+单行选项）
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

	## ---------- 内部布局：标题在上，选项横向一行 ----------
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 3)
	panel_bg.add_child(_vbox)

	## 标题
	var title: Label = Label.new()
	title.text = "◈ 远古神庙 ◈"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(0.75, 0.6, 1.0))
	_vbox.add_child(title)

	## 选项水平容器（与升级三选一同款横向排版，4个选项一行排开不溢出）
	_hbox = HBoxContainer.new()
	_hbox.add_theme_constant_override("separation", 6)
	_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_vbox.add_child(_hbox)

	## 入场动画初始状态
	panel_bg.modulate.a = 0.0
	var tween: Tween = create_tween()
	tween.tween_property(panel_bg, "modulate:a", 1.0, 0.15)

## _process() - 手柄LT/RT扳机(或D-Pad/键盘左右)导航、确认与取消（经InputManager网关轮询消费）
## 面板为横向一行，用game_choice_prev/next=LT/RT、键盘Q/E优先，ui_left/ui_right为备用
func _process(_delta: float) -> void:
	## 已锁定选择后不响应，防重复触发
	if _locked or _buttons.is_empty():
		return
	## 返回键（手柄B/键盘ESC）：取消本次神庙选择，神庙保留不消失
	if InputManager.is_action_just_pressed_safe("ui_cancel"):
		_cancel()
		return
	## 左移一项：手柄LT扳机 / 键盘Q / 备用D-Pad左·键盘左方向键（边界夹取不循环，自动跳过置灰项）
	if InputManager.is_action_just_pressed_safe("game_choice_prev") \
			or InputManager.is_action_just_pressed_safe("ui_left"):
		_move_selection(-1)
	## 右移一项：手柄RT扳机 / 键盘E / 备用D-Pad右·键盘右方向键
	elif InputManager.is_action_just_pressed_safe("game_choice_next") \
			or InputManager.is_action_just_pressed_safe("ui_right"):
		_move_selection(1)
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
## 参数：options - 神庙选项数组（TempleOption资源）；player - 交互玩家（用于价格/置灰判定）
func setup(options: Array, player: Node = null) -> void:
	_options = options
	_player = player
	_buttons.clear()
	_button_styles.clear()
	## 选中索引置-1：构建完成后_select_first_selectable才会真正刷新高亮（同索引会被去重跳过）
	_selected_index = -1
	for i in range(options.size()):
		var btn: Button = _create_option_button(options[i], i)
		_hbox.add_child(btn)
		_buttons.append(btn)
	## 默认高亮第一个可选选项（置灰项自动跳过；Temple.push_context自带0.2s屏蔽期已替输入防抖）
	_select_first_selectable()

## ========== 内部构建方法 ==========

## 创建单个选项按钮
## 参数：option - 神庙选项资源, index - 序号（数字键提示用）
func _create_option_button(option: Resource, index: int) -> Button:
	var btn: Button = Button.new()
	var key_hint: String = str(index + 1)
	var cost: int = option.get_cost(_player)
	var cost_text: String = "  %d碎片" % cost if cost > 0 else ""
	var is_fuse: bool = option.is_fuse_option()

	## 融合技能：显示"融"字图标+金色边框；普通选项：赌/稳角标
	if is_fuse:
		btn.text = "[%s] 融 %s%s" % [key_hint, option.display_name, cost_text]
	else:
		var gamble_tag: String = "赌" if option.is_gamble else "稳"
		btn.text = "[%s] %s %s%s" % [key_hint, gamble_tag, option.display_name, cost_text]

	## 描述与碎片价格走tooltip（减小面板占用）
	var tip: String = option.description
	if cost > 0:
		tip += "\n消耗：%d 梦境碎片" % cost
	btn.tooltip_text = tip
	btn.custom_minimum_size = Vector2(150, 32)
	btn.focus_mode = Control.FOCUS_NONE

	## 按钮样式：由共享工具统一生成（强调色=选项主题色；融合技能用金色强调）
	## 先套"未选中"组（1px 细边框）；选中态由 _refresh_selection_visual 切换为粗边框+外发光
	var accent: Color = FUSE_GOLD if is_fuse else option.option_color
	var styles: Dictionary = ChoiceCardStyleLib.build_card_styles(accent)
	ChoiceCardStyleLib.apply_card_styles(btn, styles, false)
	_button_styles.append(styles)

	## 置灰样式：碎片不足/前置条件不满足时灰底+灰边框，配合 disabled=true 使用
	btn.add_theme_stylebox_override("disabled", ChoiceCardStyleLib.build_disabled_style())

	## 字体颜色跟随选项主题色（融合技能=金色）
	btn.add_theme_color_override("font_color", FUSE_GOLD if is_fuse else option.option_color)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_color_override("font_disabled_color", Color(0.55, 0.55, 0.55, 0.7))
	btn.add_theme_font_size_override("font_size", 13)

	## 不可选（碎片不足/前置条件不满足）→ 置灰禁用；点击/确认均被拦截
	btn.disabled = not option.can_select(_player)

	## 点击选择
	btn.pressed.connect(_choose.bind(index))
	## 缩放以按钮中心为原点（选中放大时不偏移）
	btn.pivot_offset = btn.custom_minimum_size * 0.5
	## 鼠标悬停即同步选中索引：键鼠与手柄共用同一套选中高亮/确认逻辑
	btn.mouse_entered.connect(_set_selection.bind(index))
	return btn

## 判断指定索引是否可选（未置灰）
func _is_selectable(index: int) -> bool:
	return index >= 0 and index < _buttons.size() and not _buttons[index].disabled

## 鼠标悬停入口：仅可选选项才更新选中索引（置灰项不可悬停选中）
func _set_selection(index: int) -> void:
	if not _is_selectable(index):
		return
	_set_selection_absolute(index)

## 键盘/手柄导航：按方向移动到下一个可选选项（边界夹取不循环，自动跳过置灰项）
## 参数：direction - -1左移 / +1右移
func _move_selection(direction: int) -> void:
	if _buttons.is_empty():
		return
	var idx: int = _selected_index if _selected_index >= 0 else 0
	var guard: int = 0
	while guard < _buttons.size():
		idx += direction
		## 到达边界无可选：保持原选中不变
		if idx < 0 or idx >= _buttons.size():
			return
		if _is_selectable(idx):
			_set_selection_absolute(idx)
			return
		guard += 1

## 设置当前选中选项（绝对索引，同索引去重跳过）
func _set_selection_absolute(index: int) -> void:
	if index < 0 or index >= _buttons.size():
		return
	if index == _selected_index:
		return
	_selected_index = index
	_refresh_selection_visual()

## 默认高亮第一个可选选项（setup构建完成后调用，自动跳过置灰项）
func _select_first_selectable() -> void:
	for i in range(_buttons.size()):
		if _is_selectable(i):
			_set_selection_absolute(i)
			return

## 刷新全部选项的选中态视觉（选中=粗边框+外发光+底色提亮+放大，其余=1px 细边框常态；置灰项固定灰态）
## 具体样式由 ChoiceCardStyle 统一提供，三选一/商店/神庙三处表现完全一致
func _refresh_selection_visual() -> void:
	for i in range(_buttons.size()):
		var btn: Button = _buttons[i]
		## 置灰项不参与高亮动画，固定灰态
		if btn.disabled:
			btn.modulate = DISABLED_MODULATE
			btn.scale = Vector2.ONE
			continue
		if i >= _button_styles.size():
			continue
		ChoiceCardStyleLib.refresh_card(btn, _button_styles[i], i == _selected_index, SELECT_TWEEN_TIME)

## 选定选项（统一入口：鼠标点击/数字键/导航后A键确认）
func _choose(index: int) -> void:
	if _locked or index < 0 or index >= _options.size():
		return
	## 置灰项不可选择（碎片不足/前置条件不满足）
	if _buttons[index].disabled:
		return
	_locked = true
	var chosen: Resource = _options[index]
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	option_chosen.emit(chosen)

## 取消本次神庙选择（手柄B/键盘ESC）
## 与 _choose 共用 _locked 防重入；取消不消耗神庙，由 Temple 负责关闭面板并保留神庙
func _cancel() -> void:
	if _locked:
		return
	_locked = true
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	option_cancelled.emit()
