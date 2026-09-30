## ShopPanel.gd - 商店购买面板（紧凑底栏样式，与神庙同款横向排版）
## 职责：展示商店三大固定服务（恢复健康 / 随机装备 / 合成装备），
##       玩家选定后发出购买/合成信号、按取消关闭商店
## 设计意图：
##   1. 与 TemplePanel 同风格：屏幕底部居中面板，选项横向一行排开
##   2. 主视图固定三选项：恢复健康、随机装备（来自 Shop 的可购买服务）+ 合成装备（入口）
##   3. 点击/确认「合成装备」后，在主视图中就地展开合成子视图（6 个槽位按钮 + 返回），
##      相当于把原先「合成」页签下的内容直接弹出，不再用页签切换
##   4. 提示栏实时显示当前选中项的说明（随机装备含稀有度概率分布）；标题栏显示碎片余额
##   5. 合成成功后展示结果反馈视图（与神庙融合同款），玩家确认后回到合成子视图
## 输入架构：选择输入全部经 InputManager 网关（SHOP_CHOICE 上下文放行
##           game_choice_prev/next=LT/RT、键盘Q/E，ui_left/right 为备用，
##           ui_confirm/game_confirm 确认，ui_cancel 返回/关闭）
## 数据流：Shop.interact() → 创建面板 → setup(products, player)
##        → 玩家选定 product_selected → Shop 扣款并应用效果
##        → 玩家选定 craft_requested → Shop 校验碎片/背包并生成装备 → show_craft_result 反馈结果
##        → 玩家按ESC/点关闭按钮 → close_requested → Shop 恢复游戏并关闭面板
## 说明：一键批量分解在暂停菜单的「状态与装备」面板（操作对象是背包，不属商店职责）
extends Control

## ========== 预加载资源 ==========

## 卡片样式共享工具（与神庙面板同款：粗边框+外发光+底色提亮的选中态）
const ChoiceCardStyleLib = preload("res://scripts/ui/ChoiceCardStyle.gd")

## 装备回收/合成数值口径（合成按钮显示消耗数、判定可用态）
const EquipmentRecyclerLib = preload("res://scripts/resources/equipment/EquipmentRecycler.gd")

## ========== 常量 ==========

## 槽位名称（下标 = EquipmentData.Slot，与合成按钮一一对应）
const SLOT_NAMES := ["武器", "护甲", "鞋子", "盾牌", "戒指", "法宝"]

## 「合成装备」在主视图按钮中的下标（0=恢复健康 1=随机装备 2=合成装备）
const CRAFT_OPTION_INDEX: int = 2

## ========== 信号定义 ==========

## 玩家选定某服务购买（未扣款，由 Shop 校验余额并扣款）
## 参数：product - 被选中的 ShopProduct 资源
signal product_selected(product: Resource)

## 玩家请求合成某槽位装备（消耗该槽位碎片，由 Shop 执行校验/扣碎片/生成/入背包）
## 参数：slot - 目标槽位（EquipmentData.Slot）
signal craft_requested(slot: int)

## 玩家请求关闭商店（ESC/B 或关闭按钮）
signal close_requested()

## ========== 成员变量 ==========

var _products: Array = []                    ## Shop 提供的可购买服务（恢复健康/随机装备）
var _main_buttons: Array[Button] = []        ## 主视图固定三选项按钮（恢复健康/随机装备/合成装备）
var _main_styles: Array[Dictionary] = []     ## 主视图按钮样式集（与 _main_buttons 下标一一对应）
var _vbox: VBoxContainer = null              ## 内部垂直容器
var _main_hbox: HBoxContainer = null         ## 主视图选项行（三选项一行排开）
var _craft_box: VBoxContainer = null         ## 合成子视图容器（合成按钮行 + 返回，与主视图互斥显示）
var _craft_hbox: HBoxContainer = null        ## 合成按钮行（6 个槽位合成按钮）
var _title: Label = null                     ## 标题（含碎片余额，购买后刷新）
var _hint_label: Label = null                ## 提示栏（显示当前选中项说明，含稀有度概率分布）

## ========== 结果反馈视图控件（合成成功后使用，初始隐藏） ==========

var _result_box: VBoxContainer = null        ## 结果视图容器（反馈文本 + 确定按钮）
var _result_label: Label = null              ## 结果反馈文本（自动换行）
var _result_active: bool = false             ## 是否处于结果反馈视图（阻断选择/导航，仅响应确认）

## 当前选中索引（对应当前视图的按钮列表：主视图=三选项，合成视图=槽位按钮）
var _selected_index: int = -1

## 是否处于合成子视图（true=显示合成按钮行，false=显示主视图三选项）
var _craft_active: bool = false

## 合成按钮列表与样式集（下标 = EquipmentData.Slot；与 _craft_hbox 子节点一一对应）
var _craft_buttons: Array[Button] = []
var _craft_styles: Array[Dictionary] = []

## 上次各槽位碎片数（用于变化检测，避免每帧无谓刷新合成按钮文本/可用态）
var _last_craft_counts: Array[int] = []

## 玩家引用（读取碎片余额；购买成功后 Shop 会调 refresh_after_purchase 刷新显示）
var _player = null

## 上次显示的碎片余额（用于变化检测，避免每帧重复 set text）
var _last_fragments: int = -1

## ========== 选中态视觉常量 ==========

## 选中态切换动画时长（秒）；选中的具体样式由 ChoiceCardStyle 统一提供
const SELECT_TWEEN_TIME: float = 0.06

## ========== 生命周期方法 ==========

## _ready() - 构建紧凑底栏 UI
func _ready() -> void:
	## 根 Control 全屏（用于捕获键盘事件），鼠标穿透不拦截游戏点击
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	## ---------- 底部居中面板容器 ----------
	var panel_bg: PanelContainer = PanelContainer.new()
	add_child(panel_bg)
	panel_bg.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	panel_bg.offset_top = -228.0  ## 面板含标题+提示栏+选项行+关闭按钮，高度约180px
	panel_bg.offset_bottom = -46.0
	## 固定最小宽度：选项行(3项)与合成行(6槽位)宽度不同，统一底线避免切换视图时面板横向跳变
	panel_bg.custom_minimum_size = Vector2(700, 0)

	## 面板背景样式：半透明深色 + 金色细边框 + 圆角
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.08, 0.94)
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_color = Color(0.95, 0.75, 0.3, 0.6)  ## 金色边框（区别于神庙紫金）
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	panel_bg.add_theme_stylebox_override("panel", sb)

	## ---------- 内部布局：标题 + 提示栏 + 选项行 + 合成子视图 + 关闭按钮 ----------
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 4)
	panel_bg.add_child(_vbox)

	## 标题（含碎片余额，余额变化时刷新）
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	_title.text = "✦ 梦境商店 ✦"
	_vbox.add_child(_title)

	## 提示栏（选中项说明；随机装备在此展示稀有度概率分布）
	_hint_label = Label.new()
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.custom_minimum_size = Vector2(660, 0)
	_hint_label.add_theme_color_override("font_color", Color(0.78, 0.82, 0.9))
	_hint_label.add_theme_font_size_override("font_size", 12)
	_vbox.add_child(_hint_label)

	## 主视图选项行（三选项：恢复健康 / 随机装备 / 合成装备）
	_main_hbox = HBoxContainer.new()
	_main_hbox.add_theme_constant_override("separation", 6)
	_main_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_vbox.add_child(_main_hbox)

	## 合成子视图（初始隐藏；点击「合成装备」后与主视图互斥显示）
	_craft_box = VBoxContainer.new()
	_craft_box.add_theme_constant_override("separation", 4)
	_craft_box.visible = false
	_vbox.add_child(_craft_box)
	_craft_hbox = HBoxContainer.new()
	_craft_hbox.add_theme_constant_override("separation", 6)
	_craft_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_craft_box.add_child(_craft_hbox)
	_build_craft_buttons()
	## 合成子视图返回按钮（ESC/B 同效，鼠标用户可点）
	var back_btn: Button = Button.new()
	back_btn.text = "返回 (ESC)"
	back_btn.focus_mode = Control.FOCUS_NONE
	back_btn.custom_minimum_size = Vector2(120, 24)
	back_btn.add_theme_font_size_override("font_size", 12)
	back_btn.pressed.connect(_close_craft_view)
	_craft_box.add_child(back_btn)

	## 结果反馈视图（合成成功后展示；初始隐藏，与主视图/合成视图互斥显示）
	_build_result_view()

	## 关闭按钮（ESC/B 同效）
	var close_btn: Button = Button.new()
	close_btn.text = "离开商店 (ESC)"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.custom_minimum_size = Vector2(140, 24)
	close_btn.add_theme_font_size_override("font_size", 12)
	close_btn.pressed.connect(close_requested.emit)
	_vbox.add_child(close_btn)

	## 入场动画初始状态
	panel_bg.modulate.a = 0.0
	var tween: Tween = create_tween()
	tween.tween_property(panel_bg, "modulate:a", 1.0, 0.15)

## _process() - 左右导航、确认（购买/合成/展开）、返回/关闭（经 InputManager 网关消费）
func _process(_delta: float) -> void:
	## 刷新标题上的碎片余额（仅在变化时 set text，避免每帧无谓刷新）
	_update_fragment_label()
	## 刷新合成按钮的碎片数与可用态（仅在变化时刷新）
	_refresh_craft_buttons()

	## 结果反馈视图：仅响应确认/取消关闭，不响应左右导航与购买
	if _result_active:
		if InputManager.is_action_just_pressed_safe("ui_confirm") \
				or InputManager.is_action_just_pressed_safe("ui_cancel"):
			_close_result()
		return

	## 当前视图无可选项：仅保留返回/关闭
	var buttons: Array[Button] = _active_buttons()
	if buttons.is_empty():
		if InputManager.is_action_just_pressed_safe("ui_cancel"):
			_cancel()
		return

	## 左移一项：手柄LT扳机 / 键盘Q / 备用D-Pad左·键盘左方向键（边界夹取不循环）
	if InputManager.is_action_just_pressed_safe("game_choice_prev") \
			or InputManager.is_action_just_pressed_safe("ui_left"):
		_set_selection(_selected_index - 1)
	## 右移一项：手柄RT扳机 / 键盘E / 备用D-Pad右·键盘右方向键
	elif InputManager.is_action_just_pressed_safe("game_choice_next") \
			or InputManager.is_action_just_pressed_safe("ui_right"):
		_set_selection(_selected_index + 1)

	## A键/Space/Enter：购买/展开合成/合成当前选中槽位
	if InputManager.is_action_just_pressed_safe("ui_confirm") \
			or InputManager.is_action_just_pressed_safe("game_confirm"):
		_confirm(_selected_index)
	## ESC/B：合成视图内返回主视图；主视图内关闭商店
	if InputManager.is_action_just_pressed_safe("ui_cancel"):
		_cancel()

## _unhandled_input() - 数字键 1/2/3 快捷操作（仅主视图生效：1恢复健康 2随机装备 3合成装备）
func _unhandled_input(event: InputEvent) -> void:
	## 合成视图下数字键不参与快捷操作（槽位按钮用左右导航 + 确认）
	if _craft_active:
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var index: int = -1
	match event.physical_keycode:
		KEY_1: index = 0
		KEY_2: index = 1
		KEY_3: index = CRAFT_OPTION_INDEX
	if index >= 0:
		_confirm(index)

## ========== 对外接口 ==========

## 初始化面板显示（Shop 创建面板后调用）
## 参数：products - 可购买服务数组；player - 玩家节点（读取碎片余额）
func setup(products: Array, player: Node) -> void:
	_products = products
	_player = player
	_build_main_buttons()
	## 默认停在主视图并高亮第一项（Shop.push_context 自带 0.2s 屏蔽期，已替输入防抖）
	_craft_active = false
	_main_hbox.visible = true
	_craft_box.visible = false
	_selected_index = -1
	_set_selection(0)
	## 立即刷新一次余额与合成按钮显示
	_last_fragments = -1
	_last_craft_counts.clear()
	_update_fragment_label()
	_refresh_craft_buttons(true)

## 购买成功后刷新碎片余额（Shop 扣款完成后调用）
func refresh_after_purchase() -> void:
	_last_fragments = -1
	_update_fragment_label()

## 合成后刷新合成按钮（碎片数、按钮可用态变化；Shop 完成后调用）
func refresh_after_craft() -> void:
	_last_fragments = -1
	_update_fragment_label()
	_refresh_craft_buttons(true)

## 操作失败提示（Shop 判定失败时调用）：标题短暂变红提醒
func notify_failure() -> void:
	if _title == null:
		return
	var t: Tween = create_tween()
	t.tween_property(_title, "modulate", Color(1.0, 0.35, 0.35), 0.12)
	t.tween_property(_title, "modulate", Color.WHITE, 0.12)

## 展示合成结果反馈（Shop 合成成功后调用）
## 参数：message - 结果反馈文本（如"合成成功！\n获得「史诗武器」\n· ..."）
## 设计意图：与神庙融合同款结果视图——隐藏主视图/合成视图，展示反馈文本，
##          玩家确认（确定按钮/A键/ESC）后回到合成子视图，继续合成或返回
func show_craft_result(message: String) -> void:
	if _result_box == null:
		return
	_result_active = true
	## 合成视图与结果视图互斥显示（主视图此时本就隐藏）
	_craft_box.visible = false
	_main_hbox.visible = false
	_result_label.text = message if message != "" else "合成完成。"
	_result_box.visible = true
	## 淡入反馈视图（与入场动画同风格）
	_result_box.modulate.a = 0.0
	var tween: Tween = create_tween()
	tween.tween_property(_result_box, "modulate:a", 1.0, 0.12)

## ========== 内部构建方法 ==========

## 构建主视图三选项按钮（前两项来自可购买服务，第三项为合成装备入口）
func _build_main_buttons() -> void:
	_main_buttons.clear()
	_main_styles.clear()
	## 前两项：来自 Shop 的可购买服务（恢复健康 / 随机装备）
	for i in range(_products.size()):
		var btn: Button = _create_service_button(_products[i], i)
		_main_hbox.add_child(btn)
		_main_buttons.append(btn)
	## 第三项：合成装备（固定入口，确认后展开合成子视图）
	var craft_btn: Button = _create_craft_entry_button(CRAFT_OPTION_INDEX)
	_main_hbox.add_child(craft_btn)
	_main_buttons.append(craft_btn)

## 创建单个可购买服务按钮
## 参数：product - 服务资源（ShopProduct），index - 主视图下标（数字键提示用）
func _create_service_button(product: Resource, index: int) -> Button:
	var btn: Button = Button.new()
	var price: int = int(product.price)
	btn.text = "%d.%s  [%d碎片]" % [index + 1, product.display_name, price]
	## 描述走 tooltip 与顶部提示栏（减小面板占用）
	btn.tooltip_text = str(product.description)
	btn.custom_minimum_size = Vector2(200, 34)
	btn.focus_mode = Control.FOCUS_NONE

	## 按钮样式：由共享工具统一生成（强调色=服务主题色）
	## 这里先套"未选中"组（1px 细边框）；选中态由 _refresh_selection_visual 切换为粗边框+外发光
	var styles: Dictionary = ChoiceCardStyleLib.build_card_styles(product.product_color)
	ChoiceCardStyleLib.apply_card_styles(btn, styles, false)
	_main_styles.append(styles)

	## 字体颜色跟随服务主题色
	btn.add_theme_color_override("font_color", product.product_color)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_font_size_override("font_size", 13)

	## 点击购买 / 鼠标悬停同步选中索引
	btn.pressed.connect(_confirm.bind(index))
	btn.pivot_offset = btn.custom_minimum_size * 0.5
	btn.mouse_entered.connect(_set_selection.bind(index))
	return btn

## 创建「合成装备」入口按钮（主视图第三项）
## 参数：index - 主视图下标（固定为 CRAFT_OPTION_INDEX）
func _create_craft_entry_button(index: int) -> Button:
	var btn: Button = Button.new()
	btn.text = "%d.%s" % [index + 1, "合成装备"]
	btn.tooltip_text = "消耗各槽位装备碎片 + 梦境碎片，合成一件保底稀有装备"
	btn.custom_minimum_size = Vector2(200, 34)
	btn.focus_mode = Control.FOCUS_NONE

	## 按钮样式：统一金色强调（合成=成长向操作）
	var styles: Dictionary = ChoiceCardStyleLib.build_card_styles(Color(0.95, 0.75, 0.3))
	ChoiceCardStyleLib.apply_card_styles(btn, styles, false)
	_main_styles.append(styles)
	btn.add_theme_color_override("font_color", Color(1.0, 0.9, 0.7))
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_font_size_override("font_size", 13)

	## 点击展开合成子视图 / 鼠标悬停同步选中
	btn.pressed.connect(_confirm.bind(index))
	btn.pivot_offset = btn.custom_minimum_size * 0.5
	btn.mouse_entered.connect(_set_selection.bind(index))
	return btn

## 设置当前选中项（鼠标悬停与 LT·RT 导航的唯一入口）
func _set_selection(index: int) -> void:
	var buttons: Array[Button] = _active_buttons()
	if buttons.is_empty():
		return
	var new_index: int = clampi(index, 0, buttons.size() - 1)
	if new_index == _selected_index:
		return
	_selected_index = new_index
	_refresh_selection_visual()

## 刷新当前视图全部条目的选中态视觉（选中=粗边框+外发光+底色提亮+放大，其余=1px 细边框常态）
## 具体样式由 ChoiceCardStyle 统一提供，商店/神庙两处表现完全一致
func _refresh_selection_visual() -> void:
	var buttons: Array[Button] = _active_buttons()
	var styles: Array[Dictionary] = _active_styles()
	for i in range(buttons.size()):
		if i >= styles.size():
			continue
		ChoiceCardStyleLib.refresh_card(buttons[i], styles[i], i == _selected_index, SELECT_TWEEN_TIME)
	## 选中项变化 → 同步刷新提示栏文案（合成视图/随机装备各展示对应说明）
	_refresh_hint()

## 确认当前选中项（鼠标点击 / 数字键 / 导航后A键都走这里）
## 合成视图 → 合成该槽位装备
## 主视图 → 合成装备展开子视图；其余两项发出购买信号
func _confirm(index: int) -> void:
	if _craft_active:
		if index < 0 or index >= _craft_buttons.size():
			return
		craft_requested.emit(index)
		return
	## 合成装备入口：展开合成子视图
	if index == CRAFT_OPTION_INDEX:
		_open_craft_view()
		return
	## 其余为可购买服务（主视图下标与 _products 对齐）
	if index < 0 or index >= _products.size():
		return
	product_selected.emit(_products[index])

## 取消（ESC/B）：合成视图内返回主视图，主视图内关闭商店
func _cancel() -> void:
	if _craft_active:
		_close_craft_view()
	else:
		close_requested.emit()

## ========== 视图切换与合成按钮 ==========

## 当前视图的按钮列表（主视图=三选项，合成视图=槽位合成按钮）
func _active_buttons() -> Array[Button]:
	if _craft_active:
		return _craft_buttons
	return _main_buttons

## 当前视图的样式集列表（与 _active_buttons 下标一一对应）
func _active_styles() -> Array[Dictionary]:
	if _craft_active:
		return _craft_styles
	return _main_styles

## 展开合成子视图（点击/确认「合成装备」）：隐藏主视图、显示合成按钮行，选中重置到首槽位
func _open_craft_view() -> void:
	_craft_active = true
	_main_hbox.visible = false
	_craft_box.visible = true
	_selected_index = -1
	_set_selection(0)

## 关闭合成子视图（ESC/B）：回到主视图并高亮「合成装备」入口
func _close_craft_view() -> void:
	_craft_active = false
	_craft_box.visible = false
	_main_hbox.visible = true
	_selected_index = -1
	_set_selection(CRAFT_OPTION_INDEX)

## 关闭结果反馈视图（确定按钮/A键/ESC）：回到合成子视图，便于继续合成
func _close_result() -> void:
	if not _result_active:
		return
	_result_active = false
	_result_box.visible = false
	## 回到合成子视图（合成上下文仍为 _craft_active=true，主视图保持隐藏）
	_craft_box.visible = true
	_main_hbox.visible = false
	_selected_index = -1
	_set_selection(0)

## 刷新提示栏文案（合成视图显示合成说明；主视图显示选中服务描述）
func _refresh_hint() -> void:
	if _hint_label == null:
		return
	var text: String = ""
	if _craft_active:
		text = "选择要合成的槽位：消耗 %d 个该槽位装备碎片 + %d 梦境碎片，合成一件保底稀有装备" \
			% [int(EquipmentRecyclerLib.CRAFT_FRAGMENT_COST), int(EquipmentRecyclerLib.CRAFT_DREAM_COST)]
	elif _selected_index >= 0 and _selected_index < _products.size():
		text = str(_products[_selected_index].description)
	else:
		text = "消耗各槽位装备碎片，合成一件保底稀有的同槽位装备"
	_hint_label.text = text

## 构建结果反馈视图：多行反馈文本 + 确定按钮（加入 _vbox，初始隐藏）
## 设计意图：与神庙面板同款——合成成功后隐藏选项/合成按钮，只展示结果反馈
func _build_result_view() -> void:
	_result_box = VBoxContainer.new()
	_result_box.add_theme_constant_override("separation", 6)
	_result_box.visible = false
	_vbox.add_child(_result_box)

	## 反馈文本（自动换行，限宽保证换行美观且与选项行宽度相近）
	_result_label = Label.new()
	_result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_label.custom_minimum_size = Vector2(420, 0)
	_result_label.add_theme_color_override("font_color", Color(0.92, 0.9, 1.0))
	_result_label.add_theme_font_size_override("font_size", 13)
	_result_box.add_child(_result_label)

	## 确定按钮（点击/确认键均可）
	var ok_btn: Button = Button.new()
	ok_btn.text = "确定"
	ok_btn.focus_mode = Control.FOCUS_NONE
	ok_btn.custom_minimum_size = Vector2(96, 30)
	ok_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ok_btn.pressed.connect(_close_result)
	_result_box.add_child(ok_btn)

## 构建合成子视图的按钮（仅在 _ready 构建一次）：6 个槽位合成按钮
func _build_craft_buttons() -> void:
	_craft_buttons.clear()
	_craft_styles.clear()
	for slot in range(SLOT_NAMES.size()):
		var btn: Button = _create_craft_button(slot)
		_craft_hbox.add_child(btn)
		_craft_buttons.append(btn)

## 创建单个槽位合成按钮
## 参数：slot - 槽位下标（EquipmentData.Slot，同时作为按钮下标）
func _create_craft_button(slot: int) -> Button:
	var btn: Button = Button.new()
	var slot_name: String = _slot_name(slot)
	var cost: int = int(EquipmentRecyclerLib.CRAFT_FRAGMENT_COST)
	btn.text = "%s 0/%d" % [slot_name, cost]
	btn.tooltip_text = "消耗 %d 个%s碎片 + %d 梦境碎片，合成一件保底稀有的%s" \
		% [cost, slot_name, int(EquipmentRecyclerLib.CRAFT_DREAM_COST), slot_name]
	btn.custom_minimum_size = Vector2(104, 30)
	btn.focus_mode = Control.FOCUS_NONE
	## 缩放以按钮中心为原点（选中放大时不偏移）
	btn.pivot_offset = btn.custom_minimum_size * 0.5
	btn.add_theme_font_size_override("font_size", 12)
	## 按钮样式：统一金色强调（合成=成长向操作）；选中态由 _refresh_selection_visual 切换
	var styles: Dictionary = ChoiceCardStyleLib.build_card_styles(Color(0.95, 0.75, 0.3))
	ChoiceCardStyleLib.apply_card_styles(btn, styles, false)
	_craft_styles.append(styles)
	btn.add_theme_color_override("font_color", Color(1.0, 0.9, 0.7))
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	## 点击合成 / 鼠标悬停同步选中（slot 即合成视图的按钮下标）
	btn.pressed.connect(_confirm.bind(slot))
	btn.mouse_entered.connect(_set_selection.bind(slot))
	return btn

## 刷新合成按钮的碎片数与可用态（仅在碎片数变化时刷新，避免每帧无谓 set text）
## 参数：force - true 时强制刷新一次（初始化/合成后调用）
func _refresh_craft_buttons(force: bool = false) -> void:
	if _craft_buttons.is_empty():
		return
	var cost: int = int(EquipmentRecyclerLib.CRAFT_FRAGMENT_COST)
	var changed: bool = force or _last_craft_counts.size() != _craft_buttons.size()
	if not changed:
		for i in range(_craft_buttons.size()):
			if _last_craft_counts[i] != _get_fragment_count(i):
				changed = true
				break
	if not changed:
		return
	_last_craft_counts.clear()
	for i in range(_craft_buttons.size()):
		var frag: int = _get_fragment_count(i)
		_last_craft_counts.append(frag)
		var btn: Button = _craft_buttons[i]
		btn.text = "%s %d/%d" % [_slot_name(i), frag, cost]
		## 碎片不足时置灰提示（不置 disabled，与主视图按钮一致：仍可选中，确认时由 Shop 反馈失败，
		## 避免禁用态走主题 disabled 样式导致选中高亮丢失）
		var usable: bool = frag >= cost
		btn.modulate = Color(1, 1, 1, 1.0) if usable else Color(1, 1, 1, 0.45)

## 读取玩家指定槽位的装备碎片数量（玩家无对应接口时返回 0）
func _get_fragment_count(slot: int) -> int:
	if _player != null and _player.has_method("get_equipment_fragment"):
		return int(_player.get_equipment_fragment(slot))
	return 0

## 槽位下标 → 中文名（越界返回 "?"，容错）
func _slot_name(slot: int) -> String:
	if slot >= 0 and slot < SLOT_NAMES.size():
		return String(SLOT_NAMES[slot])
	return "?"

## 刷新标题栏碎片余额（仅变化时 set text）
func _update_fragment_label() -> void:
	if _title == null:
		return
	var count: int = 0
	if _player != null and _player is Node:
		count = int(_player.get("dream_fragment"))
	if count == _last_fragments:
		return
	_last_fragments = count
	_title.text = "✦ 梦境商店 ✦   碎片 %d" % count
