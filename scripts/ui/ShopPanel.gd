## ShopPanel.gd - 商店购买面板（紧凑底栏样式，与升级三选一/神庙同款横向排版）
## 职责：展示商店 3 件商品、碎片余额，玩家选定后发出购买信号、按取消关闭商店
## 设计意图：
##   1. 与 LevelUpPanel/TemplePanel 同风格：屏幕底部居中面板，商品横向一行排开
##   2. 鼠标点击/数字键1-3/手柄LT·RT扳机左右+D-Pad备用+A购买；ESC/B 关闭商店
##   3. 描述走 tooltip 减小占用；标题栏实时显示玩家碎片余额
## 输入架构：选择输入全部经 InputManager 网关（SHOP_CHOICE 上下文放行
##           game_choice_prev/next=LT/RT、键盘Q/E，ui_left/right/confirm 为确认/备用，ui_cancel 关闭）
## 数据流：Shop.interact() → 创建面板 → setup(products, player)
##        → 玩家选定 product_selected → Shop 扣款并应用效果
##        → 玩家按ESC/点关闭按钮 → close_requested → Shop 恢复游戏并关闭面板
extends Control

## ========== 预加载资源 ==========

## 商品数据类（读取 ProductType 枚举做"属性/技能/护盾/回血"类型标注；
## 本项目禁止用全局类名引用，一律 preload）
const ShopProductLib = preload("res://scripts/resources/shop/ShopProduct.gd")

## 卡片样式共享工具（与三选一/神庙同款：粗边框+外发光+底色提亮的选中态）
const ChoiceCardStyleLib = preload("res://scripts/ui/ChoiceCardStyle.gd")

## ========== 信号定义 ==========

## 玩家选定某商品购买（未扣款，由 Shop 校验余额并扣款）
## 参数：product - 被选中的 ShopProduct 资源
signal product_selected(product: Resource)

## 玩家请求关闭商店（ESC/B 或关闭按钮）
signal close_requested()

## ========== 成员变量 ==========

var _products: Array = []          ## 全部商品（ShopProduct 资源）
var _buttons: Array[Button] = []   ## 商品按钮列表（动画用）

## 每件商品的样式集（与 _buttons 下标一一对应，来自 ChoiceCardStyleLib.build_card_styles()）
var _button_styles: Array[Dictionary] = []
var _vbox: VBoxContainer = null    ## 内部垂直容器（标题 + 商品行 + 关闭按钮）
var _hbox: HBoxContainer = null    ## 商品水平容器（3 件一行排开）
var _title: Label = null           ## 标题（含碎片余额，购买后刷新）
var _selected_index: int = -1      ## 当前选中商品索引

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
	panel_bg.offset_top = -156.0  ## 面板含标题+商品行+关闭按钮，高度约110px
	panel_bg.offset_bottom = -46.0

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

	## ---------- 内部布局：标题 + 商品行 + 关闭按钮 ----------
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 4)
	panel_bg.add_child(_vbox)

	## 标题（含碎片余额，余额变化时刷新）
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	_title.text = "✦ 梦境商店 ✦"
	_vbox.add_child(_title)

	## 商品水平容器（与升级三选一同款横向排版，3 件一行不溢出）
	_hbox = HBoxContainer.new()
	_hbox.add_theme_constant_override("separation", 6)
	_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_vbox.add_child(_hbox)

	## 关闭按钮（ESC/B 同效）
	var close_btn: Button = Button.new()
	close_btn.text = "离开商店 (ESC)"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.custom_minimum_size = Vector2(140, 26)
	close_btn.add_theme_font_size_override("font_size", 12)
	close_btn.pressed.connect(close_requested.emit)
	_vbox.add_child(close_btn)

	## 入场动画初始状态
	panel_bg.modulate.a = 0.0
	var tween: Tween = create_tween()
	tween.tween_property(panel_bg, "modulate:a", 1.0, 0.15)

## _process() - 手柄LT/RT扳机(或D-Pad/键盘左右)导航、购买确认、关闭（经InputManager网关消费）
func _process(_delta: float) -> void:
	if _buttons.is_empty():
		return

	## 刷新标题上的碎片余额（仅在变化时 set text，避免每帧无谓刷新）
	_update_fragment_label()

	## 左移一件：手柄LT扳机 / 键盘Q / 备用D-Pad左·键盘左方向键（边界夹取不循环）
	if InputManager.is_action_just_pressed_safe("game_choice_prev") \
			or InputManager.is_action_just_pressed_safe("ui_left"):
		_set_selection(_selected_index - 1)
	## 右移一件：手柄RT扳机 / 键盘E / 备用D-Pad右·键盘右方向键
	elif InputManager.is_action_just_pressed_safe("game_choice_next") \
			or InputManager.is_action_just_pressed_safe("ui_right"):
		_set_selection(_selected_index + 1)

	## A键/Space/Enter：购买当前选中商品
	if InputManager.is_action_just_pressed_safe("ui_confirm") \
			or InputManager.is_action_just_pressed_safe("game_confirm"):
		_confirm(_selected_index)
	## ESC/B：关闭商店
	if InputManager.is_action_just_pressed_safe("ui_cancel"):
		close_requested.emit()

## _unhandled_input() - 数字键 1/2/3 快捷购买
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var index: int = -1
	match event.physical_keycode:
		KEY_1: index = 0
		KEY_2: index = 1
		KEY_3: index = 2
	if index >= 0 and index < _products.size():
		product_selected.emit(_products[index])

## ========== 对外接口 ==========

## 初始化面板显示（Shop 创建面板后调用）
## 参数：products - 商品数组；player - 玩家节点（读取碎片余额）
func setup(products: Array, player: Node) -> void:
	_products = products
	_player = player
	_buttons.clear()
	_button_styles.clear()
	_selected_index = -1
	for i in range(products.size()):
		var btn: Button = _create_product_button(products[i], i)
		_hbox.add_child(btn)
		_buttons.append(btn)
	## 默认高亮第一件（Shop.push_context 自带 0.2s 屏蔽期，已替输入防抖）
	_set_selection(0)
	## 立即刷新一次余额显示
	_last_fragments = -1
	_update_fragment_label()

## 购买成功后刷新碎片余额（Shop 扣款完成后调用）
func refresh_after_purchase() -> void:
	_last_fragments = -1
	_update_fragment_label()

## 余额不足提示（Shop 判定失败时调用）：标题短暂变红提醒
func notify_insufficient() -> void:
	if _title == null:
		return
	var t: Tween = create_tween()
	t.tween_property(_title, "modulate", Color(1.0, 0.35, 0.35), 0.12)
	t.tween_property(_title, "modulate", Color.WHITE, 0.12)

## ========== 内部构建方法 ==========

## 创建单个商品按钮
## 参数：product - 商品资源，index - 序号（数字键提示用）
func _create_product_button(product: Resource, index: int) -> Button:
	var btn: Button = Button.new()
	var price: int = int(product.price)
	## 类型标注：明确告诉玩家这是"属性/技能/护盾/回血"（判定来源 ShopProduct.product_type，
	## 与商品 apply() 的生效分支同源，杜绝"显示技能实际是属性"的错标）
	var type_text: String = _product_type_text(product)
	var type_tag: String = "[%s]" % type_text if type_text != "" else ""
	btn.text = "%d.%s %s  [%d碎片]" % [index + 1, type_tag, product.display_name, price]
	## 描述 + 价格走 tooltip（减小面板占用）
	btn.tooltip_text = "%s（%s）\n价格：%d 梦境碎片" % [product.description, type_text, price]
	btn.custom_minimum_size = Vector2(160, 32)
	btn.focus_mode = Control.FOCUS_NONE

	## 按钮样式：由共享工具统一生成（强调色=商品主题色，即稀有度/品类色）
	## 这里先套"未选中"组（1px 细边框）；选中态由 _refresh_selection_visual 切换为粗边框+外发光
	var styles: Dictionary = ChoiceCardStyleLib.build_card_styles(product.product_color)
	ChoiceCardStyleLib.apply_card_styles(btn, styles, false)
	_button_styles.append(styles)

	## 字体颜色跟随商品主题色（稀有度/品类色区分）
	btn.add_theme_color_override("font_color", product.product_color)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_font_size_override("font_size", 13)

	## 点击购买
	btn.pressed.connect(_confirm.bind(index))
	## 缩放以按钮中心为原点（选中放大时不偏移）
	btn.pivot_offset = btn.custom_minimum_size * 0.5
	## 鼠标悬停即同步选中索引：键鼠与手柄共用同一套选中高亮/确认逻辑
	btn.mouse_entered.connect(_set_selection.bind(index))
	return btn

## 设置当前选中商品（鼠标悬停与 D-Pad/LT·RT 导航的唯一入口）
func _set_selection(index: int) -> void:
	if _buttons.is_empty():
		return
	var new_index: int = clampi(index, 0, _buttons.size() - 1)
	if new_index == _selected_index:
		return
	_selected_index = new_index
	_refresh_selection_visual()

## 刷新全部商品的选中态视觉（选中=粗边框+外发光+底色提亮+放大，其余=1px 细边框常态）
## 具体样式由 ChoiceCardStyle 统一提供，三选一/商店/神庙三处表现完全一致
func _refresh_selection_visual() -> void:
	for i in range(_buttons.size()):
		var btn: Button = _buttons[i]
		if i >= _button_styles.size():
			continue
		ChoiceCardStyleLib.refresh_card(btn, _button_styles[i], i == _selected_index, SELECT_TWEEN_TIME)

## 商品类型文案（用于卡片上的类型标注与 tooltip）
## 参数：product - 商品资源（ShopProduct）
## 返回："属性"/"技能"/"护盾"/"回血"；类型字段缺失时返回空串（容错，不显示标签）
func _product_type_text(product: Resource) -> String:
	if product == null or not ("product_type" in product):
		return ""
	match int(product.product_type):
		ShopProductLib.ProductType.ATTRIBUTE:
			return "属性"
		ShopProductLib.ProductType.SKILL:
			return "技能"
		ShopProductLib.ProductType.SHIELD:
			return "护盾"
		ShopProductLib.ProductType.HEALTH:
			return "回血"
	return ""

## 确认购买当前选中商品（鼠标点击 / 数字键 / 导航后A键都走这里）
func _confirm(index: int) -> void:
	if index < 0 or index >= _products.size():
		return
	product_selected.emit(_products[index])

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
