## TemplePanel.gd - 神庙选项面板（紧凑底栏样式，与商店同款横向排版）
## 职责：展示神庙选项（数据驱动，数量不定）；支持结果反馈视图与返回键取消
## 设计意图：
##   1. 与 ShopPanel 同风格：屏幕底部居中小面板，选项横向一行排开，无全屏蒙层
##   2. 鼠标点击/数字键1-4/手柄LT·RT扳机左右+D-Pad备用+A选择；描述与碎片价格走tooltip
##   3. 赌博式选项带"赌"角标，稳妥式带"稳"角标
##   4. 碎片不足/前置条件不满足的选项置灰（disabled）但保留显示，不可选中确认
##   5. 双模式：OPTIONS=选项选择；RESULT=结果反馈（强化/融合等随机结果必须让玩家看清"发生了什么"）
## 输入架构：选择输入全部经InputManager网关（TEMPLE_CHOICE上下文放行game_choice_prev/next=LT/RT、
##           ui_left/right/confirm/cancel）；
##           按钮FOCUS_NONE，选中态由_selected_index统一管理，避免内置焦点双重移动
## 数据流：Temple.interact() → 创建面板 → setup(options, player)
##         → 玩家选定 option_chosen 信号 → Temple 应用效果 → show_result(反馈文本)
##         → 玩家确认 result_confirmed 信号 → Temple 关闭面板并消失
##         → 玩家按返回键 option_cancelled 信号 → Temple 关闭面板且神庙保留
extends Control

## ========== 预加载资源 ==========

## 卡片样式共享工具（与商店同款：粗边框+外发光+底色提亮的选中态）
## 单一来源维护卡片视觉，改一处两个面板同时生效
const ChoiceCardStyleLib = preload("res://scripts/ui/ChoiceCardStyle.gd")

## ========== 信号定义 ==========

## 选项选定信号
## 参数：option - 被选中的神庙选项资源
signal option_chosen(option: Resource)

## 玩家按返回键取消信号（手柄B/键盘ESC）：关闭面板、神庙不消失
signal option_cancelled()

## 结果反馈确认信号：玩家读完结果反馈后确认（A键/确认键/点击确定按钮）
## 语义：Temple 收到后关闭面板并按 apply() 的成功与否决定神庙是否消散
signal result_confirmed()

## ========== 面板模式 ==========

## OPTIONS=选项选择模式；RESULT=结果反馈模式（展示 apply() 产出的反馈文本，等待玩家确认）
enum PanelMode { OPTIONS, RESULT }

## ========== 成员变量 ==========

var _options: Array = []          ## 全部选项（TempleOption资源）
var _buttons: Array[Button] = []  ## 选项按钮列表（动画/置灰用）

## 每个选项的样式集（与 _buttons 下标一一对应，来自 ChoiceCardStyleLib.build_card_styles()）
var _button_styles: Array[Dictionary] = []
var _panel_bg: PanelContainer = null  ## 底部居中面板容器（提为成员，供结果视图切换高度/显隐）
var _vbox: VBoxContainer = null   ## 内部垂直容器（标题在上，选项行/结果视图在下）
var _hbox: HBoxContainer = null   ## 选项水平容器（选项一行排开）
var _locked: bool = false         ## 防重复选择锁
var _player: Node = null          ## 交互玩家（用于价格/支付状态判定）

## 当前面板模式（OPTIONS/RESULT），决定 _process 与输入守卫走哪套分支
var _mode: int = PanelMode.OPTIONS

## ========== 结果反馈视图控件（RESULT 模式使用，初始隐藏） ==========

var _result_box: VBoxContainer = null   ## 结果视图容器（反馈文本 + 确定按钮）
var _result_label: Label = null         ## 结果反馈文本（自动换行）
var _result_button: Button = null       ## 确定按钮（点击后发 result_confirmed）

## 当前选中选项索引（鼠标悬停/D-Pad左右共用一个选中态，A键确认）
var _selected_index: int = -1

## ========== 选中态视觉常量 ==========

## 选中态切换动画时长（秒）；选中的具体样式由 ChoiceCardStyle 统一提供（粗边框+外发光+底色提亮）
const SELECT_TWEEN_TIME: float = 0.06
## 置灰（不可选）选项的固定灰态调制（样式框另由 ChoiceCardStyleLib.build_disabled_style() 提供）
const DISABLED_MODULATE: Color = Color(0.55, 0.55, 0.55, 0.65)

## ========== 生命周期方法 ==========

## _ready() - 构建紧凑底栏UI
func _ready() -> void:
	## 根Control全屏（用于捕获键盘事件），鼠标穿透不拦截游戏点击
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	## ---------- 底部居中面板容器 ----------
	_panel_bg = PanelContainer.new()
	add_child(_panel_bg)
	## 锚定到屏幕底部居中，底部留出 56px 安全区（底部状态栏高28px + 间距28px）
	## 避免与 GameHUD 底部常驻状态栏重叠，同时保证面板完整显示不贴边
	_panel_bg.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_panel_bg.offset_top = -112.0  ## 面板自身高度约54px（标题+单行选项）
	_panel_bg.offset_bottom = -58.0  ## 距屏幕底边 58px
	## 内容超出固定高度时的增长方向：向上（垂直）+ 左右对称（水平）
	## 结果反馈文本为多行，需向上撑开而不遮挡/溢出屏幕底部
	_panel_bg.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_panel_bg.grow_horizontal = Control.GROW_DIRECTION_BOTH

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
	_panel_bg.add_theme_stylebox_override("panel", sb)

	## ---------- 内部布局：标题在上，选项横向一行 ----------
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 3)
	_panel_bg.add_child(_vbox)

	## 标题
	var title: Label = Label.new()
	title.text = "◈ 远古神庙 ◈"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(0.75, 0.6, 1.0))
	_vbox.add_child(title)

	## 选项水平容器（与商店同款横向排版，选项一行排开不溢出）
	_hbox = HBoxContainer.new()
	_hbox.add_theme_constant_override("separation", 6)
	_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_vbox.add_child(_hbox)

	## 结果反馈视图（强化/融合随机结果展示；初始隐藏，_choose 后由 show_result 展示）
	_build_result_view()

	## 入场动画初始状态
	_panel_bg.modulate.a = 0.0
	var tween: Tween = create_tween()
	tween.tween_property(_panel_bg, "modulate:a", 1.0, 0.15)

## 构建结果反馈视图：多行反馈文本 + 确定按钮（加入 _vbox，初始隐藏）
## 设计意图：与选项行互斥显示——OPTIONS 模式只看选项行，RESULT 模式只看本视图
func _build_result_view() -> void:
	_result_box = VBoxContainer.new()
	_result_box.add_theme_constant_override("separation", 6)
	_result_box.visible = false
	_vbox.add_child(_result_box)

	## 反馈文本（自动换行，限宽保证换行美观且与选项行宽度相近）
	_result_label = Label.new()
	_result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_label.custom_minimum_size = Vector2(360, 0)
	_result_label.add_theme_color_override("font_color", Color(0.92, 0.9, 1.0))
	_result_label.add_theme_font_size_override("font_size", 13)
	_result_box.add_child(_result_label)

	## 确定按钮（点击/确认键均可）
	_result_button = Button.new()
	_result_button.text = "确定"
	_result_button.focus_mode = Control.FOCUS_NONE
	_result_button.custom_minimum_size = Vector2(96, 30)
	_result_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_result_button.pressed.connect(_confirm_result)
	_result_box.add_child(_result_button)

## _process() - 手柄LT/RT扳机(或D-Pad/键盘左右)导航、确认与取消（经InputManager网关轮询消费）
## 面板为横向一行，用game_choice_prev/next=LT/RT、键盘Q/E优先，ui_left/ui_right为备用
## RESULT 模式下只响应"确认"（读到反馈后关闭），不响应左右导航
func _process(_delta: float) -> void:
	## 结果反馈模式：等待玩家确认/取消后关闭反馈视图
	if _mode == PanelMode.RESULT:
		if InputManager.is_action_just_pressed_safe("ui_confirm") \
				or InputManager.is_action_just_pressed_safe("ui_cancel"):
			_confirm_result()
		return
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

## _unhandled_input() - 数字键1/2/3/4快捷选择（仅选项模式）
func _unhandled_input(event: InputEvent) -> void:
	if _mode != PanelMode.OPTIONS or _locked:
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

## 切换到结果反馈视图（Temple 在 option.apply() 之后调用）
## 参数：message - 结果反馈文本（强化/融合的结果，由 TempleOption.get_result_message() 提供）
## 设计意图：强化/融合结果随机，必须让玩家明确看到"哪件装备被强化/融合出了什么"，
##          故隐藏选项行、展示反馈文本，等待玩家确认（result_confirmed）后再由 Temple 关闭面板
func show_result(message: String) -> void:
	_mode = PanelMode.RESULT
	## 解锁：结果视图只需响应"确认关闭"，_locked 保持 false 以便 _confirm_result 正常触发
	_locked = false
	## 选项行隐藏，结果视图显示
	_hbox.visible = false
	_result_label.text = message if message != "" else "神庙的馈赠已生效……"
	_result_box.visible = true
	## 淡入反馈视图（与入场动画同风格）
	_result_box.modulate.a = 0.0
	var tween: Tween = create_tween()
	tween.tween_property(_result_box, "modulate:a", 1.0, 0.12)

## ========== 内部构建方法 ==========

## 创建单个选项按钮
## 参数：option - 神庙选项资源, index - 序号（数字键提示用）
func _create_option_button(option: Resource, index: int) -> Button:
	var btn: Button = Button.new()
	var key_hint: String = str(index + 1)
	var cost: int = option.get_cost(_player)
	var cost_text: String = "  %d碎片" % cost if cost > 0 else ""

	## 普通选项：赌/稳角标
	var gamble_tag: String = "赌" if option.is_gamble else "稳"
	btn.text = "[%s] %s %s%s" % [key_hint, gamble_tag, option.display_name, cost_text]

	## 描述与碎片价格走tooltip（减小面板占用）
	var tip: String = option.description
	if cost > 0:
		tip += "\n消耗：%d 梦境碎片" % cost
	btn.tooltip_text = tip
	btn.custom_minimum_size = Vector2(150, 32)
	btn.focus_mode = Control.FOCUS_NONE

	## 按钮样式：由共享工具统一生成（强调色=选项主题色）
	## 先套"未选中"组（1px 细边框）；选中态由 _refresh_selection_visual 切换为粗边框+外发光
	var accent: Color = option.option_color
	var styles: Dictionary = ChoiceCardStyleLib.build_card_styles(accent)
	ChoiceCardStyleLib.apply_card_styles(btn, styles, false)
	_button_styles.append(styles)

	## 置灰样式：碎片不足/前置条件不满足时灰底+灰边框，配合 disabled=true 使用
	btn.add_theme_stylebox_override("disabled", ChoiceCardStyleLib.build_disabled_style())

	## 字体颜色跟随选项主题色
	btn.add_theme_color_override("font_color", option.option_color)
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
## 具体样式由 ChoiceCardStyle 统一提供，商店/神庙两处表现完全一致
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

## 选定选项（统一入口：鼠标点击/数字键/导航后A键确认；仅选项模式）
func _choose(index: int) -> void:
	if _mode != PanelMode.OPTIONS or _locked or index < 0 or index >= _options.size():
		return
	## 置灰项不可选择（碎片不足/前置条件不满足）
	if _buttons[index].disabled:
		return
	_locked = true
	var chosen: Resource = _options[index]
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	option_chosen.emit(chosen)

## 取消本次神庙选择（手柄B/键盘ESC；仅选项模式）
## 与 _choose 共用 _locked 防重入；取消不消耗神庙，由 Temple 负责关闭面板并保留神庙
func _cancel() -> void:
	if _mode != PanelMode.OPTIONS or _locked:
		return
	_locked = true
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	option_cancelled.emit()

## 确认结果反馈（读完反馈后关闭；点击"确定"按钮 / A键 / B键均可触发）
## 触发后由 Temple 关闭面板并按 apply() 结果决定神庙是否消散
func _confirm_result() -> void:
	if _mode != PanelMode.RESULT or _locked:
		return
	_locked = true
	if AudioManager:
		AudioManager.play("ui_click", 0.7)
	result_confirmed.emit()
